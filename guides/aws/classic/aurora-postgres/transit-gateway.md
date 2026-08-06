# Connect Databricks classic compute to Aurora PostgreSQL with AWS Transit Gateway

This guide shows how to connect Databricks classic clusters in one VPC to a
private Amazon Aurora PostgreSQL cluster in another VPC by using AWS Transit
Gateway and the AWS Console. Aurora remains private, and clients use the normal
Aurora DNS endpoint.

This design is for **Databricks classic compute** in a customer-managed VPC. It
does not use a Databricks Network Connectivity Configuration (NCC), which
controls serverless compute networking.

## What Transit Gateway means

An **AWS Transit Gateway (TGW)** is a regional network-routing hub managed by
AWS. VPCs, site-to-site VPNs, and Direct Connect gateways attach to the hub
instead of creating a separate point-to-point connection between every pair of
networks.

```text
                         On-premises network
                                  |
                                  v
Databricks VPC ----> AWS Transit Gateway <---- Aurora VPC
                           ^        ^
                           |        |
                    Other application VPCs
```

A Transit Gateway is not a VPC, load balancer, NAT gateway, firewall, or
PrivateLink endpoint. It does not contain the database and does not grant
network access by itself. It routes packets between attached networks according
to its route tables. VPC route tables, security groups, and network ACLs still
control the complete path.

## The two routing layers

This design has two different types of route table:

| Route table | Purpose |
|---|---|
| **VPC subnet route table** | Tells a workload subnet to send traffic for the other VPC CIDR to the Transit Gateway. |
| **Transit Gateway route table** | Tells the Transit Gateway which VPC attachment should receive that traffic. |

For example:

```text
Databricks subnet route table
  10.43.0.0/16 -> tgw-...

Transit Gateway route table
  10.43.0.0/16 -> tgw-attach-... (Aurora VPC attachment)

Aurora subnet route table
  10.44.0.0/18 -> tgw-...

Transit Gateway route table
  10.44.0.0/18 -> tgw-attach-... (Databricks VPC attachment)
```

Both directions are required. A route makes a destination reachable; it does
not permit a connection. Security groups provide that permission separately.

## When Transit Gateway is a good choice

Use Transit Gateway when the network architecture includes:

- Several workspace, application, shared-service, and database VPCs.
- Centralized connectivity to on-premises networks through VPN or Direct
  Connect.
- A hub-and-spoke model with centrally managed routing and isolation domains.
- Growth that would otherwise create a difficult mesh of VPC peerings.

For only two VPCs, VPC peering is usually simpler and less expensive. Transit
Gateway has an hourly charge for each attachment and data-processing charges.
PrivateLink is preferable when the requirement is to expose only one service
without providing general routed connectivity between VPCs.

TGW routing is transitive when its route tables allow it. This is different
from VPC peering, which is not transitive. That capability is useful, but it
also means the route-table design must deliberately prevent unwanted
spoke-to-spoke paths.

## Assumptions and prerequisites

- The Databricks workspace uses a customer-managed VPC visible in your AWS
  account.
- The classic-compute and Aurora VPC CIDRs do not overlap.
- The VPCs are in the same AWS Region as the Transit Gateway. Cross-Region
  designs require Transit Gateway peering and additional routing not covered
  here.
- Aurora PostgreSQL listens on TCP `5432`, is **Available**, and has **Publicly
  accessible** disabled.
- You can manage Transit Gateways, AWS Resource Access Manager when required,
  VPC attachments, subnets, route tables, security groups, and network ACLs.
- For cross-account VPCs, administrators in all participating accounts are
  available to share the TGW, create attachments, and approve requests.
- The organization has confirmed who owns TGW route changes. Production
  networks should not rely on unreviewed automatic route propagation.

Transit Gateway does not solve overlapping CIDRs for direct VPC-to-VPC
communication. Use non-overlapping address plans or introduce a deliberate NAT
architecture outside this procedure.

## Values to collect

| Value | Example placeholder |
|---|---|
| AWS Region | `<aws-region>` |
| Databricks VPC ID | `<classic-vpc-id>` |
| Databricks VPC CIDR | `<classic-vpc-cidr>` |
| Databricks workspace subnet IDs | `<classic-subnet-ids>` |
| Databricks private route-table IDs | `<classic-route-table-ids>` |
| Databricks compute security group | `<classic-cluster-sg-id>` |
| Aurora VPC ID | `<aurora-vpc-id>` |
| Aurora VPC CIDR | `<aurora-vpc-cidr>` |
| Aurora DB subnet IDs | `<aurora-db-subnet-ids>` |
| Aurora DB route-table IDs | `<aurora-route-table-ids>` |
| Aurora security group | `<aurora-sg-id>` |
| Aurora reader endpoint | `<cluster-name>.cluster-ro-xxxxxxxx.<region>.rds.amazonaws.com` |
| Database and read-only user | `<database-name>` / `<read-only-user>` |
| PostgreSQL port | `5432` |

## 1. Plan the network and route domains

1. In the **Databricks Account Console**, open the workspace and record its
   customer-managed VPC, workspace subnets, and security group IDs.
2. In **VPC > Your VPCs**, record every IPv4 and IPv6 CIDR on the Databricks and
   Aurora VPCs.
3. Confirm that none of their CIDRs overlap.
4. In **VPC > Subnets**, open every Databricks workspace subnet and record its
   effective route-table ID from the **Route table** tab.
5. In **RDS > Databases**, open the Aurora cluster and its DB subnet group.
6. Record every DB subnet and the effective route table used by each one.
7. Decide which additional VPCs and on-premises networks may communicate
   through this TGW route domain. Do not place all attachments into one route
   table merely because they use the same Transit Gateway.

Multiple subnets can share one VPC route table. Add one route to each unique
effective route table, not one route per subnet.

## 2. Create dedicated Transit Gateway attachment subnets

For production, create small dedicated private subnets for TGW attachment
network interfaces instead of placing them in Databricks workspace or Aurora
DB subnets.

For each VPC:

1. Choose one unused, non-overlapping CIDR block, commonly `/28`, in every
   availability zone that contains participating workload subnets.
2. Go to **VPC > Subnets > Create subnet**.
3. Select the VPC, availability zone, and planned CIDR.
4. Give it a descriptive name such as `<vpc-name>-tgw-attachment-<az>`.
5. Create a dedicated route table for the attachment subnets or associate them
   with a controlled private route table. The VPC's automatic `local` route is
   sufficient for delivery from the TGW attachment ENI to destinations inside
   the same VPC.
6. Confirm that the network ACL permits the intended database flows and return
   traffic.

Create a TGW attachment subnet in every availability zone where connectivity
must remain available. This prevents a single-AZ attachment design from
becoming the network dependency for a multi-AZ workspace or Aurora cluster.

Dedicated attachment subnets make routing and troubleshooting clearer and
avoid consuming addresses reserved for Databricks cluster nodes or database
resources.

## 3. Create the Transit Gateway

If the organization already has a centrally managed TGW in this Region, use
that TGW and follow its network-team routing process instead of creating
another hub.

To create a new TGW:

1. Go to **VPC > Transit Gateways**.
2. Choose **Create transit gateway**.
3. Enter a descriptive name and description.
4. Keep the default private Amazon-side ASN unless the hybrid network design
   requires a different, non-conflicting BGP ASN.
5. Enable **DNS support**.
6. For a controlled production design, disable **Default route table
   association** and **Default route table propagation**. The guide creates
   explicit associations and propagations later.
7. Configure **Auto accept shared attachments** according to the organization's
   cross-account approval policy. Manual acceptance is safer when attachment
   requests require review.
8. Configure VPN ECMP and multicast only if the wider architecture requires
   them; they are not needed for this database path.
9. Create the Transit Gateway and wait until its state is **Available**.
10. Record the `tgw-...` ID.

Disabling default association and propagation avoids accidentally connecting a
new VPC to every existing spoke. If the organization intentionally uses the
default TGW route table, verify its routes and isolation policy before attaching
the VPCs.

## 4. Share the Transit Gateway when accounts differ

Skip this section when the TGW and both VPCs are owned by the same AWS account.

1. In the TGW owner's account, go to **AWS Resource Access Manager > Resource
   shares**.
2. Create a resource share containing the Transit Gateway.
3. Add the participating AWS accounts or organization units as principals.
4. In each consumer account, accept the resource share if organization sharing
   does not accept it automatically.
5. Confirm the shared TGW is visible when creating a VPC attachment.

Resource sharing permits an account to request an attachment. It does not
automatically add TGW routes, VPC routes, or security-group rules.

## 5. Create the Databricks VPC attachment

1. Go to **VPC > Transit Gateway attachments**.
2. Choose **Create transit gateway attachment**.
3. Enter a name such as `databricks-classic-vpc-attachment`.
4. Select the `tgw-...` Transit Gateway.
5. Choose **VPC** as the attachment type.
6. Select the Databricks workspace VPC.
7. Enable DNS support.
8. Under **Subnet IDs**, select one dedicated TGW attachment subnet in every
   required availability zone. Select the attachment subnets, not every
   Databricks workspace subnet.
9. Create the attachment.
10. If it is cross-account and acceptance is required, approve it in the TGW
    owner account.
11. Wait until the attachment is **Available** and record its
    `tgw-attach-...` ID.

## 6. Create the Aurora VPC attachment

Repeat the attachment procedure for the Aurora VPC:

1. Name it `aurora-postgres-vpc-attachment`.
2. Select the same Transit Gateway.
3. Choose **VPC** as the attachment type.
4. Select the Aurora VPC.
5. Enable DNS support.
6. Select one dedicated TGW attachment subnet in every availability zone used
   by the Aurora DB subnet group.
7. Create and, if necessary, accept the attachment.
8. Wait until it is **Available** and record its `tgw-attach-...` ID.

Do not select only the availability zone that currently hosts the reader.
Aurora can replace or fail over instances into another DB subnet.

## 7. Configure the Transit Gateway route table

1. Go to **VPC > Transit Gateway route tables**.
2. Choose **Create transit gateway route table**.
3. Name it something descriptive, such as
   `databricks-database-production-routes`.
4. Select the Transit Gateway and create the route table.
5. Open **Associations > Create association** and associate both:
   - The Databricks VPC attachment.
   - The Aurora VPC attachment.
6. Open **Propagations > Create propagation** and enable propagation for both
   VPC attachments.
7. Open **Routes** and verify that the table contains:
   - The Databricks VPC CIDR pointing to the Databricks attachment.
   - The Aurora VPC CIDR pointing to the Aurora attachment.

VPC attachment propagation normally creates these CIDR routes dynamically. If
the organization's policy disables propagation, create equivalent static TGW
routes manually:

```text
<classic-vpc-cidr> -> <databricks-tgw-attachment>
<aurora-vpc-cidr>  -> <aurora-tgw-attachment>
```

Do not add `0.0.0.0/0` to a spoke attachment unless the architecture
intentionally provides inspected centralized egress. For stronger isolation,
use separate TGW route tables and explicit routes so unrelated spoke VPCs
cannot reach the database VPC.

## 8. Add the Databricks-to-Aurora VPC routes

For every unique route table associated with a Databricks workspace subnet:

1. Go to **VPC > Route tables** and select the route table.
2. Open **Routes > Edit routes**.
3. Add:
   - Destination: the Aurora VPC CIDR.
   - Target: **Transit Gateway**.
   - Transit Gateway: the `tgw-...` created or provided earlier.
4. Save the route.

This tells classic cluster nodes to send Aurora-bound traffic to the TGW. Do
not replace the existing `local`, NAT, S3 endpoint, or Databricks control-plane
routes.

## 9. Add the Aurora-to-Databricks return routes

For every unique route table associated with an Aurora DB subnet:

1. Go to **VPC > Route tables** and select the route table.
2. Open **Routes > Edit routes**.
3. Add:
   - Destination: the Databricks VPC CIDR.
   - Target: **Transit Gateway**.
   - Transit Gateway: the same `tgw-...`.
4. Save the route.

This is the response path from Aurora to the cluster nodes. Configure every DB
subnet route table so a failover into another availability zone does not lose
connectivity.

## 10. Configure security groups

### Aurora security group

1. Go to **EC2 > Security Groups** and open the security group attached to the
   Aurora cluster.
2. Add an inbound rule:
   - Type: **PostgreSQL**.
   - Protocol: **TCP**.
   - Port: `5432`.
   - Source: the Databricks workspace private-subnet CIDRs or, when operationally
     necessary, the Databricks VPC CIDR.
3. Do not allow `0.0.0.0/0`.

Using only the workspace private-subnet CIDRs is narrower than allowing the
whole Databricks VPC. Transit Gateway security-group referencing has feature,
Region, and rule-direction considerations; CIDR-based rules are explicit and
widely applicable for this design.

### Databricks compute security group

If outbound traffic is restricted, add an outbound rule:

- Protocol: **TCP**.
- Port: `5432`.
- Destination: the Aurora VPC CIDR or the Aurora DB subnet CIDRs.

Security groups are stateful, so a successful outbound connection permits its
return traffic. Do not add an inbound `5432` rule to the Databricks compute
security group for this client-initiated flow.

If the source is RDS SQL Server rather than Aurora PostgreSQL, use the SQL
Server security group and TCP port `1433` in these rules and use the SQL Server
private endpoint in the validation step.

## 11. Check network ACLs

The default network ACL normally permits this traffic. If either VPC uses a
custom network ACL, verify that it permits:

- Client traffic from Databricks to Aurora TCP `5432`.
- Return traffic on the applicable ephemeral port range.
- The corresponding rules in both directions because network ACLs are
  stateless.

Check the ACLs associated with workspace subnets, TGW attachment subnets, and
Aurora DB subnets. Keep the rules no broader than the organization's approved
CIDRs and ports.

## 12. Confirm DNS behavior

1. In **VPC > Your VPCs**, select each VPC and choose **Actions > Edit VPC
   settings**.
2. Confirm **DNS resolution** and **DNS hostnames** are enabled in both VPCs.
3. Confirm DNS support is enabled on the Transit Gateway and both attachments.
4. Continue using the Aurora reader endpoint containing `cluster-ro`; do not
   replace it with a fixed IP address.

The native Aurora endpoint normally resolves to private addresses usable over
the routed connection. Transit Gateway does not automatically make private
hosted zones from one VPC resolvable in another. If the design uses custom
private DNS names, associate the Route 53 private hosted zone with both VPCs or
deploy Route 53 Resolver endpoints and forwarding rules as appropriate.

## 13. Validate from a Databricks classic cluster

Run the checks from a classic cluster attached to the customer-managed VPC, not
from serverless compute.

First, test DNS and TCP connectivity:

```python
import socket

host = "<aurora-reader-endpoint>"
port = 5432

print(socket.gethostbyname_ex(host))
with socket.create_connection((host, port), timeout=10):
    print("Aurora is reachable through the Transit Gateway")
```

Then connect with a database user restricted to `SELECT` and validate that the
endpoint reaches a reader:

```sql
SELECT
  current_database(),
  current_user,
  inet_server_addr(),
  pg_is_in_recovery();
```

For a read-only connection, `pg_is_in_recovery()` should return `true`. Also
confirm that write attempts fail for the database user. Network routing alone
does not make the connection read-only; database privileges enforce that.

## Production validation checklist

- Both TGW VPC attachments are **Available**.
- Each attachment is associated with the intended TGW route table.
- The TGW route table has active routes for both VPC CIDRs to the correct
  attachments.
- Every Databricks workspace-subnet route table has the Aurora CIDR route to
  the TGW.
- Every Aurora DB-subnet route table has the Databricks CIDR route to the TGW.
- No unintended spoke VPC has a TGW route into the database route domain.
- Aurora is not publicly accessible.
- Aurora permits TCP `5432` only from approved Databricks source CIDRs.
- The application uses TLS and a `SELECT`-only database identity.
- VPC Flow Logs and Transit Gateway Flow Logs are enabled and sent to an
  approved CloudWatch Logs or S3 destination.
- AWS Network Manager or the organization's monitoring platform alerts on
  attachment, route, and packet-drop problems.
- Cost allocation tags identify the owner and purpose of the TGW and
  attachments.

## Troubleshooting

### TCP connection times out

Check the route in this order:

1. The effective Databricks workspace-subnet route table contains the Aurora
   CIDR targeting the TGW.
2. The TGW route table associated with the Databricks attachment contains the
   Aurora CIDR targeting the Aurora attachment.
3. The Aurora DB-subnet route table contains the Databricks CIDR targeting the
   TGW.
4. The TGW route table associated with the Aurora attachment contains the
   Databricks CIDR targeting the Databricks attachment.
5. The compute security-group egress and Aurora security-group ingress permit
   TCP `5432`.
6. Custom network ACLs permit the connection and ephemeral return ports.

Use VPC Flow Logs and Transit Gateway Flow Logs to determine where packets are
accepted or rejected. A timeout usually indicates routing, security-group, or
network-ACL filtering rather than an incorrect database password.

### DNS resolves but the TCP test times out

DNS success only proves that the endpoint name resolved. It does not prove the
VPC and TGW route tables or security rules are correct. Confirm the resolved IP
belongs to the Aurora VPC CIDR, then follow the four route checks above.

### Authentication fails immediately

An immediate PostgreSQL authentication error normally means the network path is
working. Check the database name, username, password, TLS options, and for
accidental leading or trailing whitespace.

### One availability zone works but another fails

- Confirm both VPC attachments include a TGW attachment subnet in every
  required availability zone.
- Confirm every workspace and DB subnet uses a route table containing the TGW
  route.
- Confirm all relevant network ACLs and security groups permit the flow.

## Removing the connection

To remove this path without disrupting other TGW users:

1. Remove the Aurora CIDR route from the Databricks workspace-subnet route
   tables.
2. Remove the Databricks CIDR route from the Aurora DB-subnet route tables.
3. Remove the two attachment propagations or static routes from the dedicated
   TGW route table.
4. Disassociate and delete the two VPC attachments only if no other approved
   connectivity uses them.
5. Delete the dedicated TGW route table when it is empty and unused.
6. Delete the Transit Gateway only if no other VPC, VPN, Direct Connect, or
   peering attachment depends on it.
7. Remove database security-group rules that are no longer required.

Never delete a shared production Transit Gateway merely to remove one database
connection.
