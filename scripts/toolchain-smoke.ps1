[CmdletBinding()]
param([ValidateSet('Both', 'GNU', 'CL')][string]$Frontend = 'Both')

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'toolchain-env.ps1') -Quiet
$workspaceRoot = Split-Path -Parent $PSScriptRoot
$source = Join-Path $workspaceRoot 'tools\toolchain\smoke'
$reports = Join-Path $workspaceRoot 'docs\reports'
$variants = @()
if ($Frontend -in @('Both', 'GNU')) { $variants += @{ Name = 'gnu'; Compiler = 'clang++' } }
if ($Frontend -in @('Both', 'CL')) { $variants += @{ Name = 'cl'; Compiler = 'clang-cl' } }

foreach ($variant in $variants) {
    $build = Join-Path $source ('build-' + $variant.Name)
    $logPrefix = Join-Path $reports ('toolchain-smoke-' + $variant.Name)
    & cmake -S $source -B $build -G Ninja '-DCMAKE_BUILD_TYPE=Release' `
        "-DCMAKE_CXX_COMPILER=$($variant.Compiler)" *> ($logPrefix + '-configure.log')
    if ($LASTEXITCODE -ne 0) {
        Get-Content -LiteralPath ($logPrefix + '-configure.log') -Tail 50
        throw "Toolchain $($variant.Name) configure failed."
    }
    & cmake --build $build --parallel 2 *> ($logPrefix + '-build.log')
    if ($LASTEXITCODE -ne 0) {
        Get-Content -LiteralPath ($logPrefix + '-build.log') -Tail 50
        throw "Toolchain $($variant.Name) compile/link failed."
    }
    & (Join-Path $build 'toolchain_smoke.exe') | Tee-Object -FilePath ($logPrefix + '-run.log')
    if ($LASTEXITCODE -ne 0) { throw "Toolchain $($variant.Name) execution failed: $LASTEXITCODE" }
}
