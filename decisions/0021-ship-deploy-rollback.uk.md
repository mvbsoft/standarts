# D-0021. Розгортання, перезапуск і відкат командами `make` у клоні на сервері

> Українська · [English](0021-ship-deploy-rollback.md)

**Статус:** прийнято · **Дата:** 2026-10-18 · **Правила:** ENV-09

## Контекст

Кожен проєкт розгортався по-своєму: одні збирали на сервері, інші запускали команди compose з інструкції, у деяких не було шляху назад. Кожен ручний крок — це крок, який хтось пропустить під тиском.

## Рішення

- **`make stage` / `make prod`** (клон на сервері): ще до будь-яких змін відмовляється, якщо `PROJECT_ENV` не збігається, якесь значення в `.env` досі `change-me`, `.env` і файли build secret можуть читати інші, це не єдина копія середовища на машині ([D-0003](0003-several-environments.uk.md)), інше розгортання тримає блокування клона, або клон не чистий; а де на диску може бракувати місця для збірки (двічі власні образи плюс `DISK_RESERVE`, [D-0025](0025-images-built-on-the-server.uk.md)), він попереджає й питає, а не відмовляє, бо це оцінка. Далі підтягує налаштовану гілку лише fast-forward; продовжує в новому `Makefile` через вкладений make; далі `make bootstrap`, `parity`, `check-compose`, збірка кожного власного образу цього коміту, якого на сервері немає, і стягування сторонніх образів, яких бракує, збереження логів контейнерів, які може замінити (OPS-03), набір бекапу прямо перед міграцією (OPS-01; із сервісом backup і заданим `MIGRATE`, не на першому розгортанні клона), крок міграції ([D-0019](0019-migrations-make-step.uk.md)), `docker compose up -d --wait --remove-orphans` для кожного сервісу, крім `backup`, потім `backup` без очікування (unhealthy-бекап друкує попередження і не зупиняє розгортання, OPS-01), рядок у `.deploy/history`, видалення власних образів, старіших за останні `KEEP_IMAGES` (типово 5) розгорнутих комітів, і останнім `make tuning-check`: перевірка, що впала, валить команду, але історія вже називає коміт, що працює, тож після виправлення `make restart` працює. Кожен крок у разі невдачі зупиняє команду; невдалий набір перед міграцією натомість попереджає й питає (ENV-09). Як зміна потрапляє в prod-гілку (pull request, злиття, захист гілки), проєкт обирає сам; `make prod` розгортає те, що в ній є.
- **`make restart`** (клон на сервері): застосовує змінений `.env` до коміту, що працює зараз, без руху гілки й без міграцій; той самий `up` перестворює лише ті контейнери, чия конфігурація змінилася, далі `make tuning-check`. Він відмовляється, якщо коміт, на якому стоїть клон, не той, що розгорнуто останнім, і не записується, тож `make rollback` його не враховує. Змінився `.env` → `make restart`; нова версія → `make stage` / `make prod`.
- **`make rollback`** (клон на сервері): розгортає попередній коміт із `.deploy/history` так само, без міграцій; образи цього коміту він збирає знову, якщо їх видалено, і рахує вільне місце лише для образів, які має зібрати.

## Розглянуті варіанти

- **CI-конвеєр, що розгортає на сервери.** Автоматично, але кожен сервер має приймати з'єднання від CI, а проєкту потрібен CI.
- **Команди compose з інструкції.** Нічого підтримувати, і кожне розгортання трохи інше.
- **Цілі `make`, які запускають у клоні на сервері.** Одна команда на крок, однакова в кожному проєкті, а серверу потрібні лише docker, git, make і sh.
- **Ціль `make`, що пересуває prod-гілку на коміт stage, лише fast-forward.** Prod запускає саме коміт stage, але це обхід pull request-ів і захисту гілок проєкту; злиття в prod-гілку й так має той самий вміст, тож отримує образи того самого вмісту ([D-0025](0025-images-built-on-the-server.uk.md)).
- **Kamal.** Пушить образ у реєстр (D-0025 його відхиляє) і спрямовує трафік на новий контейнер лише коли той відповідає `200 OK` на `GET /up`, тож розгортання не має простою, чого в нас немає.
- **Dokku.** Збирає на сервері з `git push` і не читає Compose-файлів; підтримка Compose — відкрита пропозиція (issue 5102).
- **Coolify.** Типово збирає на сервері, куди розгортається застосунок, а його відкат розгортає старіший образ, збережений на сервері, як і наш; але він розбирає Compose-визначення й додає до нього конфігурацію, тож файл у git перестає бути тим, що працює.
- **CapRover.** Надсилає на сервер поточний git-коміт, а його revert у веб-інтерфейсі не повертає змінних оточення.
- **Змінений `.env` застосовує `make stage` / `make prod`.** Жодної додаткової команди, але після `make rollback` це повертає сервер на найновіший коміт гілки — той, з якого щойно відкотилися.

## Наслідки

Перевірено 2026-10-18 (Docker Engine 29.7.2, Compose v5.5.0; разовий прогін): `up -d --wait` замінює змінений контейнер так — спершу зупиняє старий, потім запускає новий, тож оновлення має секунди простою, довше, коли PID 1 ігнорує SIGTERM (`init: true` змушує SIGTERM завершити процес, який не встановив власного обробника; той, що його ігнорує, усе одно чекає 10 с пільгового періоду); незмінені сервіси, як-от база, не перезапускаються, а дані в іменованих томах зберігаються. Коли новий контейнер так і не стає healthy, `up -d --wait` друкує `container ... is unhealthy` і виходить з кодом 1, а старого контейнера вже немає, тож виправлення — `make rollback`: `up` з попереднім тегом повертає його. Образ, який ще є на сервері, вдруге не стягується (`--pull missing` з тегом, що є локально, не звертався до мережі), тож `up` використовує образи, зібрані на сервері. Перевірено 2026-10-19 (Docker Engine 29.7.2, Compose v5.5.0; разовий прогін): після зміни значення в `.env` простий `docker compose restart` лишив у контейнері старе значення, а `up -d` перестворив контейнер з новим. Розгортання без простою потребує фронт-проксі, що перемикає трафік; у стандарті його поки немає. Якщо його додадуть, kamal-proxy (він може працювати окремо) порівняють із Caddy, Traefik і nginx у власному рішенні; воно змінить крок розгортання, правила `check-compose` і відкат.

## Перевірено

Перевірено 2026-10-19, Docker 29.7.2, Compose v5.5.0, git 2.43.0 (WSL2), через `tests/project/run.sh`: зразковий проєкт, зроблений із шаблону, локальний bare-репозиторій і його клони stage і prod на одній машині. Кроки — це перевірки цього тесту; розміри й часи нижче — разові покази того прогону (2026-10-19), яких тест не стверджує.
- Перше розгортання: `make stage` у новому клоні stage, який зібрав обидва образи (app 43 МБ, backup 127 МБ); 16–20 с.
- Повторне розгортання: другий `make stage` того самого коміту; він нічого не збирав, а ID образу й контейнер лишилися ті самі; 6–8 с. Його міграція запустилася знову, поки працювала поточна версія.
- Новий коміт: `make stage`; 11–15 с.
- Невдала збірка: коміт зі зламаним рядком Dockerfile; `make stage` зупинився з `building … failed (above); nothing was replaced`, старий контейнер працював далі, `.deploy/history` не змінився, і жодного образу цього коміту не лишилося.
- Невдала міграція й контейнер, що так і не став healthy: після першої стара версія працювала далі; після другого `make rollback` повернув попередній коміт.
- Відкат: `make rollback` зі збереженими попередніми образами 6–7 с; після їх видалення він надрукував `rollback: building the images of <sha> again (they were pruned)` і тривав 9–11 с. Жоден не запускав міграцій (`migrate: skipped (rollback)`), а невдалий відкат надрукував `make rollback did not finish (above): this clone is left at <sha> (detached HEAD); make stage deploys the main branch again, make rollback deploys <sha>`.
- Prune: розгортання й відкати шести різних комітів за наявності двох чужих образів (`<repo>-app:by-hand` і образ з іншим іменем і тегом, схожим на хеш дерева); образи найстарішого коміту видалено, лишилися рівно дерева останніх 5 розгорнутих комітів, а обидва чужі образи, `busybox:latest` і dev-образ ніхто не зачепив.
- Prod: злиття stage-гілки в prod-гілку з `--no-ff`; `make prod` у prod-клоні на тій самій машині нічого не збирав і тривав 16–17 с; виправлення, зроблене лише в prod-гілці, зібрано там.
З 2026-10-21 той самий тест перевіряє ще й: порядок розгортання вище (невдала перевірка налаштування лишає в історії новий коміт, і тоді `make restart` працює); відмову через вільне місце до будь-яких змін (запас більший за диск: коміт, історія й контейнер не змінені); відмову в другій копії середовища; відмову для `.env`, який можуть читати інші; архів логів замінюваного контейнера.
Не перевірено: stage і prod на різних машинах (на одній машині prod використав образи, зібрані для stage), справжній віддалений сервер, приватна залежність з обліковими даними для збірки і ріст кешу збірки за багато розгортань.

## Джерела

- <https://docs.docker.com/reference/cli/docker/compose/up/> — `--wait`: “Wait for services to be running|healthy. Implies detached mode.”
- <https://raw.githubusercontent.com/docker/compose/main/docs/reference/compose_up.md> — “If the process encounters an error, the exit code for this command is `1`.”
- <https://raw.githubusercontent.com/docker/docs/main/content/reference/compose-file/services.md> — `missing`: “Compose pulls the image only if it's not available in the platform cache.”
- <https://raw.githubusercontent.com/docker/docs/main/content/reference/compose-file/services.md> (`init`) — “`init` runs an init process (PID 1) inside the container that forwards signals and reaps processes. Set this option to `true` to enable this feature for the service.”; `stop_grace_period`: “Default value is 10 seconds for the container to exit before sending SIGKILL.”
- <https://man7.org/linux/man-pages/man7/pid_namespaces.7.html> — “Only signals for which the "init" process has established a signal handler can be sent to the "init" process by other members of the PID namespace.”
- <https://raw.githubusercontent.com/krallin/tini/master/README.md> — “With Tini, `SIGTERM` properly terminates your process even if you didn't explicitly install a signal handler for it.”
- <https://kamal-deploy.org/docs/installation/> — “Push the image to the registry”; “route traffic to the new container once it is responding with `200 OK` to `GET /up`”
- <https://dokku.com/docs/getting-started/installation/> — “building apps on the fly from a `git push`”; <https://github.com/dokku/dokku/issues/5102> — “Docker Compose Support” (open)
- <https://coolify.io/docs/knowledge-base/server/build-server> — “By default, Coolify builds an application on the same server where the application will be deployed.”; <https://coolify.io/docs/applications/deployments/rollbacks> — “A rollback deploys an older application image retained on the server.”; <https://coolify.io/docs/knowledge-base/docker/compose> — “Coolify parses the definition and adds the configuration required to manage the resource.”
- <https://caprover.com/docs/get-started.html> — “Note that when you run `caprover deploy`, the current git commit will be sent over to your server.”; <https://caprover.com/docs/deployment-methods.html> — “Note that this DOES NOT revert changes that you made to Environment Variables”
- <https://raw.githubusercontent.com/docker/compose/main/docs/reference/compose_restart.md> — “For example, changes to environment variables (which are added after a container is built, but before the container's command is executed) are not updated after restarting.”
