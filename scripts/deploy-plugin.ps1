<#
.SYNOPSIS
    Copies the plugin in this repo's plugin\ folder into the RS3 beta client's dev_plugins folder.

.DESCRIPTION
    Replaces the plugin's folder in dev_plugins with a fresh copy, so files deleted
    here don't linger there. Only that one plugin folder is touched.
    After deploying, reload in the game console with:  prl <plugin-name>
    (or, if it was turned off by a world hop:  pon <plugin-name>)

.EXAMPLE
    .\scripts\deploy-plugin.ps1
    Deploys plugin\ as dev_plugins\evil-trees.

.EXAMPLE
    .\scripts\deploy-plugin.ps1 -Probe
    Deploys the local research probe (research\probe, not in git) as dev_plugins\evil-trees-probe.

.EXAMPLE
    .\scripts\deploy-plugin.ps1 -Lab
    Deploys the local grid lab (research\gridlab, not in git) as dev_plugins\evil-trees-grid-lab.

.EXAMPLE
    .\scripts\deploy-plugin.ps1 -Sprites
    Deploys the local sprite lab (research\spritelab, not in git) as dev_plugins\evil-trees-sprite-lab.
#>
param(
    # Deploy the research probe instead of the real plugin.
    [switch]$Probe,

    # Deploy the grid lab (UI experiments) instead of the real plugin.
    [switch]$Lab,

    # Deploy the sprite lab (icon candidates) instead of the real plugin.
    [switch]$Sprites,

    # The beta client's dev_plugins folder.
    [string]$DevPluginsPath = "C:\ProgramData\Jagex\RuneScape-BETA\dev_plugins"
)

$ErrorActionPreference = "Stop"

# $Name is the folder name in dev_plugins, which is also the name pon/prl use.
if ($Probe) {
    $relative = "research\probe"
    $Name = "evil-trees-probe"
} elseif ($Lab) {
    $relative = "research\gridlab"
    $Name = "evil-trees-grid-lab"
} elseif ($Sprites) {
    $relative = "research\spritelab"
    $Name = "evil-trees-sprite-lab"
} else {
    $relative = "plugin"
    $Name = "evil-trees"
}

$source = Join-Path $PSScriptRoot "..\$relative" | Resolve-Path -ErrorAction SilentlyContinue
if (-not $source) {
    throw "Plugin folder not found: $relative"
}
foreach ($required in "main.lua", "plugin.json") {
    if (-not (Test-Path (Join-Path $source $required))) {
        throw "$relative is missing $required"
    }
}
if (-not (Test-Path $DevPluginsPath)) {
    throw "dev_plugins folder not found: $DevPluginsPath (has the beta client been run once?)"
}

$destination = Join-Path $DevPluginsPath $Name
if (Test-Path $destination) {
    Remove-Item -Recurse -Force $destination
}
Copy-Item -Recurse $source $destination

$files = (Get-ChildItem -Recurse -File $destination).Count
Write-Host "Deployed $relative ($files files) to $destination"
Write-Host "In the game console run:  prl $Name   (or pon $Name if it's off)"
