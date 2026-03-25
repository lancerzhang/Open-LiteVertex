[CmdletBinding(PositionalBinding = $false)]
param(
    [ValidateSet("auto", "device-code", "azure-cli")]
    [string]$AuthMode = "auto",
    [switch]$UseDeviceCode,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Args
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

& $python $clientScript `
    "run-opencode-direct" `
    "--auth-mode" $AuthMode `
    "--login-mode" $loginMode `
    "--" @Args

exit $LASTEXITCODE
