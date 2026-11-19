# Azure guides

Each guide builds one network path by hand in the Azure portal and the
Databricks account console.

## Workspace access

- [Front-end Private Link](front-end-private-link.md): reach the workspace UI
  and API through private endpoints.

## Serverless compute to data sources

- [Azure SQL Database with Private Link](serverless/sql-database/private-link.md)
- [SQL Server on a VM with a private network gateway](manual/serverless-sql-server-vm-private-network-gateway.md)
- [SQL Server on a VM with Private Link and a load balancer](manual/serverless-sql-server-vm-private-link.md)

The [comparison](manual/README.md#which-path-to-choose) explains when to use
the gateway and when to use Private Link.

## Classic compute

Classic compute runs in the workspace VNet. It reaches a source in another
VNet through VNet peering, with the source's private DNS zone linked to the
workspace VNet. The serverless paths in the guides above do not serve
classic compute.

To deploy the same scenarios as labs, see
[Lab scenarios](../operations/lab-scenarios.md#azure).
