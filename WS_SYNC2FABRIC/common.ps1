# Shared helpers, dot-source from every step: . "$PSScriptRoot\common.ps1"
# Dot-sourcing (leading ". ") runs this file in the caller's scope, so $Cfg, $Root and all
# functions below become available in the step script.

# Turn every error into a terminating error so a failed step stops instead of carrying on.
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true   # stop when az/sqlcmd return a non-zero exit code
$Root = $PSScriptRoot
if (-not (Test-Path "$Root\config.ps1")) { throw "config.ps1 missing. Copy config.example.ps1 to config.ps1 and edit it." }
. "$Root\config.ps1"   # defines $Cfg (subscription, region, names, ...)

# --- Logging ---
# Very verbose run log in logs\ (git-ignored). It deliberately contains SECRETS (passwords, raw
# tokens, connection details) so a DBA can see exactly which values were used. Never share or commit it.
# Run-All.ps1 sets FABRIC_DEMO_LOG once, so all steps of one run write to the same file;
# a step started on its own gets its own file.
$LogDir = Join-Path $Root 'logs'
if (-not $env:FABRIC_DEMO_LOG) {
    New-Item -ItemType Directory -Force $LogDir | Out-Null
    $env:FABRIC_DEMO_LOG = Join-Path $LogDir ("run-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
}

# Helper functions that must not show up as the "location" in a log line.
$script:LogNoise = 'Write-Host', 'Write-Warning', 'Write-LogValue'

# Appends one entry:  time | KIND | file:line | message
# file:line is the first frame outside common.ps1 (the step script that caused the action);
# when the entry is written from a helper in common.ps1 it is followed by "via Function@common.ps1:line".
# Kinds: STEP, CFG, AZ, SQL, REST, STATE, VALUE, DECIDE, INFO, WARN, ERROR.
function Write-Log {
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Message, [string]$Kind = 'INFO')
    try {
        $stack = @(Get-PSCallStack | Select-Object -Skip 1)
        $isCommon = { param($f) $f.ScriptName -and (Split-Path $f.ScriptName -Leaf) -eq 'common.ps1' }
        $outer = $stack | Where-Object { $_.ScriptName -and -not (& $isCommon $_) } | Select-Object -First 1
        $self  = $stack | Select-Object -First 1
        $where = if ($outer) { "$(Split-Path $outer.ScriptName -Leaf):$($outer.ScriptLineNumber)" } else { 'common.ps1' }
        if ($outer -and $self -and (& $isCommon $self) -and ($self.FunctionName -notin $script:LogNoise)) {
            $where += " via $($self.FunctionName)@common.ps1:$($self.ScriptLineNumber)"
        }
        $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
        $lines = $Message -split "\r?\n"
        $out = for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($i -eq 0) { "$ts | $($Kind.PadRight(5)) | $where | $($lines[$i])" } else { "    | $($lines[$i])" }
        }
        Add-Content -Path $env:FABRIC_DEMO_LOG -Value $out -Encoding utf8
    } catch { }   # logging must never break a step
}
# Turns any value into text for the log (objects as compact JSON, long values cut at 20000 chars).
function Format-LogValue($Value) {
    if ($null -eq $Value) { return '<null>' }
    $t = if ($Value -is [string]) { $Value } else { try { $Value | ConvertTo-Json -Depth 6 -Compress } catch { "$Value" } }
    if ($t.Length -gt 20000) { $t = $t.Substring(0, 20000) + "...<cut, $($t.Length) chars>" }
    $t
}
# One "name = value" line, e.g. Write-LogValue 'server' $server
function Write-LogValue([string]$Name, $Value, [string]$Kind = 'VALUE') { Write-Log -Kind $Kind "$Name = $(Format-LogValue $Value)" }
# Result rows of Invoke-Sqlcmd as one compact JSON object per row (DataRow objects are noisy otherwise).
function Format-SqlRows($Rows) {
    @($Rows) | Where-Object { $_ } | ForEach-Object {
        if ($_ -is [System.Data.DataRow]) {
            $o = [ordered]@{}; foreach ($c in $_.Table.Columns) { $o[$c.ColumnName] = $_[$c.ColumnName] }
            $o | ConvertTo-Json -Compress
        } else { "$_" }
    }
}

# Everything printed with Write-Host / Write-Warning is also written to the log.
function Write-Host {
    $parts = @(); $skip = $false
    foreach ($a in $args) {
        if ($skip) { $skip = $false; continue }
        if ($a -is [string] -and $a -match '^-(ForegroundColor|BackgroundColor|Separator)') { $skip = $true; continue }
        if ($a -is [string] -and $a -match '^-NoNewline') { continue }
        $parts += "$a"
    }
    Write-Log -Kind INFO ($parts -join ' ')
    Microsoft.PowerShell.Utility\Write-Host @args
}
function Write-Warning {
    Write-Log -Kind WARN ($args -join ' ')
    Microsoft.PowerShell.Utility\Write-Warning @args
}

# Every az CLI call goes through this wrapper (it shadows the az executable): the full command line,
# stdout (including tokens), stderr, exit code and duration are logged. Behaviour for the caller is
# unchanged: stdout lines are returned, $LASTEXITCODE is set, and a non-zero exit throws.
$global:FabricDemoAz = (Get-Command az -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if ($global:FabricDemoAz) {
    function az {
        $strict = $PSNativeCommandUseErrorActionPreference
        $PSNativeCommandUseErrorActionPreference = $false   # we decide below, after logging
        $ErrorActionPreference = 'Continue'
        $cmd = 'az ' + (($args | ForEach-Object { if ("$_" -match '\s') { "'$_'" } else { "$_" } }) -join ' ')
        Write-Log -Kind AZ "run: $cmd"
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $all = & $global:FabricDemoAz @args 2>&1
        $code = $LASTEXITCODE
        $sw.Stop()
        $stdout = @($all | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
        $stderr = @($all | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { $_.ToString() })
        $msg = "exit=$code elapsed=$($sw.ElapsedMilliseconds)ms`nstdout:`n$($stdout -join "`n")"
        if ($stderr) { $msg += "`nstderr:`n$($stderr -join "`n")" }
        Write-Log -Kind AZ $msg
        foreach ($e in $stderr) { Microsoft.PowerShell.Utility\Write-Host $e -ForegroundColor DarkYellow }
        $global:LASTEXITCODE = $code
        if ($code -ne 0 -and $strict) { throw "az exited with code $code. $($stderr -join ' ')" }
        $stdout
    }
}

# --- State file: generated values (e.g. passwords) shared between steps ---
$SecretsDir = Join-Path $Root '.secrets'      # git-ignored
$StateFile  = Join-Path $SecretsDir 'state.json'

# Returns the saved state as a hashtable, or an empty one when nothing has been saved yet.
function Get-State {
    $s = if (Test-Path $StateFile) { Get-Content $StateFile -Raw | ConvertFrom-Json -AsHashtable } else { @{} }
    Write-Log -Kind STATE "read $StateFile keys: $(($s.Keys | Sort-Object) -join ', ')"
    $s
}
# Read-modify-write a single key. Creates .secrets\ on first use.
function Set-State([string]$Key, $Value) {
    New-Item -ItemType Directory -Force $SecretsDir | Out-Null
    $s = Get-State; $s[$Key] = $Value
    $s | ConvertTo-Json | Set-Content $StateFile
    Write-Log -Kind STATE "write $Key = $(Format-LogValue $Value)"
}

# --- Authentication ---
# Decodes the payload of a JWT access token (who it is for, which tenant, when it expires).
function Get-JwtClaims([string]$Jwt) {
    try {
        $p = $Jwt.Split('.')[1].Replace('-', '+').Replace('_', '/')
        switch ($p.Length % 4) { 2 { $p += '==' } 3 { $p += '=' } }
        [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p)) | ConvertFrom-Json
    } catch { $null }
}

# Gets an Entra access token for $Resource from the az CLI. Used as a Bearer token for REST
# calls and as -AccessToken for Invoke-Sqlcmd, so no passwords or app registrations are needed.
function Get-Token([string]$Resource, [string]$Tenant) {
    # '-o tsv' = plain text without JSON quotes, so the token can be used as-is.
    $a = @('account','get-access-token','--resource',$Resource,'--query','accessToken','-o','tsv')
    # A tenant-level account (no subscriptions) is selected by its tenant id as "subscription";
    # --tenant would pick the wrong cached account and hit an expired refresh token.
    if ($Tenant) { $a += @('--subscription',$Tenant) }
    Write-Log -Kind AZ "Get-Token resource=$Resource subscription/tenant selector=$Tenant"
    $t = az @a   # '@a' splats the array as separate arguments
    if ($LASTEXITCODE -ne 0 -or -not $t) {
        $hint = if ($Tenant) { "az login --tenant $Tenant --allow-no-subscriptions" } else { 'az login' }
        throw "Cannot get token for $Resource. Run: $hint"
    }
    $c = Get-JwtClaims "$t"
    if ($c) {
        $exp = if ($c.exp) { [DateTimeOffset]::FromUnixTimeSeconds([int64]$c.exp).LocalDateTime.ToString('s') } else { '?' }
        Write-Log -Kind VALUE "token claims: aud=$($c.aud) tid=$($c.tid) upn=$($c.upn)$($c.unique_name) appid=$($c.appid) expires=$exp length=$("$t".Length)"
    }
    $t
}
# Fabric (API and warehouse SQL endpoint) may live in a different tenant than the Azure subscription
function Get-FabricToken([string]$Resource = 'https://api.fabric.microsoft.com') { Get-Token $Resource $Cfg.FabricTenant }

# --- Azure helpers ---
function Get-SqlServerName {
    # Deterministic, globally unique-ish name per subscription: prefix + first 6 hex chars of
    # the SHA1 of the subscription id. Same subscription always gives the same name, so re-runs
    # find the server they created earlier.
    $sub = az account show --query id -o tsv
    $hash = [BitConverter]::ToString([Security.Cryptography.SHA1]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($sub))).Replace('-','').Substring(0,6).ToLower()
    $name = "$($Cfg.SqlServerPrefix)-$hash"
    Write-Log -Kind VALUE "Get-SqlServerName: subscription=$sub sha1(first 6)=$hash prefix=$($Cfg.SqlServerPrefix) -> $name"
    $name
}

# --- Fabric REST ---
# Fabric REST. Handles long running operations (202) by polling.
# -Path is relative to https://api.fabric.microsoft.com/v1, e.g. '/workspaces'.
# -Body (hashtable/object) is sent as JSON. Returns the parsed response.
function Invoke-Fabric {
    param([string]$Method = 'GET', [string]$Path, $Body)
    $h = @{ Authorization = "Bearer $(Get-FabricToken)" }
    # ResponseHeadersVariable/StatusCodeVariable fill $rh and $sc so we can see the 202 status
    # and the Location header of a long running operation (LRO).
    $p = @{ Method = $Method; Uri = "https://api.fabric.microsoft.com/v1$Path"; Headers = $h
            ContentType = 'application/json'; ResponseHeadersVariable = 'rh'; StatusCodeVariable = 'sc' }
    if ($Body) { $p.Body = ($Body | ConvertTo-Json -Depth 20) }
    Write-Log -Kind REST "-> $Method $($p.Uri)`nAuthorization: $($h.Authorization)`nbody: $($p.Body)"
    try { $r = Invoke-RestMethod @p }
    catch {
        Write-Log -Kind ERROR "REST failed: $Method $($p.Uri) status=$($_.Exception.Response.StatusCode)`n$($_.ErrorDetails.Message)`n$($_.Exception.Message)"
        throw
    }
    Write-Log -Kind REST "<- status=$sc location=$(if ($rh) { @($rh['Location'])[0] })`nresponse: $(Format-LogValue $r)"
    if ($sc -eq 202 -and $rh['Location']) {
        # 202 Accepted: the work continues in the background. Poll the operation URL until done.
        $loc = @($rh['Location'])[0]
        do {
            Start-Sleep -Seconds 5
            $op = Invoke-RestMethod -Uri $loc -Headers $h
            Write-Host "  ..LRO $($op.status)"
        } while ($op.status -in 'NotStarted','Running')
        Write-Log -Kind REST "LRO finished: $loc`n$(Format-LogValue $op)"
        if ($op.status -ne 'Succeeded') { throw "Fabric operation failed: $($op | ConvertTo-Json -Depth 5)" }
    }
    $r
}

# Finds an item (workspace, warehouse, pipeline, ...) in a list endpoint by display name.
# Returns $null when not found, which is what makes the steps idempotent.
function Get-FabricItemByName([string]$Url, [string]$Name) {
    $item = (Invoke-Fabric -Path $Url).value | Where-Object displayName -eq $Name | Select-Object -First 1
    Write-Log -Kind DECIDE "lookup '$Name' in $Url -> $(if ($item) { "found id=$($item.id)" } else { 'not found' })"
    $item
}

# --- SQL ---
# Runs a query against an Azure SQL / Fabric warehouse endpoint using an Entra token.
# Certificate validation stays on (-TrustServerCertificate:$false) because these are public endpoints.
function Invoke-Sql {
    param([string]$Server, [string]$Database, [string]$Query, [string]$Tenant)
    $token = Get-Token 'https://database.windows.net/' $Tenant
    Write-Log -Kind SQL "-> server=$Server database=$Database auth=EntraToken tenant=$Tenant`n$Query"
    # A paused serverless database needs 30-60+ s to resume, longer than the default 15 s connection
    # timeout ("Connection Timeout Expired ... post-login"). Allow 120 s and retry the connect twice;
    # the first attempt usually wakes the database, so the retry succeeds.
    for ($attempt = 1; ; $attempt++) {
        try {
            $r = Invoke-Sqlcmd -ServerInstance $Server -Database $Database -Query $Query `
                -AccessToken $token -TrustServerCertificate:$false -ConnectionTimeout 120
            break
        } catch {
            $transient = $_.Exception.Message -match 'Timeout Expired|40613|40197|40501|not currently available'
            Write-Log -Kind WARN "attempt $attempt failed (transient=$transient): $($_.Exception.Message)"
            if (-not $transient -or $attempt -ge 3) { throw }
            Write-Host "  database not ready (resuming?), retry $attempt/2 in 20 s"
            Start-Sleep -Seconds 20
        }
    }
    $rows = @(Format-SqlRows $r)
    Write-Log -Kind SQL "<- rows=$($rows.Count)$(if ($rows) { "`n" + ($rows -join "`n") })"
    $r
}

# Same for the local SQL Server instance (Windows authentication, self-signed certificate accepted).
function Invoke-LocalSql {
    param([string]$Query, [string]$Database)
    $p = @{ ServerInstance = $Cfg.LocalSqlInstance; TrustServerCertificate = $true; Query = $Query }
    if ($Database) { $p.Database = $Database }
    Write-Log -Kind SQL "-> local server=$($Cfg.LocalSqlInstance) database=$Database auth=Windows`n$Query"
    $r = Invoke-Sqlcmd @p
    $rows = @(Format-SqlRows $r)
    Write-Log -Kind SQL "<- rows=$($rows.Count)$(if ($rows) { "`n" + ($rows -join "`n") })"
    $r
}

# Base64 of the UTF-8 text; Fabric item definition parts must be sent base64 encoded.
function ConvertTo-B64([string]$Text) { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text)) }

# --- Run header (once per log file) ---
# Environment and the complete configuration, so the log is understandable on its own.
if ($env:FABRIC_DEMO_LOG_HEADER -ne $env:FABRIC_DEMO_LOG) {
    $env:FABRIC_DEMO_LOG_HEADER = $env:FABRIC_DEMO_LOG
    Write-Log -Kind CFG "log=$env:FABRIC_DEMO_LOG user=$env:USERNAME machine=$env:COMPUTERNAME pwsh=$($PSVersionTable.PSVersion) cwd=$((Get-Location).Path)"
    Write-Log -Kind CFG "config.ps1 `$Cfg = $(Format-LogValue $Cfg)"
}
$caller = if ($MyInvocation.ScriptName) { Split-Path $MyInvocation.ScriptName -Leaf } else { '(interactive session)' }
Write-Log -Kind STEP "start $caller"
