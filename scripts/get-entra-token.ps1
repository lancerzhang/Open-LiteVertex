param(
    [string]$TenantId,

    [string]$ClientId,

    [string]$PublicClientId,

    [string]$Scope
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-PythonCommand {
    $cmd = Get-Command python -ErrorAction SilentlyContinue
    if ($null -eq $cmd) {
        throw "python is not installed or not on PATH."
    }
    return $cmd.Source
}

$python = Get-PythonCommand
$clientScript = Join-Path $PSScriptRoot "entra_client.py"
$commandArgs = @(
    $clientScript,
    "get-token"
)

if ($TenantId) {
    $commandArgs += @("--tenant-id", $TenantId)
}

if ($ClientId) {
    $commandArgs += @("--client-id", $ClientId)
}

if ($PublicClientId) {
    $commandArgs += @("--public-client-id", $PublicClientId)
}

if ($Scope) {
    $commandArgs += @("--scope", $Scope)
}

& $python @commandArgs
exit $LASTEXITCODE
