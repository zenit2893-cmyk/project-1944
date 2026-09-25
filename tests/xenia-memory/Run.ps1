[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release', 'RelWithDebInfo')]
    [string]$Configuration = 'RelWithDebInfo'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $workspace 'scripts/toolchain-env.ps1') -Quiet

$build = Join-Path $PSScriptRoot 'out'
& cmake -S $PSScriptRoot -B $build -G Ninja "-DCMAKE_BUILD_TYPE=$Configuration" `
    "-DCMAKE_CXX_COMPILER=$env:CXX"
if ($LASTEXITCODE -ne 0) { throw "Xenia memory contract configure failed: $LASTEXITCODE" }

& cmake --build $build --parallel 2
if ($LASTEXITCODE -ne 0) { throw "Xenia memory contract build failed: $LASTEXITCODE" }

$testText = (& ctest --test-dir $build -V --output-on-failure 2>&1 | Out-String)
$testExit = $LASTEXITCODE
$testText | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'last-test-output.txt') -Encoding utf8
Write-Output $testText

if ($testExit -ne 0) { throw 'Xenia memory contract test failed; inspect last-test-output.txt.' }

