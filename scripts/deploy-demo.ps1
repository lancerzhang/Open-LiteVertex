param(
    [string]$ProjectId = "project-1831e149-6b02-4652-ad2",
    [string]$ClusterName = "litellm-demo",
    [string]$Region = "asia-east1",
    [string]$Namespace = "litellm-demo",
    [string]$VertexLocation = "global",
    [switch]$RotateSecrets
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function New-RandomSecret([int]$Bytes = 32) {
    $buffer = New-Object byte[] $Bytes
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($buffer)
    } finally {
        $rng.Dispose()
    }
    $value = [Convert]::ToBase64String($buffer)
    $value = $value.TrimEnd("=")
    $value = $value.Replace("+", "A").Replace("/", "B")
    return $value
}

function Read-DotEnvFile([string]$Path) {
    $values = @{}
    if (-not (Test-Path $Path)) {
        return $values
    }

    foreach ($line in Get-Content $Path) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith("#") -or -not $trimmed.Contains("=")) {
            continue
        }

        $separatorIndex = $trimmed.IndexOf("=")
        $key = $trimmed.Substring(0, $separatorIndex).Trim()
        $value = $trimmed.Substring($separatorIndex + 1).Trim()
        $values[$key] = $value
    }

    return $values
}

function Get-ExistingSecretObject([string]$Namespace, [string]$Name) {
    try {
        return kubectl get secret $Name -n $Namespace -o json | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Get-ExistingSecretValue([object]$SecretObject, [string]$Key) {
    if ($null -eq $SecretObject -or $null -eq $SecretObject.data) {
        return $null
    }

    $property = $SecretObject.data.PSObject.Properties[$Key]
    if ($null -eq $property -or -not $property.Value) {
        return $null
    }

    return [System.Text.Encoding]::UTF8.GetString(
        [Convert]::FromBase64String([string]$property.Value)
    )
}

function Wait-ForCluster([string]$ProjectId, [string]$ClusterName, [string]$Region) {
    while ($true) {
        $status = gcloud container clusters describe $ClusterName `
            --project $ProjectId `
            --region $Region `
            --format="value(status)" 2>$null

        if ($LASTEXITCODE -eq 0 -and $status -eq "RUNNING") {
            return
        }

        Write-Host "Waiting for cluster $ClusterName to become RUNNING..."
        Start-Sleep -Seconds 20
    }
}

function Set-StaticKubeConfig([string]$ProjectId, [string]$ClusterName, [string]$Region, [string]$RootPath) {
    $endpoint = gcloud container clusters describe $ClusterName `
        --project $ProjectId `
        --region $Region `
        --format="value(endpoint)"

    $caData = gcloud container clusters describe $ClusterName `
        --project $ProjectId `
        --region $Region `
        --format="value(masterAuth.clusterCaCertificate)"

    if (-not $endpoint -or -not $caData) {
        throw "Unable to retrieve cluster endpoint or CA data."
    }

    $secretsDir = Join-Path $RootPath ".secrets"
    New-Item -ItemType Directory -Force -Path $secretsDir | Out-Null

    $caPath = Join-Path $secretsDir "gke-ca.crt"
    $kubeconfigPath = Join-Path $secretsDir "kubeconfig"
    $token = gcloud auth print-access-token

    [System.IO.File]::WriteAllBytes($caPath, [Convert]::FromBase64String($caData))
    $env:KUBECONFIG = $kubeconfigPath

    kubectl config set-cluster $ClusterName `
        --server="https://$endpoint" `
        --certificate-authority=$caPath `
        --embed-certs=true | Out-Null

    kubectl config set-credentials gcp-user --token=$token | Out-Null
    kubectl config set-context $ClusterName --cluster=$ClusterName --user=gcp-user | Out-Null
    kubectl config use-context $ClusterName | Out-Null
}

function Ensure-ArtifactRepository([string]$ProjectId, [string]$Region, [string]$Repository) {
    $existing = gcloud artifacts repositories list `
        --project $ProjectId `
        --location $Region `
        --filter="name~/$Repository$" `
        --format="value(name)"

    if (-not $existing) {
        gcloud artifacts repositories create $Repository `
            --project $ProjectId `
            --repository-format=docker `
            --location $Region `
            --description="LiteLLM demo images" | Out-Null
    }
}

function Build-CustomImage(
    [string]$ProjectId,
    [string]$Region,
    [string]$ImageUri,
    [string]$RootPath
) {
    gcloud auth configure-docker "$Region-docker.pkg.dev" -q | Out-Null
    gcloud builds submit (Join-Path $RootPath "docker") `
        --project $ProjectId `
        --tag $ImageUri | Out-Null

    if ($LASTEXITCODE -ne 0) {
        throw "Cloud Build failed for image $ImageUri."
    }
}

function Ensure-ServiceAccount([string]$ProjectId, [string]$Name, [string]$DisplayName) {
    $email = "$Name@$ProjectId.iam.gserviceaccount.com"
    $exists = gcloud iam service-accounts list `
        --project $ProjectId `
        --filter="email=$email" `
        --format="value(email)"

    if (-not $exists) {
        gcloud iam service-accounts create $Name `
            --project $ProjectId `
            --display-name $DisplayName | Out-Null
    }

    return $email
}

function Wait-ForServiceAccount([string]$Email) {
    while ($true) {
        gcloud iam service-accounts describe $Email --format="value(email)" 1>$null 2>$null
        if ($LASTEXITCODE -eq 0) {
            return
        }

        Write-Host "Waiting for service account $Email to become visible..."
        Start-Sleep -Seconds 5
    }
}

function Invoke-GCloudWithRetry([scriptblock]$Action, [int]$Attempts = 5, [int]$DelaySeconds = 5) {
    for ($i = 1; $i -le $Attempts; $i++) {
        try {
            & $Action
            return
        } catch {
            if ($i -eq $Attempts) {
                throw
            }
            Write-Host "Retrying gcloud operation after transient failure..."
            Start-Sleep -Seconds $DelaySeconds
        }
    }
}

function Wait-ForLoadBalancer([string]$Namespace, [string]$ServiceName) {
    while ($true) {
        $ip = kubectl get svc $ServiceName -n $Namespace -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
        if ($ip) {
            return "http://$ip"
        }

        $hostname = kubectl get svc $ServiceName -n $Namespace -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
        if ($hostname) {
            return "http://$hostname"
        }

        Write-Host "Waiting for external endpoint on service $ServiceName..."
        Start-Sleep -Seconds 10
    }
}

$root = Split-Path -Parent $PSScriptRoot
$configPath = Join-Path $root "config\\litellm-config.yaml"
$authHandlerPath = Join-Path $root "config\\auth_handler.py"
$entraEnvPath = Join-Path $root ".entra.env"
$entraEnv = Read-DotEnvFile -Path $entraEnvPath
$imageRepository = "litellm-demo"
$imageUri = "$Region-docker.pkg.dev/$ProjectId/$imageRepository/litellm-entra-oss:latest"
$allowedModels = "vertex-gemini-2.5-flash,vertex-gemini-2.5-flash-lite,vertex-gemini-2.5-pro,vertex-gemini-3-pro-preview,vertex-gemini-3.1-pro-preview"

gcloud config set project $ProjectId | Out-Null
gcloud services enable `
    container.googleapis.com `
    aiplatform.googleapis.com `
    artifactregistry.googleapis.com `
    cloudbuild.googleapis.com `
    --project $ProjectId | Out-Null

$clusterExists = $false
try {
    $null = gcloud container clusters describe $ClusterName --project $ProjectId --region $Region --format=json
    $clusterExists = $true
} catch {
    $clusterExists = $false
}

if (-not $clusterExists) {
    gcloud container clusters create-auto $ClusterName `
        --project $ProjectId `
        --region $Region | Out-Null
}

Wait-ForCluster -ProjectId $ProjectId -ClusterName $ClusterName -Region $Region

Set-StaticKubeConfig `
    -ProjectId $ProjectId `
    -ClusterName $ClusterName `
    -Region $Region `
    -RootPath $root

Ensure-ArtifactRepository `
    -ProjectId $ProjectId `
    -Region $Region `
    -Repository $imageRepository

Build-CustomImage `
    -ProjectId $ProjectId `
    -Region $Region `
    -ImageUri $imageUri `
    -RootPath $root

kubectl apply -f (Join-Path $root "k8s\\namespace.yaml") | Out-Null
kubectl apply -f (Join-Path $root "k8s\\litellm-serviceaccount.yaml") | Out-Null

$gsaEmail = Ensure-ServiceAccount -ProjectId $ProjectId -Name "litellm-vertex" -DisplayName "LiteLLM Vertex Demo"
Wait-ForServiceAccount -Email $gsaEmail

Invoke-GCloudWithRetry {
    gcloud projects add-iam-policy-binding $ProjectId `
        --member="serviceAccount:$gsaEmail" `
        --role="roles/aiplatform.user" | Out-Null
}

gcloud iam service-accounts add-iam-policy-binding $gsaEmail `
    --project $ProjectId `
    --member="serviceAccount:$ProjectId.svc.id.goog[$Namespace/litellm-sa]" `
    --role="roles/iam.workloadIdentityUser" | Out-Null

kubectl annotate serviceaccount litellm-sa `
    -n $Namespace `
    iam.gke.io/gcp-service-account=$gsaEmail `
    --overwrite | Out-Null

$existingSecret = Get-ExistingSecretObject -Namespace $Namespace -Name "litellm-secrets"
$postgresPassword = $null
$masterKey = $null
$saltKey = $null

if (-not $RotateSecrets) {
    $postgresPassword = Get-ExistingSecretValue -SecretObject $existingSecret -Key "postgres-password"
    $masterKey = Get-ExistingSecretValue -SecretObject $existingSecret -Key "litellm-master-key"
    $saltKey = Get-ExistingSecretValue -SecretObject $existingSecret -Key "litellm-salt-key"
}

if (-not $postgresPassword) {
    $postgresPassword = New-RandomSecret
}
if (-not $masterKey) {
    $masterKey = "sk-" + (New-RandomSecret)
}
if (-not $saltKey) {
    $saltKey = New-RandomSecret
}

$databaseUrl = "postgresql://litellm:$postgresPassword@postgres.$Namespace.svc.cluster.local:5432/litellm"
$entraTenantId = $entraEnv["ENTRA_TENANT_ID"]
$entraClientId = $entraEnv["ENTRA_CLIENT_ID"]
$entraAllowedGroupIds = $entraEnv["ENTRA_ALLOWED_GROUP_IDS"]
if (-not $entraAllowedGroupIds) {
    $entraAllowedGroupIds = $entraEnv["ENTRA_ALLOWED_GROUP_ID"]
}
$entraSharedTeamId = $entraEnv["ENTRA_SHARED_TEAM_ID"]
if (-not $entraSharedTeamId -and $entraAllowedGroupIds) {
    $entraSharedTeamId = (
        ($entraAllowedGroupIds -split "[,;]")
        | ForEach-Object { $_.Trim() }
        | Where-Object { $_ }
        | Select-Object -First 1
    )
}
if (-not $entraSharedTeamId) {
    $entraSharedTeamId = "entra-shared-team"
}
$entraSharedTeamAlias = $entraEnv["ENTRA_SHARED_TEAM_ALIAS"]
if (-not $entraSharedTeamAlias) {
    $entraSharedTeamAlias = "entra-allowed-users"
}
$entraUserMaxBudget = $entraEnv["ENTRA_USER_MAX_BUDGET"]
if (-not $entraUserMaxBudget) {
    $entraUserMaxBudget = "50"
}
$entraUserBudgetDuration = $entraEnv["ENTRA_USER_BUDGET_DURATION"]
if (-not $entraUserBudgetDuration) {
    $entraUserBudgetDuration = "7d"
}
$entraSharedTeamMaxBudget = $entraEnv["ENTRA_SHARED_TEAM_MAX_BUDGET"]
if (-not $entraSharedTeamMaxBudget) {
    $entraSharedTeamMaxBudget = $entraUserMaxBudget
}
$entraSharedTeamBudgetDuration = $entraEnv["ENTRA_SHARED_TEAM_BUDGET_DURATION"]
if (-not $entraSharedTeamBudgetDuration) {
    $entraSharedTeamBudgetDuration = $entraUserBudgetDuration
}
$entraSharedTeamMemberMaxBudget = $entraEnv["ENTRA_SHARED_TEAM_MEMBER_MAX_BUDGET"]
if (-not $entraSharedTeamMemberMaxBudget) {
    $entraSharedTeamMemberMaxBudget = $entraUserMaxBudget
}
$entraAllowedAudiences = $entraEnv["ENTRA_ALLOWED_AUDIENCES"]
$entraIssuer = $entraEnv["ENTRA_ISSUER"]
if (-not $entraIssuer -and $entraTenantId) {
    $entraIssuer = "https://login.microsoftonline.com/$entraTenantId/v2.0"
}
$entraJwksUri = $entraEnv["ENTRA_JWKS_URI"]
if (-not $entraJwksUri -and $entraTenantId) {
    $entraJwksUri = "https://login.microsoftonline.com/$entraTenantId/discovery/v2.0/keys"
}

$secretYaml = @"
apiVersion: v1
kind: Secret
metadata:
  name: litellm-secrets
  namespace: $Namespace
type: Opaque
stringData:
  postgres-password: "$postgresPassword"
  database-url: "$databaseUrl"
  litellm-master-key: "$masterKey"
  litellm-salt-key: "$saltKey"
  vertex-project: "$ProjectId"
  vertex-location: "$VertexLocation"
  entra-tenant-id: "$entraTenantId"
  entra-client-id: "$entraClientId"
  entra-allowed-group-ids: "$entraAllowedGroupIds"
  entra-allowed-audiences: "$entraAllowedAudiences"
  entra-issuer: "$entraIssuer"
  entra-jwks-uri: "$entraJwksUri"
  entra-allowed-models: "$allowedModels"
  entra-user-max-budget: "$entraUserMaxBudget"
  entra-user-budget-duration: "$entraUserBudgetDuration"
  entra-shared-team-id: "$entraSharedTeamId"
  entra-shared-team-alias: "$entraSharedTeamAlias"
  entra-shared-team-max-budget: "$entraSharedTeamMaxBudget"
  entra-shared-team-budget-duration: "$entraSharedTeamBudgetDuration"
  entra-shared-team-member-max-budget: "$entraSharedTeamMemberMaxBudget"
"@

$secretYaml | kubectl apply -f - | Out-Null

kubectl apply -f (Join-Path $root "k8s\\postgres.yaml") | Out-Null
kubectl rollout status deployment/postgres -n $Namespace --timeout=10m | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Postgres rollout failed."
}

kubectl create configmap litellm-config `
    -n $Namespace `
    --from-file=config.yaml=$configPath `
    --from-file=auth_handler.py=$authHandlerPath `
    --dry-run=client -o yaml | kubectl apply -f - | Out-Null

kubectl apply -f (Join-Path $root "k8s\\litellm.yaml") | Out-Null
kubectl set image deployment/litellm litellm=$imageUri -n $Namespace | Out-Null
kubectl rollout restart deployment/litellm -n $Namespace | Out-Null
kubectl rollout status deployment/litellm -n $Namespace --timeout=10m | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "LiteLLM rollout failed."
}

$baseUrl = Wait-ForLoadBalancer -Namespace $Namespace -ServiceName "litellm"

Start-Sleep -Seconds 10
$keyResponse = & (Join-Path $PSScriptRoot "bootstrap-user-key.ps1") `
    -BaseUrl $baseUrl `
    -MasterKey $masterKey `
    -UserId "opencode-demo-user" `
    -KeyAlias ("opencode-demo-key-" + (Get-Date -Format "yyyyMMddHHmmss"))

$demoKey = $null
if ($keyResponse -is [string]) {
    $parsed = $keyResponse | ConvertFrom-Json
    $demoKey = $parsed.key
} else {
    $demoKey = $keyResponse.key
}

$demoEnv = @"
LITELLM_BASE_URL=$baseUrl
LITELLM_API_KEY=$demoKey
LITELLM_MASTER_KEY=$masterKey
GCP_PROJECT_ID=$ProjectId
GKE_CLUSTER=$ClusterName
GKE_REGION=$Region
LITELLM_IMAGE=$imageUri
"@

$demoEnvPath = Join-Path $root ".demo.env"
Set-Content -Path $demoEnvPath -Value $demoEnv -NoNewline

Write-Host ""
Write-Host "Deployment completed."
Write-Host "LiteLLM endpoint: $baseUrl"
Write-Host "Demo env file: $demoEnvPath"
