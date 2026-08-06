# RDS PostgreSQL

Creates encrypted, private RDS PostgreSQL in a dedicated VPC. RDS manages the master password in AWS Secrets Manager. The composition root can add VPC peering for classic compute or an NLB endpoint service plus NCC for serverless.

The PrivateLink target is the current RDS ENI IP. Automate target synchronization for production because maintenance, failover, or replacement can change it.
