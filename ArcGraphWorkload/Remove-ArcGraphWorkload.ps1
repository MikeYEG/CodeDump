<#
.SYNOPSIS
    Removes everything this sample adds on top of the ArcWorkloadIdentity lab.

.DESCRIPTION
    This sample builds on the lab from the previous post, so the teardown is split in two.

    This script removes only what the Graph workload added:
      - the CronJob and any Jobs it left behind
      - the container image, from both the cluster and the local Docker daemon
      - the Device.Read.All app role assignment on the managed identity

    It deliberately leaves the cluster, the managed identity, the Key Vault and the
    federated credential alone. To remove the lab itself, run
    Remove-ArcWorkloadIdentityLab.ps1 from the ArcWorkloadIdentity folder.

.EXAMPLE
    ./Remove-ArcGraphWorkload.ps1 -IdentityName 'id-local-cluster-kv' -ResourceGroupName 'rg-arc-workload-identity'
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string] $IdentityName,

    [Parameter(Mandatory)]
    [string] $ResourceGroupName,

    [string] $ClusterName = 'arc-local-cluster',

    [string] $Namespace = 'workload-identity',

    [string] $ImageTag = 'arc-graph-workload:1.0.0',

    [string] $AppRoleValue = 'Device.Read.All'
)

$ErrorActionPreference = 'Stop'
$kubeContext = "k3d-$ClusterName"

#region cluster objects
Write-Host "Removing workload objects from $kubeContext..."

if ($PSCmdlet.ShouldProcess($Namespace, 'Delete CronJob and Jobs')) {
    kubectl --context $kubeContext delete cronjob graph-device-report -n $Namespace --ignore-not-found
    kubectl --context $kubeContext delete job -n $Namespace --all --ignore-not-found
}
#endregion

#region images
Write-Host "Removing image $ImageTag..."

if ($PSCmdlet.ShouldProcess($ImageTag, 'Remove image')) {
    # k3d has no "image remove", so the image is dropped from the node's containerd store.
    k3d node list --no-headers |
        Where-Object { $_ -match "$ClusterName-server" } |
        ForEach-Object {
            $node = ($_ -split '\s+')[0]
            docker exec $node ctr --namespace k8s.io images rm "docker.io/library/$ImageTag" 2>$null
        }

    docker image rm $ImageTag --force 2>$null
}
#endregion

#region graph permission
Write-Host "Removing the '$AppRoleValue' app role assignment..."

if (-not (Get-MgContext)) {
    Connect-MgGraph -Scopes 'Application.Read.All', 'AppRoleAssignment.ReadWrite.All' -NoWelcome
}

$graphAppId  = '00000003-0000-0000-c000-000000000000'
$principalId = (Get-AzUserAssignedIdentity -Name $IdentityName -ResourceGroupName $ResourceGroupName).PrincipalId
$graphSp     = Get-MgServicePrincipal -Filter "appId eq '$graphAppId'"

$appRole = $graphSp.AppRoles |
    Where-Object { $_.Value -eq $AppRoleValue -and $_.AllowedMemberTypes -contains 'Application' }

$assignments = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $principalId |
    Where-Object { $_.AppRoleId -eq $appRole.Id -and $_.ResourceId -eq $graphSp.Id }

foreach ($assignment in $assignments) {
    if ($PSCmdlet.ShouldProcess($assignment.Id, "Remove $AppRoleValue assignment")) {
        $removeParams = @{
            ServicePrincipalId  = $principalId
            AppRoleAssignmentId = $assignment.Id
        }

        Remove-MgServicePrincipalAppRoleAssignment @removeParams
        Write-Host "  removed assignment $($assignment.Id)"
    }
}

if (-not $assignments) {
    Write-Host '  nothing to remove.'
}
#endregion

Write-Host ''
Write-Host 'Done. The cluster, managed identity, Key Vault and federated credential are untouched.'
Write-Host 'To remove the lab itself, run Remove-ArcWorkloadIdentityLab.ps1 in the ArcWorkloadIdentity folder.'
