# Step 5: run 05-Transform.sql against the warehouse.
. "$PSScriptRoot\common.ps1"
Write-Host '== 05 Transform =='
$state = Get-State
Invoke-Sql $state.warehouseServer $Cfg.WarehouseName (Get-Content "$PSScriptRoot\05-Transform.sql" -Raw) $Cfg.FabricTenant
Write-Host 'dwh.Customers loaded.'
