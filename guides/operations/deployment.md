# Deployment workflow

Use a separate tfvars file for each environment. A practical AWS first deployment is two-stage:

1. Enable the workspace, but leave `unity_catalog = false` and every service's `classic` and `serverless` connectivity mode set to `none`. Run `plan`, review, and `apply`.
2. Enable Unity Catalog, the chosen services, and their connectivity modes. Run a new plan and apply it. The workspace-level provider now has a live workspace host. An NCC is created automatically when any service uses `serverless = "private_link"`.

Terraform can often resolve the workspace host during a single apply, but the two-stage flow makes authentication and failures easier to diagnose.

PrivateLink endpoint services use `acceptance_required = true`. After a classic interface endpoint or NCC rule creates its endpoint, inspect `./infra endpoints aws status`, find the matching endpoint-service ID in AWS, and accept only the expected endpoint:

```bash
./infra endpoints aws accept --service-id vpce-svc-... --endpoint-id vpce-...
```

See the [AWS connectivity matrix](../aws/connectivity.md) for supported classic and serverless combinations.

For disposable AWS environments, `allow_destructive_demo_cleanup = true` disables database deletion protection and skips final snapshots. If resources already exist with deletion protection, first plan and apply that configuration change. Then save and review the destroy plan before running the guarded destroy command:

```bash
./infra destroy-plan aws environments/local/my-aws.tfvars
./infra destroy aws environments/local/my-aws.tfvars --confirm destroy-aws
```

Do not enable destructive cleanup for production.
