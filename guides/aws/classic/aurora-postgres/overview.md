# Aurora PostgreSQL deployment notes

Creates an encrypted Aurora PostgreSQL cluster with one writer and at least one reader. Optional features are independent:

- `enable_proxy` adds RDS Proxy and a read-only proxy endpoint. The proxy uses Aurora subnet IPs; it is not a separate VPC.
- `enable_classic_private_link` or `enable_serverless_private_link` adds an NLB endpoint service and a scheduled Lambda that synchronizes current Aurora reader IPs into the target group.
- Composition-level `peering` connects classic-compute route tables and security groups directly to the selected Aurora or proxy security group.

Use `modules/aws/aurora-postgres/notebooks/test_classic_connectivity.py` with either the Aurora reader endpoint or the proxy read-only endpoint. The notebook verifies DNS, TCP, authentication, and read-replica routing.
