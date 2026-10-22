# D-0018. Образи збираються один раз, а сервери тягнуть їх із реєстру образів

> Українська · [English](0018-images-from-a-registry.md)

**Статус:** замінено записом [D-0025](0025-images-built-on-the-server.uk.md) · **Дата:** 2026-10-18 · **Правила:** PRN-03, ENV-08, ENV-09

2026-10-19 власник обрав збирати образи на сервері, без реєстру; цей запис лишається як історія.

## Контекст

Якщо кожен сервер збирає власний образ, stage і prod запускають дві збірки одного коміту, і ніщо не доводить, що вони однакові: базовий образ чи пакет може змінитися між двома збірками. Серверу, який збирає, ще й потрібні контекст збірки, кеш збірки й час.

## Рішення

Кожен власний образ збирається один раз на машині розробника через `make image` зі стадії `runtime` коміту, отримує тег — git-хеш дерева цього коміту (`git rev-parse <commit>^{tree}`) — і пушиться в реєстр образів проєкту (`IMAGE_PREFIX` у `.env`, наприклад `ghcr.io/<owner>/<repo>`). У файлах stage і prod немає `build:`; сервери лише тягнуть образи, кожен один раз увійшовши з токеном лише для читання, і ніколи не збирають їх знову. Хеш дерева — це хеш вмісту коміту, тож коміт злиття, squash чи rebase, який проєкт створює в prod-гілці з тим самим вмістом, що й коміт stage, використовує вже зібраний образ. Якщо prod-гілка має власні зміни, `make prod` зупиняється з `no image … for the content of commit …`, і `make image` запускають на цій гілці. Відкат використовує попередній коміт, чий образ ще лежить у реєстрі.

## Розглянуті варіанти

- **Реєстр образів.** Одна збірка, ті самі байти на кожному сервері, а старі теги лишаються доступними для відкату. Потрібні обліковий запис і токен на кожній машині.
- **`docker save` / `docker load`.** Без реєстру, але архів копіюють на кожен сервер руками, і ніщо не зберігає старі образи для відкату.
- **Збірка на кожному сервері.** Жодного додаткового сервісу, але дві збірки одного коміту можуть відрізнятися, а серверу потрібні інструменти збірки й час.
- **SHA коміту як тег.** Називає точний коміт, але коміт злиття, який проєкт створює в prod-гілці, має новий SHA, тож prod потребує або власної збірки, або кроку, що пересуває prod-гілку на коміт stage в обхід pull request-ів і захисту гілок проєкту.

## Наслідки

Сервери ніколи не збирають. Перевірено 2026-10-19: злиття `--no-ff`, squash-злиття й rebase stage-гілки на prod-гілку дають коміт з тим самим хешем дерева, що й коміт stage (перевірено один цикл; після squash-злиття stage-гілку треба скинути на prod-гілку, інакше наступне squash-злиття дасть конфлікт); hotfix, зроблений у prod-гілці до злиття, дає інший хеш дерева, тож цьому коміту потрібен власний `make image`. Образ збирається для платформи машини, яка його збирає, тож образи для серверів збирають на машині з тим самим типом процесора, що й на серверах: образ, зібраний на ARM-машині (наприклад, Mac із чипом M), не запускається на сервері Intel/AMD без емуляції, і навпаки. З GitHub Container Registry для входу потрібен personal access token (classic): `write:packages` на машині розробника, `read:packages` на серверах. Новий пакет особистого облікового запису приватний, що пасує приватному проєкту; щоб його стягнути, потрібен вхід.

## Джерела

- <https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry> — “GitHub Packages only supports authentication using a personal access token (classic).”
- <https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry> — “Select the `read:packages` scope to download container images and read their metadata.”
- <https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry> — “Select the `write:packages` scope to download and upload container images and read and write their metadata.”
- <https://docs.github.com/en/packages/learn-github-packages/configuring-a-packages-access-control-and-visibility> — “When you first publish a package that is scoped to your personal account, the default visibility is private and only you can see the package.”
- <https://raw.githubusercontent.com/docker/docs/main/content/manuals/build/building/multi-platform.md> — “This is why you can't run a `linux/amd64` container on an arm64 host (without using emulation), or a Windows container on a Linux host.”
- <https://raw.githubusercontent.com/docker/buildx/master/docs/reference/buildx_build.md> — `--platform`: “The default value is the platform of the BuildKit daemon where the build runs.”
