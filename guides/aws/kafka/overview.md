# Manually connect Databricks compute to a private Kafka broker on AWS

This guide explains how to reach a self-managed Apache Kafka broker in a
private VPC from Databricks classic and serverless compute. Kafka needs more
care than a database, because a client connects twice and the second address
comes from the broker.

It covers the network path and the broker's listener settings. It assumes a
broker on an EC2 instance with no public IP, in a VPC you control.

## Why Kafka is different

A Kafka client connects in two steps:

1. It contacts the **bootstrap address** you configure and asks for cluster
   metadata.
2. The broker answers with its **advertised listener** address. The client
   drops the first connection and connects to that address for all data.

So the network path is not enough. The address the broker advertises must be
one the client can reach over that path. A broker that advertises its private
IP works over peering but not over PrivateLink, where the client can only
reach the endpoint.

The fix is one listener for each path, each on its own port and each
advertising the right address:

| Path | Listener port | Address the broker advertises |
| --- | --- | --- |
| Classic compute over VPC peering | `9092` | The broker's private IP |
| Classic or serverless compute over PrivateLink | `9094` | The Network Load Balancer's DNS name |

Example broker settings, with `SASL_PLAINTEXT` on both listeners:

```text
listeners=INTERNAL://:9092,PRIVATELINK://:9094
advertised.listeners=INTERNAL://<broker-private-ip>:9092,PRIVATELINK://<nlb-dns-name>:9094
listener.security.protocol.map=INTERNAL:SASL_PLAINTEXT,PRIVATELINK:SASL_PLAINTEXT
```

A client receives the advertised address of the listener it connected to, so
each path stays on its own port from start to finish.

With several brokers, PrivateLink needs a way to reach each one separately:
one load balancer listener port for each broker, or one load balancer for each
broker. A managed service such as Amazon MSK handles this with its own
multi-VPC connectivity.

## Requirements

- A workspace with classic compute in a VPC you manage, serverless compute, or
  both.
- A Kafka broker in a private subnet, and permission to change its listener
  settings and restart it.
- For serverless compute: Databricks account admin, to manage the NCC.
- Permission to create load balancers, endpoint services, and endpoints, and
  to edit route tables and security groups.

## Path A: classic compute over VPC peering

1. Peer the workspace VPC with the Kafka VPC and add routes in both
   directions. The steps are the same as in
   [VPC peering](../classic/aurora-postgres/vpc-peering.md).
2. On the broker's security group, allow inbound TCP `9092` from the workspace
   private subnets.
3. Make sure the `INTERNAL` listener advertises the broker's private IP.
4. Use `<broker-private-ip>:9092` as the bootstrap address.

## Path B: PrivateLink for classic and serverless compute

Both compute types can share one load balancer and one endpoint service.

### 1. Create the load balancer

1. Create a target group: type **IP addresses**, protocol **TCP**, port
   `9094`, in the Kafka VPC. Register the broker's private IP.
2. Create an internal **Network Load Balancer** in the broker's subnets, with
   a **TCP** listener on `9094` that forwards to the target group.
3. Give the load balancer a security group, and allow inbound TCP `9094` on
   the broker's security group from that group.
4. Copy the load balancer's DNS name.

### 2. Advertise the load balancer name

Set the `PRIVATELINK` listener to advertise `<nlb-dns-name>:9094` and restart
the broker. Wait until the target group shows the broker as healthy.

### 3. Publish the endpoint service

1. Open **VPC > Endpoint services** and select **Create endpoint service**.
2. Select the load balancer and keep **Acceptance required** enabled.
3. Copy the service name (`com.amazonaws.vpce.<region>.vpce-svc-...`).

### 4. Connect classic compute

1. Open **VPC > Endpoints**, select **Create endpoint**, and choose
   **Endpoint services that use NLBs and GWLBs**. Enter the service name.
2. Select the workspace VPC and its private subnets, and a security group that
   allows inbound TCP `9094` from the cluster security group.
3. Accept the connection on the endpoint service.
4. Make the advertised name resolve to the endpoint inside the workspace VPC:
   create a Route 53 **private hosted zone** for the load balancer's DNS name,
   associate it with the workspace VPC, and add an **alias** A record that
   points to the interface endpoint.

Step 4 is what makes the second connection work. The broker advertises the
load balancer name, and from the workspace VPC that name must lead to the
endpoint, not to the load balancer's unreachable private addresses.

### 5. Connect serverless compute

1. In the Databricks account console, open **Security > Network connectivity
   configurations** and open or create the NCC for the workspace's region.
2. Add a private endpoint rule with the endpoint service name, and enter the
   load balancer's DNS name as the domain name. Databricks routes that name to
   its endpoint, which covers the advertised address too.
3. Accept the new connection on the endpoint service, after checking that its
   endpoint ID matches the one on the rule.
4. Wait for the rule to show `ESTABLISHED`, and attach the NCC to the
   workspace if it is not attached yet.

The account console steps are the same as in the
[RDS SQL Server guide](../serverless/rds-sql-server/private-link.md).

Use `<nlb-dns-name>:9094` as the bootstrap address from both compute types.

## Test with Structured Streaming

Store the Kafka username and password in a Databricks secret scope, then run
this on the compute type you are testing:

```python
username = dbutils.secrets.get("<scope>", "username")
password = dbutils.secrets.get("<scope>", "password")
jaas = (
    "org.apache.kafka.common.security.plain.PlainLoginModule required "
    f'username="{username}" password="{password}";'
)

events = (
    spark.readStream.format("kafka")
    .option("kafka.bootstrap.servers", "<bootstrap-address>")
    .option("subscribe", "<topic>")
    .option("startingOffsets", "latest")
    .option("kafka.security.protocol", "SASL_PLAINTEXT")
    .option("kafka.sasl.mechanism", "PLAIN")
    .option("kafka.sasl.jaas.config", jaas)
    .load()
    .selectExpr("CAST(value AS STRING) AS value", "timestamp", "partition", "offset")
)

display(events)
```

`SASL_PLAINTEXT` authenticates the client but does not encrypt the traffic.
Use TLS (`SASL_SSL`) for anything beyond a test, with a certificate that
matches the advertised name.

## Troubleshooting

| Symptom | Likely cause and fix |
| --- | --- |
| The stream starts, then times out fetching metadata or data | The bootstrap connection worked, but the advertised address is not reachable on this path. Check which listener the port belongs to and what it advertises. |
| It works over peering but not over PrivateLink | The client used port `9092`, or the `PRIVATELINK` listener advertises the private IP. |
| Classic compute cannot resolve the load balancer name to the endpoint | The private hosted zone is missing, or not associated with the workspace VPC. |
| The NCC rule stays pending | The connection has not been accepted on the endpoint service. |
| The target group shows the broker as unhealthy | The broker is not listening on `9094`, or its security group does not allow the load balancer. |
| Authentication fails | The path works. Check the SASL mechanism and the credentials. |
