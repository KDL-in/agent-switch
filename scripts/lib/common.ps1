#Requires -Version 5.1
# Shared helpers for Agent Switch scripts.

function Initialize-Project {
    param([string]$ScriptRoot)

    if (-not $ScriptRoot) {
        throw "Initialize-Project requires -ScriptRoot"
    }

    $script:ScriptDir = $ScriptRoot
    $script:ProjectRoot = Split-Path $ScriptRoot -Parent
    $script:ProjectName = Split-Path $ProjectRoot -Leaf
    $script:EnvFile = Join-Path $ProjectRoot ".env"
    $script:DockerNetwork = "${ProjectName}_agent-switch-net"
}

function Get-EnvFilePath {
    return $script:EnvFile
}

function Import-DotEnv {
    if (-not (Test-Path $script:EnvFile)) { return }

    foreach ($line in Get-Content $script:EnvFile) {
        if ($line -match '^\s*#' -or $line -notmatch '^\s*([^=]+)=(.*)$') { continue }
        $key = $Matches[1].Trim()
        $value = $Matches[2].Trim().Trim('"').Trim("'")
        if ($key) { Set-Item -Path "Env:$key" -Value $value }
    }
}

function Get-EnvValue {
    param(
        [string]$Name,
        [string]$Default = ""
    )

    if (Test-Path "Env:$Name") {
        $fromProcess = [Environment]::GetEnvironmentVariable($Name)
        if ($fromProcess) { return $fromProcess }
    }

    if (Test-Path $script:EnvFile) {
        foreach ($line in Get-Content $script:EnvFile) {
            if ($line -match "^\s*$Name=(.+)$") {
                return $Matches[1].Trim().Trim('"').Trim("'")
            }
        }
    }

    return $Default
}

function Write-Step {
    param([string]$Message)
    Write-Host ">> $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)
    Write-Host "OK  $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "WARN $Message" -ForegroundColor Yellow
}

function Invoke-ProjectScript {
    param(
        [string]$Name,
        [object[]]$Arguments = @()
    )

    $path = Join-Path $ScriptDir $Name
    if (-not (Test-Path $path)) {
        throw "Script not found: $path"
    }

    & $path @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Name failed with exit code $LASTEXITCODE"
    }
}

function Test-DockerInstalled {
    return [bool](Get-Command docker -ErrorAction SilentlyContinue)
}

function Test-DockerRunning {
    if (-not (Test-DockerInstalled)) { return $false }
    docker info *> $null
    return $LASTEXITCODE -eq 0
}

function Wait-DockerReady {
    param([int]$TimeoutMinutes = 3)

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-Date) -lt $deadline) {
        if (Test-DockerRunning) { return }
        Start-Sleep -Seconds 3
    }
    throw "Docker did not become ready within $TimeoutMinutes minutes"
}

function Get-DockerComposeArgs {
    $args = @()
    if (Test-Path $script:EnvFile) {
        $args += @("--env-file", $script:EnvFile)
    }
    return $args
}

function Get-LegacyProjectDir {
    $candidate = Join-Path (Split-Path $ProjectRoot -Parent) "docker\cc-switch"
    if (Test-Path (Join-Path $candidate "docker-compose.yml")) { return $candidate }
    return $null
}

function Remove-ConflictingContainers {
    $names = @(
        "cc-switch-clash", "cc-switch-clash-ui", "cc-switch-web",
        "cc-switch-gate", "cc-switch-proxy-forward"
    )

    foreach ($name in $names) {
        $id = docker ps -aq -f "name=^${name}$" 2>$null
        if (-not $id) { continue }

        $info = docker inspect $name 2>$null | ConvertFrom-Json
        $workingDir = $info[0].Config.Labels.'com.docker.compose.project.working_dir'
        if ($workingDir -and ($workingDir -replace '\\', '/') -ne ($ProjectRoot -replace '\\', '/')) {
            Write-Warn "Removing container from previous deployment: $name"
            docker rm -f $name 2>$null | Out-Null
        }
    }
}

function Import-LegacyAssets {
    $legacyDir = Get-LegacyProjectDir
    if (-not $legacyDir) { return }

    $legacyData = Join-Path $legacyDir "data\cc-switch"
    $targetData = Join-Path $ProjectRoot "data\cc-switch"
    if ((Test-Path $legacyData) -and -not (Test-Path (Join-Path $targetData "settings.json"))) {
        Write-Step "Importing CC Switch data from legacy deployment..."
        New-Item -ItemType Directory -Force -Path $targetData | Out-Null
        Copy-Item -Path (Join-Path $legacyData "*") -Destination $targetData -Recurse -Force
        Write-Ok "Imported CC Switch runtime data"
    }

    $legacyClashConfig = Join-Path $legacyDir "config\clash\config.yaml"
    $targetClashConfig = Join-Path $ProjectRoot "config\clash\config.yaml"
    if ((Test-Path $legacyClashConfig) -and -not (Test-Path $targetClashConfig)) {
        Write-Step "Importing Clash config from legacy deployment..."
        Copy-Item $legacyClashConfig $targetClashConfig -Force
        Write-Ok "Imported Clash config"
    }
}
