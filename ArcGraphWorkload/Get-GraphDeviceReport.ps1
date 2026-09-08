<#
.SYNOPSIS
    Exchanges a Kubernetes projected service account token for a Microsoft Graph
    access token using the Entra client assertion flow, then queries Graph.

.DESCRIPTION
    Runs inside a pod that carries the azure.workload.identity/use label. Any pod with
    that label gets these injected into it automatically:

        AZURE_CLIENT_ID           - client id of the user-assigned managed identity
        AZURE_TENANT_ID           - tenant the identity lives in
        AZURE_AUTHORITY_HOST      - https://login.microsoftonline.com/
        AZURE_FEDERATED_TOKEN_FILE - path to the projected service account token

    No secret, certificate or connection string is present in this image.
#>

[CmdletBinding()]
param(
    [string] $Scope = 'https://graph.microsoft.com/.default',

    # v1.0 is deliberate. /devices is generally available, so there is no reason
    # to take a dependency on beta for this workload.
    [string] $GraphApiVersion = 'v1.0',

    [int] $DeviceCount = 20
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function ConvertFrom-JwtPayload {
    <#
        Decodes the payload segment of a JWT. Base64url has to be translated back
        to plain base64 and re-padded before .NET will look at it.
    #>
    param([Parameter(Mandatory)][string] $Token)

    $payload = $Token.Split('.')[1].Replace('-', '+').Replace('_', '/')
    $payload = $payload.PadRight($payload.Length + (4 - $payload.Length % 4) % 4, '=')
    [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
}

function Write-Section {
    param([string] $Text)
    Write-Host ''
    Write-Host "=== $Text ===" -ForegroundColor Cyan
}

# --------------------------------------------------------------------------
# 1. Read the projected service account token
# --------------------------------------------------------------------------
Write-Section 'Projected service account token'

foreach ($name in 'AZURE_CLIENT_ID', 'AZURE_TENANT_ID', 'AZURE_AUTHORITY_HOST', 'AZURE_FEDERATED_TOKEN_FILE') {
    if (-not (Get-Item "env:$name" -ErrorAction SilentlyContinue)) {
        throw "$name is not set. Is the azure.workload.identity/use label on the pod template?"
    }
}

$clientId      = $env:AZURE_CLIENT_ID
$tenantId      = $env:AZURE_TENANT_ID
$authorityHost = $env:AZURE_AUTHORITY_HOST.TrimEnd('/')

$assertion = (Get-Content -Path $env:AZURE_FEDERATED_TOKEN_FILE -Raw).Trim()
$saClaims  = ConvertFrom-JwtPayload -Token $assertion

Write-Host ("  issuer    : {0}" -f $saClaims.iss)
Write-Host ("  subject   : {0}" -f $saClaims.sub)
Write-Host ("  audience  : {0}" -f ($saClaims.aud -join ', '))
Write-Host ("  expires   : {0:u}" -f ([DateTimeOffset]::FromUnixTimeSeconds($saClaims.exp).UtcDateTime))

# --------------------------------------------------------------------------
# 2. Swap it for a Graph access token (client assertion / client credentials)
# --------------------------------------------------------------------------
Write-Section 'Exchanging assertion for a Graph access token'

$tokenEndpoint = "$authorityHost/$tenantId/oauth2/v2.0/token"

$body = @{
    client_id             = $clientId
    scope                 = $Scope
    grant_type            = 'client_credentials'
    client_assertion_type = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
    client_assertion      = $assertion
}

$response = Invoke-RestMethod -Method Post -Uri $tokenEndpoint -Body $body -ContentType 'application/x-www-form-urlencoded'
$accessToken = $response.access_token

Write-Host ("  endpoint  : {0}" -f $tokenEndpoint)
Write-Host ("  granted   : an OAuth 2.0 bearer token for {0}" -f $Scope)
Write-Host ("  lifetime  : {0} seconds" -f $response.expires_in)

# --------------------------------------------------------------------------
# 3. Show the claims we got back
# --------------------------------------------------------------------------
Write-Section 'Access token claims'

$claims = ConvertFrom-JwtPayload -Token $accessToken

[pscustomobject]@{
    aud      = $claims.aud
    iss      = $claims.iss
    appid    = if ($claims.appid) { $claims.appid } else { $claims.azp }
    oid      = $claims.oid
    tid      = $claims.tid
    idtyp    = $claims.idtyp
    roles    = ($claims.roles -join ', ')
    expires  = '{0:u}' -f ([DateTimeOffset]::FromUnixTimeSeconds($claims.exp).UtcDateTime)
} | Format-List

# --------------------------------------------------------------------------
# 4. Connect to Graph and do some real work
# --------------------------------------------------------------------------
Write-Section 'Connecting to Microsoft Graph'

Connect-MgGraph -AccessToken (ConvertTo-SecureString $accessToken -AsPlainText -Force) -NoWelcome
$context = Get-MgContext
Write-Host ("  connected as app {0} in tenant {1}" -f $context.ClientId, $context.TenantId)
Write-Host ("  scopes: {0}" -f ($context.Scopes -join ', '))

Write-Section "Devices from Graph ($GraphApiVersion)"

$uri = "https://graph.microsoft.com/$GraphApiVersion/devices?`$top=$DeviceCount&`$select=displayName,operatingSystem,operatingSystemVersion,trustType,isCompliant,approximateLastSignInDateTime"
$devices = (Invoke-MgGraphRequest -Method GET -Uri $uri).value

Write-Host ("  returned {0} device(s)" -f $devices.Count)
Write-Host ''

$devices |
    ForEach-Object {
        [pscustomobject]@{
            DisplayName = $_.displayName
            OS          = $_.operatingSystem
            Version     = $_.operatingSystemVersion
            TrustType   = $_.trustType
            Compliant   = $_.isCompliant
            LastSignIn  = if ($_.approximateLastSignInDateTime) {
                              ([datetime]$_.approximateLastSignInDateTime).ToString('yyyy-MM-dd')
                          } else { 'never' }
        }
    } |
    Format-Table -AutoSize

Write-Section 'Summary by operating system'

$devices |
    Group-Object operatingSystem |
    Sort-Object Count -Descending |
    Select-Object @{n = 'OperatingSystem'; e = { $_.Name } }, Count |
    Format-Table -AutoSize

Disconnect-MgGraph | Out-Null
Write-Host 'Done.'
