# Re-register the DSH model-account sentinel task (user level, no admin needed).
# Task DSH-BalanceWatch -> runs ds-balance-watch.ps1 (full check) at logon and every 30 minutes.
# Companion: ds-mobile-bridge-register-task.ps1 does the same for the mobile bridge guard.
# ASCII only on purpose: PS 5.1 reads non-BOM files as GBK, so no Chinese here.
$ErrorActionPreference = 'Stop'

$root     = 'D:\DeepSeekHarness'
$watch    = Join-Path $root 'ds-balance-watch.ps1'
$taskName = 'DSH-BalanceWatch'
$xmlPath  = Join-Path $env:TEMP 'dsh-balance-watch-task.xml'

if (-not (Test-Path -LiteralPath $watch)) { throw "watch script not found: $watch" }

$sid   = ([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
$stamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')

$xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Date>$stamp</Date>
    <Author>DSH</Author>
    <Description>DSH model-account sentinel: DeepSeek balance, Bailian free-tier quota and a live Bailian probe (runs at logon and every 30 minutes).</Description>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <UserId>$sid</UserId>
    </LogonTrigger>
    <TimeTrigger>
      <StartBoundary>2026-01-01T00:00:00</StartBoundary>
      <Repetition>
        <Interval>PT30M</Interval>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
      <Enabled>true</Enabled>
    </TimeTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$sid</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT10M</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "$watch"</Arguments>
    </Exec>
  </Actions>
</Task>
"@

[System.IO.File]::WriteAllText($xmlPath, $xml, (New-Object System.Text.UnicodeEncoding($false, $true)))

schtasks.exe /Create /TN $taskName /XML $xmlPath /F | Out-Null
if ($LASTEXITCODE -ne 0) { throw "schtasks /Create failed with exit code $LASTEXITCODE" }

$t = Get-ScheduledTask -TaskName $taskName
$i = Get-ScheduledTaskInfo -TaskName $taskName
"registered: {0}   state={1}" -f $t.TaskName, $t.State
"triggers  : {0}" -f (($t.Triggers | ForEach-Object { $_.CimClass.CimClassName }) -join ', ')
"next run  : {0}" -f $i.NextRunTime
