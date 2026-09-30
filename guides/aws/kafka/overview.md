# Stream synthetic Kafka events from Databricks

The Kafka feature creates a disposable, single-broker Apache Kafka lab in a
dedicated AWS VPC. It is intended for connectivity and Structured Streaming
exercises, not production workloads.

The broker runs in KRaft combined broker/controller mode on a private EC2
instance. A systemd service continuously sends one synthetic purchase event to
the `demo-events` topic every second by default. Kafka retains the events for 24
hours.

```text
Synthetic producer -> Kafka topic -> Databricks Structured Streaming -> Delta
```

The producer runs on the broker host, so data begins entering Kafka after the
instance finishes bootstrapping. Databricks is a Kafka consumer: it pulls the
events rather than receiving a push from the broker.

## Connectivity

Kafka clients first contact a bootstrap address and then use the broker address
returned in Kafka metadata. This module has distinct advertised listeners so
both paths return an address that the client can actually reach:

| Compute path | Listener | Network path |
| --- | --- | --- |
| Classic `peering` | Broker private IP on `9092` | Workspace VPC peering and routes |
| Classic `private_link` | NLB hostname on `9094` | Workspace interface endpoint and private Route 53 alias |
| Serverless `private_link` | NLB hostname on `9094` | NCC-managed interface endpoint |

The classic and serverless PrivateLink consumers share the same internal NLB
and endpoint service, which requires acceptance. Terraform accepts the classic
endpoint it creates in the same account; the serverless NCC connection must be
reviewed and accepted explicitly.

## Deploy the example

Copy the example into the ignored local environment directory, then let
`./infra` select and verify the AWS and Databricks profiles:

```bash
cp environments/examples/aws/workspace-kafka-streaming.tfvars \
  environments/local/my-kafka.tfvars

./infra setup aws environments/local/my-kafka.tfvars --yes
./infra validate aws
./infra plan aws environments/local/my-kafka.tfvars
# Review and authorize the saved plan before applying it.
./infra apply aws environments/local/my-kafka.tfvars
```

The example uses classic VPC peering and serverless PrivateLink. After apply,
inspect the output and approve the expected serverless endpoint connection:

```bash
./infra output aws environments/local/my-kafka.tfvars
./infra endpoints aws status environments/local/my-kafka.tfvars
```

Endpoint acceptance is an external state change. Follow the reviewed-ID
workflow in the [AWS connectivity guide](../connectivity.md).

## Credentials

The generated SASL/PLAIN username and password are stored in AWS Secrets
Manager. Terraform outputs only the secret ARN. Copy the two values into a
Databricks secret scope as keys named `username` and `password`; do not place
them directly in a notebook or commit them to Git.

SASL/PLAIN authenticates the lab client but does not encrypt Kafka payloads.
The traffic remains on the selected private network path. Production designs
should use TLS (`SASL_SSL`) and a multi-broker managed service such as Amazon
MSK.

## Stream from Databricks

Import `modules/aws/kafka/notebooks/stream_from_kafka.py` into the workspace.
Set its `bootstrap_servers` widget from the matching `connectivity.kafka`
output:

- classic peering: `<classic.host>:9092`;
- classic PrivateLink: `<classic.host>:9094`;
- serverless PrivateLink: `<serverless.host>:9094`.

The notebook reads the live events with Spark Structured Streaming. To persist
them, replace its final `display(events)` with a checkpointed Delta sink:

```python
(
    events.writeStream
    .option("checkpointLocation", "/Volumes/main/default/checkpoints/kafka")
    .toTable("main.default.kafka_events")
)
```

Use a different checkpoint for each independent consumer.

## Operational notes

- The EC2 instance has no public IP and is managed through Systems Manager.
- A NAT gateway is used for Docker image installation and is billable.
- This is a single point of failure with replication factor `1`.
- The synthetic producer restarts automatically with systemd.
- Destroy the lab when finished to stop EC2, NAT gateway, and NLB charges.
