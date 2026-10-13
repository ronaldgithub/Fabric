# Copy to config.ps1 (git-ignored) and adjust. No secrets in this file.
$Cfg = @{
    SubscriptionName   = 'opendata'                # az subscription name or id
    Location           = 'westeurope'
    ResourceGroup      = 'rg-fabricdemo'
    SqlServerPrefix    = 'sql-fabricdemo'          # a unique suffix is appended
    AzureDbName        = 'db1'

    LocalSqlInstance   = 'localhost'               # Win10 SQL Server (MSSQLSERVER)
    LocalDbName        = 'db1'

    FabricTenant       = ''                        # tenant id (GUID) of the Fabric account, if different from Azure's
    FabricCapacityName = ''                      # display name of existing trial/F capacity
    WorkspaceName      = 'ws-fabricdemo'
    WarehouseName      = 'db1'

    # One-time manual: connection (via on-prem data gateway) to local SQL, create in Fabric portal
    # Manage connections and gateways > New > On-premises > SQL Server. Paste its GUID here.
    LocalConnectionId  = ''
}
