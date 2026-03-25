[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$sourceFile = Join-Path $root "plugins\entra-litellm-auth.ts"
$configDir = Join-Path $HOME ".config\opencode"
$targetDir = Join-Path $configDir "plugins"
$targetFile = Join-Path $targetDir "entra-litellm-auth.ts"
$globalCacheFile = Join-Path $configDir "entra-device-token.json"
$legacyCacheFile = Join-Path $root ".secrets\entra-device-token.json"

if (-not (Test-Path $sourceFile)) {
    throw "Missing plugin source: $sourceFile"
}

New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
Copy-Item -Path $sourceFile -Destination $targetFile -Force

if (-not (Test-Path $globalCacheFile) -and (Test-Path $legacyCacheFile)) {
    Copy-Item -Path $legacyCacheFile -Destination $globalCacheFile -Force
}
