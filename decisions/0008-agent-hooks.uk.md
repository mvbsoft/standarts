# D-0008. Хуки перевіряють у контейнері й ніколи не мовчать

> Українська · [English](0008-agent-hooks.md)

**Статус:** прийнято · **Дата:** 2026-10-18 · **Правила:** AI-05, AI-06

## Контекст

Хук після правки, який шукає лінтер на хості, нічого не знаходить і тихо виходить, змушує агента вірити, що файл перевірено.

## Рішення

Хук PostToolUse запускає інструменти в dev-контейнері; якщо не може їх запустити, пише `check NOT run: <reason>` у stderr і виходить з кодом 2 (обов'язково). Хук PreToolUse блокує мовні інструменти на хості й називає ціль `make` або команду в dev-контейнері, яку запустити натомість (рекомендовано). Перевірки — це `sh`-скрипти з `templates/agent-hooks/`, що не залежать від жодного агента: `check-file.sh <файл>` і `check-command.sh '<команда>'` приймають звичайні аргументи й відповідають кодом виходу 2 та причиною в stderr. Команди кожної мови вони беруть з файла проєкту `.claude/hooks/checks.conf`. Claude Code доходить до них через два тонкі адаптери, `post-edit.sh` і `pre-bash.sh`, які читають JSON хука через `awk` (на хості немає інструмента для JSON) і викликають перевірку; інший агент пише свій адаптер, а перевірки лишаються. Хуки працюють з `"onFailure": "block"`, тож хук, який не може запуститися, теж блокує, а не пропускає виклик. Matcher хука PreToolUse — `Bash`: інструмент PowerShell у Claude Code не покритий.

## Розглянуті варіанти

- **Хуки на хості.** Порушує PRN-01 і перевіряє з іншими версіями бібліотек.
- **Без хуків, лише ворота.** Помилки видно пізно, наприкінці задачі.
- **Правила дозволів одного агента (`permissions.deny`) замість скрипта PreToolUse.** Правило жило б у налаштуваннях одного інструмента, а інші агенти його б не бачили; скрипт лишається.
- **Сам агент усередині dev-контейнера.** Хуки викликали б інструменти напряму, і шлях «check NOT run» не був би потрібен. Не обрано з причин із [D-0005](0005-language-servers.uk.md): облікові дані агента й робоче дерево з правом запису опиняються всередині контейнера, а в dev-контейнері немає власного Docker. Проєкт, якому це потрібно, записує його як відхилення у своєму реєстрі.

## Наслідки

Агент завжди знає, чи перевірено файл. Код виходу 2 у PostToolUse лише повідомляє; скасувати правку він не може. Команду, виконану через інструмент PowerShell на Windows, хук PreToolUse не перевіряє, і AI-06 це прямо каже.

## Перевірено

Перевірено 2026-10-19, Docker Engine 29.7.2 (Docker Desktop, WSL 2), Compose v5.5.0, git 2.43.0, GNU awk на хості; dev-образи з python:3.12.13-slim@sha256:229a2c5bfa27522db7815ea81f9bed70af17ccb9de9fc7ad142b1877b5830d36, php:8.2-cli (PHP 8.2.33)@sha256:0ca296c0ae905940c0a333a15de437f3acaa81743333a9437221f6a44e3f0981, node:22-bookworm-slim (Node.js 22.23.3)@sha256:c3de60bf2f9dd0ac6370e6117950ff62d6e339527e7472301c9c78a017978392 і composer:2 (2.10.3)@sha256:af98f42dfff7c68ba8d53c2164fd9fde1087b7d449514baa38c418b1f6bc4bac.
- Хук після правки отримує JSON, описаний у довіднику хуків, і перевіряє в dev-контейнері: `tests/stacks/run.sh` (`make check-stacks`) на зразках Python (ruff 0.17.1, pyright 1.1.414), PHP (php-cs-fixer 3.95.27, phpstan 2.3.1) і TypeScript (prettier 3.9.10, eslint 10.13.0); чистий файл — вихід 0 без виводу за 0,9–4,4 с; помилка лінтера — вихід 2 за 1,0–1,6 с (повторний запуск 2026-10-21 після відокремлення перевірок від адаптерів, agent-hooks 1.1.0) з повідомленням лінтера в stderr (ruff `F401`, phpstan `Function undefined_function not found.`, eslint `@typescript-eslint/no-unused-vars`); pyright ще й повідомляє про помилку типів у цьому одному файлі; файл, який не названо в жодному рядку `check`, — вихід 0.
- Перевірки працюють без адаптера будь-якого агента: той самий тест викликає `check-file.sh` і `check-command.sh` зі звичайними аргументами, з іншої теки й без `CLAUDE_PROJECT_DIR`, і отримує ті самі коди виходу й повідомлення (чистий файл 0, помилка лінтера 2, `npm install` 2 з командою для dev-контейнера, `git status` 0); довга команда йде в `check-command.sh -` через stdin.
- Хук після правки ніколи не мовчить: із зупиненим dev-стеком (`make down`) і з інструментом `check`, якого немає в dev-образі, він виходить з кодом 2 і `check NOT run: <reason>`.
- Хук pre-bash блокує мовні інструменти на хості: той самий тест; `npm install`, `python x.py`, `cd src && npx eslint .`, `FOO=1 composer install`, `sh -c 'pip install x'`, `./node_modules/.bin/vitest`, `vendor/bin/phpunit` і `echo $(php -v)` — вихід 2 з командою для dev-контейнера; `git status`, `make gates`, `make dev && make gates`, `docker compose -f docker-compose.dev.yml exec -T dev npm test`, `ls -la | grep python`, `cat README.md` і `git commit -m` зі згадкою npm — вихід 0 без виводу; рядки `allow` і `block` у `checks.conf` працюють. У разовому запуску поза тестом скрипти поводилися однаково з GNU awk, mawk і busybox awk (37 форм команд).
Не перевірено: справжня сесія Claude Code (`claude` немає в PATH у WSL, і його не встановлювали): те, що Claude Code показує агентові stderr виходу 2, запускає exec-форму `sh <скрипт>` і виконує `"onFailure": "block"` (v2.1.295 або новіший), спирається на цитати нижче. Хост Windows без WSL (шляхи зі зворотними похилими рисками; інструмент PowerShell, якого не покриває matcher `Bash`).

## Джерела

- <https://code.claude.com/docs/en/hooks> — “`PostToolUse` | No | Shows stderr to Claude; the tool already ran”
- <https://code.claude.com/docs/en/hooks> — “`PreToolUse` | Yes | Blocks the tool call”
- <https://code.claude.com/docs/en/hooks> — “To surface a warning to Claude from a `PostToolUse` or `PostToolUseFailure` hook, exit 2 instead so Claude sees the stderr even though the tool already ran.”
- <https://code.claude.com/docs/en/hooks> — “To block the action instead, set `"onFailure": "block"` on a `command` or `http` hook. Requires Claude Code v2.1.295 or later.”
- <https://code.claude.com/docs/en/hooks> — “A hook that blocks by exiting 2 routes the same way as `"deny"`: Claude sees the stderr message as the denial reason.”
- <https://code.claude.com/docs/en/hooks> — “A command hook runs as exec form when `args` is set, and shell form when `args` is omitted.”
