# XenonRecomp + ReXGlue: проверенная граница совместимости

Проверены исходники XenonRecomp `ddd128bcca99fe8bfbb99bea583c972351fa6ace` и установленный ReXGlue `0.10.0.5-dev.g0c7b01a`, source commit `0c7b01a0ac0479801757507d80533f662fa0815d`. Для двух конкретных функций создана и протестирована действующая интеграция. Общая бинарная совместимость двух recompiler ABI отсутствует.

## Реально работающая ограниченная интеграция

В `integration/xenon` находятся настоящие тела функций из выполненного XenonRecomp codegen. Из `analysis/title-xenon-generated/ppc_recomp.32.cpp` выбраны без изменения тела:

| Адрес | Исходные байты PPC | Выполняемое действие |
|---|---|---|
| `0x822D0498` | `4BFFFC80` | Tail-call исходной ReXGlue-функции `sub_822D0118` |
| `0x822D2140` | `38630004 4BFF98E4` | ADDI `r3 += 4` по модулю 2^64; tail-call `sub_822CBA28` |

Их имена меняются препроцессором на `cod3_xenon_thunk_822D0498` / `cod3_xenon_thunk_822D2140`. Единственный контекст — тип из установленного `<rex/ppc/context.h>`. Исходящие функции объявлены `REX_EXTERN` и получают тот же `ctx` и `base`, как при прямом вызове в собственном codegen ReXGlue. `override_hooks.cpp` использует поддерживаемый `REX_HOOK_RAW` и обязательный Clang tail-call в адаптированные функции. Исходные `__imp__sub_*` остаются доступны.

Xenon генерирует ADDI через signed `ctx.r3.s64 + 4`. Объект bridge отдельно компилируется с `-fwrapv`; переполнение по модулю 2^64 определено, исходное сгенерированное тело сохранено. Флаги арифметики основного проекта не меняются этой интеграцией.

Повторяемая проверка:

```powershell
& '.\integration\xenon\extract-generated-thunks.ps1' -GeneratedDirectory '.\analysis\title-xenon-generated'
& '.\tests\xenon-bridge\run.ps1' -Configuration RelWithDebInfo
```

Результат: **1 072 native cases PASS** в Release и RelWithDebInfo с Clang 22.1.8. Сравнение ведётся с отдельным декодером исходных слов инструкций PPC. Проверены два прямых entry point и два `REX_HOOK_RAW` entry point; граничные значения INT64_MAX/UINT64_MAX и переход через 32-битную границу; случайные битовые состояния всех регистров; все 2 688 байт контекста перед tail-call; неизменность LR, идентичность адреса контекста и memory base; один вызов правильной функции; возврат её изменённого состояния; отсутствие записи в memory canary.

Дизассемблирование оптимизированного COFF-объекта показывает `jmp` для первой функции и `addq $4, (%rcx)` + `jmp` для второй, с релокациями к ожидаемым ReXGlue guest symbols. Это ограниченная проверка настоящего скомпилированного CPU-кода, не запуск игрового сценария и не измерение FPS.

Свидетельства:

- [Тела Xenon](<workspace>/integration/xenon/generated/thunks.generated.inl).
- [Происхождение: SHA исходного C++, строки, SHA образа, байты инструкций](<workspace>/integration/xenon/generated/thunks.provenance.json).
- [Текущий результат native test](<workspace>/tests/xenon-bridge/results.json), [его вывод](<workspace>/tests/xenon-bridge/last-test-output.txt), [COFF disassembly с релокациями](<workspace>/tests/xenon-bridge/thunks-disassembly.txt).
- [Инструкция включения двух raw hooks](<workspace>/integration/xenon/README.md).

Подключение к хосту после поиска SDK и создания его CMake target:

```cmake
add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../integration/xenon" xenon)
cod3_enable_xenon_thunk_overrides(cod3_pc)
```

Это не включает прочий Xenon output и не заменяет ReXGlue runtime, память, kernel imports или GPU. Решение о включении в конечный хост выполняется основным этапом сборки проекта.

## Почему нельзя линковать весь Xenon output напрямую

Оба инструмента объявляют функцию вида `void(PPCContext&, uint8_t*)`, но одинаковое имя типа не означает одинаковый layout. Отдельные Clang `-fsyntax-only` static_assert-пробы на настоящих заголовках подтвердили следующие размеры и смещения при отключённых Xenon register-local optimizations:

| Свойство | XenonRecomp | ReXGlue 0.10.0.5 |
|---|---:|---:|
| `sizeof(PPCContext)` | 2688 | 2688 |
| `alignof(PPCContext)` | 64 | 64 |
| `offsetof(fpscr)` | 324 | 324 |
| `offsetof(f0)` | **328** | **336** |
| `offsetof(v0)` | 592 | 592 |
| `vscr_sat` | Нет | Смещение 328 |
| `last_indirect_target` | Нет | Смещение 332 |

Совпадение общего размера скрывает несовместимость FPR. Передача raw Xenon-context в SDK будет читать/писать другие поля. Кроме того, upstream Xenon физически удаляет поля при `PPC_CONFIG_NON_ARGUMENT_AS_LOCAL`, `NON_VOLATILE_AS_LOCAL`, `SKIP_LR`, `CTR_AS_LOCAL`, `XER_AS_LOCAL`, `RESERVED_AS_LOCAL`, `SKIP_MSR`, `CR_AS_LOCAL`. В ReXGlue поля контекста постоянны; эти опции влияют на generated function locals. Для общей интеграции нужно генерировать против единого SDK-контекста, а не приводить указатель и не проверять только `sizeof`.

| Контракт | XenonRecomp в проверенном commit | ReXGlue / требуемая интеграция |
|---|---|---|
| Function definitions | `PPC_FUNC_IMPL`, `PPC_WEAK_FUNC`, C++ linkage у части внешних объявлений | `REX_EXTERN`/`REX_FUNC`, согласованная C linkage и уникальные символы; избегать второго `PPCFuncMappings` |
| Scalar memory | `base + address`, byte swap | Windows physical aliases для guest >= `0xE0000000` используют добавочное `0x1000`; нужен единый `REX_RAW_ADDR`/memory contract |
| Vector, cache, atomic memory | Генератор напрямую выдаёт `base + ea` для LVX/STVX, DCBZ/DCBZL, LDARX/LWARX, STDCX/STWCX | Переопределения scalar macros недостаточно; исправляется generator или проверенный преобразователь конкретных конструкций |
| MMIO | Default `PPC_MM_*` — обычные memory loads/stores; store выбирается ограниченной проверкой соседней EIEIO | Доступ через SDK MMIO handler и его диапазоны; требуется проверка всех фактических инструкций |
| Indirect calls | Безусловный lookup после одного image range | ReXGlue range/thunk checks и глобальный `ResolveIndirectFunction` с module registry; нужен адрес последней ошибочной функции |
| MFTB | `__rdtsc()` хоста | `rex::chrono::Clock::QueryGuestTickCount()`; нельзя подменять guest frequency частотой host TSC |
| setjmp/longjmp | Native `jmp_buf` прямо в guest memory и копия context | SDK использует thread-local host map по guest address; эти модели не взаимозаменяемы |
| Exceptions / missing code | Исключения не поддержаны; некоторые инструкции превращаются в debugtrap, нераспознанные вызовы — в `// ERROR` | Нужна отдельная корректная реализация и проверка, а не замена на успешный stub |
| SIMD helpers | Ряд вспомогательных функций в global namespace | ReXGlue перенёс их в `rex::ppc`; нужен явный alias/import audit |

По исходникам Xenon `Recompiler::Recompile` может напечатать предупреждения об отсутствии инструкций/таблиц и всё равно завершить CLI с кодом 0. Фактическая полная генерация Call of Duty 3 содержит такие сообщения. Exit code 0 сам по себе подтверждает только завершение генератора. В текущую интеграцию проходят только две функции, для которых проверены исходные инструкции и точно допустимые тела.

## Дальнейшая архитектура при расширении

Расширять такой подход можно по проверенным функциям, которые действительно лучше обрабатываются Xenon frontend. Каждая добавленная функция должна иметь границы и байты из конкретного XEX, source receipt, проверку всех emitted constructs, единый SDK-context, точные прямые/косвенные вызовы и differential tests. Сырые generated functions нельзя добавлять по одному лишь признаку успешной компиляции.

Для общего Xenon frontend есть техническая точка интеграции: второй аргумент `XenonRecomp <config.toml> <context-header>` копируется генератором в `ppc_context.h`. Такой header может использовать единственный ReXGlue context, macros, SIMD helpers, image info и dispatcher. Однако raw pointer операции, MFTB, setjmp/longjmp, неопознанные инструкции и inline exception patterns потребуют изменений генератора или проверенного преобразования. Одного заголовка для всего CoD3 недостаточно.

XenosRecomp решает отдельную задачу перевода shader microcode в HLSL/DXIL. ReXGlue `rexgpu-xenos` уже реализует GPU command processing и свою трансляцию шейдеров. Подключение файлов XenosRecomp к CPU bridge не подключает автоматически renderer; интеграция shader backend должна соответствовать конкретным ресурсам, root signatures, fetch semantics и pipeline state. Эту работу ведёт отдельный графический этап.

Основные первичные источники: [Xenon PPC context](https://github.com/hedge-dev/XenonRecomp/blob/ddd128bcca99fe8bfbb99bea583c972351fa6ace/XenonUtils/ppc_context.h), [Xenon emitter](https://github.com/hedge-dev/XenonRecomp/blob/ddd128bcca99fe8bfbb99bea583c972351fa6ace/XenonRecomp/recompiler.cpp), [SDK context](https://github.com/rexglue/rexglue-sdk/blob/0c7b01a0ac0479801757507d80533f662fa0815d/include/rex/ppc/context.h), [SDK generated runtime macros](https://github.com/rexglue/rexglue-sdk/blob/0c7b01a0ac0479801757507d80533f662fa0815d/resources/templates/codegen/pch_h.inja), [SDK indirect dispatch](https://github.com/rexglue/rexglue-sdk/blob/0c7b01a0ac0479801757507d80533f662fa0815d/resources/templates/codegen/_indirect_call.inja).
