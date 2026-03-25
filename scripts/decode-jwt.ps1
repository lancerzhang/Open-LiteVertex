param(
    [Parameter(Mandatory = $true)]
    [string]$Token
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Convert-Base64UrlToJson([string]$Segment) {
    $padded = $Segment.Replace('-', '+').Replace('_', '/')
    switch ($padded.Length % 4) {
        2 { $padded += "==" }
        3 { $padded += "=" }
    }

    $bytes = [Convert]::FromBase64String($padded)
    $json = [System.Text.Encoding]::UTF8.GetString($bytes)
    return $json | ConvertFrom-Json
}

$parts = $Token.Split(".")
if ($parts.Length -lt 2) {
    throw "Token does not look like a JWT."
}

[PSCustomObject]@{
    header  = Convert-Base64UrlToJson -Segment $parts[0]
    payload = Convert-Base64UrlToJson -Segment $parts[1]
} | ConvertTo-Json -Depth 20
