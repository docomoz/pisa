# Сайт Pisa

Страница находится в `dist/`. Серверная часть сайта размещена в `worker/index.js`: маршрут `/download` читает `pisa-updates.xml` последнего релиза и перенаправляет на указанный в нём DMG. Адрес файла проверяется по домену, репозиторию и номеру версии. Если получить актуальный адрес не удалось, сайт показывает ошибку и ссылку на страницу релиза, не выдавая старый установщик за новый.

Для локальной проверки нужны Node.js 22 или новее:

```sh
npm test
npm run build
npm run preview
```

При сборке `scripts/build.mjs` включает содержимое `dist/` в серверный файл. `dist/server/` и `dist/.openai/` — результаты сборки, они не хранятся в Git.

## Снимки интерфейса

Pisa снимает интерфейс в изолированном режиме на вымышленных данных из `fixtures/meeting.json`. В демонстрационной встрече список участников следует порядку их появления в диалоге. В обычном приложении имена идут по алфавиту.

Запустите команду из каталога `website/`, подставив путь к сборке Pisa.

```sh
/path/to/Pisa.app/Contents/MacOS/Pisa --website-screenshots "$PWD/fixtures/meeting.json" /tmp/pisa-website-screenshots
```

Команда сохраняет два файла, `transcript.png` и `welcome.png`. Скопируйте их в каталоги сайта и документации.

```sh
cp /tmp/pisa-website-screenshots/transcript.png dist/assets/meeting.png
cp /tmp/pisa-website-screenshots/transcript.png ../docs/images/transcript.png
cp /tmp/pisa-website-screenshots/welcome.png dist/assets/welcome.png
cp /tmp/pisa-website-screenshots/welcome.png ../docs/images/welcome.png
```
