# Shared by the extraction script and its small filesystem regression checks.
# No filesystem mutation occurs merely by loading these functions.

function Test-DiscPathWithin {
    param([string]$Child, [string]$Parent)
    $childPath = [IO.Path]::GetFullPath($Child).TrimEnd('\', '/')
    $parentPath = [IO.Path]::GetFullPath($Parent).TrimEnd('\', '/')
    return $childPath.Equals($parentPath, [StringComparison]::OrdinalIgnoreCase) -or
        $childPath.StartsWith($parentPath + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Assert-DiscPathNoReparse {
    param([string]$Path)
    $cursor = [IO.Path]::GetFullPath($Path)
    while ($cursor) {
        $item = $null
        try { $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop }
        catch { if ($_.CategoryInfo.Category -ne 'ObjectNotFound') { throw } }
        if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Refusing reparse point in path: $cursor"
        }
        $parent = [IO.Path]::GetDirectoryName($cursor.TrimEnd('\', '/'))
        if (-not $parent -or $parent -eq $cursor) { break }
        $cursor = $parent
    }
}

function Assert-DiscOutputLayout {
    param([string]$Image, [string]$Tool, [string]$Destination, [string]$ReportDirectory, [string[]]$ReportNames)
    foreach ($path in @($Destination, $ReportDirectory)) {
        if ($path.TrimEnd('\', '/') -eq [IO.Path]::GetPathRoot($path).TrimEnd('\', '/')) {
            throw "Refusing a drive root as output: $path"
        }
        Assert-DiscPathNoReparse $path
        if (Test-Path -LiteralPath $path -PathType Leaf) { throw "Output must be a directory: $path" }
    }
    if ((Test-DiscPathWithin $Destination $ReportDirectory) -or (Test-DiscPathWithin $ReportDirectory $Destination)) {
        throw 'Extraction destination and report directory must not overlap'
    }
    foreach ($path in @($Image, $Tool)) {
        Assert-DiscPathNoReparse $path
        if ((Test-DiscPathWithin $path $Destination) -or (Test-DiscPathWithin $path $ReportDirectory)) {
            throw "Input/tool must be outside output directories: $path"
        }
    }
    foreach ($name in $ReportNames) {
        $path = Join-Path $ReportDirectory $name
        Assert-DiscPathNoReparse $path
        if (Test-Path -LiteralPath $path -PathType Container) { throw "Report file is an existing directory: $path" }
    }
}

function Resolve-DiscImageEntry {
    param([string]$ImagePath, [string]$Destination)
    if (-not $ImagePath.StartsWith('/') -or $ImagePath.Contains('//') -or $ImagePath.Contains('\')) {
        throw "Unsafe image path: $ImagePath"
    }
    $parts = $ImagePath.Substring(1).TrimEnd('/').Split('/')
    foreach ($part in $parts) {
        if (-not $part -or $part -in @('.', '..') -or $part.TrimEnd(' ', '.') -ne $part -or
            $part.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or
            $part -match '^(?i:CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³])(?:\..*)?$') {
            throw "Unsafe Windows image path: $ImagePath"
        }
    }
    $relative = $parts -join '\'
    $target = [IO.Path]::GetFullPath((Join-Path $Destination $relative))
    if (-not $target.StartsWith($Destination.TrimEnd('\', '/') + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Escaping image path: $ImagePath"
    }
    return [pscustomobject]@{ Relative = $relative; Target = $target; IsDirectory = $ImagePath.EndsWith('/') }
}

function Assert-DiscExistingContent {
    param([string]$Destination, [hashtable]$Files, [hashtable]$Directories)
    Assert-DiscPathNoReparse $Destination
    if (-not (Test-Path -LiteralPath $Destination)) { return }
    foreach ($item in Get-ChildItem -LiteralPath $Destination -Recurse -Force) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Refusing reparse point: $($item.FullName)" }
        $relative = $item.FullName.Substring($Destination.TrimEnd('\', '/').Length + 1)
        if ($item.PSIsContainer) {
            if (-not $Directories.ContainsKey($relative)) { throw "Unknown existing directory, refusing overwrite: $relative" }
        } else {
            if (-not $Files.ContainsKey($relative)) { throw "Unknown existing file, refusing overwrite: $relative" }
            if ($item.Length -ne $Files[$relative].Length -or
                (Get-FileHash -LiteralPath $item.FullName -Algorithm MD5).Hash -ne $Files[$relative].SourceMD5) {
                throw "Existing file differs from source, refusing overwrite: $relative"
            }
        }
    }
}

function Open-DiscSourceReadLock {
    param([string]$Image)
    # Other readers, including xdvdfs, remain allowed. Writers and deletion are denied.
    return [IO.File]::Open($Image, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
}

function Write-DiscReport {
    param([string]$Path, [object[]]$Lines)
    Assert-DiscPathNoReparse $Path
    if (Test-Path -LiteralPath $Path -PathType Container) { throw "Report file is an existing directory: $Path" }
    $temporary = Join-Path ([IO.Path]::GetDirectoryName($Path)) ('.disc-report-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false))
        try { foreach ($line in $Lines) { $writer.WriteLine([string]$line) } }
        finally { $writer.Dispose() }
        # Replace the directory entry, avoiding in-place writes through existing hard links.
        [IO.File]::Move($temporary, $Path, $true)
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}
