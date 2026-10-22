# Environments

> Version 1.0.0-draft · English · [Українська](02-environments.uk.md)

### ENV-01. Shape of each environment (M)

Which environments a project has is recorded in the registry profile
([DOC-03](06-docs.md#doc-03-component-registry-m)): the agent proposes them from the project type
([TYP-01](07-project-types.md)), the owner confirms once. Anything that runs anywhere other than a
developer machine has prod. Every environment the project has follows its column below.

| | dev (`docker-compose.dev.yml`) | stage (`docker-compose.stage.yml`) and prod (`docker-compose.prod.yml`) |
|---|---|---|
| Code | bind mount at an identity path (the same absolute path inside and outside), uid = host uid | baked into the image, owned by root, `read_only` where possible |
| Images | own images built on the machine from the `dev` stage; third-party images pulled | own images built on the server by `make stage` / `make prod` from the `runtime` stage of the deployed commit, tag = the git tree hash of the commit, no image registry ([ENV-09](#env-09-ship-deploy-and-roll-back-m-if-there-is-stage-or-prod)); third-party images pulled |
| Tools | one `dev` container with the whole toolchain + sidecar services (database, cache, test database) | no development tools |
| Data | named volumes declared in the file; tmpfs for the test database; a `backup` service with the `backup` profile that does not start by itself | named volumes declared in the file + a `backup` service that always runs ([OPS-01](03-operations.md)) |
| Start and update | `make dev` | `make stage` / `make prod` ([ENV-09](#env-09-ship-deploy-and-roll-back-m-if-there-is-stage-or-prod)) |
| Protection | no default-named file, so a bare `docker compose up` fails (`no configuration file provided`) | secrets have no defaults (`${X:?}`), so neither file renders without an `.env` that sets them; `make stage` / `make prod` refuse to run in a clone whose `.env` is not that environment's, while a value in it is still `change-me`, and while `.env` (or a build-secret file) can be read by other users of the machine (`chmod 600`: it holds every secret of the environment) |
| Healthcheck and restart | healthcheck on the sidecar services, which `dev` waits for; `dev` itself runs `sleep infinity` and has none (the application runs in it by `make run`); `restart` optional | healthcheck on every service; `restart: always`; `depends_on: condition: service_healthy`; `stop_grace_period` for databases |
| Limits | `cpus` / `mem_limit` for heavy jobs: the `mutation` service (`MUTATION_CPUS` / `MUTATION_MEM` in `.env`), a browser; `logging` `json-file` 10m×3 | `deploy.resources.limits` on every service, with `memswap_limit` equal to the memory limit, so nothing swaps beyond it ([OPS-02](03-operations.md#ops-02-tuning-to-resources-m-where-factory-settings-do-not-fit-r-otherwise)); `logging` `json-file` 10m×3 |
| Security | non-root, `no-new-privileges` | the same + `cap_drop: ALL` (adding back only a capability the service was shown to need, with the reason), `read_only` + tmpfs, no docker.sock (one template exception, see [ENV-03](#env-03-compose-rule-check-m-if-there-is-stage-or-prod)), published ports only on `127.0.0.1` (or `::1`) (public traffic arrives through the server's front proxy, which is not part of the project) |
| Migrations | `make migrate`, run by `make dev` | run by `make stage` / `make prod` from the new image before the application is replaced, on every deploy (a re-deploy of the same commit included), so a migration already applied changes nothing when it runs again; they stay compatible with the previous image, so a rollback works without undoing them |

What may differ between stage and prod, and what may not, is listed once, in
[ENV-02](#env-02-stage--prod-parity-m-if-there-are-stage-and-prod).

### ENV-02. Stage ↔ prod parity (M, if there are stage and prod)

Stage exists to prove what prod will run; whatever differs between them is not proved. So the code
and the way it runs are the same, and only the settings that must differ do.

Two complete files. Everything that may differ comes from variables in the server `.env`, so the
files differ only in the `name:` line. `make parity` compares
`docker compose -p parity -f <file> config --no-interpolate` of both files: one project name for
both, so the `name:` line and the network and volume names Compose derives from it are equal; any
other difference is an error. `parity` runs automatically: it is a step of `make infra` and of
`make stage` / `make prod` before anything starts, so a divergence fails the checks and never
reaches a server.

What may differ, through `.env`: domain and addresses, secrets, database and volume names, sizes,
limits and the numbers derived from them ([OPS-02](03-operations.md)), the log level (`LOG_LEVEL`,
[OPS-03](03-operations.md)), the notification channel and the monitoring addresses, TLS, host
ports, external network names, the backup and off-server copy settings
([OPS-01](03-operations.md)).

What may not differ, and so is written in the files and never taken from `.env`: images and their
versions (the database and the cache included), the set of services, start commands, `user`,
`cap_drop` / `cap_add` and `read_only`, healthchecks, a bind mount instead of baked code, a
substitute for a service. `IMAGE_TAG` is the one variable of an `image:` line, and `make` sets it
from the commit. `parity` compares the files before the variables are filled in, so it cannot see
a value that `.env` gives to a line of this second list; keeping those lines literal is the rule
the agent follows when it writes the files.

### ENV-03. Compose rule check (M, if there is stage or prod)

`parity` guarantees that stage and prod are the same; `make check-compose` guarantees that they are
equally correct. The script is taken verbatim from
[`templates/check-compose/`](../templates/check-compose/). It renders each of the two files that
exists from `.env.example` (so the example contains every required variable, with a non-empty
placeholder, `change-me` for a secret; a project without `.env.example` is not checked, and the
script says so and fails) and checks the rows of
[ENV-01](#env-01-shape-of-each-environment-m): ports only on `127.0.0.1` (or `::1`), secrets
required with `${X:?}` (no default, never empty), no `build:` (`make stage` and `make prod` build
the own images from the commit), the project's own images as `<repo>-<name>:${IMAGE_TAG:?}`
(`<repo>` is the file's `name:` without `-stage` / `-prod`) with a non-root `USER` in the `runtime`
stage of `docker/<name>/Dockerfile` or in a stage it is built from, every other image as
`<image>:<version>@sha256:<digest>` (the digest pins the content, because a tag can be pushed
again; the version beside it tells a reader which version it is, and is never `latest`),
non-root, healthcheck, `restart: always`, `depends_on` with `service_healthy`, limits,
`memswap_limit` equal to the memory limit, log rotation, `no-new-privileges`, `cap_drop: ALL`
(`cap_add` only as an exception with its reason), `read_only`, and no `privileged`,
`network_mode: host` or docker.sock, profiled services included.

The same pinning holds inside the Dockerfiles of the own images (every stage, `dev` included):
each `FROM`, `COPY --from=` and `RUN --mount=…from=`, and a `# syntax=` line, names its image as
`<image>:<version>@sha256:<digest>`, except `scratch` and an earlier stage of the same file; an image
named through a variable is refused, because the build may give it any value. A base image that
is not pinned lets two builds of the same commit start from different bases
([D-0025](../decisions/0025-images-built-on-the-server.md)).

The check is a step of `make infra` and of `make stage` / `make prod`, also when only one of the
two files exists. A deliberate exception goes only into the top-level `x-check-compose-allow` key
with a reason. A project's own exception also needs a row in section E of the registry with its
reason; one that the standard's own template carries (the root start of the `backup` service,
[OPS-01](03-operations.md); the socket proxy of the `status` service, which mounts the socket read-only and runs as
`65534:${DOCKER_GID}`, [OPS-04](03-operations.md), [D-0027](../decisions/0027-health-monitoring.md)) needs no row. It is not an image vulnerability scanner
([QLT-01](04-quality.md)).

### ENV-04. Several environments and copies on one machine (M)

One environment is one clone of the repository in its own folder with its own `.env`. Its
`PROJECT_ENV` variable (`dev`, `stage` or `prod`) says which environment the clone runs, and the
`make` targets of the other environments refuse to run there. Prod secrets never sit in a
development clone. The dev, stage and prod files have different `name:` values, so their
containers, networks and named volumes (`<name>_<volume>`) never meet. Host ports and external
network names are set by variables in `.env`, not by numbers in the files; the dev file writes a
host port as `127.0.0.1:${<NAME>_PORT-<default>}:<container port>`, so that an empty value lets
Docker pick a free port.

**Stage and prod: one copy of each per machine.** Compose names the containers, networks and
volumes of a project after its `name:` line, and a stage clone's `name:` is the same wherever it
is cloned. A second clone of stage on the same machine would therefore take over the first one's
containers and volumes: the database, the backups and the deploy history would be shared, and no
one could tell which version runs or where the data is written. So `make stage`, `make prod` and
the commands that work on a running stack refuse in a second copy, with no setting that allows
it, and point to stopping the first copy in its own folder. Compose labels containers with their
folder but not volumes, so the refusal is by containers (stopped ones count); when only the
volumes of an earlier copy are left, the first deploy of the new copy warns and goes on
([D-0003](../decisions/0003-several-environments.md)).

**Dev: several copies, each with a name of its own.** Dev can have more than one copy on a machine
only because each copy gets its own `DEV_SUFFIX`. When `make dev` runs in a git worktree (for
example a parallel agent session) and the copy has no `.env` yet, `make bootstrap` writes one
with `DEV_SUFFIX` set to the folder name and a short hash of its path (`-fix-3f9a1c`: worktrees
named alike in different places differ), so the dev file's `name: <project>-dev${DEV_SUFFIX:-}`
gives the copy its own containers and volumes (its own dev database, filled by `make seed`), and
with the host-port variables (`*_PORT`) left empty, so Docker picks free ports and `make dev`
prints them. Any other second clone gets the same when its first `make dev` is
`make dev NAME=<n>`; without that, `make dev` refuses in a second plain clone, because its
containers and database would be the first one's. Stage and prod keep fixed names, so parity is
not affected.

### ENV-05. `make` targets (M)

The same names and the same behaviour in every project ([PRN-10](01-principles.md)), and every
project's `Makefile` has every target, but for mutation testing below: one that does not apply to the project's type or
environments (registry profile) refuses and says why (for example `this project has no prod`) and
is left out of the README section ([DOC-04](06-docs.md)); only `parity` and `check-compose`, which
`make infra` and every deploy run, and `migrate`, which `make dev` runs, pass instead, with nothing
to do. The `Makefile` starts from [`templates/project/Makefile`](../templates/project/Makefile):
what differs between projects is only its settings block at the top (the own images, the
application service, the project's commands such as the migration and the checks, the `.env`
variables that name the external networks, the stage and prod branches) and its "Project targets"
block at the end. A command of the project's own (for example an asset build, a worker or a
report) is a target in that block, with a `## ` help text, so `make help` lists it under "This
project", and a row in the README section; its name is not the name of a standard target. An
update of the standard keeps both blocks. One exception to "verbatim outside the two blocks" and to "every target": mutation testing, when the owner says no to it ([`templates/README.md`](../templates/README.md#mutation-testing-declined)). The targets are thin wrappers over `docker compose`
(each with an explicit `-f`) and over the project's scripts.

`make help` lists the targets in groups by where they work, and the **Where** column says the
same with three values: **dev** (a development clone), **server** (the clone of a stage or prod
server), **any** (every clone). The checks have two floors ([QLT-03](04-quality.md)): the *base
targets* (`lint`, `test`, `e2e`, `security`, `infra`) each run the checks of one area and none
runs another, and the *group targets* (`gates`, `verify`) only run base targets and add no check of
their own; `gates` runs `lint`, `test` and the SECRETS step of `security` (its summary line is
`secrets`).

| Target | Where | What it does |
|---|---|---|
| `help` | any | lists the targets in groups (Dev, Checks, Servers, Any clone, Backups, Service, This project); plain `make` runs it |
| `bootstrap` | any | prepares the clone: `.env` from `.env.example` if missing (dev only; a second clone as in [ENV-04](#env-04-several-environments-and-copies-on-one-machine-m)), the git hooks (`core.hooksPath .githooks`), external networks, no default-named compose file in parent folders; reports what an existing `.env` lacks of `.env.example` instead of replacing it; `make dev` runs it every time |
| `dev` | dev | builds what changed, starts the dev stack, runs `make migrate`, prints the addresses (`NAME=<n>`: the stack of a second clone) |
| `shell`, `down` | dev | enter the dev box; stop the stack (never `-v`) |
| `seed`, `run` | dev | test data; run the application |
| `migrate` | dev | the dev target only: the migration command in the dev container; a server runs the migration step of the commit it deploys inside `make stage` / `make prod` ([ENV-09](#env-09-ship-deploy-and-roll-back-m-if-there-is-stage-or-prod)), and `make migrate` there refuses |
| `lint`, `test`, `e2e`, `security`, `infra` | dev | the base targets ([QLT-01](04-quality.md)); `infra` is `check-compose`, `parity` and, when the project has a backup service, `backup-test` |
| `gates`, `verify` | dev | the group targets: `gates` is `lint`, `test` and the SECRETS step of `security` (the secret scan, summary line `secrets`), fast and offline, and the pre-push hook runs it ([QLT-02](04-quality.md)); `verify` is `lint`, `test`, `e2e`, `security` and `infra`, before a finished task is merged; both end with one summary line per base target |
| `fix` | dev | the automatic fixers of the `lint` tools in their safe mode; by hand only, then `git diff` and `make gates` ([QLT-01](04-quality.md)) |
| `mutation`, `mutation-diff`, `image-scan` | dev | by hand only: mutation testing, and mutation testing of the changed code only (both exist only if the owner wants mutation testing, see above); build the own images of the checked-out commit the way a server builds them and scan them with trivy, before a change is merged to `PROD_BRANCH` ([QLT-01](04-quality.md)) |
| `parity`, `check-compose` | any | [ENV-02](#env-02-stage--prod-parity-m-if-there-are-stage-and-prod), [ENV-03](#env-03-compose-rule-check-m-if-there-is-stage-or-prod) |
| `stage`, `prod` | server | update to the branch, build its own images if this server lacks them, deploy ([ENV-09](#env-09-ship-deploy-and-roll-back-m-if-there-is-stage-or-prod)) |
| `images` | server | build the own images of the checked-out commit this server lacks and pull the other images, as `make stage` / `make prod` do, and start nothing (for example before a cut-over, so the switch itself builds nothing) |
| `restart` | server | apply a changed `.env` to the commit that runs now: no branch move, no migration; refuses when the checked-out commit is not the one deployed last; not recorded, so `rollback` ignores it ([ENV-09](#env-09-ship-deploy-and-roll-back-m-if-there-is-stage-or-prod)) |
| `rollback` | server | go back to the previous deployed commit |
| `tuning-check` | server | [OPS-02](03-operations.md) |
| `status` | any | show the environment, the checked-out and the last deployed commit, and the health of every service |
| `logs` | any | follow the logs of this clone's stack, for a person (`S=<service>`: one service; `TAIL=<n>`: print the last n lines and end, which is the form an agent uses) |
| `backup`, `backup-list`, `backup-drill` (`SET=`), `backup-status` | any | [OPS-01](03-operations.md) |
| `backup-copy-check` | server | [OPS-01](03-operations.md) |
| `backup-test` | dev | [OPS-01](03-operations.md) |
| `restore` | any (`FROM=copy`: server) | [OPS-01](03-operations.md); the one target that replaces data (`S=`, `SET=`, `FROM=`, `NO_SAFETY=1`); in a terminal you type the database name, without one only `CONFIRM=yes` on `make`'s command line |

`S=<service>` means one service in every target that takes it (`logs`, the backup targets),
`NAME=<n>` the name of a dev copy. `NAME`, `S`, `SET`, `FROM`, `NO_SAFETY`, `CONFIRM` and `RISK` count only
when typed on the `make` command line, never from the environment: a shell that exports
`CONFIRM=yes` would confirm every `make restore`. `CONFIRM=yes` confirms a restore without a
terminal; `RISK=yes` goes on past the warning of an estimate (free space, the backup before a
migration) where there is no terminal to ask.

No target runs `docker compose down -v`, `docker volume rm` or `docker volume prune`: they delete
the named volumes that hold the data.

### ENV-06. Folder layout (M)

- `docker/<service>/` — one container, one folder: its `Dockerfile` and configs;
- `docker/backup/data/` — local backup sets on stage and prod (the suggested `BACKUP_DIR`; the
  owner chooses the folder when the standard is applied, [OPS-01](03-operations.md)); never in git
  and never in an image;
- `.deploy/` (the server's deploy history and lock, and by default the log archive), `.cache/` and
  `build/` (the scan database and the files `make image-scan` saves) — generated, never in git and
  never in an image;
- `scripts/` — `project.sh` behind the `make` targets, and the gate and check scripts;
- `.githooks/` — the git hooks `make bootstrap` installs ([QLT-02](04-quality.md));
- `docs/` — Diátaxis + `adr/` + `reference/project-registry.md` ([DOC-01](06-docs.md));
- `.claude/` — the Claude Code settings, project skills and the `docker-lsp` plugin
  ([AI-07](05-agents.md));
- at the root: `README.md`, `AGENTS.md`, `CLAUDE.md`, `.env.example`, `Makefile`,
  `docker-compose.{dev,stage,prod}.yml` (+ `docker-compose.<role>.yml`).

The files a project receives from the standard, and the rule each one serves, are listed in
[`templates/`](../templates/README.md).

### ENV-07. `.dockerignore` (M)

An image contains only what the service needs to run. The file excludes from the build context
secrets (`.env*` except `.env.example`), caches (`.cache/`), build outputs (`build/`), `.git/`,
`.githooks/`, `.claude/`, `.deploy/`, `docs/`, the backlog folder if there is one,
`docker/backup/data/` and other data folders. A server builds its images from the committed files
of the deployed commit only, so nothing uncommitted, untracked or gitignored in its clone reaches
an image either ([ENV-09](#env-09-ship-deploy-and-roll-back-m-if-there-is-stage-or-prod)).

### ENV-08. Application Dockerfile stages (M)

One Dockerfile per own service, `docker/<service>/Dockerfile`, with three stages:
1. `base` — the OS or language image by version and digest ([ENV-03](#env-03-compose-rule-check-m-if-there-is-stage-or-prod)
   checks it, and checks the tool images of `dev` the same way) + libraries from the lock file
   without dev dependencies;
2. `runtime` — `base` + code, a non-root user, the start command; `make stage` / `make prod`
   build this stage on the server as `<repo>-<service>:<tree hash of the commit>`, which stage and
   prod run ([ENV-09](#env-09-ship-deploy-and-roll-back-m-if-there-is-stage-or-prod)). The image
   needs `/bin/sh`: the migration runs as `sh -c` in a one-off container of it, past the image's
   `ENTRYPOINT` ([D-0019](../decisions/0019-migrations-make-step.md)), so an image without a shell
   (distroless, `FROM scratch`) cannot run migrations, and a migration that needs the setup an
   `ENTRYPOINT` does must include it in the migration command;
3. `dev` — `base` + dev dependencies and tools: linters, type checker, tests, language servers. It
   never copies the code (a stage that only prepares tools for `dev` to copy is allowed).

One exception: the template's two service images, `backup` ([OPS-01](03-operations.md)) and
`status` ([OPS-04](03-operations.md)), are tools that run the scripts of their own image and
mount no application code, so their `dev` stage is their `runtime`, which copies only their own
scripts (`docker/backup/*.sh`, `docker/status/status.py`); a change to the application's code
does not rebuild them.

`docker-compose.dev.yml` builds `target: dev` and mounts the code from disk: in dev the code comes
only from the mount, and only `runtime` copies it. The stage and prod files reference the
`runtime` image by name and have no `build:`. Layers go from what changes rarely to what changes
often: libraries before code, so a code change does not reinstall the libraries of `base`; the
`dev` image holds no code, so a code change does not rebuild it, only a change of `base`, of its
tools or of the lock file does (`tests/stacks` proves it on the three samples). `make dev`,
`make gates` and the pre-push hook run `up --build`, and a `dev` built from `runtime` was rebuilt
on every code change; the measured times are in
[D-0004](../decisions/0004-dockerfile-stages.md). A new development tool is added only to the
`dev` stage.
Third-party services (Postgres, Redis and so on) use official pinned images; a custom Dockerfile
for them only when something must be added (for example, an extension), and then it is an own
image like the application's.

### ENV-09. Ship, deploy and roll back (M, if there is stage or prod)

One way for every project. The branches the servers follow are set once, when the standard is
applied, in the settings block of the `Makefile` (`STAGE_BRANCH`, default `main`; `PROD_BRANCH`,
default `prod`): the stage server deploys what is in `STAGE_BRANCH`, the prod server what is in
`PROD_BRANCH`. How code reaches each branch (a pull request, a merge, branch protection) is the
project's own choice. A project may run the same `make` targets from its CI; the standard does not
require one.

Every own image (each name in `IMAGES` in the `Makefile` settings) is built on the server that
runs it, by `make stage` / `make prod`; there is no image registry
([D-0025](../decisions/0025-images-built-on-the-server.md)). Third-party images (Postgres, Redis
and so on) are pulled from their public source. An own image is `<repo>-<name>:<tag>`, and the tag
is the git tree hash of the deployed commit (`git rev-parse <commit>^{tree}`): the hash of its
content, not of the commit. A re-deploy, a rollback, or a merge, squash or rebase that brings
`STAGE_BRANCH` into `PROD_BRANCH` and changes nothing else has the same content, so on a machine
that already built it nothing is built again (after a squash merge, `STAGE_BRANCH` has to be reset
to `PROD_BRANCH`, or the next squash merge conflicts).

Stage and prod build the same content, not the same bytes. Base images pinned by digest
([ENV-03](#env-03-compose-rule-check-m-if-there-is-stage-or-prod) refuses one that is not) and
dependencies installed from lock files keep the two builds equal in content. Operating-system
packages (`apt-get install`, `apk add`) are taken as they are on the day of the build and are not
pinned: stage and prod can get different versions of them when built on different days, so deploy
prod soon after stage. That is a known trade-off, decided by the owner and not measured
([D-0025](../decisions/0025-images-built-on-the-server.md)).

A build uses the server's CPU, memory and network while the old version keeps serving, and the
limits of `.env` do not hold it: on a small server keep a reserve of memory for it. A private
dependency needs build credentials on the server: a file outside git named in the `Makefile`
setting `BUILD_SECRETS`, which the build mounts as a BuildKit secret and never bakes into the image.

1. **Ship.** A finished task reaches `STAGE_BRANCH` the way the project does it; every `git push`
   from a dev machine first runs `make gates` through the pre-push hook
   ([QLT-02](04-quality.md), which also says what the local hook cannot guarantee).
2. **`make stage`** (stage server clone; `make prod` is the same on the prod clone). The order of
   its steps is the rule; the steps themselves, with their commands and messages, are in the
   project's `docs/how-to/operations.md` ("Update", [DOC-04](06-docs.md)). A step that fails stops
   the command, and what already runs keeps running:
   - **Refuse before any change.** What is certain stops the command: `PROJECT_ENV` in `.env` is not
     `stage`, a value in `.env` is still `change-me`, other users of the machine can read `.env`
     or a `BUILD_SECRETS` file, the settings the services need are wrong (for example the Docker
     socket group of the monitoring proxy, [OPS-04](03-operations.md)), this is not the only copy
     of stage on the machine ([ENV-04](#env-04-several-environments-and-copies-on-one-machine-m)),
     another deploy runs in this clone (the lock, below), or the clone has local changes.
   - **Warn and ask on an estimate.** A check that only estimates does not stop the command by
     itself. It says what it found (how much is needed, how much there is, or what was not
     written), what can go wrong if the command goes on, and asks: in a terminal a y/N question,
     where only `y` or `yes` goes on; without a terminal it refuses with the same explanation, and
     `RISK=yes` on `make`'s command line goes on. The estimates are the free space for a build
     (the free-space rule of
     [OPS-01](03-operations.md#ops-01-backups-m-if-the-project-has-data-worth-keeping);
     `make stage`, `make prod` and `make images` need twice the own images already on the machine
     plus `DISK_RESERVE` of `.env`, `make rollback` and `make restart` count only the own images of
     their commit that are missing and check nothing when none is,
     [D-0025](../decisions/0025-images-built-on-the-server.md)), the free space for the log
     archive, and the backup set before the migration (below).
   - **Update, then check.** It checks out `STAGE_BRANCH` and pulls it fast-forward only, continues
     in the updated `Makefile`, and runs `make bootstrap`, `parity` and `check-compose` before it
     builds anything.
   - **Build before replace.** Every own image this server lacks for that commit is built from the
     commit's committed files only (`git archive`, `.dockerignore` applied), so nothing
     uncommitted, untracked or ignored in the server clone reaches an image; a commit with git
     submodules is refused, and so is a missing `BUILD_SECRETS` file, before anything is built.
     The third-party images the server lacks are pulled. A build or a pull that fails stops the
     command with nothing replaced, and the old version keeps serving.
   - **Keep what Docker would lose.** The logs of the containers about to be replaced are saved,
     because Docker removes a container's logs with the container ([OPS-03](03-operations.md)).
   - **Migration step.** `MIGRATE` runs in a one-off container of the new `APP` image before the
     application is replaced, on every deploy, a re-deploy of the same commit included, so a
     migration must be idempotent (one already applied changes nothing) and compatible with the
     previous image ([D-0019](../decisions/0019-migrations-make-step.md)). A failed migration
     stops the command, and the old application keeps serving. When the project has the `backup`
     service and `MIGRATE` is set (not on a clone's first deploy), a normal backup set is made
     right before it. If that backup, or only its off-server copy, fails, the command says which
     part failed and that the migration would run without a fresh set off the server (or anywhere,
     when the local set failed), and asks (an estimate, as
     above); nothing is replaced before the answer.
   - **Replace only what changed.** `docker compose up -d --wait --remove-orphans` for every
     service except `backup`: Compose replaces only the containers whose image or configuration
     changed and leaves the rest (the database) running. `backup` is started without waiting for
     it, and an unhealthy backup is a warning while the deploy goes on
     ([OPS-01](03-operations.md)).
   - **Record before the tuning check.** The commit goes into `.deploy/history` (not in git), then
     the old images are pruned, then `make tuning-check` runs last ([OPS-02](03-operations.md)): a
     check that fails fails the command, but the history already names the commit that runs, so
     the fix is a value in `.env` and `make restart`, or a rollback.
   - **Prune rule.** The own images removed are those whose tag is a tree hash but not the tree of
     the commit running now or of one of the last `KEEP_IMAGES` (a `Makefile` setting, default 5)
     distinct commits in `.deploy/history`. Other images and tags stay, and an image a container
     uses is never forced out. Stage and prod on one machine share the image names, so the prune
     of one may remove images the other would roll back to; that rollback then builds them again.
     No target prunes the build cache (`docs/how-to/operations.md` says how).
3. **Prod.** Before a change is merged to `PROD_BRANCH`, `make image-scan` passes on it
   ([QLT-03](04-quality.md)). When stage is checked, the change reaches `PROD_BRANCH` the way the
   project does it (for example a pull request from `STAGE_BRANCH`), and **`make prod`** on the
   prod server deploys it as in step 2, building the images on that server. A hotfix goes the
   same way, through `STAGE_BRANCH`. If prod cannot wait, it is made on a branch from
   `PROD_BRANCH`, merged into `PROD_BRANCH` and deployed with `make prod` from its own content;
   then `PROD_BRANCH` is merged back into `STAGE_BRANCH`, so that the next change from stage
   neither undoes the fix nor conflicts with it.
4. **`make rollback`** (server clone). Deploys the commit that ran before the current one, from
   `.deploy/history`, the same way, without migrations. Its images are normally still on the
   server (the prune rule keeps them); if they were removed, it builds them again from that commit. A
   second rollback goes one further back. The next `make stage` / `make prod` returns to the
   branch, so the fix goes into the code first. A rollback that fails says where it left the clone
   (a detached `HEAD` at the commit it was going back to) and which command returns to the branch.

A changed value in a server's `.env` (a secret, a limit) is applied by **`make restart`** in that
server's clone. It keeps the commit that runs now, moves no branch and runs no migration; it
creates a missing external network named in `.env` as `make bootstrap` does and builds an image of
that commit only if one was removed by hand; the `up` of the deploy recreates only the containers
whose configuration changed (a plain `docker compose restart` would keep the old values); then
`make tuning-check`. It refuses when the checked-out commit is not the one deployed last: after a
`make stage` that stopped halfway, starting the checked-out commit would skip its migrations. It
writes nothing to `.deploy/history`, so `make rollback` ignores it. The rule: a changed `.env` →
`make restart`; a new version → `make stage` / `make prod`.

In one server clone, one `make stage` / `make prod`, `rollback`, `restart`, `images` or `restore`
runs at a time: each holds the lock `.deploy/lock` while it runs, and another one refuses before it
changes anything. The lock of one that no longer runs is taken over. A lock without its owner (a
`make` killed with SIGKILL, or a machine that stopped, right after it took the lock) is not: after
3 seconds the command refuses, and a person removes `.deploy/lock`.

Replacing a container stops the old one before the new one starts, so an update has a few seconds
of downtime. Deploys without downtime are not part of the standard yet: they need a front proxy
that switches traffic ([D-0021](../decisions/0021-ship-deploy-rollback.md)). If a new container
other than `backup` does not become healthy, the deploy fails and shows which one, with the last log
lines of every service that is not running or not healthy; the old container is already gone, so
the fix is `make rollback`. Every message, and what to do about it, is in the project's
`docs/how-to/operations.md` ([DOC-04](06-docs.md)).
