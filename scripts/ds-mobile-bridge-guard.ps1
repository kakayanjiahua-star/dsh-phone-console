# DSH 手机桥接看护者（guard）— 由计划任务触发：登录时 + 每 5 分钟一次
# 职责：① supervisor 不在 → 用 WMI 脱离进程树拉起 + 推一条手机告警
#       ② supervisor 在但心跳超过 8 分钟 → 判定卡死，杀掉重拉 + 告警
# 告警去抖：同一次故障 30 分钟内只推一条，避免每 5 分钟骚扰
# 本文件必须保存为 UTF-8 with BOM（PS 5.1 否则按 GBK 读，中文会乱）
$ErrorActionPreference = 'SilentlyContinue'

$cfgDir = 'D:/DeepSeekHarness'
$sup    = "$cfgDir/ds-mobile-bridge-supervisor.ps1"
$hb     = "$cfgDir/ds-mobile-bridge.heartbeat"
$glog   = "$cfgDir/ds-mobile-guard.log"
$notify = "$cfgDir/ds-phone-notify.ps1"
$stamp  = "$cfgDir/ds-mobile-guard-alert.txt"

function G([string]$m) {
  try { Add-Content -LiteralPath $glog -Value ("[" + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + "] " + $m) -Encoding UTF8 } catch {}
}

function Alert([string]$msg) {
  $last = 0
  try { $last = [int](Get-Content -Raw -LiteralPath $stamp) } catch {}
  $now = [int][double]::Parse((Get-Date -UFormat %s))
  if (($now - $last) -lt 1800) { G "alert suppressed (debounce): $msg"; return }
  try { [System.IO.File]::WriteAllText($stamp, "$now") } catch {}
  try {
    Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $notify, '-Event', 'alert', '-Message', $msg
    )
  } catch {}
}

function Start-Supervisor {
  $cmd = 'powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $sup + '"'
  try { Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmd } | Out-Null } catch { G "WMI start failed: $_" }
}

function Get-SupervisorPids {
  @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
      Where-Object { $_.CommandLine -like '*ds-mobile-bridge-supervisor.ps1*' } |
      Select-Object -ExpandProperty ProcessId)
}

$pids = Get-SupervisorPids
$hbAge = 99999
if (Test-Path -LiteralPath $hb) { $hbAge = ((Get-Date) - (Get-Item -LiteralPath $hb).LastWriteTime).TotalMinutes }
$ageTxt = [math]::Round($hbAge, 0)

if ($pids.Count -eq 0) {
  G ("supervisor missing; heartbeat age " + [math]::Round($hbAge, 1) + " min -> starting")
  Start-Supervisor
  Alert "手机桥接守护进程掉线了（心跳停 $ageTxt 分钟），我已自动重拉，1 分钟后再点链接就行。"
  exit 0
}

if ($hbAge -gt 8) {
  G ("supervisor alive (pid " + ($pids -join ',') + ") but heartbeat stale " + [math]::Round($hbAge, 1) + " min -> restarting")
  foreach ($procId in $pids) { Stop-Process -Id $procId -Force }
  Start-Sleep -Seconds 2
  Start-Supervisor
  Alert "手机桥接卡住了（心跳停 $ageTxt 分钟），我已自动重启守护进程，1 分钟后再试。"
  exit 0
}

# 一切正常：静默退出（不打扰）
exit 0
