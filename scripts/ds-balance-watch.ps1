# DSH model-balance sentinel.
# Queries provider balance APIs and pushes an alert (phone via ds-phone-notify.ps1
# + desktop balloon) when the balance drops below the configured lines.
# Safe to run often: adds one line to ds-balance-watch.log, and never repeats the
# same alert level inside the cooldown window.
# Usage: powershell -File ds-balance-watch.ps1 [-Force] [-Test] [-Quiet]
param(
  [switch]$Force,   # ignore cooldown: push again even if this level was already sent
  [switch]$Test,    # send one test push and exit
  [switch]$Quiet    # log to file only, no console output
)
$ErrorActionPreference = 'SilentlyContinue'

$root      = 'D:\DeepSeekHarness'
$cfgPath   = Join-Path $root 'ds-balance-watch.json'
$statePath = Join-Path $root 'ds-balance-watch.state.json'
$logPath   = Join-Path $root 'ds-balance-watch.log'
$notifyPs1 = Join-Path $root 'ds-phone-notify.ps1'

function Write-Log([string]$m) {
  $line = '[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '] ' + $m
  try { Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8 } catch {}
  if (-not $Quiet) { Write-Output $line }
}

function Get-Cred([string]$name) {
  $cands = New-Object System.Collections.ArrayList
  if ($env:DSH_HOME) { [void]$cands.Add((Join-Path $env:DSH_HOME '.credentials.yaml')) }
  if ($env:APPDATA) { [void]$cands.Add((Join-Path $env:APPDATA 'dsh-desktop\harness\.credentials.yaml')) }
  foreach ($p in $cands) {
    if (Test-Path -LiteralPath $p) {
      $raw = Get-Content -Raw -Encoding UTF8 -LiteralPath $p
      if ($raw -match ('(?m)^\s*' + [regex]::Escape($name) + ':\s*(\S+)')) { return $matches[1] }
    }
  }
  foreach ($scope in @('User', 'Machine', 'Process')) {
    $v = [Environment]::GetEnvironmentVariable($name, $scope)
    if ($v) { return $v }
  }
  return $null
}

function Get-DeepSeekBalance([string]$key) {
  $raw = & curl.exe --noproxy '*' -s -m 25 'https://api.deepseek.com/user/balance' -H "Authorization: Bearer $key"
  if (-not $raw) { return $null }
  $o = $null
  try { $o = $raw | ConvertFrom-Json } catch { return $null }
  if ($o.balance_infos -and $o.balance_infos.Count -gt 0) { return [double]$o.balance_infos[0].total_balance }
  return $null
}

function Send-DesktopBalloon([string]$title, [string]$body) {
  try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $ni = New-Object System.Windows.Forms.NotifyIcon
    $ni.Icon = [System.Drawing.SystemIcons]::Warning
    $ni.Visible = $true
    $ni.ShowBalloonTip(20000, $title, $body, [System.Windows.Forms.ToolTipIcon]::Warning)
    Start-Sleep -Seconds 7
    $ni.Dispose()
  } catch {}
}

function Send-Alert([string]$msg) {
  if (Test-Path -LiteralPath $notifyPs1) {
    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $notifyPs1 -Event alert -Message $msg
  }
  Send-DesktopBalloon 'DSH 模型余额告警' $msg
}

if ($Test) {
  Send-Alert '余额哨兵测试：手机收到这条即表示告警链路可用。'
  Write-Log 'test push sent'
  exit 0
}

$cfg = $null
try { $cfg = Get-Content -Raw -Encoding UTF8 -LiteralPath $cfgPath | ConvertFrom-Json } catch {}
if (-not $cfg) { Write-Log 'config missing or unreadable'; exit 0 }

$cooldown = [double]$cfg.cooldownHours
if (-not $cooldown) { $cooldown = 12 }

$state = @{}
if (Test-Path -LiteralPath $statePath) {
  try {
    $s = Get-Content -Raw -Encoding UTF8 -LiteralPath $statePath | ConvertFrom-Json
    foreach ($p in $s.PSObject.Properties) { $state[$p.Name] = $p.Value }
  } catch {}
}

foreach ($t in $cfg.targets) {
  $name = [string]$t.name
  $key  = Get-Cred ([string]$t.keyName)
  if (-not $key) { Write-Log ("{0}: no key {1}, skipped" -f $name, $t.keyName); continue }

  $bal = $null
  switch ([string]$t.type) {
    'deepseek' { $bal = Get-DeepSeekBalance $key }
    default    { Write-Log ("{0}: unknown type {1}" -f $name, $t.type); continue }
  }
  if ($null -eq $bal) { Write-Log ("{0}: balance query failed (network or key)" -f $name); continue }

  $level = 'ok'
  if ($bal -le [double]$t.criticalBelow) { $level = 'critical' }
  elseif ($bal -le [double]$t.warnBelow) { $level = 'warn' }
  Write-Log ("{0}: balance CNY {1:N2} -> {2}" -f $name, $bal, $level)

  if ($level -eq 'ok') { continue }

  $st = $state[$name]
  if (-not $Force -and $st -and ([string]$st.level -eq $level) -and $st.at) {
    $last = [datetime]$st.at
    if (((Get-Date) - $last).TotalHours -lt $cooldown) {
      Write-Log ("{0}: {1} already pushed, inside cooldown" -f $name, $level)
      continue
    }
  }

  if ($level -eq 'critical') {
    $msg = ("{0} 余额 ¥{1:N2}，已低于告急线 ¥{2:N2}，随时可能用不了。充值：{3}" -f $name, $bal, [double]$t.criticalBelow, [string]$t.topUpUrl)
  } else {
    $msg = ("{0} 余额 ¥{1:N2}，低于提醒线 ¥{2:N2}，建议尽快充值。充值：{3}" -f $name, $bal, [double]$t.warnBelow, [string]$t.topUpUrl)
  }
  Send-Alert $msg
  Write-Log ("{0}: alert pushed ({1})" -f $name, $level)
  $state[$name] = @{ level = $level; at = (Get-Date).ToString('s') }
}

try { ($state | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $statePath -Encoding UTF8 } catch {}
exit 0
