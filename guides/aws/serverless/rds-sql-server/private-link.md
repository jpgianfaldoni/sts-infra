# Manually connect Databricks serverless to AWS SQL Server with NCC and PrivateLink

This guide explains the networking components and the AWS Console and
Databricks account-console steps required to connect serverless compute to a
private SQL Server destination.

Official reference: [Configure private connectivity to resources in your
VPC](https://docs.databricks.com/aws/en/security/network/serverless-network-security/pl-to-internal-network).

## What each component does

| Component | Where it lives | Purpose |
|---|---|---|
| **Databricks serverless compute plane** | Databricks-managed AWS account | Runs serverless notebooks, jobs, and SQL warehouses. It does not run inside the customer-managed VPC used by classic compute, so it needs its own outbound network path to private resources. |
| **Network Connectivity Configuration (NCC)** | Databricks account, scoped to one region | Defines how serverless workloads leave the Databricks-managed network. An NCC contains private endpoint rules and is attached to one or more workspaces. It affects serverless compute only; it does not replace the classic-compute VPC configuration. |
| **NCC private endpoint rule** | Inside the NCC | Maps one or more destination hostnames to an AWS endpoint service. When serverless code connects to a matching hostname, Databricks resolves and routes that traffic through the associated private endpoint instead of the normal public path. |
| **Workspace-to-NCC binding** | Databricks account | Activates the NCC for serverless workloads launched from a workspace. Creating an NCC alone does not affect a workspace until this binding is configured. A workspace can use only one NCC at a time. |
| **AWS PrivateLink** | Between the Databricks and customer AWS accounts | Provides private, one-way service connectivity across AWS VPCs without VPC peering, transit routing, or exposing the destination through the public internet. PrivateLink connects a consumer interface endpoint to a provider endpoint service. |
| **Interface VPC endpoint** | Databricks-managed serverless VPC | The consumer side of PrivateLink. Databricks creates and manages this endpoint after the NCC rule is created. The customer does not create it manually, but must copy its endpoint ID and accept its connection request. |
| **VPC endpoint service** | Customer AWS account and RDS VPC | The provider side of PrivateLink. It publishes the NLB as a private service, controls which AWS principals may connect, and optionally requires each connection to be approved. |
| **Stable Databricks IAM principal** | Databricks-managed AWS account | Identifies the Databricks serverless service that is permitted to create the consumer endpoint. Allowlisting the regional role is safer than allowing every AWS principal with `*`. |
| **Internal Network Load Balancer (NLB)** | Customer AWS account and RDS VPC | Provides the TCP frontend required by the endpoint service. It receives PrivateLink traffic on port `1433`, performs health-aware forwarding, and sends it to the SQL Server target group. It is internal, so it has no public internet-facing address. |
| **NLB listener** | On the NLB | Accepts a specific protocol and port. Here, the listener accepts TCP `1433` and forwards every connection to the SQL Server target group. |
| **Target group** | Customer AWS account and RDS VPC | Defines the backend destination for the NLB. It contains the current RDS private IP and port `1433` and continuously runs TCP health checks before forwarding traffic. |
| **Security groups** | Customer AWS account and RDS VPC | Act as stateful firewalls. The NLB security group can send only TCP `1433` to the database security group, and the database security group accepts `1433` from the NLB security group. |
| **RDS hostname and DNS matching** | RDS and the NCC rule | The RDS FQDN is the name used by JDBC or other clients. The NCC rule matches this name and overrides its route inside serverless compute. Using a different alias bypasses the rule unless that alias is also listed. |
| **RDS SQL Server** | Customer AWS account and RDS VPC | The final destination. The NLB registers its private IP as an IP target because an endpoint service cannot point directly to an RDS database. |

In short, the NCC decides *which serverless traffic should be private*;
PrivateLink transports that traffic between AWS accounts; the endpoint service
exposes the customer side; and the NLB delivers the TCP connection to RDS.

## Architecture

```text
Databricks workspace
  -> workspace-to-NCC binding
  -> NCC hostname rule
  -> Databricks serverless compute
  -> Databricks-managed interface VPC endpoint (PrivateLink consumer)
  -> customer AWS VPC endpoint service (PrivateLink provider)
  -> internal Network Load Balancer listener, TCP 1433
  -> healthy target group entry
  -> RDS SQL Server private IP, TCP 1433
```

The NCC rule associates the SQL Server hostname with the endpoint service.
Applications must use that exact hostname so Databricks DNS routing selects
the private endpoint.

The same endpoint service and NLB can also serve PostgreSQL. Add a TCP `5432`
listener and PostgreSQL target group, then add the PostgreSQL RDS FQDN to the
existing NCC rule's domain-name list. The destination port selects the correct
NLB listener, so this does not require another endpoint service or NLB.

## Values to collect

| Setting | Value |
|---|---|
| Databricks account | `<databricks-account-id>` |
| Workspace | `<workspace-name>` (`<workspace-id>`) |
| Workspace and NCC region | `<aws-region>` |
| NCC | `<ncc-name>` |
| NCC ID | `<ncc-id>` |
| RDS hostname | `<rds-hostname>` |
| RDS private IP at deployment | `<rds-private-ip>` |
| SQL port | `1433` |
| RDS VPC | `<vpc-id>` |
| Endpoint service | `com.amazonaws.vpce.<region>.vpce-svc-xxxxxxxxxxxxxxxxx` |
| Databricks endpoint | `<vpc-endpoint-id>` |
| NCC rule | `<ncc-rule-id>` |
| Databricks stable IAM principal | `arn:aws:iam::565502421330:role/private-connectivity-role-<region>` |

## Prerequisites

- The Databricks workspace must use the Enterprise plan.
- You must be a Databricks account administrator.
- You need AWS permission to manage security groups, NLBs, target groups, and
  VPC endpoint services.
- The NCC and workspace must use the same region.
- The destination must listen on a TCP port reachable from the NLB.
- Check regional capacity before starting. Databricks documents a limit of 30
  private endpoints per region across the account.

## 1. Find the RDS private IP

1. Open the **AWS Console** in the RDS and workspace region.
2. Go to **RDS > Databases** and select the SQL Server instance.
3. Under **Connectivity & security**, record:
   - The endpoint hostname.
   - Port `1433`.
   - The VPC and VPC security group.
4. Go to **EC2 > Network Interfaces**.
5. Filter by the RDS security group and description
   `RDSNetworkInterface`.
6. Record the in-use interface's primary private IPv4 address.

RDS IP addresses can change after replacement, maintenance, or failover. A
multi-AZ RDS deployment does not provide stable target IPs. For production,
automate synchronization between RDS DNS and the NLB target group.

## 2. Create a security group for the NLB

1. Go to **EC2 > Security Groups > Create security group**.
2. Use the RDS VPC recorded above.
3. Give it a recognizable name such as
   `nlb-sql-server-private-link`.
4. Do not add a public inbound rule.
5. Remove the default unrestricted outbound rule.
6. Add this outbound rule:
   - Type: **Custom TCP**
   - Port: `1433`
   - Destination: the RDS database security group
7. Open the RDS database security group.
8. Add this inbound rule:
   - Type: **Custom TCP**
   - Port: `1433`
   - Source: the new NLB security group

Do not add an internet-sourced ingress rule; the database remains private.

## 3. Create the SQL Server target group

1. Go to **EC2 > Target Groups > Create target group**.
2. Choose **IP addresses** as the target type.
3. Configure:
   - Protocol: **TCP**
   - Port: `1433`
   - IP address type: **IPv4**
   - VPC: the RDS VPC
4. Configure the health check:
   - Protocol: **TCP**
   - Port: **traffic port**
5. Register the RDS private IP on port `1433`.
6. Create the target group.
7. In the target-group attributes, ensure **Preserve client IP addresses** is
   disabled for this IP target.

Do not continue until the target becomes **Healthy**. If it remains unhealthy,
check the RDS security-group rule, RDS status, private IP, and port.

## 4. Create the internal Network Load Balancer

1. Go to **EC2 > Load Balancers > Create load balancer**.
2. Choose **Network Load Balancer**.
3. Configure:
   - Scheme: **Internal**
   - IP address type: **IPv4**
   - VPC: the RDS VPC
4. Select subnets in at least two availability zones.
5. Attach the NLB security group created in step 2.
6. Create a listener:
   - Protocol: **TCP**
   - Port: `1433`
   - Forward to: the SQL Server target group
7. Create the NLB and wait until its state is **Active**.
8. Under the NLB attributes, enable **Cross-zone load balancing**.
9. Under **Security**, set **Enforce inbound rules on PrivateLink traffic** to
   **Off**. Databricks explicitly requires this setting for this pattern.

## 5. Create the VPC endpoint service

1. Go to **VPC > Endpoint services > Create endpoint service**.
2. Select **Network** as the load-balancer type.
3. Select the internal NLB from step 4.
4. Enable **Require acceptance for endpoint**.
5. Use IPv4 support and create the service.
6. Copy its full service name. It has this form:

   ```text
   com.amazonaws.vpce.<region>.vpce-svc-xxxxxxxxxxxxxxxxx
   ```

7. Open the endpoint service's **Allow principals** tab.
8. Add the Databricks stable serverless principal for the workspace region:

   ```text
   arn:aws:iam::565502421330:role/private-connectivity-role-<region>
   ```

Do not allow `*` unless intentionally accepting connections from any AWS
principal. The region in the role ARN is the Databricks workspace/NCC region.

## 6. Create the NCC in Databricks

1. Open the AWS Databricks **Account Console** at
   [accounts.cloud.databricks.com](https://accounts.cloud.databricks.com).
2. Confirm the expected Databricks account ID.
3. Go to **Security > Network connectivity configurations**.
4. Click **Add network configuration**.
5. Set:
   - Name: a descriptive NCC name
   - Region: the workspace region
6. Click **Add**.

An NCC is regional and can only be attached to workspaces in its region.

## 7. Add the private endpoint rule

1. Open the NCC created in the previous step.
2. Select **Private endpoint rules**.
3. Click **Add private endpoint rule**.
4. Enter the full AWS endpoint service name from step 5.
5. Add the exact RDS hostname as the destination FQDN:

   ```text
   your-sql-server.example.internal
   ```

6. Create the rule.
7. Wait for it to reach **Pending**.
8. Open the rule and copy the generated AWS VPC endpoint ID.

Use this same hostname in JDBC, Lakehouse Federation, or other connection
settings. A different alias will not match the NCC rule unless it is also
added as a domain name.

## 8. Accept the Databricks endpoint in AWS

1. Return to **AWS VPC > Endpoint services**.
2. Select the endpoint service created in step 5.
3. Open **Endpoint connections**.
4. Find the connection using the endpoint ID copied in step 7.
5. Select it and choose **Actions > Accept endpoint connection request**.
6. Confirm acceptance.
7. Wait until the AWS connection state is **Available**.

## 9. Confirm the NCC rule is established

1. Return to the Databricks Account Console.
2. Go to **Security > Network connectivity configurations**.
3. Open the target NCC and then **Private endpoint rules**.
4. Confirm the SQL Server rule reports **Established**.

The rule is ready when its state is `ESTABLISHED`.

## 10. Attach the NCC to the workspace

1. In the Databricks Account Console, go to **Workspaces**.
2. Select the target workspace.
3. Under **Networking**, locate **Network connectivity configuration**.
4. Select the NCC created above.
5. Save or update the workspace configuration.
6. Confirm the workspace remains **Running** and displays the NCC assignment.

A workspace can be bound to only one NCC. Put all required endpoint rules in
that NCC rather than attaching multiple NCCs.

## 11. Validate from serverless compute

First confirm all control-plane checks:

- NLB state: **Active**.
- SQL target: **Healthy** on the recorded private IP and port `1433`.
- AWS endpoint connection: **Available**.
- Databricks private endpoint rule: **Established**.
- Target workspace NCC assignment: the NCC created above.

Then create a notebook in the target workspace, attach it to serverless compute, and
run a TCP connectivity check:

```python
import socket

host = "your-sql-server.example.internal"
with socket.create_connection((host, 1433), timeout=10):
    print("SQL Server TCP 1433 is reachable through the NCC")
```

For an authenticated query, store credentials in a Databricks secret or use a
Unity Catalog connection. Do not place the SQL password directly in a
notebook.

Network-policy changes usually propagate within 10 minutes but can take up to
24 hours. Retry only after verifying that both endpoint states remain healthy.

## Troubleshooting

### Endpoint quota reached

The Databricks account has a regional private-endpoint quota. Rejected,
expired, and recently deleted rules can consume capacity even when they are not
obvious in the AWS console.

1. In **Security > Network connectivity configurations**, inspect all NCCs in
   the target region.
2. Remove only endpoint rules that are known to be unused and are owned by your
   team.
3. Deletion can be asynchronous, so capacity might not return immediately.
4. Retry creation after the old rules disappear from the account inventory.


### NLB target is unhealthy

- Confirm SQL Server is available and listening on `1433`.
- Confirm the registered IP is the current RDS private IP.
- Confirm the database security group allows `1433` from the NLB security
  group.
- Confirm the NLB security group allows outbound `1433` to the database
  security group.

### Rule stays pending

- Confirm the AWS endpoint request was accepted.
- Confirm the endpoint service allowlist contains the regional Databricks
  stable IAM role.
- Confirm **Enforce inbound rules on PrivateLink traffic** is off.
- Confirm the AWS endpoint connection reaches **Available**.

### Connection still uses the public path

- Use the exact FQDN listed on the NCC rule.
- Confirm the workspace is bound to the NCC.
- Confirm the workload is actually using Databricks serverless compute; the
  classic compute VPC and NCC serverless path are separate networking planes.

## Operational considerations

- NLB hours/LCUs, PrivateLink, data transfer, and Databricks serverless
  networking can incur charges.
- Monitor the RDS private IP and NLB target health.
- Keep endpoint-service acceptance enabled and restrict allowed principals.
- Keep direct public database access disabled unless a separately reviewed
  requirement explicitly needs it.
