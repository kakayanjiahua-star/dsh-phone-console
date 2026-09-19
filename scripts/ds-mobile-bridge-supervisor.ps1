# DSH mobile bridge supervisor
# Purpose: the phone only works if ds-mobile-bridge.ps1 is alive - it is the piece that
#          pushes the new address to the phone whenever the PC changes network.
#          This supervisor starts the monitor, watches its heartbeat, and restarts it
#          if it exits, crashes, or gets stuck. Started at logon by the Run key.
# NOTE: ASCII only on purpose - PowerShell 5.1 reads BOM-less files as GBK.
$ErrorActionPreference = 'SilentlyContinue'

$cfgDir = 'D:/DeepSeekHarness'
$mon    = "$cfgDir/ds-mobile-bridge.ps1"
$hb     = "$cfgDir/ds-mobile-bridge.heartbeat"
$slog   = "$cfgDir/ds-mobile-supervisor.log"

function W([string]$m) {
  try { Add-Content -LiteralPath $slog -Value ("[" + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + "] " + $m) -Encoding UTF8 } catch {}
}

# single instance (the OS releases this mutex when the process dies)
try {
  $mutex   = New-Object System.Threading.Mutex($false, 'Local\DSHMobileBridgeSupervisor')
  $gotLock = $mutex.WaitOne(0)
} catch { $gotLock = $true }
if (-not $gotLock) { W 'another supervisor is already running; exit'; exit 0 }

W 'supervisor started'
for (;;) {
  $p = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -PassThru -ArgumentList @(
    '-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', $mon
  )
  W ("monitor started pid=" + $p.Id)

  # watch it: alive process + fresh heartbeat (monitor writes one every loop, ~8-12s)
  while (-not $p.HasExited) {
    Start-Sleep -Seconds 30
    $ageMin = 99999
    if (Test-Path -LiteralPath $hb) {
      $ageMin = ((Get-Date) - (Get-Item -LiteralPath $hb).LastWriteTime).TotalMinutes
    }
    if ($ageMin -gt 4) {
      W ("heartbeat stale (" + [math]::Round($ageMin, 1) + " min) - killing pid=" + $p.Id)
      Stop-Process -Id $p.Id -Force
      break
    }
  }

  $code = $p.ExitCode
  W ("monitor pid=" + $p.Id + " exited (code=" + $code + "); restarting in 5s")
  Start-Sleep -Seconds 5
}
