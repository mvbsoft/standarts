# D-0026. Інструменти якості: типовий інструмент для кожної категорії, з пінами і без мережі у воротах

> Українська · [English](0026-quality-tools.md)

**Статус:** прийнято · **Дата:** 2026-10-20 · **Правила:** QLT-01, QLT-02

## Контекст

Проєкти перевіряли код різними інструментами: одні мали пін, інші ні, а деяким потрібна була мережа на кроці, який мусить працювати без неї. Ворота, які щось завантажують під час першого запуску, падають без мережі, а ворота з плаваючою версією червоніють того дня, коли код ніхто не змінював. Звичні інструменти теж змінюються: у 2026 році TypeScript 7 вийшов без API компілятора, ESLint 10 відмовився від `.eslintrc`, `qossmic/deptrac` став `deptrac/deptrac`, gitleaks перейшов лише на виправлення безпеки, а через скомпрометовані облікові дані вийшли шкідливі релізи trivy.

## Рішення

QLT-01 задає категорії й називає типовий інструмент для кожної мови (його таблиця — єдиний перелік назв); кожен вибрано тому, що його підтримують, він працює без мережі після встановлення (для `gates`) і має точний пін у lock-файлі чи образі. Версії та причини їх вибору — тут, щоб оновлення інструмента не міняло правила.

TypeScript закріплений на 6.0.x для всього — і для компілятора, і для інструментів, — доки typescript-eslint не підтримає TypeScript 7: у TypeScript 7 ще немає API компілятора, а typescript-eslint 8.71.2 приймає TypeScript нижче 6.1. ESLint 10 читає лише flat config (`eslint.config.js`). Пакет PHP — `deptrac/deptrac`, він замінює покинутий `qossmic/deptrac`.

Посилання в документації перевіряє lychee з `--offline`: він перевіряє посилання всередині репозиторію й не робить мережевих запитів, тож працює в `gates`, а не у `verify`. Зовнішні посилання не перевіряються.

Мережеві інструменти (pip-audit, npm audit, composer audit, trivy) працюють лише у `verify` та `image-scan`. `uv audit` замінить pip-audit, коли вийде з preview; в uv 0.13.1 це досі preview-функція. pip-audit читає експорт `uv.lock` (`uv export --format pylock.toml`), бо сам `uv.lock` прочитати не може. semgrep працює з `--metrics off` і читає правила з файлів проєкту; проєкт ніколи не поширює копій правил реєстру, які підтримує Semgrep.

Кожен інструмент має точну версію. Інструмент, який потрапляє в образ як бінарний файл або з іншого образу (як-от gitleaks, lychee, trivy), закріплений за версією і за digest образу чи контрольною сумою, тож перезаписаний тег його не змінить. trivy — версії 0.72.0 або новішої: 0.72.0 виправляє path traversal у його менеджері плагінів (GHSA-8rc5-4fr6-64pw, CVE-2026-63328), і це виключає 0.69.4–0.69.6, релізи та образи Docker Hub, опубліковані у березні 2026 року зі скомпрометованими обліковими даними (GHSA-69fq-xp46-6x23, CVE-2026-33634). pyright встановлюють з extra `nodejs`, тож під час першого запуску він не завантажує Node.js.

`gitleaks dir` сканує файли теки, а не git, тож читає й ті, які git ігнорує (локальний `.env`, кеші, результати збирання; помічено під час збирання зразків, 2026-10-21). Проєкт дає йому allowlist таких файлів у `.gitleaks.toml`; у зразках `tests/stacks` він є.

`make lint` також перевіряє Dockerfile кожного власного образу через `docker build --check`, на хості, перед інструментами `LINT` (рівень R). Нового інструмента не потрібно: це власні перевірки Docker, Buildx 0.15.0 або новіший. Вона читає Dockerfile і метадані його базових образів і нічого не збирає. Вона працює й тоді, коли `LINT` — `off`: рядок `lint` у підсумку тоді показує `off` (`LINT = off; dockerfile-check: OK`) і показує `FAIL` лише якщо перевірка Dockerfile впала. Саму перевірку пропускає тільки `DOCKERFILE_CHECK = off` у налаштуваннях.

`make fix` запускає виправлялку кожного інструмента в безпечному режимі, лише вручну. ruff: `ruff format` і `ruff check --fix --no-unsafe-fixes`; ruff за замовчуванням застосовує лише безпечні виправлення, проєкт із `unsafe-fixes = true` змінив би те, що робить звичайний `--fix`, а прапорець у командному рядку це налаштування перекриває (скасувати `extend-safe-fixes` він не може). prettier: `--write`; його перша вимога — та сама поведінка, що й до форматування. eslint: `--fix` застосовує виправлення, ніколи не пропозиції (suggestions); безпека виправлення — це настанова для авторів правил, а не примус, і `--fix` може також видалити вже непотрібний коментар `eslint-disable` (виведено з коду ESLint, не запускали). php-cs-fixer: `fix --allow-risky=no`, тож конфіг, що дозволяє ризиковані правила, не змінює `make fix`. rector лишається в `--dry-run`. Жоден з інструментів не обіцяє, що поведінка лишиться тією самою (документація каже «intended», «meant»), тому після `make fix` — `git diff` і `make gates`.

## Розглянуті варіанти

- **Black + flake8 + mypy для Python.** Три інструменти там, де ruff і pyright — два; pyright за його ж даними у 3–5 разів швидший на великих кодових базах. mypy лишається допустимим вибором для проєкту, якому потрібен плагін mypy.
- **ty замість pyright.** Швидший, але в беті й без стабільної діагностики.
- **`uv audit` уже зараз.** На один інструмент менше, але preview-функція може змінитися між версіями uv.
- **mutmut замість cosmic-ray.** Простіший, але пам'ятає власну попередню роботу й повторно тестує функції, чий код змінився, а не рядки, змінені відносно git-гілки, і потребує `fork`; для `make mutation-diff` потрібен `cr-filter-git` із cosmic-ray.
- **Biome замість prettier + eslint.** Один швидкий інструмент, але за його ж даними сумісний із Prettier на 97 %, а чи покриває він типізовані правила й правила react-hooks, не перевірено. Допустимий через реєстр.
- **Opengrep замість Semgrep CE.** Форк під LGPL із ширшим taint-аналізом у відкритому рушії; допустимий через реєстр.
- **Betterleaks замість gitleaks.** Наступник від тих самих авторів; його v2 ще не стабільна.
- **TypeScript 7 для `tsc`, TypeScript 6 для інструментів** (npm-аліас, який радить анонс TypeScript 7). Швидша перевірка типів, але два пакети TypeScript в одному проєкті; одна версія простіша.
- **Скрипт перевірки посилань у кожному проєкті.** Кожен проєкт пише й підтримує той самий скрипт; lychee — один бінарний файл із піном.
- **lychee з мережею.** Він перевіряв би й зовнішні посилання, але мережева перевірка не може бути воротами, а зовнішня сторінка, що лежить, робила б їх червоними.
- **hadolint для Dockerfile.** Він ще й перевіряє shell у `RUN`, але має ліцензію GPL-3.0 і додає ще один образ; `docker build --check` не потребує нічого нового. `trivy config` над Dockerfile, із trivy, який уже закріплено, може з'явитися пізніше.
- **`ruff check --fix --unsafe-fixes` чи php-cs-fixer з ризикованими правилами в `make fix`.** Виправляється більше за раз, але зміст коду може змінитися.
- **rector у `make fix`.** Він рефакторить код (його набір для PHP 8.2, наприклад, робить класи `readonly`), тож його зміни читають як diff, що й показує `--dry-run`.
- **`eslint --fix --fix-type layout`.** Найбезпечніше, бо виправлення типу layout зберігають структуру програми, але з правилами `recommended` від typescript-eslint у зразку немає жодного правила layout, тож воно нічого б не виправило.

## Наслідки

LINT, TEST і SECRETS мають працювати без мережі, і зразки це доводять: `tests/stacks` запускає `make gates` з dev-контейнером на `network_mode: none`. Версія змінюється лише через переглянуту зміну lock-файла чи Dockerfile. Оновлення phpstan із `max` або ruff на нову minor-версію може додати роботи; це ціна точних пінів. Перевірка Dockerfile працює на хості; коли базового образу немає локально, вона читає метадані образу з реєстру (без мережі не запускали). Проєкти на TypeScript лишаються на 6.0.x, хоча TypeScript 7 уже вийшов. За чим стежити: вихід `uv audit` із preview, підтримка TypeScript 7 у typescript-eslint (після того як TypeScript 7.1 отримає API) і pcov на нових версіях PHP. gitleaks лишається; переглянути, коли Betterleaks v2 стане стабільною.

## Перевірено

Перевірено 2026-10-19, Docker Engine 29.7.2 (Docker Desktop, WSL 2), Compose v5.5.0, через `tests/stacks/run.sh` (`make check-stacks`) на зразках Python, PHP (8.2.33) і TypeScript (Node.js 22.23.3), зібраних із `templates/project`, з інструментами, закріпленими в кожному зразку: ruff 0.17.1, pyright 1.1.414 (`pyright[nodejs]`), pytest 9.1.1; php-cs-fixer 3.95.27, phpstan 2.3.1, rector 2.7.0, phpunit 11.5.57; typescript 6.0.3, eslint 10.13.0, typescript-eslint 8.71.2, prettier 3.9.10, vitest 5.0.5.
- `make gates` у dev-контейнері запускає перевірку формату, lint, типи й тести кожного зразка: `ruff format --check`, `ruff check`, pyright strict, pytest; `php-cs-fixer check`, phpstan на рівні max, `rector process --dry-run`, phpunit; `prettier --check`, eslint з `eslint.config.js` і typescript-eslint, `tsc` зі `strict` і `noUncheckedIndexedAccess`, `vitest run`. Він зелений на чистому зразку і червоний на підкинутій помилці lint з повідомленням інструмента (ruff `F401`, phpstan `undefined_function`, eslint `no-unused-vars`).
- typescript-eslint 8.71.2 працює з TypeScript 6.0.3 і ESLint 10.13.0 із flat config.
- Поза тестом (разовий запуск, 2026-10-19) pyright 1.1.414 із `pyright[nodejs]` перевірив файл у dev-образі Python з `--network none`.
- trivy: `tests/project/run.sh` з `STDTEST_TRIVY=1` додає trivy 0.75.0, закріплений за digest, у dev-образ зразка, і `make image-scan` сканує ним збережені власні образи (тест перевіряє рядки скану `app` і `backup`, а не `status`); без цієї змінної тест бере замінник trivy й доводить відмову, коли в dev-образі його немає.
- shellcheck v0.11.0, закріплений за digest, перевіряє власні скрипти цього репозиторію в `make lint`.

Перевірено 2026-10-21 через `tests/stacks/run.sh`, після того як LINT зразків отримав shellcheck і lychee, а їхній SECRETS — gitleaks (gitleaks v8.30.1, ShellCheck 0.11.0, lychee 0.24.2, кожен скопійований у стадію dev з образу, закріпленого за digest; lychee потребує набору CA-сертифікатів навіть з `--offline`):
- `make gates` зелений на кожному чистому зразку з рядками підсумку `ok` для lint, test і secrets, і червоний з рядком `FAIL` на підкинутій помилці lint, на shell-скрипті, який shellcheck відхиляє (`SC2086`), на підкинутому секреті (`github-pat`) і на зламаному посиланні в документації (lychee `--offline`). Червоні ворота після зміни коду лишають dev-образ таким, яким він був (той самий час створення й шари; ID образу змінюється з кожною збіркою за сховища образів containerd, бо індекс містить нову attestation походження).
- `make gates` зелений з dev-контейнером на `network_mode: none` (образ має бути вже зібраний); разовим запуском (2026-10-21) мутація, що змусила TEST звертатися до мережевої адреси, зробила його там червоним; тест цього не повторює.
- `make fix` повертає зіпсоване форматування на кожному зразку: після неї `git status` не показує змін, а `make gates` зелений.
- `make lint` проходить `docker build --check` над Dockerfile зразків (`Check complete, no warnings found.`). `tests/project/run.sh` доводить, що Dockerfile із зауваженням (`FROM base as runtime` серед стадій, записаних з `AS`) робить lint FAIL.
- Час (разовий замір, 2026-10-21): `make gates` тривав від 13,0 до 13,7 с на трьох зразках.

Не перевірено: semgrep; pip-audit, npm audit і composer audit; psalm; import-linter, deptrac, eslint-plugin-boundaries і dependency-cruiser; eslint-plugin-react-hooks; schemathesis і Playwright; інструменти мутаційного тестування (`tests/project/run.sh` запускає `make mutation` із командою-замінником); інструменти покриття і pcov на PHP 8.5; hypothesis і fast-check; перевірка Dockerfile на хості без мережі; чи змінює поведінку `ruff format`, сортування імпортів або будь-яка виправлялка (документи самих інструментів кажуть «intended», а не гарантують).

## Джерела

- <https://devblogs.microsoft.com/typescript/announcing-typescript-7-0/> — “While TypeScript 7.0 is here, it does not ship with an API.”
- <https://registry.npmjs.org/@typescript-eslint/eslint-plugin> — версія 8.71.2, `peerDependencies.typescript`: “>=4.8.4 <6.1.0”
- <https://raw.githubusercontent.com/eslint/eslint/main/docs/src/use/migrate-to-10.0.0.md> — “Starting with ESLint v10.0.0, the old configuration format is no longer supported.”
- <https://raw.githubusercontent.com/RobertCraigie/pyright-python/main/README.md> — “If it is not, then we download node at runtime using nodeenv, then install the pyright npm package using `npm`”; “It's highly recommended to install `pyright` with the `nodejs` extra”
- <https://raw.githubusercontent.com/microsoft/pyright/main/docs/mypy-comparison.md> — “It is not unusual for pyright to be 3x to 5x faster than mypy when type checking large code bases.”
- <https://raw.githubusercontent.com/astral-sh/ty/main/README.md> — “ty is currently in beta.”
- <https://raw.githubusercontent.com/astral-sh/ruff/main/docs/formatter.md> — “The Ruff formatter is an extremely fast Python code formatter designed as a drop-in replacement for Black”
- <https://raw.githubusercontent.com/prettier/prettier/main/docs/install.md> — “Even a patch release of Prettier can result in slightly different formatting”
- <https://raw.githubusercontent.com/biomejs/biome/main/packages/@biomejs/biome/README.md> — Biome “scores 97% compatibility with Prettier”
- <https://getrector.com/documentation> — “To see preview of suggested changed, run process command with --dry-run option”
- <https://raw.githubusercontent.com/rectorphp/rector/main/README.md> — “Rector will show you diff of files that it *would* change. To *make* the changes, drop `--dry-run`”
- <https://raw.githubusercontent.com/rectorphp/rector-src/main/rules/Php82/Rector/Class_/ReadOnlyClassRector.php> — “Decorate read-only class with `readonly` attribute”
- <https://repo.packagist.org/p2/qossmic/deptrac.json> — `"abandoned": "deptrac/deptrac"`
- <https://raw.githubusercontent.com/vimeo/psalm/6.x/docs/security_analysis/index.md> — “You can enable this mode with the `--taint-analysis` command line flag.”
- <https://docs.astral.sh/uv/concepts/preview/> — “The uv audit and uv tool audit commands check project and installed-tool dependencies for known vulnerabilities.” (у списку preview-функцій)
- <https://astral.sh/blog/uv-audit> — “Both of these features are in preview for now. They're considered unstable and there may be breaking changes as we iterate on their design.”
- <https://raw.githubusercontent.com/pypa/pip-audit/main/README.md> — “At the moment, only `pyproject.toml` and `pylock.*.toml` are supported.”
- <https://semgrep.dev/docs/licensing> — “They are available only for internal business use.”
- <https://semgrep.dev/docs/metrics> — “`--metrics off` : metrics are never sent”
- <https://semgrep.dev/docs/semgrep-code/semgrep-pro-engine-intro> — “Semgrep Community Edition (CE), can only analyze interactions within a single function”
- <https://raw.githubusercontent.com/opengrep/opengrep/main/README.md> — “Welcome to Opengrep, a fork of Semgrep, under the LGPL 2.1 license”
- <https://raw.githubusercontent.com/gitleaks/gitleaks/master/README.md> — “Future releases will be security patches only.”
- <https://raw.githubusercontent.com/betterleaks/betterleaks/main/README.md> — “Until the first stable v2 release, package managers and the Docker `latest` tag may still provide v1.”
- <https://github.com/advisories/GHSA-69fq-xp46-6x23> — “On March 19, 2026, a threat actor used compromised credentials to publish a malicious Trivy v0.69.4 release”; не зачеплені: “trivy images referenced by digest.”
- <https://api.github.com/advisories/GHSA-69fq-xp46-6x23> — поле `cve_id` застереження: `CVE-2026-33634`
- <https://api.github.com/repos/aquasecurity/trivy/security-advisories> — GHSA-8rc5-4fr6-64pw, “Path Traversal in Trivy Plugin Manager Allows Arbitrary File Write”, виправлено в 0.72.0
- <https://api.github.com/advisories/GHSA-8rc5-4fr6-64pw> — CVE-2026-63328; “Fixed in Trivy `0.72.0`. Users should upgrade to that release or later.”
- <https://raw.githubusercontent.com/lycheeverse/lychee/master/README.md> — “`--offline` Only check local files and block network requests”
- <https://docs.docker.com/build/checks/> — “Instead of executing the build steps, this command only runs the checks and reports any issues it finds.”; “Buildx version 0.15.0 and later”
- <https://github.com/hadolint/hadolint> — “GPL-3.0 license”
- <https://raw.githubusercontent.com/sixty-north/cosmic-ray/master/docs/source/how-tos/filters.rst> — “The `cr-filter-git` filter looks for edited or new lines from the given git branch.”
- <https://raw.githubusercontent.com/boxed/mutmut/main/README.rst> — “Between runs, mutmut only re-tests mutants in functions whose source changed.”; “Mutmut must be run on a system with `fork` support.”
- <https://pecl.php.net/rest/r/pcov/1.0.12.xml> — `<da>2024-12-04 09:09:53</da>`, “- PHP 8.4 compatibility”
- <https://raw.githubusercontent.com/astral-sh/ruff/main/docs/linter.md> — “Ruff only applies safe fixes by default.”; “Specifically, an unsafe fix could lead to a change in runtime behavior, the removal of comments, or both”; “The safety of fixes can be adjusted per rule using the lint.extend-safe-fixes and lint.extend-unsafe-fixes settings.”
- <https://raw.githubusercontent.com/astral-sh/ruff/main/crates/ruff/src/args.rs> — `--unsafe-fixes`: “Include fixes that may not retain the original intent of the code. Use `--no-unsafe-fixes` to disable.”
- <https://docs.astral.sh/ruff/settings/#unsafe-fixes> — “Enable application of unsafe fixes.”
- <https://raw.githubusercontent.com/prettier/prettier/main/docs/rationale.md> — “The first requirement of Prettier is to output valid code that has the exact same behavior as before formatting.”
- <https://raw.githubusercontent.com/eslint/eslint/main/docs/src/use/core-concepts/index.md> — “Fixes safely correct the violation without changing application logic.”; “Suggestions may change application logic and so cannot be automatically applied.”
- <https://raw.githubusercontent.com/eslint/eslint/main/docs/src/extend/custom-rules.md> — “Avoid any fixes that could change the runtime behavior of code and cause it to stop working.”
- <https://raw.githubusercontent.com/eslint/eslint/main/docs/src/use/command-line-interface.md> — `--fix-type`: “`layout` - apply fixes that do not change the program structure (AST)”
- <https://raw.githubusercontent.com/PHP-CS-Fixer/PHP-CS-Fixer/master/doc/usage.rst> — “A rule is considered risky if it could change code behaviour. By default no risky rules are run.”
