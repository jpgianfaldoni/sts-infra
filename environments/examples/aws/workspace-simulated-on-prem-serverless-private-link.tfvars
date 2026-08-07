databricks_account_id = "00000000-0000-0000-0000-000000000000"
name_prefix           = "acme-hybrid-lab"
workspace_name        = "acme-hybrid-lab-classic"

features = {
  workspace         = true
  unity_catalog     = false
  simulated_on_prem = true
}

# Serverless compute reaches the private on-premises host through PrivateLink and
# an NCC private endpoint. An internal NLB and VPC endpoint service front the
# host; Terraform attaches the endpoint service to the workspace through the
# Network Connectivity Configuration. Classic Transit Gateway can be enabled at
# the same time by also setting classic = "transit_gateway".
connectivity = {
  simulated_on_prem = {
    serverless = "private_link"
  }
}

# Defaults are shown explicitly so the VPC and subnet boundaries are easy to
# adapt when this lab is combined with other networks.
simulated_on_prem = {
  vpc_cidr             = "10.60.0.0/16"
  workload_subnet_cidr = "10.60.0.0/24"
  instance_type        = "t3.micro"
  service_port         = 8080
}

# Disposable environments only. This empties versioned workspace buckets during
# destroy and avoids leaving billable resources behind after a lab.
allow_destructive_demo_cleanup = true

tags = {
  ManagedBy   = "terraform"
  Environment = "demo"
  Owner       = "platform-team"
}
