# Contributing / Как помочь

## English

Thanks for helping Project 1944. Open an issue before a large change so the intended behavior and test scope are clear. Keep pull requests focused and describe the source revision, relevant mission, test method, and any limitations. A passing build alone is not proof of gameplay behavior.

**Never commit or attach** a game image, extracted game file, generated game C++, shader or memory dump, build output, binary, personal path, or private data. Report bugs with the launcher's diagnostic archive only after reviewing it. Run this gate before every commit:

```powershell
pwsh -NoProfile -File scripts/repo/Test-RepoContent.ps1 -StrictPersonalPaths
```

The launcher must still parse in Windows PowerShell 5.1. Keep `launcher/Cod3Launcher.ps1` in UTF-8 **with BOM**, because Windows PowerShell 5.1 otherwise misreads Cyrillic. UI translations live in `launcher/strings.json`; each entry needs `ru`, `en`, `uk`, `be`, `es`, and `de`, with the same `{n}` placeholders. Update all three root READMEs when changing player-facing behavior.

Third-party code lives in pinned submodules or clearly marked vendored source, with its notices preserved. Put local upstream changes in reviewable patch files. Do not add an automatic game build or release workflow: those operations require a game copy that is absent from CI.

## Русский

Перед крупным изменением откройте issue, чтобы согласовать поведение и границы проверки. Делайте PR небольшими; указывайте ревизию исходной игры, миссию, метод тестирования и ограничения. Успешная сборка сама по себе не доказывает, что игра работает правильно.

**Нельзя добавлять или прикладывать** образ игры, распакованные игровые файлы, сгенерированный игровой C++, дампы шейдеров и памяти, результаты сборки, бинарники, личные пути и приватные данные. Перед отправкой отчёта проверьте содержимое диагностического архива лаунчера. Перед каждым коммитом запускайте команду выше.

Лаунчер должен разбираться Windows PowerShell 5.1. Сохраняйте `launcher/Cod3Launcher.ps1` как UTF-8 **с BOM**: без него кириллица в Windows PowerShell 5.1 читается неверно. Переводы находятся в `launcher/strings.json`: каждой записи нужны `ru`, `en`, `uk`, `be`, `es`, `de` и одинаковые заполнители `{n}`. При изменении пользовательского поведения обновляйте все три корневых README.

Внешний код оформляется закреплёнными подмодулями или явно отмеченным vendored-исходником с сохранёнными уведомлениями. Локальные изменения upstream храните отдельными проверяемыми патчами. Автоматическую сборку игры и релиз в CI не добавляйте: там нет копии игры.

## Українською

Перед значною зміною відкрийте issue, щоб узгодити поведінку та межі перевірки. Робіть PR зосередженими; вказуйте ревізію джерела гри, місію, спосіб тестування та обмеження. Успішна збірка сама по собі не доводить, що гра працює правильно.

**Не додавайте й не прикріплюйте** образ гри, розпаковані ігрові файли, згенерований ігровий C++, дампи шейдерів або пам'яті, результати збірки, бінарні файли, особисті шляхи чи приватні дані. Переглядайте діагностичний архів лаунчера перед надсиланням. Перед кожним комітом запускайте команду вище.

Лаунчер має розбиратися Windows PowerShell 5.1. Зберігайте `launcher/Cod3Launcher.ps1` у UTF-8 **з BOM**, інакше кирилиця може читатися неправильно. Переклади містяться в `launcher/strings.json`: кожен запис потребує `ru`, `en`, `uk`, `be`, `es`, `de` й однакових заповнювачів `{n}`. Після зміни поведінки для гравця оновлюйте всі три кореневі README.

Сторонній код оформлюйте як закріплені підмодулі або чітко позначений код постачальника зі збереженням ліцензійних повідомлень. Локальні зміни upstream зберігайте окремими патчами. Не додавайте автоматичну збірку гри чи реліз у CI: там немає копії гри.
