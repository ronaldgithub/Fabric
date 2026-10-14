# Step 4: staging tables in warehouse db1, then load both sources into them:
#   Azure SQL  -> stg.Customer_Azure   (PowerShell reads and inserts)
#   Local SQL  -> stg.Customer_Local   (Fabric pipeline via gateway; only when LocalConnectionId is set)
# Idempotent: tables are created only when missing and each load truncates its table first.
. "$PSScriptRoot\common.ps1"
Write-Host '== 04 Load =='

# Step 03 stores the warehouse SQL endpoint and the workspace id in the state file.
$state = Get-State
if (-not $state.warehouseServer) { throw 'Run 03-Fabric.ps1 first.' }
$wsId = $state.workspaceId

# Shorthand: run T-SQL on the Fabric warehouse. The Fabric tenant is passed so the token comes
# from the Fabric account, not from the Azure subscription account.
function Wh([string]$q) { Invoke-Sql $state.warehouseServer $Cfg.WarehouseName $q $Cfg.FabricTenant }

# --- Staging tables ---
# stg = raw copies of the sources (landing area), dwh = the enriched result built in step 05.
# EXEC('...') is needed because CREATE SCHEMA must be the only statement in its batch.
# Both staging tables have the same shape; varchar is used because the warehouse sink maps to it.
Wh @"
IF SCHEMA_ID('stg') IS NULL EXEC('CREATE SCHEMA stg');
IF SCHEMA_ID('dwh') IS NULL EXEC('CREATE SCHEMA dwh');
IF OBJECT_ID('stg.Customer_Azure') IS NULL CREATE TABLE stg.Customer_Azure (CustomerId int, LastName varchar(100), Initials varchar(10));
IF OBJECT_ID('stg.Customer_Local') IS NULL CREATE TABLE stg.Customer_Local (CustomerId int, LastName varchar(100), Initials varchar(10));
"@

# Builds one Copy activity for the pipeline JSON: source SQL query -> warehouse staging table.
#   $SrcType / $SrcDatasetType : pipeline source and dataset types (e.g. SqlServerSource / SqlServerTable)
#   $SrcProps                  : dataset properties such as the database name
#   $ConnId                    : id of the Fabric connection (gateway connection for the local server)
#   $Table                     : target table in schema stg
function New-CopyActivity([string]$Name, [string]$SrcType, [string]$SrcDatasetType, [hashtable]$SrcProps, [string]$ConnId, [string]$Table) {
    @{ name = $Name; type = 'Copy'; dependsOn = @()
       typeProperties = @{
           source = @{ type = $SrcType; sqlReaderQuery = 'SELECT CustomerId, LastName, Initials FROM dbo.Customer'
               datasetSettings = @{ type = $SrcDatasetType; typeProperties = $SrcProps; externalReferences = @{ connection = $ConnId } } }
           # preCopyScript empties the table first, so re-running does not duplicate rows.
           sink = @{ type = 'DataWarehouseSink'; preCopyScript = "TRUNCATE TABLE stg.$Table"
               datasetSettings = @{ type = 'DataWarehouseTable'; typeProperties = @{ schema = 'stg'; table = $Table }
                   linkedService = @{ name = $Cfg.WarehouseName; properties = @{ type = 'DataWarehouse'
                       typeProperties = @{ artifactId = $state.warehouseId; endpoint = $state.warehouseServer; workspaceId = $wsId } } } } }
           # Staging on: the warehouse COPY command cannot read a SQL Server source (via gateway) directly
           # ("DataWarehouse Copy Command doesn't support 'Source connector type' as 'SqlServer'"; seen in
           # run of 2026-10-14). The copy goes source -> staging -> warehouse. No stagingSettings given:
           # tries the workspace default; if Fabric rejects that, build the pipeline once in the portal and
           # copy its definition (see NOTE below).
           enableStaging = $true } }
}

# --- Azure SQL -> stg.Customer_Azure ---
# Azure SQL -> stg.Customer_Azure: a warehouse COPY cannot read Azure SQL directly (needs a staging store),
# so for this tiny table PowerShell reads the source and inserts the rows itself.
$src = Invoke-Sql $state.sqlFqdn $Cfg.AzureDbName 'SELECT CustomerId, LastName, Initials FROM dbo.Customer'

# Build "(1, N'Jansen', N'A'),(2, ...)" for one INSERT. A single quote in a value is doubled ('')
# so names such as O'Brien do not break the statement. The N prefix keeps unicode characters.
$vals = ($src | ForEach-Object { "($($_.CustomerId), N'$($_.LastName -replace "'","''")', N'$($_.Initials -replace "'","''")')" }) -join ','
Write-LogValue 'azure source rows' @(Format-SqlRows $src)
Write-LogValue 'INSERT VALUES list' $vals
Wh "TRUNCATE TABLE stg.Customer_Azure; INSERT stg.Customer_Azure (CustomerId, LastName, Initials) VALUES $vals;"
Write-Host "Azure rows loaded: $(@($src).Count)"

# The local part needs an on-premises data gateway connection (LocalConnectionId in config.ps1).
# Without it the script stops here ('return' ends the script), the Azure rows are already loaded.
Write-Log -Kind DECIDE "LocalConnectionId='$($Cfg.LocalConnectionId)' -> $(if ($Cfg.LocalConnectionId) { 'run local copy pipeline' } else { 'skip local copy' })"
if (-not $Cfg.LocalConnectionId) { Write-Warning 'LocalConnectionId empty -> local copy skipped.'; return }

# --- Local SQL -> stg.Customer_Local ---
# Local SQL -> stg.Customer_Local through the gateway, with a pipeline.
# NOTE: pipeline JSON is the least verified part. A warehouse sink may also need staging enabled for this source;
# if it fails, build the pipeline once in the portal and compare with its definition
# (POST /workspaces/{id}/items/{id}/getDefinition).
$acts = @(New-CopyActivity 'CopyLocal' 'SqlServerSource' 'SqlServerTable' @{ database = $Cfg.LocalDbName } $Cfg.LocalConnectionId 'Customer_Local')

# Fabric item definitions are sent as base64-encoded parts; for a pipeline the part is pipeline-content.json.
$pipeName = 'pl_load_customers'
$pj  = @{ properties = @{ activities = $acts } } | ConvertTo-Json -Depth 20
$def = @{ parts = @(@{ path = 'pipeline-content.json'; payload = (ConvertTo-B64 $pj); payloadType = 'InlineBase64' }) }
# Create the pipeline when missing, otherwise overwrite its definition so edits to this script take effect.
Write-LogValue 'pipeline-content.json' $pj
$pipe = Get-FabricItemByName "/workspaces/$wsId/dataPipelines" $pipeName
Write-Log -Kind DECIDE "pipeline '$pipeName': $(if ($pipe) { "exists id=$($pipe.id), updateDefinition" } else { 'missing, create' })"
if (-not $pipe) {
    Invoke-Fabric POST "/workspaces/$wsId/dataPipelines" @{ displayName = $pipeName; definition = $def } | Out-Null
    $pipe = Get-FabricItemByName "/workspaces/$wsId/dataPipelines" $pipeName
} else {
    Invoke-Fabric POST "/workspaces/$wsId/dataPipelines/$($pipe.id)/updateDefinition" @{ definition = $def } | Out-Null
}

# --- Run the pipeline and wait ---
# Start an on-demand run. Invoke-Fabric is not used here because we need the Location header
# of the job instance, which is polled below until the run is no longer queued or running.
$h = @{ Authorization = "Bearer $(Get-FabricToken)" }
$jobUri = "https://api.fabric.microsoft.com/v1/workspaces/$wsId/items/$($pipe.id)/jobs/instances?jobType=Pipeline"
Write-Log -Kind REST "-> POST $jobUri`nAuthorization: $($h.Authorization)"
$null = Invoke-RestMethod -Method POST -Headers $h -ResponseHeadersVariable rh -Uri $jobUri
$loc = @($rh['Location'])[0]
Write-Log -Kind REST "<- job instance location=$loc"
do { Start-Sleep 10; $j = Invoke-RestMethod -Uri $loc -Headers $h; Write-Host "  pipeline: $($j.status)" } while ($j.status -in 'NotStarted','InProgress')
Write-Log -Kind REST "pipeline job result:`n$(Format-LogValue $j)"

# Anything other than 'Completed' (Failed, Cancelled, ...) stops the run with the failure reason.
if ($j.status -ne 'Completed') { throw "Pipeline ended as $($j.status): $($j.failureReason | ConvertTo-Json -Depth 5)" }
Write-Host 'Sources loaded into stg.'
