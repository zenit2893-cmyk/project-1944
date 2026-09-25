# ReXGlue SDK: проверка установленного дистрибутива

Дата проверки: 2026-09-05. Область: существующий `<workspace>\win-amd64`, соответствующий ZIP и точная версия исходников SDK. Файлы SDK, ZIP и игры не изменялись.

## Проверенный результат

`win-amd64\bin\rexglue.exe --version` возвращает **0.10.0.5-dev.g0c7b01a**. SHA-256 локального ZIP совпадает с `digest` актива официального GitHub Releases:

```text
67b19131fce54eab7019833623856d998d1c420fcf8cd8394057a2ba1957bf8b
```

Все **1 209 файлов** установленного SDK побайтно совпадают с файлами ZIP по SHA-256. Пропусков, расхождений и дополнительных файлов нет. Все **59 уникальных путей** в импортированных CMake-целях существуют. Дистрибутив содержит x64 CLI, заголовки, библиотеки, CMake-пакеты, исходники ReXApp и GPU/runtime DLL для Release, Debug и RelWithDebInfo.

Официальный релиз: [nightly-20260904-0c7b01a0](https://github.com/rexglue/rexglue-sdk/releases/tag/nightly-20260904-0c7b01a0), опубликован 2026-09-04 11:10:04 UTC. Соответствующий commit: `0c7b01a0ac0479801757507d80533f662fa0815d`.

Точные исходники сохранены для чтения в `tools\rexglue-source`, detached HEAD на этом commit. Подмодули исходного SDK не скачивались: это справочная копия; для сборки проекта используется готовый `win-amd64`.

Полное машинное свидетельство: [sdk-verification.json](<workspace>/docs/reports/sdk-verification.json). Повторная проверка из PowerShell в корне рабочей папки:

```powershell
& '.\scripts\sdk-verify.ps1' -ProbePlugin
```

## ABI и загрузка DLL

PE-заголовки всех 10 двоичных файлов в `bin` указывают AMD64 (`0x8664`). GPU-плагины экспортируют `rex_gpu_abi_version` и `rex_gpu_create`. Реальная загрузка через `LoadLibraryExW` с разрешением зависимостей из каталога DLL и системных каталогов, с вызовом только функции версии ABI, дала:

| Конфигурация | DLL | Загрузка | ABI |
|---|---|---|---|
| Release | `rexgpu-xenos.dll` | Успешна | 1 |
| RelWithDebInfo | `rexgpu-xenosrd.dll` | Успешна | 1 |
| Debug | `rexgpu-xenosd.dll` | Ошибка Windows 126 | Не вызван |

Debug-плагин импортирует `MSVCP140D.dll`, `VCRUNTIME140D.dll`, `VCRUNTIME140_1D.dll`, `ucrtbased.dll`; Debug-runtime также импортирует `MSVCP140D_ATOMIC_WAIT.dll`. Эти Debug CRT DLL не найдены в `System32` при проверке. Это согласуется с ошибкой отсутствующей зависимости; ошибка 126 сама по себе не называет конкретный файл. Для первого запуска подходит **RelWithDebInfo**, где runtime и GPU-плагин успешно загрузились. Полноценная среда разработчика C++ может предоставить Debug CRT через свой PATH; это нужно проверить после её настройки.

Release/RelWithDebInfo используют динамический MSVC CRT, включая `MSVCP140.dll`, `VCRUNTIME140.dll`, `VCRUNTIME140_1.dll`, а runtime — `MSVCP140_ATOMIC_WAIT.dll` и Universal CRT. Эти зависимости уже разрешаются на данном ПК. Не смешивать DLL разных конфигураций и SDK-сборок: загрузчик выбирает суффикс `d`/`rd` по конфигурации runtime.

Проверка ABI не создавала D3D12-устройство, не выполняла код игры и не подтверждает графику, совместимость Call of Duty 3 или FPS.

## Команды именно для 0.10.0.5

Старые страницы wiki показывают `--app_name`, `--app_root`, `*_config.toml` и прежние варианты поиска SDK. Текущий `--help` и исходники используют manifest и следующие команды. Снимки справки сохранены рядом: `sdk-cli-help.txt`, `sdk-cli-init-help.txt`, `sdk-cli-codegen-help.txt`.

Из `<workspace>`, при первоначальном создании отсутствующего проекта:

```powershell
& '.\win-amd64\bin\rexglue.exe' init --project-name cod3 --xex-path '.\game\cod3\default.xex' --game-root '.\game\cod3' --project-root '.\cod3' --scan-dll
& '.\win-amd64\bin\rexglue.exe' codegen '.\cod3\cod3_manifest.toml'
```

`init` проверяет наличие XEX и требует, чтобы он находился внутри `--game-root`. Путь XEX берётся относительно текущего рабочего каталога. В проекте создаются `cod3_manifest.toml`, `CMakeLists.txt`, `CMakePresets.json`, `generated/rexglue.cmake`, `src/main.cpp`, `src/cod3_app.h`. `--scan-dll` добавляет найденные `.dll` в разделы `[[modules]]` manifest. Повторный `init` может переписать управляемые файлы; не применять его к отредактированному проекту как способ обновления.

Сгенерированный manifest содержит `[project]` с `name`, `sdk_version`, `game_root`, а также `[entrypoint]` с `file_path`, `out_directory_path`, `includes`. `codegen` принимает manifest позиционно или находит его в текущем каталоге; `--target NAME` выбирает DLL-модули, `--ignore-stamp` отключает пропуск по stamp. Глобальный `--force` разрешает генерацию после ошибок валидации. Неразрешённые вызовы при этом могут стать `REX_FATAL` в C++; это не исправление совместимости.

После успешного codegen, из каталога `cod3`, в настроенной x64 C++ developer environment:

```powershell
cmake --preset win-amd64-relwithdebinfo '-DCMAKE_PREFIX_PATH=<workspace>/win-amd64' -DREXSDK_VERSION=0.10.0.5
cmake --build --preset win-amd64-relwithdebinfo --target cod3_codegen
cmake --preset win-amd64-relwithdebinfo
cmake --build --preset win-amd64-relwithdebinfo
```

Сначала проверяется codegen, затем CMake конфигурируется с существующим `sources.cmake`. Повторная конфигурация после первой генерации нужна для включения новых исходников. Числовой `REXSDK_VERSION=0.10.0.5` включает точное сравнение CMake-версии; строка `-dev.g...` туда не передаётся. Параметр **`REXSDK_DIR` означает исходное дерево SDK**, а не бинарный `win-amd64`. Готовый SDK подключается через `CMAKE_PREFIX_PATH` или `rexglue_DIR=<workspace>/win-amd64/lib/cmake/rexglue`.

CMake-шаблон требует CMake 3.25+, Ninja, C++23, использует `clang`/`clang++`; исходный SDK проверяет Clang 18+. Официальный Windows AMD64 preset SDK применяет `-march=x86-64-v2`. Практическая сборка потребует Windows SDK и MSVC C++ headers/libraries в окружении Clang. Проверку конкретно установленного toolchain выполняет отдельный этап проекта.

## Подключение GPU и запуск

Важная особенность шаблона 0.10: GPU по умолчанию отключён. Хост должен запрашивать копирование плагина:

```cmake
rexglue_setup_target(cod3 GPU_PLUGINS xenos)
```

При запуске необходимо `--gpu_plugin xenos` либо установка `config.gpu_plugin = "xenos"` в `OnPreSetup`. `rex::gpu-xenos` загружается динамически; его не требуется напрямую линковать в хост. CMake-helper копирует правильный GPU-плагин рядом с EXE; runtime-зависимости копируются отдельно через `TARGET_RUNTIME_DLLS`.

Для построенного стандартным preset проекта, пример команды из рабочей папки:

```powershell
& '.\cod3\out\build\win-amd64-relwithdebinfo\cod3.exe' --gpu_plugin xenos --game_data_root '<workspace>\game\cod3' --user_data_root '<workspace>\cod3\userdata' --cache_root '<workspace>\cod3\cache' --video_mode_refresh_rate 60
```

Команда описывает стандартный шаблон и не утверждает, что данный EXE уже собран/работает. Если проект изменяет output directory, путь EXE берётся из результата сборки. `ReXApp` требует **каталог извлечённых данных**; ISO и позиционный путь не являются его интерфейсом загрузки. По умолчанию он ищет `game:\default.xex`. VFS монтирует каталог как `game:` и `d:` и запрещает запись в него, пока `allow_game_relative_writes` не включён.

Этот бинарный SDK собран с `REX_HAS_D3D12=1`, `REXGLUE_USE_VULKAN=OFF`. Плагин использует D3D12 и внутренний перевод Xenos shader microcode в DXBC. `dxcompiler.dll`, `dxilconv.dll`, `D3DCompiler_47.dll` в исследованных местах используются для необязательной дизассемблировки; отсутствие DXC в архиве не свидетельствует о неполном SDK. Provider запрашивает D3D12 feature level 11_0; фактические возможности GPU и состояние драйвера требуют отдельной проверки.

## Извлечение и цель 120 FPS

В установленном `rexglue` **нет команды извлечения ISO**. Проверенный этап извлечения подготовил `game\cod3` через `tools\xdvdfs\xdvdfs.exe` 0.8.3. Команда проекта:

```powershell
& '.\scripts\extract-cod3.ps1'
```

Свидетельства отдельного этапа: `analysis\disc-extraction.json`, `analysis\disc-file-manifest.csv`. Агент извлечения сообщил проверку всех 553 файлов по длине и MD5 относительно ISO, SHA-256 каждого извлечённого файла и неизменность SHA-256 самого ISO; этот аудит SDK не повторяет чтение всего игрового образа.

Наличие `--video_mode_refresh_rate 120`, `--clock_no_scaling` и `--clock_source_raw` в SDK не доказывает безопасную работу игры при 120 FPS. До подтверждения игрового fixed timestep и разделения rendering/simulation сохраняется частота/таймеры исходной игры. Не применять `-ffast-math`/`/fp:fast` и ускорение guest clock ради FPS. SDK сам собирает свою C++ часть с `-ffp-model=strict` и `-fno-strict-aliasing`; это не означает, что эти приватные флаги автоматически применены ко всем исходникам потребителя.

## Проверяемые исходники

- [CLI init и файлы проекта](https://github.com/rexglue/rexglue-sdk/blob/0c7b01a0ac0479801757507d80533f662fa0815d/src/rexglue/commands/init_command.cpp).
- [CMake-шаблон интеграции](https://github.com/rexglue/rexglue-sdk/blob/0c7b01a0ac0479801757507d80533f662fa0815d/resources/templates/init/rexglue_cmake.inja).
- [GPU ABI](https://github.com/rexglue/rexglue-sdk/blob/0c7b01a0ac0479801757507d80533f662fa0815d/include/rex/system/gpu_plugin.h) и [загрузчик DLL](https://github.com/rexglue/rexglue-sdk/blob/0c7b01a0ac0479801757507d80533f662fa0815d/src/system/gpu_plugin_loader.cpp).
- [Настройка ReXApp и путей](https://github.com/rexglue/rexglue-sdk/blob/0c7b01a0ac0479801757507d80533f662fa0815d/src/ui/rex_app.cpp).
- [D3D12 provider](https://github.com/rexglue/rexglue-sdk/blob/0c7b01a0ac0479801757507d80533f662fa0815d/src/ui/d3d12/d3d12_provider.cpp) и [shader pipeline](https://github.com/rexglue/rexglue-sdk/blob/0c7b01a0ac0479801757507d80533f662fa0815d/src/graphics/d3d12/pipeline_cache.cpp).
