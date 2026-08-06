# Manually connect Databricks serverless to private RabbitMQ on AWS

This guide uses the AWS and Databricks account console UIs. It creates a
self-managed RabbitMQ server on a private EC2 instance and connects Databricks
serverless to it through AWS PrivateLink.

## Architecture and concepts

```text
Databricks serverless compute
        |
        | Databricks-managed interface endpoint
        v
AWS VPC endpoint service
        |
        v
Internal Network Load Balancer:5672
        |
        v
Private EC2 RabbitMQ server:5672
```

- **RabbitMQ** is a message broker. Producers publish messages and consumers
  read them from queues.
- **NLB** means Network Load Balancer. It provides a stable network front end
  and forwards TCP traffic to the RabbitMQ server.
- **VPC endpoint service** publishes the NLB as an AWS PrivateLink service.
- **Private endpoint** is the interface endpoint Databricks creates inside its
  managed serverless network. It is not created in the RabbitMQ VPC.
- **NCC** means Network Connectivity Configuration. It maps the connection
  hostname to the endpoint service and attaches that route to workspaces.

This learning setup uses AMQP on port 5672 over the private PrivateLink path.
PrivateLink does not replace application-layer TLS. For production, enable
RabbitMQ TLS on 5671 with a certificate for a customer-owned DNS name, then use
that FQDN in the NCC rule and client.

## Prerequisites

- A Databricks Enterprise workspace with serverless compute.
- Databricks account-admin permission.
- AWS permissions for VPC, EC2, IAM, Secrets Manager, NLB, and endpoint
  services.
- The AWS resources and workspace in the same region.
- A VPC CIDR that does not overlap other networks you intend to connect.

## 1. Create the VPC and subnets

1. Open **VPC > Your VPCs > Create VPC**.
2. Create a VPC, for example `rabbitmq-vpc`, with an IPv4 CIDR such as
   `10.47.0.0/16`.
3. Enable **DNS resolution** and **DNS hostnames**.
4. Create two private subnets in different availability zones for the NLB.
5. Create one public subnet for a NAT gateway.
6. Create and attach an internet gateway to the VPC.
7. Create a public route table with `0.0.0.0/0` targeting the internet
   gateway, and associate the public subnet.
8. Allocate an Elastic IP and create a NAT gateway in the public subnet.
9. Create a private route table with `0.0.0.0/0` targeting the NAT gateway.
10. Associate both private subnets with the private route table.

The EC2 server receives no public IP. NAT permits outbound bootstrap downloads
without allowing unsolicited inbound internet traffic.

## 2. Store the RabbitMQ credentials

1. Open **AWS Secrets Manager > Store a new secret**.
2. Choose **Other type of secret**.
3. Add two key/value pairs: `username` and `password`.
4. Use a strong password and a username such as `rabbitadmin`.
5. Name the secret, for example, `rabbitmq/credentials`.
6. Store the secret and record its ARN.

Do not place the password in EC2 user data, resource names, tags, or notebooks.

## 3. Create the EC2 IAM role

1. Open **IAM > Roles > Create role**.
2. Select **AWS service**, then **EC2**.
3. Attach `AmazonSSMManagedInstanceCore` so the private instance can be
   inspected with Session Manager.
4. Create an inline policy that permits
   `secretsmanager:GetSecretValue` only on the secret ARN from step 2.
5. Name the role, for example, `rabbitmq-ec2-role`.

## 4. Create the security groups

Create two security groups in the RabbitMQ VPC:

### RabbitMQ server security group

1. Create `rabbitmq-server-sg`.
2. Do not add SSH or public inbound rules.
3. Allow outbound traffic so the instance can bootstrap through NAT.

### NLB security group

1. Create `rabbitmq-nlb-sg`.
2. Add outbound TCP port `5672` with `rabbitmq-server-sg` as the
   destination.
3. Return to `rabbitmq-server-sg`.
4. Add inbound TCP port `5672` with `rabbitmq-nlb-sg` as the source.

No public inbound CIDR is required.

## 5. Launch the private RabbitMQ EC2 server

1. Open **EC2 > Instances > Launch instances**.
2. Enter a name such as `rabbitmq-server`.
3. Select the latest Amazon Linux 2023 x86_64 AMI.
4. Choose an instance size suitable for the workload. `t3.micro` is enough
   only for a learning environment.
5. Under **Network settings**:
   - Select the RabbitMQ VPC.
   - Select one private subnet.
   - Disable automatic public IP assignment.
   - Select `rabbitmq-server-sg`.
6. Under **Advanced details**, select `rabbitmq-ec2-role` as the IAM instance
   profile.
7. Require IMDSv2.
8. Encrypt the root EBS volume.
9. In **User data**, enter the following script after replacing the
   placeholders:

```bash
#!/bin/bash
set -euo pipefail

AWS_REGION="<aws-region>"
SECRET_ARN="<rabbitmq-secret-arn>"
RABBITMQ_IMAGE="rabbitmq:3.13-management"

dnf install -y docker jq
systemctl enable --now docker

secret_json=$(aws secretsmanager get-secret-value \
  --region "$AWS_REGION" \
  --secret-id "$SECRET_ARN" \
  --query SecretString \
  --output text)
username=$(printf '%s' "$secret_json" | jq -r .username)
password=$(printf '%s' "$secret_json" | jq -r .password)

docker pull "$RABBITMQ_IMAGE"
docker run -d \
  --name rabbitmq \
  --restart unless-stopped \
  -e RABBITMQ_DEFAULT_USER="$username" \
  -e RABBITMQ_DEFAULT_PASS="$password" \
  -p 5672:5672 \
  "$RABBITMQ_IMAGE"

unset secret_json username password
```

10. Launch the instance.
11. Wait for both EC2 status checks to pass.
12. Use **Connect > Session Manager** to confirm
    `docker ps --filter name=rabbitmq` reports a running container.

If Session Manager is unavailable, confirm the private subnet has a working
NAT route and that the role has the SSM managed policy.

## 6. Create the RabbitMQ target group

1. Open **EC2 > Target groups > Create target group**.
2. Choose **Instances** as the target type.
3. Configure:
   - Protocol: TCP
   - Port: `5672`
   - VPC: the RabbitMQ VPC
   - Health check protocol: TCP
   - Health check port: traffic port
4. Choose **Next**.
5. Select the RabbitMQ EC2 instance.
6. Enter port `5672`.
7. Choose **Include as pending below**.
8. Confirm it appears in **Review targets**.
9. Choose **Create target group**.

The target can show **Unused** until a load balancer listener references the
target group. It can become **Healthy** only after the NLB is attached and
RabbitMQ is listening on port 5672.

## 7. Create the internal NLB

1. Open **EC2 > Load balancers > Create load balancer**.
2. Choose **Network Load Balancer**.
3. Set **Scheme** to **Internal** and IP address type to IPv4.
4. Select the RabbitMQ VPC.
5. Select the two private subnets in different availability zones.
6. Select `rabbitmq-nlb-sg`.
7. Add a TCP listener on port `5672`.
8. Forward the listener to the RabbitMQ target group.
9. Create the NLB.
10. Open the target group and wait until the instance is **Healthy**.
11. Record the NLB DNS name. This is the hostname used in the NCC rule and
    notebook.

Do not continue while the target is unhealthy. Check the container state,
port, target registration, and both security-group rules.

## 8. Create the VPC endpoint service

1. Open **VPC > Endpoint services > Create endpoint service**.
2. Select **Network** as the load balancer type.
3. Select the RabbitMQ NLB.
4. Enable **Acceptance required**.
5. Create the service and record its service name:

```text
com.amazonaws.vpce.<region>.vpce-svc-xxxxxxxxxxxxxxxxx
```

6. Open **Allow principals** and add the Databricks serverless stable IAM role:

```text
arn:aws:iam::565502421330:role/private-connectivity-role-<workspace-region>
```

7. Open the associated NLB's **Security** settings.
8. Set **Enforce inbound rules on PrivateLink traffic** to **Off**.

For cross-region PrivateLink, follow the additional availability-zone and
supported-region requirements in the official Databricks documentation.

## 9. Create or reuse the Databricks NCC

A workspace can use only one NCC. Add this rule to the existing NCC if the
workspace already has one.

If no NCC exists:

1. Sign in to the **Databricks account console**.
2. Open **Security > Network connectivity configurations**.
3. Choose **Add network configuration**.
4. Enter a name and select the workspace region.
5. Create the NCC.

## 10. Add the RabbitMQ private endpoint rule

1. Open the NCC used by the workspace.
2. Open **Private endpoint rules**.
3. Choose **Add private endpoint rule**.
4. Enter the full endpoint-service name from step 8.
5. For domain names, enter the exact internal NLB DNS name from step 7.
6. Do not include `amqp://`, `:5672`, a wildcard, or an IP address.
7. Create the rule and copy the generated `vpce-...` endpoint ID.

The client must use this exact NLB FQDN. DNS redirects and DNS chasing are not
supported.

## 11. Accept the Databricks endpoint

1. Return to **VPC > Endpoint services**.
2. Select the RabbitMQ endpoint service.
3. Open **Endpoint connections**.
4. Find the endpoint ID copied from Databricks.
5. Choose **Actions > Accept endpoint connection request**.
6. Confirm acceptance.
7. Return to the Databricks NCC and wait for status **ESTABLISHED**.

## 12. Attach the NCC to the workspace

Skip this step when the workspace already uses this NCC.

1. In the Databricks account console, open **Workspaces**.
2. Select the workspace.
3. Under **Networking**, select the NCC.
4. Save the workspace configuration.

The NCC and workspace must be in the same region.

## 13. Store credentials in Databricks secrets

The test notebook expects scope `rabbitmq` with keys:

```text
username
password
```

Create the scope at:

```text
https://<workspace-host>#secrets/createScope
```

Secret-value entry might require the Databricks CLI or Secrets API. Copy the
two values from AWS Secrets Manager without putting them in a notebook or job
parameter.

## 14. Run the serverless notebook

Import `modules/aws/rabbitmq/notebooks/test_serverless_connectivity.py` and run it on serverless
compute with:

- `host`: the exact internal NLB DNS name
- `port`: `5672`
- `secret_scope`: `rabbitmq`

The notebook confirms DNS resolution, TCP connectivity, RabbitMQ
authentication, and a publish/consume round trip.

## Troubleshooting

- **DNS resolves but TCP times out:** check the endpoint is established, NLB
  target health, listener port, and security groups.
- **Target is Unused:** attach the target group to the NLB listener.
- **Target is unhealthy:** confirm the container is running and listening on
  5672, and confirm the NLB-to-server security-group rules.
- **NCC remains pending:** accept the matching endpoint connection in AWS.
- **Authentication fails:** verify both Databricks secrets match AWS Secrets
  Manager. Networking can be healthy while authentication fails.
- **Container did not start:** inspect `/var/log/cloud-init-output.log` with
  Session Manager and verify NAT, DNS, IAM, and secret access.
- **TLS is required:** configure RabbitMQ on 5671 with a customer-owned FQDN
  and trusted certificate, then update the target group, listener, NCC rule,
  and notebook client together.
