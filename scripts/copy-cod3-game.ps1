#requires -Version 7.0
# Installs Call of Duty 3 from a copy of the game that is not a disc image:
#
#   folder  a game the player has already unpacked - the folder holding
#           default.xex next to sp, movies and config (or default.xex itself);
#   god     a Games on Demand package, the Xbox 360 hard-drive format
#           <Title ID>\00007000\<header> + <header>.data\Data0000... (the
#           header file, its folder, or any folder above it up to 415607E1).
#
# The result is the same game\cod3 that extract-cod3.ps1 makes from the .iso;
# code generation, both bridges, the build and the game itself read only that
# folder.
#
# The code must be the supported revision, because that is what gets
# recompiled: default.xex is checked against analysis/disc-source-lock.json
# before anything is written, and every other executable (codmp_xenonf.xex
# and the fifteen level modules, sp\<level>\<level>.dll) against the per-file
# list of the verified disc, analysis/disc-file-manifest.csv (paths, sizes and
# checksums only - no game data). Every file of the disc has to be there.
# Game data - sound banks (.wbk), level packs (.cod), movie sound (.wma) - may
# differ: dubbed editions replace exactly those (a Games on Demand package of
# this revision with another voice-over does). They are installed as they
# are and listed in the log. Files the disc does not have are left behind,
# and so is $SystemUpdate, a console system update the game never reads.
# Without the list the files are copied as they are and only the shape is
# checked.
#
# A fresh install is written into <Destination>.partial and renamed once
# every file is in place and verified; running again resumes the .partial
# folder. Each file is written under a temporary name and renamed when
# complete, so a file that exists is never half-written. An existing install
# is only topped up, never overwritten.
[CmdletBinding()]
param(
    # The unpacked game (default.xex or its folder) or the GOD package.
    [Parameter(Mandatory = $true)][string]$Source,
    [string]$Destination = (Join-Path $PSScriptRoot '..\game\cod3'),
    [string]$SourceLock = (Join-Path $PSScriptRoot '..\analysis\disc-source-lock.json'),
    [string]$Manifest = (Join-Path $PSScriptRoot '..\analysis\disc-file-manifest.csv')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'extract-disc-safety.ps1')

$SectorSize = 2048
# Games on Demand data layout (the same numbers iso2god and the console use):
# every Data#### part holds up to 203 sub-parts of 204 data blocks of 4 KB,
# each sub-part preceded by its hash block, the part by a master hash block.
$GodBlock = 4096
$GodBlocksPerSubpart = 204
$GodBlocksPerPart = 41412
$GodContentType = 0x00007000

# ------------------------------------------------------------------ the source

function Read-BigEndian32([byte[]]$Bytes, [int]$Offset) {
    return ([uint32]$Bytes[$Offset] -shl 24) -bor ([uint32]$Bytes[$Offset + 1] -shl 16) -bor
           ([uint32]$Bytes[$Offset + 2] -shl 8) -bor [uint32]$Bytes[$Offset + 3]
}

function Read-GodHeader([string]$Path) {
    # A CON/LIVE/PIRS package header of content type 00007000 with its
    # <name>.data folder next to it; $null for anything else.
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item -or $item.PSIsContainer -or $item.Length -lt 0x971A) { return $null }
    $dataDir = $item.FullName + '.data'
    if (-not (Test-Path -LiteralPath $dataDir -PathType Container)) { return $null }
    $bytes = New-Object byte[] 0x971A
    $stream = [IO.File]::OpenRead($item.FullName)
    try { $read = $stream.Read($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
    if ($read -lt $bytes.Length) { return $null }
    $magic = [Text.Encoding]::ASCII.GetString($bytes, 0, 4)
    if ($magic -notin @('CON ', 'LIVE', 'PIRS')) { return $null }
    if ((Read-BigEndian32 $bytes 0x344) -ne $GodContentType) { return $null }
    return [pscustomobject]@{
        Header = $item.FullName
        DataDir = $dataDir
        TitleId = '{0:X8}' -f (Read-BigEndian32 $bytes 0x360)
        MediaId = '{0:X8}' -f (Read-BigEndian32 $bytes 0x354)
        DataFileCount = [int](Read-BigEndian32 $bytes 0x39D)
    }
}

function Find-GodHeader([string]$Folder) {
    # The header sits in <Title ID>\00007000; a folder up to three levels above
    # it will do. Only files with a .data folder beside them are opened.
    $found = New-Object System.Collections.Generic.List[object]
    $level = @($Folder)
    for ($depth = 0; $depth -le 3 -and $level.Count -gt 0; $depth++) {
        $next = New-Object System.Collections.Generic.List[string]
        foreach ($dir in $level) {
            foreach ($item in Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue) {
                if ($item.PSIsContainer) {
                    if (-not $item.Name.EndsWith('.data', [StringComparison]::OrdinalIgnoreCase)) { $next.Add($item.FullName) }
                } elseif (Test-Path -LiteralPath ($item.FullName + '.data') -PathType Container) {
                    $header = Read-GodHeader $item.FullName
                    if ($header) { $found.Add($header) }
                }
            }
        }
        $level = $next.ToArray()
    }
    return $found.ToArray()
}

function Resolve-GameSource([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    if (Test-Path -LiteralPath $full -PathType Leaf) {
        $header = Read-GodHeader $full
        if ($header) { return [pscustomobject]@{ Kind = 'god'; Root = $full; God = $header } }
        if ([IO.Path]::GetExtension($full) -ieq '.xex') {
            return [pscustomobject]@{ Kind = 'folder'; Root = (Split-Path -Parent $full); God = $null }
        }
        throw "Not a Call of Duty 3 game folder or Games on Demand package: $full"
    }
    if (-not (Test-Path -LiteralPath $full -PathType Container)) { throw "Missing game folder: $full" }
    if (Test-Path -LiteralPath (Join-Path $full 'default.xex') -PathType Leaf) {
        return [pscustomobject]@{ Kind = 'folder'; Root = $full; God = $null }
    }
    $headers = @(Find-GodHeader $full)
    if ($headers.Count -gt 1) {
        # Several packages under one folder (a whole Content folder): the one
        # of this game, if it is there.
        $own = @($headers | Where-Object { $_.TitleId -eq $script:ExpectedTitleId })
        if ($own.Count -ge 1) { $headers = @($own[0]) }
    }
    if ($headers.Count -ge 1) { return [pscustomobject]@{ Kind = 'god'; Root = $headers[0].Header; God = $headers[0] } }
    throw "Missing default.xex in the game folder: $full"
}

# ---- Games on Demand data

$script:GodParts = @()

function Open-GodParts($God) {
    $parts = @(Get-ChildItem -LiteralPath $God.DataDir -File -Force |
        Where-Object { $_.Name -match '^Data\d{4}$' } | Sort-Object Name)
    if ($parts.Count -eq 0) { throw "GOD data is missing: no Data0000... files in $($God.DataDir)" }
    for ($i = 0; $i -lt $parts.Count; $i++) {
        if ($parts[$i].Name -ne ('Data{0:D4}' -f $i)) { throw "GOD data is missing: Data{0:D4}" -f $i }
    }
    if ($God.DataFileCount -gt 0 -and $parts.Count -ne $God.DataFileCount) {
        throw "GOD data is missing: $($parts.Count) of $($God.DataFileCount) Data files"
    }
    $script:GodParts = @($parts | ForEach-Object {
        [IO.File]::Open($_.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    })
}

function Close-GodParts {
    foreach ($stream in $script:GodParts) { $stream.Dispose() }
    $script:GodParts = @()
}

function Copy-GodRange([long]$Offset, [long]$Length, $Target, $Hashes) {
    # Logical bytes of the disc's game partition, as runs of data blocks that
    # are contiguous inside one sub-part of one Data file.
    $buffer = New-Object byte[] (1MB)
    while ($Length -gt 0) {
        $block = [long][Math]::Floor($Offset / $GodBlock)
        $part = [int][Math]::Floor($block / $GodBlocksPerPart)
        $inPart = $block % $GodBlocksPerPart
        $subpart = [long][Math]::Floor($inPart / $GodBlocksPerSubpart)
        $inSubpart = $inPart % $GodBlocksPerSubpart
        $inBlock = $Offset % $GodBlock
        $run = [Math]::Min($Length, ($GodBlocksPerSubpart - $inSubpart) * $GodBlock - $inBlock)
        if ($part -ge $script:GodParts.Count) { throw "GOD data ends early at offset $Offset" }
        $stream = $script:GodParts[$part]
        # Master hash block, then one hash block per sub-part so far.
        $stream.Position = $GodBlock * ($inPart + $subpart + 2) + $inBlock
        $left = $run
        while ($left -gt 0) {
            $read = $stream.Read($buffer, 0, [int][Math]::Min($left, $buffer.Length))
            if ($read -le 0) { throw "GOD data ends early at offset $Offset" }
            if ($Target) { $Target.Write($buffer, 0, $read) }
            foreach ($hash in $Hashes) { $hash.AppendData($buffer, 0, $read) }
            $left -= $read
        }
        $Offset += $run
        $Length -= $run
    }
}

function Read-GodBytes([long]$Offset, [int]$Count) {
    $memory = New-Object IO.MemoryStream
    Copy-GodRange $Offset $Count $memory @()
    return $memory.ToArray()
}

function Get-XdvdfsFiles {
    # The disc's file system (XDVDFS) inside the GOD data: the volume
    # descriptor in sector 32, directories as binary trees of entries.
    $volume = Read-GodBytes (32 * $SectorSize) $SectorSize
    $magic = 'MICROSOFT*XBOX*MEDIA'
    if ([Text.Encoding]::ASCII.GetString($volume, 0, 20) -ne $magic -or [Text.Encoding]::ASCII.GetString($volume, 0x7EC, 20) -ne $magic) {
        throw 'Not a Games on Demand package of a game disc: no XDVDFS volume descriptor'
    }
    $files = New-Object System.Collections.Generic.List[object]
    $pending = New-Object System.Collections.Generic.Stack[object]
    $pending.Push([pscustomobject]@{ Sector = [BitConverter]::ToUInt32($volume, 20); Size = [BitConverter]::ToUInt32($volume, 24); Prefix = '' })
    $tables = 0
    while ($pending.Count -gt 0) {
        $dir = $pending.Pop()
        if ($dir.Size -eq 0) { continue }
        if (++$tables -gt 10000) { throw 'Not a Games on Demand package of a game disc: directory tree too large' }
        $table = Read-GodBytes ([long]$dir.Sector * $SectorSize) ([int]$dir.Size)
        $entries = New-Object System.Collections.Generic.Stack[int]
        $seen = New-Object 'System.Collections.Generic.HashSet[int]'
        $entries.Push(0)
        while ($entries.Count -gt 0) {
            $at = $entries.Pop()
            if ($at + 14 -gt $table.Length -or -not $seen.Add($at)) { continue }
            $left = [BitConverter]::ToUInt16($table, $at)
            if ($left -eq 0xFFFF) { continue }
            $right = [BitConverter]::ToUInt16($table, $at + 2)
            $nameLength = $table[$at + 13]
            if ($at + 14 + $nameLength -gt $table.Length) { throw 'Not a Games on Demand package of a game disc: damaged directory entry' }
            $name = [Text.Encoding]::ASCII.GetString($table, $at + 14, $nameLength)
            $relative = if ($dir.Prefix) { $dir.Prefix + '\' + $name } else { $name }
            # Same path rules as the disc extraction: nothing may escape the
            # install folder or be a reserved Windows name.
            [void](Resolve-DiscImageEntry -ImagePath ('/' + $relative.Replace('\', '/')) -Destination $script:FinalDestination)
            $sector = [BitConverter]::ToUInt32($table, $at + 4)
            $size = [BitConverter]::ToUInt32($table, $at + 8)
            if ($table[$at + 12] -band 0x10) {
                $pending.Push([pscustomobject]@{ Sector = $sector; Size = $size; Prefix = $relative })
            } else {
                $files.Add([pscustomobject]@{ Path = $relative; Length = [long]$size; Offset = [long]$sector * $SectorSize })
            }
            if ($left -ne 0) { $entries.Push([int]$left * 4) }
            if ($right -ne 0) { $entries.Push([int]$right * 4) }
        }
    }
    return $files.ToArray()
}

# ---- reading any source into a file (hashing as it goes)

function New-Hash([string]$Name) {
    return [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::new($Name))
}

function Copy-SourceFile($Available, $Target, $Hashes) {
    if ($script:GameSource.Kind -eq 'god') {
        Copy-GodRange $Available.Offset $Available.Length $Target $Hashes
        return
    }
    $buffer = New-Object byte[] (1MB)
    $reader = [IO.File]::Open($Available.FullPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        while (($read = $reader.Read($buffer, 0, $buffer.Length)) -gt 0) {
            if ($Target) { $Target.Write($buffer, 0, $read) }
            foreach ($hash in $Hashes) { $hash.AppendData($buffer, 0, $read) }
        }
    } finally {
        $reader.Dispose()
    }
}

function Get-HexHash($Hash) {
    return [Convert]::ToHexString($Hash.GetHashAndReset())
}

# --------------------------------------------------------------------- checks

if (-not (Test-Path -LiteralPath $SourceLock -PathType Leaf)) { throw "The verified source lock is missing: $SourceLock" }
$lock = Get-Content -LiteralPath $SourceLock -Raw | ConvertFrom-Json
$expectedXex = ([string]$lock.expected_default_xex.sha256).ToUpperInvariant()
$script:ExpectedTitleId = ([string]$lock.title_id).ToUpperInvariant()

$script:FinalDestination = [IO.Path]::GetFullPath($Destination).TrimEnd('\', '/')
$staging = $script:FinalDestination + '.partial'
if ($script:FinalDestination -eq [IO.Path]::GetPathRoot($script:FinalDestination).TrimEnd('\', '/')) {
    throw "Refusing a drive root as output: $($script:FinalDestination)"
}

$script:GameSource = Resolve-GameSource $Source
$sourceRoot = if ($script:GameSource.Kind -eq 'god') { Split-Path -Parent $script:GameSource.God.Header } else { $script:GameSource.Root }
# Copying a folder into itself (or the install into a folder inside it) would
# never end; the extraction has the same rule for the image.
foreach ($output in @($script:FinalDestination, $staging)) {
    if ((Test-DiscPathWithin $sourceRoot $output) -or (Test-DiscPathWithin $output $sourceRoot)) {
        throw "Game folder overlaps the install folder: $sourceRoot"
    }
}
Assert-DiscPathNoReparse $script:FinalDestination
Assert-DiscPathNoReparse $staging

try {
    # What the source offers, by relative path (case-insensitive, like the
    # file system).
    $available = @{}
    if ($script:GameSource.Kind -eq 'god') {
        $god = $script:GameSource.God
        Write-Host "Games on Demand package: $($god.Header)"
        Write-Host "  Title ID $($god.TitleId), Media ID $($god.MediaId), $($god.DataFileCount) data file(s)"
        if ($god.TitleId -ne $script:ExpectedTitleId) { throw "GOD package is a different game: Title ID $($god.TitleId)" }
        Open-GodParts $god
        foreach ($file in Get-XdvdfsFiles) { $available[$file.Path] = $file }
    } else {
        Write-Host "Unpacked game folder: $($script:GameSource.Root)"
        foreach ($item in Get-ChildItem -LiteralPath $script:GameSource.Root -Recurse -File -Force) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            $relative = $item.FullName.Substring($script:GameSource.Root.Length + 1)
            $available[$relative] = [pscustomobject]@{ Path = $relative; Length = $item.Length; FullPath = $item.FullName }
        }
    }

    # The revision first: nothing is written for a different default.xex.
    Write-Host 'Checking default.xex...'
    if (-not $available.ContainsKey('default.xex')) { throw "Missing default.xex in the game folder: $sourceRoot" }
    $sha = New-Hash 'SHA256'
    Copy-SourceFile $available['default.xex'] $null @($sha)
    $xexHash = Get-HexHash $sha
    if ($xexHash -ne $expectedXex) { throw "default.xex SHA256 differs from the supported Call of Duty 3 revision: $xexHash" }

    function Test-SystemUpdate([string]$Relative) {
        return $Relative.StartsWith('$SystemUpdate\', [StringComparison]::OrdinalIgnoreCase)
    }
    function Test-GameCode([string]$Relative) {
        # What the recompiler reads: default.xex and the level modules (and the
        # multiplayer executable, which ships with them).
        return [IO.Path]::GetExtension($Relative) -in @('.xex', '.dll')
    }

    # What has to be installed. Length is what the source has, MD5 the disc's
    # checksum; Exact files must match it.
    $useManifest = Test-Path -LiteralPath $Manifest -PathType Leaf
    $files = New-Object System.Collections.Generic.List[object]
    if ($useManifest) {
        $missing = New-Object System.Collections.Generic.List[string]
        $codeDiffers = New-Object System.Collections.Generic.List[string]
        foreach ($row in Import-Csv -LiteralPath $Manifest) {
            if (Test-SystemUpdate $row.Path) { continue }
            [void](Resolve-DiscImageEntry -ImagePath ('/' + $row.Path.Replace('\', '/')) -Destination $script:FinalDestination)
            $offer = $available[$row.Path]
            # Everything the disc has must be there before anything is written:
            # a half-copied or trimmed game is refused up front.
            if ($null -eq $offer) { $missing.Add($row.Path); continue }
            $exact = Test-GameCode $row.Path
            if ($exact -and $offer.Length -ne [long]$row.Length) { $codeDiffers.Add($row.Path) }
            $files.Add([pscustomobject]@{ Path = $row.Path; Length = $offer.Length; MD5 = $row.SourceMD5.ToUpperInvariant()
                                          DiscLength = [long]$row.Length; Exact = $exact })
        }
        if ($missing.Count -gt 0) {
            foreach ($path in @($missing | Select-Object -First 25)) { Write-Host "  missing: $path" }
            throw "Game files are incomplete: $($missing.Count) file(s) of the disc are missing"
        }
        if ($codeDiffers.Count -gt 0) {
            foreach ($path in $codeDiffers) { Write-Host "  different size: $path" }
            throw "Game code differs from the supported revision: $($codeDiffers -join ', ')"
        }
    } else {
        Write-Host 'No per-file list of the disc; copying the files as they are.'
        foreach ($offer in $available.Values) {
            if (Test-SystemUpdate $offer.Path) { continue }
            $files.Add([pscustomobject]@{ Path = $offer.Path; Length = $offer.Length; MD5 = $null; DiscLength = $offer.Length; Exact = $false })
        }
        $levels = @($files | Where-Object { $_.Path -match '^sp\\[^\\]+\\' } | ForEach-Object { $_.Path.Split('\')[1] } | Sort-Object -Unique).Count
        $shapeMissing = @()
        if ($levels -lt 15) { $shapeMissing += "sp ($levels of 15 levels)" }
        foreach ($name in @('config', 'movies')) {
            if (-not @($files | Where-Object { $_.Path.StartsWith($name + '\', [StringComparison]::OrdinalIgnoreCase) }).Count) { $shapeMissing += $name }
        }
        if ($shapeMissing.Count -gt 0) { throw "Game files are incomplete: missing $($shapeMissing -join ', ')" }
    }
    $known = @{}
    foreach ($file in $files) { $known[$file.Path] = $file }

    function Test-InstalledFile($Path, $File) {
        # A file in the install counts when it has the size of its source and,
        # for code, the disc's checksum. Files are renamed into place only once
        # complete, so the size is enough for game data.
        $item = Get-Item -LiteralPath $Path -Force
        if ($item.Length -ne $File.Length) { return $false }
        if ($File.Exact) { return (Get-FileHash -LiteralPath $Path -Algorithm MD5).Hash -eq $File.MD5 }
        return $true
    }

    # A fresh install goes through the .partial folder; a folder that already
    # holds default.xex is an install and is only topped up.
    $staged = -not (Test-Path -LiteralPath (Join-Path $script:FinalDestination 'default.xex') -PathType Leaf)
    if ($staged -and (Test-Path -LiteralPath $script:FinalDestination -PathType Container)) {
        if (@(Get-ChildItem -LiteralPath $script:FinalDestination -Force).Count -eq 0) {
            Remove-Item -LiteralPath $script:FinalDestination -Force
        } else {
            throw "Unknown existing directory, refusing overwrite: $($script:FinalDestination)"
        }
    }
    $target = if ($staged) { $staging } else { $script:FinalDestination }

    if ($staged -and (Test-Path -LiteralPath $staging -PathType Container)) {
        # Our own scratch folder from an interrupted run: keep what is already
        # right, drop anything partial or unknown.
        Write-Host 'Resuming an interrupted install...'
        $kept = 0
        foreach ($item in Get-ChildItem -LiteralPath $staging -Recurse -Force -File) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Refusing reparse point: $($item.FullName)" }
            $relative = $item.FullName.Substring($staging.Length + 1)
            $file = $known[$relative]
            if ($null -ne $file -and (Test-InstalledFile $item.FullName $file)) { $kept++ } else { Remove-Item -LiteralPath $item.FullName -Force }
        }
        Write-Host "  $kept file(s) already in place"
    }

    New-Item -ItemType Directory -Path $target -Force | Out-Null
    $ordered = @($files | Sort-Object { if ($_.Path -ieq 'default.xex') { 0 } else { 1 } }, Path)
    $totalMb = [Math]::Max(1, [long][Math]::Ceiling((($ordered | Measure-Object -Property Length -Sum).Sum) / 1MB))
    # Room for what is still to be copied? Saying so now beats an out-of-space
    # error halfway through 6 GB (what the copy already did is kept either way).
    $remaining = [long]0
    foreach ($file in $ordered) {
        if (-not (Test-Path -LiteralPath (Join-Path $target $file.Path) -PathType Leaf)) { $remaining += $file.Length }
    }
    $drive = New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($target))
    if ($drive.AvailableFreeSpace -lt $remaining + 256MB) {
        throw ('Not enough disk space on {0}: {1:n1} GB free, {2:n1} GB still to copy' -f
            $drive.Name.TrimEnd('\'), ($drive.AvailableFreeSpace / 1GB), ($remaining / 1GB))
    }
    Write-Host "Installing $($ordered.Count) files, $totalMb MB (progress below in MB)"
    $doneBytes = [long]0
    $copied = 0
    $dataDiffers = New-Object System.Collections.Generic.List[string]
    foreach ($file in $ordered) {
        $to = Join-Path $target $file.Path
        if (Test-Path -LiteralPath $to -PathType Leaf) {
            # Kept from an interrupted run (checked above), or part of an
            # existing install, which is checked here and never overwritten.
            if (-not $staged -and -not (Test-InstalledFile $to $file)) {
                throw "Existing file differs from source, refusing overwrite: $($file.Path)"
            }
        } else {
            New-Item -ItemType Directory -Path (Split-Path -Parent $to) -Force | Out-Null
            $temporary = $to + '.copying'
            $md5 = New-Hash 'MD5'
            $output = [IO.File]::Open($temporary, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try {
                Copy-SourceFile $available[$file.Path] $output @($md5)
            } catch {
                # ERROR_DISK_FULL / ERROR_HANDLE_DISK_FULL: something else took
                # the space meanwhile. PowerShell wraps the IOException from
                # Write, so the chain is searched. Named in English, whatever
                # language Windows reports it in.
                $inner = $_.Exception
                while ($inner) {
                    if ($inner -is [IO.IOException] -and $inner.HResult -in @(-2147024784, -2147024857)) {
                        throw "Not enough disk space on $([IO.Path]::GetPathRoot($target).TrimEnd('\')): $($inner.Message)"
                    }
                    $inner = $inner.InnerException
                }
                throw
            } finally {
                $output.Dispose()
            }
            if ((Get-Item -LiteralPath $temporary -Force).Length -ne $file.Length) { throw "Copied length differs: $($file.Path)" }
            $hash = Get-HexHash $md5
            if ($file.MD5 -and $hash -ne $file.MD5) {
                if ($file.Exact) {
                    Remove-Item -LiteralPath $temporary -Force
                    throw "Game code differs from the supported revision: $($file.Path)"
                }
                $dataDiffers.Add($file.Path)
            }
            [IO.File]::Move($temporary, $to)
            if ($script:GameSource.Kind -eq 'folder') {
                (Get-Item -LiteralPath $to -Force).LastWriteTimeUtc = (Get-Item -LiteralPath $available[$file.Path].FullPath -Force).LastWriteTimeUtc
            }
            $copied++
        }
        $doneBytes += $file.Length
        # "[done/total] ..." is what the launcher's progress bar follows.
        Write-Host ('[{0}/{1}] {2}' -f [long][Math]::Ceiling($doneBytes / 1MB), $totalMb, $file.Path)
    }
} finally {
    Close-GodParts
}

if ((Get-FileHash -LiteralPath (Join-Path $target 'default.xex') -Algorithm SHA256).Hash -ne $expectedXex) {
    throw 'default.xex changed while it was being installed'
}
if ($staged) {
    # Everything verified: the game folder appears in one step.
    [IO.Directory]::Move($staging, $script:FinalDestination)
}
if ($dataDiffers.Count -gt 0) {
    Write-Host "$($dataDiffers.Count) game data file(s) differ from the disc - another voice-over or edition? The code matches the supported revision, so they were installed as they are:"
    foreach ($path in @($dataDiffers | Select-Object -First 60)) { Write-Host "  $path" }
}
$verdict = if (-not $useManifest) { 'sizes checked' }
           elseif ($dataDiffers.Count -gt 0) { 'the code matches the disc' }
           else { 'every file matches the disc' }
Write-Host "Game data ready: $($script:FinalDestination) ($copied file(s) installed, $($ordered.Count - $copied) already in place, $verdict)"
