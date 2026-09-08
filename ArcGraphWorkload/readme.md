# ArcGraphWorkload

Companion code for [Run a PowerShell workload on a local Kubernetes cluster that talks to Microsoft Graph](https://powers-hell.com/2026/09/08/run-a-powershell-workload-on-a-local-kubernetes-cluster-that-talks-to-microsoft-graph/).

Runs a containerised PowerShell workload on an Azure Arc-enabled Kubernetes cluster, swaps the
projected service account token for a Microsoft Graph access token, and reports on the device
estate on a schedule. No app registration, no client secret and no certificate anywhere in the
image.

This builds directly on the lab from [ArcWorkloadIdentity](../ArcWorkloadIdentity). Set that up
first, or nothing here has an identity to use.

## Contents

| File | What it does |
| --- | --- |
| `Grant-GraphAppRole.ps1` | Grants the managed identity the `Device.Read.All` Graph application permission |
| `Get-GraphDeviceReport.ps1` | The workload. Exchanges the projected token for a Graph token and reports on devices |
| `Dockerfile` | Builds the workload image with `Microsoft.Graph.Authentication` only |
| `graphDeviceReportCronJob.yaml` | The CronJob that runs the workload on a schedule |
| `serviceAccount.yaml` | Reference copy of the annotated service account, carried over from the previous post |
| `Remove-ArcGraphWorkload.ps1` | Removes the CronJob, the image and the app role assignment |

## Prerequisites

Software:

- [Docker Desktop](https://www.docker.com/products/docker-desktop/)
- [k3d](https://k3d.io/) and [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli)
- The finished lab from [ArcWorkloadIdentity](../ArcWorkloadIdentity)

PowerShell modules, on your machine rather than in the image:

```powershell
$modules = @("Az.Accounts", "Az.ManagedServiceIdentity", "Microsoft.Graph.Applications")
$modules | ForEach-Object { Install-Module -Name $_ -Force -AllowClobber -Scope CurrentUser }
```

Granting an application permission is an admin consent operation, so you need Privileged Role
Administrator or Global Administrator in the tenant.

## Usage

Grant the permission:

```powershell
./Grant-GraphAppRole.ps1 -IdentityName 'id-local-cluster-kv' -ResourceGroupName 'rg-arc-workload-identity'
```

Build the image and side-load it into the cluster. On Apple Silicon your k3d nodes are arm64,
so pass the matching base image - the default tag is amd64 only and containerd will reject it:

```bash
docker build --build-arg BASE_IMAGE=mcr.microsoft.com/powershell:lts-azurelinux-3.0-arm64 -t arc-graph-workload:1.0.0 .
k3d image import arc-graph-workload:1.0.0 -c arc-local-cluster
```

Deploy the CronJob and trigger a run without waiting for the schedule:

```bash
kubectl apply -f graphDeviceReportCronJob.yaml
kubectl create job graph-device-report-manual --from=cronjob/graph-device-report -n workload-identity
kubectl logs job/graph-device-report-manual -n workload-identity
```

## The one that will catch you out

The `azure.workload.identity/use: "true"` label goes on the **pod template**, not on the CronJob
or the Job. There are three `metadata` blocks in that file and only one counts. Workload identity
inspects pods as they get created, and a CronJob isn't a pod - it creates Jobs, and a Job creates
Pods. The `template:` block at the bottom is the only part that describes a pod, so it is the only
place the label does anything. Put it anywhere else and you get no error and no warning. The job
runs, the container starts, and it fails on the first line because `AZURE_CLIENT_ID` was never
injected.

## Cleaning up

Removes the CronJob, the image and the app role assignment, leaving the lab intact:

```powershell
./Remove-ArcGraphWorkload.ps1 -IdentityName 'id-local-cluster-kv' -ResourceGroupName 'rg-arc-workload-identity'
```

To remove the lab itself - the Arc connection, the managed identity, the Key Vault and the
cluster - run `Remove-ArcWorkloadIdentityLab.ps1` in the [ArcWorkloadIdentity](../ArcWorkloadIdentity)
folder. Arc-enabled Kubernetes and the resources around it are billable, so do not leave the lab
running once you are finished with it.
