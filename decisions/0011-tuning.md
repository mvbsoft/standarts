# D-0011. Components are tuned to their container limits

> English · [Українська](0011-tuning.uk.md)

**Status:** accepted · **Date:** 2026-10-20 · **Rules:** OPS-02, ENV-01, ENV-03

## Context

Factory settings are made for the smallest machine, and most components do not see their
container's limits. PostgreSQL keeps 128 MB of shared buffers and assumes a 4 GB cache in a 1 GB
container; Compose `cpus` is a CPU quota, while nginx `worker_processes auto` counts the host's
CPUs. A container with a memory limit and no `memswap_limit` may use as much swap again. Projects differ in stacks,
versions and load, so a list of values or formulas in the standard would be wrong for most of them.

## Decision

The standard sets the direction, not the tuning of each application: where the values live, how
they are derived, checked and explained (OPS-02). The level is M only for a component whose factory
settings are known not to fit a container (PostgreSQL's 128 MB of shared buffers, a pool of worker
processes whose count times their memory can exceed the limit); for any other component tuning is
R, and declining it is recorded in the registry.

- The limits and the numbers derived from them are variables in `.env` (`DB_MEM=1G`,
  `DB_SHARED_BUFFERS=256MB`); `docs/how-to/tuning.md` says how each is derived; nothing is
  computed when a container starts; `make tuning-check` compares what the running service reports
  with `.env`, and runs after the deploy is recorded in the history, so a failing check fails the
  command but leaves the history true.
- A number of processes comes from the measured memory of one process under load (the limit ÷ the
  measured memory, with a margin), recorded with the date of the measurement.
- Every stage and prod service with a memory limit has `memswap_limit` equal to it, and
  check-compose enforces it.
- Where sources disagree on a value, the default stays until a measurement on the project shows a
  better one.
- PostgreSQL gets its numbers as `-c` flags in the `command:` of its service, from `.env`.
- Worker formulas, rounding of fractional CPUs and host (kernel) settings are not in the standard:
  the project chooses and explains its choice in `tuning.md`; `catalog/` keeps sourced notes.

The template carries the method: `docs/how-to/tuning.md`, `scripts/tuning-check.sh`, the
PostgreSQL flags and `memswap_limit` in the stage and prod files.

## Options considered

- **The level.** A: M only where the factory settings are known not to fit, R for the rest
  (chosen). B: M for every component, which makes a project tune things whose defaults are fine. C:
  R for all, which leaves PostgreSQL on 128 MB of shared buffers.
- **Where the derived numbers live.** A: in `.env` next to the limits, explained in `tuning.md`
  (chosen). B: only the limits in `.env`, and an entrypoint computes the rest at start: code in
  every image and a writable config path under `read_only`.
- **A number of processes.** A: from the measured memory of one process (chosen). B: from the worst
  case, `memory_limit` × processes, which leaves each request little: in 512 MB with 128 MB of
  opcache and 8 processes, (512 − 128) ÷ 8 = 48 MB per request.
- **Swap.** A: `memswap_limit` equal to the memory limit (chosen). B: Docker's default, up to as
  much swap again where the host has swap.
- **Sources that disagree** (`random_page_cost` for SSDs: the wiki 2.0–3.0, the
  PostgreSQL 17 and 18 docs no number). A: the default until measured (chosen). B: follow one source.
- **Worker formulas** (gunicorn gives both (2 × cores) + 1 and 2–4 × cores). A: not in the standard
  (chosen). B: name one.
- **Fractional CPUs.** A: not in the standard (chosen). B: round up, at least 1.
- **How PostgreSQL gets its numbers.** A: `-c` flags in `command:` (chosen). B: a
  `postgresql.conf` with the numbers, which cannot read variables.
- **Host settings** (Redis `vm.overcommit_memory`, huge pages). A: not in the standard (chosen),
  they are outside a project. B: list them.
- **A fixed list of values in the standard**, or **leaving tuning to each project with no
  method**: the first is wrong as soon as the server or the version changes; with the second the
  defaults stay forever.

## Consequences

Every project explains each tuned value once, in `tuning.md`, and a check catches a value that fell
back to its default or a `.env` change not applied yet. Changing a limit means deriving its numbers
again by hand, writing both in `.env` and running `make restart`. When `make tuning-check` fails
after a deploy, the new containers already run and the history names them, so the fix is a value in
`.env` and `make restart`; before this was recorded, the history still named the old version and
`make restart` refused. Without swap, a container that
outgrows its limit is stopped by the OOM killer instead of slowing down, so the limits are measured.

## Verified

Checked on 2026-10-20, Docker 29.7.2, Compose v5.5.0 (WSL2, the host has 4 GB of swap); the first two items are one-off runs, the third is repeated by `make check`:
- (one-off run, 2026-10-20) `memswap_limit: ${M:?}` with `deploy.resources.limits.memory: ${M:?}` (`M=512M`): `docker inspect`
  shows `Memory` and `MemorySwap` both 536870912, and the cgroup `memory.swap.max` is 0; without
  `memswap_limit`, `MemorySwap` is 1073741824 and `memory.swap.max` 536870912. `docker compose
  config --format json` renders both values in bytes.
- (one-off run, 2026-10-20) PostgreSQL 16.15 (`postgres:16-alpine`): `shared_buffers = '${X}'` in a config file, with `X` set
  in the environment, stops the server (`invalid value for parameter "shared_buffers": "${X}"`);
  `-c shared_buffers=256MB` gives 256MB. PostgreSQL 16.15 (`postgres:16`): `-c shared_buffers=32768`
  gives 256MB too (8kB blocks), while `pg_size_bytes('32768')` is 32768 bytes, so a size in `.env`
  carries a unit.
- `tests/project/run.sh`: after `make stage`, `make tuning-check` prints `ok` for the limits,
  `memswap` and both PostgreSQL settings; a changed `DB_SHARED_BUFFERS` in `.env` turns it red
  until `make restart` applies it; a `DB_SHARED_BUFFERS` without a unit turns it red with its own
  message. When the check fails at the end of a deploy, the history holds the new commit and
  `make restart` works after the value is fixed (2026-10-21).

## Sources

- <https://docs.docker.com/reference/compose-file/services/> — “If `memswap_limit` is unset, and `memory` is set, the container can use as much swap as the `memory` setting, if the host has swap memory configured.”
- <https://docs.docker.com/engine/containers/resource_constraints/> — “if the host machine has two CPUs and you set `--cpus="1.5"`, the container is guaranteed at most one and a half of the CPUs.”
- <https://github.com/torvalds/linux/blob/master/Documentation/admin-guide/cgroup-v2.rst> — `shmem`: “Amount of cached filesystem data that is swap-backed, such as tmpfs, shm segments, shared anonymous mmap()s”
- <https://www.postgresql.org/docs/current/runtime-config-resource.html> — `shared_buffers`: “The default is typically 128 megabytes (`128MB`)”; “If you have a dedicated database server with 1GB or more of RAM, a reasonable starting value for `shared_buffers` is 25% of the memory in your system.”
- <https://www.postgresql.org/docs/current/runtime-config-query.html> — `effective_cache_size`: “The default is 4 gigabytes (`4GB`).”
- <https://www.postgresql.org/docs/17/runtime-config-query.html>, <https://www.postgresql.org/docs/18/runtime-config-query.html> — `random_page_cost`, a direction with no number for SSDs: “if your data is likely to be completely in cache, such as when the database is smaller than the total server memory, or network latency is high, decreasing `random_page_cost` might be appropriate.”
- <https://github.com/docker-library/docs/blob/master/postgres/content.md> — passing settings to the server: “`-c shared_buffers=256MB -c max_connections=200`”
- <https://wiki.postgresql.org/wiki/Tuning_Your_PostgreSQL_Server> — “it's not unusual for administrators to standardize on always setting this between 2.0 and 3.0 instead.”
- <https://github.com/benoitc/gunicorn/blob/master/docs/content/design.md> — “workers = (2 × CPU cores) + 1”; <https://github.com/benoitc/gunicorn/blob/master/gunicorn/config.py> — “A positive integer generally in the ``2-4 x $(NUM_CORES)`` range.”
- <https://github.com/nginx/nginx/blob/master/src/os/unix/ngx_posix_init.c> — `ngx_ncpu = sysconf(_SC_NPROCESSORS_ONLN);`
