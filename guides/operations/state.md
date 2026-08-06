# Terraform state

This repository uses Terraform's local state only. It does not configure or support a remote backend.

Terraform stores each cloud's state in its deployment root:

- AWS: `deployments/aws/terraform.tfstate`
- Azure: `deployments/azure/terraform.tfstate`

State files are ignored by Git because they contain resource metadata and may contain sensitive values. Keep them on a trusted machine, do not commit or share them, and back them up securely if the environment must be recoverable.

Each cloud root has a single local state. Do not use different environment files against the same cloud root unless they intentionally describe the same deployed environment.
