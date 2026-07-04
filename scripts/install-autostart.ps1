#Requires -Version 5.1
<#
.SYNOPSIS
  注册 Windows 开机自启动
#>
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\lib\common.ps1"
Initialize-Project -ScriptRoot $PSScriptRoot

$startScript = Join-Path $ScriptDir "start.ps1"
$taskName = "Agent-Switch-Start"

if (-not (Test-Path $startScript)) { throw "start.ps1 not found: $startScript" }

$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$startScript`" -Silent"

$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 1)

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
    -Settings $settings -Description "Start Agent Switch Docker stack on user logon" -Force | Out-Null

Write-Host "Autostart installed: $taskName" -ForegroundColor Green
Write-Host "  Runs: $startScript -Silent" -ForegroundColor Gray
Write-Host "  Remove: scripts\uninstall-autostart.ps1" -ForegroundColor Gray
