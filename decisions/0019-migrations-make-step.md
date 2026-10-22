# D-0019. Migrations are a `make` step before the application is replaced

> English · [Українська](0019-migrations-make-step.uk.md)

**Status:** accepted · **Date:** 2026-10-18 · **Rules:** ENV-01, ENV-09

## Context

A new image often needs a new database schema. Where the migration runs decides what happens when it fails: whether the old application keeps serving, or the service is down.

## Decision

The migration step runs the project's migration command (`MIGRATE` in the `Makefile` settings) in a one-off container of the new `APP` image, with the shell as the entrypoint: `docker compose run --rm --entrypoint sh <app> -c <command>`. The image's own `ENTRYPOINT` is bypassed, so the runtime image needs `/bin/sh`, and a migration that needs the setup an `ENTRYPOINT` does includes it in the command. `make stage` and `make prod` run the step after building or pulling the new images and before `up` replaces the application, on every deploy, a re-deploy of the same commit included; `make migrate` is the dev target only: it runs the command in the dev container, and `make dev` runs it too. On a server the migration runs only as that step of a deploy, under the lock of the clone, and `make migrate` there refuses. A failure stops the command with the old application still running (`run` starts the dependencies of the service first, and a dependency whose configuration changed, such as the database, is recreated by that start). Migrations stay compatible with the previous image, so `make rollback` works without undoing them and runs none.

## Options considered

- **A one-shot `migrate` service with `depends_on: condition: service_completed_successfully`.** Declarative, but tested on 2026-10-18 (Docker Engine 29.7.2, Compose v5.5.0): when the migration fails, `up` has already removed the old application container and leaves the new one in `Created`, so the service is down; and every later `up` runs the exited migrate container again.
- **A `make` step with `run --rm`.** Tested the same day: a failing migration exits 1, and the running application container keeps the same ID and stays healthy.
- **`run --rm <app> sh -c <command>`, as the template first had it.** `run` replaces the image's `CMD` but not its `ENTRYPOINT`, so an image whose `ENTRYPOINT` is the server (common for Go and Rust) took the command as arguments, started the server, and the deploy hung under its lock. Measured on 2026-10-20 and 2026-10-21 (one-off runs, Compose v5.5.0): with an `ENTRYPOINT` that keeps running, only `timeout` ended the command (exit 124); with `--entrypoint sh` the command ran in 1 s, its exit code passed through, and quotes and `$` reached the container's shell. An image without `/bin/sh` fails either way (`exec sh failed`). The sample project of `tests/project` has an `ENTRYPOINT` in its runtime image, so every deploy of that test exercises the form.
- **The application migrates on start.** No extra step, but the migration runs only after `up` has stopped the old container, so a failure leaves the service down; and with `restart: always` a failing migration would repeat in a loop.

## Consequences

A failed migration does not stop the running application. check-compose stays strict: no one-shot services, `depends_on` only with `service_healthy` ([D-0009](0009-compose-rule-check.md)). The price is two rules for the developer: a migration must not break the previous image, so a destructive change is split over two releases; and it must be idempotent, because a re-deploy of the same commit runs it again, so a migration already applied changes nothing.

## Sources

- <https://raw.githubusercontent.com/docker/compose/main/docs/reference/compose_run.md> — “Runs a one-time command against a service.”
- <https://raw.githubusercontent.com/docker/compose/main/docs/reference/compose_run.md> — “This runs a database upgrade script, and removes the container when finished running, even if a restart policy is specified in the service configuration.”
- <https://raw.githubusercontent.com/docker/compose/main/docs/reference/compose_run.md> — “If you start a service configured with links, the run command first checks to see if the linked service is running and starts the service if it is stopped.”
- <https://raw.githubusercontent.com/docker/compose/main/docs/reference/compose_run.md> — `--no-recreate`: “If dependent containers already exist, don't recreate them, even if their configuration diverged” (on the default branch; absent from v5.5.0, so the default of recreating a diverged dependency is shown by the code below, not by a released page).
- <https://raw.githubusercontent.com/docker/compose/v5.5.0/pkg/compose/run.go> and <https://raw.githubusercontent.com/docker/compose/v5.5.0/pkg/compose/reconcile.go> — `startDependencies` calls `Create` with no `Recreate` policy, and `mustRecreate` recreates when the container's `ConfigHash` differs from the expected one (read in the source, not run).
- <https://docs.docker.com/reference/cli/docker/compose/run/> — `--entrypoint`: “Override the entrypoint of the image”.
- <https://raw.githubusercontent.com/docker/docs/main/content/reference/compose-file/services.md> — “`service_completed_successfully`: Specifies that a dependency is expected to run to successful completion before starting a dependent service.”
