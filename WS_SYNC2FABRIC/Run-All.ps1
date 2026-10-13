# Runs all steps in order. -Cleanup removes everything afterwards (also on failure).
param([switch]$Cleanup, [switch]$DropLocal)
$steps = '00-Prereq','01-Azure','02-Local','03-Fabric','04-Load','05-Transform','06-Verify'
try {
    foreach ($s in $steps) { & "$PSScriptRoot\$s.ps1" }
} finally {
    if ($Cleanup) { & "$PSScriptRoot\99-Cleanup.ps1" -DropLocal:$DropLocal }
}
