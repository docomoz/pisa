# Перенос встреч из Pisya в Pisa

Повторите эти шаги на каждом Mac под своей учётной записью. Вместе с аудио и расшифровками скопируются папки, словарь, сохранённые голоса и загруженные приложением модели.

Если Pisa ещё не установлена, по [инструкции по установке](https://getpisa.app/#install-guide) выполните только шаги 1 и 2, затем вернитесь сюда до первого запуска Pisa и продолжите перенос.

1. Дождитесь окончания записи и расшифровки в Pisya. Закройте приложение через ⌘Q.
2. Если в Pisya была отключена анонимная статистика, перенесите только этот переключатель перед первым запуском Pisa. Если Pisa уже запускали, сначала закройте её через ⌘Q. В Терминале выполните блок ниже. Он читает только переключатель из настроек Pisya и переносит явный отказ, если в Pisa ещё нет сохранённого выбора. Аудио, расшифровки и другие данные не читаются.

   ```sh
   old_prefs="$HOME/Library/Containers/com.docomoz.pisya/Data/Library/Preferences/com.docomoz.pisya.plist"
   new_container="$HOME/Library/Containers/com.domocoz.pisa"
   new_prefs="$new_container/Data/Library/Preferences"
   new_plist="$new_prefs/com.domocoz.pisa.plist"
   if [ -f "$old_prefs" ] \
     && /usr/libexec/PlistBuddy -c 'Print :usageAnalyticsEnabled' "$old_prefs" 2>/dev/null | grep -qx false; then
     if [ -d "$new_container" ]; then
       mkdir -p "$new_prefs"
       if ! /usr/libexec/PlistBuddy -c 'Print :usageAnalyticsEnabled' "$new_plist" >/dev/null 2>&1; then
         defaults write "$new_prefs/com.domocoz.pisa" usageAnalyticsEnabled -bool false
       fi
     elif ! defaults read com.domocoz.pisa usageAnalyticsEnabled >/dev/null 2>&1; then
       defaults write com.domocoz.pisa usageAnalyticsEnabled -bool false
     fi
   fi
   ```

3. Установите Pisa, откройте её один раз и закройте через ⌘Q. Сделайте это до первой записи в Pisa. Это создаст папку данных приложения.
4. В Finder нажмите ⇧⌘G, вставьте путь ниже и нажмите Enter. Выделите папку **Pisya** и скопируйте её через ⌘C.

   ```text
   ~/Library/Containers/com.docomoz.pisya/Data/Library/Application Support/
   ```

5. Через ⇧⌘G откройте новую папку. Переименуйте существующую **Pisa** в **Pisa-before-migration**. Если в Pisa уже есть новые встречи, остановитесь и сохраните обе библиотеки отдельно.

   ```text
   ~/Library/Containers/com.domocoz.pisa/Data/Library/Application Support/
   ```

6. Вставьте копию через ⌘V. Переименуйте вставленную папку **Pisya** в **Pisa**. Запустите Pisa и проверьте, что открываются прежние встречи, видны расшифровки и воспроизводится звук.

При первой записи выдайте Pisa разрешения на микрофон и системный звук. Выберите заново внешнюю папку моделей или папку экспорта Markdown, если пользовались ими. Для Codex возьмите новую конфигурацию в разделе MCP в настройках Pisa. Старые ссылки `pisya://` открываются в прежнем приложении.

Сохраните старое приложение и его папку данных, пока не проверите копию.
