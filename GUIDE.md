# The standard on one page

> Version 1.0.0-draft · English · [Українська](GUIDE.uk.md)

A map: what a project looks like, what you do in each situation, which command does it and where
the details are. Every rule has an ID such as `ENV-09`; the rules are in
[`standard/`](standard/README.md), the reasons in [`decisions/`](decisions/), the exact steps and
messages in the project's own `docs/how-to/` (the files in [`templates/project`](templates/project/docs/how-to/operations.md)).
Levels: **M** the core or strongly advised, **R** advised, **O** offered
([how to read them](standard/README.md#how-to-read-it)).

## 1. The idea

- **Everything runs in Docker.** The host has only the tools [PRN-01](standard/01-principles.md)
  lists; every language tool runs in the project's dev container.
- **One way of working.** Every project, whatever the language, is set up, checked, shipped,
  deployed and rolled back with the same `make` commands (PRN-10, DOC-04).
- **One file per environment.** `docker-compose.dev.yml`, `.stage.yml`, `.prod.yml`; there is no
  default file, so a bare `docker compose up` starts nothing (PRN-02).
- **Stage and prod run the same content.** Each server builds its images itself from the deployed
  commit; stage and prod differ only in their `.env` (PRN-03).
- **Fail closed.** A secret without a value stops the start; a check that did not run is never
  green (PRN-04).
- **Done means tests, docs and registry** (the file `docs/reference/project-registry.md` in the project, DOC-03). Nothing is added "just in case" (PRN-05, PRN-06).
- **Self-contained, and exceptions written down.** A clone, Docker and `make bootstrap` are enough
  on any machine; every exception has a reason in the project registry (PRN-07, PRN-09).

## 2. The environments

| | dev | stage | prod |
|---|---|---|---|
| Where | your machine | the stage server | the prod server |
| Code | mounted from your folder; edits apply at once | baked into an image built on the server | the same |
| Started by | `make dev` | `make stage` | `make prod` |
| Follows | your branch | `STAGE_BRANCH` (`main`) | `PROD_BRANCH` (`prod`) |
| Tools | one `dev` container with every tool, plus the database and other services | none: only the product | the same |

Each environment is a clone of the repository with its own `.env`; its line `PROJECT_ENV` says
which environment it is, and a command of another environment refuses to run there (ENV-04).

- **Stage and prod: one copy of each per machine.** A second clone would take over the containers,
  volumes and data of the first, so it is refused, with no way round it.
- **Dev: several copies are fine.** A git worktree gets its own containers, database and ports by
  itself. Another clone of the project needs `make dev NAME=2` the first time; without it, it is
  refused while the first one's containers exist.

## 3. What you do, by situation

### What you are asked

`new`, `adopt` and setting the project up again ask about each choice of TYP-01, one question
at a time, in your language: what the part gives, an example, the risk without it and the agent's
advice. What the project's files already answer is not asked. Your answers go into registry
section 0, and a part you decline is not counted as a deviation. The core, the 24 choices and their
defaults: [TYP-01](standard/07-project-types.md#the-choices); the questions:
[`prompt/questions.md`](prompt/questions.md); why: [D-0028](decisions/0028-interactive-setup.md).

### A new project

Paste the prompt from the [README](README.md) into the agent in an empty folder
(mode `new`). It asks what only you can decide, creates the skeleton from
[`templates/`](templates/README.md), proves in a throwaway copy that it works, and commits after
your approval. Yours afterwards: the remote repository and the first push, the servers
([First server](#the-first-server)), and, if you chose them, the off-server backup copy, the monitor of its heartbeat and the monitor of the status service.

### An existing project

The same prompt in the project folder (mode `adopt`): an audit against
every rule, a report outside the repository, your decisions, a plan in the backlog, the changes
after approval. A project that already runs on a server also has a cut-over: the agent writes its
steps and measures how long the application is down, so you can plan the window; the old data is
removed only after you confirm.

### A newer release, or other choices

Mode `update`: only what changed between the releases, by the decisions
already in the registry; it asks the questions the release adds and offers to revisit your earlier
answers. To go through all your choices (switch stage off, add mutation testing), set
the project up again: the agent asks every question afresh and brings the project to the new
answers.

### The first time on a machine

`git clone … && cd … && make dev`. `make bootstrap` (which
`make dev` runs) creates `.env` from `.env.example` (an existing `.env` stays; it names what it
lacks), turns on the git hooks and creates the external networks. Nothing is installed on the host.

### Daily work

`make dev` starts the stack (database, tools); `make run` starts the application;
`make shell` opens a shell with every tool; `make logs` follows the logs (`S=db`: one service;
`TAIL=200`: the last lines, then it ends); `make seed` fills test data; `make migrate` applies new
migrations; `make down` stops for the day (the data stays). Code changes need no rebuild: the dev
image is rebuilt only when the tools or the lock files change (ENV-08). To start with an empty dev
database, run `docker compose -f docker-compose.dev.yml down -v` yourself and then `make dev` and
`make seed`; it deletes the dev data, so an agent does not run it without asking you.

### When an agent works

Two hooks help it (AI-05, AI-06): after every edit the file is checked in the
dev container and the agent fixes what is red; before every command that would run a language tool
on the host, the hook names the right `make` command. The rules for the agent are in the project's
`AGENTS.md`.

### Pushing a change

The path: work in a branch, `git push` (the gates run), `make verify`, merge
into `STAGE_BRANCH` the way the project does it, `make stage` on the stage server; nothing deploys
by itself. The git hook runs `make gates` on the working tree as it is. In a terminal it lists the
uncommitted files and asks `[y/N]`; without a terminal (an IDE, an agent) it prints a warning
and goes on, so an agent asks you first (the rule is in `AGENTS.md`). Red gates mean nothing is
pushed (QLT-02). The gates run on your machine, so `--no-verify`, a merge in a web interface, an
IDE without hooks or a clone without `make bootstrap` goes round them; whoever wants a guarantee
adds CI that calls the same `make` commands ([known limitations](standard/README.md#known-limits)).

### A task is finished

`make verify`, before the change is merged: all the checks (section 4).

### The first server

Read access to the repository, a clone, `.env` from `.env.example` (`chmod 600`, `PROJECT_ENV`,
every `change-me` replaced, `DOCKER_GID`), the front proxy (your own TLS reverse proxy; the project does
not contain it), the first `make stage` / `make prod` (it builds the
images on the server); then, for what you chose, the off-server backup copy and the heartbeat
(`make restart` and `make backup-copy-check`) and the monitor of the status service. Step by step:
[operations](templates/project/docs/how-to/operations.md), [backups](templates/project/docs/how-to/backups.md).

### Shipping to stage and prod

- **Stage:** `make stage` on the stage server. It refuses on a wrong clone, a second copy, local
  changes or a `change-me` left; with too little disk it warns and asks (without a terminal
  `RISK=yes`); it builds what the server lacks, migrates,
  replaces only what changed, records the commit in `.deploy/history`, checks the tuning
  (OPS-02). Every step stops everything on failure (an estimate asks), and what runs keeps running (ENV-09).
- **Prod:** `make image-scan` on your machine first (known vulnerabilities in the images), then get
  the change into `PROD_BRANCH` the way the project does it, then `make prod` on the prod server.
- **A hotfix:** make it as a normal change on `STAGE_BRANCH` and ship it through stage; when prod
  cannot wait for the rest of stage, branch from `PROD_BRANCH`, `make image-scan`, merge it into
  `PROD_BRANCH`, `make prod`, then merge `PROD_BRANCH` back into `STAGE_BRANCH`.
- **Migrations** must work with the previous release and be safe to repeat; delete or rename
  something only in the release after the one that stops using it, or `make rollback` breaks.
- **A setting or a secret changed:** edit the server's `.env`, then `make restart`. A changed
  container limit and its derived numbers go together, as `docs/how-to/tuning.md` explains.

### Something broke after a deploy: `make rollback`

On the server: returns to the commit deployed before the current one, without migrations. The
branch still holds the broken commit, so the next `make stage` / `make prod` deploys it again: fix
it or `git revert` it first. Details: [operations](templates/project/docs/how-to/operations.md).

### What runs now

`make status`: the environment, the checked-out and the last deployed commit, the health of every
service. `make logs` follows the logs. Monitoring from outside, if you chose it: OPS-04.

### Backups

On stage and prod the `backup` service runs by itself (OPS-01): daily a checked set of every
database, an encrypted copy off the server, rotation; weekly a restore drill; a ping to an outside
monitor after each good day, so a dead server is noticed too. In dev nothing runs by itself.

| You want to | Command |
|---|---|
| back up now | `make backup` (`S=db`: one store) |
| see the sets, and the state of the service | `make backup-list`, `make backup-status` |
| prove a restore works | `make backup-drill` (`SET=<set>`: that set) |
| check the off-server copy | `make backup-copy-check` |
| restore data | `make restore`: checks the set, shows what it replaces, asks for the database name; first makes a safety set (`SET=before-restore` returns to it); on a server it stops the application, and `make restart` starts it again |
| a new server from the copy | the same passwords and `PROJECT_ENV`, then `make restore FROM=copy SET=<set> NO_SAFETY=1`, the set from `make backup-list FROM=copy`: [backups](templates/project/docs/how-to/backups.md#a-new-server-from-the-off-server-copy) |

## 4. The checks

Two floors. The **base commands** are the only places a check lives; each runs alone. The **group
commands** add no check; they run base commands and end with a summary line per base command
(`ok`, `FAIL`, `off` or `skip`, and the last line of its output).

| Base command | What runs | Protects against | In |
|---|---|---|---|
| `lint` | the code does not run: Dockerfile check, format, lint, types, shellcheck, links in the docs (offline), architecture contracts (R) | messy code, type errors, dead links | gates, verify |
| `test` | the code runs, fast and offline: unit tests, tests against a real database | broken logic | gates, verify |
| `e2e` | the whole application runs, slowly: API contract, browser | what only slow tests show | verify |
| `security` | secrets (gitleaks, offline), SAST, dependency audit (needs the network) | keys in git, unsafe code, known holes in libraries | gates (the secret scan only), verify |
| `infra` | `check-compose`, `parity`, `backup-test` | an unsafe or drifting stage or prod setup | verify; `parity` and `check-compose` in every deploy |

- `make gates` = `lint` + `test` + the secret scan. Fast, offline; the pre-push hook runs it.
- `make verify` = `lint` + `test` + `e2e` + `security` + `infra`.
- Only by hand: `make fix` (the safe automatic fixers, before `make gates`), `make mutation-diff`
  and `make mutation` (tests that catch nothing; R, your choice at setup), `make image-scan`
  (known vulnerabilities in the images; the images stay on your machine).
- Every deploy also runs `tuning-check`: each service is set up for its limits (OPS-02).
- `LINT`, `TEST` and `SECRETS` are mandatory: empty refuses and fails the groups; `off` records that
  the project does not want that check. Gate rules: QLT-02. When each check runs: QLT-03.

## 5. Every `make` command

`make help` lists them in these groups. Where: **dev** your machine, **server** that server's clone,
**any** every clone.

| Group | Command | Where | What it does |
|---|---|---|---|
| Dev | `dev` | dev | builds what changed, starts the stack, migrates (`NAME=<n>`: a copy of its own) |
| | `run`, `shell`, `seed`, `down` | dev | daily work, above |
| | `migrate` | dev | the migrations (on a server, `make stage` / `make prod` runs them) |
| Checks | `lint`, `test`, `e2e`, `security`, `infra` | dev | base commands, section 4 |
| | `gates`, `verify` | dev | group commands, section 4 |
| | `fix`, `mutation`, `mutation-diff`, `image-scan` | dev | by hand only |
| Servers | `stage`, `prod` | that server | update to the branch, build, migrate, deploy |
| | `rollback`, `restart` | server | the previous deployed commit; apply a changed `.env` |
| | `images` | server | build and pull the images, start nothing (moving a running project onto the standard) |
| | `tuning-check` | server | the running settings against the expected ones |
| Any clone | `status`, `logs` | any | what runs and how healthy it is; the logs |
| Backups | `backup`, `backup-list`, `backup-drill`, `backup-status`, `restore` | any | section 3 |
| | `backup-copy-check` | server | prove the off-server copy |
| | `backup-test` | dev | a test backup and drill of the dev database |
| Service | `help`, `bootstrap`, `parity`, `check-compose` | any | the list; prepare the clone; the stage and prod files, equal and by the rules |

The project's commands (`MIGRATE`, `LINT`, `TEST`, `RUN` and so on) are settings at the top of the
`Makefile`. A project adds its own targets only in the block "Project targets" (ENV-05); `make help`
lists them under "This project".

## 6. Where the rules are

| Section | Rules | About |
|---|---|---|
| [01 Principles](standard/01-principles.md) | PRN-01 – PRN-10 | Docker, one file per environment, same content, fail closed, one way of working |
| [02 Environments](standard/02-environments.md) | ENV-01 – ENV-09 | the three environments, parity, compose rules, `make` targets, Dockerfile stages, deploy and rollback |
| [03 Operations](standard/03-operations.md) | OPS-01 – OPS-04 | backups, tuning, logs, health monitoring |
| [04 Quality](standard/04-quality.md) | QLT-01 – QLT-03 | tool categories, gate rules, when each check runs |
| [05 Agents](standard/05-agents.md) | AI-01 – AI-09 | `AGENTS.md`, hooks, language servers; the Claude Code adapter |
| [06 Documentation](standard/06-docs.md) | DOC-01 – DOC-04 | the documentation set, backlog, registry, the README section |
| [07 Project types](standard/07-project-types.md) | TYP-01 | what a service, frontend, pipeline, library or ML project adds or drops |

## 7. Where to read more

| You want | Read |
|---|---|
| a rule in full | [`standard/`](standard/README.md) |
| what the standard does not solve yet, and what you can do | [known limitations](standard/README.md#known-limits) |
| why a rule is as it is, with sources and tests | [`decisions/`](decisions/) |
| the files a project receives | [`templates/`](templates/README.md) |
| tuning, backup and healthcheck notes per technology | [`catalog/`](catalog/README.md) |
| what the agent does | [`prompt/start.md`](prompt/start.md) |
| what changed between releases | [`CHANGELOG.md`](CHANGELOG.md) |
