# Simulated on-premises network

This lab creates a private AWS VPC that represents an on-premises network. A
small EC2 instance runs an HTTP health service, while Systems Manager interface
endpoints provide administrative access without SSH, a public IP, NAT, or an
internet gateway.

The connected option uses AWS Transit Gateway:

```text
Classic Databricks cluster
        |
Workspace private route table
        |
Workspace TGW attachment
        |
Transit Gateway route table
        |
Simulated-on-prem TGW attachment
        |
Private EC2 host :8080
```

This accurately demonstrates hub-and-spoke routing and security controls. It is
not a full physical on-premises simulation because the second VPC attaches
directly to the TGW; a production data center would normally reach AWS through
Site-to-Site VPN or Direct Connect and might exchange routes with BGP.

## Deployment options

Copy one of these templates into `environments/local`:

- `workspace-simulated-on-prem-disconnected.tfvars` deploys both VPCs without a
  network path between them.
- `workspace-simulated-on-prem-transit-gateway.tfvars` creates the TGW, two VPC
  attachments, routes, and TCP `8080` security-group rules.

The essential configuration is:

```hcl
features = {
  workspace         = true
  simulated_on_prem = true
}

connectivity = {
  simulated_on_prem = {
    classic = "transit_gateway" # or "none"
  }
}
```

Use the guarded deployment workflow:

```bash
./infra validate aws
./infra plan aws environments/local/my-hybrid-lab.tfvars
./infra apply aws environments/local/my-hybrid-lab.tfvars
```

Review the saved plan and explicitly authorize apply before the final command.

## Verify the private host

Inspect the output without printing credentials:

```bash
./infra output aws environments/local/my-hybrid-lab.tfvars
```

Use the reported instance ID to open an SSM session:

```bash
aws ssm start-session \
  --target i-0123456789abcdef0 \
  --region us-west-2 \
  --profile your-aws-profile
```

Inside the host, verify the service with:

```bash
curl http://127.0.0.1:8080/health
```

## Verify from classic Databricks compute

Attach a Python notebook to a classic cluster and use the `service_url` from
`connectivity.simulated_on_prem.classic`:

```python
import json
import urllib.request

url = "http://10.60.0.10:8080/health"  # Replace with the Terraform output.

with urllib.request.urlopen(url, timeout=10) as response:
    assert response.status == 200
    payload = json.load(response)

assert payload["status"] == "ok"
assert payload["network"] == "simulated-on-prem"
print(payload)
```

The disconnected configuration should time out because it has no TGW, routes,
or cross-VPC security-group rules. Serverless compute cannot use this path
because it does not run in the workspace VPC; use NCC and PrivateLink for
serverless connectivity.

## Cost notes

The lab creates one EC2 instance, three interface endpoints, one Transit Gateway
and two TGW VPC attachments when connected. All can incur hourly charges. The
dedicated `/28` attachment subnets contain only TGW network interfaces and have
local-only route tables.
