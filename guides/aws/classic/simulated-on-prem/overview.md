# Manually connect classic compute to an on-premises-style network with Transit Gateway

This guide connects Databricks classic compute to a private host in a second
VPC that stands in for an on-premises network. The two VPCs are joined through
an AWS Transit Gateway, the hub you would also use for a real data center.

It covers the network path only, using the AWS Management Console.

## How the path works

```text
Classic Databricks cluster
        |
Workspace private route table
        |
Workspace Transit Gateway attachment
        |
Transit Gateway route table
        |
Second VPC's Transit Gateway attachment
        |
Private host, TCP 8080
```

Traffic is routed, not translated: the host sees the cluster's private IP
address, and both networks need a route to the other.

## What this does and does not simulate

The second VPC attaches to the Transit Gateway directly. A real data center
reaches AWS through a Site-to-Site VPN or Direct Connect, and often exchanges
routes with BGP. The Databricks side of the design is the same in both cases:
the workspace VPC sends the remote range to the Transit Gateway, and security
groups allow the traffic.

| Part | In this exercise | With a real data center |
| --- | --- | --- |
| Workspace VPC attachment and routes | Same | Same |
| Remote network | A VPC attachment | A VPN or Direct Connect attachment |
| Remote routes | Static routes in the VPC | Routes learned through BGP, or static |
| Firewall | Security group on the host | On-premises firewall rules |

## Requirements

- A workspace with classic compute in a VPC you manage.
- A second VPC, in the same region, whose address range does not overlap the
  workspace VPC.
- A host in a private subnet of the second VPC that answers on a TCP port.
  This guide uses an HTTP service on `8080`.
- Permission to create Transit Gateway resources and edit route tables and
  security groups in both VPCs.

## Values to collect

| Value | Where to find it | Example |
| --- | --- | --- |
| Workspace VPC ID and CIDR | **VPC > Your VPCs** | `10.10.0.0/16` |
| Workspace private subnets and their route tables | **VPC > Subnets** | Two subnets, one per zone |
| Cluster security group | Workspace network configuration | `sg-...` |
| Second VPC ID and CIDR | **VPC > Your VPCs** | `10.60.0.0/16` |
| Host private IP, subnet, and security group | **EC2 > Instances** | `10.60.0.10` |

## 1. Create attachment subnets

In each VPC, create one small subnet (`/28`) in each Availability Zone you
use, dedicated to the Transit Gateway attachment. Give these subnets a route
table with only the local route. Keeping attachments in their own subnets
stops other route changes from affecting them.

## 2. Create the Transit Gateway

1. Open **VPC > Transit gateways** and select **Create transit gateway**.
2. Enter a name. Keep **DNS support** enabled.
3. Keep **Default route table association** and **Default route table
   propagation** enabled for this two-VPC exercise.
4. Select **Create transit gateway** and wait for the state **Available**.

## 3. Attach both VPCs

For each VPC:

1. Open **VPC > Transit gateway attachments** and select **Create transit
   gateway attachment**.
2. Select the Transit Gateway and the attachment type **VPC**.
3. Select the VPC and its attachment subnets, one per Availability Zone.
4. Select **Create** and wait for the state **Available**.

With default propagation, the Transit Gateway route table now holds a route to
each VPC's CIDR. Check it under **Transit gateway route tables > Routes**.

## 4. Add the VPC routes

The Transit Gateway knows both networks; the VPCs do not know each other yet.

1. In the route table of each workspace private subnet, add a route:
   destination the second VPC's CIDR, target the Transit Gateway.
2. In the route table of the host's subnet, add the return route: destination
   the workspace VPC's CIDR, target the Transit Gateway.

A missing return route is the most common cause of a timeout.

## 5. Allow the traffic

1. On the host's security group, add an inbound rule: TCP `8080`, source the
   CIDR ranges of the workspace private subnets. Use CIDR ranges unless
   security group referencing is enabled on the Transit Gateway.
2. If the cluster security group restricts outbound traffic, add an outbound
   rule: TCP `8080`, destination the second VPC's CIDR.
3. Check that the network ACLs of the subnets on both sides allow the port and
   the ephemeral return ports.

## 6. Test from a classic cluster

Attach a Python notebook to a classic cluster and run:

```python
import urllib.request

url = "http://<host-private-ip>:8080/health"

with urllib.request.urlopen(url, timeout=10) as response:
    print(response.status, response.read()[:200])
```

A response proves the route, the return route, and the security rules. A
timeout means one of them is missing.

For the click-by-click version of each step, with a database as the target,
see [Transit Gateway](../aurora-postgres/transit-gateway.md).

## Serverless compute

Serverless compute does not run in the workspace VPC, so this path does not
serve it. Publish the host through a Network Load Balancer and an endpoint
service, and add it to an NCC, as in the
[serverless PrivateLink guides](../../serverless/README.md).

## Remove the path

Delete the routes in both VPCs, then the security group rules, then the two
attachments, and finally the Transit Gateway. Transit Gateways and their
attachments are billed by the hour while they exist.

## Troubleshooting

| Symptom | Likely cause and fix |
| --- | --- |
| The attachment cannot be created | The subnets are in an Availability Zone the Transit Gateway does not cover, or the VPCs overlap. |
| The connection times out | A route is missing on one side, or the host's security group does not allow the workspace subnet ranges. Check the return route first. |
| One Availability Zone works and another fails | The attachment has no subnet in the failing zone, or that zone's route table lacks the route. |
| The connection is refused | The path works; the service is not listening on the port. |
