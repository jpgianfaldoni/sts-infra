# Connect Databricks classic compute read-only to Aurora PostgreSQL with AWS PrivateLink

This guide shows how to connect Databricks classic clusters in one VPC to a
private Amazon Aurora PostgreSQL cluster in another VPC by using the AWS
Console. The database remains private and does not need a public IP or public
route. This version of the design exposes Aurora reader replicas only.

This design is for **Databricks classic compute**. It does not use a Databricks
Network Connectivity Configuration (NCC), which applies to serverless compute.
It is also separate from the front-end and back-end PrivateLink options used to
privatize access to the Databricks workspace itself.

## What the components mean

| Component | Meaning and purpose |
|---|---|
| **VPC** | An isolated AWS network. The classic clusters run in the consumer VPC, while Aurora runs in the provider VPC. |
| **AWS PrivateLink** | A private, one-way service connection between VPCs. It exposes only the published database service instead of joining the two VPC networks or exchanging their routes. |
| **VPC endpoint service** | The provider-side PrivateLink resource in the Aurora VPC. It publishes an internal NLB and controls which AWS principals can request connections. |
| **Interface VPC endpoint** | The consumer-side PrivateLink resource in the classic-compute VPC. AWS creates private endpoint network interfaces in the selected subnets. Classic clusters connect to these private IPs. |
| **Network Load Balancer (NLB)** | A layer-4 TCP load balancer in the Aurora VPC. PrivateLink endpoint services require an NLB or Gateway Load Balancer. Here, the NLB receives TCP `5432` and forwards it to Aurora. It is internal and has no internet-facing address. |
| **Listener** | The NLB rule that listens for TCP connections on port `5432` and forwards them to a target group. |
| **Target group** | The NLB backend definition. Because Aurora cannot be registered directly by resource or DNS name, the group uses the current private IPs of the Aurora reader instances as IP targets. |
| **Security group** | A stateful virtual firewall. Separate rules protect the cluster nodes, interface endpoint, NLB, and Aurora database. |

PrivateLink is not a routable network link. Aurora cannot initiate connections
back to the classic-compute VPC, and resources in either VPC do not gain general
access to the other VPC.

## Traffic path

```text
Databricks classic cluster ENI
  -> interface VPC endpoint, TCP 5432, in the classic VPC
  -> AWS PrivateLink
  -> endpoint service in the Aurora VPC
  -> internal NLB listener, TCP 5432
  -> IP target group
  -> Aurora PostgreSQL reader-instance private IPs, TCP 5432
```

## Important design limitation

Aurora endpoints are stable DNS names, but the IP addresses behind them can
change during failover, maintenance, scaling, or instance replacement. An NLB
IP target does not follow Aurora DNS automatically.

This UI procedure is suitable for learning and controlled tests. For production:

- Monitor the Aurora reader endpoint, instance roles, and NLB target health.
- Automatically reconcile the current reader-instance private IPs with the
  target group, for example with EventBridge, Lambda, and scheduled
  verification.
- Never register the current writer for this read-only service.
- Remove a reader IP promptly if Aurora promotes that instance to writer during
  failover. A TCP health check verifies only that PostgreSQL accepts a
  connection; it cannot determine whether the target is still a reader.
- Use a database user with `SELECT`-only permissions. Database authorization is
  the final protection against writes if target reconciliation is delayed.

VPC peering avoids the NLB target synchronization problem because applications
can use the Aurora reader endpoint directly. See
[VPC peering guide](vpc-peering.md).

## Assumptions and prerequisites

- The Databricks workspace uses a **customer-managed VPC**. You must be able to
  create endpoint ENIs and security groups in the classic-compute VPC.
- The classic-compute and Aurora VPCs are in the same AWS Region. Cross-Region
  PrivateLink has additional requirements that are outside this guide.
- Aurora PostgreSQL is available, listens on TCP `5432`, and has **Publicly
  accessible** disabled.
- The cluster has at least one Aurora reader replica. If no replica exists,
  Aurora can send reader-endpoint connections to the writer.
- You can manage EC2 security groups, target groups, NLBs, VPC endpoint
  services, interface endpoints, and the Aurora security group.
- For cross-account deployments, administrators in both AWS accounts are
  available to configure permissions and accept the endpoint request.
- The Aurora cluster has a dedicated security group. This makes its network
  interfaces easier to identify and avoids granting access to unrelated
  databases.
- The consumer VPC has private subnets with enough free addresses for the
  interface endpoint ENIs. Dedicated endpoint subnets are preferable when the
  workspace subnets need to reserve their addresses for cluster nodes.

## Values to collect

| Value | Example placeholder |
|---|---|
| AWS Region | `<aws-region>` |
| Classic-compute VPC | `<classic-vpc-id>` |
| Classic workspace subnet IDs | `<classic-subnet-ids>` |
| Consumer endpoint subnet IDs | `<endpoint-subnet-ids>` |
| Classic cluster security group | `<classic-cluster-sg-id>` |
| Consumer AWS account ID | `<consumer-account-id>` |
| Aurora VPC | `<aurora-vpc-id>` |
| Aurora database security group | `<aurora-sg-id>` |
| Aurora reader endpoint | `<cluster-name>.cluster-ro-xxxxxxxx.<region>.rds.amazonaws.com` |
| Aurora reader instance endpoints | `<instance-name>.xxxxxxxx.<region>.rds.amazonaws.com` |
| Aurora database name | `<database-name>` |
| PostgreSQL port | `5432` |

## 1. Confirm the Databricks classic-compute VPC

1. Open the **Databricks Account Console**.
2. Go to **Workspaces** and select the workspace.
3. Open its network configuration and record the customer-managed VPC, workspace
   subnets, and security group IDs.
4. In the **AWS Console**, go to **VPC > Your VPCs** and confirm that this VPC is
   in your AWS account and Region.
5. Go to **EC2 > Security Groups** and identify the security group attached to
   the classic cluster nodes.

If the VPC is Databricks-managed and is not visible in your AWS account, you
cannot create the consumer interface endpoint in it. Deploy or migrate to a
customer-managed VPC, or choose a supported architecture that you control.

## 2. Record the Aurora networking details

1. In the AWS Console, go to **RDS > Databases**.
2. Select the Aurora PostgreSQL cluster and expand its list of instances.
3. Under **Connectivity & security**, record:
   - The reader cluster endpoint containing `cluster-ro`.
   - Port `5432`.
   - VPC, DB subnet group, and its subnets.
   - Database security group.
4. For every instance whose role is **Reader**, record its instance endpoint and
   availability zone.
5. Confirm **Publicly accessible** is **No** for every instance.
6. Confirm the cluster and each reader instance are **Available**.

Do not include the instance whose role is **Writer**. The application-facing
PrivateLink hostname will be the interface endpoint DNS name, while the Aurora
reader and instance endpoints are used to determine which private IPs belong in
the NLB target group.

## 3. Identify the current Aurora reader target IPs

Aurora does not appear as a resource target in the NLB target-group wizard. The
target must be registered as a private IP.

1. Go to **EC2 > Network Interfaces**.
2. Filter by:
   - The Aurora VPC.
   - The dedicated Aurora security group.
   - Description containing `RDSNetworkInterface`.
3. Match the network interfaces to the recorded reader-instance availability
   zones.
4. Record the primary private IPv4 address for each reader instance.
5. If more than one interface still matches in an availability zone, resolve
   each reader's **instance endpoint** from a private host in the VPC and match
   the returned address. Do not use the writer endpoint and do not guess.

Record the lookup time and the corresponding reader instance ID. Reconfirm the
reader roles and addresses after failover, scaling, maintenance, or instance
replacement.

## 4. Create the provider-side security groups

### Create the NLB security group

1. Go to **EC2 > Security Groups > Create security group**.
2. Name it `nlb-aurora-postgres-private-link`.
3. Select the Aurora VPC.
4. Do not add any internet-sourced inbound rule.
5. Remove the unrestricted outbound rule if required by your policy.
6. Add an outbound rule:
   - Type: **PostgreSQL** or **Custom TCP**.
   - Port: `5432`.
   - Destination: the Aurora database security group.

The NLB must be created with this security group. AWS does not allow adding a
security group later to an NLB that was originally created without one.

### Update the Aurora security group

1. Open the Aurora database security group.
2. Add an inbound rule:
   - Type: **PostgreSQL**.
   - Port: `5432`.
   - Source: the NLB security group.
3. Do not add `0.0.0.0/0`, the classic VPC CIDR, or an internet source for this
   PrivateLink path.

Referencing the NLB security group keeps the database rule independent of NLB
node IP changes.

## 5. Create the Aurora target group

1. Go to **EC2 > Target Groups > Create target group**.
2. Choose **IP addresses** as the target type.
3. Configure:
   - Name: `aurora-postgres-readers-private-link`.
   - Protocol: **TCP**.
   - Port: `5432`.
   - IP address type: **IPv4**.
   - VPC: the Aurora VPC.
4. Set the health check to **TCP** on **traffic port**.
5. Register every current Aurora reader private IP on port `5432`. Do not
   register the writer private IP.
6. Create the target group.

At this stage, AWS can show the registered targets as **Unused** with a message
that the target group is not configured to receive traffic. This is expected:
the target group cannot become healthy until step 6 creates an NLB listener
that forwards traffic to it. Do not wait at this point; continue to step 6.

## 6. Create the internal Network Load Balancer

1. Go to **EC2 > Load Balancers > Create load balancer**.
2. Choose **Network Load Balancer**.
3. Configure:
   - Scheme: **Internal**.
   - IP address type: **IPv4**.
   - VPC: the Aurora VPC.
4. Select private subnets in at least two availability zones used by the Aurora
   deployment.
5. Attach the NLB security group from step 4.
6. Add a listener:
   - Protocol: **TCP**.
   - Port: `5432`.
   - Default action: forward to the Aurora target group.
7. Create the NLB and wait for **Active**.
8. Open **Attributes** and enable **Cross-zone load balancing**. This allows an
   endpoint connection through one NLB zone to reach healthy reader targets in
   other enabled zones.
9. Under the NLB security settings, turn **Enforce inbound rules on PrivateLink
   traffic** **Off**. Access is still restricted by the endpoint service
   principal policy and consumer endpoint security group.
10. Return to **EC2 > Target Groups**, open the Aurora reader target group, and
    refresh the **Targets** tab.
11. Wait for every reader target to transition from **Unused** or **Initial** to
    **Healthy**.

Do not continue to the endpoint-service step while a reader target is unhealthy.
Confirm that the registered IP still belongs to a current reader, Aurora is
available, the NLB listener forwards TCP `5432` to this target group, and the
NLB-to-Aurora security-group rules from step 4 are correct.

The NLB is internal. Its DNS name and nodes are not publicly reachable.

## 7. Publish the NLB as a VPC endpoint service

1. Go to **VPC > Endpoint services > Create endpoint service**.
2. Select **Network** as the load balancer type.
3. Select the internal NLB.
4. Enable **Require acceptance for endpoint**.
5. Enable IPv4 and create the service.
6. Copy the service name:

   ```text
   com.amazonaws.vpce.<region>.vpce-svc-xxxxxxxxxxxxxxxxx
   ```

7. Open **Allow principals** for the endpoint service.
8. Add only the consumer AWS principal. An account-level example is:

   ```text
   arn:aws:iam::<consumer-account-id>:root
   ```

Use a narrower IAM principal when your account model supports it. Do not use
`*` unless the service is intentionally available to every AWS principal.

## 8. Create the consumer interface endpoint

1. Switch to the AWS account containing the classic-compute VPC if it is a
   different account.
2. Go to **VPC > Endpoints > Create endpoint**.
3. Under **Service category**, select **Endpoint services that use NLBs and
   GWLBs**.
4. Enter the endpoint service name from step 7 and click **Verify service**.
5. Select the classic-compute VPC.
6. Select one private endpoint subnet per supported availability zone. These
   subnets must be in the classic-compute VPC, but they do not have to be the
   Databricks workspace subnets because the VPC's local route connects all its
   subnets. Prefer dedicated endpoint subnets; otherwise use workspace subnets
   only after confirming they have sufficient free IP addresses.
7. Create a security group named `vpce-aurora-postgres` in the classic VPC.
8. Give that endpoint security group one inbound rule:
   - Type: **PostgreSQL**.
   - Port: `5432`.
   - Source: the classic cluster security group.
9. Attach this security group to the interface endpoint.
10. Leave **Private DNS** disabled unless the endpoint service has a verified
    private DNS name that your organization owns and deliberately configured.
11. Create the endpoint and record its VPC endpoint ID.

If the classic cluster security group restricts outbound traffic, add an
outbound TCP `5432` rule whose destination is the endpoint security group.

## 9. Accept the endpoint connection

1. Return to the account that owns the Aurora endpoint service.
2. Go to **VPC > Endpoint services** and select the service.
3. Open **Endpoint connections**.
4. Match the pending request to the consumer endpoint ID.
5. Choose **Actions > Accept endpoint connection request**.
6. Wait until the consumer endpoint reports **Available**.
7. Confirm the endpoint service shows the connection as **Available**.

## 10. Select the connection hostname and TLS behavior

Open the interface endpoint in **VPC > Endpoints** and copy its **regional DNS
name**. It resembles:

```text
vpce-xxxxxxxxxxxxxxxxx-yyyyyyyy.vpce-svc-xxxxxxxxxxxxxxxxx.<region>.vpce.amazonaws.com
```

Use the regional name rather than a zonal name when you want the endpoint ENIs
to remain available across the selected zones.

Because the NLB passes PostgreSQL TLS through unchanged, Aurora presents an RDS
certificate for its RDS hostname, not for the `vpce.amazonaws.com` hostname.
Consequently, PostgreSQL `verify-full` hostname validation fails when the
interface endpoint DNS name is used directly. Keep TLS enabled and use an
organization-approved configuration such as CA validation (`verify-ca`) with
the current Amazon RDS CA bundle. Do not silently disable encryption. A custom
DNS and certificate design requires separate security review.

## 11. Validate from a classic cluster

1. In the Databricks workspace UI, create or start a **classic** cluster.
2. Create a notebook and attach it to that cluster.
3. Run this TCP test with the interface endpoint's regional DNS name:

   ```python
   import socket

   host = "<interface-endpoint-regional-dns-name>"
   with socket.create_connection((host, 5432), timeout=10):
       print("Aurora PostgreSQL TCP 5432 is reachable through PrivateLink")
   ```

4. Store credentials for a PostgreSQL user with `SELECT`-only permissions in a
   Databricks secret or use an approved Unity Catalog connection. Do not use the
   Aurora master user and do not paste a password into the notebook.
5. Configure the PostgreSQL JDBC client with the endpoint DNS name, database,
   port `5432`, and the approved TLS mode, then run a small query such as
   `SELECT current_database(), inet_server_addr(), pg_is_in_recovery()`.
6. Confirm `pg_is_in_recovery()` returns `true`. This verifies the connection
   reached an Aurora replica rather than the writer.

Also confirm in the AWS Console:

- Interface endpoint: **Available**.
- Endpoint-service connection: **Available**.
- NLB: **Active**.
- Target: **Healthy**.
- Aurora: **Available** and not publicly accessible.

## Troubleshooting

### Service verification or endpoint creation fails

- Confirm both resources use the same Region.
- Confirm the endpoint service allows the consumer account or role.
- Confirm the requested consumer subnets use availability zones enabled on the
  endpoint service.

### Endpoint stays pending

- Accept the request under the provider endpoint service.
- Compare the endpoint ID before accepting it.

### TCP connection times out

- Check the endpoint security group allows `5432` from the cluster security
  group.
- Check restricted cluster egress allows `5432` to the endpoint security group.
- Confirm the NLB target is healthy.
- Confirm the NLB was created with its security group and PrivateLink inbound
  rule enforcement is off.

### Target becomes unhealthy after an Aurora event

- Re-read the cluster member roles and identify the current reader instances.
- Deregister stale targets and any target that Aurora promoted to writer.
- Register the current reader private IPs and wait for them to become healthy.
- Implement automated, role-aware target reconciliation before treating this
  as a production design.

### Read-only validation reaches a writer

- Immediately remove the writer IP from the target group.
- Confirm the cluster still has at least one available reader replica.
- Reconcile the target group from current cluster roles, not from a cached list
  of IP addresses.
- Keep using a `SELECT`-only database user so a routing mistake cannot perform
  writes.

### Authentication or TLS fails after TCP succeeds

TCP success proves networking only. Separately check the database name, user,
password, PostgreSQL authentication rules, Amazon RDS CA bundle, and TLS mode.
Expect `verify-full` to reject the endpoint DNS name because it does not match
the Aurora certificate hostname.

## Official references

- [Databricks customer-managed VPC requirements](https://docs.databricks.com/aws/en/security/network/classic/customer-managed-vpc)
- [AWS: Create an endpoint service](https://docs.aws.amazon.com/vpc/latest/privatelink/create-endpoint-service.html)
- [AWS: Access an endpoint service through an interface endpoint](https://docs.aws.amazon.com/vpc/latest/privatelink/create-interface-endpoint.html)
- [AWS: Create a Network Load Balancer](https://docs.aws.amazon.com/elasticloadbalancing/latest/network/create-network-load-balancer.html)
- [AWS: Security groups for Network Load Balancers](https://docs.aws.amazon.com/elasticloadbalancing/latest/network/load-balancer-security-groups.html)
- [AWS: Aurora endpoints](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/Aurora.Endpoints.html)
