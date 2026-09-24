# 手机链接工具
#   -Mode lan    在家模式：关掉公网隧道，推局域网地址（最快，毫秒级）
#   -Mode tunnel 外出模式：开公网隧道，验证后推公网链接（任何网络可用，但慢 1-2 秒/次）
#   -Mode auto   自动：能用就用，坏了就重开（默认）
param([string]$Mode = 'auto')
$ErrorActionPreference = 'SilentlyContinue'
$GW_PORT = 43127
$cfgDir  = 'D:\DeepSeekHarness'
$Base    = "http://127.0.0.1:$GW_PORT"

function J($p, $t = 10) { (& curl.exe -s --noproxy "*" --max-time $t ($Base + $p) | Out-String).Trim() }
function P($p, $b, $t = 150) { (& curl.exe -s --noproxy "*" --max-time $t -X POST -H "Content-Type: application/json" -d $b ($Base + $p) | Out-String).Trim() }
function DnsOk($url) {
  if (-not $url) { return $false }
  try { $h = ([uri]$url).Host } catch { return $false }
  if (-not $h) { return $false }
  try { return [bool](Resolve-DnsName $h -Server 1.1.1.1 -DnsOnly -ErrorAction Stop | Where-Object { $_.IPAddress }) } catch { return $false }
}
function WaitDns($url, $sec = 90) {
  for ($i = 0; $i -lt [int]($sec / 5); $i++) { if (DnsOk $url) { return $true }; Start-Sleep -Seconds 5 }
  return (DnsOk $url)
}
# 本机直连 trycloudflare 是不通的（系统 DNS 查不到 *.trycloudflare.com），所以“活着没”不能只看 DNS，
# 必须再用本机 mihomo 代理实测一次 HTTP —— 2026-09-24 就是只查 DNS 导致误报“重开失败”。
function ProxyProbe($url) {
  if (-not $url) { return $false }
  $code = (& curl.exe -s -x http://127.0.0.1:7899 --max-time 25 -o NUL -w '%{http_code}' $url | Out-String).Trim()
  return ($code -match '^(2|3)\d\d$')
}
function TunnelLive($url) { return ((DnsOk $url) -or (ProxyProbe $url)) }
function LanUrl {
  $gw = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceAlias -notmatch 'Tailscale' } | Sort-Object RouteMetric | Select-Object -First 1
  if ($gw) {
    $ip = (Get-NetIPAddress -InterfaceIndex $gw.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notmatch '^169\.254' -and $_.IPAddress -notmatch '^127\.' } | Select-Object -First 1).IPAddress
    if ($ip) { return "http://$ip`:$GW_PORT" }
  }
  return ''
}
function Send-Link($url, $title, $body) {
  try { $cfg = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $cfgDir 'ds-phone-notify.json') | ConvertFrom-Json } catch { Write-Host '读取推送配置失败' -ForegroundColor Red; return }
  if (-not $cfg.barkKey) { Write-Host '还没配置 Bark key' -ForegroundColor Red; return }
  $json = @{ device_key = $cfg.barkKey; title = $title; body = $body; group = 'DSH'; url = $url } | ConvertTo-Json -Compress
  $tmp = Join-Path $env:TEMP ('ds-link-' + [guid]::NewGuid().ToString('N') + '.json')
  [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
  $resp = (& curl.exe -s --noproxy "*" -m 15 -X POST 'https://api.day.app/push' -H 'Content-Type: application/json; charset=utf-8' --data-binary "@$tmp" | Out-String).Trim()
  Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
  if ($resp -match '"code":200') { Write-Host '已推送到你手机 ✅' -ForegroundColor Green } else { Write-Host ("推送返回: " + $resp) -ForegroundColor Yellow }
}
function Save-Url($url) {
  [System.IO.File]::WriteAllText((Join-Path $cfgDir 'ds-mobile-url.txt'), $url, (New-Object System.Text.UTF8Encoding($false)))
  $sp = Join-Path $cfgDir 'ds-mobile-state.json'
  $st = Get-Content -Raw -Encoding UTF8 $sp | ConvertFrom-Json
  $live = ''
  if ($url -match 'trycloudflare|pinggy|trycloudflare') { $live = $url }
  $st | Add-Member -NotePropertyName liveTunnelUrl -NotePropertyValue $live -Force
  $st | Add-Member -NotePropertyName deadSince -NotePropertyValue $null -Force
  [System.IO.File]::WriteAllText($sp, ($st | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding($false)))
}

Write-Host ("模式: " + $Mode)

if ($Mode -eq 'lan') {
  New-Item -ItemType File -Force -Path (Join-Path $cfgDir 'ds-mobile-tunnel.off') | Out-Null
  Remove-Item (Join-Path $cfgDir 'ds-mobile-tunnel.on') -Force -ErrorAction SilentlyContinue
  $null = P '/desktop/disconnect' @{} 30
  Start-Sleep -Seconds 2
  $null = P '/desktop/tunnel/toggle' '{"enable":false}'
  Start-Sleep -Seconds 3
  $lan = LanUrl
  if (-not $lan) { Write-Host '取不到局域网地址（电脑没连 WiFi？）' -ForegroundColor Red; return }
  Save-Url $lan
  Write-Host ''
  Write-Host ('在家快链: ' + $lan) -ForegroundColor Green
  Write-Host '（要求：手机连和电脑同一个 WiFi）'
  Send-Link $lan 'DSH 在家快链' '手机连和电脑同一个 WiFi，点开即可（局域网直连，最快，不再走公网）。'
  return
}

New-Item -ItemType File -Force -Path (Join-Path $cfgDir 'ds-mobile-tunnel.on') | Out-Null
Remove-Item (Join-Path $cfgDir 'ds-mobile-tunnel.off') -Force -ErrorAction SilentlyContinue
$st = J '/desktop/tunnel/status' | ConvertFrom-Json
$url = $st.url
if (-not ($st.active -and (TunnelLive $url))) {
  Write-Host '正在重开公网隧道（约 30-120 秒）...' -ForegroundColor Yellow
  $null = P '/desktop/disconnect' @{} 30
  Start-Sleep -Seconds 2
  for ($try = 1; $try -le 2; $try++) {
    $null = P '/desktop/tunnel/toggle' '{"enable":false}' 60
    Start-Sleep -Seconds 4
    $r = P '/desktop/tunnel/toggle' '{"enable":true}' 150
    try { $url = ($r | ConvertFrom-Json).url } catch { $url = '' }
    if (-not $url) { try { $url = (J '/desktop/tunnel/status' | ConvertFrom-Json).url } catch { $url = '' } }
    if ($url) {
      for ($i = 0; $i -lt 12; $i++) { if (TunnelLive $url) { break }; Start-Sleep -Seconds 5 }
      if (TunnelLive $url) { break }
    }
    Write-Host ("第 $try 次没起效，再试一次…") -ForegroundColor Yellow
    Start-Sleep -Seconds 5
  }
}
if ($url -and (TunnelLive $url)) {
  Save-Url $url
  Write-Host ''
  Write-Host ('公网链接: ' + $url) -ForegroundColor Green
  Write-Host ''
  Send-Link $url 'DSH 手机链接（公网）' '任何网络都能用（在家、5G 都行）。点开 → 重新连接（会自动批准）。'
} else {
  Write-Host '公网隧道重开失败，请把这句话告诉严老板' -ForegroundColor Red
}
