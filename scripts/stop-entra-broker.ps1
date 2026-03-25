Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$pidFilePath = Join-Path $root ".secrets\\entra-broker.pid"

if (-not (Test-Path $pidFilePath)) {
    Write-Host "No broker PID file found."
    exit 0
}

$brokerPid = Get-Content $pidFilePath | Select-Object -First 1
if (-not $brokerPid) {
    Write-Host "Broker PID file is empty."
    exit 0
}

$process = Get-Process -Id $brokerPid -ErrorAction SilentlyContinue
if ($process) {
    Stop-Process -Id $brokerPid -Force
    Write-Host "Stopped broker PID $brokerPid."
} else {
    Write-Host "Broker process $brokerPid is not running."
}

Remove-Item $pidFilePath -Force -ErrorAction SilentlyContinue
