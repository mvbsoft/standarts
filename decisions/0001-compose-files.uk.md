# D-0001. Три compose-файли і жодного файла з типовим ім'ям

> Українська · [English](0001-compose-files.md)

**Статус:** прийнято · **Дата:** 2026-10-18 · **Правила:** PRN-02

## Контекст

Compose сам підхоплює файл, якщо його не назвали: файл з типовим ім'ям у робочій або батьківській теці, його override-близнюка або те, що названо в `COMPOSE_FILE`, зокрема з `.env`. Проєкт, у якому голий `docker compose up` щось запускає, може випадково запустити не те середовище.

## Рішення

Кожне середовище має свій повний файл: `docker-compose.dev.yml`, `docker-compose.stage.yml`, `docker-compose.prod.yml`. Файла з типовим ім'ям і override-файлів немає, `COMPOSE_FILE`, `COMPOSE_PROJECT_NAME` і `COMPOSE_PROFILES` ніколи не задаються, а `make` завжди передає `-f`. Голий `docker compose up` падає з `no configuration file provided`.

## Розглянуті варіанти

- **Типовий файл для dev і override-файли для серверів.** Звично, але голий `up` будь-де запускає dev, а забутий override непомітно змінює те, що працює.
- **Один файл із профілями.** Профіль лише вирішує, чи стартує сервіс; власного налаштування, що змінює ліміти, монтування чи користувачів, він не має, тож dev і prod мали б їх спільними. Для налаштувань, що різняться між середовищами, документація Compose відсилає до окремих чи об'єднаних файлів.

## Наслідки

Кожна команда називає свій файл, тож випадково запустити не те середовище неможливо. Ціна — запуск через цілі `make`, а не голими командами compose.

## Джерела

- <https://docs.docker.com/compose/how-tos/multiple-compose-files/merge/> — “If not provided, Compose searches the working directory and its parent directories for a `compose.yaml` and a `compose.override.yaml` file.”
- <https://docs.docker.com/compose/how-tos/multiple-compose-files/merge/> — “When you run `docker compose up` it reads the overrides automatically.”
- <https://docs.docker.com/compose/how-tos/environment-variables/variable-interpolation/> — “An `.env` file can also be used to declare pre-defined environment variables used to control Compose behavior and files to be loaded.”
- <https://github.com/compose-spec/compose-go/blob/main/loader/loader.go> — “no configuration file provided”
- <https://docs.docker.com/compose/how-tos/project-name/> — “The COMPOSE_PROJECT_NAME environment variable.” стоїть перед “The top-level `name:` attribute in your Compose file.” у переліку “The precedence order for each method, from highest to lowest”
- <https://raw.githubusercontent.com/docker/docs/main/content/reference/compose-file/services.md> (`profiles`) — “`profiles` defines a list of named profiles for the service to be enabled under. If unassigned, the service is always started but if assigned, it is only started if the profile is activated.”
- <https://raw.githubusercontent.com/docker/docs/main/content/manuals/compose/how-tos/multiple-compose-files/_index.md> — “Using multiple Compose files lets you customize a Compose application for different environments or workflows.”
- <https://github.com/compose-spec/compose-spec/blob/main/15-profiles.md> — “A service or a job is ignored by Compose when none of the listed `profiles` match the active ones, unless it is explicitly targeted by a command.”
