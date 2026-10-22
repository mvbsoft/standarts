# D-0004. Стадії Dockerfile: base, runtime, dev

> Українська · [English](0004-dockerfile-stages.md)

**Статус:** прийнято · **Дата:** 2026-10-18 · **Правила:** ENV-08

## Контекст

Розробці потрібні лінтери, перевірка типів і мовні сервери; у prod їх бути не повинно. Два незалежні Dockerfile розходяться у версії мови й бібліотеках.

## Рішення

Один Dockerfile на сервіс із трьома стадіями: `base` (мова закріпленої версії і бібліотеки для prod), `runtime` (base + код, non-root користувач, команда запуску; цей образ іде в stage і prod) і `dev` (base + інструменти розробки, ніколи не код). Dev збирає `target: dev` і отримує код лише через підключення; `make stage` і `make prod` збирають `target: runtime` на сервері ([D-0025](0025-images-built-on-the-server.uk.md)). Бібліотеки встановлюються до копіювання коду, і копіює код лише `runtime`. Виняток — два службові образи шаблону, `backup` і `status`, інструменти, що запускають скрипти зі свого образу й не підключають коду: їхня стадія `dev` — це їхній `runtime`, який копіює лише їхні скрипти (`docker/backup/*.sh`, `docker/status/status.py`).

## Розглянуті варіанти

- **Окремі Dockerfile для dev і prod.** Легко читати, але версії розходяться, і ніщо не доводить, що dev відповідає prod.
- **Інструменти на хості, у контейнерах лише сервіси.** Порушує PRN-01.
- **`dev`, зібраний з `runtime`.** Dev мав би команду запуску й користувача образу, що працює, але `runtime` копіює код, тож кожна зміна коду перезбирає `dev`, а `make dev`, `make gates` і хук pre-push запускають `up --build`.

## Наслідки

Dev і prod мають ту саму версію мови й бібліотек за побудовою; зміна коду не перевстановлює бібліотеки `base` і не перезбирає dev-образ, у якому коду немає: його перезбирають лише тоді, коли змінюються `base`, його інструменти чи lock-файл. Виміряно 2026-10-19 на прикладі Python із `tests/stacks` (разовий прогін, тест його не повторює) — перезбирання dev-образу після зміни коду: 27,1 с з `dev`, зібраним з `runtime`, і встановленими в ньому інструментами (для чого ще й потрібна мережа), 21,4 с з інструментами, скопійованими зі стадії інструментів, 0,9 с з `dev`, зібраним з `base` без коду. Стадія, що лише готує інструменти, які `dev` копіює, дозволена. Dev-образ `backup`, виміряно того самого дня (разовий прогін) на `docker/backup/Dockerfile` шаблону: після зміни коду застосунку кожен крок збірки взявся з кешу, а образ зберіг час створення й шари.

З 2026-10-21 `tests/stacks` перевіряє це твердження на трьох зразках: після зміни коду dev-образ зберігає час створення й шари, а зміна, що копіює код у стадію dev, валить тест. Він порівнює `Created` і шари, а не ID образу, бо в сховищі образів containerd ID — це digest індексу образу, у якому є provenance-атестація, нова за кожної збірки: виміряно 2026-10-21 (Docker Engine 29.7.2, разовий прогін), одна й та сама збірка з кешу двічі дала ID `2866f700…` і `9db98048…` з тим самим `Created`, тими самими 9 шарами й тим самим маніфестом платформи `99fa5121…`.

## Джерела

- <https://docs.docker.com/build/building/multi-stage/> — “You can selectively copy artifacts from one stage to another, leaving behind everything you don't want in the final image.”
- <https://github.com/compose-spec/compose-spec/blob/main/build.md> — “`target` defines the stage to build as defined inside a multi-stage `Dockerfile`.”
- <https://docs.docker.com/build/cache/optimize/> — “By installing dependencies in earlier layers of the Dockerfile, there is no need to rebuild those layers when a project file has changed.”
