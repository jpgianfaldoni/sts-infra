# Infrastructure guides

The AWS and Azure guides explain how to build each network path by hand, in
the cloud console and the Databricks account console, and why each step is
needed. They do not depend on this repository's tooling.

The operations guides document `./infra`, which builds the same scenarios as
disposable labs.

## AWS

- [Connectivity choices](aws/connectivity.md): which path fits classic and
  serverless compute
- [Classic compute](aws/classic/README.md)
- [Serverless compute](aws/serverless/README.md)
- [Kafka](aws/kafka/overview.md), for both compute types

## Azure

- [Azure overview](azure/README.md)
- [Serverless compute](azure/serverless/README.md)
- [SQL Server on a VM](azure/manual/README.md): private network gateway or
  Private Link
- [Workspace front-end Private Link](azure/front-end-private-link.md)

## Operations

- [Lab scenarios](operations/lab-scenarios.md): what `./infra` builds for each
  scenario and the settings that select each path
- [Deployment workflow](operations/deployment.md)
- [Authentication](operations/authentication.md)
- [Local Terraform state](operations/state.md)
- [Application integration baseline](operations/application-integration.md)
