# D-0011. Компоненти налаштовуються під ліміти свого контейнера

> Українська · [English](0011-tuning.md)

**Статус:** прийнято · **Дата:** 2026-10-20 · **Правила:** OPS-02, ENV-01, ENV-03

## Контекст

Заводські налаштування розраховані на найменшу машину, а більшість компонентів не бачить лімітів
свого контейнера. PostgreSQL тримає 128 МБ спільних буферів і вважає, що має 4 ГБ кешу, у
контейнері на 1 ГБ; `cpus` у Compose — це квота процесора, а nginx із `worker_processes auto`
рахує процесори хоста. Контейнер із лімітом пам'яті без `memswap_limit` може взяти ще стільки ж
swap. Проєкти різняться стеками, версіями й навантаженням, тож перелік значень чи формул у
стандарті для більшості з них був би хибним.

## Рішення

Стандарт задає напрям, а не налаштування кожного застосунку: де лежать значення, як їх виводять,
перевіряють і пояснюють (OPS-02). Рівень M — лише для компонента, чиї заводські налаштування
відомо, що не підходять під контейнер (128 МБ спільних буферів у PostgreSQL, пул воркерів, кількість
яких, помножена на їхню пам'ять, може перевищити ліміт); для будь-якого іншого компонента
налаштування — R, і відмову записують у реєстр.

- Ліміти й виведені з них числа — змінні в `.env` (`DB_MEM=1G`, `DB_SHARED_BUFFERS=256MB`);
  `docs/how-to/tuning.md` каже, як виводиться кожне; під час старту контейнера нічого не
  обчислюється; `make tuning-check` порівнює те, що повідомляє запущений сервіс, із `.env`, і
  запускається після запису розгортання в історію, тож перевірка, що впала, валить команду, але
  лишає історію правдивою.
- Кількість процесів береться з виміряної пам'яті одного процесу під навантаженням (ліміт ÷
  виміряна пам'ять, із запасом) і записується з датою виміру.
- Кожен сервіс stage і prod з лімітом пам'яті має `memswap_limit`, що дорівнює цьому ліміту, і
  check-compose це перевіряє.
- Де джерела розходяться щодо значення, лишається типове, доки вимір на проєкті не покаже
  кращого.
- PostgreSQL отримує свої числа з `.env` прапорцями `-c` у `command:` свого сервісу.
- Формул воркерів, округлення дробових CPU і налаштувань хоста (ядра) у стандарті немає: проєкт
  обирає сам і пояснює вибір у `tuning.md`; `catalog/` зберігає нотатки з джерелами.

Шаблон несе метод: `docs/how-to/tuning.md`, `scripts/tuning-check.sh`, прапорці PostgreSQL і
`memswap_limit` у файлах stage і prod.

## Розглянуті варіанти

- **Рівень.** A: M лише там, де заводські налаштування відомо, що не підходять, R для решти (обрано).
  B: M для кожного компонента, що змушує проєкт налаштовувати те, чиї типові значення нормальні. C:
  R для всього, що лишає PostgreSQL на 128 МБ спільних буферів.
- **Де лежать виведені числа.** A: у `.env` поруч із лімітами, з поясненням у `tuning.md`
  (обрано). B: у `.env` лише ліміти, решту під час старту рахує entrypoint: код у кожному образі
  й шлях до конфігу, відкритий на запис попри `read_only`.
- **Кількість процесів.** A: з виміряної пам'яті одного процесу (обрано). B: з найгіршого
  випадку, `memory_limit` × процеси, що лишає кожному запиту мало: у 512 МБ із 128 МБ opcache і
  8 процесами — (512 − 128) ÷ 8 = 48 МБ на запит.
- **Swap.** A: `memswap_limit`, що дорівнює ліміту пам'яті (обрано). B: типова поведінка Docker —
  до стількох самих swap, якщо на хості є swap.
- **Джерела розходяться** (`random_page_cost` для SSD: вікі 2.0–3.0, документація
  PostgreSQL 17 і 18 числа не дає). A: типове значення до виміру (обрано). B: іти за одним
  джерелом.
- **Формули воркерів** (gunicorn дає і (2 × ядра) + 1, і 2–4 × ядра). A: не в стандарті (обрано).
  B: назвати одну.
- **Дробові CPU.** A: не в стандарті (обрано). B: округлювати вгору, щонайменше 1.
- **Як PostgreSQL отримує числа.** A: прапорці `-c` у `command:` (обрано). B: `postgresql.conf` із
  числами, який не читає змінних.
- **Налаштування хоста** (`vm.overcommit_memory` для Redis, huge pages). A: не в стандарті
  (обрано), вони поза проєктом. B: перелічити їх.
- **Фіксований перелік значень у стандарті** або **налаштування на розсуд кожного проєкту без
  методу**: перше хибне, щойно змінюється сервер чи версія; з другим заводські значення
  лишаються назавжди.

## Наслідки

Кожен проєкт пояснює кожне налаштоване значення один раз, у `tuning.md`, а перевірка ловить
значення, що повернулося до заводського, чи ще не застосовану зміну `.env`. Зміна ліміту означає
вручну вивести його числа знову, записати обидва в `.env` і запустити `make restart`. Коли
`make tuning-check` падає після розгортання, нові контейнери вже працюють, а історія їх називає, тож
виправлення — значення в `.env` і `make restart`; поки цього не записували, історія називала
стару версію, а `make restart` відмовляв. Без swap
контейнер, що переріс свій ліміт, не сповільнюється, а його зупиняє OOM killer, тож ліміти
вимірюють.

## Перевірено

Перевірено 2026-10-20, Docker 29.7.2, Compose v5.5.0 (WSL2, на хості 4 ГБ swap); перші два пункти — одноразові запуски, третій повторює `make check`:
- (одноразовий запуск, 2026-10-20) `memswap_limit: ${M:?}` з `deploy.resources.limits.memory: ${M:?}` (`M=512M`): `docker inspect`
  показує `Memory` і `MemorySwap` по 536870912, а `memory.swap.max` у cgroup — 0; без
  `memswap_limit` `MemorySwap` — 1073741824, а `memory.swap.max` — 536870912. `docker compose
  config --format json` рендерить обидва значення в байтах.
- (одноразовий запуск, 2026-10-20) PostgreSQL 16.15 (`postgres:16-alpine`): `shared_buffers = '${X}'` у конфіг-файлі, коли `X`
  задано в середовищі, зупиняє сервер (`invalid value for parameter "shared_buffers": "${X}"`);
  `-c shared_buffers=256MB` дає 256MB. PostgreSQL 16.15 (`postgres:16`): `-c shared_buffers=32768`
  теж дає 256MB (блоки по 8kB), а `pg_size_bytes('32768')` — 32768 байтів, тож розмір у `.env`
  пишуть з одиницею.
- `tests/project/run.sh`: після `make stage` `make tuning-check` друкує `ok` для лімітів, `memswap`
  і обох налаштувань PostgreSQL; змінений `DB_SHARED_BUFFERS` у `.env` робить його червоним, доки
  `make restart` його не застосує; `DB_SHARED_BUFFERS` без одиниці робить його червоним із власним
  повідомленням. Коли перевірка падає наприкінці розгортання, історія містить новий коміт, а
  `make restart` працює після виправлення значення (2026-10-21).

## Джерела

- <https://docs.docker.com/reference/compose-file/services/> — “If `memswap_limit` is unset, and `memory` is set, the container can use as much swap as the `memory` setting, if the host has swap memory configured.”
- <https://docs.docker.com/engine/containers/resource_constraints/> — “if the host machine has two CPUs and you set `--cpus="1.5"`, the container is guaranteed at most one and a half of the CPUs.”
- <https://github.com/torvalds/linux/blob/master/Documentation/admin-guide/cgroup-v2.rst> — `shmem`: “Amount of cached filesystem data that is swap-backed, such as tmpfs, shm segments, shared anonymous mmap()s”
- <https://www.postgresql.org/docs/current/runtime-config-resource.html> — `shared_buffers`: “The default is typically 128 megabytes (`128MB`)”; “If you have a dedicated database server with 1GB or more of RAM, a reasonable starting value for `shared_buffers` is 25% of the memory in your system.”
- <https://www.postgresql.org/docs/current/runtime-config-query.html> — `effective_cache_size`: “The default is 4 gigabytes (`4GB`).”
- <https://www.postgresql.org/docs/17/runtime-config-query.html>, <https://www.postgresql.org/docs/18/runtime-config-query.html> — `random_page_cost`, напрям без числа для SSD: “if your data is likely to be completely in cache, such as when the database is smaller than the total server memory, or network latency is high, decreasing `random_page_cost` might be appropriate.”
- <https://github.com/docker-library/docs/blob/master/postgres/content.md> — передача налаштувань серверу: “`-c shared_buffers=256MB -c max_connections=200`”
- <https://wiki.postgresql.org/wiki/Tuning_Your_PostgreSQL_Server> — “it's not unusual for administrators to standardize on always setting this between 2.0 and 3.0 instead.”
- <https://github.com/benoitc/gunicorn/blob/master/docs/content/design.md> — “workers = (2 × CPU cores) + 1”; <https://github.com/benoitc/gunicorn/blob/master/gunicorn/config.py> — “A positive integer generally in the ``2-4 x $(NUM_CORES)`` range.”
- <https://github.com/nginx/nginx/blob/master/src/os/unix/ngx_posix_init.c> — `ngx_ncpu = sysconf(_SC_NPROCESSORS_ONLN);`
