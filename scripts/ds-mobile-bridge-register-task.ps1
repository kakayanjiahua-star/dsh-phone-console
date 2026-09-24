# Re-register the DSH mobile bridge guard scheduled task (user level, no admin needed).
# Task DSH-MobileBridge-Guard -> runs ds-mobile-bridge-guard.ps1 at logon AND every 5 minutes.
# Why this script exists: the task vanished once (2026-09-24) and the bridge stayed dead
# for hours after a reboot. Re-run this file to restore it in one command.
# ASCII only on purpose: PS 5.1 reads non-BOM files as GBK, so no Chinese here.
$ErrorActionPreference = 'Stop'

$root     = 'D:\DeepSeekHarness'
$guard    = Join-Path $root 'ds-mobile-bridge-guard.ps1'
$taskName = 'DSH-MobileBridge-Guard'
$xmlPath  = Join-Path $env:TEMP 'dsh-mobile-guard-task.xml'

if (-not (Test-Path -LiteralPath $guard)) { throw "guard script not found: $guard" }

$sid = ([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
$stamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')

$xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Date>$stamp</Date>
    <Author>DSH</Author>
    <Description>DSH mobile bridge guard: keeps ds-mobile-bridge-supervisor.ps1 alive (runs at logon and every 5 minutes).</Description>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <UserId>$sid</UserId>
    </LogonTrigger>
    <TimeTrigger>
      <StartBoundary>2026-01-01T00:00:00</StartBoundary>
      <Repetition>
        <Interval>PT5M</Interval>
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
      <Arguments>-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "$guard"</Arguments>
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
