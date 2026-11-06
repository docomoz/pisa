# Выпуск Pisya

DMG для Apple Silicon, подписанный список обновлений Sparkle и контрольная сумма публикуются вместе в GitHub Releases. Homebrew устанавливает тот же DMG через [docomoz/tap](https://github.com/docomoz/homebrew-tap). Встроенное обновление работает для обоих способов установки.

## Подготовка версии

1. Увеличьте `CFBundleShortVersionString` и `CFBundleVersion` в `Resources/Info.plist`. Sparkle определяет порядок версий по `CFBundleVersion`.
2. Напишите заметки к релизу в Markdown. Их увидят в GitHub и в окне обновления Pisya.
3. Соберите DMG и подготовьте файлы для загрузки, подставив новую версию в имя образа.

   ```sh
   ./scripts/build.sh
   ./scripts/prepare-release.sh build/Pisya-0.4.4-arm64.dmg /path/to/release-notes.md
   ```

   В `build/release-v0.4.4/` появятся готовый DMG, `appcast.xml`, `SHA256SUMS` и описание Homebrew `pisya.rb`. Загружайте эту копию образа. Подпись и контрольная сумма вычислены для её байтов.

Для подписи нужен закрытый ключ Sparkle из локальной связки ключей с именем аккаунта `pisya`. Скрипт сверяет его открытый ключ с ключом внутри DMG. Для резервной копии используйте `generate_keys --account pisya -x /path/to/private-backup` из `build/SourcePackages/artifacts/sparkle/Sparkle/bin/`. Храните копию в защищённом месте. Ключ из резервной копии можно импортировать через `generate_keys --account pisya -f /path/to/private-backup`. Сохранение того же ключа позволяет установленным копиям получать следующие версии.

## Публикация

1. Загрузите коммит в GitHub и создайте черновик релиза. Укажите точный коммит сборки и добавьте три файла.

   ```sh
   gh release create v0.4.4 --draft --target COMMIT --title "Pisya 0.4.4" \
     --notes-file /path/to/release-notes.md \
     build/release-v0.4.4/Pisya-0.4.4-arm64.dmg \
     build/release-v0.4.4/appcast.xml build/release-v0.4.4/SHA256SUMS
   ```

2. Когда релиз готов, опубликуйте его как обычный релиз и отметьте как **Latest**. По адресу `releases/latest/download/appcast.xml` Pisya получает список обновлений текущего релиза. Предрелизы можно распространять через их собственные страницы.
3. Проверьте загрузку DMG из GitHub и «Проверить обновления…» в предыдущей версии с поддержкой Sparkle. Для перехода со старых сборок без Sparkle потребуется один раз установить новую версию вручную.
4. Скопируйте сгенерированный `pisya.rb` в `Casks/` репозитория tap, проверьте `brew audit --cask --strict --online docomoz/tap/pisya` и опубликуйте изменение. Строка `auto_updates true` сообщает Homebrew, что Pisya сама устанавливает новые версии. Для принудительного обновления через Homebrew используйте `brew upgrade --cask --greedy docomoz/tap/pisya`.
