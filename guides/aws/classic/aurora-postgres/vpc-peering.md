# Connect Databricks classic compute to Aurora PostgreSQL with VPC peering

This guide shows how to connect Databricks classic clusters in one VPC directly
to a private Amazon Aurora PostgreSQL cluster in another VPC by using the AWS
Console. Aurora remains private, and applications continue using the normal
Aurora DNS endpoint.

This design is for **Databricks classic compute** in a customer-managed VPC. It
does not use a Databricks Network Connectivity Configuration (NCC), which
controls serverless compute networking.

## What VPC peering means

A **VPC peering connection** is a private, point-to-point network relationship
between two VPCs. After both VPC route tables and security controls are updated,
resources in one VPC can address private IPs in the other VPC as though they
were part of connected networks.

VPC peering:

- Uses private AWS networking and requires no public database endpoint.
- Exchanges routes for the CIDRs you explicitly add.
- Does not insert a load balancer, proxy, NAT device, or encryption appliance.
- Is not transitive. If VPC A peers with VPC B and VPC B peers with VPC C, VPC
  A cannot reach VPC C through VPC B.
- Does not support overlapping IPv4 or IPv6 CIDRs.
- Does not allow one VPC to use the peer's internet gateway, NAT Gateway, VPN,
  Direct Connect gateway, or another peering connection as a transit path.

Security groups and network ACLs still apply. A route makes a destination
reachable; it does not grant permission to connect.

## Traffic path

```text
Databricks classic cluster private IP, ephemeral source port
  -> route table in the classic workspace subnet
  -> VPC peering connection
  -> route table in the Aurora DB subnet
  -> Aurora security group, TCP 5432
  -> Aurora PostgreSQL private IP
```

The return path uses the same peering connection in reverse. Both sides need a
route; VPC peering does not add routes automatically.

## When peering is a good choice

Peering is usually simpler than an NLB and PrivateLink when:

- The two VPC CIDRs do not overlap.
- The VPC owners accept bidirectional network reachability governed by routes,
  security groups, and network ACLs.
- Only a small number of VPCs must be connected.
- Applications should use the Aurora writer or reader DNS endpoint directly.

Using the Aurora endpoint directly is operationally important: Aurora updates
its DNS when instances fail over or are replaced, so there is no NLB IP target
to synchronize.

PrivateLink can provide narrower, service-only exposure when the VPCs should
not exchange routes. For that design, see
[PrivateLink guide](private-link.md).

For many VPCs or a hub-and-spoke network, evaluate AWS Transit Gateway instead
of creating a large mesh of individual peerings. See
[Transit Gateway guide](transit-gateway.md).

## Assumptions and prerequisites

- The Databricks workspace uses a customer-managed VPC that is visible in your
  AWS account.
- The classic-compute and Aurora VPC CIDRs do not overlap.
- Aurora PostgreSQL listens on TCP `5432`, is **Available**, and has **Publicly
  accessible** disabled.
- You can create and accept a VPC peering connection and edit route tables,
  security groups, VPC DNS settings, and network ACLs in both VPCs.
- For cross-account peering, an administrator in the peer account can accept
  the request and configure the peer-side routes and security rules.
- This procedure assumes the VPCs are in the same Region. Inter-Region peering
  is supported by AWS but has different security-group-reference and cost
  considerations.

## Values to collect

| Value | Example placeholder |
|---|---|
| AWS Region | `<aws-region>` |
| Classic-compute VPC ID | `<classic-vpc-id>` |
| Classic-compute VPC CIDR | `<classic-vpc-cidr>` |
| Classic workspace subnet IDs | `<classic-subnet-ids>` |
| Classic cluster security group | `<classic-cluster-sg-id>` |
| Aurora VPC ID | `<aurora-vpc-id>` |
| Aurora VPC CIDR | `<aurora-vpc-cidr>` |
| Aurora DB subnet IDs | `<aurora-db-subnet-ids>` |
| Aurora security group | `<aurora-sg-id>` |
| Aurora writer endpoint | `<cluster-name>.cluster-xxxxxxxx.<region>.rds.amazonaws.com` |
| PostgreSQL port | `5432` |

## 1. Confirm the two VPC networks do not overlap

1. Open the **Databricks Account Console**.
2. Go to **Workspaces**, select the workspace, and record its customer-managed
   VPC, workspace subnet IDs, and security group IDs.
3. In the **AWS Console**, go to **VPC > Your VPCs**.
4. Select the classic-compute VPC and record every IPv4 and IPv6 CIDR.
5. Select the Aurora VPC and record every IPv4 and IPv6 CIDR.
6. Confirm there is no overlap between any address range on either VPC.

AWS does not create a peering connection when the primary CIDRs overlap. Adding
a conflicting secondary CIDR later can also break the intended routing design.

If the Databricks VPC is not visible in your account, it is not a
customer-managed VPC that you can peer directly through this procedure.

## 2. Record all affected subnets and route tables

### Classic-compute side

1. Go to **VPC > Subnets**.
2. Select each subnet configured for the Databricks workspace.
3. Open the **Route table** tab and record the associated route-table ID.
4. Include every subnet in which current or future classic cluster nodes can be
   created.

### Aurora side

1. Go to **RDS > Databases** and select the Aurora cluster.
2. Under **Connectivity & security**, open its DB subnet group.
3. Record every subnet in the DB subnet group. Aurora can fail over into a
   different availability zone, so do not configure only the current writer's
   subnet.
4. In **VPC > Subnets**, open each DB subnet and record its associated route
   table.

Multiple subnets can share a route table. Each unique route table only needs
one route for the peer CIDR.

## 3. Enable VPC DNS support

For both VPCs:

1. Go to **VPC > Your VPCs** and select the VPC.
2. Choose **Actions > Edit VPC settings**.
3. Confirm **Enable DNS resolution** is on.
4. Confirm **Enable DNS hostnames** is on.
5. Save the settings if changed.

These settings allow instances to use Amazon-provided DNS. The Aurora endpoint
should remain the application hostname; do not replace it with a fixed private
IP.

## 4. Create the VPC peering request

1. Go to **VPC > Peering connections**.
2. Choose **Create peering connection**.
3. Enter a descriptive name such as `databricks-to-aurora-postgres`.
4. For **VPC ID (Requester)**, select the classic-compute VPC.
5. Under **Select another VPC to peer with**:
   - Select **My account** or **Another account**.
   - Select **This Region** for this guide.
   - Enter the Aurora VPC ID and peer account ID when required.
6. Create the peering connection.
7. Record the `pcx-...` peering connection ID.

The request initially reports **Pending acceptance**. A peering request expires
if it is not accepted within the AWS acceptance window.

## 5. Accept the peering request

1. Sign in to the AWS account that owns the Aurora VPC.
2. Go to **VPC > Peering connections**.
3. Select the request and verify:
   - Requester account and VPC.
   - Accepter account and VPC.
   - Both CIDR ranges.
4. Choose **Actions > Accept request**.
5. Confirm the connection reaches **Active**.

Never accept a request based only on its display name. Verify the VPC and
account IDs.

## 6. Enable DNS resolution across the peering connection

1. Select the active peering connection.
2. Choose **Actions > Edit DNS settings**.
3. Enable the requester option that allows the peer VPC to resolve DNS names to
   private addresses.
4. Enable the accepter option for the reverse direction.
5. Save the changes.

The labels vary slightly between same-account and cross-account connections.
If each account can edit only its own side, have both account administrators
enable their corresponding DNS-resolution option.

## 7. Add routes from classic compute to Aurora

For every unique route table associated with a Databricks workspace subnet:

1. Go to **VPC > Route tables** and select the route table.
2. Open **Routes > Edit routes**.
3. Add:
   - Destination: the Aurora VPC CIDR.
   - Target: **Peering Connection**.
   - Peering connection: the `pcx-...` connection created above.
4. Save the route.

If the Aurora VPC has multiple non-contiguous CIDRs that contain database
subnets, add the required route for each relevant CIDR.

Do not replace the default route, NAT route, S3 endpoint route, or Databricks
control-plane routes already required by the workspace.

## 8. Add the return routes from Aurora

For every unique route table associated with an Aurora DB subnet:

1. Go to **VPC > Route tables** and select the route table.
2. Open **Routes > Edit routes**.
3. Add:
   - Destination: the classic-compute VPC CIDR.
   - Target: **Peering Connection**.
   - Peering connection: the same `pcx-...` connection.
4. Save the route.

Configure all DB subnet route tables so an Aurora failover to another subnet
does not lose its return path to Databricks.

## 9. Configure security groups

### Aurora security group

1. Go to **EC2 > Security Groups** and open the security group attached to the
   Aurora cluster.
2. Add an inbound rule:
   - Type: **PostgreSQL**.
   - Port: `5432`.
   - Source: the classic cluster security group when same-Region peer security
     group references are supported by the account arrangement.
3. If a peer security-group reference is unavailable, use the narrowest
   classic workspace subnet CIDRs rather than the entire VPC CIDR.
4. Do not use `0.0.0.0/0`.

Security-group referencing does not add a route and does not import the peer's
rules. It only identifies the allowed source interfaces.

### Classic cluster security group

If its outbound traffic is unrestricted, no new outbound rule is necessary. If
egress is restricted:

1. Open the classic cluster security group.
2. Add outbound TCP `5432` to the Aurora security group when a same-Region peer
   reference is supported, or to the Aurora DB subnet CIDRs.

Security groups are stateful, so response traffic for an allowed connection is
automatically permitted.

## 10. Check network ACLs

Default network ACLs usually allow the traffic. If either VPC uses restrictive
custom network ACLs, remember that ACLs are stateless.

For the classic workspace subnets, allow:

- Outbound TCP `5432` to the Aurora DB subnet CIDRs.
- Inbound ephemeral TCP ports, commonly `1024-65535`, from the Aurora DB subnet
  CIDRs for response traffic.

For the Aurora DB subnets, allow:

- Inbound TCP `5432` from the classic workspace subnet CIDRs.
- Outbound ephemeral TCP ports, commonly `1024-65535`, to the classic workspace
  subnet CIDRs.

Use the ephemeral-port range required by the operating systems and organization
policy. Evaluate ACL rules in number order and check both explicit allows and
earlier denies.

## 11. Validate routing in the AWS Console

Optionally use **VPC > Reachability Analyzer** while a classic cluster is
running:

1. Create and analyze a path.
2. Choose the classic cluster ENI as the source.
3. Choose the Aurora writer ENI as the destination.
4. Select TCP port `5432`.
5. Run the analysis.

Reachability Analyzer identifies missing routes, security-group rules, or
network ACL rules. Recreate the analysis after a cluster or Aurora instance is
replaced because the source or destination ENI can change.

## 12. Validate from a Databricks classic cluster

1. In the Databricks workspace UI, create or start a **classic** cluster.
2. Create a notebook and attach it to the cluster.
3. Use the Aurora writer cluster endpoint, not an IP address:

   ```python
   import socket

   host = "<aurora-writer-cluster-endpoint>"
   addresses = sorted({
       item[4][0]
       for item in socket.getaddrinfo(host, 5432, type=socket.SOCK_STREAM)
   })
   print(f"Aurora resolves to private addresses: {addresses}")

   with socket.create_connection((host, 5432), timeout=10):
       print("Aurora PostgreSQL TCP 5432 is reachable through VPC peering")
   ```

4. Confirm the resolved addresses belong to the Aurora VPC CIDRs.
5. Store database credentials in a Databricks secret or use an approved Unity
   Catalog connection. Never place the password directly in the notebook.
6. Run a small authenticated query such as
   `SELECT current_database(), inet_server_addr()` with TLS enabled.

The writer endpoint follows Aurora failover. Read-only applications can instead
use the Aurora reader endpoint.

## Troubleshooting

### Peering cannot be created

- Compare every primary and secondary VPC CIDR for overlap.
- Confirm the accepter VPC and account IDs.
- Confirm the request has not expired.

### Aurora hostname does not resolve as expected

- Enable DNS resolution and DNS hostnames on both VPCs.
- Enable both DNS-resolution options on the peering connection.
- Use the actual Aurora endpoint, not a stale custom record or private IP.

### TCP connection times out

- Confirm the peering connection is **Active**.
- Check the classic subnet route table has an Aurora CIDR route to the peering
  connection.
- Check every Aurora DB subnet route table has the return route.
- Check the Aurora inbound security-group rule and restricted cluster egress.
- Check both subnet network ACLs, including ephemeral return ports.
- Use Reachability Analyzer to locate the first blocking component.

### TCP succeeds but login fails

Networking is working. Check the database name, username, password, TLS trust,
and PostgreSQL permissions separately.

### Connectivity breaks after Aurora failover

- Confirm all DB subnet route tables have the return route.
- Confirm the security rules cover all Aurora DB subnets or use the supported
  peer security-group reference.
- Continue using the Aurora cluster endpoint so DNS can follow the new writer.

## Operational considerations

- VPC peering has no hourly connection charge, but standard regional or
  inter-Region data-transfer charges can apply.
- Route and security changes affect network reachability between the VPCs, not
  only PostgreSQL. Keep routes and security rules as narrow as the design
  permits.
- Monitor peering status and maintain an inventory of every route table that
  depends on it.
- If either VPC CIDR strategy may change, validate future ranges against all
  existing peers before adding them.

## Official references

- [Databricks customer-managed VPC requirements](https://docs.databricks.com/aws/en/security/network/classic/customer-managed-vpc)
- [AWS: Create a VPC peering connection](https://docs.aws.amazon.com/vpc/latest/peering/create-vpc-peering-connection.html)
- [AWS: Update route tables for a VPC peering connection](https://docs.aws.amazon.com/vpc/latest/peering/vpc-peering-routing.html)
- [AWS: Enable DNS resolution for a VPC peering connection](https://docs.aws.amazon.com/vpc/latest/peering/vpc-peering-dns.html)
- [AWS: Security groups and VPC peering](https://docs.aws.amazon.com/vpc/latest/peering/vpc-peering-security-groups.html)
- [AWS: VPC peering limitations](https://docs.aws.amazon.com/vpc/latest/peering/invalid-peering-configurations.html)
- [AWS: Aurora endpoints](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/Aurora.Endpoints.html)
