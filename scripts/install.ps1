#Requires -Version 5.1
<#
.SYNOPSIS
  Agent Switch 一键安装脚本（Windows）

.USAGE
  bin\install.bat
  scripts\install.ps1 -Silent
  scripts\install.ps1 -Agents claude,codex
#>
param(
    [switch]$Silent,
    [switch]$SkipDockerInstall,
    [switch]$SkipAutostart,
    [string[]]$Agents = @("claude", "codex", "gemini"),
    [string]$SubscriptionUrl = ""
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\lib\common.ps1"
Initialize-Project -ScriptRoot $PSScriptRoot

function Write-StepLocal($msg) { if (-not $Silent) { Write-Step $msg } }
function Write-OkLocal($msg) { if (-not $Silent) { Write-Ok $msg } }
function Write-WarnLocal($msg) { if (-not $Silent) { Write-Warn $msg } }

function Test-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Install-DockerDesktop {
    if (Test-DockerInstalled) {
        Write-OkLocal "Docker CLI already installed"
        return
    }

    Write-StepLocal "Docker not found, attempting installation..."

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw @"
Docker Desktop is not installed and winget is unavailable.
Install manually: https://www.docker.com/products/docker-desktop/
Then re-run: bin\install.bat
"@
    }

    if (-not (Test-Admin)) {
        Write-WarnLocal "Docker installation requires administrator privileges."
        if (-not $Silent) {
            $open = Read-Host "Open Docker Desktop download page? (Y/n)"
            if ($open -ne "n" -and $open -ne "N") {
                Start-Process "https://www.docker.com/products/docker-desktop/"
            }
        }
        throw "Docker Desktop is required. Install it and re-run install."
    }

    Write-StepLocal "Installing Docker Desktop via winget..."
    winget install -e --id Docker.DockerDesktop --accept-package-agreements --accept-source-agreements

    $dockerExe = "${env:ProgramFiles}\Docker\Docker\Docker Desktop.exe"
    if (Test-Path $dockerExe) {
        Write-StepLocal "Starting Docker Desktop..."
        Start-Process $dockerExe | Out-Null
    }

    Write-OkLocal "Docker Desktop installed"
}

function Wait-DockerReadyLocal {
    Write-StepLocal "Waiting for Docker daemon..."
    $deadline = (Get-Date).AddMinutes(5)
    while ((Get-Date) -lt $deadline) {
        if (Test-DockerRunning) {
            Write-OkLocal "Docker is running"
            return
        }
        Start-Sleep -Seconds 5
    }
    throw "Docker did not become ready. Start Docker Desktop and re-run install."
}

function Ensure-EnvFile {
    $envExample = Join-Path $ProjectRoot ".env.example"
    if (-not (Test-Path $EnvFile)) {
        Copy-Item $envExample $EnvFile
        Write-OkLocal "Created .env from template"
    }

    if ($SubscriptionUrl) {
        Set-ClashSubUrl $SubscriptionUrl
        Write-OkLocal "Clash subscription URL configured"
    } elseif (-not $Silent) {
        $hasSub = Get-Content $EnvFile | Where-Object { $_ -match '^\s*CLASH_SUB_URL=https?://' }
        if (-not $hasSub) {
            Write-WarnLocal "No Clash subscription URL in .env"
            $sub = Read-Host "Enter Clash subscription URL (press Enter to skip)"
            if ($sub -match '^https?://') {
                Set-ClashSubUrl $sub
                Write-OkLocal "Subscription URL saved"
            }
        }
    }
}

function Set-ClashSubUrl {
    param([string]$Url)
    $content = Get-Content $EnvFile -Raw
    if ($content -match 'CLASH_SUB_URL=') {
        $content = $content -replace '(?m)^\s*#?\s*CLASH_SUB_URL=.*$', "CLASH_SUB_URL=$Url"
    } else {
        $content = $content.TrimEnd() + "`nCLASH_SUB_URL=$Url`n"
    }
    [System.IO.File]::WriteAllText($EnvFile, $content, [System.Text.UTF8Encoding]::new($false))
}

function Test-Wsl2 {
    try {
        $wslStatus = wsl --status 2>&1 | Out-String
        if ($wslStatus -match "WSL version:\s*2" -or $wslStatus -match "默认版本:\s*2") { return $true }
        wsl -l -v 2>$null | Out-Null
        return $LASTEXITCODE -eq 0
    } catch { return $false }
}

Push-Location $ProjectRoot
try {
    if (-not $Silent) {
        Write-Host "`n========================================" -ForegroundColor Magenta
        Write-Host "  Agent Switch - Windows Installer" -ForegroundColor Magenta
        Write-Host "========================================`n" -ForegroundColor Magenta
    }

    Write-StepLocal "Checking prerequisites..."
    if ($PSVersionTable.PSVersion.Major -lt 5) { throw "PowerShell 5.1+ is required" }
    Write-OkLocal "PowerShell $($PSVersionTable.PSVersion)"

    if (-not $SkipDockerInstall) { Install-DockerDesktop }
    elseif (-not (Test-DockerInstalled)) { throw "Docker not found." }

    if (-not (Test-Wsl2) -and -not $Silent) {
        Write-WarnLocal "WSL2 may not be configured. Run: wsl --install"
    }

    Wait-DockerReadyLocal
    Ensure-EnvFile

    Write-StepLocal "Deploying services..."
    if ($SubscriptionUrl) {
        Invoke-ProjectScript -Name "setup.ps1" -Arguments @("-SubscriptionUrl", $SubscriptionUrl)
    } else {
        Invoke-ProjectScript -Name "setup.ps1"
    }
    Write-OkLocal "Docker services deployed"

    Write-StepLocal "Configuring AI agents..."
    & (Join-Path $ScriptDir "setup-agents.ps1") -Agents $Agents
    if ($LASTEXITCODE -ne 0) { throw "setup-agents.ps1 failed" }
    Write-OkLocal "Agents configured: $($Agents -join ', ')"

    if (-not $SkipAutostart -and -not $Silent) {
        $enableAuto = Read-Host "Enable autostart on login? (y/N)"
        if ($enableAuto -eq "y" -or $enableAuto -eq "Y") {
            Invoke-ProjectScript -Name "install-autostart.ps1"
            Write-OkLocal "Autostart enabled"
        }
    }

    if (-not $Silent) {
        Write-Host "`n========================================" -ForegroundColor Green
        Write-Host "  Installation complete!" -ForegroundColor Green
        Write-Host "========================================" -ForegroundColor Green
        Write-Host "  Web UI:      http://localhost:3000"
        Write-Host "  Agent proxy: http://127.0.0.1:3457"
        Write-Host "  Daily start: bin\start.bat`n"
    }
} catch {
    Write-Host "`nInstallation failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
} finally {
    Pop-Location
}
