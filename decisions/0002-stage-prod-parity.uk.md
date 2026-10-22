# D-0002. Файли stage і prod різняться лише рядком `name:`

> Українська · [English](0002-stage-prod-parity.md)

**Статус:** прийнято · **Дата:** 2026-10-18 · **Правила:** PRN-03, ENV-02

## Контекст

Stage існує, щоб довести, що саме запуститься в prod. Якщо файли розійдуться (інший ліміт, користувач чи сервіс), зелений stage нічого не доводить про prod.

## Рішення

Stage і prod — два повні файли, що різняться лише рядком `name:`; усе, що може відрізнятися, приходить із серверного `.env`. [ENV-02](../standard/02-environments.uk.md#env-02-паритет-stage--prod-m-якщо-є-stage-і-prod) перелічує, що може відрізнятися через `.env` (як-от секрети, розміри, рівень логів, порти) і що не може та лишається буквальним у файлах (образи та версії, набір сервісів, команди, користувач, healthcheck-и). `make parity` рендерить обидва файли через `docker compose config --no-interpolate` під одним ім'ям проєкту (тож `name:` і похідні від нього імена однакові) і падає на будь-якій іншій різниці (він порівнює до підстановки змінних, тож тримати другий перелік поза `.env` — правило проєкту). Він є кроком `make infra` і `make stage` / `make prod`, ще до того, як щось стартує.

## Розглянуті варіанти

- **Один спільний файл плюс override для кожного сервера.** Менше тексту, але справжня конфігурація prod з'являється лише після злиття, і на рев'ю не видно, що злиття змінює.
- **Два файли, які звіряє людина.** Працює, доки хтось не забуде.

## Наслідки

Розходження валить `make infra` і ловиться перед кожним розгортанням. Ціна — два майже однакові файли; перевірка робить їх утримання недорогим.

## Джерела

- <https://12factor.net/dev-prod-parity> — “all deploys of the app (developer environments, staging, production) should be using the same type and version of each of the backing services.”
- <https://raw.githubusercontent.com/docker/compose/main/docs/reference/compose_config.md> — “`docker compose config` renders the actual data model to be applied on the Docker Engine.”
- <https://raw.githubusercontent.com/docker/compose/main/docs/reference/compose_config.md> — `--no-interpolate`: “Don't interpolate environment variables”
