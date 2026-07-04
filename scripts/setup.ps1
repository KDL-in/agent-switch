#Requires -Version 5.1
param(
    [string]$SubscriptionUrl = "",
    [switch]$SkipPull
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\lib\common.ps1"
Initialize-Project -ScriptRoot $PSScriptRoot

$VergeDir = Join-Path $env:APPDATA "io.github.clash-verge-rev.clash-verge-rev"

function Get-ClashVergeSubscriptionUrl {
    $profilesFile = Join-Path $VergeDir "profiles.yaml"
    if (-not (Test-Path $profilesFile)) { return $null }

    $lines = Get-Content $profilesFile
    $current = ($lines | Where-Object { $_ -match '^current:\s*(\S+)' } | ForEach-Object { $Matches[1] })
    if (-not $current) { return $null }

    $inCurrent = $false
    foreach ($line in $lines) {
        if ($line -match "^- uid: $([regex]::Escape($current))") { $inCurrent = $true; continue }
        if ($inCurrent -and $line -match '^- uid:') { break }
        if ($inCurrent -and $line -match '^\s+url:\s*(.+)$') { return $Matches[1].Trim() }
    }
    return $null
}

function Import-ClashVergeProfile {
    param([string]$TargetConfig)

    $profilesFile = Join-Path $VergeDir "profiles.yaml"
    if (-not (Test-Path $profilesFile)) { return $false }

    $current = (Get-Content $profilesFile | Where-Object { $_ -match '^current:\s*(\S+)' } | ForEach-Object { $Matches[1] })
    if (-not $current) { return $false }

    $profileFile = Join-Path $VergeDir "profiles\$current.yaml"
    if (-not (Test-Path $profileFile)) { return $false }

    $content = Get-Content $profileFile -Raw -Encoding UTF8
    $content = $content -replace "external-controller:\s*'127\.0\.0\.1:9090'", "external-controller: '0.0.0.0:9090'"
    $content = $content -replace 'external-controller:\s*127\.0\.0\.1:9090', 'external-controller: 0.0.0.0:9090'
    if ($content -notmatch 'allow-lan:\s*true') {
        $content = $content -replace 'allow-lan:\s*false', 'allow-lan: true'
    }
    [System.IO.File]::WriteAllText($TargetConfig, $content, [System.Text.UTF8Encoding]::new($false))
    return $true
}

function Download-ClashSubscription {
    param([string]$Url, [string]$TargetConfig)
    Write-Step "Downloading subscription..."
    Invoke-WebRequest -Uri $Url -OutFile $TargetConfig -UseBasicParsing
    $content = Get-Content $TargetConfig -Raw -Encoding UTF8
    $content = $content -replace "external-controller:\s*'127\.0\.0\.1:9090'", "external-controller: '0.0.0.0:9090'"
    $content = $content -replace 'external-controller:\s*127\.0\.0\.1:9090', 'external-controller: 0.0.0.0:9090'
    if ($content -notmatch 'allow-lan:\s*true') {
        $content = $content -replace 'allow-lan:\s*false', 'allow-lan: true'
    }
    [System.IO.File]::WriteAllText($TargetConfig, $content, [System.Text.UTF8Encoding]::new($false))
}

Write-Step "Checking Docker..."
if (-not (Test-DockerInstalled)) { throw "docker not found. Install Docker Desktop first." }
if (-not (Test-DockerRunning)) { throw "Docker is not running. Start Docker Desktop and retry." }

$envExample = Join-Path $ProjectRoot ".env.example"
if (-not (Test-Path $EnvFile)) {
    Copy-Item $envExample $EnvFile
    Write-Step "Created .env"
}

$configDir = Join-Path $ProjectRoot "config\clash"
$providersDir = Join-Path $configDir "providers"
$dataDir = Join-Path $ProjectRoot "data\cc-switch"
$configFile = Join-Path $configDir "config.yaml"
$configExample = Join-Path $configDir "config.yaml.example"

New-Item -ItemType Directory -Force -Path $providersDir, $dataDir | Out-Null

$subUrl = $SubscriptionUrl
if (-not $subUrl) { $subUrl = Get-EnvValue "CLASH_SUB_URL" "" }
if (-not $subUrl) {
    $subUrl = Get-ClashVergeSubscriptionUrl
    if ($subUrl) { Write-Step "Found Clash Verge subscription URL" }
}

$configReady = $false
if ($subUrl) {
    try {
        Download-ClashSubscription -Url $subUrl -TargetConfig $configFile
        Write-Ok "Clash config downloaded from subscription"
        $configReady = $true
    } catch {
        Write-Warn "Subscription download failed: $($_.Exception.Message)"
    }
}

if (-not $configReady) {
    $legacyDir = Get-LegacyProjectDir
    $legacyClashConfig = if ($legacyDir) { Join-Path $legacyDir "config\clash\config.yaml" } else { $null }
    if ($legacyClashConfig -and (Test-Path $legacyClashConfig)) {
        Copy-Item $legacyClashConfig $configFile -Force
        Write-Ok "Clash config imported from legacy deployment"
        $configReady = $true
    } elseif (Import-ClashVergeProfile -TargetConfig $configFile) {
        Write-Ok "Clash config imported from Clash Verge"
        $configReady = $true
    } elseif (-not (Test-Path $configFile)) {
        Copy-Item $configExample $configFile
        Write-Warn "Using template config (no subscription found)"
    }
}

if ((Get-Content $configFile -Raw) -match 'YOUR_SUBSCRIPTION_URL') {
    Write-Warn "config.yaml still has placeholder subscription URL"
}

Remove-ConflictingContainers
Import-LegacyAssets

$composeArgs = Get-DockerComposeArgs

Push-Location $ProjectRoot
try {
    if (-not $SkipPull) {
        Write-Step "Pulling images..."
        docker compose @composeArgs pull
        if ($LASTEXITCODE -ne 0) { throw "docker compose pull failed" }
    }

    Write-Step "Starting services..."
    docker compose @composeArgs up -d
    if ($LASTEXITCODE -ne 0) { throw "docker compose up failed" }

    Write-Step "Waiting for health checks..."
    $deadline = (Get-Date).AddSeconds(60)
    $clashOk = $false
    $webOk = $false
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        $clashLine = docker compose @composeArgs ps clash 2>$null
        $webLine = docker compose @composeArgs ps cc-switch 2>$null
        if ($clashLine -match 'healthy') { $clashOk = $true }
        if ($webLine -match 'Up' -and $webLine -notmatch 'Restarting') { $webOk = $true }
        if ($clashOk -and $webOk) { break }
    }

    if (-not $clashOk) { throw "Clash did not become healthy in time" }
    if (-not $webOk) { throw "cc-switch-web is not running" }
    Write-Ok "Containers healthy"

    Invoke-ProjectScript -Name "start-proxy.ps1"
    Write-Ok "CC Switch proxy started"

    Write-Step "Testing Clash proxy from docker network..."
    $proxyOk = $false
    for ($i = 1; $i -le 3; $i++) {
        Start-Sleep -Seconds 5
        $proxyTest = docker run --rm --network $DockerNetwork curlimages/curl:8.5.0 `
            -s -o /dev/null -w "%{http_code}" --connect-timeout 15 -x http://clash:7890 http://www.gstatic.com/generate_204 2>&1
        if ($proxyTest -eq "204") {
            Write-Ok "Clash proxy egress works (HTTP 204)"
            $proxyOk = $true
            break
        }
        Write-Warn "Clash proxy test attempt $i/3 returned: $proxyTest"
    }
    if (-not $proxyOk) {
        Write-Warn "Clash proxy egress not verified (node may be unreachable)"
        Write-Host "  Switch node: scripts\switch-node.ps1  or open http://127.0.0.1:9097" -ForegroundColor Yellow
    }

    Write-Step "Testing CC Switch Web UI..."
    $verifyScript = Join-Path $ScriptDir "verify-browser.mjs"
    $playwrightReady = Test-Path (Join-Path $ProjectRoot "node_modules\playwright\package.json")
    if ((Get-Command node -ErrorAction SilentlyContinue) -and (Test-Path $verifyScript) -and $playwrightReady) {
        node $verifyScript
        if ($LASTEXITCODE -ne 0) { throw "Browser verification failed" }
        Write-Ok "Browser UI verification passed"
    } else {
        if ((Get-Command node -ErrorAction SilentlyContinue) -and (Test-Path $verifyScript) -and -not $playwrightReady) {
            Write-Warn "Skipping Playwright UI test (run 'npm install playwright' in project root to enable)"
        }
        $r = Invoke-WebRequest -Uri "http://localhost:3000/" -UseBasicParsing -TimeoutSec 10
        if ($r.StatusCode -ne 200) { throw "Web UI failed with status $($r.StatusCode)" }
        Write-Ok "Web UI works (HTTP 200)"
    }

    Start-Process "http://localhost:3000" | Out-Null
    Write-Ok "Opened browser at http://localhost:3000"
    Write-Host "`nAll checks passed." -ForegroundColor Green
    Write-Host "  CC Switch:   http://localhost:3000" -ForegroundColor Green
    Write-Host "  Agent proxy: http://127.0.0.1:3457 (run scripts\setup-agents.ps1)" -ForegroundColor Green
} finally {
    Pop-Location
}
