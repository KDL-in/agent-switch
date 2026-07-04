#Requires -Version 5.1
<#
.SYNOPSIS
  配置 AI Agent CLI 连接 CC Switch 本地代理

.USAGE
  scripts\setup-agents.ps1
  scripts\setup-agents.ps1 -Agents claude,codex
  scripts\setup-agents.ps1 -EnsureOnly   # 仅补全缺失字段，不覆盖已有配置
#>
param(
    [string[]]$Agents = @("claude", "codex", "gemini", "opencode"),
    [int]$ProxyPort = 0,
    [switch]$EnsureOnly
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\lib\common.ps1"
. "$PSScriptRoot\lib\agents.ps1"
Initialize-Project -ScriptRoot $PSScriptRoot

if ($EnsureOnly) {
    $changed = Ensure-AgentsConfig -Agents $Agents -ProxyPort $ProxyPort
    if ($changed) {
        Write-Host "Agent proxy config updated (missing fields only)." -ForegroundColor Green
    }
    exit 0
}

Setup-AgentsConfig -Agents $Agents -ProxyPort $ProxyPort
Write-Host "Ensure proxy is running: bin\start.bat" -ForegroundColor Gray
