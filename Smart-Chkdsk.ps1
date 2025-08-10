<#
.SYNOPSIS
    Smart CHKDSK - Automated disk error detection and repair scheduling 

.DESCRIPTION
    Scans all local drives for errors and schedules appropriate repairs:
    - System and pagefile drives: Repair scheduled for next system restart & Notification
    - Data drives: Repair scheduled during system idle time via run once, self-removing tasks

.NOTES
    Requires: Administrator privileges
#>

# PRE-FLIGHT CHECKS
#============================================================================

if (-NOT ([System.Security.Principal.WindowsPrincipal][System.Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "This script must be run with Administrator privileges."
    Exit 1
}

Clear-Host

# HELPER FUNCTIONS
#============================================================================

function Get-DrivesThatRequireReboot {
    # Get Windows system drive
    $windowsDrive = $env:SystemDrive
    
    # Get drives with pagefiles
    $pagefileDrives = @()
    try {
        $pagefiles = Get-WmiObject Win32_PageFile -ErrorAction SilentlyContinue
        if ($pagefiles) {
            $pagefileDrives = $pagefiles | ForEach-Object { 
                $_.Name.Substring(0,2).ToUpper() 
            }
        }
    }
    catch {
        Write-Warning "Could not retrieve pagefile information: $_"
    }
    
    # Return unique drives that require reboot for repair
    $rebootDrives = @($windowsDrive) + $pagefileDrives | Select-Object -Unique
    return $rebootDrives
}

function Test-VolumeDirtyBit {
    param([string]$DriveLetter)
    
    $result = fsutil dirty query $DriveLetter 2>&1
    return ($result -match "is Dirty|is set")
}

function New-SelfDestructingChkdskTask {
    param(
        [string]$DriveLetter,
        [string]$TaskName
    )
    
    try {
        # Create run once scheduled task to repair drive
        $taskTemplate = 'schtasks /create /tn "{0}" /tr "cmd /c (chkdsk {1} /f /x) && (schtasks /delete /tn \`"{0}\`" /f)" /sc onidle /i 10 /rl highest /ru SYSTEM /f'
        $taskCommand = $taskTemplate -f $TaskName, $DriveLetter.ToLower()
        
        Write-Host "  Creating scheduled task: $TaskName" -ForegroundColor Gray
        
        $result = Invoke-Expression $taskCommand 2>&1
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  Scheduled task created successfully" -ForegroundColor Green
            return $true
        } else {
            Write-Warning "Failed to create scheduled task $TaskName (Exit code: $LASTEXITCODE)"
            Write-Warning "Error output: $result"
            return $false
        }
    }
    catch {
        Write-Warning "Exception creating scheduled task ${TaskName}: $_"
        return $false
    }
}

# MAIN SCRIPT
#============================================================================

Write-Host "============================================================"
Write-Host "  Smart CHKDSK - Automated disk error detection and repair  "
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "Scanning drives and scheduling repairs based on drive type"
Write-Host "Execution started: $(Get-Date)"
Write-Host ""

# Identify drives that require restart-based repairs
$rebootRequiredDrives = Get-DrivesThatRequireReboot
Write-Host "System/pagefile drives (restart required): $($rebootRequiredDrives -join ', ')" -ForegroundColor Yellow
Write-Host ""

# Initialize tracking arrays
$drivesScheduledForReboot = @()
$drivesScheduledForIdle = @()
$healthyDrives = @()
$failedScheduling = @()

try {
    # Get all local fixed drives
    $drives = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=3"

    if (-not $drives) {
        Write-Warning "No local fixed drives found."
        Exit 0
    }

    # Process each drive
    foreach ($drive in $drives) {
        $driveLetter = $drive.DeviceID.ToUpper()

        Write-Host "------------------------------------------------------------"
        Write-Host "Scanning drive $driveLetter" -ForegroundColor Yellow
        
        # Check if dirty bit is set (repair already scheduled)
        if (Test-VolumeDirtyBit -DriveLetter $driveLetter) {
            Write-Host "-> Drive ${driveLetter}: Repair already scheduled (dirty bit set)" -ForegroundColor Yellow
            continue
        }
        
        # Run read-only scan
        chkdsk $driveLetter | Out-Null
        $exitCode = $LASTEXITCODE
        
        if ($exitCode -eq 0) {
            Write-Host "-> Drive ${driveLetter}: No errors detected" -ForegroundColor Green
            $healthyDrives += $driveLetter
        }
        else {
            Write-Host "-> Drive ${driveLetter}: Errors detected (Exit Code: $exitCode)" -ForegroundColor Red
            
            # Determine repair scheduling method
            if ($driveLetter -in $rebootRequiredDrives) {
                # System/swap drives require restart-based repair
                Write-Host "-> Scheduling restart-based repair for $driveLetter" -ForegroundColor Magenta
                
                # Schedule the repair
                echo 'Y' | chkdsk $driveLetter /f | Out-Null
                
                # CRITICAL: Ensure Windows will actually run chkdsk at boot
                & chkntfs /c $driveLetter | Out-Null
                
                # Set dirty bit to prevent future popups
                fsutil dirty set $driveLetter | Out-Null
                
                Write-Host "-> Repair scheduled for next system restart" -ForegroundColor Green
                $drivesScheduledForReboot += $driveLetter
            }
            else {
                # Data drives can be repaired during idle time
                Write-Host "-> Scheduling idle-time repair for $driveLetter" -ForegroundColor Cyan
                $taskName = "ChkdskRepair_$($driveLetter.Replace(':', ''))"
                
                if (New-SelfDestructingChkdskTask -DriveLetter $driveLetter -TaskName $taskName) {
                    Write-Host "-> Idle-time repair task created" -ForegroundColor Green
                    $drivesScheduledForIdle += $driveLetter
                } else {
                    # Fallback to restart-based repair
                    Write-Host "-> Fallback: Scheduling restart-based repair" -ForegroundColor Yellow
                    echo 'Y' | chkdsk $driveLetter /f | Out-Null
                    & chkntfs /c $driveLetter | Out-Null
                    fsutil dirty set $driveLetter | Out-Null
                    $drivesScheduledForReboot += $driveLetter
                    $failedScheduling += $driveLetter
                }
            }
        }
    }
}
catch {
    Write-Error "Script execution error: $_"
    Exit 1
}

# FINAL SUMMARY AND USER NOTIFICATION
#============================================================================

Write-Host ""
Write-Host "============================================================"
Write-Host "                    EXECUTION SUMMARY"
Write-Host "============================================================" -ForegroundColor Cyan

if ($healthyDrives.Count -gt 0) {
    Write-Host "`nHealthy drives:" -ForegroundColor Green
    $healthyDrives | ForEach-Object { Write-Host " - $_" }
}

if ($drivesScheduledForIdle.Count -gt 0) {
    Write-Host "`nIdle-time repair tasks created:" -ForegroundColor Cyan
    $drivesScheduledForIdle | ForEach-Object { Write-Host " - $_" }
    Write-Host "-> Will execute automatically after 10 minutes of system idle time" -ForegroundColor Gray
    Write-Host "-> Tasks will remove themselves upon completion" -ForegroundColor Gray
}

if ($failedScheduling.Count -gt 0) {
    Write-Host "`nTask creation failures (fallback to restart-based repair):" -ForegroundColor Yellow
    $failedScheduling | ForEach-Object { Write-Host " - $_" }
}

# Handle restart notification
if ($drivesScheduledForReboot.Count -gt 0) {
    Write-Host "`nRestart-based repairs scheduled:" -ForegroundColor Red
    $drivesScheduledForReboot | ForEach-Object { Write-Host " - $_" }
    Write-Host "`nSystem restart required to execute repairs" -ForegroundColor Yellow
    
    # Display notification for restart-required drives
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $driveList = $drivesScheduledForReboot -join ", "
        $message = "Disk errors detected on: $driveList`n`nRepairs have been scheduled for the next system restart.`n`nPlease save your work and restart your computer to complete the repairs."
        
        if ($drivesScheduledForIdle.Count -gt 0) {
            $idleList = $drivesScheduledForIdle -join ", "
            $message += "`n`nNote: Repairs for drive(s) $idleList will execute automatically during idle time."
        }
        
        [System.Windows.Forms.MessageBox]::Show($message, "System Restart Required", "OK", "Warning") | Out-Null
    }
    catch {
        Write-Warning "Could not display notification dialog"
    }
} else {
    Write-Host "`nNo system restart required" -ForegroundColor Green
    if ($drivesScheduledForIdle.Count -gt 0) {
        Write-Host "All repairs will execute automatically during idle time" -ForegroundColor Green
    }
}

# Display task management information
if ($drivesScheduledForIdle.Count -gt 0) {
    Write-Host "`nScheduled tasks created:" -ForegroundColor Cyan
    foreach ($drive in $drivesScheduledForIdle) {
        $taskName = "ChkdskRepair_$($drive.Replace(':', ''))"
        Write-Host " - $taskName" -ForegroundColor Gray
    }
    Write-Host "`nTask management commands:" -ForegroundColor DarkGray
    Write-Host "  List:   schtasks /query | findstr ChkdskRepair" -ForegroundColor DarkGray
    Write-Host "  View:   schtasks /query /tn `"TaskName`" /v" -ForegroundColor DarkGray
    Write-Host "  Delete: schtasks /delete /tn `"TaskName`" /f" -ForegroundColor DarkGray
}

Write-Host "`nExecution completed: $(Get-Date)" -ForegroundColor Gray
Write-Host "============================================================"

Exit 0
