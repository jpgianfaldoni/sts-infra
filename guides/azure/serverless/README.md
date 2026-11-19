# Azure serverless compute guides

Serverless compute runs in a Databricks-managed network and needs a Network
Connectivity Configuration (NCC) to reach private resources.

## Azure SQL Database

- [Private Link](sql-database/private-link.md): a private endpoint rule
  straight to the SQL logical server.

## SQL Server on a VM

- [Private network gateway](../manual/serverless-sql-server-vm-private-network-gateway.md)
- [Private Link and a load balancer](../manual/serverless-sql-server-vm-private-link.md)
- [Which path to choose](../manual/README.md#which-path-to-choose)
