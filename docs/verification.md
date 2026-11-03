# Проверка Pisya

Проверено 2 ноября 2026 года на Mac с Apple M4 Pro, 24 ГБ памяти.

## Подтверждено

- Сборка Debug и Release для arm64, запуск интерфейса и чтение библиотеки после перезапуска.
- Локальное распознавание специально созданного русского WAV продолжительностью около восьми секунд. Текст совпал с заданной тестовой фразой; модель вернула один речевой сегмент и вектор голоса размерности 192.
- Импорт этого WAV через системный диалог, обработка в приложении, показ текста и сохранение изменённого названия встречи.
- Визуально просмотрены главный экран, демонстрационная встреча, обработанная тестовая запись и настройки записи. Демонстрационные реплики отделены от реальной библиотеки.
- Тесты библиотеки: сохранение/чтение, стабильное имя экспорта, защита от выхода через имя аудиофайла, задержки детектора, запрет повторного автозапуска после ручной остановки, неоднозначные совпадения голосов, типографические пробелы.
- Тесты MCP: handshake, запрет доступа до включения, отзыв доступа в существующей сессии, недопустимый идентификатор встречи. Отдельно проверен собранный исполняемый файл MCP: инициализация и отказ при выключенном доступе.
- Проверены entitlements окончательной подписи: App Sandbox включён; network.client и network.server отсутствуют. Проверка подписи выполняется после добавления помощника MCP и лицензий.
- Локальные копии весов проверены по SHA-256. Аудио и база другого установленного рекордера не использовались.

## Ещё требуется проверить

- Настоящий звонок в Толке с разрешениями macOS: обе дорожки, выключение микрофона, смена гарнитуры, выход из звонка, переподключение и сон компьютера.
- Несколько реальных голосов, одновременная речь и узнавание людей в следующих встречах. Синтетический пример не доказывает качество диаризации.
- Автоэкспорт в пользовательскую папку Dropbox/Obsidian и долговечность разрешения после перезагрузки. Функция генерации Markdown проверена тестом; ручной системный диалог экспорта был отменён, полноценная проверка выгрузки через него не завершена.
- Установка на другой Mac. У сборки нет Developer ID и notarization; модель устанавливается отдельно.

Автозапись, MCP и автоматическая выгрузка по умолчанию выключены. Для просмотра оставлена одна явно помеченная синтетическая тестовая запись. Запись окружающего звука во время разработки не включалась.

Последняя установка выполнена после повторной сборки и проверки подписи. До финальных правок пробелов интерфейс установленной Release-сборки был просмотрен. После блокировки Mac повторный запуск окна не выполнялся; окончательная сборка повторно проверяется командным тестом распознавания.


## Исправление доступа · 0.1.2

- Запрос доступа выполняется до создания встречи; пустой журнал неудачного старта удаляется только при отсутствии файлов и расшифровки. Проверка сохранности существующих данных добавлена в тесты; все 6 тестов проходят.
- В Info.plist добавлена декларация NSScreenCaptureUsageDescription. Перед ScreenCaptureKit выполняется системный запрос CoreGraphics; этап и код отказа пишутся в локальный системный журнал без содержимого встречи.
- Сборка и проверка подписи проходят. Локальная подпись теперь привязана к постоянному сертификату, а не к хешу сборки; сетевые entitlements не добавлены.
- На этом Mac до повторной выдачи разрешения preflight возвращает false. Успешный захват настоящего звонка ещё не подтверждён.

## Universal recording · 0.1.3

Manual capture now records microphone and system audio independently of call applications. The installed build successfully started with Talk closed, stopped after 13 seconds, and completed local transcription of both tracks. Screen capture preflight remained true after the signed update. All 7 tests pass, including waiting before call activity and rejecting short triggers. Real browser-call automatic start/stop, mute, and device switching remain unverified; automation is off by default.

## Live recording meters · 0.1.4

Both tracks now display bounded 72-sample RMS history at 10 Hz, measured only after successful audio-file writes. Per-track counters reflect written sample duration. Silent buffers are distinguished from missing buffers (3-second threshold); absence of system audio is not claimed to prove a capture failure. Eight core tests pass, covering silence, stale data, invalid levels, and bounded history. Release build and signature verification pass. Visually inspected both live waveforms and growing per-track counters in the installed app; a 12-second recording stopped and completed local transcription successfully. The test entry is labelled separately. No network permissions added.

## Library and speaker management · 0.2.0

Ten core tests pass, including legacy JSON compatibility, folders, Trash visibility/restoration, voice example metadata, and voice matching. The packaged app's isolated `--library-self-test` additionally generates synthetic PCM and verifies exact audio-clip extraction, correcting a learned sample, preserving source tracks after renaming, folder moves/removal, Trash/restore, and retaining a saved voice clip after deleting meeting audio. This caught AVAudioFile short reads; extraction now loops until the requested sample count is read.

Installed UI checked: native sidebar selection switches the detail view; right-click menus expose rename/move/voice/Trash actions; rename updates sidebar and title; folder creation persists; the speaker sheet displays samples, assignment controls and scope. No private conversation was labelled or used to train a profile during UI checks. Profile audio and identity assignments were tested only with the isolated synthetic fixture.

Audio-process probing now runs off the main actor and only when automation is enabled. Search text is indexed on updates and typography regex is reused. Wave scrolling uses a 60 Hz TimelineView between genuine 10 Hz audio measurements. Exact achieved frame rate under load and recognition across real meetings were not benchmarked.

## Версия 0.4.3 · 3 ноября 2026 года

- Release arm64 собрана, установлена и проверена строгой проверкой подписи. App Sandbox включён; сетевые entitlements отсутствуют. Файлы пользовательских шрифтов в сборку не входят, интерфейс и счётчики используют системные шрифты macOS.
- 34 теста ядра проходят, включая округление длительности вверх, границу часа, типографические пробелы, сохранение черновика и границы аудиоокон.
- Нативная проверка звука подтверждает подавление синтетического эха при задержках от 0 до 350 мс, сохранение локальной речи при одновременном воспроизведении и точную длительность после преобразования 24/48 кГц.
- Сквозная проверка с локальным распознавателем: системная речь не создаёт микрофонных реплик; тихое «да» сохраняется отдельно, с тишиной в опорной дорожке и на скачке времени. Проверены короткие ответы на границах окон. Два синтетических голоса не дробятся на новых участников при повторении разговора в нескольких окнах.
- Фоновая проверка на растущих CAF длительностью 48 секунд подтверждает черновик до остановки, паузу, восстановление сохранённой границы, обработку только оставшегося хвоста, повторное использование модели и очистку временных файлов. «Четверг» и короткое «да» присутствуют по одному разу. При отмене короткого распознавания проверены ожидание завершения сборщика и освобождение модели.
- Два выбранных 30-секундных фрагмента существующих записей обработаны без изменения исходников и сохранённых расшифровок: новых микрофонных реплик на этих фрагментах нет.
- Через интерфейс записано синтетическое воспроизведение, проверены черновик во время записи и завершение после остановки. Повторная обработка этой тестовой записи дала 6 фрагментов и 2 участников, без ложной микрофонной реплики в начале. Созданная для проверки запись перемещена в восстанавливаемую корзину.
- Визуально проверены основной экран, боковая панель в две строки, округлённая длительность, все четыре вкладки настроек, прокрутка, создание папки, именование голосов, переименование, мини-панель и «О программе». Email отображается синей ссылкой с адресом `mailto:maxim@berezkin.ru`; ссылка не открывалась. Фразы в шапке меняются, название Pisya сохраняет свой цвет.

Ограничения проверки: минимальная ширина окна и длительная тепловая нагрузка не измерялись. При отсутствии подтверждённого системного аудио или безопасной границы непрерывной реплики длиннее минуты черновик может ждать остановки записи. Повтор коротких неоднозначных реплик ориентирован на русский язык; это не гарантия корректного определения языка короткой иностранной речи. Качество эхоподавления зависит от устройств и акустики.
