[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$sourceFile = Join-Path $root "plugins\entra-litellm-auth.ts"
$configSourceFile = Join-Path $root "config\opencode.global.json"
$configDir = Join-Path $HOME ".config\opencode"
$targetDir = Join-Path $configDir "plugins"
$targetFile = Join-Path $targetDir "entra-litellm-auth.ts"
$globalConfigFile = Join-Path $configDir "opencode.json"
$globalCacheFile = Join-Path $configDir "entra-device-token.json"
$legacyCacheFile = Join-Path $root ".secrets\entra-device-token.json"

if (-not (Test-Path $sourceFile)) {
    throw "Missing plugin source: $sourceFile"
}

if (-not (Test-Path $configSourceFile)) {
    throw "Missing global config template: $configSourceFile"
}

New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
Copy-Item -Path $sourceFile -Destination $targetFile -Force

$template = Get-Content $configSourceFile -Raw | ConvertFrom-Json -AsHashtable
$current = if (Test-Path $globalConfigFile) {
    Get-Content $globalConfigFile -Raw | ConvertFrom-Json -AsHashtable
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

$current | ConvertTo-Json -Depth 100 | Set-Content -Path $globalConfigFile -Encoding UTF8

if (-not (Test-Path $globalCacheFile) -and (Test-Path $legacyCacheFile)) {
    Copy-Item -Path $legacyCacheFile -Destination $globalCacheFile -Force
}
