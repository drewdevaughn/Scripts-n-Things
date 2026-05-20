param(
    [switch]$Force
)

$ErrorActionPreference = "Stop"

# Requires admin
if (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Error "This script must be run as Administrator."
    exit 1
}

# Check edition
$edition = (Get-CimInstance Win32_OperatingSystem).Caption
$supportedEditions = @("Pro", "Enterprise", "Education")
$isSupported = $supportedEditions | Where-Object { $edition -match $_ }
if (-not $isSupported) {
    Write-Warning "Windows Sandbox requires Windows 10/11 Pro, Enterprise, or Education. Current edition: $edition"
    if (-not $Force) {
        $choice = Read-Host "Continue anyway? (y/N)"
        if ($choice -ne "y") { exit 0 }
    }
}

# Check virtualization
$hypervisor = Get-CimInstance Win32_ComputerSystem -Property HypervisorPresent
if (-not $hypervisor.HypervisorPresent) {
    Write-Warning "Virtualization not detected (HypervisorPresent = false). Enable VT-x/AMD-V in BIOS."
    if (-not $Force) {
        $choice = Read-Host "Continue anyway? (y/N)"
        if ($choice -ne "y") { exit 0 }
    }
}

Write-Host "Enabling Windows Sandbox..." -ForegroundColor Cyan

# Enable via DISM (works offline and online)
$result = dism /online /Enable-Feature /FeatureName:"Containers-DisposableClientVM" /All /NoRestart

if ($LASTEXITCODE -ne 0) {
    # Fallback: try Enable-WindowsOptionalFeature
    try {
        Enable-WindowsOptionalFeature -Online -FeatureName "Containers-DisposableClientVM" -All -NoRestart -ErrorAction Stop
    } catch {
        Write-Error "Failed to enable Windows Sandbox: $_"
        exit 1
    }
}

Write-Host "Windows Sandbox enabled successfully." -ForegroundColor Green
Write-Host "A reboot is required for the change to take effect." -ForegroundColor Yellow

$choice = Read-Host "Reboot now? (y/N)"
if ($choice -eq "y") {
    Restart-Computer -Confirm:$false
}
