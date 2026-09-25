#requires -Version 7.2
[CmdletBinding()]
param([ValidateRange(1, 16)][int]$Jobs = 4)
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'toolchain-env.ps1') -Quiet
$source = Join-Path $workspace 'tools/XenonRecomp'
if (-not (Test-Path -LiteralPath (Join-Path $source 'CMakeLists.txt'))) {
    throw 'The official recursive XenonRecomp checkout is missing from tools/XenonRecomp.'
}
$log = Join-Path $workspace 'logs/xenon-build.log'
Push-Location -LiteralPath $source
try {
    $configure = @('-S', '.', '-B', 'out/build/windows-release', '-G', 'Ninja', '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_C_COMPILER=clang-cl', '-DCMAKE_CXX_COMPILER=clang-cl', '-DCMAKE_POLICY_VERSION_MINIMUM=3.5')
    & cmake @configure 2>&1 | Tee-Object -FilePath $log
    if ($LASTEXITCODE -ne 0) { throw "XenonRecomp configure failed. See $log" }
    & cmake --build out/build/windows-release --target XenonRecomp XenonAnalyse --parallel $Jobs 2>&1 | Tee-Object -FilePath $log -Append
    if ($LASTEXITCODE -ne 0) { throw "XenonRecomp build failed. See $log" }
    Write-Host "XenonRecomp and XenonAnalyse built in $source/out/build/windows-release."
}
finally { Pop-Location }
