#Requires -Version 5.1
param(
    [string]$Group = "",
    [string]$Node = "",
    [string]$ApiUrl = "http://127.0.0.1:9090"
)

$ErrorActionPreference = "Stop"

function Get-ClashJson {
    param([string]$Path)
    return Invoke-RestMethod -Uri "$ApiUrl$Path" -TimeoutSec 10
}

function Set-ClashProxy {
    param([string]$GroupName, [string]$NodeName)
    $encoded = [uri]::EscapeDataString($GroupName)
    $body = @{ name = $NodeName } | ConvertTo-Json -Compress
    Invoke-RestMethod -Uri "$ApiUrl/proxies/$encoded" -Method Put -Body $body -ContentType "application/json" -TimeoutSec 10 | Out-Null
}

function Show-ProxyGroups {
    $data = Get-ClashJson "/proxies"
    $groups = @()
    $index = 1
    foreach ($entry in $data.proxies.PSObject.Properties) {
        $p = $entry.Value
        if ($p.type -in @("Selector", "select", "URLTest", "url-test", "Fallback", "fallback", "LoadBalance", "load-balance")) {
            $groups += [PSCustomObject]@{
                Index = $index++
                Name = $entry.Name
                Type = $p.type
                Now = $p.now
                All = @($p.all)
            }
        }
    }
    return $groups
}

try {
    $groups = Show-ProxyGroups
    if ($groups.Count -eq 0) { throw "No selectable proxy groups found. Is Clash running on $ApiUrl ?" }

    if ($Group -and $Node) {
        Set-ClashProxy -GroupName $Group -NodeName $Node
        Write-Host "Switched [$Group] -> $Node" -ForegroundColor Green
        exit 0
    }

    Write-Host "`nClash proxy groups:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $groups.Count; $i++) {
        $g = $groups[$i]
        Write-Host ("  [{0}] {1}  (current: {2})" -f ($i + 1), $g.Name, $g.Now)
    }

    $groupChoice = Read-Host "`nSelect group number"
    $groupIndex = [int]$groupChoice - 1
    if ($groupIndex -lt 0 -or $groupIndex -ge $groups.Count) { throw "Invalid group selection" }
    $selectedGroup = $groups[$groupIndex]

    Write-Host "`nNodes in [$($selectedGroup.Name)]:" -ForegroundColor Cyan
    for ($j = 0; $j -lt $selectedGroup.All.Count; $j++) {
        $nodeName = $selectedGroup.All[$j]
        $mark = if ($nodeName -eq $selectedGroup.Now) { " *" } else { "" }
        Write-Host ("  [{0}] {1}{2}" -f ($j + 1), $nodeName, $mark)
    }

    $nodeChoice = Read-Host "`nSelect node number"
    $nodeIndex = [int]$nodeChoice - 1
    if ($nodeIndex -lt 0 -or $nodeIndex -ge $selectedGroup.All.Count) { throw "Invalid node selection" }

    Set-ClashProxy -GroupName $selectedGroup.Name -NodeName $selectedGroup.All[$nodeIndex]
    Write-Host "`nDone: [$($selectedGroup.Name)] -> $($selectedGroup.All[$nodeIndex])" -ForegroundColor Green
} catch {
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Tip: run bin\start.bat first, API should be at $ApiUrl" -ForegroundColor Yellow
    exit 1
}
