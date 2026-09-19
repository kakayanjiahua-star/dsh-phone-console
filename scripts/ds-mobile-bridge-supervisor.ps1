# DSH mobile bridge supervisor
# Purpose: the phone only works while ds-mobile-bridge.ps1 (the monitor) is alive —
#          it is the piece that pushes the new address whenever the PC changes network.
#          This supervisor keeps it alive, and alerts the phone when it has to act.
# Started at logon by the scheduled task DSH-MobileBridge-Guard (see guard script).
#
# 设计要点（2026-09-19 重写）：只以「心跳新鲜度」为唯一判据，不依赖进程句柄，
# 所以它可以和已经在跑的 monitor 共存，不会重复拉起、也不会刷屏。
# 本文件必须保存为 UTF-8 with BOM（PS 5.1 否则按 GBK 读，中文会乱）。
$ErrorActionPreference = 'SilentlyContinue'

$cfgDir = 'D:/DeepSeekHarness'
$mon    = "$cfgDir/ds-mobile-bridge.ps1"
$hb     = "$cfgDir/ds-mobile-bridge.heartbeat"
$slog   = "$cfgDir/ds-mobile-supervisor.log"
$notify = "$cfgDir/ds-phone-notify.ps1"
$stamp  = "$cfgDir/ds-mobile-supervisor-alert.txt"

function W([string]$m) {
  try { Add-Content -LiteralPath $slog -Value ("[" + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + "] " + $m) -Encoding UTF8 } catch {}
}

function Alert([string]$msg) {
  $last = 0
  try { $last = [int](Get-Content -Raw -LiteralPath $stamp) } catch {}
  $now = [int][double]::Parse((Get-Date -UFormat %s))
  if (($now - $last) -lt 1800) { W 'alert suppressed (debounce)'; return }
  try { [System.IO.File]::WriteAllText($stamp, "$now") } catch {}
  try {
    Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $notify, '-Event', 'alert', '-Message', $msg
    )
  } catch {}
}

# single instance (the OS releases this mutex when the process dies)
try {
  $mutex   = New-Object System.Threading.Mutex($false, 'Local\DSHMobileBridgeSupervisor')
  $gotLock = $mutex.WaitOne(0)
} catch { $gotLock = $true }
if (-not $gotLock) { W 'another supervisor is already running; exit'; exit 0 }

W 'supervisor started'

function Get-HeartbeatAge {
  if (-not (Test-Path -LiteralPath $hb)) { return 99999 }
  return ((Get-Date) - (Get-Item -LiteralPath $hb).LastWriteTime).TotalMinutes
}

function Stop-StaleMonitors {
  $old = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object {
      $_.CommandLine -like '*ds-mobile-bridge.ps1*' -and
      $_.CommandLine -notlike '*supervisor*' -and
      $_.CommandLine -notlike '*guard*'
    })
  foreach ($o in $old) { try { Stop-Process -Id $o.ProcessId -Force } catch {} }
}

for (;;) {
  $age = Get-HeartbeatAge
  if ($age -le 2) { Start-Sleep -Seconds 30; continue }   # 健康：什么都不做

  W ("heartbeat stale (" + [math]::Round($age, 1) + " min) - restarting monitor")
  Stop-StaleMonitors
  Start-Sleep -Seconds 2
  $p = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -PassThru -ArgumentList @(
    '-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', $mon
  )
  W ("monitor started pid=" + $p.Id)
  Alert ("手机桥接监视器掉线了（心跳停 " + [math]::Round($age, 0) + " 分钟），守护进程已自动重拉，1 分钟后再点链接就行。")
  Start-Sleep -Seconds 30
}
