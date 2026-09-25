# Call of Duty 3 native port - tester launcher.
#
# Works both inside the development workspace and inside an unpacked
# package. It never contains game data: the player picks their own disc image,
# which the launcher unpacks into <root>\game\cod3 and, by default, recompiles
# the game from on this machine before starting it.
#
# Windows PowerShell 5.1 compatible on purpose, so testers can run it without
# installing PowerShell 7.

[CmdletBinding()]
param(
    # Start the game immediately with the saved settings and no window.
    [switch]$Play,
    # Print what a rebuild would need and which steps it would run, then exit.
    [switch]$CheckRebuild,
    # Run the same rebuild the button runs, in the console, then exit.
    [switch]$RebuildNow,
    # Where -RebuildNow installs the game from when it is not in game\cod3 yet:
    # the disc image (.iso), or the default.xex of a game already unpacked
    # into a folder (or that folder).
    [Alias('Source')]
    [string]$Iso = '',
    # With -RebuildNow: only unpack the image and use the prebuilt game.
    [switch]$ExtractOnly,
    # With -RebuildNow: compile in full even when the recompiled code matches
    # the ready-made build (the "Пересобрать игру" button).
    [switch]$FullCompile,
    # Development aid: render every launcher page to PNG files in this folder
    # instead of opening the window.
    [string]$Preview = ''
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:LauncherVersion = '2.1'
$script:LauncherScript = $MyInvocation.MyCommand.Path
$script:LauncherRoot = Split-Path -Parent $script:LauncherScript
$script:Layout = $null
$script:Settings = $null

# ---------------------------------------------------------------- environment

function Get-Layout {
    # Two supported shapes:
    #   workspace: <root>\cod3-pc\out\build\win-amd64-relwithdebinfo\cod3_pc.exe
    #   bundle:    <root>\cod3_pc.exe
    $parent = Split-Path -Parent $script:LauncherRoot
    # A freshly recompiled build wins over the prebuilt binary shipped in the
    # package, so the workspace path is probed first.
    $candidates = @(
        @{ Kind = 'workspace'; Root = $parent
           Exe = Join-Path $parent 'cod3-pc\out\build\win-amd64-relwithdebinfo\cod3_pc.exe' },
        @{ Kind = 'bundle'; Root = $parent; Exe = Join-Path $parent 'cod3_pc.exe' },
        @{ Kind = 'bundle'; Root = $script:LauncherRoot; Exe = Join-Path $script:LauncherRoot 'cod3_pc.exe' }
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate.Exe -PathType Leaf) {
            $root = $candidate.Root
            $layout = [ordered]@{
                Kind       = $candidate.Kind
                Root       = $root
                Exe        = $candidate.Exe
                BinDir     = Split-Path -Parent $candidate.Exe
                UserData   = Join-Path $root 'userdata'
                CacheRoot  = Join-Path $root 'cache'
                LogDir     = Join-Path $root 'logs'
                GameData   = Join-Path $root 'game\cod3'
                Receipt    = Join-Path $root 'analysis\cod3-pc-native-build-receipt.json'
                Manifest   = Join-Path $root 'package-manifest.json'
            }
            # An unpacked package keeps its settings and caches in userdata and
            # cache at the root even after the rebuild has produced a workspace
            # build; otherwise a finished rebuild would quietly switch to an
            # empty settings file. Only the development tree uses cod3-pc\.
            $isPackage = Test-Path -LiteralPath (Join-Path $root 'package-manifest.json') -PathType Leaf
            if ($candidate.Kind -eq 'workspace' -and -not $isPackage) {
                $layout.UserData = Join-Path $root 'cod3-pc\userdata'
                $layout.CacheRoot = Join-Path $root 'cod3-pc\cache'
            }
            return $layout
        }
    }
    return $null
}

function Get-RelativePathCompat([string]$Base, [string]$Path) {
    # [IO.Path]::GetRelativePath is .NET Core only; Windows PowerShell needs Uri.
    $baseUri = New-Object System.Uri (($Base.TrimEnd('\') + '\'))
    $targetUri = New-Object System.Uri $Path
    $relative = $baseUri.MakeRelativeUri($targetUri).ToString()
    return [Uri]::UnescapeDataString($relative).Replace('/', '\')
}

function ConvertTo-CommandLine([string[]]$Arguments) {
    # ProcessStartInfo.ArgumentList is .NET Core only; quote for the classic
    # Arguments string instead. Values here contain paths, never quotes.
    $parts = foreach ($argument in $Arguments) {
        if ($argument -match '\s') {
            $split = $argument.Split('=', 2)
            if ($split.Count -eq 2) { '{0}="{1}"' -f $split[0], $split[1] } else { '"{0}"' -f $argument }
        } else {
            $argument
        }
    }
    return ($parts -join ' ')
}

function Get-SettingsPath {
    if ($null -eq $script:Layout) { return (Join-Path $script:LauncherRoot 'launcher-settings.json') }
    return (Join-Path $script:Layout.UserData 'launcher-settings.json')
}

function New-DefaultSettings {
    return [ordered]@{
        # Only honoured for a complete tree extracted by hand elsewhere; the
        # launcher itself always installs into <root>\game\cod3, which is the
        # one place every rebuild step reads from.
        GameData     = ''
        # What the player installs from - the disc image, or the default.xex
        # (or folder) of a game already unpacked - and whether installing
        # also recompiles the game on this machine. The name is older than
        # the second kind.
        IsoPath      = ''
        Recompile    = $true
        # Set while an install that recompiles has not finished, so an
        # interrupted rebuild is resumed instead of silently falling back to
        # the prebuilt binary.
        RebuildPending = $false
        # Mouse pointer style for the launcher and the game window.
        Cursor       = 'brass'
        OutputMode   = 'Окно 1920x1080'
        RenderScale  = 1
        RefreshRate  = 60
        Vsync        = $true
        InputMode    = 'Клавиатура и мышь'
        # Call of Duty PC scale: degrees per count = sensitivity * 0.022.
        # World at War ships with 5.
        MouseSensitivity = 5.0
        MouseInvert  = $false
        AdsToggle    = $false
        AdsMultiplier = 1.0
        NoFoliage    = $true
        LogLevel     = 'info'
        TimingTrace  = $false
        # Everything the build can log, for chasing one bug (see
        # Get-LaunchArguments); KernelCallLog adds every kernel call on top.
        FullDiagnostics = $false
        KernelCallLog = $false
        # Launcher language: ru, en, uk, be, es or de; empty until chosen
        # (see Resolve-LauncherLanguage).
        Language     = ''
    }
}

function Import-Settings {
    $defaults = New-DefaultSettings
    $path = Get-SettingsPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $defaults }
    try {
        # Explicit UTF-8: Windows PowerShell would otherwise read a BOM-less
        # file written by PowerShell 7 as ANSI and garble the Russian values.
        $saved = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        return $defaults
    }
    foreach ($key in @($defaults.Keys)) {
        if ($null -ne $saved -and ($saved.PSObject.Properties.Name -contains $key)) {
            $defaults[$key] = $saved.$key
        }
    }
    return $defaults
}

function Export-Settings($Settings) {
    $path = Get-SettingsPath
    $directory = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    [IO.File]::WriteAllText($path, ($Settings | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($true)))
}

function Update-Settings([hashtable]$Changes) {
    # Settings the window does not show (the image path, the pending-rebuild
    # flag) change outside Read-Form; merge them into the saved file.
    foreach ($key in $Changes.Keys) { $script:Settings[$key] = $Changes[$key] }
    Export-Settings $script:Settings
}

# -------------------------------------------------------------------- language
#
# The launcher speaks Russian, English, Ukrainian, Belarusian, Spanish and
# German. The Russian text in this script is the key: launcher/strings.json
# holds one entry per text with the other five languages, and T returns the
# text in the chosen language - or the Russian one when a translation is
# missing, so a new line never shows up empty. Texts with values keep {0}
# placeholders in every language and are filled with -f after T.
# Settings values (OutputMode, InputMode) and the segment Tags stay Russian:
# they are data, not text.

$script:Languages = @('ru', 'en', 'uk', 'be', 'es', 'de')
$script:Language = 'ru'
$script:Strings = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)

function Import-LauncherStrings {
    $table = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    $path = Join-Path $script:LauncherRoot 'strings.json'
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        try {
            # An array of entries rather than one object keyed by the Russian
            # text: keys that differ only in case ("УСТАНОВКА", "Установка")
            # would collide in ConvertFrom-Json.
            # Assigned first: Windows PowerShell passes a JSON array down the
            # pipeline as one object, so @(... | ConvertFrom-Json) would hold
            # a single element - the whole array.
            $entries = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($entry in $entries) {
                $translations = @{}
                foreach ($property in $entry.PSObject.Properties) { $translations[$property.Name] = [string]$property.Value }
                if ($translations.ContainsKey('ru')) { $table[$translations['ru']] = $translations }
            }
        } catch {
            $table.Clear()
        }
    }
    $script:Strings = $table
}

function Resolve-LauncherLanguage($Settings, [bool]$HadSettings) {
    $choice = [string]$Settings.Language
    if ($script:Languages -contains $choice) { return $choice }
    # Testers who used the launcher before it was translated keep Russian; a
    # fresh install starts in the language of Windows when it is one of ours.
    if ($HadSettings) { return 'ru' }
    $system = [Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName
    if ($script:Languages -contains $system) { return $system }
    return 'en'
}

function T([string]$Text) {
    if ($script:Language -eq 'ru' -or [string]::IsNullOrEmpty($Text)) { return $Text }
    $entry = $null
    if ($script:Strings.TryGetValue($Text, [ref]$entry)) {
        $translated = $entry[$script:Language]
        if (-not [string]::IsNullOrEmpty($translated)) { return $translated }
    }
    return $Text
}

# ------------------------------------------------------------------ validation

function Test-GameData([string]$Path) {
    $result = [ordered]@{ Ok = $false; Xex = ''; Missing = @(); Sp = 0 }
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Container)) {
        $result.Missing = @(T 'папки с игрой ещё нет')
        return $result
    }
    $missing = New-Object System.Collections.Generic.List[string]
    $xex = Join-Path $Path 'default.xex'
    if (Test-Path -LiteralPath $xex -PathType Leaf) { $result.Xex = $xex } else { $missing.Add('default.xex') }
    $sp = Join-Path $Path 'sp'
    if (Test-Path -LiteralPath $sp -PathType Container) {
        $result.Sp = @(Get-ChildItem -LiteralPath $sp -Directory -ErrorAction SilentlyContinue).Count
        if ($result.Sp -lt 15) { $missing.Add((T 'каталог sp содержит {0} уровней вместо 15') -f $result.Sp) }
    } else {
        $missing.Add((T 'каталог {0}') -f 'sp')
    }
    foreach ($name in @('config', 'movies')) {
        if (-not (Test-Path -LiteralPath (Join-Path $Path $name) -PathType Container)) { $missing.Add((T 'каталог {0}') -f $name) }
    }
    $result.Missing = $missing.ToArray()
    $result.Ok = ($missing.Count -eq 0)
    return $result
}

function Resolve-GameDataPath {
    # The launcher decides where the game lives: <root>\game\cod3, filled from
    # the disc image. Code generation, the Xenon and coroutine bridges and the
    # build all read that exact folder, so it is the only place a rebuild can
    # work from. A complete tree the settings point at elsewhere still runs
    # the prebuilt game.
    $own = $script:Layout.GameData
    if ((Test-GameData $own).Ok) { return $own }
    $saved = [string]$script:Settings.GameData
    if ($saved -and -not $saved.Equals($own, [StringComparison]::OrdinalIgnoreCase) -and (Test-GameData $saved).Ok) {
        return $saved
    }
    return $own
}

function Test-PathWithin([string]$Child, [string]$Parent) {
    $childPath = [IO.Path]::GetFullPath($Child).TrimEnd('\', '/')
    $parentPath = [IO.Path]::GetFullPath($Parent).TrimEnd('\', '/')
    return $childPath.Equals($parentPath, [StringComparison]::OrdinalIgnoreCase) -or
        $childPath.StartsWith($parentPath + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Read-GodHeader([string]$Path) {
    # A Games on Demand package header: a CON/LIVE/PIRS file of content type
    # 00007000 with its <name>.data folder beside it (the layout the console
    # keeps under <Title ID>\00007000). $null for anything else.
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($item.PSIsContainer -or $item.Length -lt 0x971A -or $item.Length -gt 16MB) { return $null }
        $dataDir = $item.FullName + '.data'
        if (-not (Test-Path -LiteralPath $dataDir -PathType Container)) { return $null }
        $bytes = New-Object byte[] 0x400
        $stream = [IO.File]::OpenRead($item.FullName)
        try { $read = $stream.Read($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
        if ($read -lt $bytes.Length) { return $null }
        if ([Text.Encoding]::ASCII.GetString($bytes, 0, 4) -notin @('CON ', 'LIVE', 'PIRS')) { return $null }
        $word = { param($at) (([uint32]$bytes[$at] -shl 24) -bor ([uint32]$bytes[$at + 1] -shl 16) -bor ([uint32]$bytes[$at + 2] -shl 8) -bor [uint32]$bytes[$at + 3]) }
        if ((& $word 0x344) -ne 0x7000) { return $null }
        return [pscustomobject]@{
            Header = $item.FullName; DataDir = $dataDir
            TitleId = '{0:X8}' -f (& $word 0x360); MediaId = '{0:X8}' -f (& $word 0x354)
            DataFileCount = [int](& $word 0x39D)
        }
    } catch {
        return $null
    }
}

function Find-GodHeader([string]$Folder) {
    # The header sits in <Title ID>\00007000; a folder up to three levels above
    # it will do. Prefers this game's Title ID when several packages are found.
    $found = New-Object System.Collections.Generic.List[object]
    $level = @($Folder)
    for ($depth = 0; $depth -le 3 -and $level.Count -gt 0; $depth++) {
        $next = New-Object System.Collections.Generic.List[string]
        foreach ($dir in $level) {
            foreach ($item in @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)) {
                if ($item.PSIsContainer) {
                    if (-not $item.Name.EndsWith('.data', [StringComparison]::OrdinalIgnoreCase)) { $next.Add($item.FullName) }
                } elseif (Test-Path -LiteralPath ($item.FullName + '.data') -PathType Container) {
                    $header = Read-GodHeader $item.FullName
                    if ($header) { $found.Add($header) }
                }
            }
        }
        $level = $next.ToArray()
    }
    $own = @($found | Where-Object { $_.TitleId -eq (Get-ExpectedTitleId) })
    if ($own.Count -gt 0) { return $own[0] }
    if ($found.Count -gt 0) { return $found[0] }
    return $null
}

function Get-InstallSource([string]$Path) {
    # What the player installs from:
    #   iso     a disc image;
    #   folder  a game already unpacked into a folder, given by the folder or
    #           by default.xex in it (Path is the folder);
    #   god     a Games on Demand package, given by its header file or any
    #           folder up to three levels above it (God is the header).
    # $null when nothing is chosen.
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $god = Read-GodHeader $Path
        if ($god) { return [pscustomobject]@{ Kind = 'god'; Path = $god.Header; God = $god } }
        if ([IO.Path]::GetExtension($Path) -ieq '.xex') {
            return [pscustomobject]@{ Kind = 'folder'; Path = [IO.Path]::GetFullPath((Split-Path -Parent $Path)).TrimEnd('\', '/'); God = $null }
        }
        return [pscustomobject]@{ Kind = 'iso'; Path = $Path; God = $null }
    }
    if (Test-Path -LiteralPath $Path -PathType Container) {
        $full = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
        if (-not (Test-Path -LiteralPath (Join-Path $full 'default.xex') -PathType Leaf)) {
            $god = Find-GodHeader $full
            if ($god) { return [pscustomobject]@{ Kind = 'god'; Path = $god.Header; God = $god } }
        }
        return [pscustomobject]@{ Kind = 'folder'; Path = $full; God = $null }
    }
    # Gone or mistyped: judged by the name, the check then says what is wrong.
    if ([IO.Path]::GetExtension($Path) -ieq '.xex') {
        return [pscustomobject]@{ Kind = 'folder'; Path = (Split-Path -Parent $Path); God = $null }
    }
    return [pscustomobject]@{ Kind = 'iso'; Path = $Path; God = $null }
}

function Get-InstallSourceKind([string]$Path) {
    $source = Get-InstallSource $Path
    if ($source) { return $source.Kind }
    return ''
}

function Get-ExpectedTitleId {
    $lock = Join-Path $script:Layout.Root 'analysis\disc-source-lock.json'
    try {
        $json = Get-Content -LiteralPath $lock -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($json.title_id) { return ([string]$json.title_id).ToUpperInvariant() }
    } catch { }
    return '415607E1'
}

function Test-InstallOverlap([string]$Folder) {
    # Copying a folder into itself (or the install into a folder inside it)
    # would never end. $null when the two are apart.
    $install = [IO.Path]::GetFullPath($script:Layout.GameData).TrimEnd('\', '/')
    foreach ($output in @($install, ($install + '.partial'))) {
        if ((Test-PathWithin $Folder $output) -or (Test-PathWithin $output $Folder)) {
            return ((T 'Папка с игрой и папка, куда лаунчер ставит игру ({0}), вложены одна в другую. Выберите другую копию игры или переложите лаунчер.') -f $install)
        }
    }
    return $null
}

function Test-GodChoice($God) {
    # What scripts/copy-cod3-game.ps1 would refuse without reading the game,
    # said up front. It then checks default.xex and every file itself.
    $expectedTitle = Get-ExpectedTitleId
    if ($God.TitleId -ne $expectedTitle) {
        return ((T 'Это пакет GOD другой игры (Title ID {0}), а нужен Call of Duty 3 (Title ID {1}).') -f $God.TitleId, $expectedTitle)
    }
    $overlap = Test-InstallOverlap (Split-Path -Parent $God.Header)
    if ($overlap) { return $overlap }
    $parts = @(Get-ChildItem -LiteralPath $God.DataDir -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^Data\d{4}$' })
    if ($parts.Count -eq 0 -or ($God.DataFileCount -gt 0 -and $parts.Count -ne $God.DataFileCount)) {
        return ((T 'Пакет GOD неполный: в папке {0} частей Data — {1}, а должно быть {2}.') -f $God.DataDir, $parts.Count, $God.DataFileCount)
    }
    return $null
}

function Test-GameFolderChoice([string]$Folder) {
    # What scripts/copy-cod3-game.ps1 would refuse, said up front.
    if (-not (Test-Path -LiteralPath $Folder -PathType Container)) { return ((T 'Папка с игрой не найдена: {0}') -f $Folder) }
    $install = [IO.Path]::GetFullPath($script:Layout.GameData).TrimEnd('\', '/')
    # Picking the installed game itself: there is nothing to copy.
    if ($Folder.Equals($install, [StringComparison]::OrdinalIgnoreCase)) { return $null }
    $overlap = Test-InstallOverlap $Folder
    if ($overlap) { return $overlap }
    $xex = Join-Path $Folder 'default.xex'
    if (-not (Test-Path -LiteralPath $xex -PathType Leaf)) {
        return ((T 'В папке {0} нет default.xex. Выберите default.xex в корне распакованной игры — рядом с папками sp, movies и config.') -f $Folder)
    }
    $expected = Get-ExpectedXexHash
    if ($expected -and (Get-FileHash -LiteralPath $xex -Algorithm SHA256).Hash -ne $expected.ToUpperInvariant()) {
        return (T 'Этот default.xex от другой версии игры. Порт проверен на Call of Duty 3 (USA, Europe) для Xbox 360; другие версии и изменённые (расшифрованные, пропатченные) default.xex пока не поддерживаются.')
    }
    $data = Test-GameData $Folder
    if (-not $data.Ok) { return ((T 'В папке с игрой не хватает: {0}') -f ($data.Missing -join ', ')) }
    return $null
}

function Test-IsoChoice([string]$Path) {
    # Everything the extraction (or copy) script would refuse, said up front
    # and in plain words. Returns $null when the source can be used.
    if ([string]::IsNullOrWhiteSpace($Path)) { return (T 'Не выбран ни образ диска, ни папка с игрой.') }
    $source = Get-InstallSource $Path
    if ($source.Kind -eq 'folder') { return (Test-GameFolderChoice $source.Path) }
    if ($source.Kind -eq 'god') { return (Test-GodChoice $source.God) }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return ((T 'Файл образа не найден: {0}') -f $Path) }
    $item = Get-Item -LiteralPath $Path
    if ($item.Length -lt 1GB) {
        return ((T 'Это не похоже на образ диска Xbox 360 ({0} МБ): нужен .iso размером около 7 ГБ.') -f [math]::Round($item.Length / 1MB))
    }
    foreach ($inside in @($script:Layout.GameData, (Join-Path $script:Layout.Root 'analysis'))) {
        if (Test-PathWithin $Path $inside) {
            return ((T 'Образ лежит в папке, куда лаунчер распаковывает игру ({0}). Переложите .iso в любое другое место.') -f $inside)
        }
    }
    return $null
}

function Get-FailureHint([string]$LogText) {
    # The build scripts speak English and in stack traces; translate the
    # failures a player can actually do something about.
    $hints = @(
        @{ Pattern = 'Image SHA256 differs'
           Text = 'Этот образ отличается от поддерживаемого. Порт проверен на образе Call of Duty 3 (USA, Europe) для Xbox 360 (SHA-256 0FD477CE…1586); другие дампы и ревизии пока не поддерживаются.' },
        @{ Pattern = 'Input/tool must be outside output directories'
           Text = 'Образ лежит внутри папки, куда распаковывается игра. Переложите .iso в другое место и запустите установку снова.' },
        @{ Pattern = 'Unknown existing (file|directory), refusing overwrite|Existing file differs from source'
           Text = 'В папке game\cod3 уже лежат посторонние или повреждённые файлы, и распаковщик не стал их перезаписывать. Удалите папку game\cod3 рядом с лаунчером и запустите установку снова.' },
        @{ Pattern = 'Missing input image'
           Text = 'Файл образа не найден — возможно, его переместили или диск отключён.' },
        # scripts/copy-cod3-game.ps1: installing from an unpacked game or a
        # Games on Demand package.
        @{ Pattern = 'default\.xex SHA256 differs'
           Text = 'Этот default.xex от другой версии игры. Порт проверен на Call of Duty 3 (USA, Europe) для Xbox 360; другие версии и изменённые (расшифрованные, пропатченные) default.xex пока не поддерживаются.' },
        @{ Pattern = 'Game code differs from the supported revision'
           Text = 'Код игры (default.xex или модули уровней .dll) отличается от поддерживаемой версии Call of Duty 3 (USA, Europe), а пересобирается именно он. Выберите другую копию игры или сам .iso.' },
        @{ Pattern = 'Game files are incomplete'
           Text = 'В выбранной копии игры не хватает файлов — список в журнале установки. Скопируйте игру целиком заново или выберите сам .iso.' },
        @{ Pattern = 'GOD package is a different game'
           Text = 'Это пакет GOD другой игры. Нужен Call of Duty 3 (Title ID 415607E1).' },
        @{ Pattern = 'GOD data is missing|GOD data ends early|no XDVDFS volume descriptor|damaged directory entry'
           Text = 'Пакет GOD неполный или повреждён: рядом с файлом-заголовком должна лежать папка .data со всеми частями Data0000, Data0001… Скопируйте пакет заново или выберите .iso.' },
        @{ Pattern = 'Not a Call of Duty 3 game folder or Games on Demand package'
           Text = 'Выбранный файл — не образ диска, не default.xex и не пакет GOD Call of Duty 3.' },
        @{ Pattern = 'Missing default\.xex in the game folder'
           Text = 'В выбранной папке нет default.xex. Выберите default.xex в корне распакованной игры — рядом с папками sp, movies и config.' },
        @{ Pattern = 'Missing game folder'
           Text = 'Папка с игрой не найдена — возможно, её переместили или диск отключён.' },
        @{ Pattern = 'Game folder overlaps the install folder'
           Text = 'Папка с игрой и папка game\cod3, куда лаунчер ставит игру, вложены одна в другую. Выберите другую копию игры или переложите лаунчер.' },
        # The OS message comes in the language of Windows.
        @{ Pattern = 'Not enough disk space|not enough space|0x80070070|No space left|Недостаточно места|Недостатньо місця|Nicht genügend Speicherplatz|No hay espacio suficiente'
           Text = 'Не хватает места на диске. Игре с рекомпиляцией нужно около 7 ГБ свободного места, полной компиляции — около 12 ГБ. Уже скопированное сохранится: освободите место и нажмите кнопку снова — установка продолжится с того же места.' },
        @{ Pattern = 'No such host|NameResolutionFailure|Unable to connect|Could not resolve|remote name could not be resolved|timed out'
           Text = 'Нет доступа в интернет. Компилятор Microsoft (около 280 МБ) скачивается с серверов Microsoft один раз; проверьте подключение или выключите пересборку во вкладке «Установка».' },
        @{ Pattern = 'Application Control|0x800711C7|управления приложениями|blocked by your organization'
           Text = 'Windows (Smart App Control) заблокировал только что собранную программу. Отключается в «Безопасность Windows» → «Управление приложениями и браузером»; отключение необратимо, решение за вами. Либо выключите пересборку и играйте готовой сборкой.' }
    )
    foreach ($hint in $hints) {
        if ($LogText -match $hint.Pattern) { return (T $hint.Text) }
    }
    return $null
}

function Get-ExpectedXexHash {
    # The identity of the supported revision, if the bundle carries it.
    foreach ($candidate in @((Join-Path $script:Layout.Root 'analysis\disc-source-lock.json'), $script:Layout.Manifest)) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        try {
            $json = Get-Content -LiteralPath $candidate -Raw | ConvertFrom-Json
        } catch { continue }
        if ($json.PSObject.Properties.Name -contains 'expected_default_xex') { return $json.expected_default_xex.sha256 }
        if ($json.PSObject.Properties.Name -contains 'input_xex_sha256') { return $json.input_xex_sha256 }
        if ($json.PSObject.Properties.Name -contains 'input_sha256') { return $json.input_sha256 }
    }
    return $null
}

function Test-Installation([string]$GameDataPath) {
    $lines = New-Object System.Collections.Generic.List[string]
    # The first line that makes the check fail, for the status banner.
    $problems = New-Object System.Collections.Generic.List[string]
    $ok = $true

    # Extra parentheses where -f takes several values: inside a method call
    # a comma would start the next argument.
    $lines.Add(((T "Лаунчер: версия {0}, режим '{1}'") -f $script:LauncherVersion, $script:Layout.Kind))
    $lines.Add((T 'Приложение: {0}') -f $script:Layout.Exe)

    $requiredDlls = @('rexruntimerd.dll', 'rexgpu-xenosrd.dll', 'cod3_coroutines.dll')
    foreach ($dll in $requiredDlls) {
        $path = Join-Path $script:Layout.BinDir $dll
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $lines.Add('  ' + ((T 'есть {0}') -f $dll))
        } else {
            $problem = (T 'НЕТ {0}') -f $dll
            $lines.Add('  ' + $problem)
            $problems.Add($problem)
            $ok = $false
        }
    }
    $missions = @(Get-ChildItem -LiteralPath $script:Layout.BinDir -Filter 'cod3_pc_*.dll' -ErrorAction SilentlyContinue).Count
    $lines.Add('  ' + ((T 'библиотек уровней: {0} из 15') -f $missions))
    if ($missions -lt 15) {
        $problems.Add((T 'библиотек уровней: {0} из 15') -f $missions)
        $ok = $false
    }

    $data = Test-GameData $GameDataPath
    if ($data.Ok) {
        $lines.Add(((T 'Данные игры: {0} (уровней: {1})') -f $GameDataPath, $data.Sp))
        # The launcher can see this folder; the game only sees what survives
        # its narrow-string path conversion. Check that here rather than let
        # the game exit with "--game_data_root does not exist".
        $guestPath = Get-GuestPathArgument $GameDataPath
        if (-not $guestPath) {
            $problem = T 'НЕТ: игра не сможет открыть этот путь — в нём есть символы вне латиницы, а короткое имя 8.3 недоступно. Перенесите данные в каталог с латинским именем или положите их в game\cod3 рядом с лаунчером.'
            $lines.Add('  ' + $problem)
            $problems.Add($problem)
            $ok = $false
        } elseif ($guestPath -ne $GameDataPath) {
            $lines.Add('  ' + ((T 'игре передаётся как: {0}') -f $guestPath))
        }
        $expected = Get-ExpectedXexHash
        if ($expected) {
            $actual = (Get-FileHash -LiteralPath $data.Xex -Algorithm SHA256).Hash
            if ($actual -eq $expected.ToUpperInvariant()) {
                $lines.Add('  ' + (T 'default.xex совпадает с поддерживаемой версией диска'))
            } else {
                $problem = T 'ВНИМАНИЕ: default.xex не совпадает с поддерживаемой версией диска'
                $lines.Add('  ' + $problem)
                $lines.Add('    ' + ((T 'ожидается {0}') -f $expected.ToUpperInvariant()))
                $lines.Add('    ' + ((T 'получено  {0}') -f $actual))
                $problems.Add($problem)
                $ok = $false
            }
        }
    } else {
        $lines.Add((T 'Игра: не установлена ({0})') -f ($data.Missing -join ', '))
        $lines.Add('  ' + ((T 'Выберите образ диска (.iso), default.xex уже распакованной игры или пакет GOD и нажмите «Установить и играть» — лаунчер сам поставит игру в {0}.') -f $script:Layout.GameData))
        $ok = $false
    }

    $gpu = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
        Where-Object { $_.AdapterRAM -gt 0 -or $_.CurrentHorizontalResolution -gt 0 } |
        Select-Object -First 1
    if ($gpu) {
        $lines.Add(((T 'Видеокарта: {0}, режим {1}x{2} при {3} Гц') -f $gpu.Name, $gpu.CurrentHorizontalResolution,
                    $gpu.CurrentVerticalResolution, $gpu.CurrentRefreshRate))
    }

    $sac = $null
    try {
        $sac = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -ErrorAction Stop).VerifiedAndReputablePolicyState
    } catch { $sac = $null }
    if ($sac -eq 1) {
        $lines.Add((T 'Smart App Control включён: Windows может заблокировать запуск неподписанной сборки.'))
    }

    $lines.Add('')
    if ($ok) { $lines.Add((T 'Проверка пройдена, можно запускать.')) } else { $lines.Add((T 'Проверка не пройдена, смотрите строки выше.')) }
    $firstProblem = if ($problems.Count -gt 0) { $problems[0] } else { $null }
    return @{ Ok = $ok; Text = ($lines -join [Environment]::NewLine); Problem = $firstProblem }
}

# ------------------------------------------------------------------- launching

function Test-AsciiString([string]$Value) {
    if ([string]::IsNullOrEmpty($Value)) { return $true }
    foreach ($character in $Value.ToCharArray()) {
        if ([int]$character -gt 126) { return $false }
    }
    return $true
}

function Get-ShortPathCompat([string]$Path) {
    # 8.3 names are always ASCII. They exist only if the volume keeps them.
    try {
        $fso = New-Object -ComObject Scripting.FileSystemObject
        if (Test-Path -LiteralPath $Path -PathType Container) { return $fso.GetFolder($Path).ShortPath }
        if (Test-Path -LiteralPath $Path -PathType Leaf) { return $fso.GetFile($Path).ShortPath }
    } catch {
        return $null
    }
    return $null
}

function Get-GuestPathArgument([string]$Path, [switch]$CreateIfMissing) {
    # The game turns these arguments into a narrow string before touching the
    # filesystem, so an absolute path containing non-ASCII characters never
    # matches anything and it exits with "--game_data_root does not exist".
    # Two forms do survive: a path relative to the working directory, which is
    # what scripts/run-cod3.ps1 has always passed, and the 8.3 short name,
    # which is ASCII by construction. Prefer the relative form, fall back to
    # the short name, and report failure rather than launching into a crash.
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $full = [IO.Path]::GetFullPath($Path)
    if ($CreateIfMissing -and -not (Test-Path -LiteralPath $full)) {
        New-Item -ItemType Directory -Path $full -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $full)) { return $null }

    $root = [IO.Path]::GetFullPath($script:Layout.Root).TrimEnd('\', '/')
    if ($full.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
        $relative = $full.Substring($root.Length + 1).Replace('\', '/')
        if ($relative -and (Test-AsciiString $relative)) { return $relative }
    }
    if (Test-AsciiString $full) { return $full }

    $short = Get-ShortPathCompat $full
    if ($short -and (Test-AsciiString $short)) { return $short }
    return $null
}

function Get-LaunchArguments($Settings, [string]$GameDataPath, [string]$LogRelative) {
    $gameArgument = Get-GuestPathArgument $GameDataPath
    if (-not $gameArgument) {
        throw ((T 'Игра не сможет открыть этот путь: {0}') -f $GameDataPath + [Environment]::NewLine +
               (T 'В пути есть символы вне латиницы, а короткое имя 8.3 для него недоступно. Перенесите данные игры в каталог с латинским именем или положите их в папку game\cod3 рядом с лаунчером.'))
    }
    $userArgument = Get-GuestPathArgument $script:Layout.UserData -CreateIfMissing
    $cacheArgument = Get-GuestPathArgument $script:Layout.CacheRoot -CreateIfMissing
    if (-not $userArgument -or -not $cacheArgument) {
        throw ((T 'Игра не сможет открыть свои рабочие каталоги: {0}') -f ($script:Layout.UserData + ', ' + $script:Layout.CacheRoot) +
               [Environment]::NewLine + (T 'Распакуйте пакет в каталог с латинским именем.'))
    }

    $arguments = New-Object System.Collections.Generic.List[string]
    $arguments.Add('--gpu_plugin=xenos')
    $arguments.Add("--game_data_root=$gameArgument")
    $arguments.Add("--user_data_root=$userArgument")
    $arguments.Add("--cache_root=$cacheArgument")
    $arguments.Add("--log_file=$LogRelative")
    $fullDiagnostics = [bool]$Settings.FullDiagnostics
    $logLevel = if ($fullDiagnostics) { 'trace' } else { [string]$Settings.LogLevel }
    $arguments.Add("--log_level=$logLevel")
    if ($fullDiagnostics) {
        # Full diagnostics: every log macro, flushed each second so a crash
        # loses at most one second, and room for about half an hour of play
        # (40 x 100 MB; New-DiagnosticsReport picks what fits in a report).
        $arguments.AddRange([string[]]@('--log_noisy=true', '--log_flush_interval=1',
                                        '--log_max_file_size_mb=100', '--log_max_files=40',
                                        '--pc_controls_debug=true'))
        if ($Settings.KernelCallLog) { $arguments.Add('--log_high_frequency_kernel_calls=true') }
    } elseif ($logLevel -eq 'trace') {
        # About 1 MB a second at this level: with the default 20 files of 5 MB
        # the start of a session was already rotated away after 8 minutes.
        $arguments.Add('--log_max_file_size_mb=20')
        $arguments.Add('--log_max_files=50')
    }
    # The game's own console (AI, script, path and spawn messages), which the
    # retail build prints nowhere (integration/pc-controls/game_console.cpp).
    if ($fullDiagnostics -or $logLevel -ne 'info') { $arguments.Add('--cod3_game_console=true') }

    switch ($Settings.OutputMode) {
        'Окно 1280x720'   { $arguments.Add('--window_width=1280'); $arguments.Add('--window_height=720'); $arguments.Add('--fullscreen=false') }
        'Окно 1920x1080'  { $arguments.Add('--window_width=1920'); $arguments.Add('--window_height=1080'); $arguments.Add('--fullscreen=false') }
        'Окно 2560x1440'  { $arguments.Add('--window_width=2560'); $arguments.Add('--window_height=1440'); $arguments.Add('--fullscreen=false') }
        default           { $arguments.Add('--fullscreen=true') }
    }
    $arguments.Add('--present_letterbox=true')
    $arguments.Add('--present_effect=bilinear')

    $scale = [int]$Settings.RenderScale
    if ($scale -gt 1) {
        $arguments.Add("--draw_resolution_scale_x=$scale")
        $arguments.Add("--draw_resolution_scale_y=$scale")
    }
    if ([int]$Settings.RefreshRate -ne 60) { $arguments.Add("--video_mode_refresh_rate=$($Settings.RefreshRate)") }
    if (-not $Settings.Vsync) { $arguments.Add('--vsync=false') }
    # Pointer style in the game window; the game reads
    # launcher\assets\cursors\<style>\arrow.cur relative to its working folder.
    $arguments.Add('--pc_cursor=' + (Get-CursorStyle ([string]$Settings.Cursor)))

    if ($Settings.InputMode -eq 'Геймпад') {
        $arguments.AddRange([string[]]@('--mnk_mode=false', '--pc_controls=false'))
    } else {
        # The SDK driver only provides the device and the pointer lock; its
        # keybind layer is silenced so it cannot double up with, or turn the
        # arrow keys into camera motion alongside, the port's own PC layer
        # (integration/pc-controls), which owns the whole mapping.
        # mnk_sensitivity only scales the stick emulation that menus and the
        # stick-swirl battle actions read; the camera turns from raw counts.
        # 3 lets an ordinary circular mouse motion reach a full deflection.
        $arguments.AddRange([string[]]@('--mnk_mode=true', '--mnk_mouse=true', '--mnk_sensitivity=3'))
        foreach ($bind in @('a', 'b', 'x', 'y', 'left_trigger', 'right_trigger', 'left_shoulder', 'right_shoulder',
                            'lstick_up', 'lstick_down', 'lstick_left', 'lstick_right', 'lstick_press',
                            'rstick_up', 'rstick_down', 'rstick_left', 'rstick_right', 'rstick_press',
                            'dpad_up', 'dpad_down', 'dpad_left', 'dpad_right', 'start', 'back', 'guide')) {
            $arguments.Add("--keybind_$bind=")
        }
        $culture = [Globalization.CultureInfo]::InvariantCulture
        $arguments.AddRange([string[]]@(
            '--pc_controls=true', '--pc_mouse_direct=true',
            ('--pc_mouse_sensitivity=' + ([double]$Settings.MouseSensitivity).ToString('0.###', $culture)),
            ('--pc_mouse_ads_multiplier=' + ([double]$Settings.AdsMultiplier).ToString('0.###', $culture)),
            ('--pc_mouse_invert=' + $(if ($Settings.MouseInvert) { 'true' } else { 'false' })),
            ('--pc_ads_toggle=' + $(if ($Settings.AdsToggle) { 'true' } else { 'false' }))))
    }
    return $arguments.ToArray()
}

function Get-ButtonIconsDirectory {
    $directory = Join-Path $script:Layout.Root 'integration\button-icons'
    if (@(Get-ChildItem -LiteralPath $directory -Filter '*.c3tex' -File -ErrorAction SilentlyContinue).Count -gt 0) {
        return $directory
    }
    return $null
}

function Start-Game($Settings, [string]$GameDataPath) {
    foreach ($directory in @($script:Layout.UserData, $script:Layout.CacheRoot, $script:Layout.LogDir)) {
        if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    }
    $stamp = [DateTime]::Now.ToString('yyyyMMdd-HHmmss')
    $logPath = Join-Path $script:Layout.LogDir "cod3-launcher-$stamp.log"
    $logRelative = Get-RelativePathCompat $script:Layout.Root $logPath
    $arguments = Get-LaunchArguments $Settings $GameDataPath $logRelative

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $script:Layout.Exe
    $startInfo.WorkingDirectory = $script:Layout.Root
    $startInfo.UseShellExecute = $false
    $startInfo.Arguments = ConvertTo-CommandLine $arguments
    if ($Settings.NoFoliage) {
        # Foliage control-map workaround; see docs/testers.md.
        $startInfo.Environment['COD3_VS_TEX_ZERO'] = '18'
        $startInfo.Environment['COD3_VS_TEX_CONST'] = '0'
    }
    if ($Settings.InputMode -ne 'Геймпад') {
        # Keyboard/mouse glyphs drawn over the game's controller-button atlas
        # on the GPU (integration/button-icons). The game's own texture and
        # memory stay untouched; a gamepad player keeps the Xbox buttons.
        $icons = Get-ButtonIconsDirectory
        if ($icons) { $startInfo.Environment['COD3_TEXTURE_REPLACEMENTS'] = $icons }
    }
    if ($Settings.TimingTrace -or $Settings.FullDiagnostics) {
        # Frame rate, frame-time percentiles and the stall breakdown of every
        # long frame, every 5 s in the game log (GPU plugin, cod3_frame_stats.h).
        $startInfo.Environment['COD3_FRAME_STATS'] = '1'
        $startInfo.Environment['COD3_TIMING_TRACE'] = '1'
        $startInfo.Environment['COD3_TIMING_OUTPUT_DIR'] = 'logs'
        $startInfo.Environment['COD3_TIMING_MAX_CALLS'] = '65536'
    }
    if ($Settings.FullDiagnostics) {
        # Menu opens, pointer mapping and capture changes (pc-controls), and
        # the foliage texture slots (GPU plugin). Both only write log lines:
        # no screenshots, texture or shader dumps - no game data leaves.
        $startInfo.Environment['COD3_UI_PROBE'] = '1'
        $startInfo.Environment['COD3_TEX_LOG'] = '1'
        Limit-DiagnosticLogs
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw (T 'Не удалось запустить процесс игры.') }

    # The game validates its arguments and exits within a fraction of a second
    # when something is wrong. Reporting "игра запущена" for a process that is
    # already dead sends the tester looking at the screen instead of at the
    # reason, so wait briefly and read the log it just wrote.
    $exitedEarly = $process.WaitForExit(4000)
    $earlyError = $null
    if ($exitedEarly) {
        $exitCode = $process.ExitCode
        $reason = $null
        if (Test-Path -LiteralPath $logPath -PathType Leaf) {
            $logLines = @(Get-Content -LiteralPath $logPath -Encoding UTF8 -ErrorAction SilentlyContinue)
            $errorLines = @($logLines | Where-Object { $_ -match '\[error\]|\[critical\]' })
            if ($errorLines.Count -gt 0) {
                $reason = ($errorLines | Select-Object -Last 3) -join [Environment]::NewLine
            } elseif ($logLines.Count -gt 0) {
                $reason = ($logLines | Select-Object -Last 3) -join [Environment]::NewLine
            }
        }
        if (-not $reason) { $reason = (T 'Игра завершилась сразу, код выхода {0}, без записей в журнале.') -f $exitCode }
        $earlyError = $reason
    }

    $receipt = [ordered]@{
        launcher_version = $script:LauncherVersion
        started_local    = (Get-Date).ToString('o')
        executable       = $script:Layout.Exe
        game_data_root   = $GameDataPath
        arguments        = $arguments
        settings         = $Settings
        log_path         = $logPath
        process_id       = $process.Id
    }
    $receipt['texture_replacements'] = $startInfo.Environment['COD3_TEXTURE_REPLACEMENTS']
    $receipt['diagnostic_environment'] = [ordered]@{}
    foreach ($name in @('COD3_FRAME_STATS', 'COD3_TIMING_TRACE', 'COD3_UI_PROBE', 'COD3_TEX_LOG', 'COD3_VS_TEX_ZERO')) {
        if ($startInfo.Environment.ContainsKey($name)) { $receipt['diagnostic_environment'][$name] = $startInfo.Environment[$name] }
    }
    $receipt['exited_immediately'] = [bool]$exitedEarly
    if ($exitedEarly) { $receipt['early_exit_reason'] = $earlyError }
    ($receipt | ConvertTo-Json -Depth 6) |
        Set-Content -LiteralPath (Join-Path $script:Layout.LogDir 'last-launch.json') -Encoding UTF8
    return @{ Process = $process; LogPath = $logPath; ExitedEarly = [bool]$exitedEarly; EarlyError = $earlyError }
}

# ----------------------------------------------------------------- rebuilding

function Get-PowerShell7 {
    # Every rebuild step is a PowerShell 7 script. The package carries the
    # official PowerShell 7 build and runs it in place, so the version is known
    # and nothing has to be installed; an installed pwsh is the fallback.
    if ($script:Layout) {
        foreach ($relative in @('tools\pwsh\pwsh.exe', 'tools\toolchain-bundle\pwsh\pwsh.exe')) {
            $candidate = Join-Path $script:Layout.Root $relative
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
        }
    }
    $command = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    foreach ($candidate in @("$env:ProgramFiles\PowerShell\7\pwsh.exe", "${env:ProgramFiles(x86)}\PowerShell\7\pwsh.exe")) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return $null
}

function Get-BuildPrerequisites {
    # Four components cannot travel inside the package: rexglue.exe links
    # GPL-licensed GNU binutils code, and Clang, CMake/Ninja and MSVC are
    # third-party toolchains. All four can be produced or fetched on this
    # machine, so each one is marked either as present, or as something the
    # rebuild will obtain by itself (Provision), or as a hard requirement.
    $root = $script:Layout.Root
    # The SDK source sits at sdk-source in a package and at tools\rexglue-source
    # in the workspace; the build harness probes both, so this check must too.
    $sdkSource = Join-Path $root 'sdk-source\src\codegen\codegen.cpp'
    if (-not (Test-Path -LiteralPath $sdkSource -PathType Leaf)) {
        $workspaceSdkSource = Join-Path $root 'tools\rexglue-source\src\codegen\codegen.cpp'
        if (Test-Path -LiteralPath $workspaceSdkSource -PathType Leaf) { $sdkSource = $workspaceSdkSource }
    }
    $bundled = Test-Path -LiteralPath (Join-Path $root 'tools\toolchain-bundle') -PathType Container
    $fromPackage = T 'поставится из пакета'
    $checks = @(
        @{ Name = (T 'Исходники порта (cod3-pc, scripts)'); Path = (Join-Path $root 'scripts\build-cod3.ps1'); Provision = $null },
        @{ Name = (T 'Манифест рекомпиляции'); Path = (Join-Path $root 'cod3-pc\cod3_pc_manifest.toml'); Provision = $null },
        @{ Name = (T 'ReXGlue SDK: runtime и заголовки'); Path = (Join-Path $root 'win-amd64\lib\cmake\rexglue\rexglueConfig.cmake'); Provision = $null },
        @{ Name = (T 'Исходники SDK для сборки rexglue.exe'); Path = $sdkSource; Provision = $null },
        @{ Name = 'rexglue.exe'; Path = (Join-Path $root 'win-amd64\bin\rexglue.exe'); Provision = (T 'соберётся из исходников SDK') },
        @{ Name = (T 'Компилятор Clang'); Path = (Join-Path $root 'tools\toolchain\llvm\bin\clang++.exe'); Provision = $(if ($bundled) { $fromPackage } else { T 'скачается с сайта LLVM' }) },
        @{ Name = (T 'Окружение MSVC'); Path = (Join-Path $root 'tools\toolchain\msvc\env.json'); Provision = (T 'скачается с серверов Microsoft (~280 МБ)') },
        @{ Name = 'CMake'; Path = (Join-Path $root 'tools\cmake\bin\cmake.exe'); Provision = $(if ($bundled) { $fromPackage } else { T 'скачается с сайта Kitware' }) },
        @{ Name = 'Ninja'; Path = (Join-Path $root 'tools\ninja\ninja.exe'); Provision = $(if ($bundled) { $fromPackage } else { T 'скачается с GitHub' }) },
        @{ Name = (T 'Распаковщик образа xdvdfs'); Path = (Join-Path $root 'tools\xdvdfs\xdvdfs.exe'); Provision = $(if ($bundled) { $fromPackage } else { T 'скачается из релиза antangelo/xdvdfs' }) }
    )
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($check in $checks) {
        $present = Test-Path -LiteralPath $check.Path
        $rows.Add([ordered]@{
            Name = $check.Name
            Path = $check.Path
            Ok = ($present -or ($null -ne $check.Provision))
            Present = $present
            Provision = $check.Provision
        })
    }
    $pwsh = Get-PowerShell7
    $rows.Add([ordered]@{ Name = 'PowerShell 7'; Path = $pwsh; Ok = ($null -ne $pwsh); Present = ($null -ne $pwsh); Provision = $null })
    return $rows.ToArray()
}

function Test-AppControlEnforcing {
    # Smart App Control refuses to run freshly built unsigned executables. The
    # rebuild produces several, so it can stop on one of them even though the
    # compilation itself succeeded.
    try {
        $policy = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -ErrorAction Stop
        return ($policy.VerifiedAndReputablePolicyState -eq 1)
    } catch {
        return $false
    }
}

function Get-InstallSpaceProblem([bool]$Recompile, [bool]$FullCompile) {
    # Checked before an installation starts, so it fails with numbers instead
    # of an out-of-space error halfway through the copy. $null when it fits.
    $need = [long]0
    if (-not (Test-Path -LiteralPath (Join-Path $script:Layout.GameData 'default.xex') -PathType Leaf)) {
        # The game (5.9 GB), less what an interrupted install already copied.
        $need += [long]6.0GB
        $partial = $script:Layout.GameData + '.partial'
        if (Test-Path -LiteralPath $partial -PathType Container) {
            $done = (Get-ChildItem -LiteralPath $partial -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
            if ($done) { $need -= [long]$done }
        }
    }
    # Generated C++, analysis and Python; a full compile adds the compiler and
    # the object files.
    if ($Recompile) { $need += [long]1.0GB }
    if ($FullCompile) { $need += [long]5.0GB }
    if ($need -le 0) { return $null }
    try {
        $drive = New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($script:Layout.Root))
        $free = $drive.AvailableFreeSpace
    } catch {
        return $null
    }
    if ($free -ge $need) { return $null }
    return ((T 'На диске {0} свободно {1:n1} ГБ, а установке нужно ещё около {2:n1} ГБ. Освободите место и нажмите кнопку снова — уже скопированное сохранится.') -f
        $drive.Name.TrimEnd('\'), ($free / 1GB), ($need / 1GB))
}

function Get-AppControlWarning {
    if (-not (Test-AppControlEnforcing)) { return $null }
    return (T 'Внимание: в Windows включён Smart App Control. Он может не дать запустить только что собранные программы, и тогда пересборка остановится на одном из шагов с сообщением о политике управления приложениями. Отключается в «Безопасность Windows» → «Управление приложениями и браузером»; отключение необратимо, поэтому решение за вами.')
}

function Get-ProvisionScript([string]$RelativePath) {
    # Plan B tooling lives under tools/ in both the workspace and the package.
    $candidate = Join-Path $script:Layout.Root $RelativePath
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    return $null
}

function Get-RebuildSteps([string]$IsoPath, [bool]$Recompile = $true, [bool]$FullCompile = $false) {
    # Installing is: unpack the image into <root>\game\cod3 and, unless the
    # player chose the ready build, recompile from it. Code generation, both
    # bridges and the build read exactly that folder, so it is also where the
    # image goes.
    #
    # Recompiling translates the game's code into C++ (rexglue.exe, the Xenon
    # and coroutine bridges - all shipped built, no compiler needed) and then
    # hands over to scripts/complete-recompile.ps1, which compiles only when
    # the result differs from the code the package's ready-made build was
    # compiled from. $FullCompile ("Пересобрать игру") always compiles.
    $root = $script:Layout.Root
    $steps = New-Object System.Collections.Generic.List[object]

    $destination = $script:Layout.GameData
    $extracted = Test-Path -LiteralPath (Join-Path $destination 'default.xex') -PathType Leaf
    if (-not $extracted -and [string]::IsNullOrWhiteSpace($IsoPath)) {
        throw (T 'Игра ещё не установлена, а источник не выбран. Выберите образ .iso, default.xex уже распакованной игры или пакет GOD.')
    }
    # A game already unpacked into a folder, or a Games on Demand package, is
    # read by copy-cod3-game.ps1 rather than extracted, so it needs no disc
    # image tool.
    $source = Get-InstallSource $IsoPath
    $gameFolder = if ($source -and $source.Kind -ne 'iso') { $source.Path } else { $null }

    # Plan B: obtain the components the package is not allowed to carry. This
    # has to come first: unpacking the disc image already needs xdvdfs, and the
    # bridges need Python. The compilers are needed up front only for a full
    # compile or when a code generation tool has to be built; otherwise
    # complete-recompile.ps1 installs them itself if the C++ turns out to
    # differ from the ready-made build.
    $rexglueExe = Join-Path $root 'win-amd64\bin\rexglue.exe'
    $xenonTools = @('tools\XenonRecomp\out\build\windows-release\XenonAnalyse\XenonAnalyse.exe',
                    'tools\XenonRecomp\out\build\windows-release\XenonRecomp\XenonRecomp.exe')
    $thunks = Join-Path $root 'integration\xenon\generated\thunks.generated.inl'
    $needCompiler = $Recompile -and ($FullCompile -or -not (Test-Path -LiteralPath $rexglueExe -PathType Leaf) -or
        (-not (Test-Path -LiteralPath $thunks -PathType Leaf) -and
         @($xenonTools | Where-Object { -not (Test-Path -LiteralPath (Join-Path $root $_) -PathType Leaf) }).Count -gt 0))
    $toolchainScript = Get-ProvisionScript 'tools\toolchain-provision\Install-Toolchain.ps1'
    $toolchainMissing = @()
    foreach ($probe in @(
        @{ Name = 'xdvdfs'; Path = 'tools\xdvdfs\xdvdfs.exe' },
        @{ Name = 'python'; Path = 'tools\toolchain\bootstrap-python\python.exe' },
        @{ Name = 'python-packages'; Path = 'analysis\title-python\xxhash\__init__.py' },
        @{ Name = 'cmake'; Path = 'tools\cmake\bin\cmake.exe' },
        @{ Name = 'ninja'; Path = 'tools\ninja\ninja.exe' },
        @{ Name = 'llvm'; Path = 'tools\toolchain\llvm\bin\clang-cl.exe' },
        @{ Name = 'msvc'; Path = 'tools\toolchain\msvc\env.json' })) {
        # The extractor is only needed when there is an image to unpack,
        # Python only when recompiling, the compilers only as said above.
        if ($probe.Name -eq 'xdvdfs' -and ($extracted -or $gameFolder)) { continue }
        if ($probe.Name -like 'python*' -and -not $Recompile) { continue }
        if ($probe.Name -in @('cmake', 'ninja', 'llvm', 'msvc') -and -not $needCompiler) { continue }
        if (-not (Test-Path -LiteralPath (Join-Path $root $probe.Path))) { $toolchainMissing += $probe.Name }
    }
    if ($toolchainScript -and $toolchainMissing.Count -gt 0) {
        $steps.Add([ordered]@{
            Name = $(if ($needCompiler) { (T 'Установка компилятора и инструментов ({0})') -f ($toolchainMissing -join ', ') }
                     elseif ($Recompile) { (T 'Подготовка инструментов рекомпиляции ({0})') -f ($toolchainMissing -join ', ') }
                     else { T 'Установка распаковщика образа' })
            File = $toolchainScript
            # -File turns every token into a separate string argument, so a
            # multi-value array parameter would not bind. The provisioner skips
            # whatever is already present, making 'all' (or 'tools', all but
            # the compilers) equivalent here.
            Arguments = $(if ($needCompiler) { @('-Component', 'all') } elseif ($Recompile) { @('-Component', 'tools') } else { @('-Component', 'xdvdfs') })
        })
    }

    if (-not $extracted -and $gameFolder) {
        $steps.Add([ordered]@{
            Name = $(if ($source.Kind -eq 'god') { T 'Извлечение игры из пакета GOD' } else { T 'Копирование игры из папки' })
            File = (Join-Path $root 'scripts\copy-cod3-game.ps1')
            Arguments = @('-Source', $gameFolder, '-Destination', $destination)
        })
    } elseif (-not $extracted) {
        $steps.Add([ordered]@{
            Name = (T 'Распаковка образа диска')
            File = (Join-Path $root 'scripts\extract-cod3.ps1')
            Arguments = @('-Image', $IsoPath, '-Destination', $destination)
        })
    }
    if (-not $Recompile) { return $steps.ToArray() }

    $cliScript = Get-ProvisionScript 'tools\rexglue-cli\Build-RexGlueCli.ps1'
    if ($cliScript -and -not (Test-Path -LiteralPath $rexglueExe -PathType Leaf)) {
        $steps.Add([ordered]@{
            Name = (T 'Сборка rexglue.exe из исходников SDK')
            File = $cliScript
            Arguments = @()
        })
    }

    # The two reviewed Xenon thunks are generated from the game executable, so
    # they are never shipped; they are regenerated here from the user's copy.
    $bridgeScript = Get-ProvisionScript 'tools\xenon-bridge-build\Build-XenonBridge.ps1'
    if ($bridgeScript -and -not (Test-Path -LiteralPath $thunks -PathType Leaf)) {
        $steps.Add([ordered]@{
            Name = (T 'Мост Xenon из вашего образа игры')
            File = $bridgeScript
            Arguments = @()
        })
    }

    # The coroutine bridge: capture wrappers plus the PCH template overlay that
    # code generation reads. Both are derived from the user's mission modules,
    # so they are rebuilt here rather than shipped. It must run before code
    # generation - without the overlay ReXGlue quietly uses its stock template.
    $coroutineScript = Join-Path $root 'integration\coroutines\Prepare-FromGame.ps1'
    $captureTargets = Join-Path $root 'integration\coroutines\generated\capture_targets.cmake'
    $pchOverlay = Join-Path $root 'integration\coroutines\templates\codegen\pch_h.inja'
    $coroutinesPending = -not (Test-Path -LiteralPath $captureTargets -PathType Leaf) -or
                         -not (Test-Path -LiteralPath $pchOverlay -PathType Leaf)
    if ((Test-Path -LiteralPath $coroutineScript -PathType Leaf) -and $coroutinesPending) {
        $steps.Add([ordered]@{
            Name = (T 'Мост корутин из вашего образа игры')
            File = $coroutineScript
            Arguments = @()
        })
    }

    # Code generation. The CMake project includes the module list the generator
    # writes, so a package that has never been built needs one run before CMake
    # can configure at all. When the coroutine overlay is being produced in this
    # same run, anything generated earlier was made from the stock template and
    # has to be regenerated, so the stamps are ignored.
    $codegenScript = Join-Path $root 'cod3-pc\cmake\Invoke-Codegen.ps1'
    $sourcesCmake = Join-Path $root 'cod3-pc\generated\default\sources.cmake'
    $codegenMissing = -not (Test-Path -LiteralPath $sourcesCmake -PathType Leaf)
    if ((Test-Path -LiteralPath $codegenScript -PathType Leaf) -and ($codegenMissing -or $coroutinesPending)) {
        $codegenArguments = @('-ReXGlue', $rexglueExe)
        $codegenName = T 'Первичная кодогенерация'
        if (-not $codegenMissing) {
            $codegenArguments += '-IgnoreStamp'
            $codegenName = T 'Повторная кодогенерация с мостом корутин'
        }
        $steps.Add([ordered]@{
            Name = $codegenName
            File = $codegenScript
            Arguments = $codegenArguments
        })
    }

    # On a fresh install the coroutine map is made before the first code
    # generation, so whether its 45 capture functions are registered in the
    # ReXGlue output can only be checked now. The map records when that check
    # has passed; until then it is scheduled again, also after an interruption.
    $coroutineMap = Join-Path $root 'analysis\cod3-allmodule-coroutine-sites.json'
    $coroutineConfirmed = $false
    if (Test-Path -LiteralPath $coroutineMap -PathType Leaf) {
        try {
            $mapData = Get-Content -LiteralPath $coroutineMap -Raw -Encoding UTF8 | ConvertFrom-Json
            $coroutineConfirmed = ($mapData.PSObject.Properties.Name -contains 'registration_checked') -and [bool]$mapData.registration_checked
        } catch {
            $coroutineConfirmed = $false
        }
    }
    if ((Test-Path -LiteralPath $coroutineScript -PathType Leaf) -and -not $coroutineConfirmed) {
        $steps.Add([ordered]@{
            Name = (T 'Проверка моста корутин по сгенерированному коду')
            File = $coroutineScript
            Arguments = @('-VerifyOnly')
        })
    }

    # The compile: skipped when the recompiled code matches the ready-made
    # build byte for byte, otherwise (or when asked) done in full, with the
    # compiler provisioned and the package's patched GPU plugin reused there.
    $finishArguments = @('-Jobs', "$([Environment]::ProcessorCount)")
    if ($FullCompile) { $finishArguments += '-Full' }
    $steps.Add([ordered]@{
        Name = $(if ($FullCompile) { T 'Рекомпиляция и сборка' } else { T 'Сверка с готовой сборкой (компиляция при отличиях)' })
        File = (Join-Path $root 'scripts\complete-recompile.ps1')
        Arguments = $finishArguments
    })
    return $steps.ToArray()
}

function Get-RelaunchedGame([int]$ExitedId) {
    # The game restarts itself between levels; the process it hands over to is
    # written next to the logs for a few seconds' worth of relevance.
    $marker = Join-Path $script:Layout.LogDir 'cod3-relaunch.txt'
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) { return $null }
    try {
        $item = Get-Item -LiteralPath $marker
        if (([DateTime]::Now - $item.LastWriteTime).TotalSeconds -gt 60) { return $null }
        $ids = @((Get-Content -LiteralPath $marker -Raw).Trim() -split '\s+')
        if ($ids.Count -lt 2 -or [int]$ids[0] -ne $ExitedId) { return $null }
        Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
        return [System.Diagnostics.Process]::GetProcessById([int]$ids[1])
    } catch {
        return $null
    }
}

function Get-GameLogSessions {
    # One game launch writes cod3-launcher-<stamp>.log and, once that fills,
    # rotates older text into .1.log, .2.log... (.1 is the newest of those).
    # Sessions come newest first, each with its parts newest first.
    $sessions = @{}
    foreach ($file in @(Get-ChildItem -LiteralPath $script:Layout.LogDir -File -Filter 'cod3-launcher-*.log' -ErrorAction SilentlyContinue)) {
        if ($file.Name -notmatch '^(cod3-launcher-\d{8}-\d{6})(?:\.(\d+))?\.log$') { continue }
        $key = $Matches[1]
        $part = if ($Matches[2]) { [int]$Matches[2] } else { 0 }
        if (-not $sessions.ContainsKey($key)) { $sessions[$key] = New-Object System.Collections.Generic.List[object] }
        $sessions[$key].Add([pscustomobject]@{ File = $file; Part = $part })
    }
    return @($sessions.Keys | Sort-Object -Descending | ForEach-Object {
        [pscustomobject]@{ Name = $_; Parts = @($sessions[$_] | Sort-Object Part) }
    })
}

function Limit-DiagnosticLogs([long]$Budget = 8GB) {
    # A full-diagnostics session can write 4 GB. Before such a launch the
    # oldest sessions go once all game logs pass the budget; the three newest
    # always stay for a report.
    $sessions = @(Get-GameLogSessions)
    $total = [long]0
    foreach ($session in $sessions) { foreach ($part in $session.Parts) { $total += $part.File.Length } }
    for ($i = $sessions.Count - 1; $i -ge 3 -and $total -gt $Budget; $i--) {
        foreach ($part in $sessions[$i].Parts) {
            try {
                Remove-Item -LiteralPath $part.File.FullName -Force -ErrorAction Stop
                $total -= $part.File.Length
            } catch { }
        }
    }
}

function Copy-SharedFile([string]$Source, [string]$Destination) {
    # A running game keeps its log open for writing; Copy-Item would refuse.
    $inputStream = [IO.File]::Open($Source, [IO.FileMode]::Open, [IO.FileAccess]::Read,
                                   [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    try {
        $outputStream = [IO.File]::Create($Destination)
        try { $inputStream.CopyTo($outputStream) } finally { $outputStream.Dispose() }
    } finally {
        $inputStream.Dispose()
    }
}

function New-DiagnosticsReport {
    $stamp = [DateTime]::Now.ToString('yyyyMMdd-HHmmss')
    $stagingRoot = Join-Path $env:TEMP "cod3-report-$stamp"
    New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null
    $notes = New-Object System.Collections.Generic.List[string]
    $picked = New-Object System.Collections.Generic.List[object]

    # The newest game session whole while it fits: its newest part (where it
    # crashed or stopped), its oldest surviving part (the start), then the
    # rest from newest to oldest. A trace-level log zips to 1/15-1/25, so the
    # report usually stays small enough to attach in Discord.
    $budget = [long]200MB
    $sessions = @(Get-GameLogSessions)
    if ($sessions.Count -gt 0) {
        $parts = @($sessions[0].Parts)
        $order = New-Object System.Collections.Generic.List[object]
        $order.Add($parts[0])
        if ($parts.Count -gt 1) { $order.Add($parts[$parts.Count - 1]) }
        for ($i = 1; $i -lt $parts.Count - 1; $i++) { $order.Add($parts[$i]) }
        $used = [long]0
        $skipped = 0
        foreach ($part in $order) {
            if ($picked.Count -gt 0 -and $used + $part.File.Length -gt $budget) { $skipped++; continue }
            $picked.Add($part.File)
            $used += $part.File.Length
        }
        if ($skipped -gt 0) {
            $notes.Add("Запуск $($sessions[0].Name): $skipped из $($parts.Count) частей журнала не вошли в отчёт (лимит $([int]($budget / 1MB)) МБ) и остались в папке logs.")
        }
    }
    # The last part of the two launches before it, the newest install and
    # launcher logs, and the newest frame-timing trace.
    foreach ($session in @($sessions | Select-Object -Skip 1 -First 2)) { $picked.Add($session.Parts[0].File) }
    $otherLogs = @(Get-ChildItem -LiteralPath $script:Layout.LogDir -File -Filter '*.log' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike 'cod3-launcher-*' -and $_.Length -le 32MB } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 3)
    foreach ($log in $otherLogs) { $picked.Add($log) }
    $timing = Get-ChildItem -LiteralPath $script:Layout.LogDir -File -Filter '*.ndjson' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $sessionStart = [DateTime]::MaxValue
    $parsed = [DateTime]::MinValue
    if ($sessions.Count -gt 0 -and
        [DateTime]::TryParseExact($sessions[0].Name.Substring('cod3-launcher-'.Length), 'yyyyMMdd-HHmmss',
            [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsed)) {
        $sessionStart = $parsed
    }
    if ($timing -and $timing.Length -le 64MB -and $timing.LastWriteTime -ge $sessionStart) { $picked.Add($timing) }

    foreach ($file in $picked) {
        try {
            Copy-SharedFile $file.FullName (Join-Path $stagingRoot $file.Name)
        } catch {
            $notes.Add("Не удалось скопировать $($file.Name): $($_.Exception.Message)")
        }
    }
    if ($notes.Count -gt 0) {
        Set-Content -LiteralPath (Join-Path $stagingRoot 'report-notes.txt') -Value $notes -Encoding UTF8
    }
    foreach ($extra in @((Join-Path $script:Layout.LogDir 'last-launch.json'), (Get-SettingsPath), $script:Layout.Receipt, $script:Layout.Manifest)) {
        if ($extra -and (Test-Path -LiteralPath $extra -PathType Leaf)) {
            Copy-Item -LiteralPath $extra -Destination $stagingRoot -Force
        }
    }

    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
    $gpus = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)
    $binaries = @(Get-ChildItem -LiteralPath $script:Layout.BinDir -Filter '*.dll' -ErrorAction SilentlyContinue) +
                @(Get-Item -LiteralPath $script:Layout.Exe)
    $smartAppControl = $null
    try {
        $smartAppControl = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -ErrorAction Stop).VerifiedAndReputablePolicyState
    } catch {
        $smartAppControl = $null
    }
    $system = [ordered]@{
        generated_local = (Get-Date).ToString('o')
        launcher_version = $script:LauncherVersion
        layout = $script:Layout.Kind
        os = if ($os) { "$($os.Caption) $($os.Version)" } else { 'unknown' }
        memory_gb = if ($os) { [math]::Round($os.TotalVisibleMemorySize / 1MB, 1) } else { 0 }
        cpu = if ($cpu) { $cpu.Name } else { 'unknown' }
        gpus = @($gpus | ForEach-Object {
            [ordered]@{ name = $_.Name; driver = $_.DriverVersion
                        mode = "$($_.CurrentHorizontalResolution)x$($_.CurrentVerticalResolution)@$($_.CurrentRefreshRate)" } })
        smart_app_control = $smartAppControl
        binaries = @($binaries | ForEach-Object {
            [ordered]@{ name = $_.Name; size = $_.Length
                        sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash } })
    }
    ($system | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath (Join-Path $stagingRoot 'system.json') -Encoding UTF8

    $destination = Join-Path ([Environment]::GetFolderPath('Desktop')) "cod3-report-$stamp.zip"
    if (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination -Force }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory($stagingRoot, $destination)
    Remove-Item -LiteralPath $stagingRoot -Recurse -Force
    return $destination
}

function Read-NewText([string]$Path, [ref]$Offset) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        if ($stream.Length -le $Offset.Value) { return '' }
        $stream.Position = $Offset.Value
        $buffer = New-Object byte[] ($stream.Length - $Offset.Value)
        $read = $stream.Read($buffer, 0, $buffer.Length)
        $Offset.Value = $Offset.Value + $read
        return [Text.Encoding]::UTF8.GetString($buffer, 0, $read)
    } finally {
        $stream.Dispose()
    }
}

# ------------------------------------------------------------------------- UI
#
# WPF: it ships with every Windows 10/11, so the launcher still needs nothing
# installed. The artwork is drawn by launcher/assets/build_art.py; without the
# files the window falls back to a plain dark background.

$script:DiscordUrl = 'https://discord.gg/7sGEwV3sB'
$script:DonateUrl = 'https://donatepay.ru/don/1456210'

$script:ThemeXaml = @'
<Geometry x:Key="IconChat">F0 M4,4 H20 A2,2 0 0 1 22,6 V16 A2,2 0 0 1 20,18 H10 L6,21.5 V18 H4 A2,2 0 0 1 2,16 V6 A2,2 0 0 1 4,4 Z M8,9.6 A1.4,1.4 0 1 0 8,12.4 A1.4,1.4 0 1 0 8,9.6 Z M12,9.6 A1.4,1.4 0 1 0 12,12.4 A1.4,1.4 0 1 0 12,9.6 Z M16,9.6 A1.4,1.4 0 1 0 16,12.4 A1.4,1.4 0 1 0 16,9.6 Z</Geometry>
<Geometry x:Key="IconHeart">M12,21.3 C11.6,21.3 3,15.4 3,9 C3,5.9 5.3,3.6 8.2,3.6 C9.9,3.6 11.3,4.5 12,5.8 C12.7,4.5 14.1,3.6 15.8,3.6 C18.7,3.6 21,5.9 21,9 C21,15.4 12.4,21.3 12,21.3 Z</Geometry>
<Geometry x:Key="IconPlay">M6,3 L21,12 L6,21 Z</Geometry>
<Geometry x:Key="IconDisc">F0 M12,1.5 A10.5,10.5 0 1 0 12,22.5 A10.5,10.5 0 1 0 12,1.5 Z M12,9 A3,3 0 1 1 12,15 A3,3 0 1 1 12,9 Z</Geometry>

<Style x:Key="Card" TargetType="Border">
  <Setter Property="Background" Value="#DB121315"/>
  <Setter Property="BorderBrush" Value="#22FFFFFF"/>
  <Setter Property="BorderThickness" Value="1"/>
  <Setter Property="CornerRadius" Value="12"/>
  <Setter Property="Padding" Value="26,22"/>
</Style>
<Style x:Key="Chip" TargetType="Border">
  <Setter Property="Background" Value="#1FE0A340"/>
  <Setter Property="BorderBrush" Value="#55E0A340"/>
  <Setter Property="BorderThickness" Value="1"/>
  <Setter Property="CornerRadius" Value="13"/>
  <Setter Property="Padding" Value="11,4"/>
  <Setter Property="Margin" Value="0,0,8,8"/>
</Style>
<Style x:Key="ChipText" TargetType="TextBlock">
  <Setter Property="Foreground" Value="#F6C165"/>
  <Setter Property="FontSize" Value="12.5"/>
  <Setter Property="FontWeight" Value="SemiBold"/>
</Style>
<Style x:Key="Section" TargetType="TextBlock">
  <Setter Property="FontFamily" Value="Bahnschrift"/>
  <Setter Property="FontWeight" Value="SemiBold"/>
  <Setter Property="FontSize" Value="13"/>
  <Setter Property="Foreground" Value="#E0A340"/>
  <Setter Property="Margin" Value="0,0,0,12"/>
</Style>
<Style x:Key="Label" TargetType="TextBlock">
  <Setter Property="FontSize" Value="13"/>
  <Setter Property="Foreground" Value="#D6CFC1"/>
  <Setter Property="Margin" Value="0,0,0,8"/>
</Style>
<Style x:Key="Hint" TargetType="TextBlock">
  <Setter Property="FontSize" Value="12"/>
  <Setter Property="Foreground" Value="#8E887D"/>
  <Setter Property="TextWrapping" Value="Wrap"/>
  <Setter Property="LineHeight" Value="17"/>
  <Setter Property="Margin" Value="0,2,0,12"/>
</Style>
<Style x:Key="Separator" TargetType="Rectangle">
  <Setter Property="Height" Value="1"/>
  <Setter Property="Fill" Value="#1CFFFFFF"/>
  <Setter Property="Margin" Value="0,10,0,16"/>
</Style>

<Style x:Key="GhostButton" TargetType="Button">
  <Setter Property="Foreground" Value="#EEE7D9"/>
  <Setter Property="Background" Value="#14FFFFFF"/>
  <Setter Property="BorderBrush" Value="#33FFFFFF"/>
  <Setter Property="Padding" Value="16,9"/>
  <Setter Property="FontSize" Value="13"/>
  <Setter Property="Cursor" Value="{DynamicResource LinkCursor}"/>
  <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="Button">
        <Border x:Name="B" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                BorderThickness="1" CornerRadius="6" Padding="{TemplateBinding Padding}">
          <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True">
            <Setter TargetName="B" Property="Background" Value="#26FFFFFF"/>
            <Setter TargetName="B" Property="BorderBrush" Value="#E0A340"/>
          </Trigger>
          <Trigger Property="IsPressed" Value="True">
            <Setter TargetName="B" Property="Background" Value="#08FFFFFF"/>
          </Trigger>
          <Trigger Property="IsEnabled" Value="False">
            <Setter Property="Opacity" Value="0.45"/>
          </Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>

<Style x:Key="BrandButton" TargetType="Button">
  <Setter Property="Foreground" Value="White"/>
  <Setter Property="Padding" Value="14,7"/>
  <Setter Property="FontSize" Value="13"/>
  <Setter Property="FontWeight" Value="SemiBold"/>
  <Setter Property="Cursor" Value="{DynamicResource LinkCursor}"/>
  <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="Button">
        <Grid>
          <Border CornerRadius="6" Background="{TemplateBinding Background}"/>
          <Border x:Name="H" CornerRadius="6" Background="White" Opacity="0"/>
          <ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Grid>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True">
            <Setter TargetName="H" Property="Opacity" Value="0.16"/>
          </Trigger>
          <Trigger Property="IsPressed" Value="True">
            <Setter TargetName="H" Property="Opacity" Value="0.04"/>
          </Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>

<Style x:Key="PlayButton" TargetType="Button">
  <Setter Property="Foreground" Value="#1B1307"/>
  <Setter Property="Cursor" Value="{DynamicResource LinkCursor}"/>
  <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="Button">
        <Grid>
          <Border x:Name="Glow" CornerRadius="8" Background="#E0A340" Opacity="0.4">
            <Border.Effect><BlurEffect Radius="26"/></Border.Effect>
          </Border>
          <Border x:Name="Face" CornerRadius="8" BorderThickness="1" BorderBrush="#FFE6B0">
            <Border.Background>
              <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                <GradientStop Color="#F8CA70" Offset="0"/>
                <GradientStop Color="#CF882A" Offset="1"/>
              </LinearGradientBrush>
            </Border.Background>
            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <Border x:Name="Shine" CornerRadius="8" Background="White" Opacity="0" IsHitTestVisible="False"/>
        </Grid>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True">
            <Setter TargetName="Shine" Property="Opacity" Value="0.16"/>
            <Setter TargetName="Glow" Property="Opacity" Value="0.7"/>
          </Trigger>
          <Trigger Property="IsPressed" Value="True">
            <Setter TargetName="Shine" Property="Opacity" Value="0"/>
            <Setter TargetName="Glow" Property="Opacity" Value="0.3"/>
          </Trigger>
          <Trigger Property="IsEnabled" Value="False">
            <Setter TargetName="Face" Property="Background" Value="#34322E"/>
            <Setter TargetName="Face" Property="BorderBrush" Value="#4A4740"/>
            <Setter TargetName="Glow" Property="Opacity" Value="0"/>
            <Setter Property="Foreground" Value="#8C867B"/>
          </Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>

<Style x:Key="WinButton" TargetType="Button">
  <Setter Property="Width" Value="46"/>
  <Setter Property="Height" Value="34"/>
  <Setter Property="Foreground" Value="#CFC8BA"/>
  <Setter Property="FontFamily" Value="Segoe Fluent Icons, Segoe MDL2 Assets"/>
  <Setter Property="FontSize" Value="10"/>
  <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="Button">
        <Border x:Name="B" Background="Transparent">
          <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True">
            <Setter TargetName="B" Property="Background" Value="#22FFFFFF"/>
          </Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
<Style x:Key="CloseButton" TargetType="Button" BasedOn="{StaticResource WinButton}">
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="Button">
        <Border x:Name="B" Background="Transparent">
          <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True">
            <Setter TargetName="B" Property="Background" Value="#C42B1C"/>
            <Setter Property="Foreground" Value="White"/>
          </Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>

<Style x:Key="NavTab" TargetType="RadioButton">
  <Setter Property="Foreground" Value="#A8A195"/>
  <Setter Property="FontFamily" Value="Bahnschrift"/>
  <Setter Property="FontWeight" Value="SemiBold"/>
  <Setter Property="FontSize" Value="14"/>
  <Setter Property="Margin" Value="0,0,28,0"/>
  <Setter Property="Cursor" Value="{DynamicResource LinkCursor}"/>
  <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="RadioButton">
        <Grid Background="Transparent">
          <ContentPresenter VerticalAlignment="Center" Margin="0,2,0,0"/>
          <Border x:Name="Bar" Height="2" VerticalAlignment="Bottom" Background="#E0A340" Opacity="0" Margin="0,0,0,11"/>
        </Grid>
        <ControlTemplate.Triggers>
          <Trigger Property="IsChecked" Value="True">
            <Setter TargetName="Bar" Property="Opacity" Value="1"/>
          </Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
  <Style.Triggers>
    <Trigger Property="IsMouseOver" Value="True">
      <Setter Property="Foreground" Value="#EEE7D9"/>
    </Trigger>
    <Trigger Property="IsChecked" Value="True">
      <Setter Property="Foreground" Value="#F6C165"/>
    </Trigger>
  </Style.Triggers>
</Style>

<Style x:Key="LangOption" TargetType="RadioButton">
  <Setter Property="GroupName" Value="Language"/>
  <Setter Property="Margin" Value="1,0,1,0"/>
  <Setter Property="Cursor" Value="{DynamicResource LinkCursor}"/>
  <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="RadioButton">
        <Border x:Name="B" Width="31" Height="25" CornerRadius="5" BorderThickness="1"
                BorderBrush="Transparent" Background="Transparent">
          <ContentPresenter x:Name="C" HorizontalAlignment="Center" VerticalAlignment="Center" Opacity="0.55"/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True">
            <Setter TargetName="C" Property="Opacity" Value="1"/>
            <Setter TargetName="B" Property="Background" Value="#18FFFFFF"/>
          </Trigger>
          <Trigger Property="IsChecked" Value="True">
            <Setter TargetName="C" Property="Opacity" Value="1"/>
            <Setter TargetName="B" Property="BorderBrush" Value="#E0A340"/>
            <Setter TargetName="B" Property="Background" Value="#2EE0A340"/>
          </Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
<Style x:Key="LangFlag" TargetType="Image">
  <Setter Property="Width" Value="21"/>
  <Setter Property="Height" Value="14"/>
  <Setter Property="RenderOptions.BitmapScalingMode" Value="HighQuality"/>
</Style>

<Style x:Key="Segment" TargetType="RadioButton">
  <Setter Property="Foreground" Value="#CFC8BA"/>
  <Setter Property="FontSize" Value="13"/>
  <Setter Property="Margin" Value="0,0,8,8"/>
  <Setter Property="Cursor" Value="{DynamicResource LinkCursor}"/>
  <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="RadioButton">
        <Border x:Name="B" CornerRadius="6" BorderThickness="1" BorderBrush="#2EFFFFFF" Background="#12FFFFFF" Padding="14,7">
          <ContentPresenter HorizontalAlignment="Center"/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True">
            <Setter TargetName="B" Property="BorderBrush" Value="#66FFFFFF"/>
          </Trigger>
          <Trigger Property="IsChecked" Value="True">
            <Setter TargetName="B" Property="BorderBrush" Value="#E0A340"/>
            <Setter TargetName="B" Property="Background" Value="#33E0A340"/>
            <Setter Property="Foreground" Value="#F6C165"/>
          </Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>

<Style x:Key="Switch" TargetType="CheckBox">
  <Setter Property="Foreground" Value="#EEE7D9"/>
  <Setter Property="FontSize" Value="13.5"/>
  <Setter Property="Margin" Value="0,5,0,5"/>
  <Setter Property="Cursor" Value="{DynamicResource LinkCursor}"/>
  <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="CheckBox">
        <Grid Background="Transparent">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>
          <Border x:Name="Track" Width="40" Height="22" CornerRadius="11" Background="#2EFFFFFF"
                  BorderBrush="#40FFFFFF" BorderThickness="1" VerticalAlignment="Center">
            <Ellipse x:Name="Knob" Width="14" Height="14" Fill="#CFC8BA" HorizontalAlignment="Left" Margin="4,0,0,0"/>
          </Border>
          <ContentPresenter Grid.Column="1" Margin="12,0,0,0" VerticalAlignment="Center"/>
        </Grid>
        <ControlTemplate.Triggers>
          <Trigger Property="IsChecked" Value="True">
            <Setter TargetName="Track" Property="Background" Value="#E0A340"/>
            <Setter TargetName="Track" Property="BorderBrush" Value="#F6C165"/>
            <Setter TargetName="Knob" Property="HorizontalAlignment" Value="Right"/>
            <Setter TargetName="Knob" Property="Margin" Value="0,0,4,0"/>
            <Setter TargetName="Knob" Property="Fill" Value="#1B1307"/>
          </Trigger>
          <Trigger Property="IsMouseOver" Value="True">
            <Setter TargetName="Track" Property="BorderBrush" Value="#99FFFFFF"/>
          </Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>

<Style TargetType="TextBox">
  <Setter Property="Foreground" Value="#EEE7D9"/>
  <Setter Property="Background" Value="#F00C0D0E"/>
  <Setter Property="BorderBrush" Value="#2EFFFFFF"/>
  <Setter Property="CaretBrush" Value="#F6C165"/>
  <Setter Property="SelectionBrush" Value="#E0A340"/>
  <Setter Property="Padding" Value="10,7"/>
  <Setter Property="FontSize" Value="13"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="TextBox">
        <Border x:Name="B" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                BorderThickness="1" CornerRadius="6">
          <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}" Focusable="False"/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True">
            <Setter TargetName="B" Property="BorderBrush" Value="#55FFFFFF"/>
          </Trigger>
          <Trigger Property="IsKeyboardFocused" Value="True">
            <Setter TargetName="B" Property="BorderBrush" Value="#E0A340"/>
          </Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>

<Style TargetType="ScrollBar">
  <Setter Property="Width" Value="8"/>
  <Setter Property="MinWidth" Value="8"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="ScrollBar">
        <Track x:Name="PART_Track" Orientation="Vertical" IsDirectionReversed="True">
          <Track.Thumb>
            <Thumb>
              <Thumb.Template>
                <ControlTemplate TargetType="Thumb">
                  <Border CornerRadius="4" Background="#44FFFFFF" Margin="1,2"/>
                </ControlTemplate>
              </Thumb.Template>
            </Thumb>
          </Track.Thumb>
        </Track>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
  <Style.Triggers>
    <Trigger Property="Orientation" Value="Horizontal">
      <Setter Property="Width" Value="Auto"/>
      <Setter Property="MinWidth" Value="0"/>
      <Setter Property="Height" Value="8"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Track x:Name="PART_Track" Orientation="Horizontal">
              <Track.Thumb>
                <Thumb>
                  <Thumb.Template>
                    <ControlTemplate TargetType="Thumb">
                      <Border CornerRadius="4" Background="#44FFFFFF" Margin="2,1"/>
                    </ControlTemplate>
                  </Thumb.Template>
                </Thumb>
              </Track.Thumb>
            </Track>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Trigger>
  </Style.Triggers>
</Style>

<Style x:Key="SliderFill" TargetType="RepeatButton">
  <Setter Property="Focusable" Value="False"/>
  <Setter Property="IsTabStop" Value="False"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="RepeatButton">
        <Grid Background="Transparent"><Border Height="4" CornerRadius="2" Background="#E0A340"/></Grid>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
<Style x:Key="SliderRest" TargetType="RepeatButton">
  <Setter Property="Focusable" Value="False"/>
  <Setter Property="IsTabStop" Value="False"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="RepeatButton">
        <Grid Background="Transparent"><Border Height="4" CornerRadius="2" Background="#2EFFFFFF"/></Grid>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
<Style TargetType="Slider">
  <Setter Property="Cursor" Value="{DynamicResource LinkCursor}"/>
  <Setter Property="IsMoveToPointEnabled" Value="True"/>
  <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="Slider">
        <Track x:Name="PART_Track" Height="26">
          <Track.DecreaseRepeatButton>
            <RepeatButton Style="{StaticResource SliderFill}" Command="Slider.DecreaseLarge"/>
          </Track.DecreaseRepeatButton>
          <Track.IncreaseRepeatButton>
            <RepeatButton Style="{StaticResource SliderRest}" Command="Slider.IncreaseLarge"/>
          </Track.IncreaseRepeatButton>
          <Track.Thumb>
            <Thumb>
              <Thumb.Template>
                <ControlTemplate TargetType="Thumb">
                  <Ellipse Width="18" Height="18" Fill="#F6C165" Stroke="#1B1307" StrokeThickness="2"/>
                </ControlTemplate>
              </Thumb.Template>
            </Thumb>
          </Track.Thumb>
        </Track>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>

<Style TargetType="ProgressBar">
  <Setter Property="Height" Value="6"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="ProgressBar">
        <Grid ClipToBounds="True">
          <Border Background="#22FFFFFF" CornerRadius="3"/>
          <Border x:Name="PART_Track"/>
          <Border x:Name="PART_Indicator" HorizontalAlignment="Left" Background="#E0A340" CornerRadius="3"/>
          <Border x:Name="Runner" Width="180" HorizontalAlignment="Left" CornerRadius="3" Visibility="Collapsed">
            <Border.Background>
              <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                <GradientStop Color="#00E0A340" Offset="0"/>
                <GradientStop Color="#FFF6C165" Offset="0.5"/>
                <GradientStop Color="#00E0A340" Offset="1"/>
              </LinearGradientBrush>
            </Border.Background>
            <Border.RenderTransform>
              <TranslateTransform x:Name="RunnerShift" X="-180"/>
            </Border.RenderTransform>
          </Border>
        </Grid>
        <ControlTemplate.Triggers>
          <Trigger Property="IsIndeterminate" Value="True">
            <Setter TargetName="PART_Indicator" Property="Visibility" Value="Collapsed"/>
            <Setter TargetName="Runner" Property="Visibility" Value="Visible"/>
            <Trigger.EnterActions>
              <BeginStoryboard x:Name="Run">
                <Storyboard RepeatBehavior="Forever">
                  <DoubleAnimation Storyboard.TargetName="RunnerShift" Storyboard.TargetProperty="X"
                                   From="-180" To="840" Duration="0:0:1.8"/>
                </Storyboard>
              </BeginStoryboard>
            </Trigger.EnterActions>
            <Trigger.ExitActions>
              <StopStoryboard BeginStoryboardName="Run"/>
            </Trigger.ExitActions>
          </Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
'@

$script:MainWindowXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Call of Duty 3 PC" Width="1180" Height="720"
        WindowStyle="None" ResizeMode="CanMinimize" WindowStartupLocation="CenterScreen"
        Background="#0B0C0B" UseLayoutRounding="True" AllowDrop="True">
  <Viewbox x:Name="Viewport" Stretch="Uniform">
    <Grid x:Name="Root" Width="1180" Height="720" Background="#0B0C0B" ClipToBounds="True" Cursor="{DynamicResource ArrowCursor}"
          TextElement.Foreground="#EEE7D9" TextElement.FontFamily="Segoe UI" TextElement.FontSize="13"
          TextOptions.TextFormattingMode="Ideal" SnapsToDevicePixels="True">
      <Grid.Resources>{{THEME}}</Grid.Resources>
      <Grid.RowDefinitions>
        <RowDefinition Height="58"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="106"/>
      </Grid.RowDefinitions>

      <Image x:Name="Hero" Grid.RowSpan="3" Stretch="UniformToFill"/>
      <Rectangle Grid.RowSpan="3" IsHitTestVisible="False">
        <Rectangle.Fill>
          <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
            <GradientStop Color="#F00B0C0B" Offset="0"/>
            <GradientStop Color="#A80B0C0B" Offset="0.42"/>
            <GradientStop Color="#100B0C0B" Offset="0.80"/>
          </LinearGradientBrush>
        </Rectangle.Fill>
      </Rectangle>
      <Rectangle Grid.RowSpan="3" IsHitTestVisible="False">
        <Rectangle.Fill>
          <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
            <GradientStop Color="#E60B0C0B" Offset="0"/>
            <GradientStop Color="#000B0C0B" Offset="0.15"/>
            <GradientStop Color="#000B0C0B" Offset="0.68"/>
            <GradientStop Color="#F50B0C0B" Offset="1"/>
          </LinearGradientBrush>
        </Rectangle.Fill>
      </Rectangle>

      <!-- Title bar -->
      <Grid x:Name="TitleBar" Background="Transparent">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Orientation="Horizontal" Margin="24,0,0,0" VerticalAlignment="Center">
          <Image x:Name="Emblem" Width="32" Height="32"/>
          <StackPanel Margin="11,0,0,0" VerticalAlignment="Center">
            <TextBlock Text="CALL OF DUTY 3" FontFamily="Bahnschrift" FontWeight="Bold" FontStretch="Condensed" FontSize="19"/>
            <TextBlock Text="НАТИВНЫЙ PC-ПОРТ" FontFamily="Bahnschrift" FontWeight="SemiBold" FontSize="9.5"
                       Foreground="#E0A340" Margin="1,-2,0,0"/>
          </StackPanel>
        </StackPanel>
        <StackPanel Grid.Column="1" Orientation="Horizontal" Margin="50,0,0,0">
          <RadioButton x:Name="NavHome" Style="{StaticResource NavTab}" Content="ГЛАВНАЯ" IsChecked="True"/>
          <RadioButton x:Name="NavVideo" Style="{StaticResource NavTab}" Content="ГРАФИКА"/>
          <RadioButton x:Name="NavControls" Style="{StaticResource NavTab}" Content="УПРАВЛЕНИЕ"/>
          <RadioButton x:Name="NavInstall" Style="{StaticResource NavTab}" Content="УСТАНОВКА"/>
        </StackPanel>
        <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center" Margin="0,0,16,0">
          <!-- Language: Russian is the text RU, the others are flags
               (launcher/assets/build_flags.py). Names in their own language. -->
          <StackPanel x:Name="LanguagePanel" Orientation="Horizontal" VerticalAlignment="Center" Margin="0,0,12,0">
            <RadioButton Style="{StaticResource LangOption}" Tag="ru" ToolTip="Русский">
              <TextBlock Text="RU" FontFamily="Bahnschrift" FontWeight="SemiBold" FontSize="12.5" Foreground="#EEE7D9"/>
            </RadioButton>
            <RadioButton Style="{StaticResource LangOption}" Tag="en" ToolTip="English"><Image x:Name="FlagEn" Style="{StaticResource LangFlag}"/></RadioButton>
            <RadioButton Style="{StaticResource LangOption}" Tag="uk" ToolTip="Українська"><Image x:Name="FlagUk" Style="{StaticResource LangFlag}"/></RadioButton>
            <RadioButton Style="{StaticResource LangOption}" Tag="be" ToolTip="Беларуская"><Image x:Name="FlagBe" Style="{StaticResource LangFlag}"/></RadioButton>
            <RadioButton Style="{StaticResource LangOption}" Tag="es" ToolTip="Español"><Image x:Name="FlagEs" Style="{StaticResource LangFlag}"/></RadioButton>
            <RadioButton Style="{StaticResource LangOption}" Tag="de" ToolTip="Deutsch"><Image x:Name="FlagDe" Style="{StaticResource LangFlag}"/></RadioButton>
          </StackPanel>
          <Button x:Name="TopDiscord" Style="{StaticResource BrandButton}" Background="#5865F2" ToolTip="Discord-сервер проекта">
            <StackPanel Orientation="Horizontal">
              <Path Data="{StaticResource IconChat}" Fill="White" Width="15" Height="15" Stretch="Uniform" VerticalAlignment="Center"/>
              <TextBlock Text="Discord" Margin="8,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
          </Button>
          <Button x:Name="TopDonate" Style="{StaticResource BrandButton}" Background="#E8672A" Margin="8,0,0,0"
                  ToolTip="Поддержать проект через DonatePay">
            <StackPanel Orientation="Horizontal">
              <Path Data="{StaticResource IconHeart}" Fill="White" Width="14" Height="14" Stretch="Uniform" VerticalAlignment="Center"/>
              <TextBlock Text="Поддержать" Margin="8,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
          </Button>
        </StackPanel>
        <StackPanel Grid.Column="3" Orientation="Horizontal" VerticalAlignment="Top">
          <Button x:Name="MinButton" Style="{StaticResource WinButton}" Content="&#xE921;" ToolTip="Свернуть"/>
          <Button x:Name="CloseButton" Style="{StaticResource CloseButton}" Content="&#xE8BB;" ToolTip="Закрыть"/>
        </StackPanel>
      </Grid>

      <!-- Pages -->
      <Grid Grid.Row="1" Margin="56,4,56,0">

        <Grid x:Name="PageHome">
          <StackPanel Width="600" HorizontalAlignment="Left" VerticalAlignment="Center">
            <TextBlock Text="НЕОФИЦИАЛЬНЫЙ ПОРТ  ·  XBOX 360 → WINDOWS" Foreground="#E0A340"
                       FontFamily="Bahnschrift" FontWeight="SemiBold" FontSize="13.5"/>
            <TextBlock Text="CALL OF DUTY 3" FontFamily="Bahnschrift" FontWeight="Bold" FontStretch="Condensed"
                       FontSize="88" Margin="-4,-4,0,-6">
              <TextBlock.Effect><DropShadowEffect BlurRadius="30" ShadowDepth="0" Opacity="0.75" Color="Black"/></TextBlock.Effect>
            </TextBlock>
            <TextBlock TextWrapping="Wrap" FontSize="15.5" Foreground="#C4BDB0" LineHeight="24"
                       Text="Кампания с Xbox 360, перекомпилированная в родной код Windows — без эмулятора. Высокое разрешение и 120 Гц, мышь с ощущением World at War и подсказки с клавишами вместо кнопок геймпада."/>
            <WrapPanel Margin="0,18,0,0">
              <Border Style="{StaticResource Chip}"><TextBlock Style="{StaticResource ChipText}" Text="до 2560 × 1440"/></Border>
              <Border Style="{StaticResource Chip}"><TextBlock Style="{StaticResource ChipText}" Text="120 Гц"/></Border>
              <Border Style="{StaticResource Chip}"><TextBlock Style="{StaticResource ChipText}" Text="мышь как в World at War"/></Border>
              <Border Style="{StaticResource Chip}"><TextBlock Style="{StaticResource ChipText}" Text="иконки клавиш и QTE"/></Border>
            </WrapPanel>
            <Grid Margin="0,24,0,0">
            <Border x:Name="SetupCard" Style="{StaticResource Card}" Padding="22,18" Visibility="Collapsed">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="Auto"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Border Width="44" Height="44" CornerRadius="22" Background="#2EE0A340" VerticalAlignment="Top">
                  <Path Data="{StaticResource IconDisc}" Fill="#F6C165" Width="24" Height="24" Stretch="Uniform"/>
                </Border>
                <StackPanel Grid.Column="1" Margin="16,0,0,0">
                  <TextBlock x:Name="SetupTitle" Text="Установка из образа диска" FontSize="16" FontWeight="SemiBold" TextWrapping="Wrap"/>
                  <TextBlock x:Name="SetupText" Style="{StaticResource Hint}" Margin="0,4,0,10"/>
                  <StackPanel x:Name="SetupIdle">
                    <Border CornerRadius="6" Background="#0FFFFFFF" BorderBrush="#26FFFFFF" BorderThickness="1" Padding="10,7">
                      <TextBlock x:Name="SetupIso" Foreground="#CFC8BA" TextTrimming="CharacterEllipsis"/>
                    </Border>
                    <CheckBox x:Name="SetupRecompile" Style="{StaticResource Switch}" Margin="0,10,0,0"
                              Content="Рекомпилировать игру на этом компьютере (около минуты)"/>
                  </StackPanel>
                  <StackPanel x:Name="SetupRunning" Visibility="Collapsed">
                    <Grid>
                      <TextBlock x:Name="JobStep" FontFamily="Bahnschrift" FontWeight="SemiBold" Foreground="#F6C165"
                                 TextTrimming="CharacterEllipsis" Margin="0,0,60,0"/>
                      <TextBlock x:Name="JobPercent" HorizontalAlignment="Right" Foreground="#CFC8BA"/>
                    </Grid>
                    <ProgressBar x:Name="JobProgress" Margin="0,8,0,8" Minimum="0" Maximum="100"/>
                    <TextBlock x:Name="JobLine" Foreground="#8E887D" FontFamily="Consolas" FontSize="11.5" TextTrimming="CharacterEllipsis"/>
                    <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
                      <Button x:Name="JobCancel" Style="{StaticResource GhostButton}" Padding="14,6" Content="Отменить"/>
                      <Button x:Name="JobShowLog" Style="{StaticResource GhostButton}" Padding="14,6" Margin="10,0,0,0" Content="Подробный журнал"/>
                    </StackPanel>
                  </StackPanel>
                </StackPanel>
              </Grid>
            </Border>
            <Grid x:Name="CommunityCards">
              <Grid.ColumnDefinitions>
                <ColumnDefinition/>
                <ColumnDefinition Width="14"/>
                <ColumnDefinition/>
              </Grid.ColumnDefinitions>
              <Border Style="{StaticResource Card}" Padding="20,18">
                <StackPanel>
                  <StackPanel Orientation="Horizontal">
                    <Border Width="40" Height="40" CornerRadius="10" Background="#5865F2">
                      <Path Data="{StaticResource IconChat}" Fill="White" Width="20" Height="20" Stretch="Uniform"/>
                    </Border>
                    <StackPanel Margin="12,0,0,0" VerticalAlignment="Center">
                      <TextBlock Text="Сообщество в Discord" FontSize="15" FontWeight="SemiBold"/>
                      <TextBlock Text="discord.gg/7sGEwV3sB" FontSize="11.5" Foreground="#8E887D"/>
                    </StackPanel>
                  </StackPanel>
                  <TextBlock Style="{StaticResource Hint}" Margin="0,12,0,14"
                             Text="Новости порта, помощь с установкой, сообщения об ошибках и набор тестеров."/>
                  <Button x:Name="HomeDiscord" Style="{StaticResource BrandButton}" Background="#5865F2"
                          HorizontalAlignment="Left" Content="Присоединиться"/>
                </StackPanel>
              </Border>
              <Border Grid.Column="2" Style="{StaticResource Card}" Padding="20,18">
                <StackPanel>
                  <StackPanel Orientation="Horizontal">
                    <Border Width="40" Height="40" CornerRadius="10" Background="#E8672A">
                      <Path Data="{StaticResource IconHeart}" Fill="White" Width="19" Height="19" Stretch="Uniform"/>
                    </Border>
                    <StackPanel Margin="12,0,0,0" VerticalAlignment="Center">
                      <TextBlock Text="Поддержать проект" FontSize="15" FontWeight="SemiBold"/>
                      <TextBlock Text="donatepay.ru" FontSize="11.5" Foreground="#8E887D"/>
                    </StackPanel>
                  </StackPanel>
                  <TextBlock Style="{StaticResource Hint}" Margin="0,12,0,14"
                             Text="Любая сумма помогает развивать порт: исправления, графика, управление."/>
                  <Button x:Name="HomeDonate" Style="{StaticResource BrandButton}" Background="#E8672A"
                          HorizontalAlignment="Left" Content="Поддержать"/>
                </StackPanel>
              </Border>
            </Grid>
            </Grid>
          </StackPanel>
        </Grid>

        <Grid x:Name="PageVideo" Visibility="Collapsed">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="580"/>
            <ColumnDefinition Width="16"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>
          <Border Style="{StaticResource Card}" VerticalAlignment="Top" Margin="0,16,0,0">
            <StackPanel>
              <TextBlock Style="{StaticResource Section}" Text="ИЗОБРАЖЕНИЕ"/>
              <TextBlock Style="{StaticResource Label}" Text="Режим вывода"/>
              <WrapPanel x:Name="OutputSegments">
                <RadioButton Style="{StaticResource Segment}" Tag="Окно 1280x720" Content="Окно 1280×720"/>
                <RadioButton Style="{StaticResource Segment}" Tag="Окно 1920x1080" Content="Окно 1920×1080"/>
                <RadioButton Style="{StaticResource Segment}" Tag="Окно 2560x1440" Content="Окно 2560×1440"/>
                <RadioButton Style="{StaticResource Segment}" Tag="Полный экран" Content="Полный экран"/>
              </WrapPanel>
              <Grid Margin="0,10,0,0">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="220"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <StackPanel>
                  <TextBlock Style="{StaticResource Label}" Text="Частота игры"/>
                  <WrapPanel x:Name="RefreshSegments">
                    <RadioButton Style="{StaticResource Segment}" Tag="60" Content="60 Гц"/>
                    <RadioButton Style="{StaticResource Segment}" Tag="120" Content="120 Гц"/>
                  </WrapPanel>
                </StackPanel>
                <StackPanel Grid.Column="1">
                  <TextBlock Style="{StaticResource Label}" Text="Масштаб рендера"/>
                  <WrapPanel x:Name="ScaleSegments">
                    <RadioButton Style="{StaticResource Segment}" Tag="1" Content="×1"/>
                    <RadioButton Style="{StaticResource Segment}" Tag="2" Content="×2"/>
                    <RadioButton Style="{StaticResource Segment}" Tag="3" Content="×3"/>
                  </WrapPanel>
                </StackPanel>
              </Grid>
              <TextBlock Style="{StaticResource Hint}"
                         Text="×3 — кадр 3120×1872, сжатый до окна: чётче и со сглаживанием. На 120 Гц вся игра идёт 120 кадров в секунду. Монитор 144–180 Гц: для ровных 120 включите G-Sync и полный экран."/>
              <CheckBox x:Name="VsyncSwitch" Style="{StaticResource Switch}" Content="Вертикальная синхронизация"/>
            </StackPanel>
          </Border>
          <Border Grid.Column="2" Style="{StaticResource Card}" VerticalAlignment="Top" Margin="0,16,0,0">
            <StackPanel>
              <TextBlock Style="{StaticResource Section}" Text="КУРСОР МЫШИ"/>
              <WrapPanel x:Name="CursorSegments">
                <RadioButton x:Name="CursorBrass" Style="{StaticResource Segment}" Tag="brass">
                  <StackPanel Orientation="Horizontal">
                    <Image x:Name="CursorBrassImage" Width="26" Height="26" Margin="-4,-3,6,-3"/>
                    <TextBlock Text="Латунь" VerticalAlignment="Center"/>
                  </StackPanel>
                </RadioButton>
                <RadioButton x:Name="CursorReticle" Style="{StaticResource Segment}" Tag="reticle">
                  <StackPanel Orientation="Horizontal">
                    <Image x:Name="CursorReticleImage" Width="26" Height="26" Margin="-4,-3,6,-3"/>
                    <TextBlock Text="Прицел" VerticalAlignment="Center"/>
                  </StackPanel>
                </RadioButton>
              </WrapPanel>
              <TextBlock Style="{StaticResource Hint}" Margin="0,0,0,4"
                         Text="Действует в лаунчере сразу, в окне игры — со следующего запуска."/>
              <Rectangle Style="{StaticResource Separator}"/>
              <TextBlock Style="{StaticResource Section}" Text="СОВМЕСТИМОСТЬ"/>
              <CheckBox x:Name="FoliageSwitch" Style="{StaticResource Switch}" Content="Убрать полосы вместо травы"/>
              <TextBlock Style="{StaticResource Hint}" Margin="52,0,0,4"
                         Text="Трава не рисуется. Без этого на части уровней видны вытянутые полосы."/>
              <Rectangle Style="{StaticResource Separator}"/>
              <TextBlock Style="{StaticResource Section}" Text="ДИАГНОСТИКА"/>
              <TextBlock Style="{StaticResource Label}" Text="Подробность журнала"/>
              <WrapPanel x:Name="LogSegments">
                <RadioButton Style="{StaticResource Segment}" Tag="info" Content="обычная"/>
                <RadioButton Style="{StaticResource Segment}" Tag="debug" Content="отладка"/>
                <RadioButton Style="{StaticResource Segment}" Tag="trace" Content="всё"/>
              </WrapPanel>
              <CheckBox x:Name="TraceSwitch" Style="{StaticResource Switch}" Margin="0,8,0,2" Content="Записывать трассу кадров"/>
              <CheckBox x:Name="FullDiagSwitch" Style="{StaticResource Switch}" Margin="0,2,0,2" Content="Полная диагностика"/>
              <TextBlock Style="{StaticResource Hint}" Margin="52,0,0,2"
                         Text="Всё подряд, с сообщениями самой игры (ИИ, скрипты, пути). Медленнее, журнал до 4 ГБ — только пока ловите ошибку."/>
              <CheckBox x:Name="KernelCallsSwitch" Style="{StaticResource Switch}" Margin="0,2,0,0"
                        Content="…и каждый вызов ядра (очень медленно)"/>
            </StackPanel>
          </Border>
        </Grid>

        <Grid x:Name="PageControls" Visibility="Collapsed">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="430"/>
            <ColumnDefinition Width="16"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>
          <Border Style="{StaticResource Card}" VerticalAlignment="Top" Margin="0,16,0,0">
            <StackPanel>
              <TextBlock Style="{StaticResource Section}" Text="УСТРОЙСТВО"/>
              <WrapPanel x:Name="InputSegments">
                <RadioButton Style="{StaticResource Segment}" Tag="Клавиатура и мышь" Content="Клавиатура и мышь"/>
                <RadioButton Style="{StaticResource Segment}" Tag="Геймпад" Content="Геймпад"/>
              </WrapPanel>
              <TextBlock Style="{StaticResource Hint}"
                         Text="С геймпадом слой клавиатуры и мыши выключается, а подсказки снова показывают кнопки Xbox."/>
              <Rectangle Style="{StaticResource Separator}" Margin="0,2,0,14"/>
              <TextBlock Style="{StaticResource Section}" Text="МЫШЬ  ·  ШКАЛА WORLD AT WAR"/>
              <Grid>
                <TextBlock Style="{StaticResource Label}" Text="Чувствительность" VerticalAlignment="Center"/>
                <TextBox x:Name="SensText" Width="72" HorizontalAlignment="Right" TextAlignment="Right" Padding="8,4"/>
              </Grid>
              <Slider x:Name="SensSlider" Minimum="0.1" Maximum="20" SmallChange="0.05" LargeChange="0.5" Margin="0,4,0,0"/>
              <TextBlock Style="{StaticResource Hint}"
                         Text="Как в World at War: по умолчанию 5. Поворот = отсчёты мыши × значение × 0,022°."/>
              <Grid>
                <TextBlock Style="{StaticResource Label}" Text="Множитель в прицеле" VerticalAlignment="Center"/>
                <TextBox x:Name="AdsText" Width="72" HorizontalAlignment="Right" TextAlignment="Right" Padding="8,4"/>
              </Grid>
              <Slider x:Name="AdsSlider" Minimum="0.25" Maximum="2" SmallChange="0.05" LargeChange="0.25" Margin="0,4,0,0"/>
              <TextBlock Style="{StaticResource Hint}"
                         Text="1,00 — как в WaW: в прицеле чувствительность и так снижается вместе с полем зрения."/>
              <CheckBox x:Name="InvertSwitch" Style="{StaticResource Switch}" Content="Инверсия по вертикали"/>
              <CheckBox x:Name="AdsToggleSwitch" Style="{StaticResource Switch}" Content="Прицеливание переключением, а не удержанием"/>
            </StackPanel>
          </Border>
          <Border Grid.Column="2" Style="{StaticResource Card}" VerticalAlignment="Top" Margin="0,16,0,0">
            <StackPanel>
              <TextBlock Style="{StaticResource Section}" Text="КЛАВИШИ"/>
              <UniformGrid x:Name="KeyMap" Columns="2"/>
              <TextBlock Style="{StaticResource Hint}" Margin="0,8,0,0"
                         Text="В меню игры работает мышь: наведение выделяет пункт, левая кнопка выбирает, правая — назад, колесо листает. Подсказки в игре, включая QTE, показывают эти же клавиши. Вращать в QTE (закладка заряда) можно мышью по кругу, колёсиком или WASD — в любую сторону. Подробнее — docs/controls.md."/>
            </StackPanel>
          </Border>
        </Grid>

        <Grid x:Name="PageInstall" Visibility="Collapsed">
          <Border Style="{StaticResource Card}" VerticalAlignment="Top" Margin="0,16,0,0">
            <StackPanel>
              <TextBlock Style="{StaticResource Section}" Text="ОБРАЗ ДИСКА, DEFAULT.XEX ИЛИ ПАКЕТ GOD"/>
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBox x:Name="IsoBox"/>
                <Button x:Name="IsoBrowse" Grid.Column="1" Style="{StaticResource GhostButton}" Margin="10,0,0,0" Content="Выбрать…"/>
              </Grid>
              <TextBlock Style="{StaticResource Hint}" Margin="0,6,0,6"
                         Text="Call of Duty 3 (USA, Europe) для Xbox 360: файл .iso, default.xex уже распакованной игры или пакет Games on Demand (папка 415607E1\00007000) — всё это можно просто перетащить в окно. Игра встанет в папку game\cod3 рядом с лаунчером. Код игры сверяется с диском побайтно; другая озвучка допускается."/>
              <CheckBox x:Name="RecompileSwitch" Style="{StaticResource Switch}" Content="Рекомпилировать игру на этом компьютере"/>
              <TextBlock Style="{StaticResource Hint}" Margin="52,0,0,10"
                         Text="Код игры переводится в C++ из вашей копии — около минуты, компилятор для этого не нужен. Если перевод совпал байт в байт с кодом, из которого собрана готовая сборка пакета, компилировать его заново незачем: результат был бы тем же. При отличиях, а также по кнопке «Пересобрать игру», игра компилируется полностью: 10–30 минут и один раз ~280 МБ компилятора Microsoft из интернета."/>
              <WrapPanel>
                <Button x:Name="InstallButton" Style="{StaticResource GhostButton}" Margin="0,0,10,0">
                  <StackPanel Orientation="Horizontal">
                    <TextBlock Text="&#xE896;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" Foreground="#F6C165" VerticalAlignment="Center"/>
                    <TextBlock Text="Установить и играть" Margin="9,0,0,0"/>
                  </StackPanel>
                </Button>
                <Button x:Name="RebuildButton" Style="{StaticResource GhostButton}" Margin="0,0,10,0">
                  <StackPanel Orientation="Horizontal">
                    <TextBlock Text="&#xE90F;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" Foreground="#F6C165" VerticalAlignment="Center"/>
                    <TextBlock Text="Пересобрать игру" Margin="9,0,0,0"/>
                  </StackPanel>
                </Button>
                <Button x:Name="VerifyButton" Style="{StaticResource GhostButton}" Margin="0,0,10,0">
                  <StackPanel Orientation="Horizontal">
                    <TextBlock Text="&#xE73E;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" Foreground="#F6C165" VerticalAlignment="Center"/>
                    <TextBlock Text="Проверить" Margin="9,0,0,0"/>
                  </StackPanel>
                </Button>
                <Button x:Name="LogsButton" Style="{StaticResource GhostButton}" Margin="0,0,10,0">
                  <StackPanel Orientation="Horizontal">
                    <TextBlock Text="&#xE8B7;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" Foreground="#F6C165" VerticalAlignment="Center"/>
                    <TextBlock Text="Папка журналов" Margin="9,0,0,0"/>
                  </StackPanel>
                </Button>
                <Button x:Name="ReportButton" Style="{StaticResource GhostButton}">
                  <StackPanel Orientation="Horizontal">
                    <TextBlock Text="&#xE9D9;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" Foreground="#F6C165" VerticalAlignment="Center"/>
                    <TextBlock Text="Отчёт об ошибке" Margin="9,0,0,0"/>
                  </StackPanel>
                </Button>
              </WrapPanel>
              <Rectangle Style="{StaticResource Separator}" Margin="0,14,0,14"/>
              <Grid>
                <TextBlock Style="{StaticResource Section}" Text="СОСТОЯНИЕ И ЖУРНАЛ"/>
                <TextBlock x:Name="GameDataText" HorizontalAlignment="Right" Foreground="#8E887D" FontSize="11.5"
                           TextTrimming="CharacterEllipsis" MaxWidth="700"/>
              </Grid>
              <TextBox x:Name="StatusBox" Height="178" IsReadOnly="True" FontFamily="Consolas" FontSize="12"
                       TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" Foreground="#CFC8BA"/>
            </StackPanel>
          </Border>
        </Grid>
      </Grid>

      <!-- Bottom bar -->
      <Grid Grid.Row="2" Margin="56,0,44,26">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel VerticalAlignment="Bottom">
          <StackPanel Orientation="Horizontal">
            <Ellipse x:Name="StatusDot" Width="10" Height="10" Fill="#E0A340" VerticalAlignment="Center">
              <Ellipse.Effect><DropShadowEffect x:Name="StatusGlow" BlurRadius="10" ShadowDepth="0" Opacity="0.9" Color="#E0A340"/></Ellipse.Effect>
            </Ellipse>
            <TextBlock x:Name="StatusTitle" Margin="11,0,0,0" FontFamily="Bahnschrift" FontWeight="SemiBold" FontSize="17"
                       Text="Проверка установки…"/>
          </StackPanel>
          <TextBlock x:Name="StatusDetail" Margin="21,3,0,0" Foreground="#A8A195" FontSize="12.5"
                     TextTrimming="CharacterEllipsis" MaxWidth="700" HorizontalAlignment="Left"/>
          <TextBlock x:Name="VersionText" Margin="21,10,0,0" Foreground="#6F6A61" FontSize="11"
                     TextTrimming="CharacterEllipsis" MaxWidth="720" HorizontalAlignment="Left"/>
        </StackPanel>
        <Button x:Name="PlayButton" Grid.Column="1" Style="{StaticResource PlayButton}" Width="300" Height="66" VerticalAlignment="Bottom">
          <StackPanel Orientation="Horizontal">
            <Path x:Name="PlayIcon" Data="{StaticResource IconPlay}" Width="18" Height="20" Stretch="Uniform" VerticalAlignment="Center"
                  Fill="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"/>
            <TextBlock x:Name="PlayText" Text="ИГРАТЬ" Margin="14,0,0,0" FontFamily="Bahnschrift" FontWeight="Bold"
                       FontStretch="Condensed" FontSize="29" VerticalAlignment="Center"/>
          </StackPanel>
        </Button>
      </Grid>

      <Border Grid.RowSpan="3" BorderBrush="#33E0A340" BorderThickness="1" IsHitTestVisible="False"/>
    </Grid>
  </Viewbox>
</Window>
'@


# Default key layout, as integration/pc-controls binds it. '*' marks a mouse
# button; the list mirrors docs/controls.md.
$script:KeyLayout = @(
    'W A S D|Движение', 'Shift|Бег, задержка дыхания',
    'Space|Прыжок', 'C|Присесть',
    'Ctrl Z|Лечь', 'R|Перезарядка',
    'F E|Взаимодействие', '1 2 *Колесо|Смена оружия',
    '*ЛКМ|Огонь', '*ПКМ|Прицеливание',
    'G|Осколочная граната', '4 *M5|Дымовая граната',
    'V *M4|Ближний бой', 'B *СКМ|Бинокль',
    'Tab|Задачи миссии', 'Esc|Пауза',
    '↑ ↓ *Колесо|Меню: выбор', 'Enter *ЛКМ|Меню: принять',
    'Backspace *ПКМ|Меню: назад', 'F4|Настройки ReXGlue',
    '*Круги *Колесо|Вращать в QTE', 'A D|Раскачать в QTE'
)

function ConvertTo-Brush([string]$Color) {
    return (New-Object System.Windows.Media.BrushConverter).ConvertFromString($Color)
}

function Import-LauncherXaml([string]$Xaml) {
    return [System.Windows.Markup.XamlReader]::Parse($Xaml.Replace('{{THEME}}', $script:ThemeXaml))
}

function Get-LauncherElements($Window, [string[]]$Names) {
    $elements = @{}
    foreach ($name in $Names) {
        $element = $Window.FindName($name)
        if ($null -eq $element) { throw "В разметке лаунчера нет элемента '$name'." }
        $elements[$name] = $element
    }
    return $elements
}

function Get-LauncherAsset([string]$Name) {
    $path = Join-Path $script:LauncherRoot ('assets\' + $Name)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try {
        $image = New-Object System.Windows.Media.Imaging.BitmapImage
        $image.BeginInit()
        $image.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $image.UriSource = New-Object System.Uri($path)
        $image.EndInit()
        $image.Freeze()
        return $image
    } catch {
        return $null
    }
}

function Set-LauncherArt($Elements, $Window) {
    $hero = Get-LauncherAsset 'hero.jpg'
    if ($hero) { $Elements.Hero.Source = $hero }
    $emblem = Get-LauncherAsset 'emblem.png'
    if ($emblem) {
        $Elements.Emblem.Source = $emblem
        # Started from Project1944.exe the window keeps that program's icon on
        # the taskbar; under powershell.exe it would otherwise show PowerShell's.
        if (-not (Get-Variable -Name 'Project1944Host' -Scope Global -ErrorAction SilentlyContinue)) {
            $Window.Icon = $emblem
        }
    }
}

function Get-CursorStyle([string]$Style) {
    # The two pointer styles drawn by launcher/assets/cursors/build_cursors.py.
    if ($Style -in @('brass', 'reticle')) { return $Style }
    return 'brass'
}

function Set-LauncherCursor($Root, [string]$Style) {
    # Styles pick the pointers up as DynamicResource, so this switches every
    # element at once. Missing files leave the Windows arrow and hand.
    $folder = Join-Path $script:LauncherRoot ('assets\cursors\' + (Get-CursorStyle $Style))
    $cursors = @{ ArrowCursor = [System.Windows.Input.Cursors]::Arrow; LinkCursor = [System.Windows.Input.Cursors]::Hand }
    foreach ($entry in @(@{ Key = 'ArrowCursor'; File = 'arrow.cur' }, @{ Key = 'LinkCursor'; File = 'link.cur' })) {
        $path = Join-Path $folder $entry.File
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        try {
            $stream = [IO.File]::OpenRead($path)
            try { $cursors[$entry.Key] = [System.Windows.Input.Cursor]::new($stream) } finally { $stream.Dispose() }
        } catch {
            Write-LauncherErrorLog $_
        }
    }
    # The bare .NET objects: a PowerShell wrapper is not a valid Cursor value.
    $Root.Resources['ArrowCursor'] = $cursors.ArrowCursor.psobject.BaseObject
    $Root.Resources['LinkCursor'] = $cursors.LinkCursor.psobject.BaseObject
}

function Set-WindowFit($Window, [double]$Width, [double]$Height) {
    # The layout is drawn for one size and scaled as a whole by the Viewbox,
    # so a 1080p screen at 150% (about 1280x670 usable) still fits it.
    $area = [System.Windows.SystemParameters]::WorkArea
    $scale = [Math]::Min(1.0, [Math]::Min(($area.Width * 0.96) / $Width, ($area.Height * 0.96) / $Height))
    $Window.Width = [Math]::Round($Width * $scale)
    $Window.Height = [Math]::Round($Height * $scale)
}

function Enable-WindowDrag($Window, $Handle) {
    $Handle.Add_MouseLeftButtonDown({
        param($eventSender, $eventArgs)
        try { $Window.DragMove() } catch { }
    }.GetNewClosure())
}

function Restore-FromStartupMinimize($Window) {
    # PLAY-COD3.cmd starts the launcher with "start /min" to keep the console
    # out of the way, and Windows applies that to the process's first window
    # too. Undo it for the launcher window.
    $Window.Add_ContentRendered({
        if ($Window.WindowState -eq [System.Windows.WindowState]::Minimized) {
            $Window.WindowState = [System.Windows.WindowState]::Normal
        }
        [void]$Window.Activate()
    }.GetNewClosure())
}

function Save-ElementImage($Element, [string]$Path, [double]$Width, [double]$Height) {
    $size = New-Object System.Windows.Size($Width, $Height)
    $Element.Measure($size)
    $Element.Arrange((New-Object System.Windows.Rect(0, 0, $Width, $Height)))
    $Element.UpdateLayout()
    $bitmap = New-Object System.Windows.Media.Imaging.RenderTargetBitmap([int]$Width, [int]$Height, 96, 96,
        [System.Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($Element)
    $encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream = [IO.File]::Create($Path)
    try { $encoder.Save($stream) } finally { $stream.Dispose() }
}

function Open-Link([string]$Url) {
    try {
        Start-Process $Url
    } catch {
        try { [System.Windows.Clipboard]::SetText($Url) } catch { }
        [void][System.Windows.MessageBox]::Show(
            (T 'Не удалось открыть браузер. Ссылка скопирована в буфер обмена:') + "`n$Url", 'Call of Duty 3 PC')
    }
}

function Write-LauncherErrorLog($Failure) {
    try {
        if (-not (Test-Path -LiteralPath $script:Layout.LogDir)) {
            New-Item -ItemType Directory -Path $script:Layout.LogDir -Force | Out-Null
        }
        ('[' + (Get-Date).ToString('o') + '] ' + ($Failure | Out-String)) |
            Add-Content -LiteralPath (Join-Path $script:Layout.LogDir 'launcher-error.log') -Encoding UTF8
    } catch {
    }
}

function New-KeyCap([string]$Key) {
    $mouse = $Key.StartsWith('*')
    $cap = New-Object System.Windows.Controls.Border
    $cap.CornerRadius = New-Object System.Windows.CornerRadius(4)
    $cap.BorderThickness = New-Object System.Windows.Thickness(1, 1, 1, 3)
    $cap.Padding = New-Object System.Windows.Thickness(7, 1, 7, 1)
    $cap.Margin = New-Object System.Windows.Thickness(0, 0, 4, 0)
    $cap.MinWidth = 24
    $label = New-Object System.Windows.Controls.TextBlock
    $label.Text = $Key.TrimStart('*')
    $label.FontFamily = New-Object System.Windows.Media.FontFamily('Bahnschrift')
    $label.FontWeight = [System.Windows.FontWeights]::SemiBold
    $label.FontSize = 12
    $label.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
    if ($mouse) {
        $cap.Background = ConvertTo-Brush '#3A2E1A'
        $cap.BorderBrush = ConvertTo-Brush '#8A6428'
        $label.Foreground = ConvertTo-Brush '#F6C165'
    } else {
        $cap.Background = ConvertTo-Brush '#2A2C2E'
        $cap.BorderBrush = ConvertTo-Brush '#595D61'
        $label.Foreground = ConvertTo-Brush '#F2EAD8'
    }
    $cap.Child = $label
    return $cap
}

function Add-KeyLayout($Panel) {
    foreach ($row in $script:KeyLayout) {
        $parts = $row.Split('|')
        $line = New-Object System.Windows.Controls.DockPanel
        $line.Margin = New-Object System.Windows.Thickness(0, 0, 14, 9)
        $caps = New-Object System.Windows.Controls.StackPanel
        $caps.Orientation = [System.Windows.Controls.Orientation]::Horizontal
        # A minimum rather than a fixed width: "Backspace" plus a mouse
        # button is wider, and would otherwise run into the label.
        $caps.MinWidth = 118
        foreach ($key in $parts[0].Split(' ')) { [void]$caps.Children.Add((New-KeyCap $key)) }
        [void]$line.Children.Add($caps)
        $label = New-Object System.Windows.Controls.TextBlock
        $label.Text = $parts[1]
        $label.FontSize = 12.5
        $label.Foreground = ConvertTo-Brush '#D6CFC1'
        $label.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        $label.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
        $label.ToolTip = $parts[1]
        [void]$line.Children.Add($label)
        [void]$Panel.Children.Add($line)
    }
}

function Test-HasCyrillic([string]$Text) {
    return (-not [string]::IsNullOrEmpty($Text)) -and ($Text -match '[\u0400-\u04FF]')
}

function Find-TranslatableText($Node, $Items, [string[]]$Skip) {
    # Every Russian text in the window with the element and property holding
    # it: TextBlock text, string content of buttons, switches and segments,
    # and string tooltips. Named elements the code fills in are skipped, as
    # is everything inside them.
    if ($Node -isnot [System.Windows.DependencyObject]) { return }
    if ($Node -is [System.Windows.FrameworkElement] -and $Node.Name -and $Skip -contains $Node.Name) { return }
    if ($Node -is [System.Windows.Controls.TextBlock]) {
        if (Test-HasCyrillic $Node.Text) { $Items.Add(@{ Element = $Node; Property = 'Text'; Text = $Node.Text }) }
    } elseif ($Node -is [System.Windows.Controls.ContentControl] -and $Node.Content -is [string]) {
        if (Test-HasCyrillic $Node.Content) { $Items.Add(@{ Element = $Node; Property = 'Content'; Text = [string]$Node.Content }) }
    }
    if ($Node -is [System.Windows.FrameworkElement] -and $Node.ToolTip -is [string] -and (Test-HasCyrillic $Node.ToolTip)) {
        $Items.Add(@{ Element = $Node; Property = 'ToolTip'; Text = [string]$Node.ToolTip })
    }
    if ($Node -is [System.Windows.Controls.TextBlock]) { return }
    foreach ($child in @([System.Windows.LogicalTreeHelper]::GetChildren($Node))) {
        Find-TranslatableText $child $Items $Skip
    }
}

function Set-TranslatedText($Items) {
    foreach ($item in $Items) { $item.Element.($item.Property) = (T $item.Text) }
}

function Set-Segment($Panel, [string]$Value) {
    $buttons = @($Panel.Children | Where-Object { $_ -is [System.Windows.Controls.RadioButton] })
    $match = @($buttons | Where-Object { [string]$_.Tag -eq $Value })
    if ($match.Count -gt 0) { $match[0].IsChecked = $true } elseif ($buttons.Count -gt 0) { $buttons[0].IsChecked = $true }
}

function Get-Segment($Panel) {
    foreach ($button in $Panel.Children) {
        if ($button -is [System.Windows.Controls.RadioButton] -and $button.IsChecked) { return [string]$button.Tag }
    }
    return $null
}

function Remove-AnsiEscapes([string]$Text) {
    # PowerShell 7 colours its error records even when the output goes to a
    # file; the codes are noise in a text box.
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    return [regex]::Replace($Text, "\x1B\[[0-9;?]*[ -/]*[@-~]", '')
}

function Stop-ProcessTree([int]$Id) {
    # The install runs as cmd -> pwsh -> step scripts -> compilers; killing
    # only the top process would leave the build running.
    try { & "$env:SystemRoot\System32\taskkill.exe" /PID $Id /T /F 2>$null | Out-Null } catch { }
}

function Show-Launcher([string]$PreviewDirectory = '') {
    $window = Import-LauncherXaml $script:MainWindowXaml
    $ui = Get-LauncherElements $window @('Viewport', 'Root', 'Hero', 'Emblem', 'TitleBar',
        'NavHome', 'NavVideo', 'NavControls', 'NavInstall', 'PageHome', 'PageVideo', 'PageControls', 'PageInstall',
        'TopDiscord', 'TopDonate', 'HomeDiscord', 'HomeDonate', 'MinButton', 'CloseButton',
        'SetupCard', 'SetupTitle', 'SetupText', 'SetupIdle', 'SetupIso', 'SetupRecompile', 'SetupRunning',
        'JobStep', 'JobPercent', 'JobProgress', 'JobLine', 'JobCancel', 'JobShowLog', 'CommunityCards',
        'OutputSegments', 'RefreshSegments', 'ScaleSegments', 'VsyncSwitch', 'FoliageSwitch', 'LogSegments', 'TraceSwitch',
        'FullDiagSwitch', 'KernelCallsSwitch',
        'InputSegments', 'SensSlider', 'SensText', 'AdsSlider', 'AdsText', 'InvertSwitch', 'AdsToggleSwitch', 'KeyMap',
        'IsoBox', 'IsoBrowse', 'RecompileSwitch', 'InstallButton', 'RebuildButton', 'VerifyButton', 'LogsButton',
        'ReportButton', 'GameDataText', 'StatusBox', 'CursorSegments', 'CursorBrassImage', 'CursorReticleImage',
        'StatusDot', 'StatusGlow', 'StatusTitle', 'StatusDetail', 'VersionText', 'PlayButton', 'PlayIcon', 'PlayText',
        'LanguagePanel', 'FlagEn', 'FlagUk', 'FlagBe', 'FlagEs', 'FlagDe')
    Set-LauncherArt $ui $window
    Set-LauncherCursor $ui.Root ([string]$script:Settings.Cursor)
    Set-WindowFit $window 1180 720
    Enable-WindowDrag $window $ui.TitleBar
    Restore-FromStartupMinimize $window
    Add-KeyLayout $ui.KeyMap

    # ---- language: every Russian text of the window, remembered once so a
    # switch can translate it in place, without restarting the launcher.
    $texts = New-Object System.Collections.Generic.List[object]
    Find-TranslatableText $window $texts @('LanguagePanel', 'SetupTitle', 'SetupText', 'SetupIso', 'JobStep',
        'JobPercent', 'JobLine', 'GameDataText', 'StatusTitle', 'StatusDetail', 'VersionText', 'PlayText')
    Set-TranslatedText $texts
    foreach ($flag in @(@{ Image = $ui.FlagEn; Code = 'en' }, @{ Image = $ui.FlagUk; Code = 'uk' },
                        @{ Image = $ui.FlagBe; Code = 'be' }, @{ Image = $ui.FlagEs; Code = 'es' },
                        @{ Image = $ui.FlagDe; Code = 'de' })) {
        $source = Get-LauncherAsset "flag-$($flag.Code).png"
        # Without the picture the button still says which language it is.
        if ($source) { $flag.Image.Source = $source } else { $flag.Image.Parent.Content = $flag.Code.ToUpperInvariant() }
    }
    Set-Segment $ui.LanguagePanel $script:Language

    $pages = [ordered]@{ NavHome = 'PageHome'; NavVideo = 'PageVideo'; NavControls = 'PageControls'; NavInstall = 'PageInstall' }
    function Show-Page([string]$Nav) {
        foreach ($key in $pages.Keys) {
            $ui[$pages[$key]].Visibility = if ($key -eq $Nav) { 'Visible' } else { 'Collapsed' }
        }
        $ui[$Nav].IsChecked = $true
    }
    foreach ($key in @($pages.Keys)) {
        $ui[$key].Add_Checked({ Show-Page $this.Name })
    }

    # ---- settings -> controls
    $settings = $script:Settings
    $culture = [Globalization.CultureInfo]::InvariantCulture
    Set-Segment $ui.OutputSegments ([string]$settings.OutputMode)
    Set-Segment $ui.RefreshSegments ([string]$settings.RefreshRate)
    Set-Segment $ui.ScaleSegments ([string]$settings.RenderScale)
    Set-Segment $ui.LogSegments ([string]$settings.LogLevel)
    Set-Segment $ui.InputSegments ([string]$settings.InputMode)
    Set-Segment $ui.CursorSegments (Get-CursorStyle ([string]$settings.Cursor))
    $ui.CursorBrassImage.Source = Get-LauncherAsset 'cursors\brass\arrow.png'
    $ui.CursorReticleImage.Source = Get-LauncherAsset 'cursors\reticle\arrow.png'
    $ui.VsyncSwitch.IsChecked = [bool]$settings.Vsync
    $ui.FoliageSwitch.IsChecked = [bool]$settings.NoFoliage
    $ui.TraceSwitch.IsChecked = [bool]$settings.TimingTrace
    $ui.FullDiagSwitch.IsChecked = [bool]$settings.FullDiagnostics
    $ui.KernelCallsSwitch.IsChecked = [bool]$settings.KernelCallLog
    # Full diagnostics already logs everything and records the frame trace, so
    # those two controls stand aside; kernel calls only make sense on top.
    function Sync-Diagnostics {
        $full = [bool]$ui.FullDiagSwitch.IsChecked
        $ui.LogSegments.IsEnabled = -not $full
        $ui.TraceSwitch.IsEnabled = -not $full
        $ui.KernelCallsSwitch.IsEnabled = $full
        foreach ($control in @($ui.LogSegments, $ui.TraceSwitch, $ui.KernelCallsSwitch)) {
            $control.Opacity = if ($control.IsEnabled) { 1.0 } else { 0.45 }
        }
    }
    Sync-Diagnostics
    $ui.FullDiagSwitch.Add_Checked({ Sync-Diagnostics })
    $ui.FullDiagSwitch.Add_Unchecked({ Sync-Diagnostics })
    $ui.InvertSwitch.IsChecked = [bool]$settings.MouseInvert
    $ui.AdsToggleSwitch.IsChecked = [bool]$settings.AdsToggle
    $ui.IsoBox.Text = [string]$settings.IsoPath
    $ui.RecompileSwitch.IsChecked = [bool]$settings.Recompile
    $ui.SetupRecompile.IsChecked = [bool]$settings.Recompile
    function Set-VersionText {
        $ui.VersionText.Text = (T 'Лаунчер {0}  ·  неофициальный фанатский проект, не связан с Activision и Treyarch. Нужна ваша собственная копия игры.') -f $script:LauncherVersion
    }
    Set-VersionText

    # Mouse values: the slider covers the everyday range, the box beside it
    # accepts the full range the PC layer allows (0.1-40 and 0.1-3).
    $mouse = @{ Sens = 5.0; Ads = 1.0; Syncing = $false }
    try { $mouse.Sens = [double]$settings.MouseSensitivity } catch { $mouse.Sens = 5.0 }
    try { $mouse.Ads = [double]$settings.AdsMultiplier } catch { $mouse.Ads = 1.0 }
    function Get-Clamped([double]$Value, [double]$Low, [double]$High) { return [Math]::Min($High, [Math]::Max($Low, $Value)) }
    function Sync-Mouse {
        $mouse.Syncing = $true
        $ui.SensSlider.Value = Get-Clamped $mouse.Sens $ui.SensSlider.Minimum $ui.SensSlider.Maximum
        $ui.SensText.Text = $mouse.Sens.ToString('0.00', $culture)
        $ui.AdsSlider.Value = Get-Clamped $mouse.Ads $ui.AdsSlider.Minimum $ui.AdsSlider.Maximum
        $ui.AdsText.Text = $mouse.Ads.ToString('0.00', $culture)
        $mouse.Syncing = $false
    }
    function Read-MouseText {
        $value = 0.0
        if ([double]::TryParse($ui.SensText.Text.Trim().Replace(',', '.'), [Globalization.NumberStyles]::Float, $culture, [ref]$value)) {
            $mouse.Sens = Get-Clamped ([Math]::Round($value, 2)) 0.1 40
        }
        if ([double]::TryParse($ui.AdsText.Text.Trim().Replace(',', '.'), [Globalization.NumberStyles]::Float, $culture, [ref]$value)) {
            $mouse.Ads = Get-Clamped ([Math]::Round($value, 2)) 0.1 3
        }
        Sync-Mouse
    }
    $mouse.Sens = Get-Clamped $mouse.Sens 0.1 40
    $mouse.Ads = Get-Clamped $mouse.Ads 0.1 3
    Sync-Mouse
    $ui.SensSlider.Add_ValueChanged({
        if ($mouse.Syncing) { return }
        $mouse.Sens = [Math]::Round($ui.SensSlider.Value / 0.05) * 0.05
        $ui.SensText.Text = $mouse.Sens.ToString('0.00', $culture)
    })
    $ui.AdsSlider.Add_ValueChanged({
        if ($mouse.Syncing) { return }
        $mouse.Ads = [Math]::Round($ui.AdsSlider.Value / 0.05) * 0.05
        $ui.AdsText.Text = $mouse.Ads.ToString('0.00', $culture)
    })
    foreach ($box in @($ui.SensText, $ui.AdsText)) {
        $box.Add_LostFocus({ Read-MouseText })
        $box.Add_KeyDown({
            param($eventSender, $eventArgs)
            if ($eventArgs.Key -eq [System.Windows.Input.Key]::Return) { Read-MouseText; $eventArgs.Handled = $true }
        })
    }

    function Read-Form {
        # Start from the saved settings so fields the window does not show
        # (GameData, RebuildPending) survive every save.
        Read-MouseText
        $result = [ordered]@{}
        foreach ($key in @($script:Settings.Keys)) { $result[$key] = $script:Settings[$key] }
        $result.IsoPath = $ui.IsoBox.Text.Trim()
        $result.Recompile = [bool]$ui.RecompileSwitch.IsChecked
        $result.OutputMode = Get-Segment $ui.OutputSegments
        $result.RenderScale = [int](Get-Segment $ui.ScaleSegments)
        $result.RefreshRate = [int](Get-Segment $ui.RefreshSegments)
        $result.Vsync = [bool]$ui.VsyncSwitch.IsChecked
        $result.InputMode = Get-Segment $ui.InputSegments
        $result.MouseSensitivity = [double]$mouse.Sens
        $result.MouseInvert = [bool]$ui.InvertSwitch.IsChecked
        $result.AdsToggle = [bool]$ui.AdsToggleSwitch.IsChecked
        $result.AdsMultiplier = [double]$mouse.Ads
        $result.NoFoliage = [bool]$ui.FoliageSwitch.IsChecked
        $result.LogLevel = Get-Segment $ui.LogSegments
        $result.TimingTrace = [bool]$ui.TraceSwitch.IsChecked
        $result.FullDiagnostics = [bool]$ui.FullDiagSwitch.IsChecked
        $result.KernelCallLog = [bool]$ui.KernelCallsSwitch.IsChecked
        $result.Cursor = Get-CursorStyle (Get-Segment $ui.CursorSegments)
        $script:Settings = $result
        return $result
    }

    # ---- status
    $job = @{ Process = $null; OutFile = ''; Offset = [long]0; Started = $null; Running = $false; Recompile = $false
              LaunchAfter = $true; Step = 0; Total = 0; StepName = ''; Fraction = 0.0; LastLine = ''; Partial = ''
              Cancelled = $false }
    $game = @{ Process = $null }

    function Write-Status([string]$Text) {
        $ui.StatusBox.Text = $Text
        $ui.StatusBox.ScrollToHome()
    }
    function Set-Banner([string]$Kind, [string]$Title, [string]$Detail) {
        $color = switch ($Kind) { 'ok' { '#8BC34A' } 'busy' { '#6FA8DC' } 'error' { '#E0584A' } default { '#E0A340' } }
        $ui.StatusDot.Fill = ConvertTo-Brush $color
        $ui.StatusGlow.Color = [System.Windows.Media.ColorConverter]::ConvertFromString($color)
        $ui.StatusTitle.Text = $Title
        $ui.StatusDetail.Text = $Detail
    }
    function Show-Failure($Failure, [string]$Title) {
        Write-LauncherErrorLog $Failure
        $message = if ($Failure -is [System.Management.Automation.ErrorRecord]) { $Failure.Exception.Message } else { [string]$Failure.Message }
        Set-Banner 'error' $Title $message
        Write-Status ($Title + [Environment]::NewLine + [Environment]::NewLine + $message)
    }
    $window.Dispatcher.Add_UnhandledException({
        param($eventSender, $eventArgs)
        Show-Failure $eventArgs.Exception (T 'Ошибка лаунчера')
        $eventArgs.Handled = $true
    })

    function Get-IsoLabel {
        $iso = $ui.IsoBox.Text.Trim()
        if (-not $iso) { return (T 'Ничего не выбрано — нажмите «Выбрать образ» внизу или перетащите в это окно .iso, default.xex, папку с игрой или пакет GOD.') }
        $source = Get-InstallSource $iso
        if ($source.Kind -eq 'god') {
            return ((T '{0}  ·  пакет Games on Demand (GOD)') -f (Split-Path -Parent $source.God.Header))
        }
        if ($source.Kind -eq 'folder') {
            $xex = Join-Path $source.Path 'default.xex'
            if (-not (Test-Path -LiteralPath $xex -PathType Leaf)) { return ((T 'Файл не найден: {0}') -f $xex) }
            return ((T '{0}  ·  распакованная игра') -f $source.Path)
        }
        if (-not (Test-Path -LiteralPath $iso -PathType Leaf)) { return ((T 'Файл не найден: {0}') -f $iso) }
        $size = (Get-Item -LiteralPath $iso).Length / 1GB
        return ((T '{0}  ·  {1:n1} ГБ') -f [IO.Path]::GetFileName($iso), $size)
    }

    function Get-PrimaryState {
        if ($job.Running) { return 'running' }
        if ($game.Process) { return 'playing' }
        if (-not (Test-GameData (Resolve-GameDataPath)).Ok) {
            # A disc image, the default.xex (or folder) of an unpacked game, or
            # a Games on Demand package.
            $iso = $ui.IsoBox.Text.Trim()
            if ($iso -and (Test-Path -LiteralPath $iso)) { return 'install' }
            return 'choose'
        }
        $recompile = [bool]$ui.RecompileSwitch.IsChecked
        if ($recompile -and [bool]$script:Settings.RebuildPending) { return 'build' }
        if (-not (Test-Path -LiteralPath $script:Layout.Exe -PathType Leaf)) { return 'build' }
        return 'play'
    }

    function Set-PlayText([string]$Text) {
        # The big button is 300 wide. At 23 the longest label of any language
        # ("INSTALLIEREN UND SPIELEN") measures about 200 plus the icon.
        $ui.PlayText.Text = $Text
        $ui.PlayText.FontSize = if ($Text.Length -gt 12) { 23 } else { 29 }
    }

    function Update-PrimaryAction {
        # One button walks the player through: pick the image, install (and
        # recompile), play. The home card explains the current step.
        $state = Get-PrimaryState
        $recompile = [bool]$ui.RecompileSwitch.IsChecked
        $labels = @{ choose = 'ВЫБРАТЬ ОБРАЗ'; install = 'УСТАНОВИТЬ И ИГРАТЬ'; build = 'СОБРАТЬ И ИГРАТЬ'
                     play = 'ИГРАТЬ'; running = 'УСТАНОВКА…'; playing = 'ИГРА ЗАПУЩЕНА' }
        Set-PlayText (T $labels[$state])
        $ui.PlayIcon.Data = $ui.Root.FindResource($(if ($state -eq 'choose') { 'IconDisc' } else { 'IconPlay' }))
        $ui.PlayButton.IsEnabled = $state -notin @('running', 'playing')
        $ui.InstallButton.IsEnabled = -not $job.Running
        $ui.RebuildButton.IsEnabled = -not $job.Running
        $ui.IsoBrowse.IsEnabled = -not $job.Running
        $ui.RecompileSwitch.IsEnabled = -not $job.Running
        $ui.GameDataText.Text = (T 'Игра: {0}') -f (Resolve-GameDataPath)

        $setup = $state -in @('choose', 'install', 'build', 'running')
        $ui.SetupCard.Visibility = if ($setup) { 'Visible' } else { 'Collapsed' }
        $ui.CommunityCards.Visibility = if ($setup) { 'Collapsed' } else { 'Visible' }
        $ui.SetupRunning.Visibility = if ($state -eq 'running') { 'Visible' } else { 'Collapsed' }
        $ui.SetupIdle.Visibility = if ($state -eq 'running') { 'Collapsed' } else { 'Visible' }
        $ui.SetupIso.Text = Get-IsoLabel
        $sourceKind = Get-InstallSourceKind $ui.IsoBox.Text.Trim()
        # Whole sentences per case: word order differs between the languages.
        switch ($state) {
            'choose' {
                $ui.SetupTitle.Text = T 'Установка из образа диска'
                $ui.SetupText.Text = if ($recompile) {
                    T 'Выберите образ Call of Duty 3 (.iso), default.xex уже распакованной игры или пакет GOD (можно перетащить в окно), затем нажмите «Установить и играть». Лаунчер сам поставит игру, пересоберёт её на этом компьютере и запустит.'
                } else {
                    T 'Выберите образ Call of Duty 3 (.iso), default.xex уже распакованной игры или пакет GOD (можно перетащить в окно), затем нажмите «Установить и играть». Лаунчер сам поставит игру и запустит её.'
                }
            }
            'install' {
                if ($sourceKind -eq 'god') {
                    $ui.SetupTitle.Text = T 'Пакет GOD выбран — осталось нажать «Установить и играть»'
                    $ui.SetupText.Text = if ($recompile) {
                        T 'Дальше всё автоматически: лаунчер извлечёт игру из пакета GOD в game\cod3, проверит каждый файл, пересоберёт игру на этом компьютере и запустит её. Окно можно свернуть.'
                    } else {
                        T 'Дальше всё автоматически: лаунчер извлечёт игру из пакета GOD в game\cod3, проверит каждый файл и запустит игру. Окно можно свернуть.'
                    }
                } elseif ($sourceKind -eq 'folder') {
                    $ui.SetupTitle.Text = T 'Папка с игрой выбрана — осталось нажать «Установить и играть»'
                    $ui.SetupText.Text = if ($recompile) {
                        T 'Дальше всё автоматически: лаунчер скопирует игру в game\cod3, проверит каждый файл, пересоберёт игру на этом компьютере и запустит её. Окно можно свернуть.'
                    } else {
                        T 'Дальше всё автоматически: лаунчер скопирует игру в game\cod3, проверит каждый файл и запустит игру. Окно можно свернуть.'
                    }
                } else {
                    $ui.SetupTitle.Text = T 'Образ выбран — осталось нажать «Установить и играть»'
                    $ui.SetupText.Text = if ($recompile) {
                        T 'Дальше всё автоматически: лаунчер распакует образ, пересоберёт игру на этом компьютере и запустит её. Окно можно свернуть.'
                    } else {
                        T 'Дальше всё автоматически: лаунчер распакует образ и запустит игру. Окно можно свернуть.'
                    }
                }
            }
            'build' {
                $ui.SetupTitle.Text = T 'Игра распакована, осталась сборка'
                $ui.SetupText.Text = T 'Нажмите «Собрать и играть»: код игры перекомпилируется из вашей копии (обычно около минуты), затем игра запустится сама. Чтобы играть сразу готовой сборкой, выключите переключатель ниже.'
            }
            'running' {
                $ui.SetupTitle.Text = if ($job.Recompile) { T 'Идёт установка и пересборка' } else { T 'Идёт установка' }
                $ui.SetupText.Text = T 'Окно можно свернуть: когда всё будет готово, игра запустится сама.'
            }
        }
        return $state
    }

    function Update-Readiness {
        $check = Test-Installation (Resolve-GameDataPath)
        if (-not $job.Running) { Write-Status $check.Text }
        $state = Update-PrimaryAction
        switch ($state) {
            'choose'  { Set-Banner 'warn' (T 'Игра не установлена') (T 'Выберите образ диска, default.xex или пакет GOD — дальше всё автоматически.') }
            'install' {
                $title = switch (Get-InstallSourceKind $ui.IsoBox.Text.Trim()) {
                    'god' { T 'Пакет GOD выбран' }
                    'folder' { T 'Папка с игрой выбрана' }
                    default { T 'Образ выбран' }
                }
                Set-Banner 'ok' $title (T 'Нажмите «Установить и играть».')
            }
            'build'   { Set-Banner 'warn' (T 'Осталась сборка') (T 'Нажмите «Собрать и играть» — пересборка продолжится с того места, где остановилась.') }
            'play' {
                if ($check.Ok) {
                    Set-Banner 'ok' (T 'Готово к запуску') ((T 'Игра: {0}') -f (Resolve-GameDataPath))
                } else {
                    $detail = if ($check.Problem) { (T '{0}  ·  подробности во вкладке «Установка»') -f $check.Problem } else { T 'Подробности во вкладке «Установка».' }
                    Set-Banner 'warn' (T 'Нужна проверка') $detail
                }
            }
        }
        return $check
    }

    # ---- choosing the image
    function Set-IsoPath([string]$Path) {
        $ui.IsoBox.Text = $Path
        Update-Settings @{ IsoPath = $Path }
        $problem = Test-IsoChoice $Path
        [void](Update-Readiness)
        if ($problem) {
            $title = switch (Get-InstallSourceKind $Path) {
                'god' { T 'С пакетом GOD что-то не так' }
                'folder' { T 'С папкой игры что-то не так' }
                default { T 'С образом что-то не так' }
            }
            Set-Banner 'warn' $title $problem
        }
        Show-Page 'NavHome'
    }
    function Select-Iso {
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Title = T 'Call of Duty 3: образ диска, default.xex или пакет GOD'
        # The disc image, default.xex of a game already unpacked into a folder,
        # or the header of a Games on Demand package - a file without an
        # extension ("*." matches those); the first filter shows all three.
        $dialog.Filter = (T 'Образ диска, распакованная игра или пакет GOD') + ' (*.iso; default.xex; GOD)|*.iso;*.xex;*.|' +
                         (T 'Образ диска Xbox 360') + ' (*.iso)|*.iso|' +
                         (T 'Распакованная игра') + ' (default.xex)|*.xex|' +
                         (T 'Пакет Games on Demand (файл без расширения в папке 00007000)') + '|*.|' +
                         (T 'Все файлы') + ' (*.*)|*.*'
        $current = $ui.IsoBox.Text.Trim()
        if ($current -and (Test-Path -LiteralPath (Split-Path -Parent $current) -PathType Container)) {
            $dialog.InitialDirectory = Split-Path -Parent $current
        }
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            Set-IsoPath $dialog.FileName
            return $true
        }
        return $false
    }
    function Get-DroppedIso($DragArgs) {
        # A disc image, the default.xex of an unpacked game, a folder (an
        # unpacked game or one holding a Games on Demand package), or a GOD
        # header file.
        if (-not $DragArgs.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) { return $null }
        $first = [string]@($DragArgs.Data.GetData([System.Windows.DataFormats]::FileDrop))[0]
        if (-not $first) { return $null }
        if ([IO.Path]::GetExtension($first) -in @('.iso', '.xex')) { return $first }
        if (Test-Path -LiteralPath $first -PathType Container) { return $first }
        if (Read-GodHeader $first) { return $first }
        return $null
    }
    $window.Add_PreviewDragOver({
        param($eventSender, $eventArgs)
        $eventArgs.Effects = if (-not $job.Running -and (Get-DroppedIso $eventArgs)) { [System.Windows.DragDropEffects]::Copy } else { [System.Windows.DragDropEffects]::None }
        $eventArgs.Handled = $true
    })
    $window.Add_PreviewDrop({
        param($eventSender, $eventArgs)
        $eventArgs.Handled = $true
        if ($job.Running) { return }
        $file = Get-DroppedIso $eventArgs
        if ($file) { Set-IsoPath $file }
    })

    function Set-Recompile([bool]$Value) {
        $ui.RecompileSwitch.IsChecked = $Value
        $ui.SetupRecompile.IsChecked = $Value
        Update-Settings @{ Recompile = $Value }
        [void](Update-Readiness)
    }
    foreach ($radio in @($ui.CursorSegments.Children)) {
        $radio.Add_Checked({
            $style = Get-CursorStyle ([string]$this.Tag)
            Set-LauncherCursor $ui.Root $style
            Update-Settings @{ Cursor = $style }
        })
    }
    foreach ($toggle in @($ui.RecompileSwitch, $ui.SetupRecompile)) {
        $toggle.Add_Click({ Set-Recompile ([bool]$this.IsChecked) })
    }

    # ---- playing
    $watch = New-Object System.Windows.Threading.DispatcherTimer
    $watch.Interval = [TimeSpan]::FromMilliseconds(1500)
    $watch.Add_Tick({
        if ($null -eq $game.Process) { $watch.Stop(); return }
        if (-not $game.Process.HasExited) { return }
        # At the end of a level the game restarts itself for the next one, as
        # the console did: the exiting process leaves "<old pid> <new pid>" in
        # logs\cod3-relaunch.txt (integration/pc-controls/title_relaunch.cpp).
        $next = Get-RelaunchedGame $game.Process.Id
        if ($next) {
            $game.Process = $next
            Set-Banner 'ok' (T 'Следующий уровень') ((T 'Игра перезапустилась для нового уровня  ·  процесс {0}') -f $next.Id)
            return
        }
        $code = 0
        try { $code = $game.Process.ExitCode } catch { $code = 0 }
        $game.Process = $null
        $watch.Stop()
        [void](Update-PrimaryAction)
        if ($window.WindowState -eq [System.Windows.WindowState]::Minimized) {
            $window.WindowState = [System.Windows.WindowState]::Normal
        }
        [void]$window.Activate()
        if ($code -eq 0) {
            Set-Banner 'ok' (T 'Игра закрыта') (T 'Можно запускать снова.')
        } else {
            Set-Banner 'warn' ((T 'Игра закрылась с кодом {0}') -f $code) (T 'Если это случилось неожиданно — «Отчёт об ошибке» во вкладке «Установка».')
        }
    })

    function Invoke-Play {
        $current = Read-Form
        Export-Settings $current
        $gameData = Resolve-GameDataPath
        $check = Update-Readiness
        if (-not $check.Ok) {
            Write-Status ($check.Text + [Environment]::NewLine + [Environment]::NewLine + (T 'Запуск отменён.'))
            Show-Page 'NavInstall'
            return
        }
        $ui.PlayButton.IsEnabled = $false
        Set-PlayText (T 'ЗАПУСК…')
        Set-Banner 'busy' (T 'Запуск игры') (T 'Проверяем, что игра стартовала…')
        # Let the new state paint before Start-Game blocks for a few seconds.
        $window.Dispatcher.Invoke([Action]{ }, [System.Windows.Threading.DispatcherPriority]::Background)
        try {
            $started = Start-Game $current $gameData
            if ($started.ExitedEarly) {
                [void](Update-PrimaryAction)
                Set-Banner 'error' (T 'Игра завершилась сразу после запуска') (T 'Причина — во вкладке «Установка».')
                Write-Status ((T 'Игра завершилась сразу после запуска.') + "`r`n`r`n$($started.EarlyError)`r`n`r`n" +
                              ((T 'Полный журнал: {0}') -f $started.LogPath))
                Show-Page 'NavInstall'
            } else {
                $game.Process = $started.Process
                [void](Update-PrimaryAction)
                $watch.Start()
                Set-Banner 'ok' (T 'Игра запущена') ((T 'Процесс {0}  ·  журнал: {1}') -f $started.Process.Id, (Split-Path -Leaf $started.LogPath))
                Write-Status ((T 'Игра запущена (процесс {0}).') -f $started.Process.Id + "`r`n" + ((T 'Журнал: {0}') -f $started.LogPath) +
                              "`r`n`r`n" + (T 'Окно игры живёт отдельно от лаунчера. Если игра не появилась, нажмите «Отчёт об ошибке».'))
                $window.WindowState = [System.Windows.WindowState]::Minimized
            }
        } catch [System.ComponentModel.Win32Exception] {
            [void](Update-PrimaryAction)
            Set-Banner 'error' (T 'Windows заблокировала запуск') $_.Exception.Message
            Write-Status ((T 'Windows заблокировала запуск: {0}') -f $_.Exception.Message + "`r`n`r`n" +
                          (T 'Чаще всего это Smart App Control: он блокирует неподписанные сборки. Отключается в «Безопасность Windows» → «Управление приложениями и браузером». Отключение необратимо, решение за вами.'))
            Show-Page 'NavInstall'
        } catch {
            [void](Update-PrimaryAction)
            Show-Failure $_ (T 'Не удалось запустить игру')
            Show-Page 'NavInstall'
        }
    }

    # ---- installing: one child process, this script with -RebuildNow,
    # whose log is streamed into the window.
    $jobTimer = New-Object System.Windows.Threading.DispatcherTimer
    $jobTimer.Interval = [TimeSpan]::FromMilliseconds(600)

    function Update-JobView {
        $total = [Math]::Max(1, $job.Total)
        $step = [Math]::Min($total, [Math]::Max(1, $job.Step))
        $percent = [int][Math]::Min(99, [Math]::Floor((($step - 1) + $job.Fraction) / $total * 100))
        $ui.JobProgress.Value = $percent
        $ui.JobPercent.Text = "$percent%"
        $ui.JobStep.Text = if ($job.StepName) { (T 'Шаг {0} из {1}  ·  {2}') -f $step, $total, $job.StepName } else { T 'Подготовка…' }
        $ui.JobLine.Text = $job.LastLine
        if ($job.Started) {
            $elapsed = [DateTime]::Now - $job.Started
            Set-Banner 'busy' $ui.SetupTitle.Text ((T 'Прошло {0:hh\:mm\:ss}  ·  {1}') -f $elapsed, $ui.JobStep.Text)
        }
    }

    function Add-JobText([string]$Text) {
        $Text = Remove-AnsiEscapes $Text
        if ([string]::IsNullOrEmpty($Text)) { return }
        $ui.StatusBox.AppendText($Text.Replace("`r`n", "`n").Replace("`n", [Environment]::NewLine))
        $ui.StatusBox.ScrollToEnd()
        $lines = ($job.Partial + $Text.Replace("`r", '')).Split("`n")
        $job.Partial = $lines[$lines.Length - 1]
        foreach ($line in $lines[0..($lines.Length - 2)]) {
            if ($line -match '^=== \[(\d+)/(\d+)\] (.+) ===\s*$') {
                $job.Step = [int]$Matches[1]; $job.Total = [int]$Matches[2]; $job.StepName = $Matches[3]; $job.Fraction = 0.0
            } elseif ($line -match '^\s*\[(\d+)/(\d+)\]\s') {
                # ninja progress inside the build step
                $all = [int]$Matches[2]
                if ($all -gt 0) { $job.Fraction = [Math]::Min(1.0, [int]$Matches[1] / $all) }
            }
            if ($line.Trim()) { $job.LastLine = $line.Trim() }
        }
    }

    function Complete-InstallJob([int]$ExitCode) {
        $jobTimer.Stop()
        $job.Process = $null
        $job.Running = $false
        $logText = ''
        try { $logText = Remove-AnsiEscapes ([IO.File]::ReadAllText($job.OutFile, [Text.Encoding]::UTF8)) } catch { }
        if ($job.Cancelled) {
            [void](Update-Readiness)
            Set-Banner 'warn' (T 'Установка прервана') (T 'Уже скачанное и собранное сохранится: следующая попытка продолжит с того же места.')
            return
        }
        if ($ExitCode -eq 0) {
            if ($job.Recompile) { Update-Settings @{ RebuildPending = $false } }
            $fresh = Get-Layout
            if ($fresh) { $script:Layout = $fresh }
            $elapsed = [DateTime]::Now - $job.Started
            $ui.StatusBox.AppendText([Environment]::NewLine + ((T 'Установка завершена за {0:hh\:mm\:ss}.') -f $elapsed) + [Environment]::NewLine)
            $check = Update-Readiness
            if ($check.Ok -and $job.LaunchAfter) {
                Invoke-Play
            } elseif ($check.Ok) {
                Set-Banner 'ok' (T 'Установка завершена') (T 'Можно играть.')
            } else {
                Set-Banner 'error' (T 'Установка завершилась, но проверка не прошла') (T 'Подробности во вкладке «Установка».')
                Show-Page 'NavInstall'
            }
            return
        }
        $hint = Get-FailureHint $logText
        $tail = @($logText -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 4) -join [Environment]::NewLine
        $summary = [Environment]::NewLine + ((T '=== Установка остановилась (код {0}) ===') -f $ExitCode) + [Environment]::NewLine
        if ($hint) { $summary += $hint + [Environment]::NewLine }
        $summary += ((T 'Полный журнал: {0}') -f $job.OutFile) + [Environment]::NewLine +
                    (T 'Если непонятно, что делать, нажмите «Отчёт об ошибке» и пришлите файл в Discord проекта.') + [Environment]::NewLine
        $ui.StatusBox.AppendText($summary)
        $ui.StatusBox.ScrollToEnd()
        [void](Update-PrimaryAction)
        Set-Banner 'error' (T 'Установка остановилась') $(if ($hint) { $hint } else { ($tail -split [Environment]::NewLine)[-1] })
        Show-Page 'NavInstall'
    }

    $jobTimer.Add_Tick({
        try {
            if ($null -eq $job.Process) { $jobTimer.Stop(); return }
            $offset = $job.Offset
            $reference = [ref]$offset
            Add-JobText (Read-NewText $job.OutFile $reference)
            $job.Offset = $reference.Value
            if (-not $job.Process.HasExited) { Update-JobView; return }
            Start-Sleep -Milliseconds 300
            $offset = $job.Offset
            $reference = [ref]$offset
            Add-JobText (Read-NewText $job.OutFile $reference)
            $job.Offset = $reference.Value
            if ($job.Partial) { Add-JobText "`n" }
            Complete-InstallJob $job.Process.ExitCode
        } catch {
            $jobTimer.Stop()
            $job.Running = $false
            $job.Process = $null
            [void](Update-PrimaryAction)
            Show-Failure $_ (T 'Ошибка лаунчера во время установки')
        }
    })

    function Start-InstallJob([bool]$Recompile, [bool]$LaunchAfter, [bool]$FullCompile = $false) {
        if ($job.Running) { return }
        $current = Read-Form
        Export-Settings $current
        $iso = [string]$current.IsoPath
        $extracted = Test-Path -LiteralPath (Join-Path $script:Layout.GameData 'default.xex') -PathType Leaf
        if (-not $extracted) {
            $problem = Test-IsoChoice $iso
            if ($problem) {
                Set-Banner 'warn' (T 'Нужен образ диска, default.xex или пакет GOD') $problem
                if (-not $iso) { [void](Select-Iso) }
                return
            }
        }
        $pwsh = Get-PowerShell7
        if (-not $pwsh) {
            Set-Banner 'error' (T 'Не найден PowerShell 7') (T 'В пакете должен быть tools\toolchain-bundle\pwsh — распакуйте архив целиком.')
            return
        }
        $space = Get-InstallSpaceProblem $Recompile $FullCompile
        if ($space) {
            Set-Banner 'error' (T 'Не хватает места на диске') $space
            Write-Status $space
            Show-Page 'NavHome'
            return
        }
        if ($Recompile) {
            $missing = @(Get-BuildPrerequisites | Where-Object { -not $_.Ok })
            if ($missing.Count -gt 0) {
                Set-Banner 'error' (T 'Для пересборки не хватает файлов пакета') (($missing | ForEach-Object { $_.Name }) -join ', ')
                Write-Status ((T 'Не хватает компонентов для пересборки:') + "`r`n  " + (($missing | ForEach-Object { $_.Name }) -join "`r`n  ") +
                    "`r`n`r`n" + (T 'Распакуйте архив целиком или выключите пересборку и играйте готовой сборкой.'))
                Show-Page 'NavInstall'
                return
            }
        }
        try {
            $steps = @(Get-RebuildSteps $iso $Recompile $FullCompile)
        } catch {
            Show-Failure $_ (T 'Установку нельзя начать')
            return
        }
        if ($steps.Count -eq 0) {
            if ($Recompile) { Update-Settings @{ RebuildPending = $false } }
            [void](Update-Readiness)
            if ($LaunchAfter) { Invoke-Play }
            return
        }
        if ($Recompile) { Update-Settings @{ RebuildPending = $true } }

        if (-not (Test-Path -LiteralPath $script:Layout.LogDir)) {
            New-Item -ItemType Directory -Path $script:Layout.LogDir -Force | Out-Null
        }
        $stamp = [DateTime]::Now.ToString('yyyyMMdd-HHmmss')
        $job.OutFile = Join-Path $script:Layout.LogDir "cod3-install-$stamp.log"
        $job.Offset = [long]0
        $job.Partial = ''
        $job.Step = 0; $job.Total = $steps.Count; $job.StepName = ''; $job.Fraction = 0.0; $job.LastLine = ''
        $job.Recompile = $Recompile
        $job.LaunchAfter = $LaunchAfter
        $job.Cancelled = $false

        $command = '"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}" -RebuildNow' -f $pwsh, $script:LauncherScript
        if (-not $Recompile) { $command += ' -ExtractOnly' }
        if ($FullCompile) { $command += ' -FullCompile' }
        if ($iso) { $command += ' -Iso "' + $iso + '"' }
        $command += ' > "' + $job.OutFile + '" 2>&1'
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $env:ComSpec
        # chcp 65001 keeps non-ASCII paths readable in the streamed log.
        $startInfo.Arguments = '/d /c "chcp 65001 >nul & ' + $command + '"'
        $startInfo.WorkingDirectory = $script:Layout.Root
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.Environment['NO_COLOR'] = '1'

        $header = New-Object System.Collections.Generic.List[string]
        $sourceKind = Get-InstallSourceKind $iso
        $kind = if ($sourceKind -eq 'god' -and $Recompile) { T 'Установка с пересборкой из пакета GOD, {0}' }
                elseif ($sourceKind -eq 'god') { T 'Установка из пакета GOD (готовая сборка), {0}' }
                elseif ($sourceKind -eq 'folder' -and $Recompile) { T 'Установка с пересборкой из папки с игрой, {0}' }
                elseif ($sourceKind -eq 'folder') { T 'Установка из папки с игрой (готовая сборка), {0}' }
                elseif ($Recompile) { T 'Установка с пересборкой из образа, {0}' }
                else { T 'Установка из образа (готовая сборка), {0}' }
        $header.Add($kind -f (Get-Date).ToString('dd.MM.yyyy HH:mm'))
        $header.Add((T 'Шаги:'))
        foreach ($step in $steps) { $header.Add('  - ' + $step.Name) }
        $appControl = Get-AppControlWarning
        if ($Recompile -and $appControl) { $header.Add(''); $header.Add($appControl) }
        $header.Add((T 'Журнал: {0}') -f $job.OutFile)
        $header.Add('')
        Write-Status (($header -join [Environment]::NewLine) + [Environment]::NewLine)

        $job.Process = [System.Diagnostics.Process]::Start($startInfo)
        $job.Started = [DateTime]::Now
        $job.Running = $true
        [void](Update-PrimaryAction)
        Update-JobView
        Show-Page 'NavHome'
        $jobTimer.Start()
    }

    function Stop-InstallJob([bool]$Ask = $true) {
        if (-not $job.Running -or -not $job.Process) { return $true }
        if ($Ask) {
            $answer = [System.Windows.MessageBox]::Show(
                (T 'Прервать установку?') + "`n`n" + (T 'Уже скачанное и собранное сохранится: следующая попытка продолжит с того же места.'),
                'Call of Duty 3 PC', 'YesNo', 'Question')
            if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { return $false }
        }
        $job.Cancelled = $true
        Stop-ProcessTree $job.Process.Id
        return $true
    }

    function Invoke-PrimaryAction {
        switch (Get-PrimaryState) {
            'choose'  { [void](Select-Iso) }
            'install' { Start-InstallJob ([bool]$ui.RecompileSwitch.IsChecked) $true }
            'build'   { Start-InstallJob $true $true }
            'play'    { Invoke-Play }
        }
    }

    # ---- handlers
    $ui.MinButton.Add_Click({ $window.WindowState = [System.Windows.WindowState]::Minimized })
    $ui.CloseButton.Add_Click({ $window.Close() })
    $window.Add_Closing({
        param($eventSender, $eventArgs)
        if ($job.Running) {
            if (-not (Stop-InstallJob $true)) { $eventArgs.Cancel = $true; return }
        }
        try { Export-Settings (Read-Form) } catch { Write-LauncherErrorLog $_ }
        $watch.Stop()
        $jobTimer.Stop()
    })
    foreach ($button in @($ui.TopDiscord, $ui.HomeDiscord)) { $button.Add_Click({ Open-Link $script:DiscordUrl }) }
    foreach ($button in @($ui.TopDonate, $ui.HomeDonate)) { $button.Add_Click({ Open-Link $script:DonateUrl }) }

    $ui.PlayButton.Add_Click({ Invoke-PrimaryAction })
    $ui.IsoBrowse.Add_Click({ [void](Select-Iso) })
    $ui.IsoBox.Add_LostFocus({
        $typed = $ui.IsoBox.Text.Trim()
        if ($typed -ne [string]$script:Settings.IsoPath) { Set-IsoPath $typed }
    })
    $ui.InstallButton.Add_Click({ Start-InstallJob ([bool]$ui.RecompileSwitch.IsChecked) $true })
    # "Пересобрать игру" compiles in full, even when the recompiled code matches
    # the ready-made build.
    $ui.RebuildButton.Add_Click({ Start-InstallJob $true $false $true })
    $ui.JobCancel.Add_Click({ [void](Stop-InstallJob $true) })
    $ui.JobShowLog.Add_Click({ Show-Page 'NavInstall' })

    $ui.VerifyButton.Add_Click({
        $current = Read-Form
        Export-Settings $current
        [void](Update-Readiness)
    })

    $ui.LogsButton.Add_Click({
        if (-not (Test-Path -LiteralPath $script:Layout.LogDir)) {
            New-Item -ItemType Directory -Path $script:Layout.LogDir -Force | Out-Null
        }
        Start-Process explorer.exe $script:Layout.LogDir
    })

    $ui.ReportButton.Add_Click({
        try {
            $path = New-DiagnosticsReport
            if (-not $job.Running) {
                Write-Status ((T 'Отчёт сохранён: {0}') -f $path + "`r`n`r`n" +
                              (T 'Приложите этот файл к сообщению об ошибке — например, в Discord проекта. В нём журналы последних запусков и установок, настройки, состав сборки и сведения о системе. Данных игры в нём нет.'))
            }
            Set-Banner 'ok' (T 'Отчёт сохранён на рабочий стол') (Split-Path -Leaf $path)
        } catch {
            Show-Failure $_ (T 'Не удалось собрать отчёт')
        }
    })

    # ---- language switch: everything is re-translated in place; the status
    # lines are rebuilt from the current state.
    function Update-LanguageText {
        Set-TranslatedText $texts
        Set-VersionText
        if ($job.Running) {
            [void](Update-PrimaryAction)
            Update-JobView
        } elseif ($game.Process) {
            [void](Update-PrimaryAction)
            Set-Banner 'ok' (T 'Игра запущена') ((T 'Процесс {0}') -f $game.Process.Id)
        } else {
            [void](Update-Readiness)
        }
    }
    foreach ($radio in @($ui.LanguagePanel.Children)) {
        $radio.Add_Checked({
            $code = [string]$this.Tag
            if ($code -eq $script:Language) { return }
            $script:Language = $code
            Update-Settings @{ Language = $code }
            Update-LanguageText
        })
    }

    [void](Update-Readiness)

    if ($PreviewDirectory) {
        # Development aid: render every page off-screen, no window shown.
        New-Item -ItemType Directory -Path $PreviewDirectory -Force | Out-Null
        # Only the Viewbox can leave the window: a child taken out of a
        # Viewbox no longer measures.
        $window.Content = $null
        foreach ($key in @($pages.Keys)) {
            Show-Page $key
            Save-ElementImage $ui.Viewport (Join-Path $PreviewDirectory ($pages[$key] + '.png')) 1180 720
        }
        # Every page in every language, to catch text that no longer fits.
        # The saved language is not touched.
        $saved = $script:Language
        foreach ($code in $script:Languages) {
            $script:Language = $code
            Set-Segment $ui.LanguagePanel $code
            Update-LanguageText
            foreach ($key in @($pages.Keys)) {
                Show-Page $key
                Save-ElementImage $ui.Viewport (Join-Path $PreviewDirectory ("lang-$code-" + $pages[$key] + '.png')) 1180 720
            }
        }
        $script:Language = $saved
        Set-Segment $ui.LanguagePanel $saved
        Update-LanguageText
        # The install card in its running state, with made-up progress.
        $job.Running = $true; $job.Recompile = $true; $job.Started = [DateTime]::Now.AddMinutes(-12)
        $job.Step = 6; $job.Total = 9; $job.StepName = T 'Первичная кодогенерация'; $job.Fraction = 0.4
        $job.LastLine = 'Strict codegen passed: saint_lo'
        [void](Update-PrimaryAction)
        Update-JobView
        Show-Page 'NavHome'
        Save-ElementImage $ui.Viewport (Join-Path $PreviewDirectory 'PageHome-installing.png') 1180 720
        return
    }
    [void]$window.ShowDialog()
}

# ----------------------------------------------------------------------- main

Import-LauncherStrings
$script:Layout = Get-Layout
if ($null -eq $script:Layout) {
    $script:Language = Resolve-LauncherLanguage (New-DefaultSettings) $false
    [System.Windows.Forms.MessageBox]::Show(
        (T 'Не найден cod3_pc.exe.') + "`n`n" + (T 'Положите лаунчер рядом с игрой или в корень рабочего дерева проекта.'),
        'Call of Duty 3 PC', 'OK', 'Error') | Out-Null
    exit 1
}

$hadSettings = Test-Path -LiteralPath (Get-SettingsPath) -PathType Leaf
$script:Settings = Import-Settings
$script:Language = Resolve-LauncherLanguage $script:Settings $hadSettings
# Kept in the settings from now on, so the language picked for a new install
# does not turn into "existing tester, Russian" on the next start.
$script:Settings.Language = $script:Language

if ($CheckRebuild) {
    Write-Output ((T 'Режим: {0}, корень: {1}') -f $script:Layout.Kind, $script:Layout.Root)
    Write-Output ((T 'Игра: {0}') -f (Resolve-GameDataPath))
    Write-Output "PowerShell 7: $(Get-PowerShell7)"
    Write-Output (T 'Компоненты для пересборки:')
    $marks = @((T 'есть'), (T 'добудет'), (T 'НЕТ'))
    $width = ($marks | Measure-Object -Property Length -Maximum).Maximum
    foreach ($item in Get-BuildPrerequisites) {
        $mark = if ($item.Present) { $marks[0] } elseif ($item.Provision) { $marks[1] } else { $marks[2] }
        $note = if (-not $item.Present -and $item.Provision) { ' (' + $item.Provision + ')' } else { '' }
        Write-Output ("  [{0}] {1}{2} -> {3}" -f $mark.PadRight($width), $item.Name, $note, $item.Path)
    }
    $appControl = Get-AppControlWarning
    if ($appControl) { Write-Output ''; Write-Output $appControl; Write-Output '' }
    Write-Output (T 'Шаги установки с пересборкой:')
    try {
        foreach ($step in Get-RebuildSteps $Iso $true) {
            Write-Output ("  {0}: {1} {2}" -f $step.Name, $step.File, ($step.Arguments -join ' '))
        }
    } catch {
        Write-Output "  $($_.Exception.Message)"
    }
    exit 0
}

if ($RebuildNow) {
    # Runs in PowerShell 7 (the window starts it with the bundled pwsh). Plain
    # text output: the window shows this log as it is written.
    if ($PSVersionTable.PSVersion.Major -ge 7) { $PSStyle.OutputRendering = 'PlainText' }
    $recompile = -not $ExtractOnly
    if ($recompile) {
        $missing = @(Get-BuildPrerequisites | Where-Object { -not $_.Ok })
        if ($missing.Count -gt 0) {
            Write-Output (T 'Не хватает компонентов для пересборки:')
            foreach ($item in $missing) { Write-Output "  $($item.Name)" }
            exit 1
        }
    }
    if ($Iso -and -not (Test-Path -LiteralPath (Join-Path $script:Layout.GameData 'default.xex') -PathType Leaf)) {
        $problem = Test-IsoChoice $Iso
        if ($problem) { Write-Output $problem; exit 1 }
    }
    $pwsh = Get-PowerShell7
    if (-not $pwsh) { Write-Output (T 'Не найден PowerShell 7.'); exit 1 }
    $space = Get-InstallSpaceProblem $recompile ([bool]$FullCompile)
    if ($space) { Write-Output "Not enough disk space: $space"; exit 1 }
    $steps = @(Get-RebuildSteps $Iso $recompile ([bool]$FullCompile))
    $number = 0
    foreach ($step in $steps) {
        $number++
        Write-Output ''
        Write-Output "=== [$number/$($steps.Count)] $($step.Name) ==="
        & $pwsh -NoProfile -ExecutionPolicy Bypass -File $step.File @($step.Arguments)
        if ($LASTEXITCODE -ne 0) {
            Write-Output ((T 'Шаг завершился с ошибкой (код {0}).') -f $LASTEXITCODE)
            exit $LASTEXITCODE
        }
    }
    Write-Output ''
    Write-Output $(if ($recompile) { T 'Установка и пересборка завершены.' } else { T 'Установка завершена.' })
    exit 0
}

if ($Play) {
    $gameData = Resolve-GameDataPath
    $check = Test-Installation $gameData
    if (-not $check.Ok) {
        [System.Windows.Forms.MessageBox]::Show($check.Text, 'Call of Duty 3 PC', 'OK', 'Warning') | Out-Null
        exit 1
    }
    Start-Game $script:Settings $gameData | Out-Null
    exit 0
}
try {
    Show-Launcher $Preview
} catch {
    # The console is minimised behind the window, so say it on screen too.
    Write-LauncherErrorLog $_
    if ($Preview) { throw }
    [System.Windows.Forms.MessageBox]::Show(
        (T 'Лаунчер не смог открыть окно:') + "`n`n$($_.Exception.Message)`n`n" + ((T 'Подробности: {0}') -f 'logs\launcher-error.log'),
        'Call of Duty 3 PC', 'OK', 'Error') | Out-Null
    exit 1
}
