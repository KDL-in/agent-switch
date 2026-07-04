#Requires -Version 5.1
<#
.SYNOPSIS
  配置 AI Agent CLI 连接 CC Switch 本地代理

.USAGE
  scripts\setup-agents.ps1
  scripts\setup-agents.ps1 -Agents claude,codex
#>
param(
    [string[]]$Agents = @("claude", "codex", "gemini", "opencode"),
    [int]$ProxyPort = 0
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\lib\common.ps1"
Initialize-Project -ScriptRoot $PSScriptRoot

function Get-ProxyPort {
    if ($ProxyPort -gt 0) { return $ProxyPort }
    return [int](Get-EnvValue "CC_SWITCH_PROXY_PORT" "3457")
}

function Write-JsonFile {
    param([string]$Path, [object]$Object)
    $dir = Split-Path $Path -Parent
    if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $json = $Object | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($Path, $json, [System.Text.UTF8Encoding]::new($false))
}

function Merge-JsonFile {
    param([string]$Path, [scriptblock]$Merge)
    $existing = $null
    if (Test-Path $Path) {
        try { $existing = Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json }
        catch { Write-Warn "Could not parse $Path, will overwrite relevant keys." }
    }
    if (-not $existing) { $existing = [PSCustomObject]@{} }
    & $Merge $existing
    Write-JsonFile -Path $Path -Object $existing
}

function Setup-ClaudeAgent {
    param([string]$ProxyUrl)
    $settingsFile = Join-Path $env:USERPROFILE ".claude\settings.json"
    Merge-JsonFile -Path $settingsFile -Merge {
        param($obj)
        if (-not $obj.env) { $obj | Add-Member -NotePropertyName env -NotePropertyValue ([PSCustomObject]@{}) -Force }
        $obj.env.ANTHROPIC_BASE_URL = $ProxyUrl
        $obj.env.ANTHROPIC_AUTH_TOKEN = "PROXY_MANAGED"
    }
    Write-Host "  Claude Code  -> $settingsFile" -ForegroundColor Green
}

function Setup-CodexAgent {
    param([string]$ProxyUrl)
    $codexDir = Join-Path $env:USERPROFILE ".codex"
    $configFile = Join-Path $codexDir "config.toml"
    New-Item -ItemType Directory -Force -Path $codexDir | Out-Null

    $baseUrl = "$ProxyUrl/v1"
    $providerBlock = @"
[model_providers.agent-switch]
name = "agent-switch"
base_url = "$baseUrl"
wire_api = "responses"

[profiles.agent-switch]
model_provider = "agent-switch"
model = "gpt-4o"
"@

    if (Test-Path $configFile) {
        $content = Get-Content $configFile -Raw -Encoding UTF8
        if ($content -match '\[model_providers\.agent-switch\]') {
            $content = $content -replace 'base_url = "http://[^"]+"', "base_url = `"$baseUrl`""
        } else {
            $content = $content.TrimEnd() + "`n`n" + $providerBlock + "`n"
        }
        if ($content -notmatch '^\s*model_provider\s*=') {
            $content = "model_provider = `"agent-switch`"`n`n" + $content
        } else {
            $content = $content -replace 'model_provider\s*=\s*"[^"]*"', 'model_provider = "agent-switch"'
        }
    } else {
        $content = "model_provider = `"agent-switch`"`n`n" + $providerBlock + "`n"
    }
    [System.IO.File]::WriteAllText($configFile, $content, [System.Text.UTF8Encoding]::new($false))
    Write-Host "  Codex CLI    -> $configFile" -ForegroundColor Green
}

function Setup-GeminiAgent {
    param([string]$ProxyUrl)
    $geminiDir = Join-Path $env:USERPROFILE ".gemini"
    $envFile = Join-Path $geminiDir ".env"
    New-Item -ItemType Directory -Force -Path $geminiDir | Out-Null

    $lines = @{}
    if (Test-Path $envFile) {
        foreach ($line in Get-Content $envFile) {
            if ($line -match '^\s*([^=]+)=(.*)$') { $lines[$Matches[1].Trim()] = $Matches[2].Trim() }
        }
    }
    $lines["GOOGLE_GEMINI_BASE_URL"] = $ProxyUrl
    $lines["GEMINI_API_KEY"] = "PROXY_MANAGED"
    $output = ($lines.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "`n"
    [System.IO.File]::WriteAllText($envFile, $output + "`n", [System.Text.UTF8Encoding]::new($false))
    Write-Host "  Gemini CLI   -> $envFile" -ForegroundColor Green
}

function Setup-OpenCodeAgent {
    param([string]$ProxyUrl)
    $configDir = Join-Path $env:USERPROFILE ".config\opencode"
    $configFile = Join-Path $configDir "opencode.json"
    New-Item -ItemType Directory -Force -Path $configDir | Out-Null

    $config = [ordered]@{
        '$schema' = "https://opencode.ai/config.json"
        provider = @{
            "agent-switch" = @{
                npm = "@ai-sdk/openai-compatible"
                name = "Agent Switch Proxy"
                options = @{ baseURL = "$ProxyUrl/v1"; apiKey = "PROXY_MANAGED" }
                models = @{ default = @{ name = "default" } }
            }
        }
    }

    if (Test-Path $configFile) {
        try {
            $existing = Get-Content $configFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if (-not $existing.provider) { $existing | Add-Member -NotePropertyName provider -NotePropertyValue ([PSCustomObject]@{}) -Force }
            $existing.provider | Add-Member -NotePropertyName "agent-switch" -NotePropertyValue $config.provider."agent-switch" -Force
            $config = $existing
        } catch { Write-Warn "Could not merge $configFile" }
    }

    Write-JsonFile -Path $configFile -Object $config
    Write-Host "  OpenCode     -> $configFile" -ForegroundColor Green
}

$port = Get-ProxyPort
$proxyUrl = "http://127.0.0.1:$port"
$normalizedAgents = $Agents | ForEach-Object { $_.ToLower().Trim() } | Where-Object { $_ }

Write-Host "`nConfiguring agents (proxy: $proxyUrl)" -ForegroundColor Cyan
foreach ($agent in $normalizedAgents) {
    switch ($agent) {
        "claude"   { Setup-ClaudeAgent -ProxyUrl $proxyUrl }
        "codex"    { Setup-CodexAgent -ProxyUrl $proxyUrl }
        "gemini"   { Setup-GeminiAgent -ProxyUrl $proxyUrl }
        "opencode" { Setup-OpenCodeAgent -ProxyUrl $proxyUrl }
        default { Write-Warn "Unknown agent '$agent' (supported: claude, codex, gemini, opencode)" }
    }
}

Write-Host "`nAgent configuration complete." -ForegroundColor Green
Write-Host "Ensure proxy is running: bin\start.bat" -ForegroundColor Gray
