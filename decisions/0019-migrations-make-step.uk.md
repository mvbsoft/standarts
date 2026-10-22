# D-0019. Міграції — крок `make` до заміни застосунку

> Українська · [English](0019-migrations-make-step.md)

**Статус:** прийнято · **Дата:** 2026-10-18 · **Правила:** ENV-01, ENV-09

## Контекст

Новому образу часто потрібна нова схема бази. Від того, де запускається міграція, залежить, що станеться, коли вона впаде: старий застосунок і далі обслуговує запити чи сервіс лежить.

## Рішення

Крок міграції запускає команду міграцій проєкту (`MIGRATE` у налаштуваннях `Makefile`) в одноразовому контейнері нового образу `APP`, з оболонкою як entrypoint: `docker compose run --rm --entrypoint sh <app> -c <command>`. Власний `ENTRYPOINT` образу обходиться, тож runtime-образу потрібен `/bin/sh`, а міграція, якій потрібне налаштування, що його робить `ENTRYPOINT`, включає його у свою команду. `make stage` і `make prod` запускають крок після того, як зібрали чи стягнули нові образи, і до того, як `up` замінить застосунок, під час кожного розгортання, зокрема повторного розгортання того самого коміту; `make migrate` — це лише ціль dev: вона запускає команду в dev-контейнері, і `make dev` теж її запускає. На сервері міграція запускається лише як цей крок розгортання, під блокуванням клона, а `make migrate` там відмовляється. Невдача зупиняє команду, а стара версія застосунку працює далі (`run` спершу стартує залежності сервісу, і залежність зі зміненою конфігурацією, як-от база, цей старт перестворює). Міграції лишаються сумісними з попереднім образом, тож `make rollback` працює без їх скасування і не запускає жодної.

## Розглянуті варіанти

- **Одноразовий сервіс `migrate` з `depends_on: condition: service_completed_successfully`.** Декларативно, але перевірено 2026-10-18 (Docker Engine 29.7.2, Compose v5.5.0): коли міграція падає, `up` уже видалив старий контейнер застосунку й лишає новий у стані `Created`, тож сервіс лежить; а кожен наступний `up` знову запускає завершений контейнер migrate.
- **Крок `make` з `run --rm`.** Перевірено того ж дня: міграція, що падає, виходить з кодом 1, а запущений контейнер застосунку зберігає той самий ID і лишається healthy.
- **`run --rm <app> sh -c <command>`, як було в шаблоні спершу.** `run` замінює `CMD` образу, але не його `ENTRYPOINT`, тож образ, чий `ENTRYPOINT` — це сервер (типово для Go і Rust), отримував команду як аргументи, запускав сервер, і розгортання зависало під своїм блокуванням. Виміряно 2026-10-20 і 2026-10-21 (разові прогони, Compose v5.5.0): з `ENTRYPOINT`, що працює нескінченно, команду закінчив лише `timeout` (код 124); з `--entrypoint sh` команда виконалася за 1 с, її код виходу передався, а лапки й `$` дійшли до оболонки контейнера. Образ без `/bin/sh` падає в обох випадках (`exec sh failed`). Зразковий проєкт `tests/project` має `ENTRYPOINT` у runtime-образі, тож кожне розгортання в тому тесті перевіряє цю форму.
- **Застосунок мігрує під час старту.** Жодного окремого кроку, але міграція запускається лише після того, як `up` зупинив старий контейнер, тож невдача лишає сервіс лежати; а з `restart: always` міграція, що падає, повторювалася б по колу.

## Наслідки

Невдала міграція не зупиняє запущений застосунок. check-compose лишається суворим: жодних одноразових сервісів, `depends_on` лише з `service_healthy` ([D-0009](0009-compose-rule-check.uk.md)). Ціна — два правила для розробника: міграція не має ламати попередній образ, тож руйнівна зміна розбивається на два релізи; і вона має бути ідемпотентною, бо повторне розгортання того самого коміту запускає її знову, тож уже застосована міграція нічого не змінює.

## Джерела

- <https://raw.githubusercontent.com/docker/compose/main/docs/reference/compose_run.md> — “Runs a one-time command against a service.”
- <https://raw.githubusercontent.com/docker/compose/main/docs/reference/compose_run.md> — “This runs a database upgrade script, and removes the container when finished running, even if a restart policy is specified in the service configuration.”
- <https://raw.githubusercontent.com/docker/compose/main/docs/reference/compose_run.md> — “If you start a service configured with links, the run command first checks to see if the linked service is running and starts the service if it is stopped.”
- <https://raw.githubusercontent.com/docker/compose/main/docs/reference/compose_run.md> — `--no-recreate`: “If dependent containers already exist, don't recreate them, even if their configuration diverged” (є на головній гілці, у v5.5.0 його немає, тож те, що розбіжну залежність типово перестворюють, показує код нижче, а не випущена сторінка).
- <https://raw.githubusercontent.com/docker/compose/v5.5.0/pkg/compose/run.go> і <https://raw.githubusercontent.com/docker/compose/v5.5.0/pkg/compose/reconcile.go> — `startDependencies` викликає `Create` без політики `Recreate`, а `mustRecreate` перестворює, коли `ConfigHash` контейнера відрізняється від очікуваного (прочитано в коді, не запускалося).
- <https://docs.docker.com/reference/cli/docker/compose/run/> — `--entrypoint`: “Override the entrypoint of the image”.
- <https://raw.githubusercontent.com/docker/docs/main/content/reference/compose-file/services.md> — “`service_completed_successfully`: Specifies that a dependency is expected to run to successful completion before starting a dependent service.”
