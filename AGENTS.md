# Правила проекта

## Интерфейс

Все интервалы между заголовками, пояснениями, содержимым, секциями и краями окон берите из `PisyaDesign.Spacing`. Используйте общий `SectionHeading`, а не отдельные случайные интервалы. Проверяйте фактическую вёрстку главного окна, настроек, разметки голосов, редакторов и первой настройки после изменения общих компонентов.

При любом изменении интерфейса проверяйте затронутые экраны визуально в работающей окончательной сборке. Раскрывающиеся блоки проверяйте в обоих состояниях, длинное содержимое — с прокруткой до конца. Между заголовком и связанным текстом должен быть один интервал из `PisyaDesign.Spacing`, без суммирования интервала родительского списка и дополнительных полей дочерних элементов. Успешная сборка не заменяет проверку вёрстки.

У кнопок не должно быть внешней обводки ни при открытии окна, ни после клика, ни при навигации клавишами Tab и Shift+Tab. Системный focus effect должен быть отключён; клавиатурный фокус обозначается изменением заливки, без рамки. Не отключайте клавиатурную доступность кнопок. Перед выдачей проверяйте эти состояния в работающей окончательной сборке, особенно «Готово» в разметке голосов, основные кнопки, иконки и переключатели разделов.

## Завершение работы

После завершения задачи сохраняйте все завершённые изменения этой задачи в Git-коммите до итогового сообщения. Перед коммитом выполняйте проверки, подходящие для изменений. Не включайте чужие или незавершённые изменения. В итоговом сообщении указывайте хеш коммита.

# Interface typography and layout

- Use the system macOS font through `Font.appFont`; use the system monospaced font for counters. Do not bundle SB Sans or reintroduce custom font registration.

- Apply the shared `typographicText` presentation rules to human-readable interface text. Use `screenText`, `screenButton`, `screenLabel`, `screenToggle`, `screenMenu` and `screenHelp` rather than adding an unformatted string label.
- Bind Russian short prepositions, conjunctions and particles to the following word with a nonbreaking space. Bind numbers to units, percentages and month names. Preserve deliberate paragraph breaks.
- Editable values and stored transcripts remain unchanged. Show copyable paths and executable configuration with `screenText(verbatim:)`.
- For every interface change, run the typography regression tests and visually inspect every affected screen, popup and state at the supported window sizes. Check wrapping, truncation, clipping, alignment, spacing and contrast after the last edit. A successful build is not a layout check.
- Preserve the two-line maximum for sidebar items and readable control sizes. Avoid fixing wrapping by shrinking text.
- Round completed sidebar durations up to minutes, then display hours and remaining minutes. Keep live counters and transcript timestamps precise.

# Repository

- Commit and push completed requested changes to `docomoz/pisya`. The public repository is the active source of truth; preserve its history and keep the separate private archive history out of public pushes.
