# Call of Duty 3: установленный образ и статические ориентиры

Проверка выполнена 5 сентября 2026 по пользовательскому образу и извлечённым из него файлам. Анализ подтвердил отдельный основной XEX, XEX мультиплеера и 15 настоящих XEX2-модулей уровней. Игровая логика, физика и 120 FPS этим анализом не проверялись.

## Точная идентификация

| Поле | `game/cod3/default.xex` |
|---|---|
| Размер | 7 254 016 байт |
| SHA256 | `2944EEC7D1231AD6798B5F9F8ADF8855F5E489296B22EAB45B27A577CEE23692` |
| SHA1 | `681724C40E250E584E6585DD903E05AFA00A8634` |
| MD5 | `03333E7C40BF627E498E53821FC3C7CD` |
| Title ID | `415607E1` |
| Media ID | `2E07093A` |
| Version / base version | `0.0.0.1` / `0.0.0.1` |
| Исходное имя PE | `cod_xenonf.pe` |
| Timestamp PE, UTC | `2006-10-10T02:01:39Z` |
| Машина PE | `0x01F2`, PowerPC big-endian |
| База / точка входа | `0x82000000` / `0x82344D00` |
| Размер развёрнутого образа | 12 779 520 байт |
| Упаковка XEX | normal encryption, basic compression |

Поля независимо прочитаны `scripts/analyze-title-xex.py` по структурам установленного SDK, затем сверены с загрузкой ReXGlue. Машиночитаемые результаты: `analysis/title-metadata.json`, `analysis/title-modules.json`. Они содержат все 17 модулей, их хеши, базы, точки входа, библиотеки и адреса исходных импортных записей.

`codmp_xenonf.xex` имеет ту же пару title/media и версию, но другую точку входа `0x823140C8`, исходное имя `codmp_xenonf.pe` и размер развёрнутого образа 14 811 136 байт. Это отдельный исполняемый модуль, а не режим внутри единственной перекомпиляции `default.xex`.

Все 15 файлов `sp/<уровень>/<уровень>.dll` начинаются с `XEX2`, имеют флаги `0x9` (TITLE и DLL), базу `0x89000000` и различные точки входа. Список: blkbrn, chambois, credits, crssrds, falaise, forest, fuelplnt, hostage, island, laison, mace2, mayenne, nightd, saint_lo, stbert. Одинаковая база указывает на необходимость обработки сменяемых модулей; фактическую последовательность их загрузки ещё нужно проверить при запуске.

## Развёрнутый образ

`scripts/analyze-title-image.py` повторяет процедуру basic decompression установленного открытого загрузчика ReXGlue, используя `cryptography`. Он не меняет XEX и создаёт локальный исходный образ до исправления импортов runtime:

- `analysis/title-default-image.bin`, SHA256 `9771B34A1A981350A24A9C1B0E72A5FBBBE0F2815D448A297B3D2989F32C263C`;
- `analysis/title-default-image.json`: структура PE, хеши, источник алгоритма и строковые ориентиры.

Сравнение с `analysis/cod3-loaded-image.bin`, захваченным отдельным процессом ReXGlue в режиме анализа, показало полное побайтовое совпадение всех исполняемых секций. Различаются только 32 байта `.rdata`, относящиеся к исправлению импортов. Это проверка восстановления образа, а не исполнения игры. Оба `.bin` и сгенерированный из игры C++ являются локальными игровыми данными и не предназначены для включения в публичный исходный репозиторий порта.

## Ориентиры для дальнейшего анализа

| Адрес | Подтверждённая строка |
|---|---|
| `0x8201840C` | `[1.1]NGL 3.0.0` |
| `0x82018270` | Диагностика вызова `nglPresent` при незавершённых сценах |
| `0x82018B38` | Диагностика вызова `nglListSend` при незавершённых сценах |
| `0x82065B68` | `pmove_msec` |
| `0x82066288` | `timescale` |
| `0x82068764` | `com_maxfps` |
| `0x82068798` | `fixedtime` |
| `0x82069AC8` | `sv_framerate_smoothing` |
| `0x820788E8` | `pmove_fixed` |
| `0x82078F00` | `cg_fov` |

Строки подтверждают наличие соответствующих имён в точном образе; они сами по себе не устанавливают семантику функций, единицы времени и пригодность патча FPS. Надпись NGL проверена непосредственно в бинарном образе. Предположение, что это IW3 или что известный патч для другой Call of Duty применим здесь, не использовалось.

Дальнейшее прослеживание ссылок и временных функций передано исследованию timing. Имена импортов, порядковые номера, точные guest thunks и покрытие SDK вынесены в отдельный `analysis/runtime-imports.json`. Количество сырых импортных записей в XEX больше числа API: функциональный импорт обычно имеет запись значения и запись thunk.

## Публичные сведения и границы их применимости

[Canary patch database](https://github.com/xenia-canary/game-patches/blob/main/patches/415607E1%20-%20Call%20Of%20Duty%203.patch.toml) связывает SP TU0 с title `415607E1`, media `2E07093A` и хешем `B796871E700C5C6B`. Этот файл содержит графические исправления и настройки FOV; патча 120 FPS в нём нет. Копия исходника и blob SHA сохранены в `analysis/title-sources/sources.json`.

Хеш `XXH3_64` по текущей процедуре [Xenia Canary `CalculateHash`](https://github.com/xenia-canary/xenia-canary/blob/canary_experimental/src/xenia/kernel/user_module.cc#L1070-L1107), воспроизведённой для code pages `0x820A0000..0x825A0000`, равен `E990398D635E773A` и для исходного образа, и для образа ReXGlue. Он не совпал с хешем публичного патча. Причина расхождения не установлена; адреса из патча не были автоматически применены.

[Mousehook CallOfDuty.cc](https://github.com/marinesciencedude/xenia-canary-mousehook/blob/mousehook/src/xenia/hid/winkey/hookables/CallOfDuty.cc) содержит ветвь SP и отдельные ветви MP TU0/TU3. Сигнатура строки `cg_fov` SP в `0x82078F00` совпала с локальной. Адреса камеры из этой ветви пока имеют статус внешних кандидатов: статическое совпадение строки не является проверкой живого состояния камеры.

[Canary compatibility issue #27](https://github.com/xenia-canary/game-compatibility/issues/27) на момент чтения имеет `state-gameplay` и метки графических проблем, GPU readback и VIZ queries. Это сведения о сторонних запусках эмулятора, не результат проверки нашего нативного проекта.

## Повторение анализа

Использованный Python: `python`. Дополнительные `capstone 5.0.9` и `xxhash 4.0.1` установлены только в `analysis/title-python`; глобальная Python-среда не менялась. `cryptography` уже присутствовал в bundled runtime.

```powershell
& $python scripts/analyze-title-xex.py game/cod3/default.xex --out analysis/title-metadata.json
& $python scripts/analyze-title-xex.py game/cod3 --out analysis/title-modules.json
& $python scripts/analyze-title-image.py game/cod3/default.xex --out-prefix analysis/title-default-image
& $python scripts/analyze-title-xenon.py
```

`$python` в примере следует присвоить указанному пути. Для последней команды результаты реконструкции должны уже существовать. Отдельный отчёт `title-xenon-comparison.md` описывает реальный запуск XenonRecomp и его ограничения.
