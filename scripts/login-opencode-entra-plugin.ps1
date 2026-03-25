[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Args
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script = Join-Path $PSScriptRoot "start-opencode-entra-plugin.ps1"
& $script "providers" "login" "--provider" "litellm" @Args
exit $LASTEXITCODE
