# Terraform state

This repository uses local state only. It does not configure a remote backend.

`./infra` isolates state by cloud and deployment ID:

```text
.state/<cloud>/<deployment-id>/terraform.tfstate
```

The default deployment ID is the tfvars filename without `.tfvars`. An
application or automation worker should supply its own stable identifier:

```bash
export INFRA_DEPLOYMENT_ID=<customer-id>-<deployment-id>
```

Each deployment ID is bound to one absolute environment-file path to prevent
two local configurations from accidentally sharing state. Plans, provider
runtime data, and operation locks are isolated under the corresponding
`.artifacts/<cloud>/<deployment-id>` directory.

State and artifact directories are ignored by Git. State can contain resource
metadata and sensitive values: keep it on a trusted machine, do not commit or
share it, and back it up securely when the environment must be recoverable.

## Migrating legacy state

Older repository versions stored one state at
`deployments/<cloud>/terraform.tfstate`. `./infra` will not silently treat that
state as a new deployment because doing so could duplicate expensive resources.
Migrate it explicitly using the exact confirmation printed by `./infra`:

```bash
./infra state-migrate aws environments/local/my-aws.tfvars \
  --confirm migrate-aws-my-aws
```

The command moves the legacy state and its backup; it does not change cloud
resources. Create and review a new saved plan after migration.

## Hosted applications

Per-deployment local state makes the CLI safe for independent local labs, but
it is not sufficient for a multi-worker or multi-customer hosted service. Such
an application should replace this storage layer with encrypted remote state,
locking, access controls, backups, and an audit trail. The Terraform modules
and plan/approval workflow can remain unchanged.
