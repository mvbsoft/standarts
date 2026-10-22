# D-0021. Deploy, restart and roll back with `make` commands in the server clone

> English · [Українська](0021-ship-deploy-rollback.uk.md)

**Status:** accepted · **Date:** 2026-10-18 · **Rules:** ENV-09

## Context

Each project deployed in its own way: some built on the server, some ran compose commands from a runbook, some had no way back. Every manual step is one that someone skips under pressure.

## Decision

- **`make stage` / `make prod`** (server clone): before it changes anything it refuses unless `PROJECT_ENV` matches, no value in `.env` is still `change-me`, `.env` and the build-secret files are readable by their user only, this is the only copy of the environment on the machine ([D-0003](0003-several-environments.md)), no other deploy holds the lock of the clone, and the clone is clean; and where the disk may lack room for a build (twice the own images plus `DISK_RESERVE`, [D-0025](0025-images-built-on-the-server.md)) it warns and asks instead of refusing, because that is an estimate. Then it pulls the configured branch fast-forward only; continues in the new `Makefile` through a sub-make; then `make bootstrap`, `parity`, `check-compose`, a build of every own image of that commit the server lacks and a pull of the missing third-party images, the save of the logs of the containers it may replace (OPS-03), a backup set right before the migration (OPS-01; with the backup service and `MIGRATE` set, not on a clone's first deploy), the migration step ([D-0019](0019-migrations-make-step.md)), `docker compose up -d --wait --remove-orphans` for every service except `backup`, then `backup` without waiting (an unhealthy backup prints a warning and does not stop the deploy, OPS-01), a line in `.deploy/history`, the removal of own images older than the last `KEEP_IMAGES` (5 by default) deployed commits, and last `make tuning-check`: a failed check fails the command, but the history already names the commit that runs, so `make restart` after the fix works. Each step stops the command on failure; a failed backup before the migration warns and asks instead (ENV-09). How a change reaches the prod branch (a pull request, a merge, branch protection) is the project's own choice; `make prod` deploys what is in it.
- **`make restart`** (server clone): applies a changed `.env` to the commit that runs now, with no branch move and no migration; the same `up` recreates only the containers whose configuration changed, then `make tuning-check`. It refuses when the checked-out commit is not the one deployed last, and it is not recorded, so `make rollback` ignores it. A changed `.env` → `make restart`; a new version → `make stage` / `make prod`.
- **`make rollback`** (server clone): deploys the previous commit from `.deploy/history` the same way, without migrations; it builds that commit's images again if they were removed, and counts free space only for the images it has to build.

## Options considered

- **A CI pipeline that deploys to the servers.** Automatic, but every server must accept a connection from CI, and the project needs a CI.
- **Compose commands from a runbook.** Nothing to maintain, and every deploy is a little different.
- **`make` targets run in the server clone.** One command per step, the same in every project, and the server needs only docker, git, make and sh.
- **A `make` target that moves the prod branch to the stage commit, fast-forward only.** Prod runs exactly the stage commit, but it goes around the project's pull requests and branch protection; a merge into the prod branch has the same content anyway, so it gets images of the same content ([D-0025](0025-images-built-on-the-server.md)).
- **Kamal.** Pushes the image to a registry (D-0025 rejects one), and routes traffic to the new container only once it answers `200 OK` on `GET /up`, so a deploy has no downtime, which we lack.
- **Dokku.** Builds on the server from a `git push`, and reads no Compose files; Compose support is an open proposal (issue 5102).
- **Coolify.** Builds on the server where the application is deployed by default, and its rollback deploys an older image retained on the server, like ours; but it parses the Compose definition and adds configuration to it, so the file in git stops being what runs.
- **CapRover.** Sends the current git commit to the server, and its revert in the web interface does not revert the environment variables.
- **A changed `.env` applied by `make stage` / `make prod`.** No extra command, but after `make rollback` it moves the server back to the newest commit of the branch, the one just rolled back from.

## Consequences

Tested on 2026-10-18 (Docker Engine 29.7.2, Compose v5.5.0; one-off run): `up -d --wait` replaces a changed container by stopping the old one first and then starting the new one, so an update has seconds of downtime, longer when PID 1 ignores SIGTERM (`init: true` makes SIGTERM end a process that installed no handler of its own; one that ignores it still waits for the 10 s grace period); unchanged services such as the database are not restarted, and data in named volumes survives. When a new container never becomes healthy, `up -d --wait` prints `container ... is unhealthy` and exits 1, and the old container is already gone, so the fix is `make rollback`: `up` with the previous tag restores it. An image already on the server is not pulled again (`--pull missing` with a locally present tag did not touch the network), so `up` uses the images built on the server. Tested on 2026-10-19 (Docker Engine 29.7.2, Compose v5.5.0; one-off run): after a value in `.env` changed, a plain `docker compose restart` kept the container's old value, while `up -d` recreated the container with the new one. A deploy without downtime needs a front proxy that switches traffic; it is not part of the standard yet. If it is added, kamal-proxy (it can run standalone) would be compared with Caddy, Traefik and nginx in a decision of its own; it would change the deploy step, the `check-compose` rules and the rollback.

## Verified

Checked on 2026-10-19, Docker 29.7.2, Compose v5.5.0, git 2.43.0 (WSL2), with `tests/project/run.sh`: a sample project made from the template, a local bare remote, and its stage and prod clones on the same machine. The steps are checks of that test; the sizes and times below are one-off readings of that run (2026-10-19), which the test does not assert.
- A first deploy: `make stage` in a new stage clone, which built both images (app 43 MB, backup 127 MB); 16–20 s.
- A re-deploy: a second `make stage` of the same commit; it built nothing, and the image ID and the container stayed the same; 6–8 s. Its migration ran again while the running version served.
- A new commit: `make stage`; 11–15 s.
- A failed build: a commit with a broken Dockerfile line; `make stage` stopped with `building … failed (above); nothing was replaced`, the old container kept serving, `.deploy/history` was unchanged and no image of that commit was left.
- A failed migration and a container that never became healthy: the old version kept serving after the first; after the second, `make rollback` brought the previous commit back.
- Rollback: `make rollback` with the previous images kept 6–7 s; after they were removed it said `rollback: building the images of <sha> again (they were pruned)` and took 9–11 s. Neither ran a migration (`migrate: skipped (rollback)`), and a rollback that failed printed `make rollback did not finish (above): this clone is left at <sha> (detached HEAD); make stage deploys the main branch again, make rollback deploys <sha>`.
- Prune: deploys and rollbacks of six distinct commits, with two foreign images present (`<repo>-app:by-hand`, and an image of another name with a tree-hash-like tag); the images of the oldest commit went, exactly the trees of the last 5 deployed commits stayed, and both foreign images, `busybox:latest` and the dev image were untouched.
- Prod: a `--no-ff` merge of the stage branch into the prod branch; `make prod` in a prod clone on the same machine built nothing and took 16–17 s; a fix made only on the prod branch was built there.
Since 2026-10-21 the same test also checks: the deploy order above (a failed tuning check leaves the history with the new commit, and `make restart` then works); the refusal for free space before anything changes (a reserve larger than the disk: the commit, the history and the container are unchanged); the refusal of a second copy of an environment; the refusal of a `.env` that other users can read; the archive of the logs of a replaced container.
Not checked: stage and prod on separate machines (on one machine prod reused the images stage built), a real remote server, a private dependency with build credentials, and the growth of the build cache over many deploys.

## Sources

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
