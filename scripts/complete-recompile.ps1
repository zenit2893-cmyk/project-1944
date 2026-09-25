#requires -Version 7.0
<#
.SYNOPSIS
    Last step of a recompilation: compile the recompiled game, unless the
    package already holds exactly that compilation.

.DESCRIPTION
    By this point code generation has translated the player's own copy of the
    game - default.xex and the fifteen level modules - into C++, and the two
    bridges have been regenerated from it. That translation is the
    recompilation; what remains is running a C++ compiler over about 550 MB
    of output, which takes 10-30 minutes.

    The package ships a ready-made build, and analysis/recompile-reference.json
    records the SHA-256 of every generated file and every port source it was
    compiled from (hashes only, no code). When the fresh recompilation matches
    it byte for byte and the port's sources are unchanged, compiling again
    would reproduce that same build, so the ready-made binaries are the result
    and this step takes seconds. It says so, and records it in
    analysis/recompile-receipt.json.

    Anything different - another revision, an edited source, no reference -
    or -Full compiles everything: the compiler is provisioned here if it is
    missing, the patched GPU plugin the package carries is reused, and
    scripts/build-cod3.ps1 builds the game.
#>
[CmdletBinding()]
param(
    [switch]$Full,
    [int]$Jobs = [Environment]::ProcessorCount,
    [string]$Root
)

$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')) }
$Root = [IO.Path]::GetFullPath($Root).TrimEnd('\')
. (Join-Path $PSScriptRoot 'recompile-reference.ps1')

$referencePath = Join-Path $Root 'analysis\recompile-reference.json'
$receiptPath = Join-Path $Root 'analysis\recompile-receipt.json'

function Compare-WithReference {
    # $null when the recompilation matches the shipped build, otherwise why not.
    if (-not (Test-Path -LiteralPath $referencePath -PathType Leaf)) { return 'the package has no reference build' }
    $reference = Get-Content -LiteralPath $referencePath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($binary in @($reference.binaries.PSObject.Properties)) {
        $path = Join-Path $Root ($binary.Name -replace '/', '\')
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return "the ready-made build is incomplete: $($binary.Name) is missing" }
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $binary.Value) { return "the ready-made build was changed: $($binary.Name)" }
    }

    $differences = New-Object System.Collections.Generic.List[string]
    foreach ($group in @('sources', 'generated')) {
        $expected = $reference.$group
        $expectedNames = @($expected.PSObject.Properties.Name)
        $actualNames = if ($group -eq 'generated') { @(Get-RecompileGeneratedFiles $Root) } else { $expectedNames }
        $actual = Get-RecompileHashes $Root @($actualNames | Where-Object { Test-Path -LiteralPath (Join-Path $Root ($_ -replace '/', '\')) -PathType Leaf })
        foreach ($name in $expectedNames) {
            if (-not $actual.Contains($name)) { $differences.Add("missing ${group}: $name") }
            elseif ($actual[$name] -ne $expected.$name) { $differences.Add("different ${group}: $name") }
        }
        if ($group -eq 'generated') {
            foreach ($name in $actual.Keys) {
                if ($expectedNames -notcontains $name) { $differences.Add("extra generated: $name") }
            }
        }
    }
    if ($differences.Count -eq 0) { return $null }
    foreach ($line in @($differences | Select-Object -First 20)) { Write-Host "  $line" }
    if ($differences.Count -gt 20) { Write-Host "  ... and $($differences.Count - 20) more" }
    return "$($differences.Count) file(s) differ from the reference build"
}

$started = [DateTime]::UtcNow
if (-not $Full) {
    Write-Host 'Comparing the recompiled code with the code of the ready-made build...'
    $mismatch = Compare-WithReference
    if (-not $mismatch) {
        $reference = Get-Content -LiteralPath $referencePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $generated = @($reference.generated.PSObject.Properties)
        $bytes = [long]0
        foreach ($entry in $generated) { $bytes += (Get-Item -LiteralPath (Join-Path $Root ($entry.Name -replace '/', '\'))).Length }
        $receipt = [ordered]@{
            schema_version = 1
            mode = 'verified-reuse'
            completed_utc = [DateTime]::UtcNow.ToString('o')
            generated_files = $generated.Count
            generated_bytes = $bytes
            source_files = @($reference.sources.PSObject.Properties).Count
            binaries = $reference.binaries
            note = 'The C++ recompiled from this copy of the game is byte-identical to the code the ready-made build was compiled from, and the port sources are unchanged; compiling it again would reproduce that build, so it is used as the result.'
        }
        [IO.File]::WriteAllText($receiptPath, ($receipt | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
        Write-Host ("Recompiled code matches the ready-made build byte for byte: {0} generated files ({1:n0} MB), {2} port sources." -f
            $generated.Count, ($bytes / 1MB), $receipt.source_files)
        Write-Host 'Compiling it again would produce that same build, so the ready-made binaries are the result. Nothing to compile.'
        Write-Host "Receipt: $receiptPath"
        exit 0
    }
    Write-Host "Compiling in full: $mismatch."
}

# ---- full compilation
# The compiler (about 1.5 GB once) and the object files (about 1.5 GB) need room.
$drive = New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($Root))
if ($drive.AvailableFreeSpace -lt 4GB) {
    throw ('Not enough disk space on {0} for a full compile: {1:n1} GB free, about 4 GB needed' -f
        $drive.Name.TrimEnd('\'), ($drive.AvailableFreeSpace / 1GB))
}
$toolchainScript = Join-Path $Root 'tools\toolchain-provision\Install-Toolchain.ps1'
$environmentComplete = @('tools\toolchain\msvc\env.json', 'tools\toolchain\llvm\bin\clang-cl.exe', 'tools\cmake\bin\cmake.exe', 'tools\ninja\ninja.exe') |
    ForEach-Object { Test-Path -LiteralPath (Join-Path $Root $_) -PathType Leaf }
if ($environmentComplete -contains $false) {
    if (-not (Test-Path -LiteralPath $toolchainScript -PathType Leaf)) { throw "The compiler is missing and so is its installer: $toolchainScript" }
    Write-Host ''
    Write-Host '--- Installing the compiler ---'
    & $toolchainScript -Component all -Root $Root
    if ($LASTEXITCODE -ne 0) { throw "Installing the compiler failed (exit $LASTEXITCODE)." }
}

# The patched GPU plugin: built once, or the identical one the package carries.
$plugin = Join-Path $Root 'integration\vfetch-bounds\build\bin\rexgpu-xenosrd.dll'
if (-not (Test-Path -LiteralPath $plugin -PathType Leaf)) {
    $shipped = Join-Path $Root 'rexgpu-xenosrd.dll'
    if (Test-Path -LiteralPath $shipped -PathType Leaf) {
        Write-Host 'Using the patched GPU plugin the package carries.'
        $plugin = $shipped
    } else {
        $pluginScript = Join-Path $Root 'integration\vfetch-bounds\Build-GpuPlugin.ps1'
        Write-Host ''
        Write-Host '--- Building the patched GPU plugin ---'
        & $pluginScript -Jobs $Jobs
        if ($LASTEXITCODE -ne 0) { throw "Building the GPU plugin failed (exit $LASTEXITCODE)." }
    }
}

$buildArguments = @{ Configuration = 'RelWithDebInfo'; Jobs = $Jobs; GpuPlugin = $plugin }
$patchedRuntime = Join-Path $Root 'tools\rexglue-patched-sdk\bin\rexruntimerd.dll'
if (Test-Path -LiteralPath $patchedRuntime -PathType Leaf) { $buildArguments.RuntimeDll = $patchedRuntime }
Write-Host ''
Write-Host '--- Compiling ---'
& (Join-Path $Root 'scripts\build-cod3.ps1') @buildArguments
if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "The build failed (exit $LASTEXITCODE)." }

$receipt = [ordered]@{
    schema_version = 1
    mode = 'full-compile'
    completed_utc = [DateTime]::UtcNow.ToString('o')
    minutes = [Math]::Round(([DateTime]::UtcNow - $started).TotalMinutes, 1)
}
[IO.File]::WriteAllText($receiptPath, ($receipt | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
