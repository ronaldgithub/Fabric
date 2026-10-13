# Step 4: staging tables in warehouse db1, then load both sources into them:
#   Azure SQL  -> stg.Customer_Azure   (PowerShell reads and inserts)
#   Local SQL  -> stg.Customer_Local   (Fabric pipeline via gateway; only when LocalConnectionId is set)
. "$PSScriptRoot\common.ps1"
Write-Host '== 04 Load =='
$state = Get-State
if (-not $state.warehouseServer) { throw 'Run 03-Fabric.ps1 first.' }
$wsId = $state.workspaceId
function Wh([string]$q) { Invoke-Sql $state.warehouseServer $Cfg.WarehouseName $q $Cfg.FabricTenant }

Wh @"
IF SCHEMA_ID('stg') IS NULL EXEC('CREATE SCHEMA stg');
IF SCHEMA_ID('dwh') IS NULL EXEC('CREATE SCHEMA dwh');
IF OBJECT_ID('stg.Customer_Azure') IS NULL CREATE TABLE stg.Customer_Azure (CustomerId int, LastName varchar(100), Initials varchar(10));
IF OBJECT_ID('stg.Customer_Local') IS NULL CREATE TABLE stg.Customer_Local (CustomerId int, LastName varchar(100), Initials varchar(10));
"@

function New-CopyActivity([string]$Name, [string]$SrcType, [string]$SrcDatasetType, [hashtable]$SrcProps, [string]$ConnId, [string]$Table) {
    @{ name = $Name; type = 'Copy'; dependsOn = @()
       typeProperties = @{
           source = @{ type = $SrcType; sqlReaderQuery = 'SELECT CustomerId, LastName, Initials FROM dbo.Customer'
               datasetSettings = @{ type = $SrcDatasetType; typeProperties = $SrcProps; externalReferences = @{ connection = $ConnId } } }
           sink = @{ type = 'DataWarehouseSink'; preCopyScript = "TRUNCATE TABLE stg.$Table"
               datasetSettings = @{ type = 'DataWarehouseTable'; typeProperties = @{ schema = 'stg'; table = $Table }
                   linkedService = @{ name = $Cfg.WarehouseName; properties = @{ type = 'DataWarehouse'
                       typeProperties = @{ artifactId = $state.warehouseId; endpoint = $state.warehouseServer; workspaceId = $wsId } } } } }
           enableStaging = $false } }
}

# Azure SQL -> stg.Customer_Azure: a warehouse COPY cannot read Azure SQL directly (needs a staging store),
# so for this tiny table PowerShell reads the source and inserts the rows itself.
$src = Invoke-Sql $state.sqlFqdn $Cfg.AzureDbName 'SELECT CustomerId, LastName, Initials FROM dbo.Customer'
$vals = ($src | ForEach-Object { "($($_.CustomerId), N'$($_.LastName -replace "'","''")', N'$($_.Initials -replace "'","''")')" }) -join ','
Wh "TRUNCATE TABLE stg.Customer_Azure; INSERT stg.Customer_Azure (CustomerId, LastName, Initials) VALUES $vals;"
Write-Host "Azure rows loaded: $(@($src).Count)"

if (-not $Cfg.LocalConnectionId) { Write-Warning 'LocalConnectionId empty -> local copy skipped.'; return }

# Local SQL -> stg.Customer_Local through the gateway, with a pipeline.
# NOTE: pipeline JSON is the least verified part. A warehouse sink may also need staging enabled for this source;
# if it fails, build the pipeline once in the portal and compare with its definition
# (POST /workspaces/{id}/items/{id}/getDefinition).
$acts = @(New-CopyActivity 'CopyLocal' 'SqlServerSource' 'SqlServerTable' @{ database = $Cfg.LocalDbName } $Cfg.LocalConnectionId 'Customer_Local')

$pipeName = 'pl_load_customers'
$pj  = @{ properties = @{ activities = $acts } } | ConvertTo-Json -Depth 20
$def = @{ parts = @(@{ path = 'pipeline-content.json'; payload = (ConvertTo-B64 $pj); payloadType = 'InlineBase64' }) }
$pipe = Get-FabricItemByName "/workspaces/$wsId/dataPipelines" $pipeName
if (-not $pipe) {
    Invoke-Fabric POST "/workspaces/$wsId/dataPipelines" @{ displayName = $pipeName; definition = $def } | Out-Null
    $pipe = Get-FabricItemByName "/workspaces/$wsId/dataPipelines" $pipeName
} else {
    Invoke-Fabric POST "/workspaces/$wsId/dataPipelines/$($pipe.id)/updateDefinition" @{ definition = $def } | Out-Null
}

$h = @{ Authorization = "Bearer $(Get-FabricToken)" }
$null = Invoke-RestMethod -Method POST -Headers $h -ResponseHeadersVariable rh `
    -Uri "https://api.fabric.microsoft.com/v1/workspaces/$wsId/items/$($pipe.id)/jobs/instances?jobType=Pipeline"
$loc = @($rh['Location'])[0]
do { Start-Sleep 10; $j = Invoke-RestMethod -Uri $loc -Headers $h; Write-Host "  pipeline: $($j.status)" } while ($j.status -in 'NotStarted','InProgress')
if ($j.status -ne 'Completed') { throw "Pipeline ended as $($j.status): $($j.failureReason | ConvertTo-Json -Depth 5)" }
Write-Host 'Sources loaded into stg.'
