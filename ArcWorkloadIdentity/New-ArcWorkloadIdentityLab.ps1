<#
.SYNOPSIS
    Builds the Azure Arc workload identity lab end to end.

.DESCRIPTION
    Creates a local k3d cluster, connects it to Azure Arc with the OIDC issuer and workload
    identity enabled, points the k3s API server at the Arc issuer, then creates a Key Vault,
    a user-assigned managed identity and the federated credential that ties the two together.

    Companion code for https://powers-hell.com/2026/08/26/access-azure-key-vault-from-a-local-kubernetes-cluster-with-azure-arc-workload-identity/

.PARAMETER TenantId
    The Entra tenant that owns the subscription.

.PARAMETER SubscriptionId
    The subscription the lab resources are created in.

.PARAMETER ResourceGroupName
    Resource group for the lab. Created if it does not exist.

.PARAMETER Location
    Azure region for the lab resources.

.PARAMETER ClusterName
    Name of the k3d cluster and of the Arc-connected cluster resource.

.PARAMETER SkipClusterCreate
    Use an existing k3d cluster rather than creating a new one.

.EXAMPLE
    ./New-ArcWorkloadIdentityLab.ps1 -TenantId $tenantId -SubscriptionId $subscriptionId

.NOTES
    Requires Owner on the subscription, or Contributor plus Role Based Access Control
    Administrator. Creating the role assignment needs Microsoft.Authorization/roleAssignments/write,
    which Contributor on its own does not grant.
#>
[cmdletbinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$TenantId,

    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName = 'rg-arc-workload-identity',

    [Parameter(Mandatory = $false)]
    [string]$Location = 'eastus',

    [Parameter(Mandatory = $false)]
    [string]$ClusterName = 'arc-local-cluster',

    [Parameter(Mandatory = $false)]
    [switch]$SkipClusterCreate
)

try {
    #region variables
    $suffix                  = Get-Random -Minimum 10000 -Maximum 99999
    $keyVaultName            = "kvlocalarc$suffix"
    $secretName              = 'LocalClusterSecret'
    $secretText              = 'Hello from Azure Arc workload identity!'
    $identityName            = 'id-local-cluster-kv'
    $federatedCredentialName = 'local-cluster-kv-fic'
    $serviceAccountNamespace = 'workload-identity'
    $serviceAccountName      = 'kv-reader'
    $testPodName             = 'workload-identity-test'
    #endregion

    #region create the local cluster
    # The Kubernetes that ships with Docker Desktop cannot be used here. Workload identity on
    # Arc only supports a specific set of distributions, and we need to hand the API server a
    # new service-account-issuer, which Docker Desktop will not allow.
    if (-not $SkipClusterCreate) {
        Write-Host "Creating k3d cluster '$ClusterName'..." -ForegroundColor Cyan
        k3d cluster create $ClusterName --servers 1 --agents 0 --wait
    }
    #endregion

    #region connect to Azure
    Connect-AzAccount -Subscription $SubscriptionId -Tenant $TenantId
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null

    New-AzResourceGroup -Name $ResourceGroupName -Location $Location -Force | Out-Null
    #endregion

    #region register resource providers
    # These take a few minutes to reach Registered. Arc onboarding fails with an unhelpful
    # error if they have not finished.
    $providers = @("Microsoft.Kubernetes", "Microsoft.KubernetesConfiguration", "Microsoft.ExtendedLocation")
    $providers | ForEach-Object { Register-AzResourceProvider -ProviderNamespace $_ | Out-Null }

    $providers | ForEach-Object {
        Get-AzResourceProvider -ProviderNamespace $_ |
            Select-Object -First 1 ProviderNamespace, RegistrationState
    }
    #endregion

    #region connect the cluster to Azure Arc
    $k8sParams = @{
        ClusterName              = $ClusterName
        ResourceGroupName        = $ResourceGroupName
        SubscriptionId           = $SubscriptionId
        Location                 = $Location
        OidcIssuerProfileEnabled = $true
        WorkloadIdentityEnabled  = $true
    }

    New-AzConnectedKubernetes @k8sParams -AcceptEULA -Verbose

    # The Az cmdlets flatten the profile, so the property is OidcIssuerProfileIssuerUrl and
    # not the nested OidcIssuerProfile.IssuerUrl returned by the REST API.
    $connectedCluster = Get-AzConnectedKubernetes -ClusterName $ClusterName -ResourceGroupName $ResourceGroupName
    $oidcIssuer = $connectedCluster.OidcIssuerProfileIssuerUrl

    $connectedCluster | Select-Object Name, Distribution, ConnectivityStatus,
        OidcIssuerProfileEnabled, WorkloadIdentityEnabled, OidcIssuerProfileIssuerUrl
    #endregion

    #region point the API server at the Arc issuer
    # Enabling the feature in Azure installs the webhook, but the cluster still signs tokens
    # with its own issuer. Entra rejects those, because it has never heard of that issuer.
    $k3sConfig = @"
kube-apiserver-arg:
  - "service-account-issuer=$oidcIssuer"
  - "service-account-max-token-expiration=24h"
"@

    # k3d runs k3s inside a container, so we write the config there and restart it.
    $serverNode = "k3d-$ClusterName-server-0"
    $k3sConfig | docker exec -i $serverNode sh -c 'mkdir -p /etc/rancher/k3s && cat > /etc/rancher/k3s/config.yaml'
    docker restart $serverNode

    Write-Host "Waiting for the API server to come back..." -ForegroundColor Cyan
    Start-Sleep -Seconds 30

    # Prove the tokens really are signed with the Arc issuer before going any further.
    $token = kubectl create token default
    $payload = $token.Split('.')[1].Replace('-', '+').Replace('_', '/')
    $payload = $payload.PadRight($payload.Length + (4 - $payload.Length % 4) % 4, '=')
    [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json | Select-Object iss, sub
    #endregion

    #region create the Key Vault and secret
    $keyVaultParams = @{
        Name              = $keyVaultName
        ResourceGroupName = $ResourceGroupName
        Location          = $Location
    }

    $keyVault = New-AzKeyVault @keyVaultParams

    $secretValue = ConvertTo-SecureString $secretText -AsPlainText -Force
    Set-AzKeyVaultSecret -VaultName $keyVaultName -Name $secretName -SecretValue $secretValue | Out-Null
    #endregion

    #region create the managed identity and grant it access
    $identityParams = @{
        Name              = $identityName
        ResourceGroupName = $ResourceGroupName
        Location          = $Location
    }

    $identity = New-AzUserAssignedIdentity @identityParams

    $clientId = $identity.ClientId
    $principalId = $identity.PrincipalId
    $keyVaultResourceId = $keyVault.ResourceId

    $roleParams = @{
        ObjectId           = $principalId
        ObjectType         = 'ServicePrincipal'
        RoleDefinitionName = 'Key Vault Secrets User'
        Scope              = $keyVaultResourceId
    }

    New-AzRoleAssignment @roleParams
    #endregion

    #region create the Kubernetes service account
    kubectl create namespace $serviceAccountNamespace

    @"
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $serviceAccountName
  namespace: $serviceAccountNamespace
  annotations:
    azure.workload.identity/client-id: "$clientId"
    azure.workload.identity/tenant-id: "$TenantId"
"@ | Set-Content -Path (Join-Path $PSScriptRoot 'serviceAccount.yaml') -Encoding utf8

    kubectl apply -f (Join-Path $PSScriptRoot 'serviceAccount.yaml')
    #endregion

    #region create the federated credential
    # Azure trusts tokens from our cluster, but only when the subject matches this exact
    # service account. The ${} around the variable names matters - without them PowerShell
    # reads $serviceAccountNamespace: as a drive-qualified variable and throws a parser error.
    $ficParams = @{
        Name              = $federatedCredentialName
        IdentityName      = $identityName
        ResourceGroupName = $ResourceGroupName
        Issuer            = $oidcIssuer
        Subject           = "system:serviceaccount:${serviceAccountNamespace}:${serviceAccountName}"
        Audience          = @('api://AzureADTokenExchange')
    }

    New-AzFederatedIdentityCredential @ficParams
    #endregion

    #region create the test pod
    @"
apiVersion: v1
kind: Pod
metadata:
  name: $testPodName
  namespace: $serviceAccountNamespace
  labels:
    azure.workload.identity/use: "true"
spec:
  serviceAccountName: $serviceAccountName
  containers:
    - name: powershell
      image: mcr.microsoft.com/azure-powershell:latest
      command: ["pwsh", "-Command"]
      args:
        - |
          Disable-AzContextAutosave -Scope Process | Out-Null
          `$federatedToken = Get-Content -Path `$env:AZURE_FEDERATED_TOKEN_FILE -Raw
          Connect-AzAccount -ServicePrincipal -ApplicationId `$env:AZURE_CLIENT_ID -Tenant `$env:AZURE_TENANT_ID -FederatedToken `$federatedToken | Out-Null
          `$secret = Get-AzKeyVaultSecret -VaultName $keyVaultName -Name $secretName -AsPlainText
          Write-Output `$secret
          Start-Sleep -Seconds 3600
  nodeSelector:
    kubernetes.io/os: linux
"@ | Set-Content -Path (Join-Path $PSScriptRoot 'workloadIdentityTest.yaml') -Encoding utf8

    # Federated credentials take a few seconds to propagate. If the first attempt fails,
    # wait a moment and try again before pulling the manifests apart.
    Write-Host "Waiting for the federated credential to propagate..." -ForegroundColor Cyan
    Start-Sleep -Seconds 30

    kubectl apply -f (Join-Path $PSScriptRoot 'workloadIdentityTest.yaml')
    #endregion

    #region verify
    kubectl describe pod $testPodName -n $serviceAccountNamespace
    kubectl logs $testPodName -n $serviceAccountNamespace
    #endregion

    [PSCustomObject]@{
        ClusterName      = $ClusterName
        OidcIssuer       = $oidcIssuer
        KeyVaultName     = $keyVaultName
        SecretName       = $secretName
        IdentityName     = $identityName
        IdentityClientId = $clientId
        ServiceAccount   = "system:serviceaccount:${serviceAccountNamespace}:${serviceAccountName}"
    }
}
catch {
    Write-Warning $_
}
