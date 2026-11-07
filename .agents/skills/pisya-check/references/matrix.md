# Матрица регрессий Pisya

Дата составления: 8 ноября 2026 года. Исторические успешные проверки не дают
текущий PASS. Доказательства и незакрытые хвосты — в [источниках](history.md),
существующие команды и ограничения — в [каталоге](commands.md).

## Выбор режима

- **daily** (по умолчанию): все D, полный core suite, локальные тесты сайта,
  окончательная нативная сборка и основные UI-маршруты. Добавь все T, затронутые
  изменениями после последнего проверенного снимка. Если его нет — сравни с
  ближайшей известной стабильной ревизией и укажи неопределённость.
- **full**: D + W + все T; расширенный UI, модели, экспорт, MCP, аудиокорпус.
  Полный корпус ограничь заранее: список случаев/встреч, режимы, ожидаемые
  проверки и предел времени. Не запускай всю личную библиотеку.
- **release**: full + R. X включаются, когда есть согласованный тестовый сеанс
  и данные; при отсутствии обязательного для выпуска подтверждения — BLOCKED.
  Выбор режима release сам по себе не поручает установку или публикацию.

**T** — по изменению поведения, зависимостей или общего компонента; **R** — выпуск;
**W** — расширенный прогон; **X** — отдельно согласованный аппаратный/реальный сценарий.
Совмещённые метки означают объединение условий, а не требование их одновременности.
Если D/W/T/R уже делает сценарий обязательным, отсутствие условий X
блокирует его, а не исключает из обязательного охвата. Единственное исключение
для действия вне аудита — PKG-03: установка обязательна только по отдельному
поручению пользователя; иначе NOT RUN вне обязательного охвата.
При изменении распознавания ASR-02…10 и REC-05 обязательны: оба канала,
live и batch, отрицательные примеры, clip/replay и полный производственный путь
раздельно. При изменении оформления/ввода — все потребители общего компонента.
При merge — сверка ранее завершённых функций, включая отсутствующие в этой ветке.

**A** — автоматическая проверка; **V** — фактический просмотр работающего приложения;
**P** — физическая клавиатура; **M** — реальные модели/аудиопроцесс.
Если строка требует A и V, одного A недостаточно для PASS. В отчёте можно разделить
её на подслучаи, сохранив родительский ID и отдельно показав непроверенное.

Общая UI-сетка: обычный и минимальный размер окна, 100% и 120% текста;
в full и после правок ввода/типографики также 110%. Для каждого поля снимки
focus/blur при неизменной геометрии. Открытые/закрытые секции, пустые/длинные
списки, верх и конец прокрутки — отдельные наблюдаемые состояния.
Фиксированные размеры 980 × 660 и 1200 × 800 — доступные preview-фикстуры,
а не неизменный контракт размеров продукта: сверяй актуальные minSize.

Изолированный тихий preview допустим при текущей обработке, если не открывает
пользовательский контейнер и не мешает ей. Аппаратный захват, звук и тяжёлый ASR
могут быть заблокированы отдельно. Ни одна строка не разрешает прерывать запись.
Идентификаторы H в последнем столбце раскрыты в history.md; они не требуют
перечитывать архив при каждом запуске.

| ID / частота | Действие и ожидаемый результат | Автоматизация / обязательное доказательство / источник |
|---|---|---|
| ENV-01 D | Зафиксировать branch/HEAD/status/submodule, установленную и целевую app, OS/модели; определить занятые запись/очередь и грязное дерево | A read-only manifest. HEAD+dirty fingerprint+app hash. H140–158; docs/verification |
| ENV-02 D/R | Сравнить завершённые коммиты всех актуальных веток с целевой сборкой; сохранить Updates, Import label/icon, header phrases, фразы, MCP, analytics, Terms/Voices | A git ancestry/diff + V feature smoke. Не считать «больше version» доказательством свежести. H290,383,396; git `c34cddb`, `25567fe` |
| ENV-03 D | Запустить unit suite и design checker единожды; сохранить полные exit/result и число фактически выполненных тестов | A `swift test`, `python3 scripts/check-design-system.py`. Не hardcode 342/355. Состав тестов зависит от выбранного снимка |
| ENV-04 D | Сделать изолированную проверочную библиотеку с фикстурами, проверить отсутствие ключа preview в обычном app, записать changed resources re-sign | A manifest V check; бинарное сравнение с учётом signature. docs/design-system/verification |
| UI-01 D/T | Пройти main/welcome/transcript/settings/voices/terms/editors/setup/mini-panel: 980×660 и 1200×800, широкий монитор, обычный и увеличенный текст | V экранные снимки и проверка фактических переносов; это общая матрица состояний для UI-02…12. H30,33,41,187; AGENTS |
| UI-02 D/T | Заголовок/пояснение/content имеют один интервал из Spacing; раскрыть/свернуть ограничения автозаписи, сменить tabs, прокрутить вниз | A design checker + V оба состояния. Нет суммирования child padding + parent gap; scroll reset при смене раздела. `ee2aca2`, AGENTS |
| UI-03 D/T | Все роли body/supporting/code/button применяются едино; строки не получают чужой lineSpacing; paths/config системный monospace меньшего кегля | A checker + V. H32,33,40,49–53; docs/design-system |
| UI-04 D/T | Ни один button/icon/tab/checkbox не получает внешнюю focus рамку на open/click/Tab/Shift+Tab; focus виден заливкой, keyboard доступность сохранена | V+keyboard, особенно «Готово», primary, folder, permissions, dialogs. H30,47; AGENTS |
| UI-05 D/T | Все однострочные поля, placeholder, search и multi-line editors не смещаются при focus/blur, Tab/Shift+Tab, обычном/крупном тексте | V скрины до/после с одинаковой геометрией, включая системный participant-name route если достижим. H182,189,250–252; `202bf3b`,`c3f9bc1` |
| UI-06 D/T | Реальный ввод/⌘A/delete/copy/paste, изменения после unfocus там где нет submit; explicit submit/Enter и cancel где предусмотрено | V+P отдельно от AX/typeText; single/search/multiline, idle и другая обработка. H1,195–209. OPEN physical bug |
| UI-07 D/T | Активные/disabled actions различимы; на green primary white text; disabled не выглядят активными, hover/press/focus не меняют размеры | V. H26,27,54,55,88; design-system |
| UI-08 D/T | Короткие предлоги защищены точечно, естественное заполнение строк, единая leading; нет лишних forced breaks/цепей NBSP, clipping/orphans | A Core typography tests + V в разных размерах. Пользовательские forced breaks сохранять. AGENTS; H228,411,412 |
| UI-09 D/T | Пунктуация одиночного текста/нескольких предложений и абзацев, логика «…», женский род Pisya, без случайных middle dots | A string review + V всех алертов/updates; AGENTS важнее раннего H222. H28,94,270,390,410 |
| UI-10 D/T | Topbar выровнен с sidebar search, baseline icon/text/time, бренд использует доступную ширину, import текст остаётся видимым даже при записи | V min/wide+recording. H86,290,297,387,395; `c34cddb`,`3d260ca` |
| UI-11 D/T | Settings tabbar не меняет ширину на selection, permission icon insets сбалансированы, mini-panel и levels popover компактны без clipping | V, сравнение off/on screenshots; H298,366,374; `828cc2b`,`530ec41`,`c7c61cf` |
| UI-12 D/T | Все кликабельные product controls/menus показывают pointing hand; labels speakers не превращаются в дублирующие кнопки | V мышь по button/icon/card/menu, noninteractive не clickable. H60,266–267; `41ab037`,`d9d7f2c` |
| MENU-01 D/T | Status menu open без selected row при pointer снаружи; слева выровненные native rows, start neutral, toggle узнаваем и checkbox виден на highlight | A `run-status-menu-test.sh` под GUI lease + V. H16–25,63,125 |
| MENU-02 D/T | Вести мышь через строки и separators; toggle auto on/off не закрывает меню, не меняет геометрию и не теряет hover при неподвижном pointer; restore setting | A menu probe + V real mouse. Не записывать нажатие auto в production preference. H17,21–25 |
| MENU-03 D/T | Details/More/Share/sidebar context menu едины; mouse opening без преждевременного focus highlight, Tab/Shift+Tab даёт fill; нет дубликатов actions | V. Trash/Delete audio снизу после separator; ellipsis по действию. H123,286–289,368,388–390,418 |
| MENU-04 D/T | Secondary click выделяет именно строку под pointer, включая край строки/после scroll; context action работает на ней, не соседней | V набор минимум 3 rows/scroll. H132–133; `fd4dbbb`,`0a8df6c` |
| KEY-01 D/T | ⌘Q при settings/voices/terms/confirmation/own sheets на RU и EN; guard записи/обработки не обходится; после cancel sheet жив | A `run-quit-shortcut-test.sh` + V final app; не убивать production process. H223,392; `2c25612` |
| KEY-02 W/T | Отдельно ⌘Q в системном import/save NSOpenPanel/NSSavePanel; не экстраполировать own sheet | V на isolated app; известное NSOpenPanel исключение, новый результат обязателен |
| KEY-03 D/T | ⌘+/− меняет размер текста, reset работает, control/window сохраняют доступность; titlebar double-click zoom и restore | V с typing focus и без. H398,417; `841ff59`,`fab7fa0` |
| REC-01 D/T | Idle→recording/live→saved finalizing→ready, batch→queued→processing/cancel→resume; status точный, прогресс проценты/этапы где известны | A LiveTranscriptionScheduleTests + V fixture transitions, не запись окружающего звука. H67,80–85,95,118,186–190,375–376 |
| REC-02 D/T | Во время live компактная панель, спокойный статус; до готовности скрыты лишние controls/search, Share draft недоступен; old transcript dim при rerun | V 980×660. `615e51c`,`ea387b7`,`46338cf`; H67,88,187,190 |
| REC-03 D/T | Отменить queued item, очередь/иконка sidebar обновились; resume стартует с checkpoint, reprocess с нуля; cancel не удаляет аудио | A `--queue-self-test`, schedule tests + V. Команду и её isolation сверить в Launcher перед запуском |
| REC-04 D/T | Снимок растущей CAF использует опубликованные frames/offsets; Float32/Int16; failed partial copy убран | A `run-capture-window-test.sh` и Core timeline tests. Микрофон не открывает |
| REC-05 W/T | Live draft появляется до stop, pause/recover/tail не теряет/не повторяет короткое «да», stale completion не двигает cursor; models reuse/free | A/M `--live-pipeline-test` с готовой fixture; LiveTranscriptionScheduleTests. docs/verification |
| REC-06 W/X | Настоящий звонок: обе tracks, mute, headset/device switch, reconnect/end/sleep, manual before call; отсутствующий buffer ≠ silence | V/M real devices только согласованный сценарий, wave/count/logs/audio references. docs/verification backlog, Core detector/meter tests |
| REC-07 D/T | Core Audio taps захватывает только audio, не screen image; permission flow корректен, привычный auto-rec off на новой установке, debounce/manual-stop | A Core detector + source review; X actual permissions/call. H62; README; `ba75836` |
| DATA-01 D/T | CRUD folder/meeting, trash/restore/purge; запрещены traversal/symlink чужого пути; shared audio/voice samples не удаляются | A CoreTests и `--library-self-test` на synthetic/temp library. docs/verification |
| DATA-02 D/T | Название редактируется во время recording/processing и сохраняется; Empty Enter→«Созвон»; manual title не заменяется auto после ASR/restart | A MeetingTitleTests + V live-state fixture. H90–92,367; `913daed`,`56c7d46` |
| DATA-03 W/T | Permission wait держит вычисленный transcript, после unlock reread свежих метаданных; cancel и обычные ошибки не бесконечны | A ProtectedFileReadTests + X настоящая блокировка isolated workflow; OPEN real lock verification. Не ослаблять защиту файлов |
| DATA-04 D/T | Audio availability различает сохранено/частично/нет; deleting meeting audio не удаляет saved voice; import source остаётся на месте | A TranscriptEvidenceTests/CoreTests + V status/actions. H70–71; README |
| DATA-05 W/T | Автоexport в датированную папку, metadata/notes/speakers/time верны, rename/timezone без дубля/чужого overwrite; trash удаляет только owned export | A Core export tests + V isolated selected folder/restart; реальная синхронизируемая папка лишь отдельно. H108–114 |
| DATA-06 W/T | Share Transcript .md и Audio .m4a; correct enabled state; mic/call смешаны с offset, длительность/тишина/пики разумны, cancel без лишних файлов | A code/fixture checks + V save dialogs + M выборочное прослушивание. H289; `f56e820` |
| VOICE-01 D/T | До выбора фрагмента right pane «Выберите…»; максимум 2 длинных sample/voice; rename не переставляет группу; replay сохраняет draft имени | A VoiceSampleSelectionTests/CoreTests + V. H45–46,59,126; `522745b`,`ed42e7d` |
| VOICE-02 D/T | Вся fragment card запускает/останавливает play, имя selectable dbl/triple click/copy; suggestions existing saved+meeting без duplicates; Return=apply | A suggestions tests + V/P; не просто setValue. H73,245,386; `fbb7447`,`2ca50fc` |
| VOICE-03 D/T | Settings Voices пусто/12 людей/длинное имя/no sample/много sample: одна основная кнопка + «Ещё N», выбранный sample становится primary; scroll last focus | A `--voice-profiles-self-test` + V playback/menu large text. H34–35,224; `66bab31` |
| VOICE-04 W/T | Rename/delete saved profile сохраняет ID/старые transcript names; duplicate/empty reject; delete cancel; write failure не удаляет profile/audio; другой sample intact | A VoiceProfileTests + V isolated library. docs/verification saved voices |
| VOICE-05 W/T | Auto clean sample не захватывает другого/overlap, offsets/missing audio handled; self label green независимо от имени, другие black; preview loudness balanced без изменения originals | A VoiceSampleSelectionTests + V/M сравнение track previews. H37–39,61,372–373; `0d271f3` |
| VOICE-06 W/X | Реальные speakers across meetings, overlap/duplicate attribution: не учить неверный профиль, не переносить старые имена только по времени | M заранее выбранный corpus + manual truth. OPEN real quality / full-run anomalies |
| TERM-01 D/T | Candidate/manual search, select only chosen occurrences, preview=apply, metadata/source/time неизменны, undo, no-op/stale ranges отклонены | A TranscriptTermsTests/AbbreviationFamiliesTests + `--term-review-self-test`; V last occurrence/scroll/persistence. H218–221; `e45e8b8`,`7a182b1` |
| TERM-02 D/T | После correction selection/search results не пропали; base search finds all family, full-form literal; каждое ending сохранено; add base один раз | A tests + V spellings/inflected forms/reopen. `42513d1`,`7a182b1`; docs/verification |
| TERM-03 D/T | Словарь: пусто/длинный список/поиск без результата, счётчики, одна запись и пакет с предварительным просмотром, дубли/ошибки, точное написание/ё, изменение/удаление/отмена. «Показать запись» раскрывает скрытое поиском добавление; stale preview и ошибка записи не дают частичного сохранения | A VocabularyDictionaryTests, RecognitionVocabulary/SpokenVocabulary, `--dictionary-self-test` при наличии. V основной экран и оба вложенных окна при 100/110/120%, focus/blur/Tab, длинный пакет до конца, перезапуск. `44c2444`, TERM-01/02 |
| ASR-01 D/T | Орфография: русские fillers и mixed chains, «ё» с явным словарём, 75%, за $37, abbreviation endings apostrophe, идея-фикс; display first letter uppercase | A BackchannelLanguage/TranscriptOrthography/TranscriptDisplay/Core tests. AGENTS; H301,305–321,340,348 |
| ASR-02 W/T | На обоих каналах с заполненным словарём real EN sentences/quotes/code/URLs/numbers/explicit names остаются нетронуты; unknown context не переводится | A tests + M quality corpus негативные случаи. Не blanket replace всех English слов; AGENTS |
| ASR-03 W/T | Словарь помогает mic И remote; numeric/mixed scripts/pronunciation/endings, только услышанные формы; не достраивать ending по grammar | A RecognitionVocabulary/SpokenVocabulary/AbbreviationFamilies + M native quality. H43,166–179,220–221 |
| ASR-04 W/T | Prompt echo (весь словарь/хвост/пропуски/середина) вызывает bounded unprompted retry на исходном audio, не удаление реальной речи; реальный список сохраняется | A RecognitionPromptEchoTests + M silence/noise/echo. H329,335; AGENTS |
| ASR-05 W/T | Speech boundary ~24с/long/short/pauses/near limit/overlap: каждый audio sample один раз, short «да/нет/угу» не теряется, no hallucination on noise | A SpeechChunking/SpeechCoverage + M quality script/live pipeline. docs/verification 5 ноября |
| ASR-06 W/T | Echo обычный/double talk/quiet near/delay clock jump, original tracks retained, only prepared tracks production; не downgrade к raw mic ради passing clip | A Core echo + M `--audio-pipeline-test`,`--echo-regression-test`,`--speech-pipeline-test`. Исторический FAIL clock jump учесть отдельно; текущий FAIL только после воспроизведения |
| ASR-07 W/T | Context nearest committed same meeting/track order/time bounds; соседняя реплика даёт anchor но не меняется; конкурирующие initials/quotes/numbers сохранены | A RecognitionContext/RussianRecognition/Consensus/TimedWords/AudioFocus tests + M selected audio; H343,346–347,351 |
| ASR-08 W/T | Синтетический пакет + фиксированный real corpus обе tracks/live+batch; сравнить per-case и WER, число терминов, short acknowledgments, отрицательные контроли | M `run-vocabulary-test.sh`, `run-recognition-quality-test.py --corpus`; фиксировать revision/config/normalization. WER одной маленькой выборки ≠ accuracy всех встреч |
| ASR-09 X/T | Полная встреча через production pipeline на копии: реальные chunk/AEC context отличаются от clip/replay; проверить tail/gaps/duplicates/speaker labels и исходные SHA | M bounded full corpus, не всю библиотеку ежедневно. Локальный отчёт из history.md; исторический результат, клип PASS не закрывает full case |
| ASR-10 T | Исправление общей причины: нет whole-phrase substitution эталона, prompt hint не считается независимым acoustic evidence; ambiguous disagreement остаётся неизменным | A diff review + negative tests + M replay/full distinction. AGENTS; H343; `62f76ba` |
| TITLE-01 W/T | Auto title только completed nonempty; конкретная тема/повестка/follow-up, 8 слов/80 символов, RU/EN без иных writing systems, no reasoning; long tail учитывается | A MeetingTitleTests + M `--meeting-title-self-test`/smoke на isolated library. H58,183–185; docs/verification |
| TITLE-02 W/T | Cancel/failure/load missing model не меняет meeting/transcript/manual name, memory policy restored, следующая генерация успешна | A/M native title fixture + restart proof. Не требовать exact title string для stochastic generation |
| MCP-01 D/T | Process handshake и 5 tools с открытым stdin без buffering; list/read/search/context/filters/pagination, no unrequested content | A MCPTransport/MCPContext/MeetingSearch + packaged helper process isolated fixture. H369–371; docs/mcp |
| MCP-02 D/T | Fresh default enabled; прежний disabled сохранён; revoke в открытой сессии; trash excluded; bad args/dates не расширяют scope | A Core/MCPContext tests + helper session. H56,94; README |
| MCP-03 D/T | Unreadable prefs→JSON-RPC protocol error для tools/list, tool-call isError; corrupt JSON→generic message; no private paths; TCC actionable permission | A MCPContext tests + failure fixture; `8bd7015`; docs/verification |
| MCP-04 W/T | Source URL действительно clickable в целевом клиенте → нужная реплика highlight/play; exact/fallback/shared boundary/missing audio/trash/malformed URL | A TranscriptLinkTests + `--source-link-self-test`; V real client and final app. H423 «не ссылается»; fixtures only |
| MCP-05 D/T | Draft/incomplete/unknown confidence/audio coverage не объявлены verified/whole; original quotes preserved, folder/speaker/date boundaries/timezone валидны | A TranscriptEvidence/MCPContext tests; прочитать сериализованный output, не только object unit |
| MCP-06 W/T | Connected actual client отдельно от helper: обнаружены все методы, запросы выполняются, current chat catalogue проверен после reconnect | V/tool invocation; старая/отдельная сессия не доказательство текущей. H102–104; docs/verification |
| MODEL-01 W/T | First setup missing/valid/custom Qwen/invalid bookmark/missing diarization+Russian model; cancel/retry/HTTP503/no space/hash/path/symlink | A ModelInstaller/NativeModelDownload + `--model-setup-self-test`; V setup initial/progress/error/ready. docs/verification |
| MODEL-02 R/W | Signed app small real network smoke; pinned revisions+SHA, license/resources/Metal dylib bundled, no Homebrew/local dependency | A `--model-download-smoke-test`, signature/otool/package inspection; M smoke. Network action объявить; cache reuse |
| MODEL-03 R/X | Чистая установка из DMG→download→import synthetic→transcript+192 vector→restart без redownload и изменения meeting | A manifest/hash + V/M isolated app+container. H6; docs/verification E2E. Full 3GB не каждый день |
| PKG-01 R | Build final Release, strict code signature app+DMG, DMG verify, resources/helper/licenses, native UI packaged app verified | A build script+codesign/hdiutil; V Finder DMG app/Applications/instruction/geometry. Проверять актуальный signing, не обещать notarization |
| PKG-02 R | Version/build растут по коммиту, native updater присутствует; appcast signature/URL/version match; prior build offers target; cancel/idle rules | A актуальные release tools только если есть в выбранной ветке + V isolated old/new. H147–148,396–397; не изобретать absent command |
| PKG-03 R (условно) | Только при отдельном поручении установить приложение, иначе NOT RUN вне обязательного охвата. Install: дождаться idle, backup, один app process, executable/resources matches verified source, launch existing data intact | A before/after provenance + V smoke. Никакой автоматической установки в обычном audit; H142–154 |
| PRIV-01 D/T | Telemetry allowlist только events/rounded duration/install hash/version; no audio/text/names/paths/glossary/errors; optout stops+clears queue, tests telemetry off | A UsageAnalyticsTests+source/data flow review; V optout, isolated fixture capture not production counter. docs/analytics |
| PRIV-02 W/T | Network delivery/retry/expiry и actual dashboard arrival учитываются раздельно; delayed dashboard не instant FAIL; одна page_view на лендинге | A/mock + explicit test-mode delivery if in scope. `fbd69ae`,`14b3ef9`; не утверждать delivery по успешной сборке |
| PHRASE-01 D/T | 🤦 open/refresh/copy/close focus/long text; no immediate repeats/sequence repetition; прочитать sample корпуса на grammar, естественные бессмысленные manager вбросы | A MeetingPhrasesTests + V и editorial sample. Не exact philosophical полезные советы; H211,254–265; история корпуса: `c1f5cb9`; текущий состав определить заново |
| SITE-00 D | Выполнить локальные тесты сайта: статика, скачивание при отказе API, аналитика без дублей; проверить актуальность локальных ссылок | A `npm test --prefix website`, полный вывод и код завершения. Browser/delivery проверяются отдельно в SITE-01…03 и PRIV-02 |
| SITE-01 T/R | Лендинг desktop+mobile min/typical/wide, все sections/final bottom, natural wraps/baselines/no overflow/forced breaks, punctuation latest rule | V real browser screenshots widths; static checks only auxiliary. H191,228–229,409–412 |
| SITE-02 T/R | Current download ведёт на актуальный DMG при API limit; actual browser download; title for Mac, Telegram contact, Github link, актуальный feature/copy/screenshot | A link/assets + V browser. H281,227,229,242–243; fixture screenshots без личных встреч/cursor/system capture icon |
| SITE-03 T | White background и лёгкая animation final choice, reduced-motion/readability; screenshot full app sidebar current UI, curated fiction; app Liquid Glass не возвращается | V. H128–129 app revert `11ac771`; H296 site white supersedes earlier waves/glass. Не смешивать истории сайта и app |
| DOC-01 T/R | Выдаваемые fixed documents рендер всех страниц, typography/metadata creator cleanup; README/screenshots соответствует текущему app и не changelog вместо overview | A package metadata + V final rendered artifact; global AGENTS/H13–15. Только когда документ создан/обновлён |
| AUDIT-01 D | Проверить coverage report, provenance, все mandatory IDs имеют evidence или честный blocker; один defect group на общую причину, нет repeated rerun без cause | A report validation + независимый review coordinator. H362 «по кругу» |
