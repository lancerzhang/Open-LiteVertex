param(
    [int]$Port = 8787,
    [string]$BrokerApiKey = "opencode-local-broker-key",
    [switch]$UseDeviceCode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Import-DotEnv([string]$Path) {
    foreach ($line in Get-Content $Path) {
        if ($line -match "^(.*?)=(.*)$") {
            Set-Item -Path Env:$($matches[1]) -Value $matches[2]
        }
    }
}

$root = Split-Path -Parent $PSScriptRoot
$entraEnvPath = Join-Path $root ".entra.env"
$demoEnvPath = Join-Path $root ".demo.env"
$brokerScriptPath = Join-Path $PSScriptRoot "entra_litellm_broker.py"
$pidFilePath = Join-Path $root ".secrets\\entra-broker.pid"
$stdoutLogPath = Join-Path $root ".secrets\\entra-broker.stdout.log"
$stderrLogPath = Join-Path $root ".secrets\\entra-broker.stderr.log"

if (-not (Test-Path $entraEnvPath)) {
    throw "Missing .entra.env. Run scripts\\setup-entra-oss.ps1 first."
}
if (-not (Test-Path $demoEnvPath)) {
    throw "Missing .demo.env. Run scripts\\deploy-demo.ps1 first."
}

Import-DotEnv -Path $entraEnvPath
Import-DotEnv -Path $demoEnvPath

if (-not $env:ENTRA_TENANT_ID -or -not $env:ENTRA_CLIENT_ID -or -not $env:ENTRA_SCOPE) {
    throw ".entra.env is missing ENTRA_TENANT_ID, ENTRA_CLIENT_ID, or ENTRA_SCOPE."
}
if (-not $env:LITELLM_BASE_URL) {
    throw ".demo.env is missing LITELLM_BASE_URL."
}

$getTokenScript = Join-Path $PSScriptRoot "get-entra-token.ps1"
if ($UseDeviceCode) {
    $tokenJson = & $getTokenScript `
        -TenantId $env:ENTRA_TENANT_ID `
        -ClientId $env:ENTRA_CLIENT_ID `
        -UseDeviceCode
} else {
    $tokenJson = & $getTokenScript `
        -TenantId $env:ENTRA_TENANT_ID `
        -ClientId $env:ENTRA_CLIENT_ID
}
$tokenResponse = $tokenJson | ConvertFrom-Json

$env:BROKER_HOST = "127.0.0.1"
$env:BROKER_PORT = [string]$Port
$env:BROKER_LOG_LEVEL = "info"
$env:BROKER_UPSTREAM_BASE_URL = $env:LITELLM_BASE_URL.TrimEnd("/")
$env:ENTRA_BROKER_API_KEY = $BrokerApiKey
$env:BROKER_REFRESH_SKEW_SECONDS = "300"

$python = Get-Command python -ErrorAction SilentlyContinue
if ($null -eq $python) {
    throw "python is not installed or not on PATH."
}
$az = Get-Command az -ErrorAction SilentlyContinue
if ($null -eq $az) {
    throw "Azure CLI (az) is not installed or not on PATH."
}
$env:AZ_PATH = $az.Source

$existingPid = $null
if (Test-Path $pidFilePath) {
    $existingPid = (Get-Content $pidFilePath -ErrorAction SilentlyContinue | Select-Object -First 1)
}
if ($existingPid) {
    $existingProcess = Get-Process -Id $existingPid -ErrorAction SilentlyContinue
    if ($existingProcess) {
        Write-Host "Broker already running on PID $existingPid."
        Write-Host "Broker base URL: http://127.0.0.1:$Port/v1"
        Write-Host "Initial Entra token expires on: $($tokenResponse.expiresOn)"
        return
    }
}

$process = Start-Process `
    -FilePath $python.Source `
    -ArgumentList $brokerScriptPath `
    -WorkingDirectory $root `
    -RedirectStandardOutput $stdoutLogPath `
    -RedirectStandardError $stderrLogPath `
    -PassThru

Set-Content -Path $pidFilePath -Value $process.Id -NoNewline

$healthzUrl = "http://127.0.0.1:$Port/healthz"
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 1
    try {
        $response = Invoke-RestMethod -Method Get -Uri $healthzUrl
        if ($response.status -eq "ok") {
            Write-Host "Broker started on PID $($process.Id)."
            Write-Host "Broker base URL: http://127.0.0.1:$Port/v1"
            Write-Host "Broker API key: $BrokerApiKey"
            Write-Host "Initial Entra token expires on: $($tokenResponse.expiresOn)"
            Write-Host "Broker stdout log: $stdoutLogPath"
            Write-Host "Broker stderr log: $stderrLogPath"
            return
        }
    } catch {
    }
}

throw "Broker process started but did not become healthy on $healthzUrl."
