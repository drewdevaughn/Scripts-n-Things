<#
.SYNOPSIS
    Enables Windows Sandbox with comprehensive pre-flight diagnostics.
.DESCRIPTION
    Checks OS build, edition, virtualization, RAM, nested-VM status,
    feature state, and Group Policy before enabling Windows Sandbox.
.PARAMETER Force
    Skip interactive prompts and continue on warnings.
.PARAMETER Diagnose
    Run checks only — do not enable the feature.
#>
param(
    [switch]$Force,
    [switch]$Diagnose
)

$ErrorActionPreference = "Stop"

# ---------- helpers ----------
function Deny($msg) {
    Write-Host "[FAIL] $msg" -ForegroundColor Red
    return $false
}
function Warn($msg) { Write-Host "[WARN] $msg" -ForegroundColor Yellow }
function Pass($msg)  { Write-Host "[PASS] $msg" -ForegroundColor Green }
function Info($msg)  { Write-Host "[INFO] $msg" -ForegroundColor Cyan }

function Test-LocalAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = [Security.Principal.WindowsPrincipal]$id
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]"Administrator")
}

function Test-Interactive {
    return [Environment]::UserInteractive -and
           ($Host.Name -ne "ServerRemoteHost" -or $Host.Runspace.ApartmentState -eq "STA")
}

# ---------- admin ----------
if (-not (Test-LocalAdmin)) {
    if ($Diagnose) {
        Warn "Diagnose mode — admin rights not required for read-only checks."
    } else {
        Deny "This script must be run as Administrator."; exit 1
    }
}

# ---------- results ----------
$allPassed = $true

# 1. OS build version (Sandbox needs Win10 18305+ or Win11)
$os = Get-CimInstance Win32_OperatingSystem
$build = [int]$os.BuildNumber

# Simplified check: Build >= 18305 is required.
$buildOk = $build -ge 18305
if (-not $buildOk) {
    Deny "Build $build is too old. Windows Sandbox requires build 18305+ (Win10 19H1 / Win11). Current: $($os.Caption) (build $build)"
    $allPassed = $false
} else {
    Pass "Build $build meets minimum requirement (>= 18305)."
}

# 2. Edition
$caption = $os.Caption
$supportedEditions = @("Pro", "Enterprise", "Education")
$editionOk = ($supportedEditions | Where-Object { $caption -match $_ }) -ne $null
if (-not $editionOk) {
    Warn "'$caption' is not officially supported. Requires Pro, Enterprise, or Education."
    if (-not $Force -and (Test-Interactive)) {
        $c = Read-Host "Continue anyway? (y/N)"; if ($c -ne "y") { exit 0 }
    }
} else {
    Pass "Edition: $caption"
}

# 3. Virtualization (HypervisorPresent)
$cs = Get-CimInstance Win32_ComputerSystem -Property HypervisorPresent
if (-not $cs.HypervisorPresent) {
    Warn "Hardware virtualization not detected (HypervisorPresent=false)."
    Deny "Enable VT-x/AMD-V + SLAT in BIOS/UEFI. Also ensure 'Virtualization Technology' is on."
    $allPassed = $false
} else {
    Pass "Hardware virtualization detected."
}

# 4. Check nested virtualization scenario
try {
    $vmDetect = Get-CimInstance Win32_ComputerSystem -Property Model, Manufacturer
    $inVM = ($vmDetect.Manufacturer -match "VMware|VirtualBox|Microsoft|Xen|QEMU|Parallels") -or
            ($vmDetect.Model -match "VirtualBox|VMware|Virtual")
    if ($inVM) {
        Warn "Running inside a virtual machine. Nested virtualization must be enabled on the hypervisor host."
        # Nested VT on Hyper-V: Set-VMProcessor -VMName <name> -ExposeVirtualizationExtensions $true
        # We can't fix this from inside the guest, so just warn.
    }
} catch { }

# 5. RAM check
$osFreeMB = [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1024, 1)
$suggestedMB = 4096
if ($osFreeMB -lt $suggestedMB) {
    Warn "Low available RAM: ${osFreeMB}MB free. Sandbox allocates ${suggestedMB}MB by default — host may become unresponsive."
} else {
    Pass "Free RAM: ${osFreeMB}MB (≥ ${suggestedMB}MB recommended)."
}

# 6. Hyper-V / Virtual Machine Platform feature state
$features = @(
    @{ Name = "Microsoft-Hyper-V";            Label = "Hyper-V Platform" },
    @{ Name = "VirtualMachinePlatform";        Label = "Virtual Machine Platform" },
    @{ Name = "Containers-DisposableClientVM"; Label = "Windows Sandbox" }
)
$anyMissing = $false
foreach ($f in $features) {
    $state = Get-WindowsOptionalFeature -Online -FeatureName $f.Name -ErrorAction SilentlyContinue
    if ($state -and $state.State -eq "Enabled") {
        Pass "$($f.Label) [$($f.Name)] is enabled."
    } elseif ($state -and $state.State -eq "EnablePending") {
        Warn "$($f.Label) [$($f.Name)] — enabled pending reboot."
    } else {
        Warn "$($f.Label) [$($f.Name)] is NOT enabled."
        $anyMissing = $true
    }
}

# 7. Group Policy check
try {
    $gpoPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Sandbox"
    if (Test-Path $gpoPath) {
        $val = (Get-ItemProperty -Path $gpoPath -Name "AllowSandbox" -ErrorAction SilentlyContinue).AllowSandbox
        if ($val -eq 0) {
            Deny "Group Policy blocks Windows Sandbox (AllowSandbox=0). Check GPO or registry: $gpoPath"
            $allPassed = $false
        } elseif ($val -eq 1) {
            Pass "Group Policy allows Windows Sandbox."
        }
    } else {
        Pass "No Group Policy restriction on Windows Sandbox (key absent)."
    }
} catch { Warn "Could not read Sandbox GP policy (non-fatal)." }

# 8. Check for pending reboot
$rebootRequired = $false
$pend = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
if ($pend.PendingFileRenameOperations -and $pend.PendingFileRenameOperations.Count -gt 0) { $rebootRequired = $true }
try {
    $cb = Get-WURebootStatus -ErrorAction SilentlyContinue
    if ($cb -and $cb.RebootRequired) { $rebootRequired = $true }
} catch { }
try {
    $wsus = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update" -Name RebootRequired -ErrorAction SilentlyContinue
    if ($wsus) { $rebootRequired = $true }
} catch { }
if ($rebootRequired) {
    Warn "A system reboot is pending. Windows Sandbox may not start until after reboot."
} else {
    Pass "No pending reboot detected."
}

# ---------- summary ----------
Write-Host ""
if ($allPassed) {
    Info "All critical checks passed."
} else {
    Warn "Some critical checks failed — sandbox may not start. Review [FAIL] items above."
}

# ---------- exit early in diagnose mode ----------
if ($Diagnose) {
    Write-Host "`nDiagnose mode: no changes made." -ForegroundColor Cyan; exit 0
}

# ---------- enable sandbox ----------
$isEnabled = (Get-WindowsOptionalFeature -Online -FeatureName "Containers-DisposableClientVM").State -eq "Enabled"
if ($isEnabled) {
    Info "Windows Sandbox is already enabled."
    $needsReboot = (Get-WindowsOptionalFeature -Online -FeatureName "Containers-DisposableClientVM").State -eq "EnablePending"
} else {
    Write-Host "`nEnabling Windows Sandbox..." -ForegroundColor Cyan
    $result = dism /online /Enable-Feature /FeatureName:"Containers-DisposableClientVM" /All /NoRestart /Quiet
    if ($LASTEXITCODE -ne 0) {
        try {
            Enable-WindowsOptionalFeature -Online -FeatureName "Containers-DisposableClientVM" -All -NoRestart -ErrorAction Stop
        } catch {
            Deny "Failed to enable Windows Sandbox: $_"; exit 1
        }
    }
    $needsReboot = $true
    Info "Windows Sandbox enabled. A reboot is required."
}

if ($needsReboot) {
    Write-Host "`nA reboot is required for the change to take effect." -ForegroundColor Yellow
    if (Test-Interactive) {
        $choice = Read-Host "Reboot now? (y/N)"
        if ($choice -eq "y") { Restart-Computer -Confirm:$false }
    }
}
