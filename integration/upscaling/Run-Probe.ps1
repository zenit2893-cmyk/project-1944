[CmdletBinding()]
param([ValidateRange(1,8)][int]$Jobs=2)
$ErrorActionPreference='Stop'
$workspaceRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $workspaceRoot 'scripts\toolchain-env.ps1') -Quiet
& (Join-Path $workspaceRoot 'tools\toolchain\bootstrap-python\Scripts\python.exe') (Join-Path $PSScriptRoot 'prepare_overlay.py')
if($LASTEXITCODE -ne 0){throw 'Spatial overlay preparation failed.'}
$buildPath=Join-Path $PSScriptRoot 'build'
$compiler=$env:CXX
& cmake -S $PSScriptRoot -B $buildPath -G Ninja -DCMAKE_BUILD_TYPE=Release "-DCMAKE_CXX_COMPILER=$compiler"
if($LASTEXITCODE -ne 0){throw 'Spatial probe configure failed.'}
& cmake --build $buildPath --parallel $Jobs
if($LASTEXITCODE -ne 0){throw 'Spatial probe compile failed.'}
& (Join-Path $buildPath 'spatial_probe.exe')
if($LASTEXITCODE -ne 0){throw 'Spatial probe execution failed.'}
& ctest --test-dir $buildPath --output-on-failure
if($LASTEXITCODE -ne 0){throw 'Spatial CTest verification failed.'}
