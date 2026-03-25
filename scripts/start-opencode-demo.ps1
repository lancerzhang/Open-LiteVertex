param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Args
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$envFile = Join-Path $root ".demo.env"

if (-not (Test-Path $envFile)) {
    throw "Missing .demo.env. Run scripts\\deploy-demo.ps1 first."
}

foreach ($line in Get-Content $envFile) {
    if ($line -match "^(.*?)=(.*)$") {
        Set-Item -Path Env:$($matches[1]) -Value $matches[2]
    }
}

if (-not $env:LITELLM_BASE_URL) {
    throw "LITELLM_BASE_URL is missing from .demo.env."
}

$env:LITELLM_OPENAI_BASE_URL = $env:LITELLM_BASE_URL.TrimEnd("/") + "/v1"

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
