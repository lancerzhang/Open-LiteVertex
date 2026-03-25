param(
    [Parameter(Mandatory = $true)]
    [string]$BaseUrl,

    [Parameter(Mandatory = $true)]
    [string]$MasterKey,

    [string]$UserId = "opencode-demo-user",

    [string]$KeyAlias = "opencode-demo-key",

    [string[]]$Models = @(
        "vertex-gemini-2.5-flash",
        "vertex-gemini-2.5-flash-lite",
        "vertex-gemini-2.5-pro"
    )
)

$body = @{
    user_id = $UserId
    key_alias = $KeyAlias
    max_budget = 50
    budget_duration = "7d"
    models = $Models
} | ConvertTo-Json -Depth 6

Invoke-RestMethod `
    -Method Post `
    -Uri "$BaseUrl/key/generate" `
    -Headers @{ Authorization = "Bearer $MasterKey" } `
    -ContentType "application/json" `
    -Body $body

