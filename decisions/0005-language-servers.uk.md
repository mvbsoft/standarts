# D-0005. Мовні сервери працюють у dev-контейнері

> Українська · [English](0005-language-servers.md)

**Статус:** прийнято · **Дата:** 2026-10-18 · **Правила:** AI-07

## Контекст

Claude Code отримує помилки й навігацію по коду від мовних серверів. Офіційні плагіни мовних серверів запускають сервер на хості, де немає бібліотек проєкту, і це ще й порушує PRN-01.

## Рішення

Мовні сервери стоять у стадії `dev` із закріпленими версіями. Невеликий плагін `docker-lsp` у самому репо (`templates/docker-lsp/`) запускає кожен сервер через `docker compose exec -T dev`, тож лаунчеру потрібні лише `sh` і `docker`. Офіційні плагіни `*-lsp` не ставляться.

## Розглянуті варіанти

- **Офіційні LSP-плагіни із серверами на хості.** Бібліотек проєкту там немає, тож діагностика хибна, а на хості з'являється toolchain.
- **Без мовних серверів, лише хук після правки.** Працює, але без переходу до визначень і миттєвих помилок.
- **Сам агент усередині dev-контейнера (специфікація Dev Containers, CLI `devcontainer`, Feature Claude Code від Anthropic).** Мовні сервери, хуки й інструменти працювали б там, де агент, тож плагін `docker-lsp` був би не потрібен. Не обрано: облікові дані агента й робоче дерево з правом запису опиняються всередині контейнера, у dev-контейнері немає власного Docker, тож цілям `make`, що запускають контейнери, знадобився б сокет хоста, а сам підхід передбачає редактор із підтримкою Dev Containers. Він пасує агентові, що працює без нагляду з вимкненими запитами дозволів, — Anthropic це описує. Проєкт, якому це потрібно, записує його як відхилення у своєму реєстрі; стандарт не змінюється.

## Наслідки

Агент бачить ті самі помилки, що й ворота. Плагін — два JSON-файли на репо, скопійовані дослівно з шаблону. Сервери в стадії `dev` обслуговують будь-якого агента; лише плагін належить Claude Code. Те, що Claude Code завантажує плагін, не може показати агент, який налаштовує проєкт (він не запускає власної сесії), тож власник перевіряє це під час передачі: нова сесія, і вкладка Errors у `/plugin` порожня.

## Перевірено

Перевірено 2026-10-19, Docker Engine 29.7.2 (Docker Desktop, WSL 2), Compose v5.5.0; dev-образи з python:3.12.13-slim@sha256:229a2c5bfa27522db7815ea81f9bed70af17ccb9de9fc7ad142b1877b5830d36, php:8.2-cli (PHP 8.2.33)@sha256:0ca296c0ae905940c0a333a15de437f3acaa81743333a9437221f6a44e3f0981 і node:22-bookworm-slim (Node.js 22.23.3)@sha256:c3de60bf2f9dd0ac6370e6117950ff62d6e339527e7472301c9c78a017978392.
- Команда плагіна `docker-lsp`, узята з `plugin.json` із `${CLAUDE_PROJECT_DIR}` = тека проєкту, запускає зупинений dev-стек і віддає LSP через stdio крізь `docker compose exec -T`: `tests/stacks/run.sh` (`make check-stacks`) з невеликим LSP-клієнтом у контейнері (initialize, initialized, didOpen файла з помилкою типів); відповідь на initialize за 0,5–0,9 с, `publishDiagnostics` з цією помилкою за 1,3–1,6 с (уся сесія 2,2–2,6 с, повторний запуск 2026-10-21): pyright-langserver 1.1.414 `Argument of type "Literal[1]" cannot be assigned to parameter "name" of type "str"`, typescript-language-server 6.0.2 з TypeScript 6.0.3 `Argument of type 'number' is not assignable to parameter of type 'string'.`, intelephense 1.18.5 `Expected type 'string'. Found '42'.`. Код має той самий шлях усередині й назовні, тож URI файлів не треба перетворювати; pyright-langserver — це pyright воріт, а typescript-language-server бере TypeScript воріт.
Не перевірено: плагін у справжній сесії Claude Code (завантаження marketplace, `enabledPlugins`, вкладка Errors у `/plugin`), бо `claude` не встановлено у WSL; чи надсилає intelephense, що містить Application Insights, телеметрію з dev-контейнера; хост Windows без WSL.

## Джерела

- <https://code.claude.com/docs/en/plugins/code-intelligence> — “You install the plugin from Anthropic's official marketplace and the language server binary on your machine.”
- <https://code.claude.com/docs/en/plugins/components> — “Claude Code starts `command` by name from the user's `PATH`.”
- <https://code.claude.com/docs/en/plugins/manifest-reference> — “`lspServers` takes a `.json` file path, an inline map of server name to config, or an array of either.”
- <https://code.claude.com/docs/en/plugins/org> — “If you use a local `directory` or `file` source with a relative path, the path resolves against your repository's main checkout.”
- <https://code.claude.com/docs/en/devcontainer> — “commands Claude runs execute inside it rather than on the host machine, while edits to your project files appear in your local repository as you work.”
- <https://code.claude.com/docs/en/devcontainer> — “dev containers do not prevent a malicious project from exfiltrating anything accessible inside the container, including the Claude Code credentials stored in `~/.claude`”
- <https://containers.dev/implementors/spec/> — “Docker Compose configurations use docker-compose (which may be Docker Compose V1 or aliased Docker Compose V2) to create and manage a set of containers required for an application.”
