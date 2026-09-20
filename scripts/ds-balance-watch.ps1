# DSH model-account sentinel.
# Checks the model accounts this machine really spends quota/money on:
#   deepseek       - official DeepSeek balance (CNY)
#   bailian-quota  - Bailian free-tier quota left for a model (needs console login)
#   bailian-probe  - one real minimal call to the Bailian endpoint the dictation
#                    project uses (catches arrearage / exhausted quota / bad key)
# Pushes a phone alert (Bark via ds-phone-notify.ps1) plus a desktop balloon when a
# check reports a problem. The same level is never repeated inside the cooldown.
# Usage: powershell -File ds-balance-watch.ps1 [-Force] [-Test] [-Quiet]
param(
  [switch]$Force,   # ignore cooldown: push again even if this level was already sent
  [switch]$Test,    # send one test push and exit
  [switch]$Fast,    # skip the slow console-quota check (used by the per-turn hook)
  [switch]$Quiet    # log to file only, no console output
)
$ErrorActionPreference = 'SilentlyContinue'

$root      = 'D:\DeepSeekHarness'
$cfgPath   = Join-Path $root 'ds-balance-watch.json'
$statePath = Join-Path $root 'ds-balance-watch.state.json'
$logPath   = Join-Path $root 'ds-balance-watch.log'
$notifyPs1 = Join-Path $root 'ds-phone-notify.ps1'
$blCmd     = 'D:\node_global\bl.cmd'
# 32x32 white PNG, embedded so the probe needs no image library.
$probeImage = 'iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAAqSURBVFhH7c4xAQAADMOg+TedyegDCrjGBAQEBAQEBAQEBAQEBAQExoF6l/rw4lHYRKwAAAAASUVORK5CYII='

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

function Get-BailianCred {
  $p = Join-Path $env:USERPROFILE '.bailian\config.json'
  if (-not (Test-Path -LiteralPath $p)) { return $null }
  try {
    $c = Get-Content -Raw -Encoding UTF8 -LiteralPath $p | ConvertFrom-Json
    if ($c.api_key -and $c.base_url) { return @{ api_key = [string]$c.api_key; base_url = [string]$c.base_url } }
  } catch {}
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
  Send-DesktopBalloon 'DSH 模型账户告警' $msg
}

function Check-DeepSeek($t) {
  $key = Get-Cred ([string]$t.keyName)
  if (-not $key) { return @{ status = 'skip'; detail = "no key $($t.keyName)"; alert = $null } }
  $raw = & curl.exe --noproxy '*' -s -m 25 'https://api.deepseek.com/user/balance' -H "Authorization: Bearer $key"
  if (-not $raw) { return @{ status = 'skip'; detail = 'balance query failed'; alert = $null } }
  $o = $null
  try { $o = $raw | ConvertFrom-Json } catch { return @{ status = 'skip'; detail = 'balance reply unreadable'; alert = $null } }
  if (-not ($o.balance_infos -and $o.balance_infos.Count -gt 0)) { return @{ status = 'skip'; detail = 'no balance info'; alert = $null } }
  $bal = [double]$o.balance_infos[0].total_balance
  $level = 'ok'
  if ($bal -le [double]$t.criticalBelow) { $level = 'critical' }
  elseif ($bal -le [double]$t.warnBelow) { $level = 'warn' }
  $alert = $null
  if ($level -eq 'critical') {
    $alert = ("{0} 余额 ¥{1:N2}，已低于告急线 ¥{2:N2}，随时可能用不了。充值：{3}" -f [string]$t.name, $bal, [double]$t.criticalBelow, [string]$t.topUpUrl)
  } elseif ($level -eq 'warn') {
    $alert = ("{0} 余额 ¥{1:N2}，低于提醒线 ¥{2:N2}，建议尽快充值。充值：{3}" -f [string]$t.name, $bal, [double]$t.warnBelow, [string]$t.topUpUrl)
  }
  return @{ status = $level; detail = ("balance CNY {0:N2}" -f $bal); alert = $alert }
}

function Check-BailianQuota($t) {
  $bl = $blCmd
  if (-not (Test-Path -LiteralPath $bl)) { $bl = 'bl' }
  $model = [string]$t.model
  $out = (& $bl usage free --model $model --output json 2>$null | Out-String)
  $m = [regex]::Match($out, '(?s)\[.*\]')
  if (-not $m.Success) { return @{ status = 'skip'; detail = 'quota query failed (console login needed?)'; alert = $null } }
  $arr = $null
  try { $arr = $m.Value | ConvertFrom-Json } catch { return @{ status = 'skip'; detail = 'quota reply unreadable'; alert = $null } }
  $item = $arr | Where-Object { [string]$_.model -eq $model } | Select-Object -First 1
  if (-not $item) { return @{ status = 'skip'; detail = "no quota row for $model"; alert = $null } }

  $remaining = [double]$item.remaining
  $total     = [double]$item.total
  $pct       = [double]$item.remainingPercent
  $expires   = [string]$item.expires
  $detail    = ("{0}: {1:N0}/{2:N0} left ({3}%), expires {4}" -f $model, $remaining, $total, $pct, $expires)

  $level = 'ok'
  if ($pct -le [double]$t.criticalBelowPercent) { $level = 'critical' }
  elseif ($pct -le [double]$t.warnBelowPercent) { $level = 'warn' }

  $alert = $null
  if ($level -eq 'critical') {
    $alert = ("百炼免费额度告急：{0} 只剩 {1}%（约 {2:N0} token），用完孩子的默写识别就会失败。去百炼处理：{3}" -f $model, $pct, $remaining, [string]$t.topUpUrl)
  } elseif ($level -eq 'warn') {
    $alert = ("百炼免费额度偏低：{0} 只剩 {1}%（约 {2:N0} token，{3} 到期），建议提前充值或换模型。百炼控制台：{4}" -f $model, $pct, $remaining, $expires, [string]$t.topUpUrl)
  }

  if ($expires) {
    $exp = $null
    try { $exp = [datetime]::ParseExact($expires, 'yyyy-MM-dd', $null) } catch {}
    if ($exp) {
      $days = [int][math]::Round(($exp - (Get-Date)).TotalDays)
      $detail += " ($days days to expiry)"
      if ($days -le [int]$t.expireWarnDays) {
        if ($level -eq 'ok') { $level = 'warn' }
        if (-not $alert) {
          $alert = ("百炼免费额度 {0} 还有 {1} 天到期（{2}），到期就作废。百炼控制台：{3}" -f $model, $days, $expires, [string]$t.topUpUrl)
        }
      }
    }
  }
  return @{ status = $level; detail = $detail; alert = $alert }
}

function Check-BailianProbe($t) {
  $c = Get-BailianCred
  if (-not $c) { return @{ status = 'skip'; detail = 'no bailian config'; alert = $null } }
  $model = [string]$t.model
  $body = @{
    model      = $model
    messages   = @(@{ role = 'user'; content = @(
        @{ type = 'image_url'; image_url = @{ url = ('data:image/png;base64,' + $probeImage) } },
        @{ type = 'text'; text = 'ok' }
      ) })
    max_tokens = 4
  } | ConvertTo-Json -Depth 10 -Compress
  $tmp = Join-Path $env:TEMP ('dsh-probe-' + [guid]::NewGuid().ToString('N') + '.json')
  try { [System.IO.File]::WriteAllText($tmp, $body, (New-Object System.Text.UTF8Encoding($false))) } catch { return @{ status = 'skip'; detail = 'probe body write failed'; alert = $null } }
  $out = (& curl.exe --noproxy '*' -s -m 90 -w '|HTTPSTATUS:%{http_code}' -X POST "$($c.base_url)/compatible-mode/v1/chat/completions" -H 'Content-Type: application/json' -H "Authorization: Bearer $($c.api_key)" --data-binary "@$tmp" | Out-String)
  Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue

  $code = ''
  $mm = [regex]::Match($out, '\|HTTPSTATUS:(\d{3})')
  if ($mm.Success) { $code = $mm.Groups[1].Value }
  if ($code -eq '200') { return @{ status = 'ok'; detail = "live call OK ($model)"; alert = $null } }
  if (-not $code) { return @{ status = 'skip'; detail = 'probe had no response (network)'; alert = $null } }

  $msg = ''
  $jm = [regex]::Match($out, '"message":"(.*?)"')
  if ($jm.Success) { $msg = $jm.Groups[1].Value }
  if (-not $msg) { $msg = ($out -replace '\s+', ' ') }
  if ($msg.Length -gt 180) { $msg = $msg.Substring(0, 180) }
  return @{
    status = 'critical'
    detail = "live call FAILED http=$code $msg"
    alert  = ("英语默写的识别模型现在调不通了（{0}）：{1}。孩子做题会识别失败，去百炼看额度/欠费：{2}" -f $model, $msg, [string]$t.topUpUrl)
  }
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
  if ($Fast -and ([string]$t.type -eq 'bailian-quota')) { continue }
  $name = [string]$t.name
  $r = $null
  switch ([string]$t.type) {
    'deepseek'      { $r = Check-DeepSeek $t }
    'bailian-quota' { $r = Check-BailianQuota $t }
    'bailian-probe' { $r = Check-BailianProbe $t }
    default         { $r = @{ status = 'skip'; detail = "unknown type $($t.type)"; alert = $null } }
  }
  if (-not $r) { $r = @{ status = 'skip'; detail = 'no result'; alert = $null } }

  $level = [string]$r.status
  Write-Log ("{0}: {1} [{2}]" -f $name, $r.detail, $level)

  if ($level -ne 'warn' -and $level -ne 'critical') { continue }

  $st = $state[$name]
  if (-not $Force -and $st -and ([string]$st.level -eq $level) -and $st.at) {
    $last = [datetime]$st.at
    if (((Get-Date) - $last).TotalHours -lt $cooldown) {
      Write-Log ("{0}: {1} already pushed, inside cooldown" -f $name, $level)
      continue
    }
  }

  $msg = [string]$r.alert
  if (-not $msg) { $msg = [string]$r.detail }
  Send-Alert $msg
  Write-Log ("{0}: alert pushed ({1})" -f $name, $level)
  $state[$name] = @{ level = $level; at = (Get-Date).ToString('s') }
}

try { ($state | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $statePath -Encoding UTF8 } catch {}
exit 0
