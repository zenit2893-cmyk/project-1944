[CmdletBinding()]
param(
    [ValidateRange(1, 64)]
    [int]$Jobs = 4,
    [string]$CMakePath,
    [string]$NinjaPath,
    [string]$CCompiler,
    [string]$CxxCompiler
)

$ErrorActionPreference = 'Stop'
$workspaceRoot = Split-Path -Parent $PSScriptRoot
$repositoryRoot = Join-Path $workspaceRoot 'tools\XenosRecomp'
$buildRoot = Join-Path $repositoryRoot 'build'
$environmentScript = Join-Path $PSScriptRoot 'toolchain-env.ps1'
if (Test-Path -LiteralPath $environmentScript) {
    . $environmentScript
}

function Resolve-BuildTool([string]$ExplicitPath, [string]$CommandName, [string]$LocalRelativePath) {
    if ($ExplicitPath) { return (Get-Command $ExplicitPath -ErrorAction Stop).Source }
    $localPath = Join-Path $workspaceRoot $LocalRelativePath
    if (Test-Path -LiteralPath $localPath -PathType Leaf) { return $localPath }
    return (Get-Command $CommandName -ErrorAction Stop).Source
}

$CMakePath = Resolve-BuildTool $CMakePath 'cmake' 'tools\cmake\bin\cmake.exe'
$NinjaPath = Resolve-BuildTool $NinjaPath 'ninja' 'tools\ninja\ninja.exe'
$CCompiler = Resolve-BuildTool $CCompiler 'clang-cl' 'tools\toolchain\llvm\bin\clang-cl.exe'
$CxxCompiler = Resolve-BuildTool $CxxCompiler 'clang-cl' 'tools\toolchain\llvm\bin\clang-cl.exe'

foreach ($requiredFile in @('CMakeLists.txt', 'thirdparty\fmt\CMakeLists.txt', 'thirdparty\dxc-bin\CMakeLists.txt')) {
    if (-not (Test-Path -LiteralPath (Join-Path $repositoryRoot $requiredFile) -PathType Leaf)) {
        throw "Incomplete XenosRecomp checkout: $requiredFile. Clone the official repository recursively."
    }
}

$configureArguments = @(
    '-S', $repositoryRoot,
    '-B', $buildRoot,
    '-G', 'Ninja',
    "-DCMAKE_MAKE_PROGRAM=$NinjaPath",
    "-DCMAKE_C_COMPILER=$CCompiler",
    "-DCMAKE_CXX_COMPILER=$CxxCompiler",
    '-DCMAKE_BUILD_TYPE=Release',
    '-DBUILD_SHARED_LIBS=OFF',
    '-DZSTD_BUILD_PROGRAMS=OFF',
    '-DZSTD_BUILD_SHARED=OFF',
    '-DXXHASH_BUILD_XXHSUM=OFF'
)
& $CMakePath @configureArguments
if ($LASTEXITCODE -ne 0) { throw "XenosRecomp configure failed with exit code $LASTEXITCODE." }

& $CMakePath --build $buildRoot --config Release --target XenosRecomp --parallel $Jobs
if ($LASTEXITCODE -ne 0) { throw "XenosRecomp build failed with exit code $LASTEXITCODE." }

$executablePath = Join-Path $buildRoot 'XenosRecomp\XenosRecomp.exe'
& $executablePath
if ($LASTEXITCODE -ne 0) { throw "XenosRecomp usage smoke test failed with exit code $LASTEXITCODE." }
Write-Output "`nBuilt and smoke tested: $executablePath"
