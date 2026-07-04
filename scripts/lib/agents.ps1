#Requires -Version 5.1
# Agent CLI config helpers (merge-only, never replace existing config).

function Get-AgentProxyUrl {
    param([int]$ProxyPort = 0)
    if ($ProxyPort -gt 0) { return "http://127.0.0.1:$ProxyPort" }
    return "http://127.0.0.1:$(Get-EnvValue 'CC_SWITCH_PROXY_PORT' '3457')"
}

function Write-AgentJsonFile {
    param([string]$Path, [object]$Object)
    $dir = Split-Path $Path -Parent
    if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $json = $Object | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($Path, $json, [System.Text.UTF8Encoding]::new($false))
}

function Merge-AgentJsonFile {
    param([string]$Path, [scriptblock]$Merge)
    $existing = $null
    if (Test-Path $Path) {
        try { $existing = Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json }
        catch { Write-Warn "Could not parse $Path, skipping merge."; return $false }
    }
    if (-not $existing) { $existing = [PSCustomObject]@{} }
    $changed = & $Merge $existing
    if ($changed) { Write-AgentJsonFile -Path $Path -Object $existing }
    return [bool]$changed
}

function Get-JsonEnvValue {
    param([object]$EnvObj, [string]$Name)
    if (-not $EnvObj) { return $null }
    $prop = $EnvObj.PSObject.Properties[$Name]
    if (-not $prop) { return $null }
    $value = [string]$prop.Value
    if ([string]::IsNullOrWhiteSpace($value)) { return $null }
    return $value.Trim()
}

function Set-JsonEnvVarIfMissing {
    param([object]$EnvObj, [string]$Name, [string]$Value)
    if (Get-JsonEnvValue -EnvObj $EnvObj -Name $Name) { return $false }
    $EnvObj | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    return $true
}

function Test-ClaudeAgentConfig {
    param([string]$ProxyUrl)
    $settingsFile = Join-Path $env:USERPROFILE ".claude\settings.json"
    if (-not (Test-Path $settingsFile)) { return $false }
    try {
        $obj = Get-Content $settingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $baseUrl = Get-JsonEnvValue -EnvObj $obj.env -Name "ANTHROPIC_BASE_URL"
        $token = Get-JsonEnvValue -EnvObj $obj.env -Name "ANTHROPIC_AUTH_TOKEN"
        return ($baseUrl -eq $ProxyUrl) -and ($token -eq "PROXY_MANAGED")
    } catch { return $false }
}

function Ensure-ClaudeAgentConfig {
    param([string]$ProxyUrl)
    if (Test-ClaudeAgentConfig -ProxyUrl $ProxyUrl) { return $false }

    $settingsFile = Join-Path $env:USERPROFILE ".claude\settings.json"
    $changed = Merge-AgentJsonFile -Path $settingsFile -Merge {
        param($obj)
        $updates = $false
        if (-not $obj.env) {
            $obj | Add-Member -NotePropertyName env -NotePropertyValue ([PSCustomObject]@{}) -Force
        }
        if (Set-JsonEnvVarIfMissing -EnvObj $obj.env -Name "ANTHROPIC_BASE_URL" -Value $ProxyUrl) { $updates = $true }
        if (Set-JsonEnvVarIfMissing -EnvObj $obj.env -Name "ANTHROPIC_AUTH_TOKEN" -Value "PROXY_MANAGED") { $updates = $true }
        return $updates
    }
    if ($changed) { Write-Host "  Claude Code  -> added proxy env to $settingsFile" -ForegroundColor Green }
    return $changed
}

function Test-CodexAgentConfig {
    param([string]$ProxyUrl)
    $configFile = Join-Path $env:USERPROFILE ".codex\config.toml"
    if (-not (Test-Path $configFile)) { return $false }
    $content = Get-Content $configFile -Raw -Encoding UTF8
    $baseUrl = "$ProxyUrl/v1"
    return ($content -match '\[model_providers\.agent-switch\]') -and ($content -match [regex]::Escape("base_url = `"$baseUrl`""))
}

function Ensure-CodexAgentConfig {
    param([string]$ProxyUrl)
    if (Test-CodexAgentConfig -ProxyUrl $ProxyUrl) { return $false }

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
        if ($content -match '\[model_providers\.agent-switch\]') { return $false }
        $content = $content.TrimEnd() + "`n`n" + $providerBlock + "`n"
    } else {
        $content = "model_provider = `"agent-switch`"`n`n" + $providerBlock + "`n"
    }

    [System.IO.File]::WriteAllText($configFile, $content, [System.Text.UTF8Encoding]::new($false))
    Write-Host "  Codex CLI    -> added agent-switch provider to $configFile" -ForegroundColor Green
    return $true
}

function Test-GeminiAgentConfig {
    param([string]$ProxyUrl)
    $envFile = Join-Path $env:USERPROFILE ".gemini\.env"
    if (-not (Test-Path $envFile)) { return $false }
    $lines = @{}
    foreach ($line in Get-Content $envFile) {
        if ($line -match '^\s*([^=]+)=(.*)$') { $lines[$Matches[1].Trim()] = $Matches[2].Trim() }
    }
    return ($lines["GOOGLE_GEMINI_BASE_URL"] -eq $ProxyUrl) -and ($lines["GEMINI_API_KEY"] -eq "PROXY_MANAGED")
}

function Ensure-GeminiAgentConfig {
    param([string]$ProxyUrl)
    if (Test-GeminiAgentConfig -ProxyUrl $ProxyUrl) { return $false }

    $geminiDir = Join-Path $env:USERPROFILE ".gemini"
    $envFile = Join-Path $geminiDir ".env"
    New-Item -ItemType Directory -Force -Path $geminiDir | Out-Null

    $lines = [ordered]@{}
    if (Test-Path $envFile) {
        foreach ($line in Get-Content $envFile) {
            if ($line -match '^\s*([^=]+)=(.*)$') { $lines[$Matches[1].Trim()] = $Matches[2].Trim() }
        }
    }

    $changed = $false
    if (-not $lines["GOOGLE_GEMINI_BASE_URL"]) { $lines["GOOGLE_GEMINI_BASE_URL"] = $ProxyUrl; $changed = $true }
    if (-not $lines["GEMINI_API_KEY"]) { $lines["GEMINI_API_KEY"] = "PROXY_MANAGED"; $changed = $true }
    if (-not $changed) { return $false }

    $output = ($lines.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "`n"
    [System.IO.File]::WriteAllText($envFile, $output + "`n", [System.Text.UTF8Encoding]::new($false))
    Write-Host "  Gemini CLI   -> added proxy env to $envFile" -ForegroundColor Green
    return $true
}

function Test-OpenCodeAgentConfig {
    param([string]$ProxyUrl)
    $configFile = Join-Path $env:USERPROFILE ".config\opencode\opencode.json"
    if (-not (Test-Path $configFile)) { return $false }
    try {
        $existing = Get-Content $configFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $existing.provider) { return $false }
        $provider = $existing.provider."agent-switch"
        if (-not $provider) { return $false }
        $baseUrl = $provider.options.baseURL
        $apiKey = $provider.options.apiKey
        return ($baseUrl -eq "$ProxyUrl/v1") -and ($apiKey -eq "PROXY_MANAGED")
    } catch { return $false }
}

function Ensure-OpenCodeAgentConfig {
    param([string]$ProxyUrl)
    if (Test-OpenCodeAgentConfig -ProxyUrl $ProxyUrl) { return $false }

    $configDir = Join-Path $env:USERPROFILE ".config\opencode"
    $configFile = Join-Path $configDir "opencode.json"
    New-Item -ItemType Directory -Force -Path $configDir | Out-Null

    $agentSwitchProvider = @{
        npm = "@ai-sdk/openai-compatible"
        name = "Agent Switch Proxy"
        options = @{ baseURL = "$ProxyUrl/v1"; apiKey = "PROXY_MANAGED" }
        models = @{ default = @{ name = "default" } }
    }

    if (Test-Path $configFile) {
        $changed = Merge-AgentJsonFile -Path $configFile -Merge {
            param($obj)
            if (-not $obj.provider) {
                $obj | Add-Member -NotePropertyName provider -NotePropertyValue ([PSCustomObject]@{}) -Force
            }
            if ($obj.provider."agent-switch") { return $false }
            $obj.provider | Add-Member -NotePropertyName "agent-switch" -NotePropertyValue $agentSwitchProvider -Force
            return $true
        }
        if ($changed) { Write-Host "  OpenCode     -> added agent-switch provider to $configFile" -ForegroundColor Green }
        return $changed
    }

    $config = [ordered]@{
        '$schema' = "https://opencode.ai/config.json"
        provider = @{ "agent-switch" = $agentSwitchProvider }
    }
    Write-AgentJsonFile -Path $configFile -Object $config
    Write-Host "  OpenCode     -> created $configFile" -ForegroundColor Green
    return $true
}

function Ensure-AgentsConfig {
    param(
        [string[]]$Agents = @("claude", "codex", "gemini", "opencode"),
        [int]$ProxyPort = 0,
        [switch]$Silent
    )

    $proxyUrl = Get-AgentProxyUrl -ProxyPort $ProxyPort
    $normalizedAgents = $Agents | ForEach-Object { $_.ToLower().Trim() } | Where-Object { $_ }
    $anyChanged = $false

    foreach ($agent in $normalizedAgents) {
        $changed = switch ($agent) {
            "claude"   { Ensure-ClaudeAgentConfig -ProxyUrl $proxyUrl }
            "codex"    { Ensure-CodexAgentConfig -ProxyUrl $proxyUrl }
            "gemini"   { Ensure-GeminiAgentConfig -ProxyUrl $proxyUrl }
            "opencode" { Ensure-OpenCodeAgentConfig -ProxyUrl $proxyUrl }
            default {
                if (-not $Silent) { Write-Warn "Unknown agent '$agent' (supported: claude, codex, gemini, opencode)" }
                $false
            }
        }
        if ($changed) { $anyChanged = $true }
    }

    return $anyChanged
}

function Setup-ClaudeAgent {
    param([string]$ProxyUrl)
    $settingsFile = Join-Path $env:USERPROFILE ".claude\settings.json"
    Merge-AgentJsonFile -Path $settingsFile -Merge {
        param($obj)
        if (-not $obj.env) { $obj | Add-Member -NotePropertyName env -NotePropertyValue ([PSCustomObject]@{}) -Force }
        $obj.env | Add-Member -NotePropertyName ANTHROPIC_BASE_URL -NotePropertyValue $ProxyUrl -Force
        $obj.env | Add-Member -NotePropertyName ANTHROPIC_AUTH_TOKEN -NotePropertyValue "PROXY_MANAGED" -Force
        return $true
    } | Out-Null
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

    $agentSwitchProvider = @{
        npm = "@ai-sdk/openai-compatible"
        name = "Agent Switch Proxy"
        options = @{ baseURL = "$ProxyUrl/v1"; apiKey = "PROXY_MANAGED" }
        models = @{ default = @{ name = "default" } }
    }

    $config = [ordered]@{
        '$schema' = "https://opencode.ai/config.json"
        provider = @{ "agent-switch" = $agentSwitchProvider }
    }

    if (Test-Path $configFile) {
        try {
            $existing = Get-Content $configFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if (-not $existing.provider) { $existing | Add-Member -NotePropertyName provider -NotePropertyValue ([PSCustomObject]@{}) -Force }
            $existing.provider | Add-Member -NotePropertyName "agent-switch" -NotePropertyValue $agentSwitchProvider -Force
            $config = $existing
        } catch { Write-Warn "Could not merge $configFile" }
    }

    Write-AgentJsonFile -Path $configFile -Object $config
    Write-Host "  OpenCode     -> $configFile" -ForegroundColor Green
}

function Setup-AgentsConfig {
    param(
        [string[]]$Agents = @("claude", "codex", "gemini", "opencode"),
        [int]$ProxyPort = 0
    )

    $proxyUrl = Get-AgentProxyUrl -ProxyPort $ProxyPort
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
}
