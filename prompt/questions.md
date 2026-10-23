# Setup questions

This file is the English source. Ask each question in the owner's language, translated as you go
([`start.md`](start.md) section 3); never translate this file in the repository.

These are the questions the standard asks when it is applied: [`new.md`](new.md) step 1,
[`adopt.md`](adopt.md) phases 0 and 4, and [`update.md`](update.md) for the questions a release
adds. How they are asked (one at a time, theme by theme, in this order) is in
[`start.md`](start.md) section 3. What is never asked is [the core of TYP-01](../standard/07-project-types.md#the-core);
the recommended option of each question by project type, its level, whether it can be declined
and the rule behind it are in [the choices of TYP-01](../standard/07-project-types.md#the-choices), and not
repeated here.

- A question whose answer the project's facts give, as its line "Skipped when" says, is not asked:
  say the answer with its evidence in one line, and the owner may correct it. A question whose
  part does not apply (no stage or prod, for example) is left out.
- A question that registry section 0 already answers is not asked again, except when the project
  is set up again (the recorded answer is then shown as a reference, never as the answer) or the
  owner revisits it in an update.
- Before the owner declines a part whose level in TYP-01 is M, explain the risk of declining in
  detail, with the example below. A declined part is recorded with its reason and is not a
  deviation: no row in registry section E, and an audit or update does not count it.
- Every answer goes into registry section 0 ([DOC-03](../standard/06-docs.md)): `S-nn` (an answer
  outside this file gets a short name instead), on or off or the value, the reason, the date. "Answer goes to" names the files and settings it fills as
  well.

## 1. Environments

### S-01. Project type and languages

- **What it is.** What kind of project this is (a service with a database, a frontend, a pipeline
  or agents, a library or plugin, ML: the table of [TYP-01](../standard/07-project-types.md)) and
  its languages. It decides which parts apply. A repository may have several types and takes the
  parts of each.
- **Example.** An API in Python with a React UI is a service with a database and a frontend: it
  is offered backups and browser tests; a Claude Code plugin is a library and gets only dev.
- **Risk without it.** A wrong type leaves out what the project needs (backups of a service) or
  adds what it does not (stage and prod files for a library).
- **Options.** The type and languages you found, which the owner confirms or corrects; nothing
  else, it cannot be declined.
- **Skipped when.** Never asked open: in adopt, say what the code and files show and ask to
  confirm; in new, propose it from the owner's description of the project.
- **Answer goes to.** The profile line of section 0 (`Type:`, `Languages:`).

### S-02. Environments: stage, prod

- **What it is.** Dev is always there. Prod is where users work; whatever runs anywhere other than
  a developer machine has prod ([ENV-01](../standard/02-environments.md)). Stage is a server that
  runs the same images as prod with test data, where a change is tried first.
- **Example.** A migration that locks a large table for ten minutes shows on stage in the evening,
  not on prod at noon.
- **Risk without it.** Without stage, a change meets its first server when users see it; without
  prod, the project never runs anywhere but a developer machine, which only suits a library.
- **Options.**
  - dev, stage and prod: a change is tried on a server before users see it; a second server to pay
    for and look after.
  - dev and prod: cheaper; a change is tried only in a proof copy on the developer machine before
    prod.
  - dev only: for a library or plugin; nothing is deployed.
  With stage or prod come the parts TYP-01 adds by itself (the deploy targets, the compose rule
  check and the others it lists); they are not asked.
- **Skipped when.** Not by facts: the compose files of an existing project show what it has, not
  what it should have; propose from the type and ask.
- **Answer goes to.** The profile line of section 0 (`Environments:`), and the files
  `docker-compose.stage.yml` and `docker-compose.prod.yml` of the environments chosen.

### S-03. Branches of stage and prod

- **What it is.** Each server deploys what one git branch holds
  ([ENV-09](../standard/02-environments.md)): the stage branch and the prod branch.
- **Example.** A merge into `main` is what stage runs after `make stage`; merging `main` into
  `prod` is what prod runs after `make prod`.
- **Risk without it.** Names that do not match the project's way of working (it already releases
  from `main`, for example) make people push to the wrong branch.
- **Options.** The template's `main` and `prod`, or the owner's own names.
- **Skipped when.** No stage or prod. An existing `Makefile` of the template already sets them:
  say them.
- **Answer goes to.** The `Makefile` settings `STAGE_BRANCH` and `PROD_BRANCH`.

### S-04. Size of the servers

- **What it is.** The CPUs and memory of each server. The container limits and the numbers derived
  from them come from it ([OPS-02](../standard/03-operations.md)).
- **Example.** Postgres with a 1 GB limit gets `DB_SHARED_BUFFERS=256MB`; its factory 128MB leaves
  memory unused, and numbers made for a larger server get the container killed.
- **Risk without it.** Limits that do not fit the server: a container killed for memory, or a
  server that swaps.
- **Options.**
  - The size of each server: the limits fit from the first deploy.
  - Not known yet: the template's limits, and a row in registry section E whose trigger is "the
    server exists".
- **Skipped when.** No stage or prod. A size the owner or the repository gives is said, not asked
  (adopt phase 1 measures no server).
- **Answer goes to.** The limits (`*_CPUS`, `*_MEM`) and the derived numbers (such as
  `DB_SHARED_BUFFERS` and `DB_EFFECTIVE_CACHE_SIZE`) in `.env.example`, and
  `docs/how-to/tuning.md`.

### S-05. A private dependency in the build

- **What it is.** Each server builds its own images from the commit
  ([ENV-09](../standard/02-environments.md)). A package from a private registry or repository then
  needs read credentials on every machine that builds: a file outside git, mounted into the build
  as a BuildKit secret and never baked into the image.
- **Example.** A company package on a private npm registry: without its token on the server, the
  build of `make stage` stops at the install step.
- **Risk without it.** The first deploy fails on the server, or someone copies the token into the
  Dockerfile, and every image then holds it.
- **Options.**
  - None.
  - Yes, which one and the file that holds its credentials. A con: a proof copy cannot run, since
    git ignores that file (`scripts/proof.sh` refuses), so the stage and prod proofs go into the
    report as not verified.
- **Skipped when.** The lock files and Dockerfiles fetch only from public sources: say so.
- **Answer goes to.** The `Makefile` setting `BUILD_SECRETS` (`<id>=<file>` pairs), the same
  secret in `docker-compose.dev.yml`, and the owner's step of putting the file on each server.

## 2. Data and backups

### S-06. Backups of the data

- **What it is.** The `backup` service makes a daily set of every data store, checks each set, and
  restores the newest one into a temporary database once a week to prove it can be restored
  ([OPS-01](../standard/03-operations.md)). Before a migration a deploy takes one more set.
- **Example.** The server's disk dies: the data comes back from the copy within an hour. Without
  a backup it is gone.
- **Risk without it.** Data lost for good after a broken disk, a mistaken `DROP` or a bad
  migration, and no set to return to before a migration.
- **Options.**
  - Yes: the data can be restored, and the weekly drill proves it; one more service, disk space
    for the sets.
  - No: nothing to run; the usual reason is data that can be rebuilt (a cache, a copy of data kept
    elsewhere, the dev data that `make seed` makes again). The parts
    [`templates/README.md`](../templates/README.md) lists for a project without data worth keeping
    are left out.
- **Skipped when.** No data store.
- **Answer goes to.** The `backup` service with its compose blocks, `docker/backup/`, `backup` in
  the `Makefile` setting `IMAGES`, the `BACKUP_*` lines of `.env.example`, and
  `docs/how-to/backups.md`.

### S-07. The folder of the backup sets

- **What it is.** Where on each server the sets are kept.
- **Example.** The system disk has 20 GB and the data disk 500 GB: sets on the system disk fill it
  in a month.
- **Risk without it.** Sets on a disk without room stop the backups; sets on the disk of the data
  die with it (the off-server copy, S-08, covers that).
- **Options.**
  - The template's `./docker/backup/data` in the clone: nothing to set up; it is on the disk of the
    clone.
  - Your advice with its reason (another disk, where the project keeps its data today).
  - A path of the owner's.
- **Skipped when.** No stage or prod, or no backups (S-06).
- **Answer goes to.** `BACKUP_DIR` in `.env.example` and in the `.env` of each server.

### S-08. A copy of the backups on another machine

- **What it is.** Every set is also copied, encrypted, to storage on another machine, where this
  server can only write: it can add sets and never delete them.
- **Example.** The server is broken into or burns: the sets on its disk are gone with it, and the
  intruder cannot delete the copy, because the server cannot either.
- **Risk without it.** A copy on the same disk does not survive that disk.
- **Options.**
  - A rest-server on which the server can only write (`rest:https://<host>:<port>/<login>/`), the
    template's example ([`backups.md`](../templates/project/docs/how-to/backups.md)).
  - Another kind of storage: it needs its own client in `docker/backup/` and its own proof that
    the server cannot delete from it.
  - None.
  Until a server exists, the copy waits in registry section E as TYP-01 says.
- **Skipped when.** No stage or prod, or no backups (S-06).
- **Answer goes to.** `BACKUP_COPY_TO`, `BACKUP_COPY_LOGIN`, `BACKUP_COPY_LOGIN_PASSWORD`,
  `BACKUP_COPY_PASSWORD` and `BACKUP_COPY_CACERT` in `.env`, and `docs/how-to/backups.md`.

### S-09. Heartbeat of the backups

- **What it is.** After each good daily run the backup service calls a monitor on another machine;
  the monitor alerts when a call does not come.
- **Example.** After a server reboot the backup service did not start. Nothing fails loudly, but
  the next morning the monitor alerts because the call is missing.
- **Risk without it.** A backup that stopped silently is found only on the day a restore is needed.
- **Options.** Yes, with the monitor (a hosted heartbeat service or the owner's own), set up once
  a server exists (registry section E until then); or no.
- **Skipped when.** No prod, or no backups (S-06).
- **Answer goes to.** `BACKUP_HEARTBEAT_URL` in `.env`.

### S-10. Notifications of a backup failure

- **What it is.** A one-line message to a webhook about every backup failure.
- **Example.** At 03:00 the chat channel of the team gets a line that the backup failed because
  the disk is full.
- **Risk without it.** A failure shows only in the service's health, the heartbeat (S-09) or the
  status service (S-17), which someone has to look at.
- **Options.** Yes, with the webhook (a chat channel, an incident tool); or no, until there is a
  place to send it.
- **Skipped when.** No stage or prod, or no backups (S-06).
- **Answer goes to.** `BACKUP_NOTIFY_URL` in `.env`.

## 3. Quality checks

`LINT`, `TEST` and `SECRETS` (S-15) take a command or `off`; empty is not an answer, since it
fails `make gates` as not set up yet. `E2E` and `SECURITY` (S-16) take a command, empty (the
summary shows `skip`) or `off`. The tools of each category for each language are in
[QLT-01](../standard/04-quality.md); in adopt, propose from the tools phase 1 found.

### S-11. Static checks (`LINT`)

- **What it is.** Checks that do not run the code: the format, the linter, the types, `shellcheck`,
  the links of the docs, architecture contracts. They run in `make gates`, before every push.
- **Example.** An unused import or a wrong type is caught on the developer machine, not after a
  deploy.
- **Risk without it.** Format drift and type errors reach the branch.
- **Options.** The command you propose (it runs fast and offline); or `off`, and the summary of
  `make gates` shows `off`.
- **Skipped when.** Not by facts: an existing command is shown as your proposal.
- **Answer goes to.** The `Makefile` setting `LINT`, `FIX` with the safe fixers of the same tools,
  and the `check` lines of `.claude/hooks/checks.conf`.

### S-12. Tests (`TEST`)

- **What it is.** Tests that run the code, fast and offline: unit tests, tests against a real
  database, property-based tests. They run in `make gates`.
- **Example.** A change to a discount rule breaks the total of an order; a test fails before the
  push.
- **Risk without it.** A broken behaviour is found by a user.
- **Options.** The command you propose; or `off`.
- **Skipped when.** Not by facts: an existing command is shown as your proposal.
- **Answer goes to.** The `Makefile` setting `TEST`; with tests against a database, the `db-test`
  service of `docker-compose.dev.yml`.

### S-13. End-to-end tests (`E2E`)

- **What it is.** Tests that run the whole application, slowly: the API contract, the browser,
  calls to outside APIs. They run in `make verify`, not before every push.
- **Example.** After a style change the login button no longer submits; a browser test clicks it
  and fails.
- **Risk without it.** What only shows when the parts work together is found by a user.
- **Options.** The command you propose (Playwright for a UI, schemathesis for an OpenAPI); empty
  (`skip`); or `off`.
- **Skipped when.** No UI, no OpenAPI and no calls to outside APIs: say it, and `E2E` stays empty.
- **Answer goes to.** The `Makefile` setting `E2E`.

### S-14. Mutation testing

- **What it is.** A tool changes the code on purpose (a `>` into `>=`, for example) and checks
  that a test fails. It finds tests that pass whatever the code does. It runs by hand and is slow
  ([QLT-01](../standard/04-quality.md)).
- **Example.** A test calls the price function but asserts nothing; every mutant survives, and the
  report shows that this code is not really tested.
- **Risk without it.** Tests that look green and check nothing.
- **Options.**
  - Yes: the limits of its container and the base of `make mutation-diff` (normally the stage
    branch). It suits code with logic; a run takes long.
  - No: nothing of it goes into the project; the parts the list in
    [`templates/README.md`](../templates/README.md#mutation-testing-declined) names are removed.
- **Skipped when.** Not by facts.
- **Answer goes to.** With yes: the `Makefile` settings `MUTATION` and `MUTATION_DIFF`, the
  `mutation` service of `docker-compose.dev.yml`, `MUTATION_CPUS` and `MUTATION_MEM` in
  `.env.example`, and the tool in the `dev` stage.

## 4. Security

### S-15. Secret scan (`SECRETS`)

- **What it is.** A scan of the working tree for passwords, keys and tokens, offline, in
  `make gates` before every push.
- **Example.** An API key pasted into a config file is caught before the push. Once pushed, it is
  in the history for good and must be revoked.
- **Risk without it.** A secret in git, readable by everyone who can read the repository.
- **Options.** The command you propose (a scan of the working tree needs an allowlist of the files
  git ignores in `.gitleaks.toml`, as [QLT-01](../standard/04-quality.md) says); or `off`.
- **Skipped when.** Not by facts.
- **Answer goes to.** The `Makefile` setting `SECRETS`, and `.gitleaks.toml`.

### S-16. Code analysis and dependency audit (`SECURITY`)

- **What it is.** Static security analysis of the code (semgrep) and an audit of the dependencies
  against the lists of known vulnerabilities, which needs the network. They run in
  `make security` and `make verify`.
- **Example.** A library version with a known hole: the audit names it and the version that fixes
  it.
- **Risk without it.** A known vulnerability ships unnoticed.
- **Options.** The command you propose; empty (`skip`); or `off`.
- **Skipped when.** Not by facts.
- **Answer goes to.** The `Makefile` setting `SECURITY`.

## 5. Monitoring and logs

### S-17. Health monitoring

- **What it is.** The `status` service reports the health of every service and the free disk
  space to a monitor on another machine, which alerts when something fails or the reports stop
  ([OPS-04](../standard/03-operations.md)).
- **Example.** The cache dies at night, and the alert comes in a minute instead of the next
  morning from a user.
- **Risk without it.** A failure is found by users, or by someone who happens to run
  `make status`.
- **Options.**
  - Yes: two small services (`status` and its socket proxy, which reads the Docker socket
    read-only) and a monitor to set up.
  - No: the parts [`templates/README.md`](../templates/README.md) lists for a project that does
    not want health monitoring are left out.
- **Skipped when.** No stage or prod.
- **Answer goes to.** The `status` and `status-proxy` services, `docker/status/`, `status` in
  `IMAGES`, the `STATUS_*`, `DISK_WARN` and `DOCKER_GID` lines of `.env.example`, and the section
  "Monitoring" of `docs/how-to/operations.md`.

### S-18. Where the monitoring signals go

- **What it is.** The monitor that receives the reports of the `status` service.
- **Example.** A hosted monitor that expects a report every minute and alerts on silence; or the
  owner's own monitor that asks the server every minute.
- **Risk without it.** The service reports to no one, and nobody is alerted.
- **Options.**
  - The service sends its reports to the monitor (push): works behind a firewall; the monitor
    alerts when they stop.
  - The monitor asks `GET /status` through the server's front proxy, with the token: no outgoing
    calls from the server; the monitor must reach it.
  - Not known yet: it is set up once a server exists.
- **Skipped when.** No health monitoring (S-17).
- **Answer goes to.** `STATUS_TOKEN` and `STATUS_PORT` in `.env`, and for push
  `STATUS_PUSH_URL`, `STATUS_PUSH_FAIL_URL` and `STATUS_PUSH_INTERVAL`; the owner's step of setting
  up the monitor and one alarm drill on stage.

### S-19. Archive of the logs of replaced containers

- **What it is.** A deploy, rollback or restart replaces containers, and Docker removes a
  container's logs with it. The archive keeps each replaced container's log in a folder
  ([OPS-03](../standard/03-operations.md)).
- **Example.** The new version fails and is rolled back; the warning the old version logged an
  hour before is still in the archive.
- **Risk without it.** The logs of a replaced container are gone. With it, nothing removes old
  files: the folder grows until someone clears it.
- **Options.**
  - The template's `.deploy/logs` in the clone.
  - Your advice with its reason (a disk with more room).
  - A path of the owner's.
  - None: the logs of a container go with it.
- **Skipped when.** No stage or prod.
- **Answer goes to.** `LOG_ARCHIVE_DIR` in `.env.example` and in the `.env` of each server (empty
  for none).

## 6. The agent's tools and the project's docs

### S-20. The agent's hooks

- **What it is.** Two hooks of Claude Code: after every edit the changed file is checked in the dev
  container ([AI-05](../standard/05-agents.md)), and before every shell command a language tool run
  on the host is blocked, with the `make` target to use instead
  ([AI-06](../standard/05-agents.md)).
- **Example.** The agent writes a type error and hears about it at once, not at `make gates`; it
  types `npm install` on the host and is told the target to use instead.
- **Risk without it.** Errors pile up until the gates; tools run on the host and leave
  `node_modules` or a `.venv` there.
- **Options.** Yes: each edit waits a moment for the check; the PowerShell tool on Windows is not
  covered. Or no.
- **Skipped when.** Not by facts.
- **Answer goes to.** `.claude/hooks/`, `.claude/hooks/checks.conf` and the hooks in
  `.claude/settings.json`.

### S-21. Language servers for the agent

- **What it is.** Language servers in the dev container give the agent errors after an edit,
  go-to-definition and find-references ([AI-07](../standard/05-agents.md)).
- **Example.** The agent renames a function and finds every caller through the references, not by
  searching text.
- **Risk without it.** The agent works from text search and finds type errors only at the gates.
- **Options.** Yes: a larger dev image, and the owner checks once that Claude Code loaded the
  plugin. Or no.
- **Skipped when.** Not by facts.
- **Answer goes to.** The servers in the `dev` stage of the Dockerfile, `.claude/plugins/`, and
  the plugin in `.claude/settings.json`.

### S-22. A browser for the agent

- **What it is.** A browser in Docker that the agent drives to open the dev application
  ([AI-08](../standard/05-agents.md)).
- **Example.** After a change the agent opens the page and sees that the save button is hidden
  behind the menu.
- **Risk without it.** The agent cannot see the UI it changes.
- **Options.** Yes: it guides the browser to trusted addresses but does not protect against a
  hostile page, and the templates have no browser profile yet (the agent writes it from AI-08). Or
  no.
- **Skipped when.** No UI.
- **Answer goes to.** The `browser` profile of `docker-compose.dev.yml` and `.mcp.json`.

### S-23. Where the backlog lives

- **What it is.** The one place for the project's tasks ([DOC-02](../standard/06-docs.md)); the
  plan's tasks and the open items go there.
- **Example.** The tasks of the adopt plan land in it, and each is marked done when committed.
- **Risk without it.** Tasks spread over notes, chats and files, and some are lost.
- **Options.**
  - A file in the repository: versioned with the code, no account needed; no board or
    notifications.
  - An issue tracker (which one): a board and assignments; outside git, and the agent writes to it
    only while executing a plan the owner approved.
- **Skipped when.** The project already has a backlog (adopt phase 0 reads it): say where.
- **Answer goes to.** Section 0 only.

### S-24. The language of the documentation

- **What it is.** The language of the README, `docs/`, the registry and `AGENTS.md`. It is not the
  language of the conversation, which [`start.md`](start.md) section 3 sets.
- **Example.** A team in one country writes its docs in its own language; a project with outside
  contributors writes them in English.
- **Risk without it.** Docs in two languages, half of them read by no one.
- **Options.** The owner's language: the team reads it best. English: anyone, and any agent,
  reads it. Another language of the owner's.
- **Skipped when.** The existing docs are all in one language: say which.
- **Answer goes to.** Section 0 only.
