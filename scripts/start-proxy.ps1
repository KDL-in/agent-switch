#Requires -Version 5.1
param([string]$ApiBase = "http://localhost:3000")

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\lib\common.ps1"
Initialize-Project -ScriptRoot $PSScriptRoot

Import-DotEnv

$externalPort = [int](Get-EnvValue "CC_SWITCH_PROXY_PORT" "3457")
$webEnvFile = Join-Path $ProjectRoot "data\cc-switch\web_env"
$headers = @{}

$csrf = ""
if (Test-Path $webEnvFile) {
    foreach ($line in Get-Content $webEnvFile) {
        if ($line -match 'WEB_CSRF_TOKEN=(.+)') { $csrf = $Matches[1].Trim() }
    }
}
if ($csrf) { $headers["X-CSRF-Token"] = $csrf }

Invoke-RestMethod -Uri "$ApiBase/api/proxy/stop" -Method Post -Headers $headers -Body "{}" -ContentType "application/json" -ErrorAction SilentlyContinue | Out-Null
Start-Sleep -Seconds 2

$settings = Invoke-RestMethod -Uri "$ApiBase/api/settings" -Headers $headers
$settings.proxy.enabled = $true
$settings.proxy.host = "127.0.0.1"
$settings.proxy.port = 3456
$settings.proxy.autoStart = $true
$settings.proxy.apps.claude.enabled = $true
$settings.proxy.apps.codex.enabled = $true
$settings.proxy.apps.gemini.enabled = $true
if ($settings.proxy.apps.opencode) { $settings.proxy.apps.opencode.enabled = $true }

$body = @{ settings = $settings } | ConvertTo-Json -Depth 12 -Compress
Invoke-RestMethod -Uri "$ApiBase/api/settings" -Method Put -Headers $headers -Body $body -ContentType "application/json" | Out-Null
Start-Sleep -Seconds 1
Invoke-RestMethod -Uri "$ApiBase/api/proxy/start" -Method Post -Headers $headers -Body $body -ContentType "application/json" | Out-Null
Start-Sleep -Seconds 2

$status = Invoke-RestMethod -Uri "$ApiBase/api/proxy/status" -Headers $headers
if (-not $status.running) { throw "CC Switch proxy failed to start" }

Write-Host "CC Switch proxy started (internal :3456, host http://127.0.0.1:$externalPort via socat)" -ForegroundColor Green
