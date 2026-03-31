param(
    [string]$TenantId,
    [string]$ApiAppName = "opencode-vertex-gateway-api",
    [string]$PublicClientAppName = "opencode-vertex-gateway-public-client",
    [string]$AllowedGroupName = "opencode-users",
    [string[]]$MemberUpns = @(),
    [string]$OutputEnvPath = ".entra.env",
    [switch]$InviteMissingUsers
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Require-AzCli {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw "Azure CLI (az) is not installed. Install it first, then rerun this script."
    }
}

function Get-JsonObject([string]$JsonText) {
    if (-not $JsonText) {
        return $null
    }

    $trimmed = $JsonText.Trim()
    if (-not $trimmed -or $trimmed -eq "null" -or $trimmed -eq "[]") {
        return $null
    }

    return $trimmed | ConvertFrom-Json
}

function Get-MailNickname([string]$Name) {
    $nickname = ($Name -replace "[^A-Za-z0-9]", "").ToLowerInvariant()
    if (-not $nickname) {
        $nickname = "opencodeusers"
    }
    return $nickname
}

function Invoke-AzOptional([scriptblock]$Action) {
    $hasNativePreference = Test-Path variable:global:PSNativeCommandUseErrorActionPreference
    if ($hasNativePreference) {
        $previousPreference = $global:PSNativeCommandUseErrorActionPreference
    }
    try {
        if ($hasNativePreference) {
            $global:PSNativeCommandUseErrorActionPreference = $false
        }
        try {
            $output = & $Action 2>$null
        } catch {
            return $null
        }
        if ($LASTEXITCODE -ne 0) {
            return $null
        }
        if ($output -is [System.Array]) {
            return ($output -join "`n").Trim()
        }
        return [string]$output
    } finally {
        if ($hasNativePreference) {
            $global:PSNativeCommandUseErrorActionPreference = $previousPreference
        }
    }
}

function Invoke-AzRestJson([string]$Method, [string]$Uri, [string]$Body, [string]$Query = "") {
    $tempFile = [System.IO.Path]::GetTempFileName()
    try {
        Set-Content -Path $tempFile -Value $Body -NoNewline -Encoding UTF8

        $arguments = @(
            "rest",
            "--method", $Method,
            "--uri", $Uri,
            "--headers", "Content-Type=application/json",
            "--body", "@$tempFile"
        )

        if ($Query) {
            $arguments += @("--query", $Query)
        }

        $arguments += @("-o", "json")
        return & az @arguments
    } finally {
        Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
    }
}

function Escape-ODataString([string]$Value) {
    return $Value.Replace("'", "''")
}

function New-SecurityGroup([string]$DisplayName) {
    $body = @{
        displayName = $DisplayName
        mailEnabled = $false
        mailNickname = Get-MailNickname -Name $DisplayName
        securityEnabled = $true
    } | ConvertTo-Json -Depth 5 -Compress

    return Invoke-AzRestJson `
        -Method "POST" `
        -Uri "https://graph.microsoft.com/v1.0/groups" `
        -Body $body `
        -Query "{id:id,displayName:displayName}" | ConvertFrom-Json
}

function Invite-GuestUser([string]$EmailAddress) {
    $body = @{
        invitedUserEmailAddress = $EmailAddress
        inviteRedirectUrl = "https://myapplications.microsoft.com/"
        sendInvitationMessage = $true
    } | ConvertTo-Json -Depth 5 -Compress

    $invitation = Invoke-AzRestJson `
        -Method "POST" `
        -Uri "https://graph.microsoft.com/v1.0/invitations" `
        -Body $body | ConvertFrom-Json

    $invitedUserId = $null
    if ($invitation -and $invitation.invitedUser) {
        $invitedUserId = $invitation.invitedUser.id
    }

    if (-not $invitedUserId) {
        throw "Invitation was created, but Microsoft Graph did not return the invited user ID for $EmailAddress."
    }

    return $invitedUserId
}

function Resolve-UserId([string]$Identity, [switch]$InviteIfMissing) {
    $userId = Invoke-AzOptional { az ad user show --id $Identity --query id -o tsv }
    if ($userId) {
        return $userId
    }

    $signedInName = Invoke-AzOptional { az account show --query user.name -o tsv }
    if ($signedInName -and $signedInName.Trim().ToLowerInvariant() -eq $Identity.Trim().ToLowerInvariant()) {
        $userId = Invoke-AzOptional { az ad signed-in-user show --query id -o tsv }
        if ($userId) {
            return $userId
        }
    }

    $escapedIdentity = Escape-ODataString -Value $Identity
    $userId = Invoke-AzOptional {
        az ad user list `
            --filter "mail eq '$escapedIdentity'" `
            --query "[0].id" `
            -o tsv
    }
    if ($userId) {
        return $userId
    }

    if ($InviteIfMissing) {
        Write-Host "User $Identity was not found in the tenant. Inviting as guest..."
        return Invite-GuestUser -EmailAddress $Identity
    }

    throw (
        "User not found: $Identity. If this is a personal/external email address, " +
        "rerun the script with -InviteMissingUsers or use a tenant member UPN."
    )
}

Require-AzCli

if ($TenantId) {
    az login --tenant $TenantId | Out-Null
} else {
    az login | Out-Null
}

$account = az account show -o json | ConvertFrom-Json
$effectiveTenantId = if ($TenantId) { $TenantId } else { $account.tenantId }

$group = Get-JsonObject (
    az ad group list `
        --filter "displayName eq '$AllowedGroupName'" `
        --query "[0].{id:id,displayName:displayName}" `
        -o json
)

if (-not $group) {
    $group = New-SecurityGroup -DisplayName $AllowedGroupName
}

foreach ($upn in $MemberUpns) {
    $userId = Resolve-UserId -Identity $upn -InviteIfMissing:$InviteMissingUsers

    $isMember = az ad group member check `
        --group $group.id `
        --member-id $userId `
        --query value -o tsv

    if ($isMember -ne "true") {
        az ad group member add --group $group.id --member-id $userId
    }
}

$app = Get-JsonObject (
    az ad app list `
        --display-name $ApiAppName `
        --query "[0].{id:id,appId:appId,displayName:displayName,scopes:api.oauth2PermissionScopes}" `
        -o json
)

if (-not $app) {
    $app = az ad app create `
        --display-name $ApiAppName `
        --sign-in-audience AzureADMyOrg `
        --query "{id:id,appId:appId,displayName:displayName,scopes:api.oauth2PermissionScopes}" `
        -o json | ConvertFrom-Json
}

$spId = az ad sp list `
    --filter "appId eq '$($app.appId)'" `
    --query "[0].id" `
    -o tsv

if (-not $spId) {
    $spId = az ad sp create --id $app.appId --query id -o tsv
}

$scopeId = $null
if ($app.scopes) {
    $existingScope = @($app.scopes) | Where-Object { $_.value -eq "access_as_user" } | Select-Object -First 1
    if ($existingScope) {
        $scopeId = $existingScope.id
    }
}
if (-not $scopeId) {
    $scopeId = [Guid]::NewGuid().ToString()
}

$patchBody = @{
    identifierUris = @("api://$($app.appId)")
    groupMembershipClaims = "SecurityGroup"
    api = @{
        requestedAccessTokenVersion = 2
        oauth2PermissionScopes = @(
            @{
                id = $scopeId
                adminConsentDescription = "Allow signed-in users to access the OpenCode Vertex gateway."
                adminConsentDisplayName = "Access OpenCode Vertex gateway"
                isEnabled = $true
                type = "User"
                userConsentDescription = "Allow this application to access the OpenCode Vertex gateway on your behalf."
                userConsentDisplayName = "Access OpenCode Vertex gateway"
                value = "access_as_user"
            }
        )
    }
} | ConvertTo-Json -Depth 20 -Compress

Invoke-AzRestJson `
    -Method "PATCH" `
    -Uri "https://graph.microsoft.com/v1.0/applications/$($app.id)" `
    -Body $patchBody | Out-Null

$publicClientApp = Get-JsonObject (
    az ad app list `
        --display-name $PublicClientAppName `
        --query "[0].{id:id,appId:appId,displayName:displayName}" `
        -o json
)

if (-not $publicClientApp) {
    $publicClientApp = az ad app create `
        --display-name $PublicClientAppName `
        --sign-in-audience AzureADMyOrg `
        --query "{id:id,appId:appId,displayName:displayName}" `
        -o json | ConvertFrom-Json
}

$publicClientPatchBody = @{
    isFallbackPublicClient = $true
    groupMembershipClaims = "SecurityGroup"
    requiredResourceAccess = @(
        @{
            resourceAppId = $app.appId
            resourceAccess = @(
                @{
                    id = $scopeId
                    type = "Scope"
                }
            )
        }
    )
} | ConvertTo-Json -Depth 20 -Compress

Invoke-AzRestJson `
    -Method "PATCH" `
    -Uri "https://graph.microsoft.com/v1.0/applications/$($publicClientApp.id)" `
    -Body $publicClientPatchBody | Out-Null

$publicClientSpId = az ad sp list `
    --filter "appId eq '$($publicClientApp.appId)'" `
    --query "[0].id" `
    -o tsv

if (-not $publicClientSpId) {
    $publicClientSpId = az ad sp create --id $publicClientApp.appId --query id -o tsv
}

$issuer = "https://login.microsoftonline.com/$effectiveTenantId/v2.0"
$jwksUri = "https://login.microsoftonline.com/$effectiveTenantId/discovery/v2.0/keys"
$scope = "api://$($app.appId)/access_as_user"

$lines = @(
    "ENTRA_TENANT_ID=$effectiveTenantId",
    "ENTRA_CLIENT_ID=$($app.appId)",
    "ENTRA_PUBLIC_CLIENT_ID=$($publicClientApp.appId)",
    "ENTRA_ALLOWED_GROUP_ID=$($group.id)",
    "ENTRA_SCOPE=$scope",
    "ENTRA_ISSUER=$issuer",
    "ENTRA_JWKS_URI=$jwksUri",
    "ENTRA_GROUPS_CLAIM=groups"
)

Set-Content -Path $OutputEnvPath -Value ($lines -join "`n") -NoNewline

Write-Host ""
Write-Host "Entra setup completed."
Write-Host "Tenant ID : $effectiveTenantId"
Write-Host "API App ID       : $($app.appId)"
Write-Host "Public Client ID : $($publicClientApp.appId)"
Write-Host "Group ID         : $($group.id)"
Write-Host "Scope            : $scope"
Write-Host "Env file         : $(Resolve-Path $OutputEnvPath)"
