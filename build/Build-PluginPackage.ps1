<#
.SYNOPSIS
    Builds a nopCommerce plugin against a nopCommerce source tree and produces an
    uploadable plugin package (.zip).

.DESCRIPTION
    Generic: nothing about a specific plugin is hardcoded. The plugin project, assembly
    name, plugin folder, system name and target nopCommerce version are all discovered,
    so the same script packages any nopCommerce plugin repository.

    Steps: discover -> build -> guard -> collect -> stage -> zip -> verify -> metadata.

    Two package layouts are produced, selected with -PackageLayout Auto (the default):

      Marketplace  For nopCommerce marketplace submissions. The repository's own
                   uploadedItems.json is the manifest, so a multi-version manifest is
                   fine: binaries are staged at each entry's DirectoryPath and sources at
                   its SourceDirectoryPath, and nopCommerce skips the versions it cannot
                   use. Selected when uploadedItems.json exists in the repository root.

      Single       For "Upload plugin" in the admin. The archive contains exactly one root
                   directory, named after the plugin's system name, holding the build
                   output. nopCommerce's UploadSingleItemAsync rejects an archive with more
                   than one root entry, so no README/LICENSE is added at the root.

    nopCommerce-specific details this script exists to enforce:

      * $(SolutionDir) must be passed to the build. The plugin csproj has a
        ProjectReference to Nop.Web.csproj, and outside the solution that variable is
        empty, so the build fails with ~61 CS0246 errors.

      * Entry names are written with forward slashes. Compress-Archive on Windows
        PowerShell 5.1 stores backslash separated names, and nopCommerce matches
        entry.FullName against forward-slash literals, so such an archive uploads as
        "0 plugins and 0 themes have been uploaded".

      * A .NET reference assembly must never be shipped. It has no method bodies, so the
        plugin installs and then fails. Roslyn emits one next to the real output under
        obj\<Config>\<tfm>\ref\, and it is trivially easy to copy by mistake.

      * The build output folder also receives the referenced Nop.Web project's output
        (Nop.Web.staticwebassets.*.json alone is ~4 MB). Only the plugin's own declared
        content and assembly are packaged.

    The verification pass replays nopCommerce's upload logic against the finished
    archive, so a package that would report zero plugins fails the build instead of
    failing silently in the admin.

.PARAMETER RepoRoot
    Root of the plugin repository. Defaults to the parent of this script's folder, which
    is only correct when the script is vendored into a plugin repository.

.PARAMETER NopCommerceSrc
    Path to the nopCommerce source tree (a clone of nopSolutions/nopCommerce). Required
    unless -VerifyOnly is used.

.PARAMETER NopCommerceVersion
    nopCommerce version to build against. Defaults to the target tree's own
    NopVersion.CURRENT_VERSION.

.PARAMETER Configuration
    Build configuration. Defaults to Release.

.PARAMETER ProjectPath
    Path to the plugin csproj. Discovered when omitted: the single *.csproj within two
    levels of -RepoRoot.

.PARAMETER OutputZip
    Where to write the package. Defaults to <RepoRoot>/../<SystemName>.zip. A
    <OutputZip>.json metadata sidecar is written next to it.

.PARAMETER PackageLayout
    Auto (default), Marketplace or Single. See .DESCRIPTION.

.PARAMETER SkipBuild
    Package whatever is already in the build output.

.PARAMETER VerifyOnly
    Skip discover, build, stage and zip; only run verification over -OutputZip.

.EXAMPLE
    ./build/Build-PluginPackage.ps1 -RepoRoot .. -NopCommerceSrc /path/to/nopCommerce

.EXAMPLE
    pwsh ./build/Build-PluginPackage.ps1 -RepoRoot . -NopCommerceSrc ../nopCommerce -PackageLayout Single

.EXAMPLE
    ./build/Build-PluginPackage.ps1 -VerifyOnly -OutputZip ./out/plugin-package.zip
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$NopCommerceSrc,
    [string]$NopCommerceVersion,
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',
    [string]$ProjectPath,
    [string]$OutputZip,
    [ValidateSet('Auto', 'Marketplace', 'Single')]
    [string]$PackageLayout = 'Auto',
    [switch]$SkipBuild,
    [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:entriesWritten = 0
$script:fileCount = 0

function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "    OK  $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "    !!  $Message" -ForegroundColor Yellow }
function Fail       { param([string]$Message) throw $Message }

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

# ----------------------------------------------------------------- utilities ----

# Forward-slash segments of a path relative to a root, so entry names never inherit a
# platform separator. Works for both 'a\b\c' and 'a/b/c'.
function Get-RelativeSegments {
    param([string]$Root, [string]$FullName)
    @(($FullName.Substring($Root.Length).TrimStart('\', '/') -replace '\\', '/').Split('/') | Where-Object { $_ })
}

function Test-ExcludedPath {
    param([string]$Root, [string]$FullName, [string[]]$DirNames, [string[]]$Extensions)
    foreach ($segment in @(Get-RelativeSegments -Root $Root -FullName $FullName)) {
        if ($DirNames -contains $segment) { return $true }
    }
    return ($Extensions -contains [System.IO.Path]::GetExtension($FullName))
}

function New-Entry {
    param($Archive, [string]$EntryName, [string]$SourceFile)
    $entry = $Archive.CreateEntry($EntryName, [System.IO.Compression.CompressionLevel]::Optimal)
    $stream = $entry.Open()
    try {
        $bytes = [System.IO.File]::ReadAllBytes($SourceFile)
        $stream.Write($bytes, 0, $bytes.Length)
    }
    finally { $stream.Dispose() }
    # counted as written, so the reported number always matches the archive
    $script:entriesWritten++
    $script:fileCount++
}

function New-DirEntry {
    param($Archive, [string]$EntryName)
    [void]$Archive.CreateEntry($EntryName)
    $script:entriesWritten++
}

function Add-Tree {
    param($Archive, [string]$OnDiskRoot, [string]$ZipPrefix, [string[]]$DirNames = @(), [string[]]$Extensions = @())

    foreach ($dir in (Get-ChildItem -LiteralPath $OnDiskRoot -Recurse -Directory -Force | Sort-Object FullName)) {
        $segments = Get-RelativeSegments -Root $OnDiskRoot -FullName $dir.FullName
        if ($segments | Where-Object { $DirNames -contains $_ }) { continue }
        New-DirEntry -Archive $Archive -EntryName "$ZipPrefix/$($segments -join '/')/"
    }
    foreach ($file in (Get-ChildItem -LiteralPath $OnDiskRoot -Recurse -File -Force | Sort-Object FullName)) {
        if (Test-ExcludedPath -Root $OnDiskRoot -FullName $file.FullName -DirNames $DirNames -Extensions $Extensions) { continue }
        $segments = Get-RelativeSegments -Root $OnDiskRoot -FullName $file.FullName
        New-Entry -Archive $Archive -EntryName "$ZipPrefix/$($segments -join '/')" -SourceFile $file.FullName
    }
}

function Get-PropertyValue {
    param($Project, [string]$Name)
    foreach ($group in @($Project.Project.PropertyGroup)) {
        foreach ($child in $group.ChildNodes) {
            if ($child.Name -eq $Name -and -not [string]::IsNullOrWhiteSpace($child.InnerText)) { return $child.InnerText.Trim() }
        }
    }
    return $null
}

# --------------------------------------------------------------- discover ----

if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path.TrimEnd('\', '/')
if (-not (Test-Path -LiteralPath $RepoRoot -PathType Container)) { Fail "repository root not found: $RepoRoot" }

$projectDir    = $null
$projectFile   = $null
$assemblyName  = $null
$pluginJson    = $null
$pluginDirName = $null
$layout        = $PackageLayout
$manifest      = $null

function Find-PluginProject {
    param([string]$Root, [string]$Explicit)
    if ($Explicit) {
        if (-not (Test-Path -LiteralPath $Explicit)) { Fail "project not found: $Explicit" }
        return (Resolve-Path -LiteralPath $Explicit).Path
    }
    $candidates = Get-ChildItem -LiteralPath $Root -Filter '*.csproj' -Recurse -Depth 2 -File |
                  Where-Object { -not (Test-ExcludedPath -Root $Root -FullName $_.FullName -DirNames @('obj', 'bin', '.vs', '.git') -Extensions @()) }
    if (-not $candidates) { Fail "no plugin project found within two levels of $Root. Pass -ProjectPath." }
    if (@($candidates).Count -gt 1) {
        Fail "more than one project found, pass -ProjectPath: $((@($candidates) | ForEach-Object { $_.FullName }) -join ', ')"
    }
    return $candidates[0].FullName
}

if (-not $VerifyOnly) {
    Write-Step "Discovering plugin in $RepoRoot"
    $projectFile = Find-PluginProject -Root $RepoRoot -Explicit $ProjectPath
    $projectDir  = Split-Path -Parent $projectFile

    $csproj = [xml](Get-Content -LiteralPath $projectFile -Raw)
    $assemblyName = Get-PropertyValue -Project $csproj -Name 'AssemblyName'
    if (-not $assemblyName) { $assemblyName = [System.IO.Path]::GetFileNameWithoutExtension($projectFile) }

    $jsonPath = Join-Path $projectDir 'plugin.json'
    if (-not (Test-Path -LiteralPath $jsonPath)) { Fail "plugin.json not found next to the project: $jsonPath" }
    $pluginJson = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json

    if (-not $pluginJson.SystemName) { Fail 'plugin.json has no SystemName' }
    if (-not $pluginJson.FileName)   { Fail 'plugin.json has no FileName' }

    # the deployed folder must be the system name: nopCommerce deploys the folder as-is and
    # plugin view paths are ~/Plugins/<SystemName>/...
    $outputPath = Get-PropertyValue -Project $csproj -Name 'OutputPath'
    if ($outputPath) {
        $pluginDirName = ($outputPath.TrimEnd('\', '/') -split '[\\/]')[-1]
        if ($pluginDirName -ne $pluginJson.SystemName) {
            Write-Warn "csproj OutputPath ends in '$pluginDirName' but SystemName is '$($pluginJson.SystemName)'; packaging as '$($pluginJson.SystemName)'"
        }
    }
    if (-not $pluginDirName) { $pluginDirName = $pluginJson.SystemName }

    if ($layout -eq 'Auto') {
        $layout = if (Test-Path -LiteralPath (Join-Path $RepoRoot 'uploadedItems.json')) { 'Marketplace' } else { 'Single' }
    }
    Write-Ok "project   : $([System.IO.Path]::GetFileName($projectFile))"
    Write-Ok "assembly  : $assemblyName (plugin folder $pluginDirName)"
    Write-Ok "system    : $($pluginJson.SystemName) - $($pluginJson.FriendlyName) $($pluginJson.Version)"
    Write-Ok "layout    : $layout"

    # ------------------------------------------------- nopCommerce source tree ----
    if (-not $NopCommerceSrc) { Fail '-NopCommerceSrc is required unless -VerifyOnly is used' }
    $NopCommerceSrc = (Resolve-Path -LiteralPath $NopCommerceSrc).Path.TrimEnd('\', '/')

    $globalJson = Get-ChildItem -LiteralPath $NopCommerceSrc -Filter 'global.json' -Recurse -Depth 2 -File | Select-Object -First 1
    if (-not $globalJson) { Fail "global.json not found under $NopCommerceSrc; is it a nopCommerce source tree?" }
    $treeRoot = $globalJson.DirectoryName
    $solutionDir = if (Test-Path -LiteralPath (Join-Path $treeRoot 'src')) { Join-Path $treeRoot 'src' } else { $treeRoot }

    $nopWeb = Get-ChildItem -LiteralPath $solutionDir -Filter 'Nop.Web.csproj' -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $nopWeb) { Fail "Nop.Web.csproj not found under $solutionDir; the plugin's ProjectReference cannot resolve" }

    if (-not $NopCommerceVersion) {
        $versionFile = Get-ChildItem -LiteralPath $solutionDir -Filter 'NopVersion.cs' -Recurse -File | Select-Object -First 1
        if (-not $versionFile) { Fail 'NopVersion.cs not found; pass -NopCommerceVersion explicitly' }
        $match = Select-String -LiteralPath $versionFile.FullName -Pattern 'CURRENT_VERSION\s*=\s*"([^"]+)"' | Select-Object -First 1
        if (-not $match) { Fail 'could not read CURRENT_VERSION from NopVersion.cs; pass -NopCommerceVersion explicitly' }
        $NopCommerceVersion = $match.Matches[0].Groups[1].Value
    }
    Write-Ok "target    : nopCommerce $NopCommerceVersion ($solutionDir)"

    if ($pluginJson.SupportedVersions -notcontains $NopCommerceVersion) {
        Fail "plugin.json SupportedVersions ($($pluginJson.SupportedVersions -join ', ')) does not include $NopCommerceVersion"
    }
    if ($pluginJson.FileName -ne "$assemblyName.dll") {
        Write-Warn "plugin.json FileName '$($pluginJson.FileName)' but assembly is '$assemblyName.dll'"
    }

    if ($layout -eq 'Marketplace') {
        $manifestPath = Join-Path $RepoRoot 'uploadedItems.json'
        if (-not (Test-Path -LiteralPath $manifestPath)) { Fail "uploadedItems.json not found: $manifestPath" }
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $usable = @($manifest | Where-Object { -not $_.Type -or ($_.SupportedVersion -and $_.SupportedVersion.Contains($NopCommerceVersion)) })
        foreach ($item in $usable) {
            if (-not $item.DirectoryPath) { Fail 'uploadedItems.json entry without DirectoryPath' }
            if ($item.SystemName -ne $pluginJson.SystemName) {
                Write-Warn "uploadedItems.json entry SystemName '$($item.SystemName)' != plugin.json '$($pluginJson.SystemName)'"
            }
        }
        $skipped = @($manifest).Count - @($usable).Count
        Write-Ok "manifest  : $(@($usable).Count) of $(@($manifest).Count) entries target $NopCommerceVersion$($(if($skipped){", $skipped left for nopCommerce to filter"}))"
    }

    # ------------------------------------------------------------- build ----
    if ($SkipBuild) {
        Write-Step "Skipping build (-SkipBuild)"
    }
    else {
        Write-Step "Building $assemblyName ($Configuration)"
        # $(SolutionDir) is mandatory outside the solution; see .DESCRIPTION
        & dotnet build $projectFile -c $Configuration -v minimal "-p:SolutionDir=$solutionDir\"
        if ($LASTEXITCODE -ne 0) { Fail "dotnet build failed (exit $LASTEXITCODE)" }
    }

    # Locate the built assembly. The project's own OutputPath is authoritative, because an
    # incremental build does not rewrite the file and so cannot be found by timestamp.
    # Discovery is only a fallback for projects that declare no usable OutputPath.
    $assemblyFilter = "$assemblyName.dll"
    $assemblyPath = $null

    if ($outputPath) {
        $declared = $outputPath -replace '\$\(SolutionDir\)', ($solutionDir.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar)
        $declared = ($declared -replace '/', [System.IO.Path]::DirectorySeparatorChar) -replace '\\', [System.IO.Path]::DirectorySeparatorChar
        if ($declared -notmatch '\$\(') {
            $declaredAssembly = Join-Path $declared $assemblyFilter
            if (Test-Path -LiteralPath $declaredAssembly) { $assemblyPath = (Get-Item -LiteralPath $declaredAssembly).FullName }
        }
    }
    if (-not $assemblyPath) {
        $found = Get-ChildItem -LiteralPath $solutionDir -Filter $assemblyFilter -Recurse -File -ErrorAction SilentlyContinue |
                 Where-Object { -not (Test-ExcludedPath -Root $solutionDir -FullName $_.FullName -DirNames @('obj', 'bin', '.vs', '.git', 'ref', 'refint') -Extensions @()) } |
                 Sort-Object LastWriteTime -Descending
        if ($found) { $assemblyPath = $found[0].FullName; Write-Warn "build output taken from discovery, not OutputPath: $assemblyPath" }
    }
    if (-not $assemblyPath) { Fail "build output $assemblyFilter not found; pass a correct -NopCommerceSrc" }

    $builtAssembly = Get-Item -LiteralPath $assemblyPath
    $buildOutput = $builtAssembly.DirectoryName
    if ((Split-Path -Leaf $buildOutput) -ne $pluginJson.SystemName) {
        Write-Warn "build output folder is '$(Split-Path -Leaf $buildOutput)' but SystemName is '$($pluginJson.SystemName)'"
    }

    # ------------------------------------------ guard against a ref assembly ----
    $refSearchRoots = @(
        (Join-Path $projectDir 'obj')
        (Join-Path $solutionDir "Plugins\$assemblyName\obj")
    ) | Where-Object { Test-Path -LiteralPath $_ }
    $refAssemblies = foreach ($root in $refSearchRoots) {
        Get-ChildItem -LiteralPath $root -Recurse -Filter "$assemblyName.dll" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Directory.Name -in @('ref', 'refint', 'bin') }
    }
    $assemblyHash = (Get-FileHash -LiteralPath $builtAssembly.FullName -Algorithm MD5).Hash
    foreach ($ref in $refAssemblies) {
        if ((Get-FileHash -LiteralPath $ref.FullName -Algorithm MD5).Hash -eq $assemblyHash) {
            Fail "build output is a reference assembly (identical to $($ref.FullName)); it has no method bodies and the plugin would fail to load"
        }
    }
    Write-Ok "assembly  : real build, $($builtAssembly.Length) bytes, md5 $assemblyHash ($(@($refAssemblies).Count) reference assemblies compared)"

    # ------------------------------------------------- collect the payload ----
    # The project's own <Content Include> items are the authoritative list of what has to
    # ship alongside the assembly, so logos of any name, extra views and locales work
    # without touching this script.
    $contentNames = foreach ($itemGroup in @($csproj.DocumentElement.ChildNodes | Where-Object { $_.Name -eq 'ItemGroup' })) {
        foreach ($item in @($itemGroup.ChildNodes | Where-Object { $_.Name -eq 'Content' })) {
            $include = $item.GetAttribute('Include')
            if (-not [string]::IsNullOrWhiteSpace($include)) { $include }
        }
    }
    $payload = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    $payload.Add($builtAssembly)
    $pdb = Join-Path $buildOutput "$assemblyName.pdb"
    if (Test-Path -LiteralPath $pdb) { $payload.Add((Get-Item -LiteralPath $pdb)) }

    if (@($contentNames).Count) {
        foreach ($include in $contentNames) {
            $relative = $include -replace '\\', '/'
            # prefer the copy in the build output, fall back to the project file
            $inOutput = Join-Path $buildOutput ($relative -replace '/', '\')
            $origin = if (Test-Path -LiteralPath $inOutput) { $inOutput } else { Join-Path $projectDir ($relative -replace '/', '\') }
            if (-not (Test-Path -LiteralPath $origin)) { Fail "content file declared by the project is missing: $include" }
            $payload.Add((Get-Item -LiteralPath $origin))
        }
    }
    else {
        Write-Warn 'project declares no <Content> items; falling back to build output discovery'
        $payload += Get-ChildItem -LiteralPath $buildOutput -Recurse -File |
                    Where-Object { $_.Name -notlike 'Nop.Web.*' -and $_.Extension -ne '.deps.json' -and $_.FullName -notmatch '\\(obj|bin)\\' }
    }
    $payload = @($payload | Sort-Object FullName -Unique)
    Write-Ok "payload   : $($payload.Count) files declared by the project + assembly"

    # -------------------------------------------------------------- stage ----
    if (-not $OutputZip) { $OutputZip = Join-Path (Split-Path -Parent $RepoRoot) "$($pluginJson.SystemName).zip" }
    $zipDir = Split-Path -Parent $OutputZip
    if ($zipDir -and -not (Test-Path -LiteralPath $zipDir)) { New-Item -ItemType Directory -Path $zipDir -Force | Out-Null }
    if (Test-Path -LiteralPath $OutputZip) { Remove-Item -LiteralPath $OutputZip -Force }

    Write-Step "Writing $OutputZip"
    $archive = [System.IO.Compression.ZipFile]::Open($OutputZip, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        if ($layout -eq 'Single') {
            # exactly one root entry, named after the system name
            $root = $pluginJson.SystemName
            New-DirEntry -Archive $archive -EntryName "$root/"
            foreach ($file in $payload) {
                $segments = Get-RelativeSegments -Root $buildOutput -FullName $file.FullName
                New-Entry -Archive $archive -EntryName "$root/$($segments -join '/')" -SourceFile $file.FullName
            }
        }
        else {
            # uploadedItems.json is the manifest: its paths are archive paths, not
            # repository paths. Sources always come from the discovered project directory.
            foreach ($item in $usable) {
                $binPrefix = $item.DirectoryPath.TrimEnd('/')
                $srcPrefix = if ($item.SourceDirectoryPath) { $item.SourceDirectoryPath.TrimEnd('/') } else { $binPrefix }
                foreach ($file in $payload) {
                    $segments = Get-RelativeSegments -Root $buildOutput -FullName $file.FullName
                    New-Entry -Archive $archive -EntryName "$binPrefix/$($segments -join '/')" -SourceFile $file.FullName
                }
                Add-Tree -Archive $archive -OnDiskRoot $projectDir -ZipPrefix $srcPrefix `
                         -DirNames @('obj', 'bin', '.vs', '.git', 'PublishProfiles') -Extensions @('.user', '.pubxml')
            }
            New-Entry -Archive $archive -EntryName 'uploadedItems.json' -SourceFile $manifestPath
            $readme = Join-Path $RepoRoot 'Readme.txt'
            if (Test-Path -LiteralPath $readme) { New-Entry -Archive $archive -EntryName 'Readme.txt' -SourceFile $readme }        }
    }
    finally { $archive.Dispose() }
    $entryCount = $script:entriesWritten
    Write-Ok "archive   : $entryCount entries ($script:fileCount files + $($entryCount - $script:fileCount) directories)"
}

# ------------------------------------------------------------- verify ----
# Replay nopCommerce's upload logic against the finished archive. Anything that would make
# the admin report "0 plugins and 0 themes have been uploaded" fails here.
function Read-ZipEntryText {
    param($Entry)
    $stream = $Entry.Open()
    $reader = New-Object System.IO.StreamReader($stream)
    try { $reader.ReadToEnd() }
    finally { $reader.Dispose(); $stream.Dispose() }
}

$problems  = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]
$verified = New-Object System.Collections.Generic.List[string]

Write-Step "Verifying $OutputZip"
if (-not (Test-Path -LiteralPath $OutputZip)) { Fail "package not found: $OutputZip" }

$zip = [System.IO.Compression.ZipFile]::OpenRead($OutputZip)
try {
    $entries  = @($zip.Entries)
    $fullName = @($entries | ForEach-Object { $_.FullName })
    $entryCount = $entries.Count

    $backslash = @($fullName | Where-Object { $_ -like '*\*' })
    if ($backslash.Count) { $problems.Add("$($backslash.Count) backslash entry name(s), e.g. $($backslash[0])") }

    $residue = @($fullName | Where-Object {
        $_ -match '(^|/)(obj|bin)/' -or $_ -like '*.user' -or $_ -like '*.pubxml' -or $_ -like '*staticwebassets*'
    })
    if ($residue.Count) { $problems.Add("$($residue.Count) build residue or referenced-project file(s)") }

    $rootEntries = @($fullName | ForEach-Object { ($_ -split '/')[0] } | Sort-Object -Unique)

    $manifestEntry = $entries | Where-Object { $_.Name -eq 'uploadedItems.json' -and $_.FullName -notmatch '/' }
    if ($manifestEntry) {
        # UploadMultipleItemsAsync path
        foreach ($item in (Read-ZipEntryText $manifestEntry | ConvertFrom-Json)) {
            if (-not $item.Type) { $problems.Add('uploadedItems.json entry without Type'); continue }
            if ($item.SupportedVersion -and $NopCommerceVersion -and -not $item.SupportedVersion.Contains($NopCommerceVersion)) {
                $warnings.Add("uploadedItems.json '$($item.SupportedVersion)' does not target $NopCommerceVersion; nopCommerce will skip it")
                continue
            }
            $itemPath = "$($item.DirectoryPath.TrimEnd('/'))/"
            $descriptor = $entries | Where-Object { $_.FullName -eq "$itemPath" + 'plugin.json' }
            if (-not $descriptor) { $problems.Add("plugin.json is not resolvable at '$itemPath" + "plugin.json'"); continue }

            $descriptorJson = Read-ZipEntryText $descriptor | ConvertFrom-Json
            if ($NopCommerceVersion -and -not $descriptorJson.SupportedVersions.Contains($NopCommerceVersion)) {
                $problems.Add("plugin.json SupportedVersions '$($descriptorJson.SupportedVersions -join ',')' excludes $NopCommerceVersion")
            }
            $targetDir = ($itemPath.TrimEnd('/') -split '/')[-1]
            if ($targetDir -ne $descriptorJson.SystemName) {
                $problems.Add("deployed folder '$targetDir' != SystemName '$($descriptorJson.SystemName)'")
            }
            $staged = @($entries | Where-Object { $_.FullName.StartsWith($itemPath, [System.StringComparison]::OrdinalIgnoreCase) })
            if (-not ($entries | Where-Object { $_.FullName -eq "$itemPath" + $descriptorJson.FileName })) {
                $problems.Add("main assembly '$($descriptorJson.FileName)' missing from the package")
            }
            $verified.Add("$($descriptorJson.SystemName) -> ~/Plugins/Uploaded/$targetDir ($($staged.Count) entries)")
            Write-Ok "installs to ~/Plugins/Uploaded/$targetDir ($($staged.Count) entries, $($descriptorJson.FriendlyName) $($descriptorJson.Version))"
        }
    }
    else {
        # UploadSingleItemAsync path
        $roots = @($rootEntries)
        if ($roots.Count -ne 1) {
            $problems.Add("the archive must contain exactly one root entry, found $($roots.Count): $($roots -join ', ')")
        }
        else {
            $root = $roots[0]
            if (-not (Test-Path -LiteralPath $OutputZip)) { $problems.Add('package vanished during verification') }
            $dirEntry = $entries | Where-Object { $_.FullName -eq "$root/" -or $_.FullName -eq $root }
            if (-not $dirEntry) { $problems.Add("root entry '$root' is not a directory") }
            $descriptor = $entries | Where-Object { $_.FullName -eq "$root" + '/plugin.json' }
            if (-not $descriptor) { $problems.Add("plugin.json is not resolvable at '$root" + "/plugin.json'"); }
            else {
                $descriptorJson = Read-ZipEntryText $descriptor | ConvertFrom-Json
                if ($root -ne $descriptorJson.SystemName) {
                    $problems.Add("root directory '$root' != SystemName '$($descriptorJson.SystemName)'")
                }
                if ($NopCommerceVersion -and -not $descriptorJson.SupportedVersions.Contains($NopCommerceVersion)) {
                    $problems.Add("plugin.json SupportedVersions '$($descriptorJson.SupportedVersions -join ',')' excludes $NopCommerceVersion")
                }
                if (-not ($entries | Where-Object { $_.FullName -eq "$root/" + $descriptorJson.FileName })) {
                    $problems.Add("main assembly '$($descriptorJson.FileName)' missing from the package")
                }
                $staged = @($entries | Where-Object { $_.FullName.StartsWith("$root/", [System.StringComparison]::OrdinalIgnoreCase) })
                $verified.Add("$($descriptorJson.SystemName) -> ~/Plugins/Uploaded/$root ($($staged.Count) entries)")
                Write-Ok "installs to ~/Plugins/Uploaded/$root ($($staged.Count) entries, $($descriptorJson.FriendlyName) $($descriptorJson.Version))"
            }
        }
    }
}
finally { $zip.Dispose() }

foreach ($w in $warnings) { Write-Warn $w }
if ($problems.Count) {
    Write-Host ''
    Write-Host 'VERIFICATION FAILED' -ForegroundColor Red
    foreach ($p in $problems) { Write-Host "  - $p" -ForegroundColor Red }
    exit 1
}

# ----------------------------------------------------------- metadata ----
$metadata = [ordered]@{
    systemName         = if ($pluginJson) { $pluginJson.SystemName } else { $verified[0].Split(' ')[0] }
    friendlyName       = if ($pluginJson) { $pluginJson.FriendlyName } else { $null }
    pluginVersion      = if ($pluginJson) { $pluginJson.Version } else { $null }
    nopCommerceVersion = $NopCommerceVersion
    layout             = $layout
    entryCount         = $entryCount
    sizeBytes          = (Get-Item -LiteralPath $OutputZip).Length
    sha256             = (Get-FileHash -LiteralPath $OutputZip -Algorithm SHA256).Hash.ToLowerInvariant()
}
$metadataPath = "$OutputZip.json"
$metadata | ConvertTo-Json | Set-Content -LiteralPath $metadataPath -Encoding UTF8

Write-Host ''
Write-Host 'VERIFICATION PASSED - package is uploadable' -ForegroundColor Green
foreach ($v in $verified) { Write-Host "  install : $v" }
Write-Host "  layout  : $layout"
Write-Host "  entries : $entryCount"
Write-Host "  size    : $('{0:N0}' -f $metadata.sizeBytes) bytes"
Write-Host "  sha256  : $($metadata.sha256)"
Write-Host "  zip     : $OutputZip"
Write-Host "  meta    : $metadataPath"
exit 0
