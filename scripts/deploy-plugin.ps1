<#
.SYNOPSIS
    Copies the plugin in this repo's plugin\ folder into the RS3 beta client's dev_plugins folder.

.DESCRIPTION
    Replaces the plugin's folder in dev_plugins with a fresh copy, so files deleted
    here don't linger there. Only that one plugin folder is touched.
    After deploying, reload in the game console with:  prl <plugin-name>
    (or, if it was turned off by a world hop:  pon <plugin-name>)

    PrettyUI: plugin\plugin.json names the Plugin Hub's PrettyUI by its ID
    ("prettyui": 6398181), as a release must. A dev plugin can't use a Hub ID
    (beta, 2026-11-18: prettyui came through empty), so the deployed copy is
    changed to the dev folder ("prettyui": "prettyui"), which
    scripts\install-prettyui.ps1 fills. -HubDependency keeps the Hub ID.

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

.EXAMPLE
    .\scripts\deploy-plugin.ps1 -Effects
    Deploys the local effects lab (research\effectslab, not in git) as dev_plugins\evil-trees-effects-lab.
#>
param(
    # Deploy the research probe instead of the real plugin.
    [switch]$Probe,

    # Deploy the grid lab (UI experiments) instead of the real plugin.
    [switch]$Lab,

    # Deploy the sprite lab (icon candidates) instead of the real plugin.
    [switch]$Sprites,

    # Deploy the effects lab (lightning and sparks on a canvas) instead of the real plugin.
    [switch]$Effects,

    # Keep plugin.json's Hub ID for PrettyUI instead of the dev folder (see above).
    [switch]$HubDependency,

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
} elseif ($Effects) {
    $relative = "research\effectslab"
    $Name = "evil-trees-effects-lab"
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

# The real plugin: point the deployed copy's PrettyUI dependency at the dev
# folder (see the description at the top).
if ($relative -eq "plugin" -and -not $HubDependency) {
    $manifest = Join-Path $destination "plugin.json"
    $text = [System.IO.File]::ReadAllText($manifest)
    $hubId = '"prettyui":\s*6398181'
    if ($text -match $hubId) {
        $text = $text -replace $hubId, '"prettyui": "prettyui"'
        # UTF-8 without a byte order mark, like the original.
        [System.IO.File]::WriteAllText($manifest, $text, (New-Object System.Text.UTF8Encoding $false))
        Write-Host "PrettyUI dependency: dev folder dev_plugins\prettyui (plugin\plugin.json keeps the Hub ID)"
    } else {
        Write-Warning "plugin.json has no '""prettyui"": 6398181' to change; deployed as is"
    }
}

$files = (Get-ChildItem -Recurse -File $destination).Count
Write-Host "Deployed $relative ($files files) to $destination"
Write-Host "In the game console run:  prl $Name   (or pon $Name if it's off)"
