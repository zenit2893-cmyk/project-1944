[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InputPath,
    [Parameter(Mandatory = $true)]
    [string]$OutputPath,
    [switch]$CoD3Legacy,
    [ValidateSet('Default', 'Primary', 'Secondary')]
    [string]$Entry = 'Default',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$workspaceRoot = Split-Path -Parent $PSScriptRoot
$repositoryRoot = Join-Path $workspaceRoot 'tools\XenosRecomp'
$executablePath = Join-Path $repositoryRoot 'build\XenosRecomp\XenosRecomp.exe'
$headerPath = Join-Path $repositoryRoot 'XenosRecomp\shader_common.h'
if (-not (Test-Path -LiteralPath $executablePath -PathType Leaf)) {
    throw 'XenosRecomp has not been built. Run scripts\xenos-build.ps1 first.'
}

$resolvedInput = (Resolve-Path -LiteralPath $InputPath -ErrorAction Stop).Path
$resolvedOutput = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
$isDirectoryInput = Test-Path -LiteralPath $resolvedInput -PathType Container
if ($Entry -ne 'Default' -and (-not $CoD3Legacy -or $isDirectoryInput)) {
    throw 'Explicit primary/secondary selection requires -CoD3Legacy and an individual shader container.'
}
if (-not $isDirectoryInput) {
    $inputStream = [IO.File]::OpenRead($resolvedInput)
    try {
        $containerPrefix = [byte[]]::new(36)
        $bytesRead = $inputStream.Read($containerPrefix, 0, $containerPrefix.Length)
        $acceptedRevision = $containerPrefix[2] -eq 0x11 -or
            ($CoD3Legacy -and $containerPrefix[2] -eq 0x10 -and
                ($containerPrefix[3] -le 1 -or ($containerPrefix[3] -eq 0x21 -and $Entry -ne 'Default')))
        if ($bytesRead -ne 36 -or $containerPrefix[0] -ne 0x10 -or $containerPrefix[1] -ne 0x2A -or -not $acceptedRevision) {
            if ($bytesRead -eq 36 -and $containerPrefix[0] -eq 0x10 -and $containerPrefix[1] -eq 0x2A -and $containerPrefix[2] -eq 0x10) {
                throw 'Legacy CoD3 shaders require -CoD3Legacy; dual-program 0x102A1021 containers also require -Entry Primary or -Entry Secondary.'
            }
            throw 'Input is not a supported Xbox 360 shader container. Extract/decompress the archive before conversion.'
        }
        if (($containerPrefix[16] -bor $containerPrefix[17] -bor $containerPrefix[18] -bor $containerPrefix[19]) -eq 0) {
            throw 'This shader has no reflection table; the upstream XenosRecomp converter requires reflection data.'
        }
    } finally {
        $inputStream.Dispose()
    }
}
if (Test-Path -LiteralPath $resolvedOutput) {
    if (-not $Force) { throw "Output already exists: $resolvedOutput. Choose a new path or use -Force." }
    if (Test-Path -LiteralPath $resolvedOutput -PathType Container) { throw 'Output must be a file.' }
}
if ([string]::Equals($resolvedInput, $resolvedOutput, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Input and output must be different paths.'
}

$outputParent = Split-Path -Parent $resolvedOutput
[void](New-Item -ItemType Directory -Path $outputParent -Force)
# The upstream CLI uses narrow file APIs. Relative ASCII paths avoid passing the
# Cyrillic workspace prefix through its char** interface on Windows.
$inputArgument = [IO.Path]::GetRelativePath($workspaceRoot, $resolvedInput)
$outputArgument = [IO.Path]::GetRelativePath($workspaceRoot, $resolvedOutput)
$headerArgument = [IO.Path]::GetRelativePath($workspaceRoot, $headerPath)

Push-Location -LiteralPath $workspaceRoot
try {
    $nativeArguments = @($inputArgument, $outputArgument, $headerArgument)
    if ($CoD3Legacy) {
        $nativeArguments += switch ($Entry) {
            'Primary' { '--cod3-legacy-primary' }
            'Secondary' { '--cod3-legacy-secondary' }
            default { '--cod3-legacy-container' }
        }
    }
    & $executablePath @nativeArguments
    if ($LASTEXITCODE -ne 0) { throw "XenosRecomp conversion failed with exit code $LASTEXITCODE." }
} finally {
    Pop-Location
}

if (-not (Test-Path -LiteralPath $resolvedOutput -PathType Leaf) -or (Get-Item -LiteralPath $resolvedOutput).Length -eq 0) {
    throw 'XenosRecomp did not produce a non-empty output file.'
}
if ($isDirectoryInput) {
    $cacheText = [IO.File]::ReadAllText($resolvedOutput)
    $shaderCount = [regex]::Matches($cacheText, '(?m)^\s*\{\s*0x[0-9A-Fa-f]+,').Count
    if ($shaderCount -eq 0) {
        throw "No shaders were found. The generated empty cache at $resolvedOutput does not provide game shaders."
    }
    Write-Output "Converted $shaderCount shaders into the upstream Unleashed Recompiled cache format."
}
Write-Output "Generated: $resolvedOutput"
Write-Output 'Shader conversion output still requires game-specific validation; a generated file does not establish rendering correctness.'
