# New: create a project by the standard

The folder is empty (or holds only `.git` and a README). You create the skeleton of a new project
that meets the standard in `$STANDARD` from the first commit, prove that it works, and hand it over.
Stop after every step and wait for the owner, as [`start.md`](start.md) section 3 says.

## 1. Ask

Ask what only the owner knows, one question at a time as [`start.md`](start.md) section 3 says.
First what the project does, in a sentence or two, its name (the repository name, lowercase with
dashes) and which data stores it needs (for example Postgres, Redis), if any; then the questions of
[`questions.md`](questions.md), S-01 to S-25, with your recommendation for each. Every answer
goes into section 0 of the registry ([DOC-03](../standard/06-docs.md)) with its reason, under its
`S-nn` or, for the first three, a short name (`name`, `description`, `data stores`);
[`update.md`](update.md) does not ask them again unless the owner revisits one.

## 2. Plan the skeleton

List every file you will create, and for each the rule it serves and its source: taken from
[`$STANDARD/templates/`](../templates/README.md) (verbatim or a starting point, as that index says),
or written for this project's languages
(the Dockerfile stages of [ENV-08](../standard/02-environments.md), the dev tools of
[QLT-01](../standard/04-quality.md) with exact pins, the lock file, the migration tool). Name every
version you pin and where you took it from. Nothing goes in "just in case"
([PRN-06](../standard/01-principles.md)): a file that no rule or task of this project needs is left
out. With an independent check (S-25), give its rough time and tokens for this list, as S-25 of
[`questions.md`](questions.md) says. Show the list and wait.

## 3. Create

1. Take the template files and fill every setting of the block at the top of the `Makefile`, as
   its comments say: `IMAGES`, `APP`, `MIGRATE` (with a database: never empty, or no migration
   ever runs), `SEED`, `RUN`, `NETWORKS`, `BUILD_SECRETS` (for the private dependency of step 1,
   with its secret in `docker-compose.dev.yml` too), the branches; `LINT`, `TEST` and `SECRETS`
   with the commands (or `off`) of step 1, `E2E` and `SECURITY` where the project has them
   (empty: the summary shows `skip`), and `FIX` with the safe fixers of the `LINT` tools
   ([QLT-01](../standard/04-quality.md)). With `SECRETS` as `gitleaks dir`, which
   reads every file of the working tree, also those git ignores, a `.gitleaks.toml` allowlists the
   local files git ignores, as `$STANDARD/tests/stacks/.gitleaks.toml` does (`.env`, `.cache/`,
   `.deploy/`, the build outputs, the backup folder; `.env.example` stays scanned). Without
   mutation testing, every part of it the list in [`templates/README.md`](../templates/README.md#mutation-testing-declined)
   names is removed (the settings and the targets of the `Makefile` too: the one exception to its
   verbatim copy). The project's own formatter and type checker skip the verbatim files, as
   [`templates/README.md`](../templates/README.md) shows; `shellcheck` checks the verbatim shell
   files too. A command of
   the project's own (for example an asset build, a worker or a report) becomes a target in the
   block "Project targets" at the end of the `Makefile`, with a `## ` help text and a row in the
   README section, under a name no standard target has
   ([ENV-05](../standard/02-environments.md)).
2. Write `docker/<service>/Dockerfile` for every own service with the stages of
   [ENV-08](../standard/02-environments.md): `base` (the pinned OS image, the language and the
   runtime libraries from the lock file), `runtime` (`base` + the code, a non-root user, the start
   command) and `dev` (`base` + the pinned dev tools and the language servers of S-21; it never
   copies the code, which comes only from the dev mount, so a code change does not rebuild it).
   Then the
   compose files of the environments the project has ([ENV-01](../standard/02-environments.md)),
   `.env.example` with a comment on every variable (`BACKUP_DIR` and `LOG_ARCHIVE_DIR` as the
   owner chose; the limits from the server size, or the template's), the services for its data
   stores with official images pinned by version and digest (`<image>:<version>@sha256:<digest>`,
   [ENV-03](../standard/02-environments.md)) and named volumes, the application logging in to a
   database with its own role, never the superuser (the template's `APP_DB_USER` and
   `APP_DB_PASSWORD`; its `DB_PASSWORD` is the superuser's, so a framework with names of its own,
   such as Laravel's `DB_USERNAME` and `DB_PASSWORD`, gets them from those two in the
   application's `environment:`), for tests against a database the `db-test` service
   on tmpfs that the dev file's comment shows, with backups (S-06) the `backup` service of
   [OPS-01](../standard/03-operations.md) from the template (a module for every store; the
   template's `postgres` module is the pattern for others and needs PostgreSQL 15 or later),
   with health monitoring the `status` service of [OPS-04](../standard/03-operations.md) from the
   template (`docker/status/`, its compose blocks and `.env.example` variables, `status` in
   `IMAGES`; without monitoring all of these are left out), and, with stage or prod,
   `docs/how-to/tuning.md` and `scripts/tuning-check.sh` from their starting points, with a row
   and a check line for every tuned parameter ([OPS-02](../standard/03-operations.md));
   with prod, `trivy.yaml` from its starting point and a pinned trivy in the `dev` stage for
   `make image-scan` ([QLT-01](../standard/04-quality.md)).
3. With the agent's hooks (S-20), those of [AI-05 and AI-06](../standard/05-agents.md) from
   `$STANDARD/templates/agent-hooks/`: `.claude/hooks/post-edit.sh`, `pre-bash.sh`,
   `check-file.sh`, `check-command.sh` and `json-get.awk` verbatim (or the whole `.claude/hooks/`
   folder), `.claude/hooks/checks.conf` from its starting point with a `check` line
   for the formatter check, the linter and (where it checks one file) the type checker of each
   language, the same tools as `LINT`, and the hooks of its `settings.fragment.json` merged into
   `.claude/settings.json`. With language servers (S-21), the `docker-lsp` plugin of
   [AI-07](../standard/05-agents.md) from `$STANDARD/templates/docker-lsp/`: its
   `.claude/plugins/` files with `<repo>`, `<owner>` and the project's languages filled in, and its
   `settings.fragment.json` merged the same way. With a
   browser for the agent, the `browser` profile and the `.mcp.json` entry of
   [AI-08](../standard/05-agents.md).
4. Write the smallest working application: one test that runs in `make gates`, and, with a
   database, one migration. A project with stage or prod also starts and answers the healthcheck
   of its stage and prod files; a library has only dev, and `make gates` is its whole proof.
5. Fill the README section ([DOC-04](../standard/06-docs.md)), `AGENTS.md`, the registry
   ([DOC-03](../standard/06-docs.md)) with every answer of step 1 in its section 0, and the docs
   pages the project needs ([DOC-01](../standard/06-docs.md)), with `tuning.md` as the table of
   [`adopt.md`](adopt.md) phase 5.1 and, with backups, `backups.md` from its starting point.
   Every rule the project does not meet yet gets a row in registry section E with its reason and
   trigger.

## 4. Prove it

Run the proofs in a proof copy ([`start.md`](start.md) section 3), so the project folder gets no
commit and no remote before step 5: `sh "$STANDARD/scripts/proof.sh" create` in the project
folder (without `.git` the copy gets its own, with the branches the owner chose). Commit and push
every later change in `$t/p` as [`start.md`](start.md) section 3 says. Run, and keep each
output for the report:
- `make dev` in `$t/p` starts the stack and prints the addresses; with stage or prod, once the
  application runs in the dev container (`docker compose -f docker-compose.dev.yml exec -d dev sh -c '<RUN>'`),
  the command of the healthcheck in its stage and prod files answers there:
  `docker compose -f docker-compose.dev.yml exec -T dev <command>`; `make logs TAIL=20` prints
  the last lines and ends;
- `make gates` is green, takes under five minutes and ends with its summary, one line for each of
  `lint`, `test` and `secrets`: `ok`, or `off` for a check the owner turned off; a
  deliberately failing test, committed in `$t/p`, makes `git push origin HEAD:<STAGE_BRANCH>`
  refuse after the gates' output and `make gates: FAIL (test)`; after `git revert --no-edit HEAD`
  and one more commit in `$t/p` with a new file left uncommitted next to it,
  `git push origin HEAD:<STAGE_BRANCH>` (the run has no terminal) prints
  `pre-push: WARNING: not committed in <top>, and the gates check them together with the commit:`
  with that file, runs the gates and pushes (then remove the file); with `FIX` set, a formatting
  slip planted in a code file makes `make lint` fail,
  `make fix` repairs it (`git diff` shows only that), and `make gates` is green again; after a
  one-line change to a code file,
  `docker compose -f docker-compose.dev.yml build dev` rebuilds no layer of the dev image: its
  creation time (`docker image inspect -f '{{.Created}}' <repo>-dev-proof-dev`) stays the same
  (its ID may change: each build can add a new provenance record);
- `make verify` is green: every base target of it ran once (`lint`, `test`, `e2e`, `security`,
  `infra`), and its summary shows `ok` for each, `skip` only for an empty `E2E` or `SECURITY`, and
  `off` only where the owner chose it;
- with mutation testing ([QLT-01](../standard/04-quality.md)): `make mutation-diff` run once, then
  again after a one-line change to one code file, mutates only that file the second time (its
  report names no mutant in another file), and `make mutation` runs over all the code;
- with language servers, the servers ([AI-07](../standard/05-agents.md)), in `$t/p` with its
  dev stack running:
  `docker compose -f docker-compose.dev.yml exec -T dev sh -c 'command -v <server>'` finds each,
  and each answers over LSP, started as the plugin starts it, with a type error planted in a file
  of its language in its diagnostics: the session of the function `lsp` in
  `$STANDARD/tests/stacks/run.sh`, with its client `$STANDARD/tests/stacks/lsp-client.py` in the
  pinned Python image of `scripts/check-compose.sh` (`git checkout -- <file>` takes the error out
  again). That Claude Code loads the plugin is the owner's step of step 5;
- with the agent's hooks, the hooks, fed the JSON Claude Code sends, in `$t/p` with its dev
  stack running:
  `printf '{"hook_event_name":"PostToolUse","tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$PWD/<file>" | sh .claude/hooks/post-edit.sh; echo "exit $?"`
  prints only `exit 0` for a clean file of each language, and `exit 2` after `check failed: <file>`
  and the tool's message once a lint error is planted in that file (an unused import, for
  example; `git checkout -- <file>` takes it out again); after `make down` it prints
  `check NOT run: the dev container is not running` and `exit 2` (then `make dev` again);
  `printf '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"%s"}}' '<a host tool of the project, such as npm install>' | sh .claude/hooks/pre-bash.sh; echo "exit $?"`
  prints `blocked: …` and `exit 2`, and with the command `make gates` only `exit 0`;
- with stage or prod: `make parity` and `make check-compose` are green;
  `sh "$STANDARD/scripts/proof.sh" stage` makes the stage clone (`PROJECT_ENV=stage`; without
  stage, `prod` and `PROJECT_ENV=prod` wherever this item says stage), whose `make stage` prints
  the free space it checked (`space: <free> free where Docker keeps the images (need <X>)`), builds
  the images of the commit (`build: <repo>-proof-<img>:<tree> from commit <sha>`), deploys it and
  prints `OK: stage runs <sha>`, then a `tuning-check: ok` line for every row of `tuning.md`; with
  prod, `make image-scan` in `$t/p` after that first `make stage` (a scan before it builds the
  same images, and the stage clone would then print no `build:` line) ends with
  `image-scan: OK` (a finding is fixed, or accepted in `.trivyignore` with its reason in a
  comment above it and a question to the owner); with that clone's `.env` readable by others
  (`chmod 644 .env`), `make stage` refuses with
  `.env can be read or written by other users of this machine (-rw-r--r--): chmod 600 .env`
  (then `chmod 600 .env`); a value changed in that clone's `.env`
  turns `make tuning-check` red until `make restart`; a second `make stage` prints no `build:`
  line; a second clone of stage on this machine, `git clone -b <STAGE_BRANCH> "$t/remote.git" "$t/stage2"`
  with a copy of the stage clone's `.env` (mode 600), refuses `make stage` before any change with
  `<project> already runs from <folder> …`, the folder `$t/stage`, and the stage clone's containers
  stay as they were (then `rm -rf "$t/stage2"`); a deliberately broken line in a Dockerfile (a failing `RUN` in the `runtime` stage) stops
  it with
  `building <repo>-proof-<img> for commit <sha> failed (above); nothing was replaced` and a
  deliberately failing migration (pushed with `--no-verify`) stops it, each with the old
  application still running, as [`start.md`](start.md) section 3 says; the deploy of a second
  good commit prints `log-archive: <LOG_ARCHIVE_DIR>/<UTC time>-<service>.log` for the container
  it replaced (unless the owner chose no archive), and that file holds the old container's log;
  then `make rollback` returns to the first commit;
- with a database on stage or prod: the application's role is no superuser (Postgres:
  `docker compose -f <file> exec -T db psql -U postgres -tAc "SELECT rolsuper FROM pg_roles WHERE rolname = '<APP_DB_USER>'"`
  prints `f`; `<file>` is the clone's compose file);
- with health monitoring, in the stage clone: `make status` shows `status` and `status-proxy`
  healthy, and the envelope, read inside the status container (the host has no `curl`),
  `docker compose -f <file> exec -T status python -c 'import os, urllib.request as u; print(u.urlopen(u.Request("http://127.0.0.1:8080/status", headers={"Authorization": "Bearer " + os.environ["STATUS_TOKEN"]})).read().decode())'`,
  names every service of the file with `"status": "pass"` overall; after
  `docker compose -f <file> stop <a service>` the same command fails with
  `HTTP Error 503: Service Unavailable` until `docker compose -f <file> start <that service>`;
- `make dev` in the worktree `$t/wt` starts its own stack next to the main one;
- with backups: `make backup-test` in `$t/p` prints `OK`. With stage or prod, in the stage
  clone (`<file>` is its compose file), whose `.env` the script gave
  `BACKUP_COPY_TO=/backup/.copy` (a local-path repository inside `BACKUP_DIR`, for this proof
  only). The steps name the store `db`
  and its module's database tools as in the template's `postgres` module; for another store, the
  same step with that store's name and its own tool:
  1. `make backup`, `make backup-drill` and `make backup-copy-check` print `OK`, and
     `make backup-list` lists the new set of every store;
  2. after `docker compose -f <file> exec -T -u postgres backup sh -c 'echo 1 > /backup/.state/set.db'`
     (the newest set of the store `db` now looks decades old; `-u` names the backup user,
     `BACKUP_USER` of `docker/backup/Dockerfile`), `make backup-status` fails with
     `unhealthy: the newest set of db was made …`; after `make backup` it says `healthy: …`;
  3. the run has no terminal, so `make restore FROM=copy SET=latest` without `CONFIRM=yes` prints
     `restore: would restore db from <set> (copy)` and what it would replace, then
     `restore replaces the working database <name> on <host>: run again with CONFIRM=yes`, stops
     nothing and changes nothing; `env CONFIRM=yes make restore FROM=copy SET=latest` is refused
     the same way. A person at a terminal types the database name instead; that path is proved
     by the standard's tests only, never in a proof copy, which has no terminal;
  4. the safety set: after `make backup`, write a mark into the store that the next set will not
     hold (Postgres: `docker compose -f <file> exec -T db psql -U postgres -d <db> -c 'CREATE TABLE proof_mark ()'`);
     `make restore CONFIRM=yes` prints `backup: db/before-restore-<time> OK (…)` before it
     replaces anything, and the mark is gone; `make backup-list` lists exactly one set of kind
     `before-restore` per store, where `local, copied`; `make backup-drill` drills the newest normal
     set (its line names that set, not the safety set); `make restore SET=before-restore CONFIRM=yes`
     brings the mark back, and `make backup-list` still lists one safety set (the new one); after
     `make backup`, which rotates, it is still there;
  5. after the application's tables are dropped with the store's own tool (Postgres:
     `docker compose -f <file> exec -T db psql -U postgres -c 'DROP TABLE <its tables> CASCADE'`;
     the database stays, since the db healthcheck connects to it; never `docker volume rm`),
     `make restore FROM=copy SET=latest NO_SAFETY=1 CONFIRM=yes` says
     `restore: db: no safety set (NO_SAFETY=1)`, restores it, says
     `restore: db OK: equal to the manifest of <set>` and
     `restore: the application is stopped: make restart starts it again`, and `make restart`
     prints `OK: stage runs <sha> (restarted with the current .env)`.

If `create` refuses for `BUILD_SECRETS`, every check of this list is reported as not verified
([`start.md`](start.md) section 3), not as failed. If something fails,
`sh "$STANDARD/scripts/proof.sh" clean`, fix it in the project folder, and
run the whole list again in a new proof copy. At the end, `clean` the same way.

## 5. Hand over

With an independent check (S-25 of [`questions.md`](questions.md)), an agent that made no change
first checks the skeleton as S-25 says, and what it finds is fixed and checked again. Then, with
the owner's approval, set the registry's `Standard:` field to this release and make the first
commit: without `.git`, first `git init -b <STAGE_BRANCH>`; with one, on its current branch. Put
the open items (registry section E rows
with a trigger, the owner's steps below) into the backlog the owner named in step 1
([DOC-02](../standard/06-docs.md)). Then report in the report folder
(`~/audits/<repo>/<YYYY-MM-DD>/`, the page of [`start.md`](start.md) section 3): `00-summary.md`
(what was created, what could not be verified, and the steps only the owner can do: create the
remote repository and push; with language servers, open the project in a new Claude Code session,
trust the folder, and check that the Errors tab of `/plugin` is empty and that a type error shows
its diagnostic after an edit ([AI-07](../standard/05-agents.md)); set up the servers by
`docs/how-to/operations.md` (read access to the repository, and to a private dependency if there
is one, since each server builds its own images; `.env` with `chmod 600`; with backups the backup
folder, and the log archive folder unless there is none, as chosen in step 1); with backups, the off-server backup copy and the
heartbeat monitor of `BACKUP_HEARTBEAT_URL`, each if chosen, by `docs/how-to/backups.md`; with
health monitoring, the monitor of the
`status` service and one alarm drill on stage (stop `status` there and see the alert) by
`docs/how-to/operations.md`), `01-current-state.md` (the outputs of step 4 as
`- <fact> — <evidence>`), and `questions.md` if anything is still open, in the formats of
[`adopt.md`](adopt.md), section "Report".
