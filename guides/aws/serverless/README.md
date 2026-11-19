# AWS serverless compute guides

Serverless compute runs in a Databricks-managed network. Each guide publishes
a private service through a Network Load Balancer and an endpoint service, and
connects it with a Network Connectivity Configuration (NCC).

- [RDS SQL Server](rds-sql-server/private-link.md). The guide also explains
  how to adapt the path for RDS PostgreSQL on TCP `5432`.
- [RabbitMQ on EC2](rabbitmq/private-link.md)
- [Kafka](../kafka/overview.md)
