param(
    [Parameter(Mandatory = $true)]
    [string]$BaseUrl,

    [Parameter(Mandatory = $true)]
    [string]$MasterKey,

    [Parameter(Mandatory = $true)]
    [string]$GroupId,

    [string[]]$Models = @(
        "vertex-gemini-2.5-flash",
        "vertex-gemini-2.5-flash-lite",
        "vertex-gemini-2.5-pro"
    )
)

$body = @{
    team_id = $GroupId
    team_alias = $GroupId
    models = $Models
} | ConvertTo-Json -Depth 6

Invoke-RestMethod `
    -Method Post `
    -Uri "$BaseUrl/team/new" `
    -Headers @{ Authorization = "Bearer $MasterKey" } `
    -ContentType "application/json" `
    -Body $body

