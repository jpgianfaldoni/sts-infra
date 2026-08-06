data "databricks_aws_assume_role_policy" "workspace" {
  provider    = databricks.mws
  external_id = var.databricks_account_id
}

resource "aws_iam_role" "cross_account" {
  name               = "${var.resource_prefix}-crossaccount"
  assume_role_policy = data.databricks_aws_assume_role_policy.workspace.json
  tags               = var.tags
}

data "databricks_aws_crossaccount_policy" "workspace" {
  provider    = databricks.mws
  policy_type = "customer"
}

resource "aws_iam_role_policy" "cross_account" {
  name   = "${var.resource_prefix}-crossaccount-policy"
  role   = aws_iam_role.cross_account.id
  policy = data.databricks_aws_crossaccount_policy.workspace.json
}

resource "aws_iam_role_policy" "describe_vpc_attribute" {
  name = "${var.resource_prefix}-describe-vpc-attribute"
  role = aws_iam_role.cross_account.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "ec2:DescribeVpcAttribute"
      Resource = "*"
    }]
  })
}

resource "time_sleep" "iam_propagation" {
  depends_on = [
    aws_iam_role_policy.cross_account,
    aws_iam_role_policy.describe_vpc_attribute,
  ]

  create_duration = "30s"
}
