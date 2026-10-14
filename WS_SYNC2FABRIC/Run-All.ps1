# Runs all steps in order. -Cleanup removes everything afterwards (also on failure).
# Examples:
#   .\Run-All.ps1                      run the demo and keep the result to look at
#   .\Run-All.ps1 -Cleanup             run, then delete the Azure and Fabric resources
#   .\Run-All.ps1 -Cleanup -DropLocal  same, and also drop the local db1 (nothing left behind)
# Every run writes one verbose log, logs\run-<timestamp>.log (contains secrets, git-ignored).
param([switch]$Cleanup, [switch]$DropLocal)

# New log file for this run; common.ps1 creates it and all steps then append to the same file.
$env:FABRIC_DEMO_LOG = $null
. "$PSScriptRoot\common.ps1"
Write-Log -Kind STEP "Run-All parameters: Cleanup=$($Cleanup.IsPresent) DropLocal=$($DropLocal.IsPresent)"
Write-Host "Log file: $env:FABRIC_DEMO_LOG"

# Order matters: each step uses what the previous ones stored in .secrets\state.json.
$steps = '00-Prereq','01-Azure','02-Local','03-Fabric','04-Load','05-Transform','06-Verify'
try {
    # Each step is a separate script. A failing step throws (see common.ps1), which jumps
    # straight to 'finally', so the later steps are skipped.
    foreach ($s in $steps) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Write-Log -Kind STEP "===== begin $s ====="
        & "$PSScriptRoot\$s.ps1"
        Write-Log -Kind STEP "===== end $s ($([int]$sw.Elapsed.TotalSeconds) s) ====="
    }
} catch {
    # Log where it went wrong before cleanup starts, then let the error continue.
    Write-Log -Kind ERROR "step failed: $($_.Exception.Message)`n$($_.InvocationInfo.PositionMessage)`n$($_.ScriptStackTrace)"
    throw
} finally {
    # 'finally' runs after success AND after a failure or Ctrl+C, so -Cleanup never leaves
    # billable resources behind. -DropLocal:$DropLocal passes the switch value on explicitly.
    if ($Cleanup) { & "$PSScriptRoot\99-Cleanup.ps1" -DropLocal:$DropLocal }
    Write-Log -Kind STEP "Run-All finished"
    # Later single-step runs in this shell get their own log file again.
    $env:FABRIC_DEMO_LOG = $null
    $env:FABRIC_DEMO_LOG_HEADER = $null
}
