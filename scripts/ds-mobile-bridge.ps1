# DSH Mobile 自动隧道 / 访问地址监视器 (v5)
#  1) 桌面重启后若之前开过隧道 → 自动重新开启(手机不在线时)；
#  2) 隧道地址**验证公网可用后**才推送到手机（避免推送"假活"死链）；
#  3) 已推送的隧道地址会定期复检，失效则自动【关→开】隧道并推送新链接(自愈)；
#  4) 局域网 IP 变化 → 也推送新地址；
#  5) 持续写 ds-mobile-url.txt 与 ds-mobile-bridge.log。
param([switch]$Once)
$ErrorActionPreference = 'SilentlyContinue'
$cfgDir   = 'D:/DeepSeekHarness'
$statePath= "$cfgDir/ds-mobile-state.json"
$urlPath  = "$cfgDir/ds-mobile-url.txt"
$keyPath  = "$cfgDir/ds-phone-notify.json"
$logPath  = "$cfgDir/ds-mobile-bridge.log"
$GW_PORT  = 43127
$Base     = "http://127.0.0.1:$GW_PORT"

# 单实例：用系统互斥体。进程一死操作系统自动释放，比"匹配命令行"可靠
#（旧写法会被别的命令行里出现过脚本名的命令误判，导致监视器自己不肯启动）
try {
  $script:mutex   = New-Object System.Threading.Mutex($false, 'Local\DSHMobileBridge')
  $script:gotLock = $script:mutex.WaitOne(0)
} catch { $script:gotLock = $true }
if (-not $script:gotLock) { Write-Output 'another instance running; exit'; exit 0 }

# 心跳文件：每轮循环覆盖写一次时间戳；看门狗靠它判断"还活着吗"
$hbPath = "$cfgDir/ds-mobile-bridge.heartbeat"

function Log-Msg($m) { try { Add-Content -LiteralPath $logPath -Value ("[" + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + "] " + $m) -Encoding UTF8 } catch {} }
function Read-State { try { Get-Content -Raw -Encoding UTF8 -LiteralPath $statePath | ConvertFrom-Json } catch { $null } }
function Write-State($obj) { try { [System.IO.File]::WriteAllText($statePath, ($obj | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding($false))) } catch {} }
# 用 curl.exe 做本机 HTTP（跨 PowerShell 5.1/7 都可靠，且显式绕过系统代理）
function Get-Json($path) {
  try {
    $out = (& curl.exe -s --noproxy "*" --max-time 10 ($Base + $path) 2>$null | Out-String).Trim()
    if (-not $out) { return $null }
    return ($out | ConvertFrom-Json)
  } catch { return $null }
}
function Post-Json($path, $obj, $timeoutSec = 25) {
  try {
    $body = $obj | ConvertTo-Json -Compress
    $tmp = Join-Path $env:TEMP ('ds-post-' + [guid]::NewGuid().ToString('N') + '.json')
    [System.IO.File]::WriteAllText($tmp, $body, (New-Object System.Text.UTF8Encoding($false)))
    $out = (& curl.exe -s --noproxy "*" --max-time $timeoutSec -X POST -H "Content-Type: application/json" --data-binary "@$tmp" ($Base + $path) 2>$null | Out-String).Trim()
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    Log-Msg "post $path -> $out"
    if (-not $out) { return $null }
    return ($out | ConvertFrom-Json)
  } catch { Log-Msg "post $path failed: $($_.Exception.Message)"; return $null }
}
function Gateway-Pid { $c = Get-NetTCPConnection -LocalPort $GW_PORT -State Listen -ErrorAction SilentlyContinue; if ($c) { $c[0].OwningProcess } else { $null } }
function Lan-Url {
  # 只取“有默认网关”的真实网卡地址（手机可达），避免误选 WSL/Hyper-V/Wi-Fi Direct 等虚拟网卡
  $gw = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceAlias -notmatch 'Tailscale' } |
        Sort-Object RouteMetric | Select-Object -First 1
  if ($gw) {
    $ip = (Get-NetIPAddress -InterfaceIndex $gw.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
           Where-Object { $_.IPAddress -notmatch '^169\.254' -and $_.IPAddress -notmatch '^127\.' } | Select-Object -First 1).IPAddress
    if ($ip) { return "http://$ip`:$GW_PORT" }
  }
  $item = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
          Where-Object { $_.IPAddress -notmatch '^127\.' -and $_.IPAddress -notmatch '^169\.254' -and $_.InterfaceAlias -notmatch 'Tailscale' } |
          Sort-Object SkipAsSource, InterfaceMetric | Select-Object -First 1
  if ($item) { "http://$($item.IPAddress):$GW_PORT" } else { '' }
}
function Tailnet-Url {
  $tsExe = $null
  $cmd = Get-Command tailscale.exe -ErrorAction SilentlyContinue
  if ($cmd) { $tsExe = $cmd.Source }
  elseif (Test-Path 'C:/Program Files/Tailscale/tailscale.exe') { $tsExe = 'C:/Program Files/Tailscale/tailscale.exe' }
  if (-not $tsExe) { return '' }
  try { $ip = (& $tsExe ip -4 2>$null | Select-Object -First 1).Trim(); if ($ip) { "http://$ip`:$GW_PORT" } else { '' } } catch { '' }
}
# 隧道是否“真的活着”：公网 DNS 能解析出该域名（Cloudflare 快速隧道只有连上边缘后才发布记录）
function Test-TunnelLive($url) {
  if (-not $url) { return $false }
  $host_ = ''
  try { $host_ = ([uri]$url).Host } catch { return $false }
  if (-not $host_) { return $false }
  foreach ($srv in '1.1.1.1','8.8.8.8') {
    try {
      $r = Resolve-DnsName -Name $host_ -Server $srv -DnsOnly -ErrorAction Stop
      if ($r | Where-Object { $_.IPAddress }) { return $true }
    } catch {}
  }
  try {
    $r = Resolve-DnsName -Name $host_ -DnsOnly -ErrorAction Stop
    if ($r | Where-Object { $_.IPAddress }) { return $true }
  } catch {}
  return $false
}
function Push-Msg($title, $body, $url) {
  try { $cfg = Get-Content -Raw -Encoding UTF8 -LiteralPath $keyPath | ConvertFrom-Json } catch { return }
  if (-not $cfg.barkKey) { Log-Msg "push-skip(no barkKey) title=$title"; return }
  $p = @{ device_key = $cfg.barkKey; title = $title; body = $body; group = 'DSH' }
  if ($url) { $p.url = $url }
  $json = $p | ConvertTo-Json -Compress
  $tmp = Join-Path $env:TEMP ('ds-murl-' + [guid]::NewGuid().ToString('N') + '.json')
  try { [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false))) } catch { return }
  $resp = (& curl.exe -s -m 15 --noproxy "*" -X POST 'https://api.day.app/push' -H 'Content-Type: application/json; charset=utf-8' --data-binary "@$tmp" 2>&1 | Out-String).Trim()
  Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
  Log-Msg "push title=$title url=$url resp=$resp"
}

Log-Msg "monitor v5 start pid=$PID"
# 隧道意图：以“标志文件”为准（避免运行中的监视器用内存态覆盖手工修改）
$flagOn  = Join-Path $cfgDir 'ds-mobile-tunnel.on'    # 存在 => 希望隧道保持开启
$flagOff = Join-Path $cfgDir 'ds-mobile-tunnel.off'   # 存在 => 明确不要隧道
$state = Read-State
if (-not $state) { $state = [pscustomobject]@{ lastGatewayPid=$null; tunnelDesired=$true; liveTunnelUrl=''; lastToggleAt=$null; toggleAttempts=0; lastLanUrl=''; deadSince=$null; healAttempts=0 } }
if (Test-Path -LiteralPath $flagOn)  { $state | Add-Member -NotePropertyName tunnelDesired -NotePropertyValue $true  -Force }
if (Test-Path -LiteralPath $flagOff) { $state | Add-Member -NotePropertyName tunnelDesired -NotePropertyValue $false -Force }
foreach ($f in 'lastGatewayPid','tunnelDesired','liveTunnelUrl','lastLanUrl','deadSince','toggleAttempts','healAttempts') {
  if ($null -eq $state.$f -and $f -notin 'lastToggleAt','deadSince') { $state | Add-Member -NotePropertyName $f -NotePropertyValue '' -Force }
}

$loop = 0
for (;;) {
  $loop++
  # 心跳：不管有没有网关都写，看门狗据此判断监视器是否还活着
  try { [System.IO.File]::WriteAllText($hbPath, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), (New-Object System.Text.UTF8Encoding($false))) } catch {}
  $gwPid = Gateway-Pid
  if (-not $gwPid) {
    if ($state.lastGatewayPid) { Log-Msg "gateway down (was pid=$($state.lastGatewayPid))"; $state.lastGatewayPid=$null; Write-State $state }
    if ($Once) { break }
    Start-Sleep -Seconds 8; continue
  }
  $restarted = ($state.lastGatewayPid -ne $gwPid)
  if ($restarted) { Log-Msg "desktop(gateway) detected pid=$gwPid (previous=$($state.lastGatewayPid))"; $state.lastGatewayPid=$gwPid }

  $status = Get-Json '/desktop/tunnel/status'
  $conn   = Get-Json '/desktop/status'
  $connected = ($conn -and $conn.connected)
  $active    = ($status -and $status.active)
  $loading   = ($status -and $status.loading)
  $turl      = if ($status.url) { $status.url } else { '' }

  $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  if ($state.tunnelDesired -and $restarted -and -not $active -and -not $loading -and -not $connected) {
    $lastAt = if ($state.lastToggleAt) { [int64]$state.lastToggleAt } else { 0 }
    if ($null -eq $state.lastToggleAt -or $nowMs - $lastAt -gt 90000) {
      $state.toggleAttempts = [int]$state.toggleAttempts + 1
      $state.lastToggleAt = $nowMs
      if ($state.toggleAttempts -le 4) {
        Log-Msg "auto-enable tunnel attempt $($state.toggleAttempts)"
        $null = Post-Json '/desktop/tunnel/toggle' @{ enable = $true } 150
      } else { Log-Msg 'auto-enable giving up (retry next restart)' }
    }
  }
  if ($active) { $state.toggleAttempts = 0; $state.lastToggleAt = $null }

  # ---- 隧道：验证后推送 + 失效自愈 ----
  if ($active -and $turl) {
    $unverified = ($turl -ne $state.liveTunnelUrl)
    $checkNow = $unverified -or ($loop % 5 -eq 0)      # 待验证每轮查；已验证每 60s 复检
    if ($checkNow) {
      $live = Test-TunnelLive $turl
      if ($unverified) {
        if ($live) {
          $state.liveTunnelUrl = $turl
          $state.deadSince = $null
          $state.healAttempts = 0
          Log-Msg "tunnel verified live: $turl"
          Push-Msg 'DSH 访问链接已更新（已验证）' '点此打开 → 重新连接（会自动批准）。' $turl
        } else {
          Log-Msg "new tunnel url NOT live yet (dns pending/failed): $turl"
        }
      } else {
        if ($live) {
          $state.deadSince = $null
        } else {
          if (-not $state.deadSince) {
            $state.deadSince = $nowMs
            Log-Msg "tunnel dns check failed (watching): $turl"
          } elseif (($nowMs - [int64]$state.deadSince) -gt 120000) {
            if ([int]$state.healAttempts -ge 3) {
              Log-Msg 'self-heal giving up (3 attempts used)'
            } else {
              $state.healAttempts = [int]$state.healAttempts + 1
              if ($connected) {
                Log-Msg "self-heal: tunnel dead - disconnecting the session, then restarting tunnel (attempt $($state.healAttempts))"
                $null = Post-Json '/desktop/disconnect' @{} 30
                Start-Sleep -Seconds 2
              } else {
                Log-Msg "self-heal: restarting tunnel (attempt $($state.healAttempts))"
              }
              $null = Post-Json '/desktop/tunnel/toggle' @{ enable = $false } 150
              Start-Sleep -Seconds 3
              $null = Post-Json '/desktop/tunnel/toggle' @{ enable = $true } 150
              $state.liveTunnelUrl = ''
              $state.deadSince = $null
            }
          }
        }
      }
    }
  }

  $lan = Lan-Url
  $best = ''
  if ($active -and $state.liveTunnelUrl) { $best = $state.liveTunnelUrl }   # 只缓存“已验证可用”的隧道地址
  if (-not $best) { $best = Tailnet-Url }
  if (-not $best) { $best = $lan }
  if ($best) { try { [System.IO.File]::WriteAllText($urlPath, $best, (New-Object System.Text.UTF8Encoding($false))) } catch {} }

  # 局域网地址变化 → 推送(手机存的旧地址会失效，这是最常见的“打不开”原因)
  if ($lan -and $lan -ne $state.lastLanUrl) {
    $prev = $state.lastLanUrl
    $state.lastLanUrl = $lan
    if ($prev) {
      Log-Msg "lan url changed: $prev -> $lan"
      Push-Msg 'DSH 手机访问地址已变' "电脑局域网地址变了(原 $prev)。点此用新地址连接。" $lan
    } else { Log-Msg "lan url recorded: $lan" }
  }

  # --- 可选：自动批准手机配对请求（默认关闭；需显式创建 ds-mobile-autoapprove.on）---
  # 说明：开启后，电脑重启不再需要你在电脑上点“允许”，手机重新连接即自动放行。
  # 代价：任何拿到隧道链接的人也能不经过你批准就进来（网关有文件读写/命令执行能力）。
  if (Test-Path -LiteralPath (Join-Path $cfgDir 'ds-mobile-autoapprove.on')) {
    $pending = Get-Json '/desktop/pending'
    if ($pending -and $pending.id) {
      Log-Msg "auto-approving pairing id=$($pending.id) from=$($pending.remoteAddress) mode=$($pending.mode)"
      $null = Post-Json '/desktop/decide' @{ id = $pending.id; approved = $true }
      Push-Msg 'DSH 已自动批准一台设备' '按你的设置（autoapprove 已开启），已自动放行这次连接请求。' ''
    }
  }

  Write-State $state
  if ($Once) { break }
  Start-Sleep -Seconds 12
}
exit 0
