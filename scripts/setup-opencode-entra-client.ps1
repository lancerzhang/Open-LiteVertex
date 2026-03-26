[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Args
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Web.Extensions

function ConvertFrom-JsonCompat {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Json
    )

    $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    return $serializer.DeserializeObject($Json.TrimStart([char]0xFEFF))
}

function Write-Utf8NoBomFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Content
    )

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

$root = Split-Path -Parent $PSScriptRoot
$sourceFile = Join-Path $root "plugins\entra-litellm-auth.ts"
$configSourceFile = Join-Path $root "config\opencode.global.json"
$configDir = Join-Path $HOME ".config\opencode"
$targetDir = Join-Path $configDir "plugins"
$targetFile = Join-Path $targetDir "entra-litellm-auth.ts"
$globalConfigFile = Join-Path $configDir "opencode.json"
$globalCacheFile = Join-Path $configDir "entra-device-token.json"
$legacyCacheFile = Join-Path $root ".secrets\entra-device-token.json"
$authFile = Join-Path $HOME ".local\share\opencode\auth.json"
$mode = "start"
$forceLogin = $false
$opencodeArgs = New-Object System.Collections.Generic.List[string]

foreach ($arg in $Args) {
    if ($opencodeArgs.Count -eq 0 -and $arg -eq "--setup-only") {
        $mode = "setup-only"
        continue
    }
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

if (-not (Test-Path $sourceFile)) {
    throw "Missing plugin source: $sourceFile"
}

if (-not (Test-Path $configSourceFile)) {
    throw "Missing global config template: $configSourceFile"
}

New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
Copy-Item -Path $sourceFile -Destination $targetFile -Force

$template = ConvertFrom-JsonCompat -Json (Get-Content $configSourceFile -Raw)
$current = if (Test-Path $globalConfigFile) {
    ConvertFrom-JsonCompat -Json (Get-Content $globalConfigFile -Raw)
} else {
    @{}
}

$current['$schema'] = $template['$schema']

$enabled = New-Object System.Collections.Generic.List[string]
foreach ($item in @($current['enabled_providers'])) {
    if ($null -ne $item -and -not $enabled.Contains([string]$item)) {
        [void]$enabled.Add([string]$item)
    }
}
foreach ($item in @($template['enabled_providers'])) {
    if ($null -ne $item -and -not $enabled.Contains([string]$item)) {
        [void]$enabled.Add([string]$item)
    }
}
$current['enabled_providers'] = @($enabled)

if (-not $current.ContainsKey('provider') -or $null -eq $current['provider']) {
    $current['provider'] = @{}
}
foreach ($providerId in $template['provider'].Keys) {
    $current['provider'][$providerId] = $template['provider'][$providerId]
}

$current['model'] = $template['model']
$current['small_model'] = $template['small_model']

$json = ($current | ConvertTo-Json -Depth 100) + [Environment]::NewLine
Write-Utf8NoBomFile -Path $globalConfigFile -Content $json

if (-not (Test-Path $globalCacheFile) -and (Test-Path $legacyCacheFile)) {
    Copy-Item -Path $legacyCacheFile -Destination $globalCacheFile -Force
}

if ($mode -eq "setup-only") {
    exit 0
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
