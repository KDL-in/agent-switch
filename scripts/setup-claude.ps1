#Requires -Version 5.1
<#
.SYNOPSIS
  Configure Claude Code only (alias for setup-agents.ps1 -Agents claude).
#>
param([int]$ProxyPort = 0)

$ErrorActionPreference = "Stop"
$forwardArgs = @{ Agents = @("claude") }
if ($ProxyPort -gt 0) { $forwardArgs.ProxyPort = $ProxyPort }
& "$PSScriptRoot\setup-agents.ps1" @forwardArgs
