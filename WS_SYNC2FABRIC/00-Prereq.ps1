# Step 0: check prerequisites. Read-only.
# Nothing is created or changed in Azure, Fabric or SQL Server; the only side effect is
# selecting the configured subscription as the active az CLI subscription.

# Load shared config ($Cfg) and helpers (Invoke-Fabric, etc.)
. "$PSScriptRoot\common.ps1"

Write-Host '== 00 Prereq =='

# --- Local tooling ---
# az CLI is used for Azure resources and for fetching Entra tokens; SqlServer module provides Invoke-Sqlcmd.
if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Azure CLI (az) not found.' }
if (-not (Get-Module -ListAvailable SqlServer)) { throw 'Install-Module SqlServer' }
Write-LogValue 'az executable' $global:FabricDemoAz
Write-LogValue 'SqlServer module version' ((Get-Module -ListAvailable SqlServer | Select-Object -First 1).Version.ToString())

# --- Azure login and subscription ---
# 'az account show' fails when there is no cached login; stdout is discarded, stderr is silenced.
az account show -o none 2>$null
if ($LASTEXITCODE -ne 0) { throw 'Not logged in. Run: az login' }
# Make the configured subscription the active one for all later steps.
az account set --subscription $Cfg.SubscriptionName
if ($LASTEXITCODE -ne 0) { throw "Subscription '$($Cfg.SubscriptionName)' not found." }
Write-Host "Subscription : $(az account show --query name -o tsv)"
Write-Host "User         : $(az account show --query user.name -o tsv)"

# --- Config sanity checks ---
if (-not $Cfg.FabricCapacityName) { throw 'Set FabricCapacityName in config.ps1' }
# The local copy is optional: without a gateway connection, step 04 skips the local SQL Server part.
if (-not $Cfg.LocalConnectionId)  { Write-Warning 'LocalConnectionId empty: step 04 (local copy via gateway) will be skipped.' }

# --- Fabric access ---
# Calls the Fabric REST API with the Fabric tenant account (separate from the Azure subscription login)
# and checks that the configured trial capacity is visible to that account.
$cap = (Invoke-Fabric -Path '/capacities').value | Where-Object displayName -eq $Cfg.FabricCapacityName
if (-not $cap) { throw "Fabric capacity '$($Cfg.FabricCapacityName)' not visible to you." }
Write-Host "Capacity     : $($cap.displayName) ($($cap.sku), $($cap.state))"
Write-LogValue 'capacity' $cap

# --- Local SQL Server ---
# Connectivity test against the on-premises instance (the source for the local copy);
# prints only the first line of @@VERSION.
Invoke-LocalSql -Query 'SELECT @@VERSION AS v' | Select-Object -ExpandProperty v | Select-Object -First 1
Write-Host 'Prereq OK'
