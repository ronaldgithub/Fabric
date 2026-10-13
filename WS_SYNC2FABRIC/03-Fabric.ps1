# Step 3: Fabric workspace on the capacity, connection to Azure SQL, warehouse db1.
# Idempotent: workspace, connection and warehouse are only created when missing.

# Load shared config ($Cfg) and helpers (Invoke-Fabric, Get-FabricItemByName, Get-State/Set-State)
. "$PSScriptRoot\common.ps1"
Write-Host '== 03 Fabric =='
# Step 01 stores the Azure SQL server name and the fabric_reader password in the state file; we need both below.
$state = Get-State
if (-not $state.sqlFqdn) { throw 'Run 01-Azure.ps1 first.' }

# --- Workspace + capacity ---
# Look the workspace up by name first, so a re-run reuses it instead of creating a duplicate.
$ws = Get-FabricItemByName '/workspaces' $Cfg.WorkspaceName
if (-not $ws) { $ws = Invoke-Fabric POST '/workspaces' @{ displayName = $Cfg.WorkspaceName } }
# A new workspace has no compute; assign it to the existing (trial) capacity so items can be created in it.
# Repeating the assignment is harmless.
$cap = (Invoke-Fabric -Path '/capacities').value | Where-Object displayName -eq $Cfg.FabricCapacityName
Invoke-Fabric POST "/workspaces/$($ws.id)/assignToCapacity" @{ capacityId = $cap.id } | Out-Null
# Save the workspace id for later steps and for cleanup.
Set-State 'workspaceId' $ws.id
Write-Host "Workspace $($ws.displayName) $($ws.id)"

# --- Cloud connection to Azure SQL ---
# SQL login with read-only rights; works across tenants (Azure and Fabric are in different tenants,
# so Entra single sign-on is not an option). Created once; the id in the state file marks it as done.
if (-not $state.azureConnId) {
    $conn = Invoke-Fabric POST '/connections' @{
        displayName       = "conn-$($Cfg.ResourceGroup)-azuresql"
        # ShareableCloud = a connection to a public cloud endpoint, no on-premises gateway involved.
        connectivityType  = 'ShareableCloud'
        privacyLevel      = 'Organizational'
        # Which server and database the connection points to (the Azure SQL server from step 01).
        connectionDetails = @{ type = 'SQL'; creationMethod = 'SQL'
            parameters = @(@{ dataType = 'Text'; name = 'server';   value = $state.sqlFqdn },
                           @{ dataType = 'Text'; name = 'database'; value = $Cfg.AzureDbName }) }
        # Basic (SQL) authentication as the fabric_reader user from step 01. skipTestConnection = $false
        # makes Fabric test the login on creation, so a firewall or password problem fails here and not later.
        credentialDetails = @{ singleSignOnType = 'None'; connectionEncryption = 'NotEncrypted'; skipTestConnection = $false
            credentials = @{ credentialType = 'Basic'; username = 'fabric_reader'; password = $state.readerPwd } }
    }
    # Save the connection id so the pipeline in step 04 can refer to it.
    Set-State 'azureConnId' $conn.id
}

# --- Warehouse ---
# Create the warehouse only if it is not there yet. The create call returns no item, so look it up again afterwards.
$wh = Get-FabricItemByName "/workspaces/$($ws.id)/warehouses" $Cfg.WarehouseName
if (-not $wh) {
    Invoke-Fabric POST "/workspaces/$($ws.id)/warehouses" @{ displayName = $Cfg.WarehouseName } | Out-Null
    $wh = Get-FabricItemByName "/workspaces/$($ws.id)/warehouses" $Cfg.WarehouseName
}
# The list result lacks the SQL endpoint, so fetch the full item to get its connection string.
$whd = Invoke-Fabric -Path "/workspaces/$($ws.id)/warehouses/$($wh.id)"
# Save the ids and the SQL endpoint; later steps connect to the warehouse with Invoke-Sqlcmd through it.
Set-State 'warehouseId' $wh.id
Set-State 'warehouseServer' $whd.properties.connectionString
Write-Host "Warehouse $($Cfg.WarehouseName) at $($whd.properties.connectionString)"
