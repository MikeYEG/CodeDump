<#
.SYNOPSIS
    Tears down the Azure Arc workload identity lab.

.DESCRIPTION
    Deletes the lab resource group and the local k3d cluster. Run this when you are finished,
    an Arc-connected cluster and a Key Vault will keep billing quietly in the background.

.PARAMETER SubscriptionId
    The subscription the lab resources live in.

.PARAMETER ResourceGroupName
    Resource group to delete.

.PARAMETER ClusterName
    Name of the local k3d cluster to delete.

.EXAMPLE
    ./Remove-ArcWorkloadIdentityLab.ps1 -SubscriptionId $subscriptionId
#>
[cmdletbinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param (
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName = 'rg-arc-workload-identity',

    [Parameter(Mandatory = $false)]
    [string]$ClusterName = 'arc-local-cluster'
)

try {
    if ($PSCmdlet.ShouldProcess("$ResourceGroupName and k3d cluster $ClusterName", 'Delete')) {
        Set-AzContext -SubscriptionId $SubscriptionId | Out-Null

        Write-Host "Deleting resource group '$ResourceGroupName'..." -ForegroundColor Cyan
        Remove-AzResourceGroup -Name $ResourceGroupName -Force -AsJob | Out-Null

        Write-Host "Deleting k3d cluster '$ClusterName'..." -ForegroundColor Cyan
        k3d cluster delete $ClusterName
    }
}
catch {
    Write-Warning $_
}
