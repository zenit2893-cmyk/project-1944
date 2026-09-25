#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$Image = (Join-Path $PSScriptRoot '..\Call of Duty 3 (USA, Europe).iso'),
    [string]$Destination = (Join-Path $PSScriptRoot '..\game\cod3'),
    [string]$Tool = (Join-Path $PSScriptRoot '..\tools\xdvdfs\xdvdfs.exe'),
    [string]$ReportDirectory = (Join-Path $PSScriptRoot '..\analysis')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'extract-disc-safety.ps1')
$Image = [IO.Path]::GetFullPath($Image)
$Destination = [IO.Path]::GetFullPath($Destination).TrimEnd('\')
$Tool = [IO.Path]::GetFullPath($Tool)
$ReportDirectory = [IO.Path]::GetFullPath($ReportDirectory)
$expectedImageSha256 = '0FD477CE0A6BA1BF9784292073A43EE7CA7BA1FD04DB60F9C265BFCD5A6C1586'
if (-not (Test-Path -LiteralPath $Image -PathType Leaf)) { throw "Missing input image: $Image" }
if (-not (Test-Path -LiteralPath $Tool -PathType Leaf)) { throw "Missing xdvdfs tool: $Tool" }

# A fresh install is unpacked into <Destination>.partial and renamed only once
# every file has been verified, so an interrupted run never leaves a
# half-copied game folder behind. Running again resumes the .partial folder:
# files that already match the image are kept, anything else is copied anew.
# A destination that already holds a game is checked and topped up in place.
$finalDestination = $Destination
$staged = -not (Test-Path -LiteralPath (Join-Path $finalDestination 'default.xex') -PathType Leaf)
if ($staged -and (Test-Path -LiteralPath $finalDestination -PathType Container)) {
    if (@(Get-ChildItem -LiteralPath $finalDestination -Force).Count -eq 0) {
        Remove-Item -LiteralPath $finalDestination -Force
    } else {
        $staged = $false
    }
}
if ($staged) {
    $Destination = $finalDestination + '.partial'
    if ((Test-DiscPathWithin $Image $finalDestination) -or (Test-DiscPathWithin $Tool $finalDestination)) {
        throw "Input/tool must be outside output directories: $Image"
    }
}

$reportNames = @('disc-image-tree.txt', 'disc-image-info.txt', 'disc-image-md5.txt', 'disc-copy-out.log', 'disc-file-manifest.csv', 'disc-extraction.json')
Assert-DiscOutputLayout -Image $Image -Tool $Tool -Destination $Destination -ReportDirectory $ReportDirectory -ReportNames $reportNames
$sourceGuard = Open-DiscSourceReadLock $Image
try {
Write-Host 'Verifying source image SHA256...'
$sourceHash = (Get-FileHash -LiteralPath $Image -Algorithm SHA256).Hash
if ($sourceHash -ne $expectedImageSha256) { throw "Image SHA256 differs from the inspected Call of Duty 3 image: $sourceHash" }
$sourceInfo = @( & $Tool info $Image )
if ($LASTEXITCODE -ne 0) { throw 'xdvdfs info failed' }
$tree = @( & $Tool tree $Image )
if ($LASTEXITCODE -ne 0) { throw 'xdvdfs tree failed' }
$copyLogLines = @('Extraction run ' + [datetime]::UtcNow.ToString('o'))

$files = @{}
$directories = @{}
$topLevel = @{}
foreach ($line in $tree) {
    if ($line -notmatch '^(/.+) \((\d+) bytes\)$') { continue }
    $imagePath = $Matches[1]
    $length = [long]$Matches[2]
    $entry = Resolve-DiscImageEntry -ImagePath $imagePath -Destination $Destination
    $relative = $entry.Relative
    if ($files.ContainsKey($relative) -or $directories.ContainsKey($relative)) { throw "Duplicate case-insensitive image path: $relative" }
    $topName = $relative.Split('\')[0]
    $topLevel[$topName] = $true
    if ($imagePath.EndsWith('/')) { $directories[$relative] = $true }
    else {
        $files[$relative] = [pscustomobject]@{ Path = $relative; Length = $length; SourceMD5 = $null; SHA256 = $null }
    }
}
if (-not $files.ContainsKey('default.xex')) { throw 'default.xex missing from the image' }
Write-Host "Reading source checksums for $($files.Count) files..."
$md5Lines = @( & $Tool md5 $Image )
if ($LASTEXITCODE -ne 0) { throw 'xdvdfs source MD5 calculation failed' }
foreach ($line in $md5Lines) {
    if ($line -notmatch '^([0-9a-fA-F]{32})  (/.+)$') { throw "Unexpected MD5 output: $line" }
    $relative = $Matches[2].TrimStart('/').Replace('/', '\')
    # xdvdfs also hashes raw on-disc directory tables; only files are copied as bytes.
    if ($directories.ContainsKey($relative)) { continue }
    if (-not $files.ContainsKey($relative)) { throw "Checksum has unexpected path: $relative" }
    $files[$relative].SourceMD5 = $Matches[1].ToUpperInvariant()
}
foreach ($file in $files.Values) { if (-not $file.SourceMD5) { throw "Source MD5 absent: $($file.Path)" } }

if ($staged -and (Test-Path -LiteralPath $Destination -PathType Container)) {
    # Our own scratch folder from an interrupted run. Keep what already
    # matches the image byte for byte; drop anything partial or unknown.
    Write-Host 'Resuming an interrupted extraction...'
    $kept = 0
    foreach ($item in Get-ChildItem -LiteralPath $Destination -Recurse -Force -File) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Refusing reparse point: $($item.FullName)" }
        $relative = $item.FullName.Substring($Destination.TrimEnd('\', '/').Length + 1)
        $keep = $files.ContainsKey($relative) -and $item.Length -eq $files[$relative].Length -and
            (Get-FileHash -LiteralPath $item.FullName -Algorithm MD5).Hash -eq $files[$relative].SourceMD5
        if ($keep) { $kept++ } else { Remove-Item -LiteralPath $item.FullName -Force }
    }
    foreach ($item in Get-ChildItem -LiteralPath $Destination -Recurse -Force -Directory | Sort-Object { $_.FullName.Length } -Descending) {
        $relative = $item.FullName.Substring($Destination.TrimEnd('\', '/').Length + 1)
        if (-not $directories.ContainsKey($relative) -and @(Get-ChildItem -LiteralPath $item.FullName -Force).Count -eq 0) {
            Remove-Item -LiteralPath $item.FullName -Force
        }
    }
    Write-Host "  $kept file(s) already in place"
}

# Nothing is written until the image, all paths, and any existing assets pass preflight.
Assert-DiscExistingContent -Destination $Destination -Files $files -Directories $directories
New-Item -ItemType Directory -Path $Destination, $ReportDirectory -Force | Out-Null

# Room for what is still to be extracted? Saying so now beats an out-of-space
# error halfway through (what is already extracted is kept either way).
$remaining = [long]0
foreach ($file in $files.Values) {
    if (-not (Test-Path -LiteralPath (Join-Path $Destination $file.Path) -PathType Leaf)) { $remaining += $file.Length }
}
$drive = New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($Destination))
if ($drive.AvailableFreeSpace -lt $remaining + 256MB) {
    throw ('Not enough disk space on {0}: {1:n1} GB free, {2:n1} GB still to extract' -f
        $drive.Name.TrimEnd('\'), ($drive.AvailableFreeSpace / 1GB), ($remaining / 1GB))
}

# Copy absent root items in bulk. Already extracted executables stay untouched.
foreach ($name in $topLevel.Keys | Sort-Object { if ($_ -eq 'default.xex') { 0 } elseif ($_ -like '*.xex') { 1 } else { 2 } }, { $_ }) {
    $target = Join-Path $Destination $name
    if (-not (Test-Path -LiteralPath $target)) {
        Write-Host "Extracting /$name..."
        $copyLogLines += @( & $Tool copy-out $Image ('/' + $name) $target 2>&1 )
        if ($LASTEXITCODE -ne 0) { throw "Extraction failed: $name" }
    }
}
foreach ($relative in $directories.Keys | Sort-Object Length) { New-Item -ItemType Directory -Path (Join-Path $Destination $relative) -Force | Out-Null }
foreach ($file in $files.Values | Sort-Object Path) {
    $target = Join-Path $Destination $file.Path
    if (-not (Test-Path -LiteralPath $target)) {
        $copyLogLines += @( & $Tool copy-out $Image ('/' + $file.Path.Replace('\', '/')) $target 2>&1 )
        if ($LASTEXITCODE -ne 0) { throw "Extraction failed: $($file.Path)" }
    }
    if ((Get-Item -LiteralPath $target).Length -ne $file.Length) { throw "Extracted length differs: $($file.Path)" }
    if ((Get-FileHash -LiteralPath $target -Algorithm MD5).Hash -ne $file.SourceMD5) { throw "Extracted content differs: $($file.Path)" }
    $file.SHA256 = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
}
$manifest = @($files.Values | Sort-Object Path)
if ((Get-FileHash -LiteralPath $Image -Algorithm SHA256).Hash -ne $sourceHash) { throw 'Source image changed during extraction or verification' }
if ($staged) {
    # Everything verified: the game folder appears in one step.
    [IO.Directory]::Move($Destination, $finalDestination)
    $Destination = $finalDestination
    Write-Host "Game data ready: $Destination"
}
$metadata = [ordered]@{
    VerifiedUtc = [datetime]::UtcNow.ToString('o')
    SourceImage = $Image
    SourceSize = (Get-Item -LiteralPath $Image).Length
    SourceSHA256 = $sourceHash
    SourceSHA256UnchangedAfterExtraction = $true
    Destination = $Destination
    ToolVersion = ((& $Tool --version) -join '').Trim()
    ToolSHA256 = (Get-FileHash -LiteralPath $Tool -Algorithm SHA256).Hash
    FileCount = $files.Count
    DirectoryCount = $directories.Count
    TotalFileBytes = [long]($manifest | Measure-Object Length -Sum).Sum
    AllFileLengthsMatchImage = $true
    AllFileMD5MatchImage = $true
    PerFileSHA256 = 'disc-file-manifest.csv'
    DefaultXexSHA256 = $files['default.xex'].SHA256
    Note = 'This proves extraction integrity relative to the supplied image; it does not establish a trusted retail dump or successful runtime execution.'
}
Write-DiscReport -Path (Join-Path $ReportDirectory 'disc-image-tree.txt') -Lines $tree
Write-DiscReport -Path (Join-Path $ReportDirectory 'disc-image-info.txt') -Lines $sourceInfo
Write-DiscReport -Path (Join-Path $ReportDirectory 'disc-image-md5.txt') -Lines $md5Lines
Write-DiscReport -Path (Join-Path $ReportDirectory 'disc-copy-out.log') -Lines $copyLogLines
Write-DiscReport -Path (Join-Path $ReportDirectory 'disc-file-manifest.csv') -Lines @($manifest | ConvertTo-Csv -NoTypeInformation)
Write-DiscReport -Path (Join-Path $ReportDirectory 'disc-extraction.json') -Lines @($metadata | ConvertTo-Json -Depth 4)
$metadata | ConvertTo-Json -Depth 4
} finally {
    $sourceGuard.Dispose()
}
