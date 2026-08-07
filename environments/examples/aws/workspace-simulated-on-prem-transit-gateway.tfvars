databricks_account_id = "00000000-0000-0000-0000-000000000000"
name_prefix           = "acme-hybrid-lab"
workspace_name        = "acme-hybrid-lab-classic"

features = {
  workspace         = true
  unity_catalog     = false
  simulated_on_prem = true
}

connectivity = {
  simulated_on_prem = {
    classic = "transit_gateway"
  }
}

# Defaults are shown explicitly so the VPC and subnet boundaries are easy to
# adapt when this lab is combined with other networks.
simulated_on_prem = {
  vpc_cidr                    = "10.60.0.0/16"
  workload_subnet_cidr        = "10.60.0.0/24"
  tgw_attachment_subnet_cidrs = ["10.60.1.0/28", "10.60.1.16/28"]
  instance_type               = "t3.micro"
  service_port                = 8080
}

tags = {
  ManagedBy   = "terraform"
  Environment = "demo"
  Owner       = "platform-team"
}
