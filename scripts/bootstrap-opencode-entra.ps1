[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Args
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$installScript = Join-Path $PSScriptRoot "setup-opencode-entra-client.ps1"
$authFile = Join-Path $HOME ".local\share\opencode\auth.json"
$mode = "start"
$forceLogin = $false
$opencodeArgs = New-Object System.Collections.Generic.List[string]

foreach ($arg in $Args) {
    if ($opencodeArgs.Count -eq 0 -and $arg -eq "--login-only") {
        $mode = "login-only"
        continue
    }
    if ($opencodeArgs.Count -eq 0 -and $arg -eq "--relogin") {
        $forceLogin = $true
        continue
    }
    [void]$opencodeArgs.Add($arg)
}

function Test-LiteLLMAuth {
    if (-not (Test-Path $authFile)) {
        return $false
    }

    try {
        $payload = Get-Content $authFile -Raw | ConvertFrom-Json
    } catch {
        return $false
    }

    return ($null -ne $payload.litellm)
}

function Invoke-LiteLLMLogin {
    Write-Host "No saved Entra LiteVertex login found. Opening OpenCode provider login..." -ForegroundColor Yellow
    & $cmd.Source "auth" "login"
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}

& $installScript

if (Get-Item -Path Env:ENTRA_OPENCODE_PLUGIN_DISABLED -ErrorAction SilentlyContinue) {
    Remove-Item -Path Env:ENTRA_OPENCODE_PLUGIN_DISABLED
}

$cmd = Get-Command opencode -ErrorAction SilentlyContinue
if ($null -eq $cmd) {
    throw "opencode is not installed. Install it first, for example: npm install -g opencode-ai"
}

if ($mode -eq "login-only") {
    Invoke-LiteLLMLogin
    exit 0
}

if ($forceLogin -or -not (Test-LiteLLMAuth)) {
    Invoke-LiteLLMLogin
}

& $cmd.Source @opencodeArgs
