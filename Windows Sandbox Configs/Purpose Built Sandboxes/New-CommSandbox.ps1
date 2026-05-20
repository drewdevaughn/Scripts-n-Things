<#
.SYNOPSIS
    Generates a Windows Sandbox .wsb config pre-loaded with Zoom + Telegram.
.DESCRIPTION
    Validates that the host can run the sandbox (RAM, feature enabled) before
    writing the config file. Use -Force to skip prompts, -Diagnose to only
    validate, -MemoryMB to adjust RAM allocation.
.PARAMETER OutputPath
    Path for the generated .wsb file (default: CommSandbox.wsb alongside this script).
.PARAMETER MemoryMB
    RAM in MB to allocate to the sandbox (default: 4096, min: 2048).
.PARAMETER Force
    Overwrite output file without prompting.
.PARAMETER Diagnose
    Run pre-flight checks only — do not generate the config.
#>
param(
    [string]$OutputPath = (Join-Path $PSScriptRoot "CommSandbox.wsb"),
    [int]$MemoryMB = 4096,
    [switch]$Force,
    [switch]$Diagnose
)

$ErrorActionPreference = "Stop"

function Info($m) { Write-Host "[INFO] $m" -ForegroundColor Cyan }
function Warn($m) { Write-Host "[WARN] $m" -ForegroundColor Yellow  }
function Pass($m) { Write-Host "[PASS] $m" -ForegroundColor Green   }
function Deny($m) { Write-Host "[FAIL] $m" -ForegroundColor Red; return $false }

# ---------- pre-flight checks ----------
$allOk = $true

# 1. Validate MemoryMB
if ($MemoryMB -lt 2048) {
    Deny "MemoryMB must be at least 2048 (got $MemoryMB)."
    $allOk = $false
} elseif ($MemoryMB -gt 32768) {
    Warn "MemoryMB ($MemoryMB) exceeds 32 GB — sandbox may not start on most systems."
}

# 2. Check available RAM
$freeMB = [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1024, 1)
$headroom = 1024
$needed = $MemoryMB + $headroom
if ($freeMB -lt $needed) {
    Warn "Host free RAM: ${freeMB}MB. Sandbox wants ${MemoryMB}MB + ${headroom}MB overhead = ${needed}MB. May be tight."
}

# 3. Check sandbox feature state (requires admin)
try {
    $sbFeature = Get-WindowsOptionalFeature -Online -FeatureName "Containers-DisposableClientVM" -ErrorAction Stop
    if ($sbFeature.State -eq "Disabled") {
        Warn "Windows Sandbox feature is not enabled. Run Enable-WindowsSandbox.ps1 first (requires reboot)."
        $allOk = $false
    } elseif ($sbFeature.State -eq "EnablePending") {
        Warn "Windows Sandbox enable is pending a reboot."
    } else {
        Pass "Windows Sandbox feature is enabled."
    }
} catch {
    Warn "Could not check Sandbox feature state (run as Admin to check). Skipping."
}

# 4. Check virtualization
try {
    $cs = Get-CimInstance Win32_ComputerSystem -Property HypervisorPresent
    if (-not $cs.HypervisorPresent) {
        Warn "Hardware virtualization not detected — sandbox will not start."
        $allOk = $false
    } else {
        Pass "Hardware virtualization detected."
    }
} catch { }

# ---------- exit if diagnose ----------
if ($Diagnose) {
    if ($allOk) { Info "All checks passed — ready to generate config." }
    exit 0
}

# ---------- build config ----------
$template = @'
<Configuration>
  <VGpu>Default</VGpu>
  <RAM>__RAMMB__</RAM>
  <Networking>Enable</Networking>
  <AudioInput>Enable</AudioInput>
  <VideoInput>Enable</VideoInput>
  <ProtectedClient>Enable</ProtectedClient>
  <PrinterRedirection>Disable</PrinterRedirection>
  <ClipboardRedirection>Enable</ClipboardRedirection>
  <LogonCommand>
    <Command>
      powershell.exe -NoLogo -WindowStyle Hidden -ExecutionPolicy Bypass -Command "
        Write-Host '[Sandbox] Installing Zoom...' -ForegroundColor Cyan;
        $zc = 'C:\Users\WDAGUtilityAccount\Desktop\ZoomInstaller.exe';
        try {
          Invoke-WebRequest -Uri 'https://zoom.us/client/latest/ZoomInstaller.exe' -OutFile $zc -UseBasicParsing -ErrorAction Stop;
          Start-Process -FilePath $zc -ArgumentList '/silent' -Wait -NoNewWindow;
          Write-Host '[Sandbox] Zoom installed.' -ForegroundColor Green;
        } catch { Write-Host (""[Sandbox] Zoom install failed: "" + $_.Exception.Message) -ForegroundColor Red }

        Write-Host '[Sandbox] Installing Telegram...' -ForegroundColor Cyan;
        $tc = 'C:\Users\WDAGUtilityAccount\Desktop\TelegramSetup.exe';
        try {
          Invoke-WebRequest -Uri 'https://telegram.org/dl/desktop/win64' -OutFile $tc -UseBasicParsing -ErrorAction Stop;
          Start-Process -FilePath $tc -ArgumentList '/S' -Wait -NoNewWindow;
          Write-Host '[Sandbox] Telegram installed.' -ForegroundColor Green;
        } catch { Write-Host (""[Sandbox] Telegram install failed: "" + $_.Exception.Message) -ForegroundColor Red }

        Remove-Item $zc -Force -ErrorAction SilentlyContinue;
        Remove-Item $tc -Force -ErrorAction SilentlyContinue;
        Write-Host '[Sandbox] Setup complete.' -ForegroundColor Green;
      "
    </Command>
  </LogonCommand>
</Configuration>
'@
$wsbContent = $template -replace '__RAMMB__', $MemoryMB

# ---------- write ----------
if ((Test-Path $OutputPath) -and -not $Force) {
    $msg = "Output file '$OutputPath' already exists. Overwrite?"
    $choice = Read-Host "$msg (y/N)"
    if ($choice -ne "y") { exit 0 }
}

$OutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
$wsbContent | Out-File -FilePath $OutputPath -Encoding utf8 -Force

Write-Host "Sandbox config created: $OutputPath" -ForegroundColor Green
Write-Host "Run it by double-clicking the .wsb file or use:" -ForegroundColor Gray
Write-Host "  WindowsSandbox.exe `"$OutputPath`"" -ForegroundColor Cyan
