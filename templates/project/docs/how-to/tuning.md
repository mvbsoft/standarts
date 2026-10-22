# Tuning to the container limits

<!-- project template 1.0.0 — a starting point (standard OPS-02, DOC-01): keep the method; one row per tuned parameter of this project. -->

Every stage and prod service runs inside the limits of its container, and every setting that
depends on them is tuned to them. This page explains each such setting once; its variable in
`.env.example` points here, and `scripts/tuning-check.sh` checks it on the running services.

## The method

- **Where the values live.** The limits (`<SERVICE>_CPUS`, `<SERVICE>_MEM`) and the numbers
  derived from them (`DB_SHARED_BUFFERS`) are variables in `.env`. Nothing is computed when a
  container starts: the compose files pass each number by the component's own route (PostgreSQL:
  `-c` flags in the `command:` of `db`, because its config file does not read variables). A size
  always has a unit (`256MB`, not `32768`): without one PostgreSQL reads the parameter's own unit
  (8kB blocks for `shared_buffers`), and `tuning-check` refuses it.
- **How a number is derived.** From the limits of its own container, never from the memory of the
  whole server, by the rule in its row. What a container's processes can use together, `/dev/shm`
  and tmpfs included, stays within its memory limit.
- **A number of processes** (PHP-FPM `pm.max_children`, application-server workers) comes from the
  memory of one process measured under load: (the memory limit − what the rest of the container
  uses) ÷ the measured memory per process, with a margin. Its row records the date, how it was
  measured and the number.
- **Sources that disagree.** The default stays until a measurement on this project shows a better
  value; the row names the sources and the measurement.
- **No swap.** Every service with a memory limit has `memswap_limit` equal to it.
- **To change a limit**, derive the numbers of its rows again, write both in `.env`, then
  `make restart`.
- **To check**, `make tuning-check` (also the last step of `make stage`, `make prod` and
  `make restart`) compares what each running service reports with `.env`:
  `tuning-check: ok <parameter>` or `tuning-check: FAIL <parameter>: <actual>, expected <expected>`.
  A FAIL fails the deploy after it is recorded, so `.deploy/history` names the commit that runs:
  set the value in `.env`, then `make restart`.

## Parameters

| Parameter | Variable | Why | How it is derived | How to change | How to check (`tuning-check`) | Source |
|---|---|---|---|---|---|---|
| CPUs and memory of every service | `APP_CPUS`, `APP_MEM`, `DB_CPUS`, `DB_MEM`, `BACKUP_CPUS`, `BACKUP_MEM`, `STATUS_CPUS`, `STATUS_MEM`, `STATUS_PROXY_CPUS`, `STATUS_PROXY_MEM` | the limits every other row is derived from | what the service needs under load, measured; the sum fits the server | `.env`, `make restart` | `<service> cpus`, `<service> memory` | the measurement: <date, how, the numbers> |
| No swap beyond the limit | `memswap_limit` = `<SERVICE>_MEM` | without it the container may use as much swap again, slow instead of stopped | equal to the memory limit | follows `<SERVICE>_MEM` | `<service> memswap` | <https://docs.docker.com/reference/compose-file/services/> — “If `memswap_limit` is unset, and `memory` is set, the container can use as much swap as the `memory` setting, if the host has swap memory configured.” |
| PostgreSQL `shared_buffers` | `DB_SHARED_BUFFERS` | the default 128MB ignores the limit | 25% of `DB_MEM` from 1 GB up (1G → 256MB); less below 1 GB. `shm_size` (256m) counts inside `DB_MEM` too | `.env`, `make restart` | `db shared_buffers` | <https://www.postgresql.org/docs/current/runtime-config-resource.html> — “If you have a dedicated database server with 1GB or more of RAM, a reasonable starting value for `shared_buffers` is 25% of the memory in your system.” |
| PostgreSQL `effective_cache_size` | `DB_EFFECTIVE_CACHE_SIZE` | the default 4GB is larger than the whole container; the planner uses it as an estimate only | 75% of `DB_MEM` (1G → 768MB) | `.env`, `make restart` | `db effective_cache_size` | <https://www.postgresql.org/docs/current/runtime-config-query.html> — “The default is 4 gigabytes (`4GB`).”; <https://wiki.postgresql.org/wiki/Tuning_Your_PostgreSQL_Server> — “3/4 of memory is a more aggressive but still reasonable amount.” |
| <parameter (service)> | <VARIABLE> | <why the default does not fit> | <the rule; for a pool, the measured memory per process: date, how, number> | <how> | `<service> <parameter>` | <URL — quote> |

## Left at the default on purpose

| Parameter | Why |
|---|---|
| PostgreSQL `work_mem`, `maintenance_work_mem`, `wal_buffers` | the defaults (4MB, 64MB, and 8MB from `-1`) stay: nothing measured here shows a better value |
| PostgreSQL `random_page_cost` | sources disagree for SSDs (the PostgreSQL wiki 2.0–3.0, the PostgreSQL 17 and 18 docs no number; the sources and quotes are in the standard's decision D-0011), and nothing here has measured it |
