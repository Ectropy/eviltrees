<#
.SYNOPSIS
    Installs the PrettyUI UI library into the RS3 beta client's dev_plugins folder.

.DESCRIPTION
    Evil Trees draws its dashboard with PrettyUI (https://github.com/PrettyRS/prettyui),
    a Plugin Hub library. A dev plugin's dependencies aren't downloaded by the client,
    so this script fetches one tagged PrettyUI release with git and copies the files a
    release contains (plugin.json, main.lua, src, resources, LICENSE) into
    dev_plugins\prettyui. plugin\plugin.json points at that folder name.

    Then enable it once in the game console:  pon prettyui
    and reload Evil Trees:                     prl evil-trees

.EXAMPLE
    .\scripts\install-prettyui.ps1
    Installs the pinned version.

.EXAMPLE
    .\scripts\install-prettyui.ps1 -Tag v1.4.0
    Installs another release.

.EXAMPLE
    .\scripts\install-prettyui.ps1 -Hub
    Installs the PrettyUI the Plugin Hub gave this client, from its zip in
    plugins\6398181 (the plugin needs 1.3.0 or later). Install it from
    the Hub first. Use this to test Evil Trees against what players will have.
#>
param(
    # The PrettyUI release (git tag) to install.
    [string]$Tag = "v1.3.0",

    # Install the Hub's copy instead of a GitHub release.
    [switch]$Hub,

    # Where the Hub's copy is: the client's plugins folder for PrettyUI (mod.io ID 6398181).
    [string]$HubPath = "C:\ProgramData\Jagex\RuneScape-BETA\plugins\6398181",

    # The beta client's dev_plugins folder.
    [string]$DevPluginsPath = "C:\ProgramData\Jagex\RuneScape-BETA\dev_plugins"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $DevPluginsPath)) {
    throw "dev_plugins folder not found: $DevPluginsPath (has the beta client been run once?)"
}

if ($Hub) {
    $zip = Join-Path $HubPath "6398181.zip"
    if (-not (Test-Path $zip)) {
        throw "Hub copy not found: $zip (install PrettyUI from the Plugin Hub first)"
    }
    $destination = Join-Path $DevPluginsPath "prettyui"
    if (Test-Path $destination) {
        Remove-Item -Recurse -Force $destination
    }
    Expand-Archive -Path $zip -DestinationPath $destination
    # The version from its plugin.json, to show which one was installed.
    $version = (Get-Content -Raw (Join-Path $destination "plugin.json") | ConvertFrom-Json).version
    $files = (Get-ChildItem -Recurse -File $destination).Count
    Write-Host "Installed the Hub's PrettyUI $version ($files files) to $destination"
    Write-Host "In the game console run:  pon prettyui   then   prl evil-trees"
    return
}

$temp = Join-Path ([System.IO.Path]::GetTempPath()) ("prettyui-" + [guid]::NewGuid())
try {
    # (advice.detachedHead=false: a tag checkout is expected, so skip git's notice about it)
    git -c advice.detachedHead=false clone --quiet --depth 1 --branch $Tag https://github.com/PrettyRS/prettyui.git $temp
    if ($LASTEXITCODE -ne 0) {
        throw "git clone failed for tag $Tag"
    }

    $destination = Join-Path $DevPluginsPath "prettyui"
    if (Test-Path $destination) {
        Remove-Item -Recurse -Force $destination
    }
    New-Item -ItemType Directory $destination | Out-Null
    foreach ($item in "plugin.json", "main.lua", "LICENSE", "src", "resources") {
        Copy-Item -Recurse (Join-Path $temp $item) $destination
    }

    $files = (Get-ChildItem -Recurse -File $destination).Count
    Write-Host "Installed PrettyUI $Tag ($files files) to $destination"
    Write-Host "In the game console run:  pon prettyui   then   prl evil-trees"
}
finally {
    if (Test-Path $temp) {
        Remove-Item -Recurse -Force $temp
    }
}
