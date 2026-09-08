<#
.SYNOPSIS
    Grants a user-assigned managed identity a Microsoft Graph application permission.

.DESCRIPTION
    A managed identity has no "API permissions" blade of its own, so the grant is made
    the way Entra actually models it: an app role assignment where the managed
    identity's service principal is the principal, the Microsoft Graph service
    principal is the resource, and the app role is the permission.

    This is an application permission, not a delegated scope, because there is no
    signed-in user anywhere in this flow. A pod running on a schedule at 3am has no
    one to impersonate, so it needs permission in its own right.

    Device.Read.All is read only and is the only role granted. Nothing else is needed
    to enumerate devices.

.NOTES
    Granting an application permission is admin consent. You need Privileged Role
    Administrator or Global Administrator to run this.
#>

[CmdletBinding(DefaultParameterSetName = 'ByName')]
param(
    [Parameter(Mandatory, ParameterSetName = 'ByName')]
    [string] $IdentityName,

    [Parameter(Mandatory, ParameterSetName = 'ByName')]
    [string] $ResourceGroupName,

    # Skip the Az lookup if you already have the identity's principal id to hand.
    [Parameter(Mandatory, ParameterSetName = 'ByPrincipalId')]
    [string] $PrincipalId,

    [string] $AppRoleValue = 'Device.Read.All'
)

$ErrorActionPreference = 'Stop'

# The well-known application id of Microsoft Graph. It is the same in every tenant.
$graphAppId = '00000003-0000-0000-c000-000000000000'

if (-not (Get-MgContext)) {
    Connect-MgGraph -Scopes 'Application.Read.All', 'AppRoleAssignment.ReadWrite.All' -NoWelcome
}

# The managed identity's principal id is the object id of its service principal.
$principalId = if ($PSCmdlet.ParameterSetName -eq 'ByPrincipalId') {
    $PrincipalId
}
else {
    (Get-AzUserAssignedIdentity -Name $IdentityName -ResourceGroupName $ResourceGroupName).PrincipalId
}
Write-Host "Managed identity principal id: $principalId"

# Microsoft Graph's own service principal in this tenant.
$graphSp = Get-MgServicePrincipal -Filter "appId eq '$graphAppId'"
Write-Host "Microsoft Graph service principal: $($graphSp.Id)"

# Find the app role by its value. AllowedMemberTypes must contain Application,
# otherwise you have picked up the delegated scope of the same name.
$appRole = $graphSp.AppRoles |
    Where-Object { $_.Value -eq $AppRoleValue -and $_.AllowedMemberTypes -contains 'Application' }

if (-not $appRole) {
    throw "No application app role named '$AppRoleValue' found on Microsoft Graph."
}
Write-Host "App role '$($appRole.Value)' id: $($appRole.Id)"

# Skip if it is already assigned, so this script is safe to re-run.
$existing = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $principalId |
    Where-Object { $_.AppRoleId -eq $appRole.Id -and $_.ResourceId -eq $graphSp.Id }

if ($existing) {
    Write-Host "Already assigned. Nothing to do."
    return $existing
}

$assignment = New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $principalId -BodyParameter @{
    principalId = $principalId
    resourceId  = $graphSp.Id
    appRoleId   = $appRole.Id
}

Write-Host "Granted '$AppRoleValue'."
$assignment | Select-Object Id, PrincipalDisplayName, ResourceDisplayName, AppRoleId
