#Requires -Version 5.1
$ErrorActionPreference = "Stop"
Unregister-ScheduledTask -TaskName "Agent-Switch-Start" -Confirm:$false -ErrorAction Stop
Write-Host "Autostart removed." -ForegroundColor Green
