#Requires -Version 5.1
<#
.SYNOPSIS
  一键启动 Agent Switch 全套服务

.USAGE
  bin\start.bat
  scripts\start.ps1 -Silent
#>
param(
    [switch]$Silent,
    [switch]$NoBrowser
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\lib\common.ps1"
Initialize-Project -ScriptRoot $PSScriptRoot

$InternalWebPassword = "ccswitch"

function Write-StepLocal($msg) { if (-not $Silent) { Write-Step $msg } }

function Ensure-InternalWebPassword {
    $passwordFile = Join-Path $ProjectRoot "data\cc-switch\web_password"
    New-Item -ItemType Directory -Force -Path (Split-Path $passwordFile) | Out-Null

    $changed = $true
    if (Test-Path $passwordFile) {
        $current = [System.IO.File]::ReadAllText($passwordFile).Trim()
        $changed = ($current -ne $InternalWebPassword)
    }

    if ($changed) {
        [System.IO.File]::WriteAllText($passwordFile, $InternalWebPassword, [System.Text.UTF8Encoding]::new($false))
    }
    return $changed
}

function Test-WebUi {
    $port = Get-EnvValue "CC_SWITCH_PORT" "3000"
    try {
        $response = Invoke-WebRequest -Uri "http://127.0.0.1:${port}/" -UseBasicParsing -TimeoutSec 10
        return $response.StatusCode -eq 200
    } catch { return $false }
}

Push-Location $ProjectRoot
try {
    Import-DotEnv
    $composeArgs = Get-DockerComposeArgs

    Write-StepLocal "Checking Docker..."
    if (-not (Test-DockerInstalled)) { throw "Docker not found. Install Docker Desktop first." }
    Wait-DockerReady

    if ((Ensure-InternalWebPassword)) {
        Write-StepLocal "Restarting CC Switch to apply internal auth..."
        docker compose @composeArgs restart cc-switch cc-switch-proxy 2>$null | Out-Null
        Start-Sleep -Seconds 5
    }

    Write-StepLocal "Starting containers..."
    docker compose @composeArgs up -d
    if ($LASTEXITCODE -ne 0) { throw "docker compose up failed" }

    Write-StepLocal "Waiting for services..."
    $deadline = (Get-Date).AddSeconds(90)
    $ready = $false
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        $clash = docker compose @composeArgs ps clash 2>$null
        $web = docker compose @composeArgs ps cc-switch 2>$null
        $gate = docker compose @composeArgs ps cc-switch-gate 2>$null
        if ($clash -match "healthy" -and $web -match "Up" -and $web -notmatch "Restarting" -and $gate -match "Up") {
            $ready = $true
            break
        }
    }
    if (-not $ready) { throw "Services did not become ready in time" }

    if (-not (Test-WebUi)) {
        Write-StepLocal "Restarting web gateway..."
        docker compose @composeArgs restart cc-switch-gate cc-switch | Out-Null
        Start-Sleep -Seconds 8
        if (-not (Test-WebUi)) {
            throw "Web UI is not reachable at http://127.0.0.1:$(Get-EnvValue 'CC_SWITCH_PORT' '3000')"
        }
    }

    Write-StepLocal "Starting CC Switch proxy..."
    Invoke-ProjectScript -Name "start-proxy.ps1"

    if (-not $Silent) {
        Write-Host "`nAll services started." -ForegroundColor Green
        Write-Host "  CC Switch:   http://127.0.0.1:$(Get-EnvValue 'CC_SWITCH_PORT' '3000')" -ForegroundColor Green
        Write-Host "  Agent proxy: http://127.0.0.1:$(Get-EnvValue 'CC_SWITCH_PROXY_PORT' '3457')" -ForegroundColor Green
        Write-Host "  Clash UI:    http://127.0.0.1:$(Get-EnvValue 'CLASH_UI_PORT' '9097')" -ForegroundColor Green
    }

    if (-not $NoBrowser -and -not $Silent) {
        Write-StepLocal "Opening CC Switch Web UI..."
        Start-Process "http://127.0.0.1:$(Get-EnvValue 'CC_SWITCH_PORT' '3000')/" | Out-Null
    }
} finally {
    Pop-Location
}
