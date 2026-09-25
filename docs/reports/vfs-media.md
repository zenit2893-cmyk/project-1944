# CoD3 VFS and media path audit

Дата проверки: 2026-09-13. Объект: `<workspace>\game\cod3`, полученный
из уже проверенного образа `Call of Duty 3 (USA, Europe).iso`.

Этот отчёт описывает путь к данным и наблюдаемые отсутствующие файлы. Он не
добавляет игровые данные, не изменяет `game/cod3` и не трактует успешную
регистрацию процесса как успешный запуск игры.

## Результат

Маппинг для извлечённого XEX подготовлен в
`integration/vfs-media/cod3_vfs_media.toml`, а безопасная лексическая
реализация находится в `integration/vfs-media/cod3_vfs_media_map.*`.

| Гостевой путь | Host device | Host root | Политика |
| --- | --- | --- | --- |
| `GAME:\...` / `game:/...` | `\\Device\\Harddisk0\\Partition1` | `game/cod3` | разрешён |
| `D:\...` / `d:/...` | `\\Device\\Harddisk0\\Partition1` | `game/cod3` | разрешён |
| `\\Device\\Harddisk0\\Partition1\\...` | тот же | `game/cod3` | разрешён |
| `cache:\...` | отдельное устройство | отсутствует в этом маппинге | не подменяется |
| `update:\...` | отдельное устройство | отсутствует в этом маппинге | не подменяется |
| `C:\...` | host path | не является гостевым путём | отклоняется |

Сравнение `GAME:` и `D:` выполняется без учёта ASCII-регистра и вида
разделителя. `.` и внутренние `..` сворачиваются. Попытка выйти `..` выше
корня игры отклоняется до формирования host path. Резолвер только строит путь,
а наличие проверяет вызывающий код; он ничего не создаёт и не считает
отсутствующий файл найденным.

## Источник и полный инвентарь

Предыдущая проверка XDVDFS зафиксировала для этого источника:

| Показатель | Значение |
| --- | ---: |
| Файлов | 553 |
| Каталогов | 41 |
| Суммарный размер | 6 193 138 297 байт |
| SHA-256 `default.xex` | `2944EEC7D1231AD6798B5F9F8ADF8855F5E489296B22EAB45B27A577CEE23692` |

Нативный тест повторно перечисляет живое дерево и проверяет все три числа.
Кроме этого, он проверяет каждый файл в корне, `config`, `media` и `movies`.
Остальные 496 файлов из `sp`/`mp` и один файл `$SystemUpdate` учитываются в
полном инвентаре и не копируются в этот integration-пакет.

### Присутствует

В корне:

`codmp_xenonf.xex`, `default.xex`.

В `config` присутствуют ровно следующие 13 файлов:

`default.cfg`, `mp_xenon_a.cfg`, `mp_xenon_b.cfg`, `mp_xenon_c.cfg`,
`mp_xenon_d.cfg`, `ts_def.cfg`, `ts_leg.cfg`, `ts_legsp.cfg`, `ts_sp.cfg`,
`xenon_a.cfg`, `xenon_b.cfg`, `xenon_c.cfg`, `xenon_d.cfg`.

В `media` присутствует `GARA.TTF`.

В `movies` присутствуют 40 файлов:

`attract.wma`, `attract.wmv`, `atvi.wma`, `atvi.wmv`, `blkbrn-en.wma`,
`blkbrn.wmv`, `chambois-en.wma`, `chambois.wmv`, `crssrds-en.wma`,
`crssrds.wmv`, `falaise-en.wma`, `falaise.wmv`, `finale-en.wma`,
`finale.wmv`, `forest-en.wma`, `forest.wmv`, `fuelplnt-en.wma`,
`fuelplnt.wmv`, `hostage-en.wma`, `hostage.wmv`, `island-en.wma`,
`island.wmv`, `laison-en.wma`, `laison.wmv`, `legal-uk.wma`, `legal-uk.wmv`,
`legal-us.wma`, `legal-us.wmv`, `mace2-en.wma`, `mace2.wmv`, `mayenne-en.wma`,
`mayenne.wmv`, `nightd-en.wma`, `nightd.wmv`, `saint_lo-en.wma`,
`saint_lo.wmv`, `stbert-en.wma`, `stbert.wmv`, `Treyarch.wma`, `treyarch.wmv`.

Регистронезависимый lookup маппит `d:/media/gara.ttf` на этот же `GARA.TTF`
на Windows. Это проверка правил имени, не преобразование файла.

### Отсутствует

В последнем просмотренном журнале запуска зафиксированы 21 уникальный
отсутствующий путь (`logs/cod3-pc-run-20260905-100006.log:19-43` и повторные
запросы `:44-57`):

| Гостевой путь | Наблюдение |
| --- | --- |
| `d:/config/language.cfg` | файл отсутствует; каталог `config` есть |
| `d:/config/bro.cfg` | файл отсутствует; каталог `config` есть |
| `d:/config/autoexec.cfg` | файл отсутствует; каталог `config` есть |
| `d:/movies/legal-us-en.wma` | имя отсутствует; `legal-us.wma` есть |
| `d:/movies/legal-us-fr.wma` | французский вариант отсутствует |
| `d:/movies/legal-us-de.wma` | немецкий вариант отсутствует |
| `d:/hunkusage.dat` | файл отсутствует |
| `d:/_english/` | каталог отсутствует |
| `d:/_french/` | каталог отсутствует |
| `d:/_german/` | каталог отсутствует |
| `d:/_italian/` | каталог отсутствует |
| `d:/_spanish/` | каталог отсутствует |
| `d:/_british/` | каталог отсутствует |
| `d:/_russian/` | каталог отсутствует |
| `d:/_polish/` | каталог отсутствует |
| `d:/_korean/` | каталог отсутствует |
| `d:/_taiwanese/` | каталог отсутствует |
| `d:/_japanese/` | каталог отсутствует |
| `d:/_chinese/` | каталог отсутствует |
| `d:/_thai/` | каталог отсутствует |
| `d:/_leet/` | каталог отсутствует |

Лог показывает статус `0xc000000f` для этих запросов. Для `d:/config` и
`d:/movies` это важно: предупреждение вызвано отсутствием конкретного имени,
а не отсутствием корневого host mount.

## Языковые и content aliases

В Xenia-подобном VFS регистрируются device и symbolic links; регистр имени и
разделители не являются content aliases. Поэтому `D:\MOVIES\LEGAL-US.WMA`
может найти существующий `movies/legal-us.wma`, но `legal-us-en.wma` не должен
автоматически превращаться в `legal-us.wma` только потому, что похожее имя
есть.

В конфигурации зафиксированы три кандидата, все `enabled = false`:

| Запрос | Кандидат | Причина отключения |
| --- | --- | --- |
| `d:/movies/legal-us-en.wma` | `d:/movies/legal-us.wma` | наличие кандидата не доказывает, что заголовок ожидает этот язык |
| `d:/movies/legal-us-fr.wma` | нет | исходного французского файла нет |
| `d:/movies/legal-us-de.wma` | нет | исходного немецкого файла нет |

14 каталогов `_english`, `_french`, `_german`, `_italian`, `_spanish`,
`_british`, `_russian`, `_polish`, `_korean`, `_taiwanese`, `_japanese`,
`_chinese`, `_thai`, `_leet` также не алиасуются к английскому или к другому
языку. Нативный тест отдельно требует, чтобы отсутствующие имена оставались
отсутствующими, то есть конфигурация не маскирует предупреждения успешными
заглушками.

## Минимальное обратимое исправление

Для самого маппинга достаточно передавать `game/cod3` как host root и
регистрировать оба Xenia-совместимых алиаса на один read-only device. Это уже
подтверждено тестом.

Для оставшихся предупреждений минимальная корректная мера зависит от цели:

1. Если нужны оригинальные языковые ролики и конфиги, добавить точные файлы
   из собственной лицензированной копии источника и повторить проверку
   манифеста. Этот пакет не копирует и не генерирует их.
2. Если допустим английский fallback для legal screen, сначала подтвердить
   поведение выбора языка на уровне заголовка, затем включить отдельный
   opt-in fallback в вызывающем runtime. До такой проверки `legal-us.wma`
   остаётся только кандидатом.
3. `hunkusage.dat` и `_leet`/прочие языковые каталоги не следует считать
   исправленными без наблюдаемого запроса, который требует их содержимого.

Создание пустых `language.cfg`, `bro.cfg`, `autoexec.cfg`, каталогов или
пустых медиа-файлов является ложным исправлением: оно меняет статус
`NAME_NOT_FOUND`, но не даёт игре необходимые данные.

## Xenia/ReXGlue основание

Использованная схема сверена с локальной копией Xenia:

- `tools/Xenia-source/src/xenia/emulator.h:59-60` задаёт `GAME:` и `D:`.
- `tools/Xenia-source/src/xenia/emulator.cc:448-473` создаёт/регистрирует
  host device и symbolic links.
- `tools/Xenia-source/src/xenia/emulator.cc:600-613` описывает extracted-XEX
  запуск из каталога, содержащего XEX.
- `tools/Xenia-source/src/xenia/vfs/virtual_file_system.cc:128-155`
  нормализует guest path, разрешает symbolic link и выбирает device.
- `integration/rexglue-runtime-build/src/src/system/runtime.cpp:295-323`
  уже монтирует `game_data_root` как
  `\\Device\\Harddisk0\\Partition1` и регистрирует `game:`/`d:`.

## Проверка

Standalone native test: `tests/vfs-media/main.cpp`. Он собирается без SDK,
без GPU и без запуска игры:

```powershell
& .\scripts\toolchain-env.ps1 -Quiet
cmake -S .\tests\vfs-media -B <temp>\cod3-vfs-media-build-20260913-03 -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo
cmake --build <temp>\cod3-vfs-media-build-20260913-03 --config RelWithDebInfo
& <temp>\cod3-vfs-media-build-20260913-03\cod3_vfs_media_tests.exe <workspace>\game\cod3
```

Результат: `cod3_vfs_media_tests: PASS`; проверены counts 553/41/6 193 138 297,
все перечисленные startup assets и 21 ожидаемый miss. `ctest`-обвязка в
`tests/vfs-media/CMakeLists.txt` использует тот же read-only тестовый процесс.
