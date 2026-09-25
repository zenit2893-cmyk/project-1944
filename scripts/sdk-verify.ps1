[CmdletBinding()]
param(
    [string]$WorkspaceRoot = (Split-Path -Parent $PSScriptRoot),
    [switch]$ProbePlugin
)

$ErrorActionPreference = 'Stop'
$sdkRoot = Join-Path $WorkspaceRoot 'win-amd64'
$archivePath = Join-Path $WorkspaceRoot 'rexglue-sdk-0.10.0.5-dev.g0c7b01a-win-amd64.zip'
$reportRoot = Join-Path $WorkspaceRoot 'docs/reports'
$expectedArchiveSha256 = '67b19131fce54eab7019833623856d998d1c420fcf8cd8394057a2ba1957bf8b'
$officialRelease = 'https://github.com/rexglue/rexglue-sdk/releases/tag/nightly-20260904-0c7b01a0'
$null = New-Item -ItemType Directory -Path $reportRoot -Force

function Get-StreamSha256([IO.Stream]$Stream) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($Stream)).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-PeSummary([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    $pe = [BitConverter]::ToInt32($bytes, 0x3c)
    if ([BitConverter]::ToUInt32($bytes, $pe) -ne 0x4550) { throw "Invalid PE: $Path" }
    $machine = [BitConverter]::ToUInt16($bytes, $pe + 4)
    $sectionCount = [BitConverter]::ToUInt16($bytes, $pe + 6)
    $optionalSize = [BitConverter]::ToUInt16($bytes, $pe + 20)
    $optional = $pe + 24
    $magic = [BitConverter]::ToUInt16($bytes, $optional)
    $directories = if ($magic -eq 0x20b) { $optional + 112 } else { $optional + 96 }
    $sections = @()
    for ($i = 0; $i -lt $sectionCount; $i++) {
        $s = $optional + $optionalSize + 40 * $i
        $sections += [pscustomobject]@{
            Rva = [BitConverter]::ToUInt32($bytes, $s + 12)
            Size = [Math]::Max([BitConverter]::ToUInt32($bytes, $s + 8), [BitConverter]::ToUInt32($bytes, $s + 16))
            Raw = [BitConverter]::ToUInt32($bytes, $s + 20)
        }
    }
    function Convert-Rva([uint32]$Rva) {
        foreach ($s in $sections) {
            if ($Rva -ge $s.Rva -and $Rva -lt ($s.Rva + $s.Size)) { return [int]($s.Raw + $Rva - $s.Rva) }
        }
        if ($Rva -lt [BitConverter]::ToUInt32($bytes, $optional + 60)) { return [int]$Rva }
        throw ('Unmapped RVA 0x{0:X} in {1}' -f $Rva, $Path)
    }
    function Read-Ascii([int]$Offset) {
        $end = $Offset
        while ($end -lt $bytes.Length -and $bytes[$end] -ne 0) { $end++ }
        return [Text.Encoding]::ASCII.GetString($bytes, $Offset, $end - $Offset)
    }
    $imports = @()
    $importRva = [BitConverter]::ToUInt32($bytes, $directories + 8)
    if ($importRva) {
        $descriptor = Convert-Rva $importRva
        while ([BitConverter]::ToUInt32($bytes, $descriptor + 12)) {
            $imports += Read-Ascii (Convert-Rva ([BitConverter]::ToUInt32($bytes, $descriptor + 12)))
            $descriptor += 20
        }
    }
    $exports = @()
    $exportRva = [BitConverter]::ToUInt32($bytes, $directories)
    if ($exportRva) {
        $exportDir = Convert-Rva $exportRva
        $count = [BitConverter]::ToUInt32($bytes, $exportDir + 24)
        $names = Convert-Rva ([BitConverter]::ToUInt32($bytes, $exportDir + 32))
        for ($i = 0; $i -lt $count; $i++) {
            $name = Read-Ascii (Convert-Rva ([BitConverter]::ToUInt32($bytes, $names + 4 * $i)))
            if ($name -like 'rex_gpu_*') { $exports += $name }
        }
    }
    [pscustomobject]@{ Name = [IO.Path]::GetFileName($Path); Machine = ('0x{0:X4}' -f $machine); Imports = $imports; GpuExports = $exports }
}

$archiveSha256 = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
$archive = [IO.Compression.ZipFile]::OpenRead($archivePath)
$archiveFiles = 0
$archiveBytes = [long]0
$missing = @()
$mismatches = @()
$archiveNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
try {
    foreach ($entry in $archive.Entries) {
        if (-not $entry.Name) { continue }
        $archiveFiles++
        $archiveBytes += $entry.Length
        $localPath = [IO.Path]::GetFullPath((Join-Path $WorkspaceRoot $entry.FullName))
        $prefix = [IO.Path]::GetFullPath($sdkRoot).TrimEnd('\') + '\'
        if (-not $localPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Unexpected archive path: $($entry.FullName)" }
        $null = $archiveNames.Add($localPath)
        if (-not (Test-Path -LiteralPath $localPath -PathType Leaf)) { $missing += $entry.FullName; continue }
        $entryStream = $entry.Open()
        try { $expected = Get-StreamSha256 $entryStream } finally { $entryStream.Dispose() }
        $localStream = [IO.File]::OpenRead($localPath)
        try { $actual = Get-StreamSha256 $localStream } finally { $localStream.Dispose() }
        if ($expected -ne $actual) { $mismatches += $entry.FullName }
    }
} finally { $archive.Dispose() }
$extra = @(Get-ChildItem -LiteralPath $sdkRoot -File -Recurse | Where-Object { -not $archiveNames.Contains($_.FullName) } | ForEach-Object FullName)
$cmakeRefs = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$cmakeMissing = @()
foreach ($cmakeFile in (Get-ChildItem -LiteralPath $sdkRoot -Filter '*.cmake' -File -Recurse)) {
    foreach ($match in [regex]::Matches((Get-Content -LiteralPath $cmakeFile.FullName -Raw), '\$\{_IMPORT_PREFIX\}/([^";\r\n]+)')) {
        $tail = $match.Groups[1].Value
        if ($tail -match '\$') { continue }
        $reference = Join-Path $sdkRoot $tail
        if ($cmakeRefs.Add($reference) -and -not (Test-Path -LiteralPath $reference)) { $cmakeMissing += $reference }
    }
}
$version = ((& (Join-Path $sdkRoot 'bin/rexglue.exe') --version) | Out-String).Trim()
if ($LASTEXITCODE -ne 0) { throw 'rexglue --version failed' }
$peFiles = @(Get-ChildItem -LiteralPath (Join-Path $sdkRoot 'bin') -File | Where-Object Extension -in '.dll', '.exe' | ForEach-Object { Get-PeSummary $_.FullName })
$pluginResults = @()
if ($ProbePlugin) {
    if (-not ('SdkNativeProbe' -as [type])) {
        Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class SdkNativeProbe {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr LoadLibraryExW(string path, IntPtr file, UInt32 flags);
    [DllImport("kernel32.dll", CharSet = CharSet.Ansi, SetLastError = true)]
    public static extern IntPtr GetProcAddress(IntPtr module, string name);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool FreeLibrary(IntPtr module);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate UInt32 AbiVersion();
}
'@
    }
    foreach ($file in @('rexgpu-xenos.dll', 'rexgpu-xenosd.dll', 'rexgpu-xenosrd.dll')) {
        $module = [SdkNativeProbe]::LoadLibraryExW((Join-Path $sdkRoot "bin/$file"), [IntPtr]::Zero, 0x00001100)
        if ($module -eq [IntPtr]::Zero) {
            $pluginResults += [pscustomobject]@{ Name = $file; Loaded = $false; Win32Error = [Runtime.InteropServices.Marshal]::GetLastWin32Error(); AbiVersion = $null }
            continue
        }
        try {
            $address = [SdkNativeProbe]::GetProcAddress($module, 'rex_gpu_abi_version')
            if ($address -eq [IntPtr]::Zero) { throw "Missing ABI export in $file" }
            $call = [Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer($address, [SdkNativeProbe+AbiVersion])
            $pluginResults += [pscustomobject]@{ Name = $file; Loaded = $true; Win32Error = 0; AbiVersion = $call.Invoke() }
        } finally { $null = [SdkNativeProbe]::FreeLibrary($module) }
    }
}
$passed = ($archiveSha256 -eq $expectedArchiveSha256 -and $version -eq '0.10.0.5-dev.g0c7b01a' -and $missing.Count -eq 0 -and $mismatches.Count -eq 0 -and $cmakeMissing.Count -eq 0)
$report = [ordered]@{
    checkedUtc = [DateTime]::UtcNow.ToString('o')
    sdkRoot = $sdkRoot
    cliVersion = $version
    officialRelease = $officialRelease
    sourceCommit = '0c7b01a0ac0479801757507d80533f662fa0815d'
    archiveSha256 = $archiveSha256
    officialSha256 = $expectedArchiveSha256
    archiveDigestMatches = ($archiveSha256 -eq $expectedArchiveSha256)
    archiveFiles = $archiveFiles
    archiveUncompressedBytes = $archiveBytes
    missingFiles = $missing
    mismatchedFiles = $mismatches
    extraInstalledFiles = $extra
    cmakeImportedPathsCount = $cmakeRefs.Count
    cmakeImportedPathsMissing = $cmakeMissing
    binaries = $peFiles
    pluginLoadProbes = $pluginResults
    distributionIntegrityPassed = $passed
    runtimeBoundary = 'Plugin probes call only rex_gpu_abi_version. They do not create a D3D12 device, render game frames, or validate game compatibility.'
}
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $reportRoot 'sdk-verification.json') -Encoding utf8
[pscustomobject]@{ CliVersion = $version; ArchiveFiles = $archiveFiles; Missing = $missing.Count; Mismatched = $mismatches.Count; Extra = $extra.Count; IntegrityPassed = $passed; PluginProbes = $pluginResults } | ConvertTo-Json -Depth 5
if (-not $passed) { exit 1 }
