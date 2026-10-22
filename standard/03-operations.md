# Operations

> Version 1.0.0-draft · English · [Українська](03-operations.uk.md)

### OPS-01. Backups (M, if the project has data worth keeping)

Data is worth keeping unless it can be rebuilt from the code or from another store, as a cache or a
search index usually can; registry section A says which. All backup logic lives in one `backup`
service, built from [`templates/project/docker/backup/`](../templates/project/docker/backup/). In
stage and prod it always runs; in `docker-compose.dev.yml` it has the `backup` profile and does not
start by itself. The working databases stay in their own containers, and `backup` connects to each
one as a client. How it works step by step, how to set it up, check it and restore is the project's
`docs/how-to/backups.md`, from [its starting point](../templates/project/docs/how-to/backups.md).
What may differ between servers (times, rotation, folder, the copy's address and secrets, and the
limits `BACKUP_CPUS` and `BACKUP_MEM` of
[OPS-02](#ops-02-tuning-to-resources-m-where-factory-settings-do-not-fit-r-otherwise)) is a variable in `.env` with a comment
in `.env.example`. What makes the service what it is, the same on every server (its stores, the user
its commands run as, its mounts and capabilities), lives in the compose files and the Dockerfile.

- **One module per store.** Every database and every folder of user files has a module in the
  service, listed in `BACKUP_STORES`. The standard sets the module's interface, not a list of
  supported databases. A module makes a set of its store from one consistent state, and gives the
  facts a restored store must match (row counts, for example); it checks that a new set reads back;
  it restores a set into a temporary server of its own (the drill) and into the working store,
  comparing each result with those facts; and it names the working store (database name and host)
  that a person confirms a restore with. The template's `postgres` module is an example, not the
  only kind, and needs PostgreSQL 15 or later; the project writes the module of each of its other
  stores after it. The tool is the database's official one (`pg_dump`, `mongodump` and so on); which
  one and how to use it, the audit researches for the specific database and version
  ([`catalog/`](../catalog/README.md)). A set also holds what a dump cannot be restored without:
  the roles, without their passwords (those come from `.env`), and the database's own settings and
  privileges. The image is built from the project's image of the database, so the client, the
  drill's server and the working database have one version, and restic in it is pinned by digest.
- **Its own read-only role.** Dumps run as a read-only role of their own (`BACKUP_DB_USER` for the
  store `db`), never the superuser; the service creates it and keeps its rights up to date
  ([`catalog/`](../catalog/README.md)).
- **The application is not the superuser.** The application connects with a role of its own, which
  owns what its migrations create and has no superuser right. The superuser's password is used only
  by the database service and by `backup`, to create the backup role and to restore. Otherwise one
  SQL injection reaches the whole database server: `COPY` naming a file or a program is allowed to
  superusers and to the roles that grant it ([D-0010](../decisions/0010-backups.md)). How the
  template gives the application its role is in its `docs/how-to/operations.md`.
- **Where the data lives.** Every store keeps its data in a named volume declared in the compose
  file. Rebuilds, container replacement, `git clean` and deleting the clone leave it alone; only
  `docker compose down -v`, `docker volume rm` and `docker volume prune -a` delete it (and so does
  deleting Docker's own data: uninstalling Docker Desktop, resetting its disk image, or removing
  `/var/lib/docker` on a Linux host), and no `make` target runs them
  ([ENV-05](02-environments.md#env-05-make-targets-m)).
- **Checked sets.** Each set has a manifest: the checksum of each file and what the dump holds,
  read in the same snapshot as the dump. Every check and every restore compares with it, and a set
  that is not finished and checked never has a final name. A backup, a drill, a restore and a copy
  check never run at the same time.
- **The backup folder is advice, then the owner's choice.** On stage and prod the sets are in the
  host folder `BACKUP_DIR`, never in git or an image; in dev they are test sets in the named volume
  `backup-data`, which `docker compose --profile backup down -v` removes. The standard's advice for
  `BACKUP_DIR` is the template's default `docker/backup/data`. When the standard is applied, the
  owner chooses: that, the folder the agent advises after looking at the project (with its reason),
  or their own path; the answer goes into `.env` and the registry. One folder serves one
  environment of one project. The service takes a folder only when it is empty or missing, marked
  as its own, or holds only the sets an earlier release of the service made (it then marks it), and
  refuses any other, changing nothing. Inside the container the folder is always
  `/backup`; messages name the host variable.
- **Free space.** Before anything that writes a lot (a backup, a restore, a drill, and also a deploy,
  [ENV-09](02-environments.md#env-09-ship-deploy-and-roll-back-m-if-there-is-stage-or-prod), and
  the log archive of [OPS-03](#ops-03-logs-m)) the command reads the free space of the disk it
  writes to. If there is less than it needs, it says what it needs, what there is, what can go wrong if it
  goes on, and to free space. These checks are estimates, so the command asks and does not stop by
  itself: in a terminal it asks y/N; without one it refuses with the same explanation until
  `RISK=yes` is added on make's command line (like `CONFIRM`, never from the environment), which an
  agent does only after the owner's yes (AI-01). The backup service's own scheduled jobs have no
  one to ask and still refuse before writing. What is kept free on top of what a step needs is
  `DISK_RESERVE` in `.env`. A backup needs room for the new sets (about the size of the last ones),
  a restore also for its safety set and a set fetched from the copy, and a drill, which restores into a
  temporary server on a volume of Docker's data disk, for the size of the set. Because a failure for lack of
  space is usually noticed too late, the status service warns before
  ([OPS-04](#ops-04-health-monitoring-r-for-stage-and-prod)). On Docker Desktop the free space seen
  from inside Linux belongs to its virtual disk, not to the Windows drive under it (one-off
  measurement, 2026-10-21, [D-0010](../decisions/0010-backups.md)), so there the check protects
  only the virtual disk.
- **Schedule and rotation.** Daily at `BACKUP_TIME` (UTC) a set of every store, then the copy. A day
  missed while the service was down is made up when it starts. On this server, rotation keeps the
  newest set of each of the last `BACKUP_KEEP_DAILY` days and of each of the last
  `BACKUP_KEEP_WEEKLY` ISO weeks. Rotation of the off-server copy is not done from the server (see
  below). On a server deploy that runs a migration (not on a clone's first deploy, when nothing was
  deployed from it yet), a fresh set is made right before the migration step; if that backup, or
  only its off-server copy, fails, the command says which part and that the migration would run
  without a fresh set off the server, or anywhere when the local set failed, and asks as the free-space checks do.
- **Drill: restore check.** Weekly on `BACKUP_DRILL_DAY` after the backup, and through
  `make backup-drill`, the service restores the newest set (or the one named with `SET=`) into a
  temporary server of each store's type and version inside itself, compares it with the manifest
  and deletes it. A drill never touches the working databases.
- **Off-server copy: the server may only add.** Prod has one: an empty `BACKUP_COPY_TO` in prod is
  an audit finding, because a copy on the same disk does not survive that disk. Every checked set is
  also copied to a store outside the server, as a restic repository that restic encrypts with
  `BACKUP_COPY_PASSWORD`; that password is also kept in a safe place off the server, because
  without it the copy cannot be read. The server's credentials for the copy can add and read sets
  and can neither delete nor change one, so someone who breaks into prod cannot delete or change the
  sets already in the copy; the template's test proves that the server's login cannot `forget`
  them, and the rest is a one-off measurement ([D-0010](../decisions/0010-backups.md)). A copy into a local folder or over
  `rest:http://` is an audit finding in prod too, like an empty `BACKUP_COPY_TO`; the template accepts them for
  tests only. The copy is rotated by the storage side with credentials
  of its own, and its rotation keeps every set of a recent window (`--keep-within`), because
  someone with the server's credentials can add empty sets with any date, and a rotation that counts
  sets would then delete the real ones. The window is also the limit: restic counts only days and weeks
  that have a set, so many sets dated in the future can take the daily and weekly slots, and against
  a broken-into server only the sets of the last window are guaranteed; future-dated sets do not go
  away when the window passes, the storage side removes them. The server reads the copy back regularly (a random part of
  its data on `BACKUP_DRILL_DAY`), so a copy that no longer reads is known. Which store holds the
  copy is the project's choice: the template's example is a rest-server in append-only mode
  (`--append-only --private-repos`); SFTP with deletes denied is not write-only (restic needs
  rename and chmod, which can destroy a set), and another store needs its own setup and its own
  proof that the server cannot delete ([D-0010](../decisions/0010-backups.md)).
  `make backup-copy-check`, on a server, proves the setup (a test set written and read back, its
  deletion refused) and prints `OK` or the exact reason.
- **Health and notifications.** The `backup` healthcheck turns unhealthy when the newest set of a
  store, or its newest copy when `BACKUP_COPY_TO` is set, is older than `BACKUP_MAX_AGE`, or the
  last drill or read check of the copy failed; `make backup-status` says why. A deploy does not wait
  for it and only warns
  ([ENV-09](02-environments.md#env-09-ship-deploy-and-roll-back-m-if-there-is-stage-or-prod)).
  A failed backup, drill, restore, copy check or read check is also a one-line POST to
  `BACKUP_NOTIFY_URL` (R); an empty variable means no notifications.
- **Heartbeat.** After each daily run in which every step succeeded, the service sends one GET to
  `BACKUP_HEARTBEAT_URL`. Prod sets `BACKUP_HEARTBEAT_URL` to a monitor on another machine that
  alerts when the daily ping is missing (R): the healthcheck and the notifications run on the
  server itself, so they stay silent when the server, Docker or the service is down. Only this ping
  proves that the nightly job happened, so it stays when health monitoring
  ([OPS-04](#ops-04-health-monitoring-r-for-stage-and-prod)) is on.
- **Targets.** `make backup`, `make backup-list`, `make backup-drill`, `make backup-status`,
  `make backup-test` (dev; `make infra` ends with it), `make backup-copy-check` (server) and
  `make restore` ([ENV-05](02-environments.md#env-05-make-targets-m)). `S=<service>` limits a
  command to one store. `make restore [SET=<set>|latest|before-restore] [FROM=local|copy]
  [NO_SAFETY=1]` (`FROM=copy` on a server only) is the only command that replaces data. It first
  checks the set of every store (`latest` is the newest normal set all stores have) and shows what
  it would replace, and changes nothing until that check passes and it is confirmed. Confirmation:
  when the command's input is a terminal, the warning is red and the person types the name of each
  database it replaces; otherwise (an agent, a script) only `CONFIRM=yes` on make's command line
  confirms it. `CONFIRM`, `SET`, `FROM`, `S` and `NO_SAFETY` count only on the command line, never
  from the environment: an exported `CONFIRM=yes` confirms nothing. Before it replaces a store, a
  restore makes a safety set of it as it is now, `before-restore-<UTC time>`: an ordinary set, copied
  off the server like the others, of which there is at most one per store on the server (a
  new one replaces the old; before the first restore there is none). Rotation, `latest` and the
  weekly drill ignore it; `SET=before-restore` takes it, for a restore and for `make backup-drill`, and `NO_SAFETY=1` skips it, for a database that can no longer be dumped. On the
  storage side the last safety set and every one of the last seven days are kept. On a server the
  restore then stops the application side, so nothing writes during it, and compares the result with
  the manifest; `backup`, the status service and its socket proxy keep running (they write nothing
  of the application's, and the status service reports the stopped application as down); the
  application stays stopped until `make restart`. A new server gets its data with
  `make restore FROM=copy SET=latest NO_SAFETY=1` before its first `make stage` / `make prod` (a new
  database holds nothing to keep); on a server, `make restore` first builds the images of the
  checked-out commit that the server lacks.
- **Non-root.** The service starts as root only to give its backup folder and `/drill` to the
  database user, then drops to it; every command runs as that user without capabilities. For that
  start it adds back `CHOWN`, `SETUID` and `SETGID`, each shown to be needed (one-off run,
  2026-10-19). These are the template's sanctioned exceptions to
  [ENV-01](02-environments.md#env-01-shape-of-each-environment-m) and
  [ENV-03](02-environments.md#env-03-compose-rule-check-m-if-there-is-stage-or-prod) (the rules
  `user` and `cap_add`): the stage and prod files list both, with their reasons, in
  `x-check-compose-allow`, and they need no registry row.
- **Large databases** (physical backup plus WAL, for example pgBackRest or WAL-G) are outside the
  standard for now. They are added by a decision recorded in an ADR when a nightly dump becomes too
  large in some project.

### OPS-02. Tuning to resources (M where factory settings do not fit, R otherwise)

No stage or prod component (database, cache, web server, language runtime, the container itself)
stays on factory settings that do not fit the limits of its container. The standard sets where the
values live and how they are derived, checked and explained; which parameters a component needs,
and their values, the project decides for its components and versions and explains in
`docs/how-to/tuning.md` ([D-0011](../decisions/0011-tuning.md)). It applies to stage and prod. The level is M for a component
whose factory settings are known not to fit a container: it sizes itself by something other than
the container's limits (PostgreSQL's 128 MB of shared buffers, a pool of worker processes whose
count times their memory can exceed the limit). For any other component tuning is R: declining it
is recorded in the registry.
1. **The values live in `.env`.** The limits of every service (`<SERVICE>_CPUS`, `<SERVICE>_MEM`)
   and the numbers derived from them (for example `DB_MEM=1G` and `DB_SHARED_BUFFERS=256MB`) are
   variables in `.env`; nothing is computed when a container starts. The compose files pass each
   number by the component's own route, the same in stage and prod, so `parity` holds; fixed
   settings live in a file in `docker/<service>/`. PostgreSQL gets its numbers as `-c` flags in the
   `command:` of its service, because its config file does not read environment variables
   (`${X}` there is an invalid value; one-off run, 2026-10-20, PostgreSQL 16.15). Dev services have
   no limits apart from the heavy jobs of
   [ENV-01](02-environments.md#env-01-shape-of-each-environment-m) (the `mutation` service), and
   dev runs without the derived numbers.
2. **No swap beyond the limit.** Every stage and prod service with a memory limit has
   `memswap_limit` equal to it; without it Docker lets the container use as much swap again.
3. **Derived from the container, not the server.** Every number comes from the limits of its own
   container, never from the memory of the whole server. What the container's processes use
   together stays within its memory limit, `/dev/shm` and tmpfs included (they count toward it). A
   number of processes (PHP-FPM `pm.max_children`, any worker pool) comes from the memory of one
   process measured under load: the limit, less what the rest of the container uses, divided by
   the measured memory, with a margin; `tuning.md` records the measurement and its date.
4. **Researched, and the default where sources disagree.** Which parameters to tune and the rule
   for each, the audit researches for the specific component and its version in the official
   documentation (URL and quote). Where sources disagree on a value (for example
   `random_page_cost` for SSDs), the default stays until a measurement on the project shows a
   better one. [`catalog/`](../catalog/) is a starting point, not a complete list: a component
   researched for the first time is added there.
5. **Checked on the running services.** `make tuning-check` runs the project's
   `scripts/tuning-check.sh`, which asks the running services of this clone's environment
   (`PROJECT_ENV`) for their actual values, compares each with its value in `.env`, prints one line
   per parameter of `docs/how-to/tuning.md` and exits non-zero on any parameter that differs or a
   service that does not answer. It runs at the end of `make stage`, `make prod` and
   `make restart`, after the deploy is recorded: when it fails, the new containers already run, the
   history says so, and the command fails. Fix the value in `.env` and run `make restart`.
6. **Explained once.** Every parameter is explained in `docs/how-to/tuning.md`: what it is, why,
   how it is derived, how to change it, how to check it, the source. Its variable in
   `.env.example` has a one-line comment that points there. The template's `tuning.md` and
   `scripts/tuning-check.sh` already hold the method, the limits and the PostgreSQL rows
   ([`templates/`](../templates/README.md)).

### OPS-03. Logs (M)

- Every service writes to stdout and stderr, not to files inside the container. Docker rotates the
  logs (`json-file`, 10m×3) in every environment, dev included
  ([ENV-01](02-environments.md#env-01-shape-of-each-environment-m)).
- The log format is the same in every environment, so stage checks what prod will produce.
- The `LOG_LEVEL` variable in `.env` sets the level: dev and stage may use `debug`, prod uses
  `info` or higher. It is one of the differences stage and prod may have
  ([ENV-02](02-environments.md#env-02-stage--prod-parity-m-if-there-are-stage-and-prod)).
- Logs contain no secrets or tokens.
- **Logs of replaced containers are kept.** Docker removes a container's logs with the container,
  so a deploy would erase what was written just before a failure. Before `make stage`, `make prod`,
  `make rollback` or `make restart` replaces a container, its logs are saved as
  `<UTC time>-<service>.log` in the folder `LOG_ARCHIVE_DIR` of `.env` (empty: no archive). If they
  cannot be saved because the folder is not writable, nothing is replaced; too little space is an
  estimate, so the command warns and asks
  ([OPS-01](#ops-01-backups-m-if-the-project-has-data-worth-keeping)). The
  template's default is a folder in the clone; when the standard is applied the owner chooses the
  folder, and the answer goes into `.env` and the registry. Its files can be read by their owner only (and the folder the deploy creates). Nothing removes the old files: the
  folder grows until the owner clears it (cron, logrotate or by hand).

### OPS-04. Health monitoring (R for stage and prod)

Nobody learns that a service of a live server has failed unless something tells them. Docker
already knows: every service has a healthcheck, and Docker marks the container healthy or
unhealthy. This rule makes that state visible outside the server. A `status` service, built from
[`templates/project/docker/status/`](../templates/project/docker/status/), reports the health of
the containers of its own compose project and the free disk space as one JSON; an outside monitor
reads it or receives it. How to set it up, read it and test it is the project's
`docs/how-to/operations.md`, section "Monitoring". Declining the rule is recorded in the registry;
setting the standard up asks the owner whether they want health monitoring
([D-0027](../decisions/0027-health-monitoring.md)).

- **The healthchecks come first.** Every stage and prod service has one
  ([ENV-03](02-environments.md#env-03-compose-rule-check-m-if-there-is-stage-or-prod)). It proves
  that the service answers in its own protocol (a query, a `PING` that must return `PONG`, an HTTP
  request that must return 2xx), not that its process exists, and it fails on an error reply.
  Its output is short and safe: Docker keeps the last five results and the first 4096 bytes of each,
  `status` shows the output as it is, and a monitor may e-mail it, so it never holds a secret, a
  connection string or an environment dump. Its `timeout` is shorter than its `interval`; a slow
  starter gets `start_period` and `start_interval` rather than a long `interval`; its exit codes
  are 0 and 1 only. Tested checks for common images, with their pitfalls, are in the
  [catalog](../catalog/README.md#healthchecks).
- **The application's `/health`.** It checks what the application cannot serve without and that
  lives in the same project (its database, a cache it requires), each with a timeout below the
  healthcheck's, with no writes and no heavy queries. It answers `200` with `{"status": "pass"}`, or
  `503` with `{"status": "fail"}` and the failing checks listed, as `application/health+json`
  (the format of an expired IETF draft, the only one there is); never a secret or a stack trace.
  Optional and external dependencies (a payment API, mail) are listed in the body as `warn` with
  `200` and never fail the healthcheck: otherwise our deploy would wait on their outage.
- **One status service per project.** It asks Docker about the containers of its own compose
  project, so the environment tells itself apart and nothing is listed by hand: a new service with
  a healthcheck is watched at once. It reaches Docker only through the template's socket proxy,
  which forwards only reading the container list and the containers of this project by name and
  refuses everything else. That proxy is the template's sanctioned exception to the no `docker.sock`
  rule of [ENV-01](02-environments.md#env-01-shape-of-each-environment-m) and
  [ENV-03](02-environments.md#env-03-compose-rule-check-m-if-there-is-stage-or-prod): the stage and
  prod files list it in `x-check-compose-allow`, it runs as a user without root rights, and it needs
  no registry row. Why this proxy and this scope: [D-0027](../decisions/0027-health-monitoring.md).
- **One status for the monitor.** The JSON has the same shape in every project. Its `status` is
  `pass` (every service healthy, every disk healthy), `warn` (nothing failed, but a service is still
  `starting`, so a deploy pages nobody) or `fail` (a service unhealthy, stopped, gone or unknown, a
  disk below its threshold, or Docker unreadable). The fields and values are in the template's
  `docs/how-to/operations.md`.
- **Poll or push.** `GET /status` answers only with the token `STATUS_TOKEN` (`401` otherwise, also
  while failing) and is reached through the server's front proxy over TLS only. It answers `200` for
  `pass` and `warn` and `503` for `fail`, with the same body, so any monitor that polls HTTP sees a
  failure as down without special setup. For a monitor that waits for pings, every
  `STATUS_PUSH_INTERVAL` the same JSON is POSTed to `STATUS_PUSH_URL` while the status is `pass` or
  `warn`, and to `STATUS_PUSH_FAIL_URL` while it is `fail`. Two addresses, because a monitor counts
  every ping on one address as alive and decides failure by the address; they also keep the
  template free of any one product. An empty failure address sends nothing, and the monitor alerts
  on the silence; both empty means no push, and a monitor polls instead. Pushing is the only way
  for an environment without a public address, and polling the only way to see a broken front proxy,
  certificate or DNS, so prod also has an outside check of its public site (R).
- **One monitor per environment.** Not one per service: one incident is one alert, a new service is
  covered without setup, and free plans limit the number of monitors. The JSON names the failing
  service. The monitor runs on another machine, as the heartbeat of
  [OPS-01](#ops-01-backups-m-if-the-project-has-data-worth-keeping) does, and its period and grace
  cover a deploy, when `status` itself is recreated. When it is set up, one alarm drill proves that
  it really alerts, which the template's tests cannot: stop `status` on stage, see the alert, start
  it, see it clear.
- **Disk.** `status` reports the free space of the disk of Docker's data and of the backup folder; a
  disk below `DISK_WARN` (a percentage or a size, never less than `DISK_RESERVE`) is `fail`, so the
  alarm comes before a deploy or a backup refuses for lack of space
  ([OPS-01](#ops-01-backups-m-if-the-project-has-data-worth-keeping)). A deploy needs twice the
  own images plus `DISK_RESERVE`, so `DISK_WARN` is set above that sum to be warned first; `status`
  does not compute it. On Docker Desktop the reading is indicative only (one-off measurement,
  2026-10-21, [D-0027](../decisions/0027-health-monitoring.md)).
- **Not covered.** The CPU and memory use of containers needs another tool (cAdvisor, for example);
  it is not part of this rule.
