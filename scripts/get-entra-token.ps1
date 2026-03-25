param(
    [Parameter(Mandatory = $true)]
    [string]$TenantId,

    [Parameter(Mandatory = $true)]
    [string]$ClientId,

    [switch]$UseDeviceCode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI (az) is not installed. Install it first, then rerun this script."
}

$scope = "api://$ClientId/access_as_user"

$loginArgs = @(
    "login",
    "--tenant", $TenantId,
    "--scope", $scope
)

if ($UseDeviceCode) {
    $loginArgs += "--use-device-code"
}

& az @loginArgs | Out-Null
az account get-access-token `
    --tenant $TenantId `
    --scope $scope `
    --query "{accessToken:accessToken, expiresOn:expiresOn, tenant:tenant}" `
    -o json
