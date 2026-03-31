param(
    [string]$ProjectId = "project-1831e149-6b02-4652-ad2",
    [string]$ClusterName = "litellm-demo",
    [string]$Region = "asia-east1",
    [string]$Namespace = "litellm-demo",
    [string]$VertexLocation = "us-central1",
    [string]$VertexProjectId = "",
    [string]$VertexCredentialsFile = "",
    [switch]$RotateSecrets,
    [switch]$SkipVertexProjectSetup
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

function Get-OptionalValue([hashtable]$Values, [string]$Name) {
    $envItem = Get-Item -Path ("Env:" + $Name) -ErrorAction SilentlyContinue
    if ($null -ne $envItem) {
        $envValue = [string]$envItem.Value
        if ($envValue.Trim()) {
            return $envValue.Trim()
        }
    }

    if ($Values.ContainsKey($Name)) {
        $fileValue = [string]$Values[$Name]
        if ($fileValue.Trim()) {
            return $fileValue.Trim()
        }
    }

    return $null
}

function Get-FirstOptionalValue([hashtable]$Values, [string[]]$Names) {
    foreach ($name in $Names) {
        $value = Get-OptionalValue -Values $Values -Name $name
        if ($null -ne $value -and $value.Trim()) {
            return $value.Trim()
        }
    }

    return $null
}

function ConvertTo-BooleanSetting([string]$Value) {
    if ($null -eq $Value) {
        return $false
    }

    switch -Regex ($Value.Trim().ToLowerInvariant()) {
        "^(1|true|yes|y|on)$" {
            return $true
        }
        "^(0|false|no|n|off)$" {
            return $false
        }
        default {
            throw "Invalid boolean value '$Value'. Use true/false, yes/no, on/off, or 1/0."
        }
    }
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

function Get-ProjectNumber([string]$ProjectId) {
    $projectNumber = gcloud projects describe $ProjectId --format="value(projectNumber)"
    if (-not $projectNumber) {
        throw "Unable to retrieve project number for $ProjectId."
    }

    return [string]$projectNumber
}

function Wait-ForServiceAccount([string]$ProjectId, [string]$Email) {
    while ($true) {
        $existing = gcloud iam service-accounts list `
            --project $ProjectId `
            --filter="email=$Email" `
            --format="value(email)" 2>$null
        if ($LASTEXITCODE -eq 0 -and $existing) {
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
$vertexEnvPath = Join-Path $root ".vertex.env"
$modelArmorEnvPath = Join-Path $root ".modelarmor.env"
$entraEnv = Read-DotEnvFile -Path $entraEnvPath
$vertexEnv = Read-DotEnvFile -Path $vertexEnvPath
$modelArmorEnv = Read-DotEnvFile -Path $modelArmorEnvPath
$imageRepository = "litellm-demo"
$imageUri = "$Region-docker.pkg.dev/$ProjectId/$imageRepository/litellm-entra-oss:latest"
$allowedModels = "vertex-gemini-2.5-flash,vertex-gemini-2.5-flash-lite,vertex-gemini-2.5-pro,vertex-gemini-3-pro-preview,vertex-gemini-3.1-pro-preview"

if (-not $PSBoundParameters.ContainsKey("VertexProjectId")) {
    $vertexProjectOverride = Get-FirstOptionalValue -Values $vertexEnv -Names @("VERTEX_PROJECT_ID", "VERTEXAI_PROJECT")
    if ($vertexProjectOverride) {
        $VertexProjectId = $vertexProjectOverride
    }
}
if (-not $VertexProjectId) {
    $VertexProjectId = $ProjectId
}

if (-not $PSBoundParameters.ContainsKey("VertexLocation")) {
    $vertexLocationOverride = Get-FirstOptionalValue -Values $vertexEnv -Names @("VERTEX_LOCATION", "VERTEXAI_LOCATION")
    if ($vertexLocationOverride) {
        $VertexLocation = $vertexLocationOverride
    }
}

if (-not $PSBoundParameters.ContainsKey("VertexCredentialsFile")) {
    $vertexCredentialsFileOverride = Get-FirstOptionalValue -Values $vertexEnv -Names @("VERTEXAI_CREDENTIALS_FILE")
    if ($vertexCredentialsFileOverride) {
        $VertexCredentialsFile = $vertexCredentialsFileOverride
    }
}

$vertexCredentials = Get-FirstOptionalValue -Values $vertexEnv -Names @("VERTEXAI_CREDENTIALS")
if ($VertexCredentialsFile) {
    $resolvedVertexCredentialsFile = $VertexCredentialsFile
    if (-not [System.IO.Path]::IsPathRooted($resolvedVertexCredentialsFile)) {
        $resolvedVertexCredentialsFile = Join-Path $root $resolvedVertexCredentialsFile
    }
    if (-not (Test-Path $resolvedVertexCredentialsFile)) {
        throw "Vertex credentials file not found: $resolvedVertexCredentialsFile"
    }

    $vertexCredentials = [System.IO.File]::ReadAllText($resolvedVertexCredentialsFile)
    $VertexCredentialsFile = $resolvedVertexCredentialsFile
}

$vertexProjectIsRemote = $VertexProjectId -ne $ProjectId
$skipVertexProjectSetup = $SkipVertexProjectSetup.IsPresent
if (-not $PSBoundParameters.ContainsKey("SkipVertexProjectSetup")) {
    $skipVertexProjectSetupOverride = Get-FirstOptionalValue -Values $vertexEnv -Names @("VERTEX_SKIP_PROJECT_SETUP")
    if ($null -ne $skipVertexProjectSetupOverride) {
        $skipVertexProjectSetup = ConvertTo-BooleanSetting -Value $skipVertexProjectSetupOverride
    } elseif ($vertexProjectIsRemote) {
        $skipVertexProjectSetup = $true
    }
}

$vertexUsesExplicitCredentials = [bool]($vertexCredentials -and $vertexCredentials.Trim())
$modelArmorTemplate = Get-OptionalValue -Values $modelArmorEnv -Name "VERTEX_MODEL_ARMOR_TEMPLATE"
$modelArmorPromptTemplate = Get-OptionalValue -Values $modelArmorEnv -Name "VERTEX_MODEL_ARMOR_PROMPT_TEMPLATE"
if (-not $modelArmorPromptTemplate) {
    $modelArmorPromptTemplate = $modelArmorTemplate
}
$modelArmorResponseTemplate = Get-OptionalValue -Values $modelArmorEnv -Name "VERTEX_MODEL_ARMOR_RESPONSE_TEMPLATE"
if (-not $modelArmorResponseTemplate) {
    $modelArmorResponseTemplate = $modelArmorTemplate
}
$modelArmorEnabled = [bool]($modelArmorPromptTemplate -or $modelArmorResponseTemplate)

gcloud config set project $ProjectId | Out-Null
gcloud services enable `
    container.googleapis.com `
    artifactregistry.googleapis.com `
    cloudbuild.googleapis.com `
    --project $ProjectId | Out-Null

if ($vertexProjectIsRemote) {
    if ($skipVertexProjectSetup) {
        Write-Host "Skipping remote Vertex project setup for $VertexProjectId. Ensure the provider team has already enabled Vertex AI and granted IAM."
    } else {
        gcloud services enable `
            aiplatform.googleapis.com `
            --project $VertexProjectId | Out-Null
    }
} else {
    gcloud services enable `
        aiplatform.googleapis.com `
        --project $VertexProjectId | Out-Null
}

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

if ($modelArmorEnabled) {
    if ($vertexProjectIsRemote -and $skipVertexProjectSetup) {
        Write-Host "Skipping remote Model Armor setup for $VertexProjectId. Ensure the provider team enables modelarmor.googleapis.com and grants roles/modelarmor.user to the Vertex AI service agent."
    } else {
        $vertexProjectNumber = Get-ProjectNumber -ProjectId $VertexProjectId
        $vertexServiceAgent = "service-$vertexProjectNumber@gcp-sa-aiplatform.iam.gserviceaccount.com"
        gcloud services enable modelarmor.googleapis.com --project $VertexProjectId | Out-Null
        Invoke-GCloudWithRetry {
            gcloud projects add-iam-policy-binding $VertexProjectId `
                --member="serviceAccount:$vertexServiceAgent" `
                --role="roles/modelarmor.user" | Out-Null
        }
    }
}

kubectl apply -f (Join-Path $root "k8s\\namespace.yaml") | Out-Null
kubectl apply -f (Join-Path $root "k8s\\litellm-serviceaccount.yaml") | Out-Null

$gsaEmail = Ensure-ServiceAccount -ProjectId $ProjectId -Name "litellm-vertex" -DisplayName "LiteLLM Vertex Demo"
Wait-ForServiceAccount -ProjectId $ProjectId -Email $gsaEmail

if ($vertexUsesExplicitCredentials) {
    Write-Host "Using explicit Vertex credentials. Skipping Workload Identity access grant on the Vertex provider project."
} elseif ($vertexProjectIsRemote -and $skipVertexProjectSetup) {
    Write-Host "Skipping remote Vertex IAM binding for $gsaEmail on $VertexProjectId. Ensure the provider team grants roles/aiplatform.user."
} else {
    Invoke-GCloudWithRetry {
        gcloud projects add-iam-policy-binding $VertexProjectId `
            --member="serviceAccount:$gsaEmail" `
            --role="roles/aiplatform.user" | Out-Null
    }
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
$entraPublicClientId = $entraEnv["ENTRA_PUBLIC_CLIENT_ID"]
$entraAllowedGroupIds = $entraEnv["ENTRA_ALLOWED_GROUP_IDS"]
if (-not $entraAllowedGroupIds) {
    $entraAllowedGroupIds = $entraEnv["ENTRA_ALLOWED_GROUP_ID"]
}
$entraSharedTeamId = $entraEnv["ENTRA_SHARED_TEAM_ID"]
if (-not $entraSharedTeamId -and $entraAllowedGroupIds) {
    $entraSharedTeamId = (($entraAllowedGroupIds -split "[,;]") | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -First 1)
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

$vertexCredentialsYaml = '  vertex-credentials: ""'
if ($vertexUsesExplicitCredentials) {
    $normalizedVertexCredentials = ($vertexCredentials -replace "`r`n", "`n").TrimEnd("`n")
    $vertexCredentialsLines = ($normalizedVertexCredentials -split "`n" | ForEach-Object { "    $_" }) -join "`n"
    $vertexCredentialsYaml = "  vertex-credentials: |-" + "`n" + $vertexCredentialsLines
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
  vertex-project: "$VertexProjectId"
  vertex-location: "$VertexLocation"
$vertexCredentialsYaml
  entra-tenant-id: "$entraTenantId"
  entra-client-id: "$entraClientId"
  entra-public-client-id: "$entraPublicClientId"
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
  vertex-model-armor-template: "$modelArmorTemplate"
  vertex-model-armor-prompt-template: "$modelArmorPromptTemplate"
  vertex-model-armor-response-template: "$modelArmorResponseTemplate"
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

$litellmManifestPath = Join-Path $root "k8s\\litellm.yaml"
kubectl apply -f $litellmManifestPath | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Retrying LiteLLM manifest apply by recreating the Deployment..."
    kubectl delete deployment litellm -n $Namespace --ignore-not-found | Out-Null
    kubectl apply -f $litellmManifestPath | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "LiteLLM manifest apply failed."
    }
}
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
GCP_DEPLOY_PROJECT_ID=$ProjectId
VERTEX_PROJECT_ID=$VertexProjectId
VERTEX_LOCATION=$VertexLocation
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
Write-Host "Deploy project: $ProjectId"
Write-Host "Vertex project: $VertexProjectId"
Write-Host "Vertex location: $VertexLocation"
if ($vertexUsesExplicitCredentials) {
    Write-Host "Vertex auth mode: explicit VERTEXAI_CREDENTIALS"
} else {
    Write-Host "Vertex auth mode: Workload Identity via $gsaEmail"
}
if ($vertexProjectIsRemote -and $skipVertexProjectSetup) {
    Write-Host "Remote Vertex project setup was skipped. Coordinate API enablement and IAM grants with the provider team."
}
if ($modelArmorEnabled) {
    Write-Host "Vertex Model Armor templates enabled for Gemini generateContent calls."
}
