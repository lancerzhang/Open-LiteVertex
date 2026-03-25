[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Args
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$demoEnvFile = Join-Path $root ".demo.env"
$entraEnvFile = Join-Path $root ".entra.env"
$configFile = Join-Path $root "opencode.json"
$installScript = Join-Path $PSScriptRoot "install-opencode-entra-plugin.ps1"

if (-not (Test-Path $demoEnvFile)) {
    throw "Missing .demo.env. Run scripts\deploy-demo.ps1 first."
}

foreach ($envFile in @($demoEnvFile, $entraEnvFile)) {
    if (-not (Test-Path $envFile)) {
        continue
    }
    foreach ($line in Get-Content $envFile) {
        if ($line -match "^(.*?)=(.*)$") {
            Set-Item -Path Env:$($matches[1]) -Value $matches[2]
        }
    }
}

if (-not $env:LITELLM_BASE_URL) {
    throw "LITELLM_BASE_URL is missing from .demo.env."
}

foreach ($requiredVar in @("ENTRA_TENANT_ID", "ENTRA_CLIENT_ID", "ENTRA_PUBLIC_CLIENT_ID")) {
    if (-not (Get-Item -Path "Env:$requiredVar" -ErrorAction SilentlyContinue)) {
        throw "$requiredVar is required. Create .entra.env or export it before starting OpenCode."
    }
}

& $installScript

$env:OPENCODE_CONFIG = $configFile
$env:ENTRA_ENV_PATH = $entraEnvFile
$env:LITELLM_OPENAI_BASE_URL = $env:LITELLM_BASE_URL.TrimEnd("/") + "/v1"
if (-not $env:LITELLM_API_KEY) {
    $env:LITELLM_API_KEY = "opencode-entra-plugin-placeholder"
}
if (Get-Item -Path Env:ENTRA_OPENCODE_PLUGIN_DISABLED -ErrorAction SilentlyContinue) {
    Remove-Item -Path Env:ENTRA_OPENCODE_PLUGIN_DISABLED
}

$cmd = Get-Command opencode -ErrorAction SilentlyContinue
if ($null -eq $cmd) {
    throw "opencode is not installed. Install it first, for example: npm install -g opencode-ai"
}

Push-Location $root
try {
    & $cmd.Source @Args
} finally {
    Pop-Location
}
