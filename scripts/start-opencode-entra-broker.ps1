[CmdletBinding(PositionalBinding = $false)]
param(
    [int]$Port = 8787,
    [string]$BrokerApiKey = "opencode-local-broker-key",
    [switch]$UseDeviceCode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot

& (Join-Path $PSScriptRoot "start-entra-broker.ps1") `
    -Port $Port `
    -BrokerApiKey $BrokerApiKey `
    -UseDeviceCode:$UseDeviceCode

$env:LITELLM_OPENAI_BASE_URL = "http://127.0.0.1:$Port/v1"
$env:LITELLM_API_KEY = $BrokerApiKey

$cmd = Get-Command opencode -ErrorAction SilentlyContinue
if ($null -eq $cmd) {
    throw "opencode is not installed. Install it first, for example: npm install -g opencode-ai"
}

Push-Location $root
try {
    & $cmd.Source @args
} finally {
    Pop-Location
}
