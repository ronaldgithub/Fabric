# Shared helpers, dot-source from every step: . "$PSScriptRoot\common.ps1"
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true   # stop when az/sqlcmd return a non-zero exit code
$Root = $PSScriptRoot
if (-not (Test-Path "$Root\config.ps1")) { throw "config.ps1 missing. Copy config.example.ps1 to config.ps1 and edit it." }
. "$Root\config.ps1"

$SecretsDir = Join-Path $Root '.secrets'      # git-ignored
$StateFile  = Join-Path $SecretsDir 'state.json'

function Get-State {
    if (Test-Path $StateFile) { Get-Content $StateFile -Raw | ConvertFrom-Json -AsHashtable } else { @{} }
}
function Set-State([string]$Key, $Value) {
    New-Item -ItemType Directory -Force $SecretsDir | Out-Null
    $s = Get-State; $s[$Key] = $Value
    $s | ConvertTo-Json | Set-Content $StateFile
}

function Get-Token([string]$Resource, [string]$Tenant) {
    $a = @('account','get-access-token','--resource',$Resource,'--query','accessToken','-o','tsv')
    # A tenant-level account (no subscriptions) is selected by its tenant id as "subscription";
    # --tenant would pick the wrong cached account and hit an expired refresh token.
    if ($Tenant) { $a += @('--subscription',$Tenant) }
    $t = az @a
    if ($LASTEXITCODE -ne 0 -or -not $t) {
        $hint = if ($Tenant) { "az login --tenant $Tenant --allow-no-subscriptions" } else { 'az login' }
        throw "Cannot get token for $Resource. Run: $hint"
    }
    $t
}
# Fabric (API and warehouse SQL endpoint) may live in a different tenant than the Azure subscription
function Get-FabricToken([string]$Resource = 'https://api.fabric.microsoft.com') { Get-Token $Resource $Cfg.FabricTenant }

function Get-SqlServerName {
    # Deterministic, globally unique-ish name per subscription
    $sub = az account show --query id -o tsv
    $hash = [BitConverter]::ToString([Security.Cryptography.SHA1]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($sub))).Replace('-','').Substring(0,6).ToLower()
    "$($Cfg.SqlServerPrefix)-$hash"
}

# Fabric REST. Handles long running operations (202) by polling.
function Invoke-Fabric {
    param([string]$Method = 'GET', [string]$Path, $Body)
    $h = @{ Authorization = "Bearer $(Get-FabricToken)" }
    $p = @{ Method = $Method; Uri = "https://api.fabric.microsoft.com/v1$Path"; Headers = $h
            ContentType = 'application/json'; ResponseHeadersVariable = 'rh'; StatusCodeVariable = 'sc' }
    if ($Body) { $p.Body = ($Body | ConvertTo-Json -Depth 20) }
    $r = Invoke-RestMethod @p
    if ($sc -eq 202 -and $rh['Location']) {
        $loc = @($rh['Location'])[0]
        do {
            Start-Sleep -Seconds 5
            $op = Invoke-RestMethod -Uri $loc -Headers $h
            Write-Host "  ..LRO $($op.status)"
        } while ($op.status -in 'NotStarted','Running')
        if ($op.status -ne 'Succeeded') { throw "Fabric operation failed: $($op | ConvertTo-Json -Depth 5)" }
    }
    $r
}

function Get-FabricItemByName([string]$Url, [string]$Name) {
    (Invoke-Fabric -Path $Url).value | Where-Object displayName -eq $Name | Select-Object -First 1
}

function Invoke-Sql {
    param([string]$Server, [string]$Database, [string]$Query, [string]$Tenant)
    Invoke-Sqlcmd -ServerInstance $Server -Database $Database -Query $Query `
        -AccessToken (Get-Token 'https://database.windows.net/' $Tenant) -TrustServerCertificate:$false
}

function ConvertTo-B64([string]$Text) { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text)) }
