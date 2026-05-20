param(
    [string]$OutputPath = (Join-Path $PSScriptRoot "CommSandbox.wsb"),
    [switch]$Force
)

$ErrorActionPreference = "Stop"

$wsbContent = @'
<Configuration>
  <VGpu>Default</VGpu>
  <RAM>4096</RAM>
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
        } catch { Write-Host '[Sandbox] Zoom install failed: ' + $_.Exception.Message -ForegroundColor Red }

        Write-Host '[Sandbox] Installing Telegram...' -ForegroundColor Cyan;
        $tc = 'C:\Users\WDAGUtilityAccount\Desktop\TelegramSetup.exe';
        try {
          Invoke-WebRequest -Uri 'https://telegram.org/dl/desktop/win64' -OutFile $tc -UseBasicParsing -ErrorAction Stop;
          Start-Process -FilePath $tc -ArgumentList '/S' -Wait -NoNewWindow;
          Write-Host '[Sandbox] Telegram installed.' -ForegroundColor Green;
        } catch { Write-Host '[Sandbox] Telegram install failed: ' + $_.Exception.Message -ForegroundColor Red }

        Remove-Item $zc -Force -ErrorAction SilentlyContinue;
        Remove-Item $tc -Force -ErrorAction SilentlyContinue;
        Write-Host '[Sandbox] Setup complete.' -ForegroundColor Green;
      "
    </Command>
  </LogonCommand>
</Configuration>
'@

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
