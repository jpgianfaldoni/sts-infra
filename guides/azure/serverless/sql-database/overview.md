# Azure SQL Database deployment notes

Creates an Azure SQL logical server and database with public access disabled, plus a private endpoint and private DNS zone in a dedicated VNet. The sample `modules/azure/sql-database/assets/seed.sql` is provided for manual initialization from a client that can resolve and route to the private endpoint.

Terraform generates the SQL administrator password. It remains sensitive state, so use an encrypted remote backend with tightly restricted access for shared environments. Retrieve sensitive outputs only in an authorized local terminal.

For Databricks serverless connectivity, follow the [NCC and Private Link tutorial](private-link.md).
