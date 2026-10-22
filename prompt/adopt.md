# Adopt: audit, plan, then execute step by step

You bring an existing project in line with the standard in `$STANDARD` (see [`start.md`](start.md)).
The work has two parts with a hard line between them:

- **Audit and plan (phases 0–5).** You read, measure, research, ask and write one report. You change
  nothing in the project: no code, no config, no deletions, no git commands that write (commit,
  checkout, stash, reset, clean and the like). Building and running the dev stack is allowed
  ([`start.md`](start.md), section 3); in a project that already has the template's `Makefile`,
  its `make bootstrap` (which every `make dev` runs) may write a missing `.env`, set
  `core.hooksPath` and create the external networks.
- **Execute (phase 6).** Only after the owner has approved the plan, task by task, each task proven
  by its own check and committed on its own.

The standard outranks your taste, and the owner's word outranks the standard. Where the project's
own `AGENTS.md` / `CLAUDE.md` conflicts with the standard, do not resolve it yourself: Claude Code's
documentation warns that "if two instructions contradict each other, Claude may pick one
arbitrarily" (<https://code.claude.com/docs/en/memory>). Record it as a deviation with the action
`owner decision` and ask the owner in phase 4; the plan does not touch it until the owner decides.
Sometimes the project is right, and then it is a proposal for the standard (`proposals.md`).

## Phase 0 — orient

1. Read `AGENTS.md`, `CLAUDE.md`, `~/.claude/CLAUDE.md`, `README.md`, the project's backlog (a
   file in the repository or an issue tracker, [DOC-02](../standard/06-docs.md)), `docs/`, and a
   workflow plugin's config if there is one. Determine the project type
   ([TYP-01](../standard/07-project-types.md)), its languages, and whether a registry exists.
2. If a previous report of this project exists (`~/audits/<repo>/`, a registry, an ADR about
   environments), read it: you update it rather than start over.
3. Ask the owner, in one message: the project type and the environments you propose from TYP-01
   (unless the registry profile already records them; when the project is set up again, show
   what it records and ask anyway, as [`start.md`](start.md) section 2 says); the three or four
   biggest deviations you expect; whether anything is out of scope; and whether you should compare
   it with any other of their projects (if yes, which folders; "none" is a normal answer). Keep
   the answers for the report and the registry of phase 5.3: phase 4 does not ask them again.

## Phase 1 — collect facts (measure, never assume)

Run language tools in the project's dev container; build its image if needed (a project without
`docker-compose.dev.yml`: as [`start.md`](start.md) section 3 says). On the host run only the tools
of [PRN-01](../standard/01-principles.md). Save the outputs you rely on to
`~/audits/<repo>/<YYYY-MM-DD>/evidence/`, outside the repository. Never save a rendered config
with secret values: use `config --no-interpolate`, and record variable names, never their values.

**Infrastructure**
- List every `compose*.y*ml` / `docker-compose*.y*ml`, every `Dockerfile*`, `.dockerignore`,
  `.gitattributes`, `Makefile`, `scripts/*.sh`, `.githooks/*`, `trivy.yaml`. For every compose file:
  `docker compose -f <file> config --services` and `config --profiles`. Record which file a bare
  `docker compose up` would pick up (Compose loads `compose.yaml`, `compose.yml`,
  `docker-compose.yaml`, `docker-compose.yml`, their `*.override.*` twin, and whatever
  `COMPOSE_FILE` names in `.env` or the shell (record any `COMPOSE_PROJECT_NAME` or
  `COMPOSE_PROFILES` there as well); it also searches parent folders — check them too). Under
  [PRN-02](../standard/01-principles.md) a bare `up` must fail.
- The `Makefile` against [`$STANDARD/templates/project/Makefile`](../templates/project/Makefile):
  which targets of [ENV-05](../standard/02-environments.md) exist, which behave differently, which
  project commands are not behind a target, and how the project is shipped and deployed today
  (who builds the image, where, how a server gets it, how it rolls back).
- `.dockerignore`: does it exclude everything [ENV-07](../standard/02-environments.md) lists? Each
  gap is a finding.
- `.gitattributes`: without `* text=auto eol=lf`, a clone on a machine with `core.autocrlf=true`
  gets the scripts and the hook with CRLF line endings, and they fail in `sh`. That is a finding.
- Every own `Dockerfile` against [ENV-08](../standard/02-environments.md): the stages `base`,
  `runtime` (`base` + the code, a non-root user) and `dev` (`base` + the dev tools, never the
  code, which comes only from the dev mount; the one exception is the template's `backup` and `status`
  services, whose `dev` stage is their `runtime`, ENV-08). A `dev` stage built `FROM runtime` or with a `COPY`
  of the code is rebuilt after every code change by `make gates` and the `pre-push` hook, which
  build the dev stack first. Each gap is a finding.
- For every service: image or build target, what is installed in it (read the Dockerfile stage),
  user, `restart`, `healthcheck`, `depends_on`, published ports, networks, volumes, `read_only`,
  `security_opt`, `cap_*`, resource limits, log cap.
- Compose rule check ([ENV-03](../standard/02-environments.md)): do `scripts/check-compose.sh` and
  `scripts/check-compose.py` exist, do they match `$STANDARD/templates/check-compose/scripts/`, and
  do `make infra`, `make stage` and `make prod` call `check-compose`? If there is a stage or prod
  file, run the template's check on a clone of the committed state, so the repository does not
  change:
  `t=$(mktemp -d) && git clone --quiet "$(git rev-parse --show-toplevel)" "$t/p" && mkdir -p "$t/p/scripts" && cp "$STANDARD"/templates/check-compose/scripts/check-compose.* "$t/p/scripts/" && sh "$t/p/scripts/check-compose.sh"; echo "exit $?"; rm -rf "$t"`.
  A stage or prod file under another name (for example a production `docker-compose.yml`) is
  checked too: in that command, add `&& cp "$t/p/<its name>" "$t/p/docker-compose.prod.yml"` (or
  `.stage.yml`) before `&& sh`. It checks the last commit: note uncommitted changes to the compose
  files, `.env.example` and `docker/` (`git status --porcelain`) next to the result. Every
  `check-compose:` violation line is a finding: `ports`, `docker-sock`, `privileged` and a secret
  with a default value are `blocker`, the rest `major` (an image without a version and digest
  among them). A file that does not render from `.env.example` is `major` (the example lacks a
  variable). A clone without `.env.example` (a committed `.env`, an `.env.dist`) prints
  `not checked: there is no .env.example to render it from` and checks no rule: record that as
  its own `major` finding, then, in the same `$t/p` before `rm -rf "$t"`, write a temporary
  `.env.example` with every name that `docker compose -f <file> config --variables` lists and a
  test value that fits where it is used (its default, a port number for a port, `change-me` for a
  secret), and run the check again, so the real violations are found too.
- Networks and volumes: which are compose-managed, which external (need a manual
  `docker network create`), which volume or folder holds data worth keeping, and where each
  database keeps its data (a named volume, a bind mount, a folder in the repository).
- Backups ([OPS-01](../standard/03-operations.md)): for every data store — is there a module in the
  `backup` service, which tool and which user take it, which folder or volume holds the sets and on
  which disk, is there a manifest, when did a drill last pass (from logs), is there an off-server
  copy, with which tool, is it encrypted, and can the server delete it (it must only be able to
  write, OPS-01), the healthcheck, the notifications (`BACKUP_NOTIFY_URL`), the heartbeat (`BACKUP_HEARTBEAT_URL`: a
  GET after each good daily run to a monitor on another machine that alerts when it is missing;
  recommended for prod), the variables in `.env.example`. A data store without a backup is
  `blocker`; a backup without a drill is `major`; prod without a heartbeat monitor is a finding
  unless the registry records why it has none.
- Tuning ([OPS-02](../standard/03-operations.md)): for every component, the container limit and the
  actual values of the parameters listed in `$STANDARD/catalog/README.md`. Take them from the
  running dev stack (`SHOW shared_buffers` and so on), otherwise from config files. Check whether
  they are explained in `.env.example` and `docs/how-to/tuning.md`. A factory value that does not
  fit the limit is `major`.
- Logs ([OPS-03](../standard/03-operations.md)): where each service writes, the format, how the
  level is set, the size cap, and whether the logs of a replaced container are kept anywhere.
- Where data, config, logs and secrets live: `.env*`, state folders, bind mounts, log files, named
  volumes. Which secrets reach which containers, and whether any has a default value. The names in
  the owner's local `.env` (never the values) that the template's `.env.example` also uses with
  another meaning (a framework's `DB_PASSWORD`, for example, which is the application's password
  where the template's is the superuser's).
- Which environments exist (dev / stage / prod / test / agents) and how each starts. Does prod bake
  the code into the image or mount it?
- Self-containment ([PRN-07](../standard/01-principles.md)):
  `git grep -nE '\.\./[A-Za-z0-9_-]+/|/home/|/mnt/[a-z]/|[A-Z]:\\'` over scripts, hooks, compose
  files, the Makefile and `.claude/settings.json`. Every path into a neighbouring repository or
  absolute machine path is a `major` finding, together with what is taken through it.
- Host leftovers: `.venv`, `node_modules` outside a container mount, `__pycache__`, tool caches
  outside `.gitignore`; `docker ps -a` and `docker images` entries of this project that nothing
  uses; orphan volumes in `docker volume ls`, each with its size (`docker system df -v`) and the
  Compose project that made it (the `com.docker.compose.project` label in `docker volume inspect`);
  a volume with data is never just a leftover.
- Host tools the project really calls: grep hooks, the Makefile and scripts for host `uv`, `pip`,
  `python`, `node`, `npm`, `npx`, `composer`, `php`, `ruff`, `eslint`. Each hit is a host exception
  that is either in registry section E or is a finding.

**Docs** ([DOC-01](../standard/06-docs.md) to [DOC-04](../standard/06-docs.md)): does the README
start with the section of DOC-04, which required pages exist, where the backlog lives, and what
duplicates what between `README.md`, `docs/`, `AGENTS.md`, the backlog and a workflow plugin's
state.

**Tools** (for each: what it does, where it runs, how its version is pinned, which gate runs it,
whether it is needed)
- Linters and formatters, type checkers, architecture contracts, test runners, tests against a real
  database, property-based tests, coverage, mutation testing, secret scanners, dependency auditors,
  image scanners (and their settings, such as `trivy.yaml` and `.trivyignore`), SAST, link checks, browser end-to-end tests, API contract tests
  ([QLT-01](../standard/04-quality.md)).
- The gate command (`make gates` or its equivalent): list every step it runs and time one full run,
  and which of the mandatory checks of QLT-01 (lint, tests, the secret scan) it lacks.
  Over five minutes is a `major` finding ([QLT-02](../standard/04-quality.md)); name the slow steps.
- Is there a `pre-push` hook, and is it installed in this clone (`git config core.hooksPath`)?
- Security scanners declared by a workflow plugin's config or CI, against what the Makefile exposes.
  A plugin or CI that runs its own check commands instead of the `make` targets is a finding
  ([AI-03](../standard/05-agents.md)).

**Claude Code layer**
- Project skills `.claude/skills/*`, commands `.claude/commands/*`, hooks in `.claude/settings.json`
  and `.claude/hooks/*`, `enabledPlugins` and `extraKnownMarketplaces` in project settings,
  `.mcp.json`, `.claude/rules/*.md`.
- Global: `~/.claude/settings.json` (`enabledPlugins`, `extraKnownMarketplaces`, hooks, permission
  mode), `~/.claude/plugins/installed_plugins.json` (scope and version per project),
  `~/.claude/skills/`, `~/.claude/CLAUDE.md`. Compare plugin pins only with the other projects the
  owner named in phase 0.
- For every skill and plugin: which problem it solves, whether this project uses it (grep for what
  it is about), whether another layer already covers it (a global plugin, a built-in skill,
  `AGENTS.md`), and whether it works (an MCP server that needs authorisation and lacks it is
  "installed, not working").
- Language servers ([AI-07](../standard/05-agents.md)): for every language of the project, is
  its server in the dev image
  (`docker compose -f docker-compose.dev.yml exec -T dev sh -c 'command -v pyright-langserver'`
  and so on) and does its version match the gate pin; does `.claude/plugins/` contain the files of
  `$STANDARD/templates/docker-lsp/` (identical except the placeholders `<repo>`, `<owner>` and the
  language list), and is the plugin enabled in `.claude/settings.json`. Official `*-lsp` plugins or
  another plugin with `lspServers` are a `drop` finding.
- Hooks ([AI-05](../standard/05-agents.md), [AI-06](../standard/05-agents.md)): do
  `.claude/hooks/post-edit.sh`, `pre-bash.sh`, `check-file.sh`, `check-command.sh` and
  `json-get.awk` exist and match `$STANDARD/templates/agent-hooks/.claude/hooks/` (`diff`), does
  `.claude/hooks/checks.conf` name the same formatter, linter and type checker as the lint step of
  the gates for each language, and are both hooks in `.claude/settings.json` as the template's `settings.fragment.json` has them? For a hook of the
  project's own: does it check the changed file in the dev container, and what does it do when the
  tool is missing or the container is stopped (read the script)? A silent skip is `major`. Does a
  PreToolUse hook block host language tools?
- The size in lines of the instruction files a session loads (`CLAUDE.md`, `AGENTS.md`, rules of
  global plugins); the official recommendation is under ~200 lines per `CLAUDE.md`.

## Phase 2 — research only what the standard leaves open

The standard already settles the usual questions; do not research them again. Research only: (a) a
tool or practice of this project that the standard does not mention; (b) a technology of this
project that the standard has no entry for: a language missing from QLT-01 or AI-07 (research one
tool per QLT-01 category), or a component missing from `$STANDARD/catalog/README.md`; (c) a
statement of the standard that this project's facts seem to contradict; (d) the tuning and backup
method of every component (database, cache, web server, language runtime): fully for a component
missing from the catalog, and for a listed one, whether its rows hold for this project's version.
For each: 1–3 sources, official documentation first, quoted ([`start.md`](start.md), section 3).
Record them in the report's sources file with what each one confirms.

## Phase 3 — compare with the standard

Build the deviation table: rule ID → what the project does → evidence → severity (`blocker` breaks
the Docker axiom or threatens data, `major` is a wrong environment shape or a missing mandatory
item, `minor` is duplication, drift, leftovers) → proposed action (`keep`, `fix`, `move`, `merge`,
`drop`, `add`, `owner decision`) → effort (S/M/L) → depends on.

Then four lists: superfluous, duplicated, outdated, badly organised. Every item names its evidence.
Also list what the project does BETTER than the standard: a candidate for changing the standard, not
a deviation to fix.

## Phase 4 — ask before deciding

Collect the decisions only the owner can make, written as [`start.md`](start.md) section 3 says.
Always ask, unless the registry or the owner's answer in phase 0 already settles them (when the
project is set up again, ask each, with the registry's answer shown as a reference): the
environments (registry profile); the branches stage and prod follow (`Makefile` settings; default
`main` and `prod`); with stage or prod, whether the build needs a private dependency (each server
builds its own images, so it then needs read credentials for it there: a file outside git named in
the `Makefile` setting `BUILD_SECRETS`, which the build mounts as a BuildKit secret, never baked
into the image); and the questions of [`new.md`](new.md) step 1 that phase 1 did not answer by
measuring (a server that runs gives its size, for example):
- for a project with data on stage or prod, the folder of the backup sets on each server
  (`BACKUP_DIR`): (a) the template's `./docker/backup/data` in the clone, (b) your advice after
  phase 1 with its reason (where the project keeps its data today, a disk with more room), or
  (c) a path of the owner's; where the off-server backup copy goes (`BACKUP_COPY_TO`; the
  template's example is a rest-server the server can only write to,
  `rest:https://<host>:<port>/<login>/`) and, with prod, which monitor on another machine receives the backup heartbeat
  (`BACKUP_HEARTBEAT_URL`; recommended); until a server exists, the copy and the heartbeat wait in
  registry section E as [TYP-01](../standard/07-project-types.md) says;
- with stage or prod, health monitoring ([OPS-04](../standard/03-operations.md)) and the folder of
  the log archive (`LOG_ARCHIVE_DIR`, [OPS-03](../standard/03-operations.md)), each with the
  options of new.md step 1;
- `LINT`, `TEST` and `SECRETS`: the command you propose for each from phase 1 and 2, or `off`;
  mutation testing, yes or no; with a UI, a browser for the agent.

Every answer goes into section 0 of the registry of phase 5.3. Then every `owner decision` from
phase 3 and every choice the standard leaves to the project.

## Phase 5 — target state and plan

1. **Target architecture**: compose files and what each starts, the dev box contents, the stage and
   prod shape (for an environment without a server yet: complete files proven in a proof copy,
   [`start.md`](start.md) section 3, [TYP-01](../standard/07-project-types.md)), data storage and
   backups, tuning, health monitoring, the log archive, the secret
   path, healthchecks, restart, and how the project is shipped, deployed and rolled back
   ([ENV-09](../standard/02-environments.md)). Explain every significant choice in one or two
   sentences. Present backups and tuning as a table that reads without the standard: component →
   parameter or variable → value and how it is derived from the limit → why, in plain words → how
   to change it → how to check it → source (URL). Follow the method of
   [OPS-02](../standard/03-operations.md): the limits and the derived numbers in `.env`, a number of
   processes from the measured memory of one process, the default where sources disagree. This
   table becomes the rows of the project's `docs/how-to/tuning.md` (and `backups.md`), from their
   starting points in `$STANDARD/templates/project/docs/how-to/`, and the comments on the
   variables in `.env.example`.
2. **Target Claude Code layer**: which skills and plugins stay in the project, which move to global,
   which go, with a reason for each.
3. **Registry**: a filled `docs/reference/project-registry.md` for the target state in the format of
   [DOC-03](../standard/06-docs.md), with changing rows marked `→`, and every answer of phases 0
   and 4 in its section 0, each with its reason (a check turned `off` and a part the owner left
   out included).
4. **Plan**: ordered tasks, each with a name, a one-sentence goal, the files it touches, "done when"
   criteria that a command can check, the tests and docs it owes, dependencies, effort and the ADR
   it needs (if it changes an architectural decision). Group them into sessions of at most one `L`
   or three `S`/`M` tasks. Write the first task so it can start without further questions. If the
   project has an issue tracker, give the plan in its format. Standard tasks and their "done when":
   - **Environments and compose files** (before **Makefile and README**, whose `make bootstrap`
     refuses a default-named file): `docker-compose.dev.yml`, `.stage.yml` and `.prod.yml` for the
     environments the project has, from the template files; a default-named file (`compose.yaml`,
     `docker-compose.yml` and their twins) taken apart into them and removed, its data kept as
     **Data carry-over** decides; `.env.example`, `.gitignore` and `.dockerignore` brought to the
     template, with the project's own entries kept. The template's `DB_PASSWORD` is the database
     superuser's, and the application logs in with its own role, `APP_DB_USER` and
     `APP_DB_PASSWORD`, never as the superuser. A framework that reads names of its own (Laravel:
     `DB_USERNAME`, `DB_PASSWORD`) gets them in the application's `environment:` from
     `APP_DB_USER` and `APP_DB_PASSWORD`. In each `.env` the old application login becomes
     `APP_DB_USER` and `APP_DB_PASSWORD`, and `DB_PASSWORD` the superuser's; when the old
     application logged in as the superuser, that password stays `DB_PASSWORD`, the application
     gets a new role, and its tables move to that role once (the command in
     `docs/how-to/operations.md`, "Update"). Done when a bare `docker compose up` fails with
     `no configuration file provided`, and every new stage and prod file renders with the example
     (the dev file waits for `make bootstrap` of the next task):
     `docker compose --env-file .env.example -f <file> config -q`.
   - **Makefile and README**: the `Makefile` and `scripts/project.sh` from
     `$STANDARD/templates/project/`, the `Makefile` with the
     project's settings block filled as [`new.md`](new.md) step 3, item 1, says (`LINT`, `TEST` and
     `SECRETS` as the owner answered in phase 4, a command or `off`; with `SECRETS` as
     `gitleaks dir`, a `.gitleaks.toml` as [`new.md`](new.md) step 3, item 1, says), the project's own
     commands moved behind targets in its block
     "Project targets" (each with a `## ` help text and a README row, under a name no standard
     target has, [ENV-05](../standard/02-environments.md)), and the README section of
     [DOC-04](../standard/06-docs.md) from `$STANDARD/templates/project/README.md`, and
     `.gitattributes` from the template (with `git add --renormalize .` in the same commit if a
     committed file has CRLF line endings). Done when `make bootstrap` passes in the owner's
     working copy, `make help` lists the targets, every command in the README section exists in the
     `Makefile`, and `git ls-files --eol` shows no `i/crlf`. With a `.env` there already,
     `make bootstrap` keeps it and names what it lacks
     (`WARNING: .env lacks variables of .env.example: <names>`); show the owner the list, and the
     owner adds them or lets you add them. Never delete that `.env`: it holds the project's local
     secrets, such as Laravel's `APP_KEY`. Depends on **Environments and compose files**.
   - **AGENTS.md and CLAUDE.md** ([AI-01](../standard/05-agents.md)): `AGENTS.md` from
     `$STANDARD/templates/project/AGENTS.md` with the project's names, and the project's own rules
     under its "Project rules"; `CLAUDE.md` is the template's one line `@AGENTS.md`. A rule of the
     project's that conflicts with the template is an `owner decision` of phase 4, never settled by
     you. Done when `diff` of each with its template shows only the filled placeholders and the
     "Project rules" section.
   - **Dockerfiles**: `docker/<service>/Dockerfile` of every own service with the stages of
     [ENV-08](../standard/02-environments.md): `base` (its image pinned by version and digest),
     `runtime` (`base` + the code, a non-root user, `/bin/sh`) and `dev` (`base` + the pinned dev
     tools and language servers, never the code), and the
     dev compose file building `target: dev` with the code mounted (the template's `backup` and `status`
     services keep their `dev` stage = `runtime`, ENV-08). Done when `make gates` is green in under five
     minutes (its `lint` checks every Dockerfile with `docker build --check`) and, in a proof copy
     ([`start.md`](start.md) section 3), after a one-line change to a
     code file `docker compose -f docker-compose.dev.yml build dev` rebuilds no layer of the dev
     image: `docker image inspect -f '{{.Created}}' <repo>-dev-proof-dev` stays the same. Depends
     on **Makefile and README**; from this task on every task also runs `make gates`.
   - **Compose rule check**: if there is stage or prod and `scripts/check-compose.*` is missing or
     differs from the template, copy both files verbatim (the project's own formatter and type
     checker skip them, as [`templates/README.md`](../templates/README.md) shows), fix
     every violation, and record each
     deliberate exception of the project's own in `x-check-compose-allow` with a reason and a row
     in registry section E (the `backup` and `status` templates' own exceptions need no row,
     [ENV-03](../standard/02-environments.md)).
     Done when `make check-compose` is green and a temporary `"5432:5432"` port in the prod file
     turns it red. Depends on **Dockerfiles** (it checks the digest of every `FROM`).
   - **Git hook**: `.githooks/pre-push` from the template and `make bootstrap` installs it. Done
     when the pre-push checks of [`new.md`](new.md) step 4 pass in a proof copy
     ([`start.md`](start.md) section 3). Depends on **Dockerfiles** (the hook runs the gates in the
     dev stack).
   - **Tuning** ([OPS-02](../standard/03-operations.md)): `docs/how-to/tuning.md` and
     `scripts/tuning-check.sh` from their starting points in `$STANDARD/templates/project/`, with
     a row and a check line for every parameter of the phase 5.1 table; the limits and the derived
     numbers in `.env.example`, each number passed by its component's own route (PostgreSQL: `-c`
     flags in the `command:` of its service); `memswap_limit` next to every memory limit. Done
     when `make tuning-check` is green in the stage clone of a proof copy (without stage, its prod
     clone; [`start.md`](start.md) section 3), a value changed in that clone's `.env` turns it red
     until `make restart`, and a commit that returns one parameter to its factory value (its `-c`
     flag removed, for example) makes `make stage` end with `tuning-check: FAIL` for it. Depends
     on **Dockerfiles** and **Compose rule check** (every `make stage` runs it).
   - **Ship and deploy**: `make stage` / `make prod`, `make restart`, `make rollback`,
     `make status` from the template; the stage and prod files reference
     `<repo>-<image>:${IMAGE_TAG:?}` for every own image in the `Makefile`'s `IMAGES` and have no
     `build:`; `LOG_ARCHIVE_DIR` as the owner chose; with prod, `make image-scan` with `trivy.yaml`
     from its starting point and a pinned trivy in the `dev` stage
     ([QLT-01](../standard/04-quality.md)). Done when every check of the stage-or-prod item of
     [`new.md`](new.md) step 4 passes in a proof copy, and `make stage` in `$t/p` refuses. Depends
     on **Dockerfiles**, **Compose rule check** (every deploy runs it) and **Tuning** (`make stage`
     ends with `make tuning-check`).
   - **Backups**: the `backup` service of [OPS-01](../standard/03-operations.md) from
     `$STANDARD/templates/project/docker/backup/`, with its compose blocks and `.env.example`
     variables from the template files (`BACKUP_DIR` as the owner chose), a module for every
     store (the template's `postgres` module is the pattern for others and needs PostgreSQL 15 or
     later; a store of another kind gets a module of its own, written to the interface in
     `docs/how-to/backups.md`, "Writing a module for another store"), `backup` in the Makefile's
     `IMAGES` (with stage or prod) and `docs/how-to/backups.md` from its starting point. Done when
     every check of the data-store item of [`new.md`](new.md) step 4 passes in a proof copy, for
     every store and with that store's own tool, each where that item says.
   - **Health monitoring** (with stage or prod, when the owner wants it,
     [OPS-04](../standard/03-operations.md)): the `status` service from
     `$STANDARD/templates/project/docker/status/`, with its compose blocks (`status` and
     `status-proxy`) and `.env.example` variables, `status` in the Makefile's `IMAGES`, and the
     section "Monitoring" of `docs/how-to/operations.md`. Done when the monitoring check of
     [`new.md`](new.md) step 4 passes in a proof copy.
   - **Data carry-over**: if the target state changes a compose project name, a volume name or a
     data path that holds data, the plan either attaches the existing volume or moves the data: a
     dump of the old stack, taken with the database's own tool, is restored into the new one. An
     attached volume is named through `.env`: `external: true` with `name: "${DB_VOLUME:?}"` in
     both the stage and the prod file, and `DB_VOLUME` in `.env.example` and in the `.env` of
     every server (a row in registry section E until the data moves into the volume the new file
     declares); a literal name would point stage at prod's volume, or fail `make parity`. On a
     server this is part of **Server cut-over**. The old volume or folder is removed only after
     the owner confirms. Done when, on the dev machine, the new stack shows the same row count per
     table as the old stack just before the switch.
   - **Server cut-over** (when the project already runs on a server): `docs/how-to/operations.md`
     gets the section "Moving the running server to the standard" with every step for this
     project: read access to the repository on the server (and build credentials for a private
     dependency, if phase 4 found one); on the dev machine, if the repository has no
     `<PROD_BRANCH>` yet, `git push origin <STAGE_BRANCH>:<PROD_BRANCH>` as the runbook says; a new
     clone of `<PROD_BRANCH>` (`git clone -b <PROD_BRANCH>`, so `make images` builds the commit
     prod will run) in its own folder, not inside the old stack's folder, with `.env` from
     `.env.example` and `chmod 600 .env` (`PROJECT_ENV`, the secrets the old stack uses); a
     machine runs one copy of each environment, so when the old stack's Compose project name
     (`docker compose ls`) is the new file's `name:`, the new clone's commands refuse until the old
     stack's containers are removed: stop writes to the old stack, take a last dump of every store
     with the database's own tool, remove the old stack's containers
     (`docker compose -p <name> down`; the volumes stay), then `make images`, and the downtime the
     section names adds its build time (the `build: … built in N s` lines of the proof run);
     otherwise `make images` while the old stack still serves (it builds every own image of the commit, a data store's own
     image included, and pulls the others, and starts nothing), then stop writes to the old stack,
     take a last dump of every store with the database's own tool and remove the old stack's
     containers, which hold the same ports (`docker compose -p <name> down`; the volumes stay); in
     either case, if the old stack served the public ports or TLS itself,
     the server's front proxy takes them over now (it is not part of the project); move the data
     as **Data carry-over** decided: attach the old volume, or `make bootstrap` and start only the
     stores
     (`IMAGE_TAG=$(git rev-parse 'HEAD^{tree}') docker compose -f docker-compose.prod.yml up -d --wait <store> …`)
     and restore the dump into them with the database's own tool through
     `docker compose -f docker-compose.prod.yml exec -T <store> …`; `make prod`, which builds
     nothing now (the section names how long the application was down in the proof run, from
     removing the old stack's containers to `OK: prod runs <sha>`, so the owner can plan the window);
     `make status` and the row counts compared with the dump. The old stack's data is removed only
     after the owner confirms. The old stack has no `backup` service of this standard, so the data
     moves with the database's own dump and restore; a later move to a new server restores from the
     off-server copy instead (`make restore FROM=copy SET=latest NO_SAFETY=1` before `make prod`,
     as `docs/how-to/backups.md` says). The agent writes the section and runs it end to end in a
     proof copy ([`start.md`](start.md) section 3) against a copy of the old stack in a folder
     directly in `$t` (`clean` finds it there by its compose file), with its own project name and volume names (no `name:`,
     `COMPOSE_PROJECT_NAME` or external volume shared with a stack on this machine) and free host
     ports, never on a server. Done when that run ends with `OK: prod runs <sha>` and the same row
     count per table as the old stack.
   - **Mutation testing** (only when the owner chose it in phase 4,
     [QLT-01](../standard/04-quality.md)): the tool in the `dev` stage with a pin, the `mutation`
     service of `docker-compose.dev.yml` with `MUTATION_CPUS` and `MUTATION_MEM` in `.env.example`,
     `MUTATION` and `MUTATION_DIFF` in the `Makefile` settings, the base of the diff given as
     QLT-01 says for that tool; without it, every part the list in
     [`templates/README.md`](../templates/README.md#mutation-testing-declined) names is removed (the `Makefile` settings and
     targets too), and a mutation tool the project has is a `drop` finding the owner confirms. Done when the mutation check of [`new.md`](new.md)
     step 4 passes in a proof copy.
   - **Language servers** ([AI-07](../standard/05-agents.md)): if a language server or the
     `docker-lsp` plugin is missing or its files differ from the template, add each language's
     server to the `dev` stage with a pin, copy the template files with only the project's
     languages, remove official `*-lsp` plugins. Done when the language-server check of
     [`new.md`](new.md) step 4 passes in a proof copy. That Claude Code loads the plugin (a new
     session in the trusted folder, a type error shows its diagnostic after an edit, the Errors
     tab of `/plugin` is empty) is the owner's step at the end of phase 6.
   - **Hooks** ([AI-05](../standard/05-agents.md), [AI-06](../standard/05-agents.md),
     with a `dev` service): from `$STANDARD/templates/agent-hooks/`, `.claude/hooks/post-edit.sh`,
     `pre-bash.sh`, `check-file.sh`, `check-command.sh` and `json-get.awk` verbatim (or the whole
     `.claude/hooks/` folder), `.claude/hooks/checks.conf` from its starting
     point (a `check` line for the formatter check, the linter and, where it checks one file, the
     type checker of each language, the same tools as `LINT`; `allow` lines only for the host
     exceptions of registry section E), and the hooks of its `settings.fragment.json` merged into
     `.claude/settings.json`. A hook the project already has for the same purpose is replaced, not
     kept next to them; a check of its own that the gates also run becomes a `check` line. Done
     when the hook check of [`new.md`](new.md) step 4 passes in a proof copy, with a host tool
     the project used (such as `npm install`) as the blocked command.
   - **Browser for the agent** (with a UI, when the owner wants it,
     [AI-08](../standard/05-agents.md)): the `browser` profile and the `.mcp.json` entry that rule
     describes. Done when the agent opens the dev application's address with it.
   - **Self-containment**: replace every path into a neighbouring repository with a versioned source
     (image, package, plugin from git).
5. **Verification**: the commands that prove the project meets the standard afterwards: a bare
   `docker compose up` fails with `no configuration file provided`;
   `docker compose -f docker-compose.dev.yml config --services` lists only dev services;
   `docker compose --env-file /dev/null -f <file> config -q --no-env-resolution` fails on `:?` for
   each stage and prod file; `make parity` shows no difference except `name:`;
   `make check-compose` is green and every exception in it has a reason; `make gates` is green in
   under five minutes, and `make verify` is green with every base target run once (its summary
   shows `ok`, `skip` only for an empty `E2E` or `SECURITY`, `off` only where the owner chose it;
   its `infra`
   runs `make backup-test` in dev); the checks of [`new.md`](new.md) step 4 that apply (the pre-push warning
   and the refused second stage clone among them) pass in a
   proof copy ([`start.md`](start.md) section 3), `make image-scan` after the first
   `make stage`; no host tool is called outside registry section E; every component in the
   compose files has a row in registry section A; the README section's commands work on a fresh
   clone.

## Phase 6 — execute (only after the owner approves the plan)

The approved plan goes into the project's backlog ([DOC-02](../standard/06-docs.md)); the report
stays outside the repository. Then, one task at a time:
1. Make the change described by the task. Verbatim templates are copied unchanged except their
   placeholders and the `Makefile` settings and "Project targets" blocks; starting points are
   filled in for the project ([`templates/README.md`](../templates/README.md)).
2. Run the task's "done when" commands, and `make gates` once the task **Dockerfiles** is done.
   If one fails, stop, explain what failed and
   why, and propose a fix; do not move to the next task.
3. Commit the task on its own, with its tests and docs and the registry update
   ([PRN-05](../standard/01-principles.md)).
4. Mark the task done in the backlog.

When the last task is done, run the verification list of phase 5.5, set the registry's `Standard:`
field to this release, and report what is left, including the steps only the owner can do:
- on a server: build credentials for a private dependency if there is one; `chmod 600 .env`; the
  backup folder and the log archive folder chosen in phase 4; the off-server backup copy; with prod
  the heartbeat monitor of `BACKUP_HEARTBEAT_URL`; with health monitoring, the monitor of the
  `status` service and one alarm drill on stage (stop `status` and see the alert), by
  `docs/how-to/operations.md`;
- the variables `.env.example` gained, renamed (with the new name) or removed in this plan, from
  `git diff <the commit before the first task> -- .env.example`, which the owner adds, renames or
  removes in the `.env` of every server before its next `make stage` or `make prod`, and in the
  dev `.env` of every working copy (`make bootstrap` names what each lacks); a second working copy of the
  owner's gets a dev stack of its own (`make dev NAME=<n>` before it has a `.env`, else
  `DEV_SUFFIX=-<n>` and an empty `APP_PORT=` in it), since a second plain clone is refused;
- in a new Claude Code session in the trusted project folder: the Errors tab of `/plugin` is
  empty and a type error shows its diagnostic after an edit ([AI-07](../standard/05-agents.md)).

## Report

Write to `~/audits/<repo>/<YYYY-MM-DD>/`, outside the repository, so nothing reaches git and nothing
needs ignoring. It is a working document for this migration; once the plan is in the backlog and
executed, it can be deleted. The page for the owner ([`start.md`](start.md), section 3) shows these
files: `00`–`02` on the tab "State", `questions.md` on "Questions", `03`, `04`, `05` and
`proposals.md` on "Plan". Use exactly these headings and columns, translated into the report's
language, so that every report reads the same; the markers the page reads stay exactly as written
here, in any language: `### Q-<n>.`, `- [A] `, and `Recommendation:`.

| File | Skeleton |
|---|---|
| `00-summary.md` | `# <repo> — summary` · `## State` (three to five lines) · `## Main deviations` (the five most severe, linked to `02`) · `## Decisions needed` (links to `questions.md`) · `## First tasks` (the first three) |
| `01-current-state.md` | one `##` per phase 1 group (Infrastructure, Docs, Tools, Claude Code layer); facts as `- <fact> — <evidence>` |
| `02-deviations.md` | `## Deviations`: `\| ID \| Rule \| What the project does \| Evidence \| Severity \| Action \| Effort \| Depends on \|` with IDs `X-1`, `X-2`, …; then `## Superfluous`, `## Duplicated`, `## Outdated`, `## Badly organised`, `## Better than the standard` |
| `questions.md` | one `### Q-<n>. <title>` per question: `**What we decide.**`, `**Example.**`, one line per option `- [A] **<name>.** <text with pros and cons>`, `Recommendation: <letter>`, `**Why.**`, `**Sources.**` |
| `03-target-and-plan.md` | `## Target architecture`, `## Claude Code layer`, `## Plan` (tasks `T1`, `T2`, … each with goal, files, done when, tests and docs, depends on, effort, ADR), `## Verification` |
| `04-registry.md` | the registry of phase 5.3 |
| `05-sources.md` | `\| # \| URL \| Quoted sentence \| What it confirms \|` |
| `proposals.md` | one `## P-<n>. <rule ID>: <change>` per proposal: why it is better, a neutral example, the source |

`proposals.md` holds what the project does better than the standard and where the standard did not
work, written so it can be shared: no project names, paths, hostnames or secrets. The owner decides
whether to send it as an issue to the standard's repository.

Before the last message, scan the report folder for secrets with the gitleaks pinned in the
project's dev image, the folder mounted read-only
(`docker run --rm --network none -v "<report folder>:/r:ro" --entrypoint gitleaks <dev image> dir /r`;
a project without gitleaks yet uses the image the standard's samples pin,
`ghcr.io/gitleaks/gitleaks:v8.30.1@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f`);
every hit is removed from the report. End your last message with: what you could not
verify, what you skipped and why, and the risks of the plan.

## Rules for the whole run

- Measure, do not infer: `docker compose config`, `docker inspect`, `git ls-files`, the real
  Dockerfile stage — never a comment or a document as the only evidence.
- No new tool "because it is popular": every `add` names the concrete problem it solves here.
- No duplicate mechanisms: if the project already has a rule, skill or tool for something, plan to
  align it with the standard instead of adding a second one next to it.
- Keep the report short: tables instead of prose, one line per item, links instead of retelling.
- Run nothing that spends tokens or touches production; in phases 0–5 write nothing to issue
  trackers or remote APIs.
