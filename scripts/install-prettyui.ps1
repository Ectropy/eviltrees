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
#>
param(
    # The PrettyUI release (git tag) to install.
    [string]$Tag = "v1.3.0",

    # The beta client's dev_plugins folder.
    [string]$DevPluginsPath = "C:\ProgramData\Jagex\RuneScape-BETA\dev_plugins"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $DevPluginsPath)) {
    throw "dev_plugins folder not found: $DevPluginsPath (has the beta client been run once?)"
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
