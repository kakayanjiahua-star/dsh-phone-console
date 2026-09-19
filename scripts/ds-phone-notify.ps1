# DSH phone push notification (Bark / ntfy.sh) — both free, no account.
# Called by @deepseek-ai/dsh-hooks-codex on turn-stop and on ask_user_question.
# Notifications carry a tappable url (from ds-mobile-url.txt). Every real push
# is logged to ds-mobile-bridge.log with the Bark/ntfy response, so hook
# firing can be verified independently. Never affects the agent.
param(
  [string]$Event = 'stop',
  [string]$Message = ''
)
$ErrorActionPreference = 'SilentlyContinue'

$cfgPath = 'D:/DeepSeekHarness/ds-phone-notify.json'
$urlPath = 'D:/DeepSeekHarness/ds-mobile-url.txt'
$logPath = 'D:/DeepSeekHarness/ds-mobile-bridge.log'

function Log-Msg($m) {
  try { Add-Content -LiteralPath $logPath -Value ("[" + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + "] " + $m) -Encoding UTF8 } catch {}
}

$cfg = $null
try { $cfg = Get-Content -Raw -Encoding UTF8 -LiteralPath $cfgPath | ConvertFrom-Json } catch {}
$mobileUrl = ''
try { $u = Get-Content -Raw -Encoding UTF8 -LiteralPath $urlPath; if ($u) { $mobileUrl = $u.Trim() } } catch {}

switch ($Event) {
  'question' { $title = 'DSH 需要你回答' }
  'prompt'   { $title = 'DSH 收到新任务' }
  'alert'    { $title = 'DSH 手机桥接告警' }
  default    { $title = 'DSH 本轮完成' }
}

if ($Message) {
  $body = $Message
} elseif ($Event -eq 'question') {
  $body = '智能体向你提问，点此直达会话回答'
} elseif ($Event -eq 'prompt') {
  $body = '新任务已开始，点此直达会话看进度'
} else {
  $body = '点此直达会话查看结果并继续派活'
}

# ---- Bark ----
if ($cfg.barkKey) {
  $p = @{ device_key = $cfg.barkKey; title = $title; body = $body; group = 'DSH' }
  if ($mobileUrl) { $p.url = $mobileUrl }
  $json = $p | ConvertTo-Json -Compress
  $tmp = Join-Path $env:TEMP ('ds-phone-notify-' + [guid]::NewGuid().ToString('N') + '.json')
  try { [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false))) } catch { exit 0 }
  $resp = (& curl.exe -s -m 15 -X POST 'https://api.day.app/push' -H 'Content-Type: application/json; charset=utf-8' --data-binary "@$tmp" 2>&1 | Out-String).Trim()
  Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
  Log-Msg "notify event=$Event title=$title url=$mobileUrl resp=$resp"
  exit 0
}

# ---- ntfy.sh ----
if ($cfg.ntfyTopic) {
  $topic = $cfg.ntfyTopic
  $ntfyBody = $body
  if ($mobileUrl) { $ntfyBody += "`n$mobileUrl" }
  $resp = (& curl.exe -s -m 15 -X POST "https://ntfy.sh/$topic" -H "Title: $title" -H "Tags: robot" --data-binary $ntfyBody 2>&1 | Out-String).Trim()
  Log-Msg "notify event=$Event channel=ntfy topic=$topic resp=$resp"
  exit 0
}

Log-Msg "notify event=$Event no-provider-configured (barkKey/ntfyTopic empty)"
exit 0