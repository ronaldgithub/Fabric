# Step 5: run 05-Transform.sql against the warehouse.
# The transformation itself is plain T-SQL kept in a separate file, so it can also be run
# by hand in the Fabric portal or SSMS. This script only sends that file to the warehouse.
. "$PSScriptRoot\common.ps1"

Write-Host '== 05 Transform =='
# Step 03 stores the warehouse SQL endpoint in the state file.
$state = Get-State
if (-not $state.warehouseServer) { throw 'Run 03-Fabric.ps1 first.' }
# -Raw reads the file as one string (not line by line), so it is sent as a single batch.
# The Fabric tenant is passed so the token comes from the Fabric account, not the Azure one.
# Reads stg.Customer_* from step 04 and fully reloads dwh.Customers, so re-running is safe.
Write-LogValue 'staging counts before transform' @(Format-SqlRows (Invoke-Sql $state.warehouseServer $Cfg.WarehouseName 'SELECT ''Azure'' AS src, COUNT(*) AS n FROM stg.Customer_Azure UNION ALL SELECT ''Local'', COUNT(*) FROM stg.Customer_Local' $Cfg.FabricTenant))
Invoke-Sql $state.warehouseServer $Cfg.WarehouseName (Get-Content "$PSScriptRoot\05-Transform.sql" -Raw) $Cfg.FabricTenant
Write-Host 'dwh.Customers loaded.'
