#requires -Version 7.0
# Builds and runs the stick-QTE check with the workspace toolchain.
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
. (Join-Path $root 'scripts\toolchain-env.ps1') -Quiet
$out = Join-Path $root 'tests\pc-controls\out'
New-Item -ItemType Directory -Path $out -Force | Out-Null
$exe = Join-Path $out 'stick_qte_test.exe'
Push-Location $out
try {
    & clang-cl.exe /nologo /std:c++20 /EHsc /O2 /W4 (Join-Path $PSScriptRoot 'stick_qte_test.cpp') /Fe:$exe
    if ($LASTEXITCODE -ne 0) { throw "build failed ($LASTEXITCODE)" }
} finally {
    Pop-Location
}
& $exe
exit $LASTEXITCODE
