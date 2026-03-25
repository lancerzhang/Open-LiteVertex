[CmdletBinding(PositionalBinding = $false)]
param(
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

if (-not (Test-Path $entraEnvPath)) {
    throw "Missing .entra.env. Run scripts\\setup-entra-oss.ps1 first."
}
if (-not (Test-Path $demoEnvPath)) {
    throw "Missing .demo.env. Run scripts\\deploy-demo.ps1 first."
}

Import-DotEnv -Path $entraEnvPath
Import-DotEnv -Path $demoEnvPath

if (-not $env:ENTRA_TENANT_ID -or -not $env:ENTRA_CLIENT_ID) {
    throw ".entra.env is missing ENTRA_TENANT_ID or ENTRA_CLIENT_ID."
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

$env:ENTRA_ACCESS_TOKEN = $tokenResponse.accessToken
$env:ENTRA_ACCESS_TOKEN_EXPIRES_ON = $tokenResponse.expiresOn
$env:LITELLM_API_KEY = $tokenResponse.accessToken
$env:LITELLM_OPENAI_BASE_URL = $env:LITELLM_BASE_URL.TrimEnd("/") + "/v1"

$cmd = Get-Command opencode -ErrorAction SilentlyContinue
if ($null -eq $cmd) {
    throw "opencode is not installed. Install it first, for example: npm install -g opencode-ai"
}

Write-Host "Using Entra access token directly against LiteLLM."
Write-Host "Token expires on: $($tokenResponse.expiresOn)"

Push-Location $root
try {
    & $cmd.Source @args
} finally {
    Pop-Location
}
