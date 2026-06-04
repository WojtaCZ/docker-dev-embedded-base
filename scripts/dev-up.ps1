<#
.SYNOPSIS
    WSL shim — delegates to scripts/dev-up.sh running inside WSL2.

.DESCRIPTION
    This container targets Linux Docker. On Windows, run it through WSL2.
    Ensure Docker Desktop is configured to use the WSL2 backend.

.PARAMETER Workspace
    Host directory to mount at /workspace. Defaults to the current directory.

.PARAMETER NoBuild
    Skip docker build.

.PARAMETER NoPull
    Skip --pull (offline / pinned builds).

.PARAMETER Rebuild
    Force docker build --no-cache.

.EXAMPLE
    .\scripts\dev-up.ps1
    .\scripts\dev-up.ps1 -Workspace C:\code\firmware
    .\scripts\dev-up.ps1 -Rebuild
#>
[CmdletBinding()]
param(
    [string]$Workspace = (Get-Location).Path,
    [switch]$NoBuild,
    [switch]$NoPull,
    [switch]$Rebuild
)

$env:DEV_NO_BUILD = if ($NoBuild)  { "1" } else { "0" }
$env:DEV_NO_PULL  = if ($NoPull)   { "1" } else { "0" }
$env:DEV_REBUILD  = if ($Rebuild)  { "1" } else { "0" }

$wslWorkspace = wsl --exec wslpath -a $Workspace

wsl --cd "$PSScriptRoot/.." -- bash scripts/dev-up.sh $wslWorkspace
