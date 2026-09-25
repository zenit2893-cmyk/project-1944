[CmdletBinding()]
param([ValidateSet('Release', 'RelWithDebInfo')][string]$Configuration = 'Release')
$ErrorActionPreference = 'Stop'
$workspaceRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $workspaceRoot 'scripts/toolchain-env.ps1') -Quiet
$buildRoot = Join-Path $PSScriptRoot ('out/' + $Configuration.ToLowerInvariant())
$sdkRoot = Join-Path $workspaceRoot 'win-amd64'
& cmake -S $PSScriptRoot -B $buildRoot -G Ninja "-DCMAKE_BUILD_TYPE=$Configuration" -DCMAKE_CXX_COMPILER=clang++ "-DCMAKE_PREFIX_PATH=$sdkRoot"
if ($LASTEXITCODE -ne 0) { throw "Bridge CMake configure failed: $LASTEXITCODE" }
& cmake --build $buildRoot --parallel 2
if ($LASTEXITCODE -ne 0) { throw "Bridge build failed: $LASTEXITCODE" }
$testOutput = & ctest --test-dir $buildRoot --output-on-failure -V 2>&1
$testExit = $LASTEXITCODE
$testText = $testOutput | Out-String
$testText | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'last-test-output.txt') -Encoding utf8
Write-Output $testText
$caseCount = 0
if ($testText -match 'PASS: (\d+) cases') { $caseCount = [int]$Matches[1] }
$objectPath = Join-Path $buildRoot 'xenon/CMakeFiles/cod3_xenon_thunks.dir/xenon_thunks.cpp.obj'
if (Test-Path -LiteralPath $objectPath) {
    & llvm-objdump --disassemble --reloc --no-show-raw-insn $objectPath |
        Set-Content -LiteralPath (Join-Path $PSScriptRoot 'thunks-disassembly.txt') -Encoding utf8
    if ($LASTEXITCODE -ne 0) { throw "Object disassembly failed: $LASTEXITCODE" }
}
$receipt = [ordered]@{
    checkedUtc = [DateTime]::UtcNow.ToString('o')
    configuration = $Configuration
    compiler = (& clang++ --version | Select-Object -First 1)
    sdkVersion = (& (Join-Path $sdkRoot 'bin/rexglue.exe') --version)
    testExitCode = $testExit
    nativeCases = $caseCount
    passed = ($testExit -eq 0 -and $caseCount -eq 1072)
    executableSha256 = (Get-FileHash -LiteralPath (Join-Path $buildRoot 'xenon_bridge_tests.exe') -Algorithm SHA256).Hash.ToLowerInvariant()
    generatedSourceSha256 = (Get-FileHash -LiteralPath (Join-Path $workspaceRoot 'integration/xenon/generated/thunks.generated.inl') -Algorithm SHA256).Hash.ToLowerInvariant()
    scope = 'Two original PPC branch thunks only. Does not execute CoD3 game logic, prove broad Xenon/ReXGlue interoperability, or measure gameplay FPS.'
}
$receipt | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'results.json') -Encoding utf8
if (-not $receipt.passed) { throw "Bridge test failed (exit $testExit, cases $caseCount)" }

