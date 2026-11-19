# Azure manual networking guides

These guides build a network path by hand in the Azure portal and the
Databricks account console, with REST API calls only where the consoles offer
no equivalent.

Both guides connect Azure Databricks serverless compute to SQL Server on an
Azure VM. They cover networking only, not database setup or CDC.

| Guide | Path |
| --- | --- |
| [Private network gateway](serverless-sql-server-vm-private-network-gateway.md) | NCC and a private network gateway in a delegated subnet of your VNet |
| [Private Link](serverless-sql-server-vm-private-link.md) | NCC private endpoint rule, Private Link service, and internal load balancer |

## Which path to choose

| | Private network gateway | Private Link |
| --- | --- | --- |
| Azure resources to build | One delegated subnet | Load balancer, NAT subnet, Private Link service |
| Each new server needs | One more destination name | Another load balancer rule or service, and another rule |
| Reaches peered and on-premises networks | Yes, anything the subnet routes to | Only what sits behind the load balancer |
| Approval step in Azure | None | Approve the private endpoint |
| Status | Public Preview | Generally available |

To practice against a lab VM, deploy a SQL Server VM with no serverless path,
or with `private_network_gateway.manual = true`, as described in
[Lab scenarios](../../operations/lab-scenarios.md#build-the-gateway-yourself).
