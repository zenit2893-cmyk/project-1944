# Engineering log snapshot

This is a sanitized snapshot of the development README recorded in September 2026. Its test statements are dated observations; use the root README and tester guide for the current public summary.

---

# Call of Duty 3 PC — рабочий проект

Активный проект: **`cod3-pc`**, Windows x64 / Clang / Direct3D 12. Предыдущая проверка `cod3` сохранена. Пользовательский образ и извлечённые данные не перезаписываются.

На этом этапе собраны `cod3_pc.exe` и 15 нативных DLL уровней. Проверено вживую 19.09.2026: меню, новая кампания, сохранение и загрузка чекпоинта, геймплей первой миссии (Saint-Lo) в полноэкранном 2560×1440 при 120 кадрах/с.

Что для этого сделано:

- **Скриптовые корутины** (`integration/coroutines`) работают в игре; прежнее падение на `_introscreen::main` устранено.
- **Пропущенные функции уровней.** Анализатор ReXGlue не находит часть функций, на которые есть только указатели (`lis/addi`, таблицы в `.rdata/.data`). `analysis/cod3-module-pointer-sweep.py` ищет их во всех 15 образах, `analysis/cod3-module-function-hints.py` записывает `[modules.functions]` в манифест (318 записей). Это исправило падение `Call to invalid or unregistered function at 0x890C1950`.
- **Микрофризы.** Поток гостевого vblank SDK ждёт через `Sleep(1)`, а таймер 1 мс никто не запрашивал, поэтому vblank приходил пачками по 15,6 мс. `cod3-pc/src/cod3_pc_app.h` включает `timeBeginPeriod(1)` и отключает power throttling процесса.
- **1440p/120.** Лаунчер получил `-OutputSize 1440p|NativeDisplay`, `-RenderScale 1..3` (`draw_resolution_scale`) и `-RefreshRate 60|120` (`video_mode_refresh_rate`).
- **Выборка вершин.** ReXGlue не переносил из Xenia обнуление слов за концом вершинного буфера и обрезание адреса буфера маской `0x1FFFFFFC`; в его коде остался комментарий «проверка границ не делается». Восстановлено в [integration/vfetch-bounds](integration/vfetch-bounds), собирается свой `rexgpu-xenosrd.dll`.
- **Полосы вместо травы.** Обходной ключ `-NoFoliage` подменяет выборку контрольной карты травы (слот текстуры 18) константой, из-за чего собственная проверка длины в шейдере игры не проходит и геометрия стеблей не создаётся. Полосы исчезают, текстуры земли не меняются. Первопричина не устранена, см. ниже.

Замер `scripts/frame_hitches.py` по трассе `-TimingTrace`, 45 с геймплея Saint-Lo, NativeDisplay 2560×1440, RenderScale 2, RefreshRate 120: 119,8 кадра/с, p99 10,8 мс, максимум 18,3 мс, кадров длиннее 20 мс нет. Игра измеряет ≈8,3 мс на кадр, то есть игровое время идёт с реальной скоростью.

### Что известно про траву

Шейдер травы (хеш микрокода `4B4E6FDA02FB39C3`) считает длину стебля как `красный канал × c28.x − c29.x`; в игре `c28.x = 45`, `c29.x = 2`. Контрольная карта — DXT5 128×128, слот 18, порядок байтов 8-в-16. Дамп её байтов из памяти игры показывает: при правильной перестановке байтов красный канал даёт плавный градиент, без перестановки — только 0 или 1. Перестановка в скомпилированном загрузочном шейдере SDK присутствует, упаковка поля endian совпадает с Xenia, трансляция выборки, констант, предикатов и адресов вершин тоже сверена с Xenia и расхождений не содержит. Поэтому источник неверных значений пока не найден; следующий шаг — сравнить ту же сцену в Xenia Canary.

Диагностика живёт в плагине за переменными окружения и по умолчанию выключена: `COD3_VS_TEX_ZERO` (`all` или номер слота), `COD3_VS_TEX_CONST`, `COD3_TEX_LOG`, `COD3_VS_CONST_LOG` (хеш шейдера).

Известные проблемы: трава (см. выше), масштаб рендера ×2 не доходит до кадра (игра отдаёт 1040×624, 2K получается растягиванием), вылет на экране сохранения в конце уровня воспроизводится у пользователя и теперь снабжён журналированием, остальные 14 уровней вживую не запускались.

## Для тестеров

Двойной щелчок по `Project1944.exe` открывает лаунчер [launcher/Cod3Launcher.ps1](launcher/Cod3Launcher.ps1) (exe собирается [launcher/exe/Build-LauncherExe.ps1](launcher/exe/Build-LauncherExe.ps1) и выполняет скрипт внутри себя; запасной путь — `launcher\PLAY-COD3.cmd`). Это игровой лаунчер на WPF (есть в любой Windows 10/11, ставить ничего не нужно) с вкладками «Главная», «Графика», «Управление» и «Установка»: установка — два клика: «Выбрать образ» (или перетащить `.iso` в окно) и «Установить и играть», после чего лаунчер сам распакует образ в `game\cod3`, пересоберёт игру на этой машине и запустит её; там же проверяется комплектность сборки и совпадение версии диска и задаются вывод, частота, мышь в шкале World at War, раскладка и обход ошибки с травой. Кнопка «Отчёт об ошибке» собирает на рабочий стол архив с логами, настройками, составом сборки и сведениями о системе; игровых файлов в нём нет. Кнопки вверху ведут в Discord проекта (https://discord.gg/7sGEwV3sB) и на страницу поддержки DonatePay (https://donatepay.ru/don/1456210). Фон и эмблема нарисованы кодом, [launcher/assets/build_art.py](launcher/assets/build_art.py), — чужих изображений в лаунчере нет.

Рекомпиляция переводит код игры из вашей копии в C++ готовыми `rexglue.exe` и XenonRecomp (GPL, исходники в архиве) — около минуты, без компилятора — и сверяет результат с кодом, из которого собрана готовая сборка (`analysis/recompile-reference.json`, только хеши). Совпало байт в байт — готовая сборка и есть результат; иначе, и по кнопке «Пересобрать игру», игра компилируется полностью. Инструменты лежат в самом архиве, в `tools/toolchain-bundle`: Clang/LLVM, CMake, Ninja, xdvdfs, переносимый CPython и модули для анализа образа. Из сети берётся только MSVC с Windows SDK (~280 МБ), только для полной компиляции и только если на машине нет Visual Studio. Подробности: [docs/build-from-source.md](docs/build-from-source.md), правовая часть — [docs/legal.md](docs/legal.md).

LLVM кладётся в архив один раз: драйвер `clang.exe` и линкер `lld.exe` физически одни и те же файлы под несколькими именами, и остальные имена воссоздаются жёсткими ссылками при установке — 783 МБ на вид, 246 МБ на диске.

Инструменты Плана Б: [tools/toolchain-provision](tools/toolchain-provision) (компилятор, CMake/Ninja, xdvdfs), [tools/rexglue-cli](tools/rexglue-cli) (сборка кодогенератора SDK), [tools/xenon-bridge-build](tools/xenon-bridge-build) (мост Xenon), [tools/signing](tools/signing) (подпись сборки и исключения Defender).

Про антивирусы, SmartScreen и Smart App Control — [docs/antivirus.md](docs/antivirus.md). Подписать собранное:

```powershell
& '.\tools\signing\Set-Cod3Signature.ps1' -CertificateThumbprint <отпечаток> -IncludeBinaries
```

Пошаговая инструкция для тестеров: [docs/testers.md](docs/testers.md). Шаблон сообщения об ошибке: [.github/ISSUE_TEMPLATE/bug_report.yml](.github/ISSUE_TEMPLATE/bug_report.yml).

Единый архив для раздачи собирается одной командой:

```powershell
& '.\scripts\release-package\New-Cod3Package.ps1' -Bundle Full
```

Результат — `integration/release-packaging/artifacts/cod3-pc-full.zip` (**246 МБ**, 16 483 файла, 831 МБ в распакованном виде): готовое приложение с библиотеками, лаунчер, исходники порта, ReXGlue SDK в `win-amd64`, его исходники в `sdk-source`, инструменты сборки в `tools/toolchain-bundle`, инструменты Плана Б в `tools`, исходники FFmpeg и libmspack в `lgpl-sources`, документация, лицензии и манифест с хешами. Этот архив самодостаточен: рядом с ним ничего нести не нужно, в том числе для LGPL.

Отдельно доступны `-Bundle Runtime` (только готовая сборка) и `-Bundle Developer` (только исходники). К `Runtime` архив исходников нужен отдельно — его собирает `New-SdkSourcePackage.ps1` в `cod3-pc-sdk-sources.zip` (25 МБ). Данные игры и компилятор не входят ни в один пакет.

Полная правовая картина: [docs/legal.md](docs/legal.md), перечень компонентов — [integration/release-packaging/THIRD-PARTY-NOTICES.md](integration/release-packaging/THIRD-PARTY-NOTICES.md).

Без аргументов в командной строке те же действия доступны так:

```powershell
powershell -ExecutionPolicy Bypass -File launcher\Cod3Launcher.ps1 -CheckRebuild
powershell -ExecutionPolicy Bypass -File launcher\Cod3Launcher.ps1 -RebuildNow -Iso "путь\к\образу.iso"
```

## Запуск имеющейся сборки

В рабочем дереве (не в пакете) — двойной щелчок по `START-COD3-PC.cmd`, либо из PowerShell:

```powershell
& '.\scripts\run-cod3.ps1'
```

`START-COD3-PC.cmd` запускает полный экран на разрешении монитора с рендером ×2 и 120 Гц:

```powershell
& '.\scripts\run-cod3.ps1' -OutputSize NativeDisplay -RenderScale 2 -RefreshRate 120
```

Без аргументов лаунчер запускает окно 1920×1080, рендер ×1 и 60 Гц. Ключ `-NoFoliage` убирает полосы вместо травы. Параметры `-InputMode Gamepad`, `-LogLevel debug`, `-TimingTrace` и `-DumpShaders` предназначены для отдельных проверок. Клавиатурное управление описано в [docs/controls.md](docs/controls.md).

Трасса кадров: запустить с `-TimingTrace`, затем

```powershell
python scripts/frame_hitches.py analysis/timing/captures/<файл>.ndjson --seconds 45
```

## Сборка

```powershell
& '.\scripts\build-cod3.ps1' -Configuration RelWithDebInfo -Jobs 6 `
  -RuntimeDll '<workspace>\tools\rexglue-patched-sdk\bin\rexruntimerd.dll'
```

Скрипт включает локальный toolchain, проверяет ревизию XEX, запускает CMake/Ninja и сохраняет хеши EXE и всех runtime DLL. Опциональный `-SaintLoDiagnostics` включает ограниченное наблюдение за переключением регистров уровня. Исправленный SDK сейчас собран только для **RelWithDebInfo**; его Release/Debug остаются исходными.

Генерация каждого из 15 модулей выполняется отдельным процессом, поскольку они используют один гостевой адрес. `cod3-pc/cmake/Invoke-Codegen.ps1` восстанавливает полный реестр DLL после изолированного анализа.

## Как используются три инструмента

| Инструмент | Фактическая роль |
|---|---|
| ReXGlue SDK 0.10.0.5 | Основной PowerPC → C++ codegen, runtime, память, потоки, аудио, ввод и GPU plugin |
| XenonRecomp / XenonAnalyse | Независимый анализ, выявление пропущенных входов; две буквально сгенерированные функции подключены через проверенный адаптер ABI |
| XenosRecomp | Локальный адаптер формата шейдеров CoD3, подготовка HLSL и проверка DXIL/SPIR-V |

Все 610 программ из 437 подготовленных контейнеров проходят компиляцию шейдеров. Для 63 программ конвертер отмечает неполную семантику градиентов. Их результаты **не подключены к активному GPU plugin**: runtime использует собственный транслятор ReXGlue. Детали и ограничения находятся в [docs/plan-b-architecture.md](docs/plan-b-architecture.md) и [docs/reports/graphics-pipeline.md](docs/reports/graphics-pipeline.md).

## Проверки

Полная подготовка вспомогательных CPU/GPU артефактов повторяется одной командой:

```powershell
& '.\scripts\prepare-cod3-pc.ps1'
```

Она проверяет исходную ревизию, запускает XenonAnalyse/XenonRecomp, выделяет и проверяет два разрешённых bridge-тела, извлекает шейдеры, обновляет разбор их инструкций и компилирует Xenos/DXC-артефакты. `-Stage Cpu` и `-Stage Shaders` позволяют отдельно повторить нужную часть при изменении соответствующих инструментов.

```powershell
& '.\scripts\verify-cod3.ps1' -RequireThrough native-build
& '.\tests\xenon-bridge\run.ps1' -Configuration RelWithDebInfo
& '.\integration\nonlocal-flow\Run.ps1'
```

Аудит отделяет успешную компиляцию от загрузки, gameplay, 120 FPS и сохранения физики. Трассы кандидатов игровых функций записываются только с `-TimingTrace`; их частота вызовов не выдаётся за FPS. Условия проверки физики описаны в [docs/reports/timing-120fps.md](docs/reports/timing-120fps.md).

## Данные и отчёты

- `game/cod3` — 553 файла из исходного ISO, включая основной XEX, MP XEX и 15 DLL уровней.
- `analysis/disc-source-lock.json` — точная ревизия и ожидаемые хеши.
- `analysis/*receipt*.json`, `logs` — результаты команд и запусков.
- `docs/reports` — доказательства установки, codegen, загрузчика, ABI, шейдеров и timing.
- `tools` — исходники и локальные инструменты; `win-amd64` — сохранённый исходный SDK.
- `integration` — проверенные адаптеры и отдельные диагностические компоненты.

Образы, игровые ресурсы, сгенерированный игровой C++, memory images и пользовательские данные исключены из Git. Внешних публикаций этого проекта не было.
