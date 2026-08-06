# RabbitMQ deployment notes

Creates RabbitMQ on a private EC2 instance. The host has no public IP; a NAT gateway is used only for outbound bootstrap traffic. Generated credentials are stored in AWS Secrets Manager and read by the instance through its IAM role.

With either `enable_classic_private_link` or `enable_serverless_private_link`, the module adds an internal NLB and endpoint service. The composition root creates the matching classic interface endpoint, serverless NCC rule, or both. For production, use AMQPS on 5671 and a customer-owned DNS name whose certificate matches the NCC domain.

See the [NCC and PrivateLink tutorial](private-link.md) for the UI workflow and `modules/aws/rabbitmq/notebooks/test_serverless_connectivity.py` for validation.
