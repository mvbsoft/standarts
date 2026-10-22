# D-0009. Скрипт перевіряє правила compose

> Українська · [English](0009-compose-rule-check.md)

**Статус:** прийнято · **Дата:** 2026-10-18 · **Правила:** ENV-03

## Контекст

`make parity` доводить лише те, що stage і prod однакові. Якщо обидва однаково неправильні (порт бази відкритий у світ, пароль зі значенням за замовчуванням), parity зелений.

## Рішення

`make check-compose` рендерить кожен наявний файл stage і prod з `.env.example` і перевіряє правила ENV-01: порти, секрети, піни (сторонній образ файла має вигляд `<image>:<version>@sha256:<digest>`, а версія — не `latest`), non-root, healthcheck, restart, ліміти з `memswap_limit`, що дорівнює ліміту пам'яті, ротацію логів і захист контейнера, зокрема `cap_add` — лише як виняток із причиною. Він також падає на `build:` у stage чи prod (власні образи з коміту збирають `make stage` і `make prod`), перевіряє, що власні образи проєкту мають вигляд `<repo>-<name>:${IMAGE_TAG:?}` (`<repo>` — `name:` файла без `-stage` / `-prod`) з non-root `USER` у стадії `runtime` їхнього Dockerfile або в стадії, з якої вона зібрана, і перевіряє кожен базовий образ цих Dockerfile-ів (`FROM`, `COPY --from`, `RUN --mount … from=` і рядок `# syntax=` кожної стадії, стадію `dev` теж) на ту саму версію й digest, крім `scratch` і попередньої стадії; образ, названий через змінну, відхиляється, а перевірка Dockerfile не має винятків. Вона приймає `depends_on` лише з `service_healthy`: одноразові сервіси не використовуються, бо міграції — це крок `make` ([D-0019](0019-migrations-make-step.uk.md)). Без `.env.example` вона так і каже й падає, бо рендерить файли з нього; про відсутню змінну вона не повідомляє. Вона є кроком `make infra` (отже, `make verify`) і `make stage` / `make prod`. Свідомі винятки — у верхньому ключі `x-check-compose-allow` з причиною, і скрипт друкує їх при кожному запуску. Власний виняток проєкту має ще й рядок у розділі E реєстру; винятки, які несе сам шаблон стандарту (старт сервісу `backup` від root, [OPS-01](../standard/03-operations.uk.md); read-only socket proxy сервісу status, [OPS-04](../standard/03-operations.uk.md)), його не потребують. Скрипт — один шаблон для всіх проєктів.

## Розглянуті варіанти

- **Покладатися на промпт аудиту.** Перевіряє лише тоді, коли його запускають.
- **Додати, коли в проєкті з'явиться сервер.** Правила перевірялися б лише після того, як уже розійшлися.
- **KICS** (а також hadolint, `trivy config`, Checkov). Порівняно 2026-10-21 за документацією й кодом запитів інструментів; жоден не запускали. KICS — єдиний із них, що читає файли Compose, і він покриває частину правил (`docker.sock`, `privileged`, `cap_add`, healthcheck, ліміти, `no-new-privileges`). За його кодом він читає файл як написано, а не відрендерений, не може виразити правила stage і prod (теги власних образів, `memswap_limit`, ротацію логів, `depends_on`, секрети `${X:?}`), а його запит про restart, «Restart Policy On Failure Not Set To 5», вимагає число 5, де ENV-01 вимагає `always`. Використання його разом зі скриптом додало б другий інструмент і другий список винятків.
- **`trivy config`, hadolint.** Вони читають лише Dockerfile-и; у таблиці trivy Compose позначено «-». Перевірка Dockerfile понад `USER` і піни — це `docker build --check` у `make lint` ([D-0026](0026-quality-tools.uk.md)); `trivy config` для Dockerfile-ів можна додати пізніше, з trivy, що вже є в dev-образі.

## Наслідки

Правила, які перелічує скрипт (ENV-03), перевіряє машина, а не пам'ять; решту таблиці середовищ перевіряє аудит. Compose на сервері не може зібрати образ із теки клону, а власний образ завжди має тег вмісту коміту; власні образи збирають лише `make stage` / `make prod`, із закомічених файлів ([D-0025](0025-images-built-on-the-server.uk.md)). На хості й далі потрібні лише docker і sh; перевірки йдуть у python-образі, закріпленому за версією й digest. Від check-compose 4.0.0 сторонній образ без digest, у файлі compose чи в Dockerfile власного образу, не проходить перевірку.

## Джерела

- <https://docs.docker.com/engine/network/packet-filtering-firewalls/> — “Packets are routed before the firewall rules can be applied, effectively ignoring your firewall configuration.”
- <https://docs.kics.io/latest/queries/dockercompose-queries/> — запит “Restart Policy On Failure Not Set To 5”.
- <https://trivy.dev/docs/latest/coverage/iac/docker/> — “It supports the following configurations.”; таблиця має Dockerfile і Containerfile з позначкою підтримки, а Compose — «-».
- <https://docs.docker.com/build/checks/> — “Instead of executing the build steps, this command only runs the checks and reports any issues it finds.”
