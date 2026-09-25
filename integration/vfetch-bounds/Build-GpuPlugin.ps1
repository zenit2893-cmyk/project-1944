#requires -Version 7.2
[CmdletBinding()]
param(
    [ValidateRange(1, 16)][int]$Jobs = 8,
    [switch]$RefreshStage,
    # Copy the built plugin next to the game executable after a successful build.
    [switch]$Stage
)

$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$buildRoot = Join-Path $PSScriptRoot 'build'
$project = Join-Path $PSScriptRoot 'runtime'
# The runtime the plugin is built against. The workspace keeps a patched SDK
# next to the stock one; a released package carries the runtime in the SDK tree
# and beside the executable.
$patchedRuntime = $null
foreach ($candidate in @(
    'tools\rexglue-patched-sdk\bin\rexruntimerd.dll',
    'win-amd64\bin\rexruntimerd.dll',
    'rexruntimerd.dll')) {
    $probe = Join-Path $workspace $candidate
    if (Test-Path -LiteralPath $probe -PathType Leaf) { $patchedRuntime = $probe; break }
}
if (-not $patchedRuntime) { throw 'No ReXGlue runtime DLL found to build the plugin against.' }
$gameBin = Join-Path $workspace 'cod3-pc\out\build\win-amd64-relwithdebinfo'

. (Join-Path $workspace 'scripts\toolchain-env.ps1') -Quiet

# The plugin compiles Dear ImGui directly, and the SDK keeps it as a git
# submodule that is empty in both the workspace source tree and the packaged
# one. Fetch it (MIT) the same way the code-generation CLI fetches its own
# header-only dependencies.
$sdkSource = $null
foreach ($candidate in @('integration\rexglue-runtime-build\src', 'sdk-source')) {
    $probe = Join-Path $workspace $candidate
    if (Test-Path -LiteralPath (Join-Path $probe 'src\graphics') -PathType Container) { $sdkSource = $probe; break }
}
if (-not $sdkSource) { throw 'ReXGlue source not found (looked for integration\rexglue-runtime-build\src and sdk-source).' }
$imguiProbe = Join-Path $sdkSource 'thirdparty\imgui\imgui.cpp'
if (-not (Test-Path -LiteralPath $imguiProbe -PathType Leaf)) {
    $deps = Join-Path $workspace 'tools\rexglue-cli\Get-Dependencies.ps1'
    if (-not (Test-Path -LiteralPath $deps -PathType Leaf)) { throw "Dear ImGui is missing and the fetcher is not available: $deps" }
    & $deps -SdkSourceRoot $sdkSource -IncludeImGui
}
# A stage copied before ImGui arrived would still be missing it.
$stagedImgui = Join-Path $PSScriptRoot 'source\thirdparty\imgui\imgui.cpp'
if ((Test-Path -LiteralPath (Join-Path $PSScriptRoot 'source') -PathType Container) -and
    -not (Test-Path -LiteralPath $stagedImgui -PathType Leaf)) {
    $RefreshStage = $true
}

# apply_fix.py is stdlib-only, so any Python will do. A released package has
# none, but the toolchain provisioner leaves uv behind, which supplies one.
$fixScript = Join-Path $PSScriptRoot 'apply_fix.py'
$fixArgs = @($fixScript)
if ($RefreshStage) { $fixArgs += '--refresh' }
$python = $null
foreach ($candidate in @(
    (Join-Path $workspace 'tools\toolchain\bootstrap-python\Scripts\python.exe'),
    (Join-Path $workspace 'tools\toolchain\bootstrap-python\python.exe'))) {
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { $python = $candidate; break }
}
if (-not $python) {
    $systemPython = Get-Command python -ErrorAction SilentlyContinue
    if ($systemPython -and ((& $systemPython.Source --version 2>&1 | Out-String) -match 'Python\s+3\.\d')) {
        $python = $systemPython.Source
    }
}
if ($python) {
    & $python @fixArgs
} else {
    $uv = Join-Path $workspace 'tools\uv\uv.exe'
    if (-not (Test-Path -LiteralPath $uv -PathType Leaf)) {
        $found = Get-Command uv -ErrorAction SilentlyContinue
        if ($found) { $uv = $found.Source } else { $uv = $null }
    }
    if (-not $uv) {
        throw 'Python is required to apply the vertex-fetch fix. Run tools/toolchain-provision/Install-Toolchain.ps1 first; it installs uv, which provides one.'
    }
    & $uv run --python 3.12 @fixArgs
}
if ($LASTEXITCODE -ne 0) { throw 'Vertex-fetch bounds fix could not be applied.' }

& cmake -S $project -B $buildRoot -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo `
    "-DCMAKE_C_COMPILER=$env:CC" "-DCMAKE_CXX_COMPILER=$env:CXX" `
    "-DCOD3_RUNTIME_DLL=$($patchedRuntime -replace '\\','/')"
if ($LASTEXITCODE -ne 0) { throw 'GPU plugin configure failed.' }
& cmake --build $buildRoot --target rexgpu-xenos --parallel $Jobs
if ($LASTEXITCODE -ne 0) { throw 'GPU plugin build failed.' }

$plugin = Join-Path $buildRoot 'bin\rexgpu-xenosrd.dll'
if (-not (Test-Path -LiteralPath $plugin)) { throw "Plugin output is missing: $plugin" }

$receipt = [ordered]@{
    schema_version = 1
    recorded_utc = [datetime]::UtcNow.ToString('o')
    purpose = 'Xenos GPU plugin with the restored vertex-fetch out-of-bounds zeroing'
    configuration = 'RelWithDebInfo'
    plugin = $plugin
    plugin_sha256 = (Get-FileHash -LiteralPath $plugin -Algorithm SHA256).Hash
    # A fresh package has no game build yet, so there may be nothing to compare against.
    shipped_plugin_sha256 = $(
        $shipped = Join-Path $gameBin 'rexgpu-xenosrd.dll'
        if (Test-Path -LiteralPath $shipped -PathType Leaf) { (Get-FileHash -LiteralPath $shipped -Algorithm SHA256).Hash } else { $null }
    )
    runtime_dll = $patchedRuntime
    fix_receipt = Join-Path $PSScriptRoot 'fix-receipt.json'
    staged_to_game = [bool]$Stage
}
if ($Stage) {
    Copy-Item -LiteralPath $plugin -Destination (Join-Path $gameBin 'rexgpu-xenosrd.dll') -Force
    $pdb = Join-Path $buildRoot 'bin\rexgpu-xenosrd.pdb'
    if (Test-Path -LiteralPath $pdb) {
        Copy-Item -LiteralPath $pdb -Destination (Join-Path $gameBin 'rexgpu-xenosrd.pdb') -Force
    }
    # The launcher verifies runtime DLL hashes against the build receipt, so the
    # native build receipt has to be refreshed after staging a new plugin.
    Write-Host 'Plugin staged. Re-run scripts/build-cod3.ps1 to refresh the build receipt.'
}
$receiptPath = Join-Path $PSScriptRoot 'plugin-receipt.json'
$receipt | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $receiptPath -Encoding utf8
$receipt | ConvertTo-Json -Depth 6
