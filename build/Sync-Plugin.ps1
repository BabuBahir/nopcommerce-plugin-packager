<#
.SYNOPSIS
    Mirrors a plugin project from a nopCommerce source tree into a plugin repository.

.DESCRIPTION
    nopCommerce's own source tree is where a plugin is normally developed and run against a
    store; a standalone plugin repository is where it is released from. This keeps the two
    copies honest: it copies the plugin project (and only the project) from the nopCommerce
    tree into the repository, reporting anything that changed or exists in only one place.

    Build output folders and machine specific files are never copied.

.PARAMETER NopCommerceSrc
    Path to the nopCommerce source tree (a clone of nopSolutions/nopCommerce).

.PARAMETER RepoRoot
    Root of the plugin repository to mirror into. Defaults to the parent of this script's
    folder, which is only correct when the script is vendored into a plugin repository.

.PARAMETER Check
    Report differences without writing anything. Exits 1 when the mirror has drifted, which
    makes it usable as a CI guard.

.EXAMPLE
    ./build/Sync-Plugin.ps1 -NopCommerceSrc D:\PROJECTS\miscNopCommerce\nopCommerce_4.90.8_Source

.EXAMPLE
    ./build/Sync-Plugin.ps1 -NopCommerceSrc ..\nopCommerce -RepoRoot . -Check
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$NopCommerceSrc,
    [string]$RepoRoot,
    [switch]$Check
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path.TrimEnd('\', '/')

$excludeDirs = @('obj', 'bin', '.vs', '.git', 'PublishProfiles')
$excludeExts = @('.user', '.pubxml')

function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Fail       { param([string]$Message) throw $Message }

function Test-ExcludedPath {
    param([string]$Root, [string]$FullName)
    $relative = $FullName.Substring($Root.Length).TrimStart('\', '/')
    $segments = @(($relative -replace '\\', '/').Split('/') | Where-Object { $_ })
    if ($segments | Where-Object { $excludeDirs -contains $_ }) { return $true }
    return ($excludeExts -contains [System.IO.Path]::GetExtension($FullName))
}

function Get-RelativeSegments {
    param([string]$Root, [string]$FullName)
    @(($FullName.Substring($Root.Length).TrimStart('\', '/') -replace '\\', '/').Split('/') | Where-Object { $_ })
}

# ------------------------------------------------------------- discover ----

if (-not $NopCommerceSrc) { Fail '-NopCommerceSrc is required' }
$NopCommerceSrc = (Resolve-Path -LiteralPath $NopCommerceSrc).Path.TrimEnd('\', '/')
$pluginsRoot = Join-Path $NopCommerceSrc 'src'
if (-not (Test-Path -LiteralPath $pluginsRoot)) { $pluginsRoot = $NopCommerceSrc }
$pluginsRoot = Join-Path $pluginsRoot 'Plugins'
if (-not (Test-Path -LiteralPath $pluginsRoot)) { Fail "no src/Plugins directory under $NopCommerceSrc" }

$projects = @(Get-ChildItem -LiteralPath $pluginsRoot -Filter '*.csproj' -Recurse -File |
              Where-Object { -not (Test-ExcludedPath -Root $pluginsRoot -FullName $_.FullName) })

if ($projects.Count -eq 0) { Fail "no plugin project found under $pluginsRoot" }
if ($projects.Count -gt 1) {
    Write-Step "Found $($projects.Count) projects under $pluginsRoot"
    Write-Host ($projects | ForEach-Object { "    $($_.FullName)" })
    Fail 'more than one plugin in the tree: pass -ProjectName to choose one'
}

$source = $projects[0].DirectoryName
$projectName = Split-Path -Leaf $source
$destination = Join-Path $RepoRoot $projectName

Write-Step "Mirroring $projectName"
Write-Host "    from      : $source"
Write-Host "    to        : $destination"
Write-Host ''

# ---------------------------------------------------------------- sync ----

$files = @(Get-ChildItem -LiteralPath $source -Recurse -File -Force |
          Where-Object { -not (Test-ExcludedPath -Root $source -FullName $_.FullName) })

$changed = New-Object System.Collections.Generic.List[string]
$removed = New-Object System.Collections.Generic.List[string]

foreach ($file in $files) {
    $relative = $file.FullName.Substring($source.Length).TrimStart('\', '/')
    $target = Join-Path $destination $relative
    $state = if (-not (Test-Path -LiteralPath $target)) { 'new' }
             elseif ((Get-FileHash -LiteralPath $file.FullName -Algorithm MD5).Hash -ne
                     (Get-FileHash -LiteralPath $target -Algorithm MD5).Hash) { 'changed' }
             else { 'same' }
    if ($state -eq 'same') { continue }

    $changed.Add("$state  $relative")
    if ($Check) { continue }
    if ($PSCmdlet.ShouldProcess($target, 'sync from nopCommerce tree')) {
        $parent = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        Copy-Item -LiteralPath $file.FullName -Destination $target -Force
    }
}

if (Test-Path -LiteralPath $destination) {
    foreach ($file in (Get-ChildItem -LiteralPath $destination -Recurse -File -Force |
                       Where-Object { -not (Test-ExcludedPath -Root $destination -FullName $_.FullName) })) {
        $relative = $file.FullName.Substring($destination.Length).TrimStart('\', '/')
        if (-not (Test-Path -LiteralPath (Join-Path $source $relative))) { $removed.Add($relative) }
    }
}

if ($changed.Count -eq 0 -and $removed.Count -eq 0) {
    Write-Host 'in sync - nothing to do' -ForegroundColor Green
    exit 0
}

if ($changed.Count) {
    Write-Host "changed ($($changed.Count)):" -ForegroundColor Yellow
    $changed | ForEach-Object { Write-Host "  $_" }
}
if ($removed.Count) {
    Write-Host "only in repository ($($removed.Count)):" -ForegroundColor Yellow
    $removed | ForEach-Object { Write-Host "  $_" }
}

if ($Check) { exit 1 }
Write-Host ''
Write-Host 'review the changes, then commit' -ForegroundColor Cyan
exit 0
