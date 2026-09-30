# Configure AWS back-end PrivateLink for Databricks using the UIs

This guide creates private connectivity from a Databricks classic compute plane
in a customer AWS account to the Databricks control plane. It uses the AWS
Management Console and the Databricks account console, without Terraform or
API calls.

Databricks now calls this **classic compute plane PrivateLink**. It is also
commonly called **back-end PrivateLink**.

This procedure creates two AWS interface endpoints:

1. **General Access (workspace/REST API):** carries calls from classic compute
   to workspace REST APIs and other control-plane services.
2. **Secure cluster connectivity (SCC) relay:** carries the long-lived secure
   cluster connectivity tunnel.

These endpoints do not provide inbound private access for users, browsers, or
external clients. Inbound, or front-end, PrivateLink is a separate use case.

## Architecture

```text
Customer AWS account                              Databricks AWS account

Classic cluster
  |-- HTTPS/control-plane APIs --> General Access interface endpoint
  |                                 --> Databricks General Access endpoint service
  |
  `-- SCC tunnel -----------------> SCC relay interface endpoint
                                    --> Databricks SCC relay endpoint service
```

Databricks owns the two regional **VPC endpoint services**. You create two
consumer **interface VPC endpoints** in the workspace VPC. PrivateLink connects
their private endpoint ENIs to the Databricks services without VPC peering or a
routed connection between the two VPCs.

## Requirements

Before starting, confirm all of the following:

- The Databricks account uses the Enterprise pricing tier.
- The workspace uses classic compute and secure cluster connectivity.
- The workspace is, or will be, deployed in a customer-managed VPC.
- The VPC, workspace, endpoint services, endpoint registrations, network
  configuration, private access settings, and workspace are all in the same
  AWS region.
- The VPC has **DNS resolution** and **DNS hostnames** enabled.
- The workspace has at least two private workspace subnets in different
  Availability Zones. Each workspace subnet must be between `/17` and `/26`.
- You have AWS permissions to create subnets, route-table associations,
  security groups, and interface VPC endpoints.
- You are a Databricks account administrator.

An existing workspace deployed in a Databricks-managed VPC cannot be converted
to use back-end PrivateLink. Create a customer-managed-VPC workspace instead.
An existing workspace that already uses a customer-managed VPC can be updated
using a new Databricks network configuration.

## Information to collect

Record these values before opening the consoles:

| Value | Example |
| --- | --- |
| Workspace region | `us-west-2` |
| Workspace VPC ID | `vpc-...` |
| Two workspace subnet IDs | `subnet-...`, `subnet-...` |
| Workspace security group ID | `sg-...` |
| General Access service name | `com.amazonaws.vpce.<region>.vpce-svc-...` |
| SCC relay service name | `com.amazonaws.vpce.<region>.vpce-svc-...` |

Always copy the two service names from the current
[Databricks regional service table](https://docs.databricks.com/aws/en/resources/ip-domain-region#privatelink).
Do not reuse service names from another region.

For example, the current `us-west-2` values are:

| Purpose | Service name |
| --- | --- |
| General Access, including REST APIs | `com.amazonaws.vpce.us-west-2.vpce-svc-0129f463fcfbc46c5` |
| SCC relay | `com.amazonaws.vpce.us-west-2.vpce-svc-0158114c0c730c3bb` |

Verify these values against the linked table before every new deployment.

## Step 1: Prepare endpoint subnets

A dedicated endpoint subnet is recommended. For resilience, create one endpoint
subnet in each Availability Zone used by the workspace.

In the AWS Management Console:

1. Open **VPC** and select the workspace region.
2. Select **Subnets**, then **Create subnet**.
3. Select the workspace VPC.
4. Create one small private subnet per selected Availability Zone. `/27` is a
   practical size for a dedicated endpoint subnet.
5. Select **Route tables**, then **Create route table**.
6. Associate the endpoint subnets with this route table.
7. Keep only the automatically created VPC-local route. Do not add an internet
   gateway or NAT gateway route to this endpoint route table.

The endpoint ENIs and classic-compute ENIs communicate through the VPC's local
route. The endpoint subnet IDs are not the workspace subnet IDs entered later
in the Databricks network configuration.

You can place the endpoints in workspace subnets when dedicated endpoint
subnets are not practical, but separation makes routing and security policies
easier to understand.

## Step 2: Create the endpoint security group

Use a separate security group for the interface endpoints.

1. In the AWS VPC console, select **Security groups**.
2. Select **Create security group**.
3. Enter a descriptive name such as `databricks-backend-privatelink-endpoints`.
4. Select the workspace VPC.
5. Add inbound TCP rules whose source is the **workspace security group**, not
   a public CIDR:

   | Port | Purpose |
   | --- | --- |
   | `443` | General Access and REST APIs |
   | `6666` | SCC relay |
   | `2443` | FIPS SCC; required with the compliance security profile |
   | `5432` | Lakebase control-plane connectivity when applicable |
   | `8443-8451` | Databricks control-plane services, logging, lineage, and reserved services |

6. The endpoint security group does not require outbound rules for response
   traffic because AWS security groups are stateful.
7. Save the security group and record its `sg-...` ID.

Ensure the workspace security group permits the corresponding outbound TCP
traffic to the endpoint security group. It must allow at least `443` and
`6666`; add `2443`, `5432`, and `8443-8451` when those services apply. Keep the
normal workspace self-referencing TCP and UDP rules required by Databricks.

Network ACLs must also permit the required traffic. Databricks requires
workspace subnet network ACLs that do not deny ingress or egress.

## Step 3: Create the General Access VPC endpoint

1. In the AWS VPC console, select **Endpoints**.
2. Confirm the AWS region in the upper-right corner matches the workspace.
3. Select **Create endpoint**.
4. Enter a name such as `databricks-<region>-workspace-vpce`.
5. For **Service category**, select **Endpoint services that use Network Load
   Balancers (NLBs) and Gateway Load Balancers (GWLBs)**.
6. Paste the regional **General Access (including REST API)** service name.
7. Select **Verify service** and confirm that AWS reports **Service name
   verified**.
8. Select the workspace VPC.
9. Select the dedicated endpoint subnet in each Availability Zone. AWS permits
   one endpoint subnet per Availability Zone.
10. Select the endpoint security group created in Step 2.
11. Under **Additional settings**, enable **Private DNS name**.
12. Select **Create endpoint**.
13. Record the new AWS endpoint ID, `vpce-...`.

The endpoint might remain in `Pending acceptance` until it is registered with
Databricks.

## Step 4: Create the SCC relay VPC endpoint

Repeat Step 3 with these changes:

- Name: `databricks-<region>-scc-vpce`, or another name containing `scc`.
- Service name: the regional **Secure cluster connectivity relay** service.
- VPC, endpoint subnets, and endpoint security group: use the same selections
  as the General Access endpoint.
- Enable **Private DNS name**.

Record the second `vpce-...` ID. At this point you should have exactly two
Databricks back-end endpoints: one General Access endpoint and one SCC relay
endpoint.

## Step 5: Register both endpoints with Databricks

Registration creates Databricks account objects that wrap the AWS endpoints.
It does not create ENIs, DNS records, routes, or security groups.

For the General Access endpoint:

1. Open the [Databricks account console](https://accounts.cloud.databricks.com/).
2. Select **Security**.
3. Select **Networking**.
4. In the vertical navigation, select **VPC endpoints**.
5. Select **Register a VPC endpoint**.
6. Enter a descriptive registration name, such as
   `VPCE <region> workspace REST`.
7. Select the workspace region.
8. Paste the General Access AWS endpoint ID, `vpce-...`.
9. Select **Register new VPC endpoint**.

Repeat the procedure for the SCC relay endpoint, using a name such as
`VPCE <region> SCC relay` and its own `vpce-...` ID.

The region is critical. Databricks validates the registration's region only
when the workspace is created or updated. Endpoint registrations are
immutable; delete and recreate an incorrect registration.

Return to the AWS VPC console and confirm that both endpoints eventually reach
the `Available` state.

## Step 6: Create a Databricks network configuration

A network configuration registers the customer-managed VPC and tells
Databricks which endpoint handles each back-end function.

1. In the Databricks account console, select **Security**.
2. Find **Classic network configurations**.
3. Select **Add network configuration**.
4. Enter a descriptive network configuration name.
5. Enter the workspace VPC ID.
6. Enter at least two **workspace subnet IDs** from different Availability
   Zones. Do not enter the dedicated endpoint subnet IDs here.
7. Enter the **workspace security group ID**. Do not substitute the endpoint
   security group.
8. Under **Back-end private connectivity**, select:
   - **Secure cluster connectivity relay:** the SCC endpoint registration.
   - **Workspace (REST APIs):** the General Access endpoint registration.
9. Select **Add**.

Network configurations are immutable. When enabling PrivateLink on an existing
customer-managed-VPC workspace, create a new network configuration containing
the two endpoint registrations and update the workspace to use it.

AWS VPC endpoints can be shared by multiple Databricks workspaces that use the
same VPC. Each workspace still needs its own Databricks network configuration.

## Step 7: Create private access settings

Private access settings express that the workspace uses PrivateLink and govern
which registered endpoints can access its UI and APIs.

1. In the Databricks account console, select **Security**.
2. Select **Private access settings**.
3. Select **Add private access settings**.
4. Enter a descriptive name.
5. Select the workspace region.
6. Set **Public access enabled**:
   - For a **back-end-only** PrivateLink deployment, normally select `True` so
     users and administrators can still reach the workspace UI and APIs over
     the public front end.
   - Select `False` only when an inbound/front-end PrivateLink endpoint and its
     DNS path are already prepared. Otherwise, you can lock users out of the
     workspace front end.
7. Select the **Private Access Level**:
   - `Account`: all endpoints registered in this Databricks account are
     eligible.
   - `Endpoint`: only explicitly selected registrations are eligible. Include
     the General Access/workspace registration used by this workspace. If the
     workspace also uses inbound PrivateLink, include that registration too.
8. Select **Add private access setting**.

When `Public access enabled` is `True`, IP access lists and context-based
ingress controls apply to public traffic. They do not filter traffic arriving
through PrivateLink.

## Step 8: Attach the objects to the workspace

For a new workspace:

1. In the Databricks account console, begin creating a classic workspace.
2. Complete its region, credential configuration, storage configuration, and
   other required fields.
3. Open **Advanced configurations**.
4. Under **Virtual Private Cloud**, select the network configuration created in
   Step 6.
5. Under **PrivateLink**, select the private access settings object created in
   Step 7.
6. Select **Save**.

For an existing workspace:

1. Terminate running classic compute before changing its network configuration.
2. Open **Workspaces** in the account console and select the workspace.
3. Choose the option to update the workspace.
4. Under **Advanced configurations**, select the new network configuration and
   private access settings object.
5. Save the update.

The existing workspace must already use a customer-managed VPC and secure
cluster connectivity.

## Step 9: Wait for propagation

1. Wait until the workspace status is `RUNNING`.
2. Wait an additional **20 minutes** before creating or starting classic
   compute. PrivateLink and DNS changes can continue propagating after the
   workspace first reports `RUNNING`.
3. Confirm that both AWS interface endpoints report `Available`.

## Step 10: Verify General Access from classic compute

Start a classic cluster and run the following from a notebook, replacing the
hostname with the workspace hostname and omitting `https://`:

```bash
%sh
nslookup <workspace-hostname>
```

The returned addresses must be private IP addresses assigned to the General
Access endpoint ENIs. Compare them with the **Subnets** section of the endpoint
in the AWS console.

Then test HTTPS connectivity:

```bash
%sh
curl -sS -o /dev/null -w '%{http_code}\n' \
  https://<workspace-hostname>/api/2.0/clusters/list
```

An HTTP response such as `401` proves that the private network and TLS path are
working; it only means the test did not provide Databricks authentication. Use
an approved OAuth or token-based test if you need to verify an authenticated
API response. Do not place long-lived credentials directly in a notebook.

If the hostname resolves to a public address, stop: the API request could be
using the NAT route even if it succeeds.

## Step 11: Verify SCC

Successfully starting and attaching a classic cluster is the main functional
test for SCC. If the cluster cannot establish the SCC tunnel, cluster startup
or attachment fails with control-plane connectivity errors.

For stronger evidence:

1. Enable VPC Flow Logs on the workspace or endpoint ENIs.
2. Start a classic cluster.
3. Confirm accepted TCP flows from classic-compute ENIs to the SCC endpoint ENI
   private IPs on port `6666`, or `2443` for the FIPS SCC path.

## Optional: make the compute plane fully private

Back-end PrivateLink only privatizes Databricks API and SCC traffic. It does
not automatically privatize S3, STS, Kinesis, package repositories, or your
data sources.

With the standard configuration, workspace subnets retain a NAT or equivalent
egress path. Databricks recommends regional endpoints for S3, STS, and
Kinesis, but they are mandatory only when public AWS service endpoints are not
reachable.

For a strict air-gapped deployment, also create:

- an S3 gateway endpoint attached to the workspace subnet route tables;
- an STS interface endpoint with private DNS enabled;
- a Kinesis Streams interface endpoint with private DNS enabled; and
- private or inspected paths for every other required destination.

Do not remove NAT or internet egress until every required Databricks, AWS,
library, and data-source destination has an approved private or inspected path.

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| AWS cannot verify the service name | The service name or selected AWS region is wrong |
| Endpoint remains `Pending acceptance` | Register the correct `vpce-...` ID with Databricks and recheck its region |
| Workspace update rejects the network configuration | Endpoint registration, VPC, or workspace regions do not match |
| Cluster cannot start or attach | SCC endpoint, port `6666`, private DNS, or endpoint registration is incorrect |
| REST test times out | Port `443`, endpoint SG direction, DNS, NACL, or routing is incorrect |
| Workspace hostname resolves publicly from the cluster | General Access endpoint private DNS is disabled or DNS forwarding is bypassing the VPC resolver |
| Users lose UI access | Public access was disabled without a working inbound PrivateLink and DNS path |
| A second endpoint fails private DNS association | Another endpoint for the same service already owns the VPC private DNS name; share the existing endpoint |

## Final checklist

- [ ] Customer-managed VPC with DNS hostnames and resolution enabled
- [ ] Secure cluster connectivity enabled
- [ ] General Access interface endpoint created with private DNS
- [ ] SCC relay interface endpoint created with private DNS
- [ ] Endpoint security group permits traffic from the workspace security group
- [ ] Both AWS `vpce-...` IDs registered in the correct Databricks region
- [ ] Network configuration maps SCC and REST registrations to the correct fields
- [ ] Private access settings created with the intended public-access behavior
- [ ] Network configuration and private access settings attached to the workspace
- [ ] Workspace `RUNNING` plus 20-minute propagation wait completed
- [ ] Workspace hostname resolves to the General Access endpoint's private IPs from classic compute
- [ ] Classic cluster starts and establishes SCC successfully

## References

- [Configure classic private connectivity to Databricks](https://docs.databricks.com/aws/en/security/network/classic/privatelink)
- [PrivateLink VPC endpoint services by region](https://docs.databricks.com/aws/en/resources/ip-domain-region#privatelink)
- [Manage VPC endpoint registrations](https://docs.databricks.com/aws/en/security/network/classic/vpc-endpoints)
- [Manage private access settings](https://docs.databricks.com/aws/en/security/network/classic/private-access-settings)
- [Configure a customer-managed VPC](https://docs.databricks.com/aws/en/security/network/classic/customer-managed-vpc)
- [Create an AWS interface endpoint](https://docs.aws.amazon.com/vpc/latest/privatelink/create-interface-endpoint.html)
