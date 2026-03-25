param(
    [Parameter(Mandatory = $true)]
    [string]$TenantId,

    [Parameter(Mandatory = $true)]
    [string]$ClientId,

    [switch]$UseDeviceCode,

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
$loginMode = if ($UseDeviceCode) { "device-code" } else { "interactive" }
$commandArgs = @(
    $clientScript,
    "get-token",
    "--tenant-id", $TenantId,
    "--client-id", $ClientId,
    "--login-mode", $loginMode
)

if ($Scope) {
    $commandArgs += @("--scope", $Scope)
}

& $python @commandArgs
exit $LASTEXITCODE
