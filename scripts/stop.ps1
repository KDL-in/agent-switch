#Requires -Version 5.1
param([switch]$Silent)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\lib\common.ps1"
Initialize-Project -ScriptRoot $PSScriptRoot

function Write-StepLocal($msg) { if (-not $Silent) { Write-Step $msg } }

function Stop-CcSwitchProxy {
    $running = docker ps --filter "name=^cc-switch-gate$" --filter "status=running" -q 2>$null
    if (-not $running) { return }

    $port = Get-EnvValue "CC_SWITCH_PORT" "3000"
    try {
        Invoke-RestMethod `
            -Uri "http://127.0.0.1:${port}/api/proxy/stop" `
            -Method Post -Body "{}" -ContentType "application/json" `
            -TimeoutSec 5 -ErrorAction SilentlyContinue | Out-Null
    } catch { }
}

Push-Location $ProjectRoot
try {
    if (-not (Test-DockerInstalled)) { throw "Docker not found." }

    Write-StepLocal "Stopping CC Switch proxy..."
    Stop-CcSwitchProxy

    Write-StepLocal "Stopping containers..."
    docker compose stop
    if ($LASTEXITCODE -ne 0) { throw "docker compose stop failed" }

    if (-not $Silent) {
        Write-Host "`nAll services stopped." -ForegroundColor Green
        Write-Host "  Run bin\start.bat to start again." -ForegroundColor Green
    }
} finally {
    Pop-Location
}
