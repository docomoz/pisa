# Проверки версий

Исторические записи ниже описывают соответствующие версии. Начиная с 0.4.1, добавлено разрешение network.client для нативной загрузки моделей; утверждения об отсутствии сетевых разрешений относятся к прежним сборкам.

## Установщик и первая настройка · 0.4.1

Проверено 3 ноября 2026 года. Сборка Release для arm64 завершена; приложение и DMG проверены на этом Mac.

- Все 42 теста ядра проходят. Проверены установка файлов, SHA-256, отказ при повреждённом файле, повторная попытка, сохранность готовых файлов, очистка незавершённого файла при отмене, нехватка места и защита пути, включая символьную ссылку. Настоящий URLSession проверен на локальном HTTP-сервере: успешная загрузка, HTTP 503, повтор и отмена задачи.
- Нативный `--model-setup-self-test` проходит на изолированных файлах: стандартные и пользовательские модели, недействительный bookmark, отсутствие моделей участников и передача отмены рабочей задаче. `--library-self-test` также проходит.
- `--model-download-smoke-test` загружает только небольшой настоящий config.json с Hugging Face, проверяет SHA-256 и готовность без перезапуска. Проверка выполнена подписанным приложением с App Sandbox и network.client.
- Окно первой настройки просмотрено визуально: начальное состояние, настоящая загрузка примерно 13 МБ и отмена с возвратом к кнопке загрузки. Использована отдельная временная папка; библиотека установленного приложения не открывалась.
- В приложение включены dylib, Metal-библиотека, помощник MCP и лицензии. Проверка связей не выявила зависимостей от локальных папок или Homebrew. Пользователю готовой сборки не нужны Xcode и Python.
- Подпись приложения проверена через `codesign --verify --deep --strict`, включая копию в DMG. Текущая сборка подписана ad-hoc; Developer ID и нотариального заверения нет. Контрольная сумма образа проверена через `hdiutil verify`.
- Оформление DMG проверено в Finder: приложение и Applications, большие значки, зелёный фон и стрелка, компактное окно без боковой панели и панелей инструментов. Макет записывается непосредственно в .DS_Store средствами сборки, без автоматизации Finder.

### Полная проверка с нуля · 3 ноября 2026 года

После первоначальных проверок выполнен полный сценарий установки, загрузки и распознавания той же версии 0.4.1. Из DMG приложение скопировано в `build/e2e-20261103/Applications/Pisya E2E.app`. Для изоляции изменены только идентификатор пакета на `com.docomoz.pisya.e2e20261103a` и отображаемое имя, затем повторно применена ad-hoc подпись. Основной исполняемый файл после удаления подписи побайтово совпадает с исходным файлом из DMG; все 46 файлов ресурсов и других файлов вне изменённого Info.plist и данных подписи совпадают с копией из образа.

- В новом sandbox изначально были только пустые папки Audio и Meetings; папки Models не было. Обычное окно первой настройки загрузило все 11 официальных файлов общим размером 2 570 802 502 байта. Независимая проверка подтвердила размер и SHA-256 каждого файла: `build/e2e-20261103/root-model-verification.json`.
- Через стандартный диалог импорта открыт специально подготовленный русский AIFF длительностью 14,554 с. Микрофон и окружающий звук не записывались. Настоящий обработчик распознавания, Metal и включённые в приложение Sherpa/ONNX завершили обработку: статус ready, один говорящий и один сегмент. Все 26 слов совпали с эталоном при нормализации регистра, пунктуации и «ё». Временные границы корректны; голосовой вектор содержит 192 конечных числовых значения. Результаты сохранены в `build/e2e-20261103/evidence/root-transcript-verification.json`; эталон и текст — в `fixture/expected.txt` и `evidence/transcript.txt` внутри папки проверки.
- Проверка открытых файлов через lsof подтвердила загрузку `default.metallib` из ресурсов установленной тестовой копии. Во время работы создался дополнительный кэш `tokenizer.json`, поэтому после распознавания в папке моделей находится 12 файлов.
- После обычного завершения и повторного запуска настройки показывают готовую модель в изолированной папке. Файл встречи не изменился; размеры и время изменения всех 12 файлов моделей и кэша сохранились. Повторной загрузки не было. Подтверждение: `build/e2e-20261103/evidence/restart-verification.json`.
- Окончательный DMG повторно просмотрен в Finder после добавления надписи «Перенесите Pisya в Приложения». Обе версии фонового TIFF не содержат метаданных автора или программы создания. SHA-256 образа: `1c0b85225c83035cf9954948a2480880743b615667fdf799ca6d08e9cc3564bf`.

Тестовая копия, модели и запись сохранены в отдельном окружении. Основное установленное приложение и библиотека не использовались и не изменялись действиями этой проверки. Побайтовое сравнение основной библиотеки не проводилось: доступ к её контейнеру закрыт TCC.

Установка на другой Mac и проверка минимальной macOS 15 остаются за пределами проверки. Подпись по-прежнему ad-hoc, без Developer ID и нотариального заверения. Синтетическая запись с одним голосом не подтверждает качество разделения нескольких реальных участников.

## Проверка версии 0.1

Проверено 2 ноября 2026 года на Mac с Apple M4 Pro, 24 ГБ памяти.

## Подтверждено

- Сборка Debug и Release для arm64, запуск интерфейса и чтение библиотеки после перезапуска.
- Локальное распознавание специально созданного русского WAV продолжительностью около восьми секунд. Текст совпал с заданной тестовой фразой; модель вернула один речевой сегмент и вектор голоса размерности 192.
- Импорт этого WAV через системный диалог, обработка в приложении, показ текста и сохранение изменённого названия встречи.
- Визуально просмотрены главный экран, демонстрационная встреча, обработанная тестовая запись и настройки записи. Демонстрационные реплики отделены от реальной библиотеки.
- Тесты библиотеки: сохранение/чтение, стабильное имя экспорта, защита от выхода через имя аудиофайла, задержки детектора, запрет повторного автозапуска после ручной остановки, неоднозначные совпадения голосов, типографические пробелы.
- Тесты MCP: handshake, запрет доступа до включения, отзыв доступа в существующей сессии, недопустимый идентификатор встречи. Отдельно проверен собранный исполняемый файл MCP: инициализация и отказ при выключенном доступе.
- Проверены entitlements окончательной подписи: App Sandbox включён; network.client и network.server отсутствуют. Проверка подписи выполняется после добавления помощника MCP и лицензий.
- Локальные копии весов проверены по SHA-256. Аудио и база другого установленного рекордера не использовались.

## Ещё требуется проверить

- Настоящий звонок в Толке с разрешениями macOS: обе дорожки, выключение микрофона, смена гарнитуры, выход из звонка, переподключение и сон компьютера.
- Несколько реальных голосов, одновременная речь и узнавание людей в следующих встречах. Синтетический пример не доказывает качество диаризации.
- Автоэкспорт в пользовательскую папку Dropbox/Obsidian и долговечность разрешения после перезагрузки. Функция генерации Markdown проверена тестом; ручной системный диалог экспорта был отменён, полноценная проверка выгрузки через него не завершена.
- Установка на другой Mac. У сборки нет Developer ID и notarization; модель устанавливается отдельно.

Автозапись, MCP и автоматическая выгрузка по умолчанию выключены. Для просмотра оставлена одна явно помеченная синтетическая тестовая запись. Запись окружающего звука во время разработки не включалась.

Последняя установка выполнена после повторной сборки и проверки подписи. До финальных правок пробелов интерфейс установленной Release-сборки был просмотрен. После блокировки Mac повторный запуск окна не выполнялся; окончательная сборка повторно проверяется командным тестом распознавания.


## Исправление доступа · 0.1.2

- Запрос доступа выполняется до создания встречи; пустой журнал неудачного старта удаляется только при отсутствии файлов и расшифровки. Проверка сохранности существующих данных добавлена в тесты; все 6 тестов проходят.
- В Info.plist добавлена декларация NSScreenCaptureUsageDescription. Перед ScreenCaptureKit выполняется системный запрос CoreGraphics; этап и код отказа пишутся в локальный системный журнал без содержимого встречи.
- Сборка и проверка подписи проходят. Локальная подпись теперь привязана к постоянному сертификату, а не к хешу сборки; сетевые entitlements не добавлены.
- На этом Mac до повторной выдачи разрешения preflight возвращает false. Успешный захват настоящего звонка ещё не подтверждён.

## Universal recording · 0.1.3

Manual capture now records microphone and system audio independently of call applications. The installed build successfully started with Talk closed, stopped after 13 seconds, and completed local transcription of both tracks. Screen capture preflight remained true after the signed update. All 7 tests pass, including waiting before call activity and rejecting short triggers. Real browser-call automatic start/stop, mute, and device switching remain unverified; automation is off by default.

## Live recording meters · 0.1.4

Both tracks now display bounded 72-sample RMS history at 10 Hz, measured only after successful audio-file writes. Per-track counters reflect written sample duration. Silent buffers are distinguished from missing buffers (3-second threshold); absence of system audio is not claimed to prove a capture failure. Eight core tests pass, covering silence, stale data, invalid levels, and bounded history. Release build and signature verification pass. Visually inspected both live waveforms and growing per-track counters in the installed app; a 12-second recording stopped and completed local transcription successfully. The test entry is labelled separately. No network permissions added.

## Library and speaker management · 0.2.0

Ten core tests pass, including legacy JSON compatibility, folders, Trash visibility/restoration, voice example metadata, and voice matching. The packaged app's isolated `--library-self-test` additionally generates synthetic PCM and verifies exact audio-clip extraction, correcting a learned sample, preserving source tracks after renaming, folder moves/removal, Trash/restore, and retaining a saved voice clip after deleting meeting audio. This caught AVAudioFile short reads; extraction now loops until the requested sample count is read.

Installed UI checked: native sidebar selection switches the detail view; right-click menus expose rename/move/voice/Trash actions; rename updates sidebar and title; folder creation persists; the speaker sheet displays samples, assignment controls and scope. No private conversation was labelled or used to train a profile during UI checks. Profile audio and identity assignments were tested only with the isolated synthetic fixture.

Audio-process probing now runs off the main actor and only when automation is enabled. Search text is indexed on updates and typography regex is reused. Wave scrolling uses a 60 Hz TimelineView between genuine 10 Hz audio measurements. Exact achieved frame rate under load and recognition across real meetings were not benchmarked.
