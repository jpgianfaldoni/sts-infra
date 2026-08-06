# STS infrastructure labs

Modular Terraform for Databricks networking demonstrations on AWS and Azure. Each cloud has one composition root; feature flags select only the workspace, databases, messaging, and connectivity needed for a scenario.

The files under `environments/examples` are templates with placeholder values. Do not edit them in place. Choose the example closest to your scenario, copy it into `environments/local`, and replace the placeholders in the copy. The `environments/local` directory is ignored by Git so account IDs, profile names, and other environment-specific settings are not committed.

For example, to configure the AWS workspace with PostgreSQL over VPC peering:

```bash
mkdir -p environments/local
cp environments/examples/aws/workspace-postgres.tfvars environments/local/my-aws.tfvars
```

After editing `environments/local/my-aws.tfvars`, run:

```bash
./infra list
./infra auth aws environments/local/my-aws.tfvars
./infra validate aws
./infra plan aws environments/local/my-aws.tfvars
./infra apply aws environments/local/my-aws.tfvars
```

`apply` accepts only the saved plan produced for the same cloud and tfvars. Destruction requires a saved `destroy-plan` plus typed confirmation. See `components.json` for the machine-readable feature catalog and `AGENTS.md` for agent guardrails.

Documentation starts at the [guides index](guides/README.md). Tutorials are organized by cloud, compute type, and data source; cross-cutting references cover [authentication](guides/operations/authentication.md), the [deployment workflow](guides/operations/deployment.md), and [local Terraform state](guides/operations/state.md).
