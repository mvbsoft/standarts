# Server runbook

<!-- project template 1.0.0 — a starting point (standard DOC-04): fill in the names; keep every scenario that applies. -->

Every scenario in the order you meet them. Commands run in the server's clone of the repository
unless a step says "on the dev machine". The daily commands are in the
[README](../../README.md#working-with-this-project).

## The first server from scratch

1. Install the server's host tools (standard PRN-01: Docker with Compose, `git`, `make`). Nothing
   else. The server builds the
   project's own images itself, so it needs to reach the base images and the package sources the
   Dockerfiles name, and room for a build next to the running application.
2. Give the server read access to the repository (for GitHub, a deploy key without write access),
   then clone it into its own folder, one clone per environment, and check out the branch: stage
   follows `<STAGE_BRANCH>`, prod follows `<PROD_BRANCH>` (if the repository has no
   `<PROD_BRANCH>` yet, create it on the dev machine: `git push origin <STAGE_BRANCH>:<PROD_BRANCH>`).
   A machine runs one copy of each environment ("One copy of each environment per machine" below).
3. `cp .env.example .env && chmod 600 .env`, then set `PROJECT_ENV=stage` (or `prod`), every secret,
   every `change-me` replaced (`DB_PASSWORD` for the database superuser, `APP_DB_PASSWORD` for the
   application's own role, `STATUS_TOKEN`), `DOCKER_GID` (the group that owns the Docker socket:
   `stat -c %g /var/run/docker.sock`), `LOG_LEVEL` (prod: `info` or higher), the limits, the ports,
   `DISK_RESERVE` and `LOG_ARCHIVE_DIR` ("Logs of replaced containers" below). If the `Makefile`
   setting `BUILD_SECRETS` names files, put each in this clone ("Update" below) and `chmod 600` it
   too: `make stage` and `make prod` refuse a `.env` or such a file that other users of the machine
   can read. Keep a copy of the secrets, above all `BACKUP_COPY_PASSWORD`, in a safe place outside
   the server.
4. Point the server's front proxy at the `127.0.0.1` ports set in `.env`, `STATUS_PORT` too, for
   `https://<host>/status` ("Monitoring" below); the front proxy is not part of the project.
5. `make stage` (or `make prod`). The first one builds every own image ("Update" below), so it
   takes longer than the next ones. It prints `OK: stage runs <commit>`, then the `prune:` line.
6. Set up the backups' off-server copy and heartbeat (`BACKUP_COPY_TO` and the rest,
   `BACKUP_HEARTBEAT_URL`: [backups](backups.md)) and the monitor of the `status` service
   (`STATUS_PUSH_URL`, `STATUS_PUSH_FAIL_URL`: "Monitoring" below), apply them with
   `make restart`, then prove the copy: `make backup-copy-check` prints `OK` or the reason.

## Update

On the stage server: `make stage`. What it does, step by step: refuses in a clone that is not
stage, still has a `change-me` in `.env`, has a `.env` other users can read, is a second copy of
stage on this machine, or has a `DOCKER_GID` that is not the group of the Docker socket; takes the
lock of the clone (`.deploy/lock`: one deploy, rollback, restart, images or restore at a time);
refuses when the clone has local changes; warns and asks when the disk where Docker keeps the
images has less free space than two times the own images plus `DISK_RESERVE` ("Images on the
server" below; otherwise it prints `space: <free> free where Docker keeps the images (need <X>)`); takes the stage branch (a fast-forward to origin only); creates the
external networks and refuses a default-named compose file in a parent folder; checks the files
(`parity`, `check-compose`); builds every own image (`IMAGES` in the `Makefile` settings) that this
server does not have yet for the content of that commit, and pulls the other images it lacks;
saves the logs of every container it may replace ("Logs of replaced containers" below); runs
the migrations from the new image (on every deploy, so a migration already applied must change
nothing when it runs again), as `sh -c "<MIGRATE>"` in a one-off container of `APP` that bypasses
the image's `ENTRYPOINT`, so the runtime image needs `/bin/sh`; replaces the containers whose image or configuration changed, leaves
the rest running and waits until every service but `backup` is healthy (an unhealthy `backup` only
prints a `WARNING`); records the deploy and prints `OK: stage runs <commit>`; removes the images
of older deploys ("Images on the server" below); checks the tuning last, so a failed check fails
the command while the history names the commit that runs. A failure in any step stops the command, and what already runs keeps
running (nothing is replaced before the images and the migration have succeeded). The update has a few seconds
of downtime while a container is replaced.

The application logs in to the database with its own role (`APP_DB_USER`, `APP_DB_PASSWORD`),
never as the superuser, whose password (`DB_PASSWORD`) only the `db` and `backup` services get.
`db` reports healthy only once that role logs in; until then its health check creates the role,
or sets its password and rights again (on a new volume, on a database made before the role, after
a changed `APP_DB_PASSWORD`). The role may create in the schema `public`, so it owns what the
migrations create there. A project whose tables the superuser created (it ran as the superuser
before) gives them to the role once, as the superuser, in the `db` container:
`printf '%s\n' "SELECT format('ALTER TABLE %I OWNER TO app', tablename) FROM pg_tables WHERE schemaname = 'public' AND tableowner = 'postgres' \gexec" | psql -U postgres`
(with the value of `APP_DB_USER` for `app`; sequences and views the same way).

The build takes the commit itself (`git archive`), not the folder: nothing uncommitted, untracked
or ignored in the server's clone, `.env` included, reaches an image, and a commit with git
submodules is refused. Each image prints `build: <repo>-<image>:<tree> from commit <sha>`, then
`build: <repo>-<image>:<tree> built in N s`. The image is tagged with the commit's tree hash, so a
commit with the same content (a re-deploy, a merge that changes nothing, a rollback) reuses the
image already on this server and builds nothing. The build runs while the old version keeps
serving: it uses the server's CPU, memory and network for as long as the Dockerfile's steps take.
`make images` builds and pulls the images of the checked-out commit the same way and starts
nothing, for example ahead of a planned switch. A server runs the migrations only within
`make stage` / `make prod`, under the lock of the clone; `make migrate` there refuses
(`make migrate runs only in dev: …`).

The build pulls its base images without credentials, so they must be public. A package it fetches
from a private source gets its credentials as a build secret, never as a build argument or a copied
file, which would stay in the image: the credentials go into a file in this clone that git ignores
(for example `.env.<name>`), the `Makefile` setting `BUILD_SECRETS` names it as `<id>=<file>`, and
the Dockerfile step that needs it reads it with `RUN --mount=type=secret,id=<id>`. The image never
holds the file. The dev machine needs the same file for `make dev` and `make image-scan`, and
`docker-compose.dev.yml` gives each secret to the dev build too (`secrets: [<id>]` in `build:` of
`dev`, and `<id>: {file: <file>}` in its top-level `secrets:`; its comments show both), so a step
of the base stage that reads it builds in dev as well; `make dev` refuses while the two differ.

## Stage to prod

When stage is checked, run `make image-scan` on the dev machine on `<STAGE_BRANCH>` up to date with
origin: it builds the images of that commit the way a server does and scans them with trivy, by
the project's `trivy.yaml` and `.trivyignore`. The images it builds stay on the dev machine (a scan
of the same content again builds nothing): `docker images '<repo>-*'` lists them with their
tree-hash tags, and `docker rmi <repo>-<image>:<tree>` removes one (an image a container uses
stays). Then get the change into `<PROD_BRANCH>` the way the
project does it (for example a pull request from `<STAGE_BRANCH>`), then `make prod` on the prod
server. The prod server builds its images itself, from the same content stage ran: base images
pinned by digest and dependencies from lock files keep the two builds equal in content, though not
byte for byte.

## Images on the server

The own images are `<repo>-<image>:<tree hash>`. After each deploy, `prune` keeps those of the last
`KEEP_IMAGES` (a `Makefile` setting, 5 by default) distinct deployed commits and of the commit that
runs, and removes the older ones: `prune: removed N old images; the images of the last 5 deployed
commits stay` (5: the value of `KEEP_IMAGES`).
It removes only images named that way; other images, and one a container still uses, stay.

- Stage and prod on one machine use the same image names, so each one's prune may remove the
  other's older images; a later `make rollback` there builds them again, which costs only the
  build time.
- Before it builds or replaces anything, every `make stage`, `make prod`, `make images`,
  `make rollback`, `make restart` and `make restore` (on a server) reads the free space where
  Docker keeps the images, with `df` in a container of an image of the compose file this machine
  has (the third-party ones first, then the own ones, until one has `df`; on Docker Desktop and
  with the containerd image store, a `df` on the host reads another disk), and warns below two times the own images (each with its
  largest version on this machine, as `docker images` shows its size) plus `DISK_RESERVE` of `.env`
  (with no own image yet, `DISK_RESERVE` alone). That is an estimate, so it does not stop the command
  by itself: it says how much is needed, how much there is and what can go wrong, and asks. In a
  terminal it asks `Go on anyway? [y/N]` and only `y` or `yes` goes on; without a terminal (an agent,
  a script) it stops, unless `RISK=yes` is on the command line of that `make` (as `CONFIRM=yes`
  for a restore, it counts nowhere else). An agent adds `RISK=yes` only after the owner's yes.
  `make restart` and `make rollback` count only the
  own images of their commit that this machine lacks, because only those can be built: with none
  missing they check nothing and ask nothing (`space: not checked: …`); `make stage`,
  `make prod`, `make images` and `make restore` keep the full count. A machine with none of the
  file's images yet, or with none that has `df`, is not checked and says why
  (`space: not checked: …`).
- Docker keeps the build cache, which speeds up the next build but grows; the template never
  removes it. `docker system df` shows it (`Build Cache`), and
  `docker builder prune --filter until=720h` removes the cache older than 30 days.

## One copy of each environment per machine

Stage, and prod, run from one clone on a machine. Compose names a project's containers and
volumes after its `name:` line, so a second clone of stage would take over the first one's
containers, volumes and data (the database, the backups), and no one could tell which version
runs or where the data goes. `make stage`, `make prod`, `make images`, `make rollback`,
`make restart`, `make restore` and the backup commands of a stage or prod clone refuse while
containers of its project, stopped ones too, carry another folder in the label Compose gives them:
`<project> already runs from <folder> …`, with no setting that skips it. In dev, a plain second
clone is refused the same way: without a `.env` yet, `make dev` refuses before it writes one, and
`make dev NAME=<n>` gives the clone a stack of its own; with a `.env` already there (a copied
folder), `make dev` and every command in the dev container refuse, and `DEV_SUFFIX=-<n>` with an
empty `APP_PORT=` in its `.env` gives it its own (`NAME=` counts only while there is no `.env`).
To move the environment
to this clone, stop it in the other folder with `docker compose -p <project> down` (the volumes
stay), then `make stage` (`make prod`) here. Volumes carry no folder: after that `down`, or when
only the volumes of an earlier clone are left, nothing can tell whose they are; the first deploy
of a clone then uses them and says so (`WARNING: the volumes of <project> exist, but no container
of it: …`). Dev can have several copies only because each gets its own `DEV_SUFFIX`.

## Logs of replaced containers

Docker removes a container's logs with the container. Before `make stage`, `make prod`,
`make rollback` or `make restart` replaces containers, it saves what Docker still holds of each
container it may replace (its configuration or image changed, or its service is gone; stopped
containers too; up to 10 MB × 3 per container) to `<LOG_ARCHIVE_DIR>/<UTC time>-<service>.log`,
with Docker's timestamps, and prints `log-archive: <file>`. `LOG_ARCHIVE_DIR` is a folder of `.env`,
relative to the clone or absolute (`.deploy/logs` by default; empty: no archive). Nothing removes
old files there: the folder grows until you remove them, by hand or with a cron job such as
`find <LOG_ARCHIVE_DIR> -name '*.log' -mtime +90 -delete`. The logs of the containers that run
are `make logs`.

## Monitoring

The `status` service tells a monitor on another machine whether this environment is healthy, so
that you hear about a failure from an alert and not from a user. It reads, through its read-only
socket proxy `status-proxy`, the health Docker keeps for each container of this compose project
(the `healthcheck:` of the service) and the free space of two disks, and answers with one JSON.
It finds the containers by the compose project, so a service added later is watched with no
setting (a one-off `docker compose run` container is left out). The proxy is the only thing that
touches `/var/run/docker.sock`: it lets `status` list the containers and inspect those named
`<project>-<service>-<n>`, refuses every other path (403) and every method but GET (405), and runs
as `nobody` in the group that owns the socket (`DOCKER_GID`). `make bootstrap` writes it only into a new `.env` in dev; a server's `.env` is made by hand, so set it there (`stat -c %g /var/run/docker.sock`).
`status` reaches Docker only through the `status-proxy` network, which has no way out, and
publishes no port but `127.0.0.1:${STATUS_PORT}`.

**Reach it.** Point the server's front proxy at `127.0.0.1:${STATUS_PORT}` for
`https://<host>/status`, TLS only (the token travels in a header), as for the site. Ask it by hand:
`curl -H "Authorization: Bearer <STATUS_TOKEN>" https://<host>/status`. `STATUS_TOKEN` is a long
random value (`openssl rand -hex 32`; under 16 characters the service refuses to start). A request
without the token or with a wrong one gets 401 and no details, also while the status is `fail`.
`GET /health` needs no token and says only whether the service can read Docker; it is the
container's own healthcheck.

**The answer** has `project`, `ok`, `checked_at`, `status`, `services` and `disk`, and `error`
when Docker cannot be read. `status` is the one word a monitor needs:

| `status` | When | `ok` | `GET /status` |
|---|---|---|---|
| `pass` | every service `healthy` (or `none`), every disk `healthy` | true | 200 |
| `warn` | nothing failed, but a service is `starting`, as after a deploy | true | 200 |
| `fail` | a service `unhealthy`, `down`, `missing` or `unknown`; a disk `unhealthy`; or Docker unreadable (`error`) | false | 503, same body |

Every entry of `services` has `status`, `failing`, `ms` and `output`:

- `status`: `healthy`, `unhealthy` and `starting` are Docker's own result of the service's
  healthcheck. `none`: it runs with no healthcheck (counts as up). `down`: the container is not
  running (stopped, exited, restarting). `missing`: a service `status` has seen since it started
  is gone. `unknown`: Docker refused the inspect of the container (a `container_name` outside
  `<project>-<service>-<n>`) and its list has no health either.
- `failing`: how many checks in a row failed. Above 0 while `healthy` is an early sign: Docker
  turns a container `unhealthy` only after its `retries` failures in a row.
- `ms` and `output`: how long the last check took and what it printed (cut at 4096 bytes), from a
  check that ran since the container last started; null until then. A healthcheck must never
  print a secret: the output is in the answer and goes to the monitor.

`disk.docker` is the disk where Docker keeps its data (the images), `disk.backup` the disk of
`BACKUP_DIR`; each has `status`, `free_bytes`, `free_pct` and `min_free_bytes`. A disk is
`unhealthy` below `DISK_WARN` (a percentage, `10%` by default, or a size, `20G`) and never below
`DISK_RESERVE`; `DISK_WARN=0` means `DISK_RESERVE` alone. A deploy needs more than the reserve:
twice the own images plus `DISK_RESERVE` ("Images on the server"). `status` does not work that sum
out, so to be warned before a deploy warns about the space, set `DISK_WARN` above it for the disk of the images.
The service reads only the free space of the backup folder, never its sets.

**Push.** Every `STATUS_PUSH_INTERVAL` (`60`, `60s`, `5m` or `1h`; `60s` by default) the service
POSTs the same JSON (`Content-Type: application/json`) to `STATUS_PUSH_URL` while the status is
`pass` or `warn`, and to `STATUS_PUSH_FAIL_URL` while it is `fail`. An empty address sends
nothing: with `STATUS_PUSH_FAIL_URL` empty, a monitor that waits for pings alerts on the silence;
with both empty nothing is pushed, and a monitor polls `GET /status` (200 is up, 503 is down).
A push that fails (no connection, an answer other than 2xx) is only logged, without the address,
which may hold a key, and the next round tries again. `make logs S=status` shows each change of
the status once, as `status: now <status>: pushing to <VAR>` (or
`status: now fail: no push, empty STATUS_PUSH_FAIL_URL`), and a failed push as
`status: push failed: HTTPError: Not Found` (a wrong or deleted address) or
`status: push failed: URLError: …`.

**Set up the monitor.** One monitor per environment, named for it (`<project>-stage`,
`<project>-prod`), on another machine than the server, which cannot report its own death. One
alert then covers one incident (a database that fails and takes the application with it), a new
service needs no new monitor, and the JSON says which service. Two examples:

- [Healthchecks.io](https://healthchecks.io/docs/), hosted or self-hosted: a check with a simple
  schedule, **Period** 1 minute and **Grace Time** 5 minutes (a deploy recreates `status` too).
  `STATUS_PUSH_URL=https://hc-ping.com/<uuid>` and
  `STATUS_PUSH_FAIL_URL=https://hc-ping.com/<uuid>/fail`: its documentation says of `/fail`
  “Signals to Healthchecks.io that the job has failed.”, while a plain ping counts as success
  whatever its body says, which is why a failure has an address of its own. It stores the body of
  a ping and shows it in the e-mail alert, so the alert names the service. A check takes at most
  5 pings a minute.
- [Uptime Kuma](https://github.com/louislam/uptime-kuma), self-hosted: a monitor of type **Push**
  with **Heartbeat Interval** 180 seconds (longer than `STATUS_PUSH_INTERVAL`).
  `STATUS_PUSH_URL=https://<its address>/api/push/<token>?status=up&msg=OK` and
  `STATUS_PUSH_FAIL_URL=https://<its address>/api/push/<token>?status=down&msg=status%20fail%3A%20see%20GET%20%2Fstatus`.
  Its push route reads only `status` and `msg` of the URL and ignores the body, so the alert says
  only that, and `GET /status` says which service. Or poll instead: a monitor of type
  **HTTP(s)** on `https://<host>/status` with the header
  `{"Authorization": "Bearer <STATUS_TOKEN>"}`; its accepted codes are 200-299 by default, so 503
  is down.

Set where the alerts go in the monitor itself, as for the backup's heartbeat ([backups](backups.md),
"Heartbeat"). The two are separate monitors: only the backup's own ping proves that the daily
backup happened. For prod, add one more monitor that fetches the public site itself (any 2xx or
3xx is up): `status` pushes from inside, so it cannot see a broken front proxy, certificate or
DNS. A self-hosted monitor is watched by nothing here: give it a watcher of its own.

**Prove the alarm once**, on stage, as for the backup's test alert: `docker compose -f
docker-compose.stage.yml stop status`, wait the period plus the grace time (or the interval of
the Uptime Kuma monitor), and see the alert; `start status` and see the recovery. Then
`stop app`: the monitor must alert at once on the failure address, and `GET /status` shows `app`
as `down`; `start app` again. Never stop `db` to test.

**Limits.** A service removed while `status` was down is not noticed (a deploy that changes the
code recreates `status`, so a service a deploy removes on purpose is no alarm). `status` reads
the disk of its own container and of the folder mounted into it: on Docker Desktop that is the
virtual disk, not the host drive. It reports health and free space, not CPU or memory.

## When something fails

| What you see | What it means | What to do |
|---|---|---|
| `building <repo>-<image> for commit <sha> failed (above); nothing was replaced` | a build step failed: a Dockerfile line, a package source that cannot be reached, a full disk; the old version still runs | read the output above; a fault in the code: fix it and ship again; the network or the disk: fix it, then `make stage` / `make prod` again |
| `git archive of commit <sha> failed (above); nothing was replaced`, or `unpacking commit <sha> failed (above); …` | the commit could not be read in full from this clone's git objects, or not unpacked into a temporary folder (a damaged repository, a full disk) | read the output above; `git fsck` checks the clone; free the disk; then run the command again |
| `make <target> (pid <pid>) is running in this clone; nothing was changed: run make <target> again after it ends` | another `make stage` / `make prod`, `rollback`, `restart`, `images` or `restore` runs in this clone; only one runs at a time (the lock `.deploy/lock`) | wait until it ends, then run the command again; if that pid is no `make` of this clone, remove `.deploy/lock` |
| `.deploy/lock has no owner: if no make stage, prod, rollback, restart, images or restore runs in this clone, remove .deploy/lock; nothing was changed` | the lock has had no owner file for 3 seconds: a `make` was killed with SIGKILL, or the machine stopped, right after it took the lock | check that none of these commands runs in this clone (`ps -ef`), remove `.deploy/lock`, run the command again |
| `commit <sha> has git submodules: an image built from it would lack their files; nothing was built` | the build takes the commit without its submodules | put the files into the repository instead of a submodule, ship again |
| `pulling <image> failed (above); nothing was replaced` | a third-party image could not be pulled: a wrong name or tag, or its registry cannot be reached | fix the name in the code and ship again, or fix the network and run the command again |
| `docker-compose.<env>.yml has no image <repo>-<image>:${IMAGE_TAG:?} for <image> in IMAGES (the Makefile settings)` | `IMAGES` names an image that the file's `image:` lines do not name that way | fix `IMAGES` or the `image:` line in the code, ship again |
| `the migration failed; the application was not replaced` | the migration stopped; the old version still runs (a dependency whose configuration changed, such as the database, may already be recreated). With `[FATAL tini (7)] exec sh failed: No such file or directory` above it (with `init: true`; without it, `exec: "sh": executable file not found in $PATH`), the runtime image has no `/bin/sh` | read its output above, fix it in the code (or add `/bin/sh` to the runtime image), ship again |
| `make migrate runs only in dev: on a server, make stage (make prod on prod) runs the migrations of the commit it deploys` | `make migrate` was run in a server clone; nothing ran | `make stage` / `make prod` deploys and migrates |
| `the backup service found too little free space for the set before the migration (above)` | the backup folder lacks room for the set (an estimate; the service's own line above says how much); the command asks, as for the free space | free space as in [backups](backups.md), "When something fails"; or go on (`y`, or `RISK=yes` without a terminal): the set is then made despite it, and if it fails the next question is the one below |
| `the backup before the migration failed (above): no fresh set was made` | on a server with the backup service, a deploy makes a set first (not on a clone's first deploy), and that backup failed; the command asks, as for the free space | read the output above (the lines of [backups](backups.md), "When something fails") and fix it; or go on (`y`, or `RISK=yes`), and the migration runs without a fresh set, here or off the server |
| `the backup before the migration made the local set, but its off-server copy failed (above)` | the local set was made, its copy was not | fix the copy (`make backup-copy-check`); or go on, and the migration runs with a fresh set on this server only |
| `you answered '<answer>', not y: stopped here`, `RISK=yes is not on the command line of this make: it came from MAKEFLAGS or GNUMAKEFLAGS of the environment, or from a make that runs this one, which accept no risk: stopped here` | the question was not answered `y`; or `RISK=yes` reached make another way than the command line of this `make` | nothing was replaced; run the command again and answer `y`, or type `RISK=yes` on its command line |
| `WARNING: the git hooks were not set (git config core.hooksPath .githooks): PROJECT_ENV is '<value>' in .env, not dev; set PROJECT_ENV=dev and run make bootstrap again` | `make bootstrap` found a `.env` that already existed with another `PROJECT_ENV`, so the pre-push hook is not installed in this clone | set `PROJECT_ENV=dev` in `.env` (a dev clone) and run `make bootstrap` or `make dev` again |
| `a container did not become healthy` | a new container (any service but `backup`) is up but unhealthy; the old one is already gone | `make rollback`, then read the printed logs and fix it in the code |
| `parity` or `check-compose` fails | the files break a rule | fix the files in the code, ship again |
| `… is a default-named compose file` | a `compose.yaml` or `docker-compose.yml` in this folder or a parent (an old stack?) would be picked up by a bare `docker compose up` | move or rename it, then run the command again |
| `this clone is PROJECT_ENV=…` | the command was run in the wrong clone | run it in the clone of that environment |
| `required variable … is missing a value`, then `… does not render with this .env (the error above names the variable); nothing was replaced` | `.env.example` gained a variable this server's `.env` lacks | add it to `.env` (its comment in `.env.example` says what it is) and run the command again |
| `a value in .env is still change-me` | a secret was left as the placeholder | set it in `.env` and run the command again |
| `a container did not become healthy with the changed .env` | `make restart` started a container with the new `.env` values and it is unhealthy | set the previous values back in `.env` and `make restart`, then find out what the new value needs |
| `the checked-out commit … is not the one deployed last` | the last `make stage` / `make prod` stopped halfway, so `make restart` would start a commit whose migrations did not run | `make stage` / `make prod` again (or `make rollback`), then `make restart` |
| `make rollback did not finish (above): this clone is left at <sha> (detached HEAD); make <env> deploys the <branch> branch again, make rollback deploys …` | a step of the rollback failed (a build, a container); the clone stays at the commit it was going back to | read the error above; then the line's `make <env>` returns to the branch, and another `make rollback` goes one deploy further back (or says there is none) |
| `KEEP_IMAGES=… in the Makefile settings is not a whole number of at least 1` | the new commit's `Makefile` has a bad `KEEP_IMAGES`; the deploy stopped before it built or replaced anything | set `KEEP_IMAGES` in the code, ship again, then `make stage` / `make prod` again |
| `the build secret <id> needs the file <file> (BUILD_SECRETS in the Makefile settings), which is not in this folder; nothing was replaced` | `BUILD_SECRETS` names a file this clone lacks; nothing was built | put the file there ("Update" above), then run the command again |
| `WARNING: backup unhealthy: <reason> (docs/how-to/backups.md)` | the release runs and is recorded; the backups need attention (a deploy does not wait for the `backup` service) | the reason is a line of [backups](backups.md), "When something fails" |
| `backup` is unhealthy in `make status` | the backup service names a reason: an old set or copy, a failed drill, a failed check of the copy | `make backup-status` says which; [backups](backups.md), "When something fails" |
| `tuning-check: FAIL …`, then `tuning-check failed (above), and <env> runs <sha>, recorded in .deploy/history: …` | the new version runs and is recorded, but a setting differs from `docs/how-to/tuning.md` | a value from `.env`: set it in `.env`, then `make restart`; a value in the code: fix it and ship again; if the service misbehaves meanwhile, `make rollback` |
| `<project> already runs from <folder> (its containers, stopped ones too, name that folder): a second copy of <env> on this machine would take over …; nothing was changed. …` | another clone of this environment runs on this machine ("One copy of each environment per machine" above) | keep that one; or stop it there with `docker compose -p <project> down`, then run the command here |
| `the dev project <name> already runs from <folder> (its containers, stopped ones too, name that folder): a second clone would take them over …; make dev NAME=<n> …; nothing was created` | `make dev` in a second plain clone without a `.env`: it would share the first clone's containers and database | `make dev NAME=<n>` with a name no other clone uses |
| `the dev project <name> also has containers from <folder> (stopped ones count): two clones of one dev project take over each other's containers and share its database. Stop it there (…), or give this clone a dev stack of its own: DEV_SUFFIX=-<n> and APP_PORT= (empty: a free port) in its .env, then make dev` | this clone's `.env` names the dev project of another clone (a copied folder) | set `DEV_SUFFIX=-<n>` and `APP_PORT=` in this clone's `.env`, then `make dev`; or stop the other one in its folder |
| `WARNING: the volumes of <project> exist, but no container of it: this first deploy of this clone uses their data …` | the first deploy of this clone found the volumes of an earlier or another clone | nothing, when this clone replaces that one; otherwise stop, and find out whose data it is |
| `.env can be read or written by other users of this machine (-rw-r--r--): chmod 600 .env` (or a file of `BUILD_SECRETS`) | the file of secrets is open to other users; nothing ran | `chmod 600 <file>`, then the command again |
| `not enough free space where Docker keeps the images: need <X> (2 × <Y>, the own images, and DISK_RESERVE=<R>), have <Z>`, in a terminal then `Go on anyway? [y/N]` | an estimate: a build next to the running images might fill the disk; nothing has changed yet | free space: `docker system df` shows what takes it; the build cache (`docker builder prune --filter until=720h`), old images, the log archive; then the command again. To go on anyway, answer `y`, or without a terminal add `RISK=yes` to the make command line. Never delete volumes |
| `not enough free space for the <backup or restore> in the backup folder (…): …` | the disk of `BACKUP_DIR` is too full for the backup service; the manual command warns and asks like the line above, the scheduled job refuses; nothing was written or replaced | [backups](backups.md), "When something fails" |
| `not enough free space for the log archive in <dir> (LOG_ARCHIVE_DIR): need <X> (30M for the logs of each of <n> containers, and DISK_RESERVE=<R>), have <Z>`, in a terminal then `Go on anyway? [y/N]` | the folder of the log archive lacks 30 MB per container to save plus `DISK_RESERVE`; an estimate, asked as above; a deploy may already have checked out the new commit and built its images | remove old files of the archive, then the command again; or go on, knowing that a log file that cannot be written stops the command before anything is replaced |
| `saving the logs of <service> to <dir> failed (above); nothing was replaced` | the folder of the log archive cannot be written; a deploy may already have checked out the new commit and built its images | fix the folder (or `LOG_ARCHIVE_DIR`), then the command again |
| `DISK_RESERVE is '…' in .env, not a size like 2G or 500M (or 0)` | a malformed `DISK_RESERVE` | fix it in `.env`, then the command again |
| `db` stays unhealthy, and its log says `password authentication failed` or `permission denied`, or the health check says `APP_DB_USER must not be the superuser postgres` | its health check cannot create or set the application's role: `APP_DB_USER` is the superuser, or a role it may not change | set `APP_DB_USER` to a role of its own, then the command again |
| `DOCKER_GID is '<value>' in .env, but /var/run/docker.sock belongs to group <gid>: set DOCKER_GID=<gid> (the socket proxy of the status service reads the socket as that group); nothing was changed` | `DOCKER_GID` in `.env` is not the group that owns the Docker socket on this server; without the fix `status-proxy` exits with `socket not available … permission denied` and the deploy fails with `dependency failed to start` | set `DOCKER_GID` to the number the message names (`stat -c %g /var/run/docker.sock`), then the command again. The commands that start or recreate `status-proxy` refuse it: `make stage`, `make prod`, `make restart`, `make rollback`; backup, restore and `make images` never depend on monitoring |
| `/var/run/docker.sock cannot be read here, but the socket proxy of the status service mounts it; nothing was changed` | the socket is missing or not readable by `stat` on this machine, and the proxy of the status service mounts it | start Docker, or run the command on the server whose Docker socket it is; then again |
| `status: STATUS_TOKEN has fewer than 16 characters: set a long random one in .env (openssl rand -hex 32)` in `make logs S=status` | the token is too short; the service did not start | set a long one in `.env` (the monitor that polls needs the same), `make restart` |
| `status: DISK_WARN is '…', not a percentage like 10% or a size like 20G (0: DISK_RESERVE alone)`, `status: DISK_RESERVE is '…', not a size like 2G or 500M`, `status: STATUS_PUSH_INTERVAL is '…', not like 60, 60s, 5m or 1h`, `status: STATUS_PUSH_URL is not an http:// or https:// address (empty: no push)` (also `STATUS_PUSH_FAIL_URL`) in `make logs S=status` | a setting in `.env` is malformed; the service did not start | fix it in `.env`, `make restart` |
| `"error": "cannot read the containers: …"` in `GET /status`, with `"status": "fail"` | `status` cannot read Docker through its proxy: `status-proxy` is stopped or unhealthy, or refuses | `make status`, then `make logs S=status-proxy`; the `DOCKER_GID` row above is the usual cause |
| `GET /status` has `"status": "fail"` and the monitor alerts | a service is `unhealthy`, `down`, `missing` or `unknown`, or a disk is `unhealthy` | the JSON names it: for a service `make logs S=<service>` and its `output`; for a disk, free space as in "Everyday checks" |
| the monitor alerts that no ping came | `status` or the server is down, or the push fails: the network, a wrong address | check that the server is up, then `make status`, `make logs S=status` (`status: push failed: …`) and the addresses in `.env` |
| `GET /status` answers 401 | no token, or not `STATUS_TOKEN` | send `Authorization: Bearer <STATUS_TOKEN>`; the monitor that polls needs the same value |

## Roll back

`make rollback` deploys the commit that ran before the current one, from `.deploy/history`, without
running migrations (they stay compatible with the previous version); a second `make rollback` goes
one further back. Its images are normally still on this server; when prune has removed them, it
builds them again first (`rollback: building the images of <sha> again (they were pruned)`). A
`make restart` is not recorded there (the commit stays the same); every deploy and rollback uses
the current `.env`. The next `make stage` / `make prod` returns to the branch, so fix the problem in
the code first.

## Everyday checks

- `make status`: the running commit and the health of every service.
- `GET /status`, or the alert of the monitor: the health of every service and the free disk space
  ("Monitoring").
- `make backup-status`: whether the backup service runs, its health and why, the newest sets and
  copy, the last result of every backup job.
- `make logs S=<service>`: follow the logs of one service until Ctrl-C; `make logs S=<service> TAIL=200`:
  print its last 200 lines and end.
- After a server reboot every service starts by itself (`restart: always`); `make status` shows it.
- A full disk: `docker system df` shows what takes the space; logs are capped at 10 MB × 3 per
  container; old own images go with each deploy and old backup sets rotate by themselves
  (`BACKUP_KEEP_DAILY`, `BACKUP_KEEP_WEEKLY`); the build cache stays until
  `docker builder prune --filter until=720h`, and the log archive until you remove its old files.
  Never delete volumes to free space. The deploys and the manual backup commands warn and ask before
  they may fill the disk (the scheduled jobs refuse).

## Secrets

To change a secret, or any other value in `.env`: edit `.env`, then `make restart`. It keeps the
commit that runs, runs no migration and recreates only the containers whose configuration the
change affects, then checks the tuning (an image of that commit removed by hand is built again
first, and an external network a changed name in `.env` points to is created). A new version is `make stage` / `make prod`, not `make restart`. A changed
`APP_DB_PASSWORD` needs nothing more: `db` sets it on the application's role itself. The
superuser's `DB_PASSWORD` is also changed inside the database first (the template's Postgres:
`ALTER ROLE <user> PASSWORD '<new>'` with `psql` in the `db` container, then `.env`). A changed
`STATUS_TOKEN` is also set in the monitor that polls `GET /status`. Of the backup copy:

- `BACKUP_COPY_PASSWORD`: first `restic key add` with the new password on the storage side, then
  `.env` and `make restart`; the storage side removes the old key afterwards. Changed in `.env`
  first, it fails with `wrong password for the repository …`.
- `BACKUP_COPY_LOGIN_PASSWORD`: change the htpasswd file of the storage side first, then `.env`
  and `make restart`; `make backup-copy-check` proves it.

## Backups and moving to a new server

How the backup works, how to check a restore and how to restore: [backups](backups.md). To move to a
new server: set it up as in "The first server from scratch" up to step 4, restore the data from the
off-server copy as [backups](backups.md#a-new-server-from-the-off-server-copy) says, then step 5,
`make prod` (or `make stage`).
