[CmdletBinding(PositionalBinding = $false)]
param(
    [int]$Port = 8787,
    [string]$BrokerApiKey = "opencode-local-broker-key",
    [string]$Host = "127.0.0.1",
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
    "run-opencode-broker" `
    "--port" $Port `
    "--host" $Host `
    "--broker-api-key" $BrokerApiKey `
    "--login-mode" $loginMode `
    "--" @Args

exit $LASTEXITCODE
