<#
.SYNOPSIS
    Copies a plugin from this repo's plugins\ folder into the RS3 beta client's dev_plugins folder.

.DESCRIPTION
    Replaces the plugin's folder in dev_plugins with a fresh copy, so files deleted
    here don't linger there. Only that one plugin folder is touched.
    After deploying, reload in the game console with:  prl <plugin-name>
    (or, if it was turned off by a world hop:  pon <plugin-name>)

.EXAMPLE
    .\scripts\deploy-plugin.ps1
    Deploys the default plugin (plugins\evil-trees).
#>
param(
    # Folder name under plugins\ (this is also the name used by pon/prl in the console).
    [string]$Name = "evil-trees",

    # The beta client's dev_plugins folder.
    [string]$DevPluginsPath = "C:\ProgramData\Jagex\RuneScape-BETA\dev_plugins"
)

$ErrorActionPreference = "Stop"

$source = Join-Path $PSScriptRoot "..\plugins\$Name" | Resolve-Path -ErrorAction SilentlyContinue
if (-not $source) {
    throw "Plugin folder not found: plugins\$Name"
}
foreach ($required in "main.lua", "plugin.json") {
    if (-not (Test-Path (Join-Path $source $required))) {
        throw "plugins\$Name is missing $required"
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
Write-Host "Deployed $Name ($files files) to $destination"
Write-Host "In the game console run:  prl $Name   (or pon $Name if it's off)"
