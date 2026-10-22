# Backups

<!-- project template 1.0.0 — a starting point (standard OPS-01, DOC-01): fill in the names; add a section per store the project adds. -->

How the backup works, how to set up and check the off-server copy, how to check a restore and how
to restore. The commands run in the clone of the environment (dev, or the server's clone).

## Where the settings are

- **`.env`**: what may differ between servers, each with its comment in `.env.example`: the
  folder of the sets (`BACKUP_DIR`), the time and the rotation (`BACKUP_TIME`,
  `BACKUP_KEEP_DAILY`, `BACKUP_KEEP_WEEKLY`, `BACKUP_DRILL_DAY`, `BACKUP_MAX_AGE`), the
  off-server copy (`BACKUP_COPY_TO`, `BACKUP_COPY_PASSWORD`, `BACKUP_COPY_LOGIN`,
  `BACKUP_COPY_LOGIN_PASSWORD`, `BACKUP_COPY_CACERT`, `BACKUP_COPY_READ`), the alerts
  (`BACKUP_NOTIFY_URL`, `BACKUP_HEARTBEAT_URL`), the backup role (`BACKUP_DB_USER`,
  `BACKUP_DB_PASSWORD`), the free space kept (`DISK_RESERVE`) and the limits (`BACKUP_CPUS`,
  `BACKUP_MEM`).
- **The compose files**: what the service is, the same on every server: the stores
  (`BACKUP_STORES`), the host name the copy lists the sets under (`<repo>-backup-<env>`), the
  mounts and the capabilities.
- **`docker/backup/Dockerfile`**: the base image (the database's own), restic, and the user every
  command runs as (`ENV BACKUP_USER`).
- **Fixed in the service**: the sets are always at `/backup` inside the container and the drill
  runs at `/drill`; the messages name `BACKUP_DIR`, the host folder behind `/backup`.

## How it works

One `backup` service (`docker/backup/`) backs up every store: <the stores, for example "the
Postgres database `db`">. In stage and prod it always runs; in dev it has the `backup` profile and
runs only for a command.

- **Stores.** `BACKUP_STORES` in the compose files lists them as `<compose service>:<module>`, for
  example `db:postgres`. A module is `docker/backup/<module>.sh`; it makes, checks, drills and
  restores its store ("Writing a module for another store" below). The settings of a store `<s>`
  are `BACKUP_<S>_<NAME>`: for `db`, `BACKUP_DB_USER` and `BACKUP_DB_PASSWORD`. `postgres.sh` is
  an example module and needs PostgreSQL 15 or later (it passes the backup role's password with
  psql's `\getenv`, 15+, and grants `pg_read_all_data`, 14+).
- **Daily** at `BACKUP_TIME` (UTC) it makes a set of every store, copies it off the server (when
  `BACKUP_COPY_TO` is set) and rotates the old local sets. On `BACKUP_DRILL_DAY` it also runs a
  restore drill and a read check of the copy. A day the service was down, or a daily run stopped
  halfway, is made up when it starts again; stage and prod give a running job two minutes to finish
  when the service stops (`stop_grace_period`).
- **A set** is `<the backup folder>/<service>/<UTC time>/`, for example
  `docker/backup/data/db/20261019T030000Z/`: `globals.sql` (the roles, without passwords:
  `pg_dumpall --globals-only --no-role-passwords`), `database.dump` (the database with its
  settings and privileges: `pg_dump -Fc --create`) and `manifest` (the checksum of each file; the
  row count of every table, the number of large objects, the roles and the settings, all read in
  the same snapshot as the dump). `globals.sql` cannot be read in that snapshot, so it is dumped
  after it and the roles are compared: when one changed meanwhile, the set is made once more. A set
  is written under a temporary name (`.tmp-<name>`), checked (the checksums, and
  `pg_restore --list` reads the dump), and only then renamed: a folder without the `.tmp-` prefix
  is a finished, checked set. The next backup removes what an interrupted one left.
- **The safety set** `before-restore-<UTC time>` is a set like any other, which `make restore`
  makes of every store it replaces, just before it replaces it ("Restore" below). There is at
  most one per store: a new one replaces the old one. Rotation neither counts nor removes it, and
  neither `latest` nor the weekly drill takes it; only `SET=before-restore` or its full name
  takes it, for `make restore` and for `make backup-drill`. It is copied off the server like the other sets, tagged `before-restore`.
- **The backup folder.** On stage and prod it is the host folder `BACKUP_DIR` (by default
  `docker/backup/data`, which `.gitignore` and `.dockerignore` list); in dev the sets are test sets
  in the named volume `backup-data`, which goes when the dev stack's volumes are removed
  (`docker compose -f docker-compose.dev.yml --profile backup down -v`, which also removes the dev
  database; without `--profile backup` the volume stays). The folder is one environment's own:
  the service takes it only when it is missing or empty, or holds only what an earlier release of
  the service left (`.state` and the store folders of sets, all of the service's user), then marks it with the file
  `.backup-folder` (which names the service's host name, for example `<repo>-backup-prod`), and
  refuses, changing nothing, a folder that holds anything else or the mark of another
  environment. Give each environment of each project a folder of its own.
- **The read-only role** `BACKUP_DB_USER` makes the dumps. It is its own role, never the superuser
  or `BACKUP_DB_ADMIN_USER`, and never a role that owns a database or tables (the application's
  role): the backup refuses each, because it sets this role's password. The
  service creates the role with the superuser before each backup and keeps its rights
  (`pg_read_all_data`, `BYPASSRLS` when a table uses row-level security, `SELECT` on every large
  object); its password is `BACKUP_DB_PASSWORD`. The superuser (`DB_PASSWORD`) is used for that and
  for a restore.
- **Rotation** keeps the newest set of each of the last `BACKUP_KEEP_DAILY` days and of each of
  the last `BACKUP_KEEP_WEEKLY` ISO weeks, on this server. A second `make backup` on the same day
  replaces that day's set. The off-server copy is rotated by the storage side, never from here
  ("Rotate the copy on the storage side" below).
- **Free space.** Before a backup and before a restore the service reads the free space where the
  sets are written (`df -Pk /backup`, the same as `df -Pk "$BACKUP_DIR"` on the host) and, before it
  writes anything, finds when there is less than it needs. That is an estimate: `make backup`,
  `make backup-drill` and `make restore` say what they found and what can go wrong and ask (in a
  terminal `Go on anyway? [y/N]`; without one `RISK=yes` on the command line of that `make`, which
  an agent adds only after the owner's yes), while the daily and weekly jobs of the service refuse
  and notify, since no one is there to ask:
  `not enough free space for the backup in the backup folder (…): need <X> (<Y> for the new sets, the size of the last ones, and DISK_RESERVE=<R>), have <Z>`.
  A new set of a store takes about what its last set took, since it is a dump of the same store a
  day later, so the need is the size of the last set of every store it backs up (a restore: one
  for the safety set, and one more for a set fetched from the copy), plus `DISK_RESERVE` for growth
  and for everything else on that disk. The first set has no size to go by: `DISK_RESERVE` alone.
  Before a drill (`make backup-drill`, the weekly one, `make backup-test`) it reads the free space
  of `/drill`, the volume `backup-drill`, the same way: the restored store takes at least what its
  set takes, so the need is the size of the set plus `DISK_RESERVE`, and with less the drill
  finds it before it writes anything there; `make backup-drill` asks as above, the weekly drill and
  `make backup-test` fail:
  `not enough free space for the drill in /drill (the volume backup-drill): need <X> (<Y> for the set, its size, and DISK_RESERVE=<R>), have <Z>`.
  On Docker Desktop the Linux disk does not show the host drive's free space; there the check
  protects only the virtual disk.
- **The user.** Every command runs as `BACKUP_USER`, the database user of the base image
  (`ENV BACKUP_USER=postgres` in `docker/backup/Dockerfile`, not in `.env`; uid <70 in the Alpine
  image, 999 in the Debian one>). The service starts as root only to give the backup folder (when
  it is empty or marked as the service's) and `/drill` to that user: `BACKUP_DIR` is a bind mount,
  and Docker creates a missing host folder as root (`0:0`, mode 755). Then it drops to that user
  with `gosu`; the capabilities `CHOWN`, `SETUID` and `SETGID` serve only this start, and the stage
  and prod files list them, with their reasons, in `x-check-compose-allow`. The folder gets mode
  700, the files 600: on a server, read them with `sudo` or in a shell of that user,
  `docker compose -f docker-compose.<env>.yml exec -u postgres backup sh` (`-u` names
  `BACKUP_USER`, `postgres` by default; the default root shell has no right to read them).
- **Health**: the service turns unhealthy when the newest set, or the newest copy when
  `BACKUP_COPY_TO` is set, is older than `BACKUP_MAX_AGE`, when the last drill failed, or when the
  last read check of the copy failed. `make status` shows it, and `make backup-status` says why,
  then lists the newest set of every store, the safety set, the newest copy, the last result of
  every job (backup, drill, copy-verify, copy-check, restore) and the free space. Until the
  first set or copy exists, the age counts from the start of the service. A deploy does not wait
  for the service: `make stage`, `make prod`, `make restart` and `make rollback` print
  `WARNING: backup unhealthy: <reason> (docs/how-to/backups.md)`, and the release runs.
- **Notifications**: every failed backup, drill, read check of the copy, restore or copy check is
  also a one-line POST to `BACKUP_NOTIFY_URL`, when it is set. That needs `curl` or `wget` in the
  image: the Alpine Postgres images have `wget`, the Debian ones have neither (add
  `RUN apt-get update && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/*`
  to the `base` stage). A refused `make restore` (not confirmed) is not a failure and sends
  nothing.
- **Heartbeat**: after each daily run in which every step succeeded, one GET to
  `BACKUP_HEARTBEAT_URL`, when it is set; a monitor on another machine alerts when it is missing
  ("Heartbeat" below).

## Commands

`S=<service>` takes one store (for example `S=db`) where the table says so; without it, every
store of `BACKUP_STORES`. `S=`, `SET=`, `FROM=`, `NO_SAFETY=` and `CONFIRM=` count only on make's
command line, never from a variable of the environment: a `CONFIRM=yes` exported in a shell
confirms nothing. GNU make also reads such values from an exported `MAKEFLAGS` or `GNUMAKEFLAGS`,
or from a make that runs this one; `S=`, `SET=`, `FROM=` and `NO_SAFETY=` are taken from there
too, but `CONFIRM=yes` is taken only when it is on the command line of the `make restore` itself
(read with `ps`).

| Command | Where | What it does |
|---|---|---|
| `make backup [S=…]` | any | a set of every store (or of one) now, then the copy and rotation |
| `make backup-list [S=…] [FROM=copy]` | any (`FROM=copy`: server) | the sets of every store: name, time (UTC), size, kind (`normal` or `before-restore`), where (`local`, `local, copied`); `FROM=copy` lists the sets in the copy; the names are what `SET=` takes |
| `make backup-drill [S=…] [SET=…]` | any | restores the newest normal set (or `SET=`) into a temporary database inside the service and compares it with the manifest; the working database is not touched; `make restore-drill` is its old name |
| `make backup-copy-check` | server | proves the copy: writes a small test set, reads it back, compares, and checks that deleting it is refused; then the read check of the copy; `OK` or the reason |
| `make backup-status` | any | on a server first whether the service runs (`backup-status: the backup service runs (healthy)`); then the health line and why, the newest sets, the last result of every job, the free space |
| `make backup-test [S=…]` | dev | a set of the seed database (or of one store), a drill on it, then the set is deleted; `make infra` ends with it (so `make verify` runs it too) |
| `make restore [S=…] [SET=…] [FROM=…] [NO_SAFETY=1]` | any (`FROM=copy`: server) | the one command that replaces data: after a confirmation, a safety set, then the set into the working database (below) |

Dev has no off-server copy, so there `make backup-copy-check`, `make backup-list FROM=copy` and
`make restore FROM=copy` refuse.

## Set up the off-server copy

A copy on the same disk does not survive that disk, so prod always has one. It must also survive
someone who breaks into this server, so the server may only add to it: its login can write new
sets and read them, and cannot delete or change a set. Rotation is the storage side's job, with a
login of its own. The copy is a [restic](https://restic.readthedocs.io/) repository, encrypted
with `BACKUP_COPY_PASSWORD`. The template's example is
[rest-server](https://github.com/restic/rest-server) 0.14.0 with `--append-only --private-repos`:
the template's test shows that the server's login can add and read sets, and that `forget` (also
with `--prune`) gets `403 Forbidden` and removes nothing; rest-server refuses every delete or
overwrite of an existing file but a lock. An SFTP login with deletes
denied is not write-only (restic needs rename and chmod, which can destroy a set), so the template
does not use it. Another store (object storage with keys that cannot delete, for example) needs
its own setup in `docker/backup/copy.sh` and its own proof that the server cannot delete.

1. On the storage machine (never this server), run two rest-server instances on one data folder:
   one for the servers, append-only, and one for the rotation, with full access. Each has its own
   htpasswd file, outside the data folder:

   ```sh
   docker run --rm -it --entrypoint htpasswd restic/rest-server:0.14.0@sha256:d2aff06f47eb38637dff580c3e6bce4af98f386c396a25d32eb6727ec96214a5 \
     -B -n <project>-prod
   docker run --rm -it --entrypoint htpasswd restic/rest-server:0.14.0@sha256:d2aff06f47eb38637dff580c3e6bce4af98f386c396a25d32eb6727ec96214a5 \
     -B -n admin
   docker run -d --name rest-servers --restart unless-stopped -p 8000:8000 \
     -v /srv/rest/data:/data -v /srv/rest/servers.htpasswd:/htpasswd:ro -v /srv/rest/tls:/tls:ro \
     -e OPTIONS="--append-only --private-repos --htpasswd-file /htpasswd --tls --tls-cert /tls/cert.pem --tls-key /tls/key.pem" \
     restic/rest-server:0.14.0@sha256:d2aff06f47eb38637dff580c3e6bce4af98f386c396a25d32eb6727ec96214a5
   docker run -d --name rest-admin --restart unless-stopped -p 127.0.0.1:8001:8000 \
     -v /srv/rest/data:/data -v /srv/rest/admin.htpasswd:/htpasswd:ro \
     -e OPTIONS="--htpasswd-file /htpasswd" \
     restic/rest-server:0.14.0@sha256:d2aff06f47eb38637dff580c3e6bce4af98f386c396a25d32eb6727ec96214a5
   ```

   Each `htpasswd` command asks for the password (so it stays out of the shell history) and prints
   one `<login>:<hash>` line: put the first in `/srv/rest/servers.htpasswd` and the second in
   `/srv/rest/admin.htpasswd`. The certificate and key are in `/srv/rest/tls`; the instance the
   servers reach needs TLS on the internet (a proxy with one in front also works: publish the port
   as `-p 127.0.0.1:8000:8000` and use the proxy's address in step 2). The template's test does not
   cover TLS.
2. Set `BACKUP_COPY_TO=rest:https://<host>:8000/<login>/`, one login and one repository per
   environment: with `--private-repos` a login reaches only the path that starts with its name.
   Set `BACKUP_COPY_LOGIN` and `BACKUP_COPY_LOGIN_PASSWORD` to that login (the password in place
   of the `none` of `.env.example`, which a server without a copy keeps); they never go into the
   URL, which the messages show.
3. Set `BACKUP_COPY_PASSWORD` to a long random value of letters and digits (`openssl rand -hex 32`)
   and keep it in a safe place outside the server as well: without it the copy cannot be read.
4. A certificate of your own (not from a public authority): copy it to this server, give it to
   `BACKUP_USER` (`sudo chown <uid>:<gid> <file> && sudo chmod 600 <file>`, the uid and gid of that
   user in the image) and set `BACKUP_COPY_CACERT` to its path; the service mounts it read-only
   and restic trusts it. A public certificate needs nothing (`/dev/null`).
5. Apply the `.env` change (`make restart`), then `make backup-copy-check`. On first use it
   creates the repository (`restic init`) and prints
   `copy-check: the test set <id> was written and read back`,
   `copy-check: deleting it was refused: the copy is write-only for this server`, the read check
   and `OK`, or the reason: an empty login, a login in the URL, the rest-server refused the login,
   it cannot be reached, its certificate is not trusted, a wrong password, the repository is
   missing and cannot be created, or `the login BACKUP_COPY_LOGIN could delete the test set` (the
   instance is not append-only). The test set stays in the copy, tagged `copy-check`.

Each set is stored with `restic backup --tag <service>` (a safety set with
`--tag <service>,before-restore`) and the set's own time, under the service's static host name
`<repo>-backup-<env>`. The service never runs `forget`, `prune` or any other command that removes
or rewrites a snapshot. A refused delete can leave a restic lock behind; the copy check removes its
own (`restic unlock`, which removes only stale locks of this host).

**The read check** (the job `copy-verify`; `copy-check` is the proof of `make backup-copy-check`). On `BACKUP_DRILL_DAY`, and in `make backup-copy-check`, the service runs
`restic check --read-data-subset <BACKUP_COPY_READ>` on the copy (default `10%`: a random tenth of
the data each time; `0`: the structure only). A failure is notified, turns the service unhealthy
until a check passes, and `make backup-status` shows it.

## Rotate the copy on the storage side

On the storage machine, with the full-access instance (or restic on the data folder itself), daily
at a time the servers do not write, for example twelve hours after `BACKUP_TIME`. The repository
password is needed, so whoever rotates can also read the copy:

```sh
export RESTIC_REPOSITORY=rest:http://127.0.0.1:8001/<login>/ RESTIC_PASSWORD='<BACKUP_COPY_PASSWORD>'
export RESTIC_REST_USERNAME=admin RESTIC_REST_PASSWORD='<the admin password>'
restic forget --group-by host,tags --keep-daily <BACKUP_KEEP_DAILY> --keep-weekly <BACKUP_KEEP_WEEKLY> \
  --keep-within 7d --keep-tag before-restore
restic forget --tag before-restore --group-by host,tags --keep-last 1 --keep-within 7d
restic prune
```

The first command keeps the same sets as the local rotation, groups by host and tags because every
set has its own path (the standard's catalog/README.md, source [11]), and leaves the safety sets to the second, which keeps the
newest safety set. `--keep-within 7d` keeps every set of the last seven days, in both: a
broken-into server can add empty sets with any date, and without it the rotation would keep those
and delete the real ones (restic's own advice for append-only repositories; the template's test
adds such sets and checks that the real ones stay). So the copy holds the newest safety set and
every safety set of the last seven days. The `copy-check` test sets rotate in their own group.

The window is also the limit. restic counts only days and weeks that have a set, so many sets that
someone with the server's credentials dates in the future can take the daily and weekly slots;
against a broken-into server only the sets of the last `--keep-within` window are guaranteed.
Future-dated sets do not go away when the window passes: the storage side removes them.

## Heartbeat

The healthcheck and the notifications run on this server: when the server, Docker or the `backup`
service is down, nothing reports it. The heartbeat (a dead man's switch) turns this around. After
each daily run in which every step succeeded (the set of every store, the copy when
`BACKUP_COPY_TO` is set, the drill and the read check of the copy on `BACKUP_DRILL_DAY`), the
service sends one GET to `BACKUP_HEARTBEAT_URL`, and logs `heartbeat: sent`. A monitor outside the
project and outside this server expects that ping every day and alerts when it is missing. A run
with a failure sends no ping (the failure still goes to `BACKUP_NOTIFY_URL`); `make backup` and
the other commands send none, only the daily run does. A ping that fails logs
`WARNING: the heartbeat to BACKUP_HEARTBEAT_URL failed` and the run goes on. Like the
notifications, it needs `curl` or `wget` in the image ("Notifications" above).

1. Choose the monitor; never host it on this server, which cannot report its own death. Two
   examples:
   - [Healthchecks.io](https://healthchecks.io/docs/), hosted or self-hosted (open source): a
     check with a simple schedule, **Period** 1 day and **Grace Time** 2 hours. The check URL is
     `https://hc-ping.com/<uuid>`; on a self-hosted instance, `<its address>/ping/<uuid>`.
   - [Uptime Kuma](https://github.com/louislam/uptime-kuma), self-hosted: a monitor of type
     **Push** with **Heartbeat Interval** 86400 seconds, and **Retries** 1 with **Heartbeat Retry
     Interval** 7200 seconds as the 2-hour grace. The push URL is the one the monitor shows,
     `https://<its address>/api/push/<token>?status=up&msg=OK&ping=`.
2. Set where the alerts go in the monitor itself, one channel or several: in Healthchecks.io the
   check's integrations (e-mail, Slack, Telegram and more), in Uptime Kuma the monitor's
   notifications (e-mail over SMTP, Telegram, Slack and more). Send a test alert from there.
3. Set `BACKUP_HEARTBEAT_URL` to that URL in `.env` (it is not in git: whoever has it can ping),
   then `make restart`. The first ping comes with the next daily run at `BACKUP_TIME`;
   `make logs S=backup` shows `heartbeat: sent`.

## Check a restore

`make backup-drill` at any time (`SET=<name>` for an older set, `S=<service>` for one store); the
service drills the newest set of every store by itself every week. A drill starts a temporary
Postgres of the same version inside the service, reachable only through a socket inside the
container, restores the roles and the dump there, compares every row count with the manifest and
deletes everything. That server runs on the `backup-drill` volume at `/drill`, not in memory,
because the database may be larger than the memory. A failed drill makes the service unhealthy
until a drill of the newest sets passes again.

## Restore

A restore replaces the working database with a set: everything written after that set is lost,
except in the safety set.

1. Choose the set: `make backup-list` names them. `latest`, the default, is the newest normal set
   that every store has; `SET=<name>` names one, for example `SET=20261019T030000Z`;
   `SET=before-restore` is the safety set of the last restore. `FROM=copy` takes the set from the
   off-server copy (on a server only; `make backup-list FROM=copy` names those); a restore only
   opens the repository at `BACKUP_COPY_TO` and never creates one. `S=<service>` restores one
   store.
2. `make restore` with the same `SET=`, `FROM=` and `S=` first checks, and changes nothing until
   the check passes: it finds the set of every store, checks the checksums of the local sets and
   the free space, then shows what it would replace, for each store:
   `restore: db: replaces the database <name> on <host> with the local set <set> of <time> UTC; what was written after that set is lost`
   and `restore: db: first a safety set before-restore-<now> of it as it is now` (or
   `no safety set (NO_SAFETY=1)`); in red when it runs in a terminal. Then the confirmation;
   without it nothing is replaced:
   - when its input is a terminal (a person at the keyboard) it asks, for every database it
     replaces,
     `restore: to replace the database <name> on <host> (db), type its name:`; anything but that
     name stops it (`you typed '<answer>', not <name>: nothing was replaced`). `CONFIRM=yes` does
     not stand for the name there.
   - when its input is not a terminal (an agent, a script, `< /dev/null`) only `CONFIRM=yes` on
     the command line of that `make restore` confirms it; without it the service refuses:
     `restore replaces the working database <name> on <host>: run again with CONFIRM=yes`.
3. On a server it then stops every service that runs except `backup` (and `status` with its
   socket proxy, which keep running and report the application as down), so nothing writes
   meanwhile, and names them (for example `restore: stopping app db for the restore`); then it
   starts only `backup` and the stores it depends on; in dev the dev container stays up. Inside
   the service the set of every store is found and checked (with `FROM=copy`, fetched and checked)
   before anything changes. Then the safety set of every store is made
   (`backup: db/before-restore-<time> OK (…)`), and the older safety set removed; when it cannot
   be made, nothing is replaced. Then the restore closes every connection left to the database,
   restores the roles (without passwords: the backup role gets its password from `.env` at the
   next backup, <the application's own roles: how they get theirs>), drops and creates the
   database from the dump, and compares the result with the manifest:
   `restore: db OK: equal to the manifest of <set>` means every row count matches. With a copy,
   the safety set goes off the server at once (when that fails, the next backup copies it). On a
   server it ends, whether it succeeded or failed, with
   `restore: the application is stopped: make restart starts it again` (on a server with no
   deploy recorded yet: `… make stage starts it again` or `… make prod starts it again`).
4. Start the application again with the command that line names (in dev: `make dev`).

If the restore stops halfway, the database may be missing or incomplete, and the application stays
stopped: run the same command again with `NO_SAFETY=1`. The safety set of the first attempt still
holds the state before it; a new one would hold the broken state and remove it. If the restored set
was the wrong one,
`make restore SET=before-restore` returns to the state just before it. `NO_SAFETY=1` skips the
safety set: for a database that cannot be dumped any more, or when the state before is not worth
keeping.

## A new server from the off-server copy

Set the new server up as [the server runbook](operations.md) describes up to the first start, with
the same `BACKUP_COPY_TO`, `BACKUP_COPY_PASSWORD`, `BACKUP_COPY_LOGIN`,
`BACKUP_COPY_LOGIN_PASSWORD` and `PROJECT_ENV` as the old one (the copy lists its sets under the
host name `<repo>-backup-<env>`), an empty or missing `BACKUP_DIR`, and the certificate file if the
storage side uses its own. Then `make restore FROM=copy SET=latest NO_SAFETY=1` before the
application starts (a new database holds nothing to keep); it builds the images of the
checked-out commit first.

## Writing a module for another store

`docker/backup/postgres.sh` is an example, not the only kind: every store of the project (another
database, a folder of user files) gets a module of its own, `docker/backup/<module>.sh`, listed in
`BACKUP_STORES` as `<service>:<module>`, and its client and server go into the `base` stage of
`docker/backup/Dockerfile`, in the store's own version. The module defines five functions; each
fails with `|| die "<why>"` on every command that can fail (a job's subshell does not stop on
errors by itself):

| Function | Does |
|---|---|
| `<module>_backup <store> <dir>` | writes the store's files into `<dir>`, read in one consistent state, and the facts the restored store must match into `<dir>/facts`, one per line (`rows <table> <count>`, for example); the service adds the checksums and makes them the manifest |
| `<module>_check <store> <dir>` | checks that the files of a new set can be read back (`pg_restore --list` in the example) |
| `<module>_drill <store> <dir>` | restores the set into a temporary server under `/drill/<store>`, compares its facts with the manifest (`compare_facts`) and removes the server |
| `<module>_restore <store> <dir>` | restores the set into the working store, then compares its facts with the manifest |
| `<module>_describe <store>` | prints two lines: the name of the working store that a person confirms a restore with (a database name), and where it is (its host) |

The settings of the store come from `store_var <store> <NAME>` (`BACKUP_<STORE>_<NAME>`). The
module's proof: `make backup-test` in dev, then on the server `make backup`, `make backup-drill`,
and a restore into an empty store with `make restore`, comparing the result with the store's own
counts.

## When something fails

| What you see | What it means | What to do |
|---|---|---|
| `WARNING: backup unhealthy: <reason> (docs/how-to/backups.md)` after a deploy | the release runs; the backups need attention | the reason is one of the `unhealthy:` lines below; `make backup-status` shows more |
| `unhealthy: the newest set of db was made … ago (BACKUP_MAX_AGE=…)`, or `there is no set of db yet, and the service started … ago` | no backup succeeded within `BACKUP_MAX_AGE` | `make logs S=backup` shows the error of the daily run; fix it, then `make backup` |
| `unhealthy: the newest copy of db was made … ago` | the off-server copy failed | `make backup-copy-check` names the reason |
| `unhealthy: the last drill failed: …` | a set did not restore, or differs from its manifest | read the reason; `make backup`, then `make backup-drill` |
| `unhealthy: the last check of the copy failed: …` | the copy did not read back: the storage disk changed or lost data | check the storage machine; `make backup-copy-check` checks again; meanwhile the local sets are the only good ones |
| `the backup folder (BACKUP_DIR on the host; in dev the volume backup-data) holds files the service did not make (…)` | `BACKUP_DIR` names a folder that holds other files; nothing was changed | set `BACKUP_DIR` to an empty or missing folder of its own, then `make restart` |
| `the backup folder (…) belongs to the backup service of <host>, not of <this host>` | the folder is another environment's (its `.backup-folder` names another host) | give each environment a folder of its own; after renaming the project, edit the `host` line of `.backup-folder` |
| `the backup folder (…) belongs to uid <u> and cannot be read` | the folder is another user's and closed | an empty folder of its own, or `sudo chown <uid>:<gid>` of an empty one |
| `not enough free space for the <backup or restore> in the backup folder (…): need <X> (<Y> for the new sets, the size of the last ones, and DISK_RESERVE=<R>), have <Z>` | the disk of `BACKUP_DIR` lacks room for the new sets (for a restore: the safety set, and a set fetched from the copy) plus `DISK_RESERVE` ("Free space" above); the service wrote nothing, and a restore replaced nothing; a manual command asked first (`Go on anyway? [y/N]`, or `RISK=yes` without a terminal), the scheduled job refused | free space on that disk: `docker system df` shows what takes it (old images, the build cache: `docker builder prune --filter until=720h`, the log archive); fewer local sets: lower `BACKUP_KEEP_*`; then the same command; to go on anyway, `y` or `RISK=yes`. Never delete volumes |
| `the drill of db failed: not enough free space for the drill in /drill (the volume backup-drill): need <X> (<Y> for the set, its size, and DISK_RESERVE=<R>), have <Z>` | the disk of Docker's volumes lacks room for the drill's server: the set's size plus `DISK_RESERVE`; nothing was written to `/drill`. The weekly drill and `make backup-test` fail with it (the weekly one is notified and makes the service unhealthy); `make backup-drill` asks first, as for the backup folder | free space on that disk (`docker system df`: old images, the build cache; never delete volumes), then `make backup-drill`; or go on (`y`, or `RISK=yes` without a terminal) |
| `DISK_RESERVE is '…', not a size like 2G or 500M`, `BACKUP_COPY_READ is '…', not a percentage like 10% (or 0: the structure only)` | a setting in `.env` is malformed | fix it, then `make restart` |
| `… the checksum does not match the manifest, so the set is damaged` | the disk changed a file of the set | the disk is suspect; check it, use an older set or the copy |
| `db: BACKUP_DB_USER <role> is a superuser: the backup needs its own read-only role`, `db: BACKUP_DB_USER must not be BACKUP_DB_ADMIN_USER` | the backup role in `.env` is the superuser | set `BACKUP_DB_USER` to a role of its own (`backup` in `.env.example`), then `make restart` |
| `db: BACKUP_DB_USER <role> owns database objects: the backup needs its own read-only role` | the backup role in `.env` owns a database or tables, as the application's role does; nothing was changed | set `BACKUP_DB_USER` to a role of its own (`backup` in `.env.example`), then `make restart` |
| `db: the roles or role settings changed during the backup twice: back up again later` | roles were being changed while the backup ran | `make backup` once the change is done |
| `no repository at <BACKUP_COPY_TO> (BACKUP_COPY_TO): nothing to restore from` | `make restore FROM=copy` found no restic repository there (a mistyped `BACKUP_COPY_TO`, or the wrong environment); nothing was created | set `BACKUP_COPY_TO` to the repository the copy was made in, `make restart`, then the same restore |
| `wrong password for the repository …` | `BACKUP_COPY_PASSWORD` is not the one it was created with | set the right one from your safe place |
| `the rest-server refused the login BACKUP_COPY_LOGIN: …` | a wrong login or password (also `BACKUP_COPY_LOGIN_PASSWORD` still `none`, the value of `.env.example`), or a path in `BACKUP_COPY_TO` that does not start with `/<login>/` | check the three against the storage side's htpasswd, then `make backup-copy-check` |
| `the rest-server cannot be reached: dial tcp …` | no server at the host and port of `BACKUP_COPY_TO`; restic retries for some minutes first | check the address and that the server is up and reachable from this server |
| `the rest-server's certificate is not trusted: …` | a certificate of its own, and `BACKUP_COPY_CACERT` does not name it | step 4 of "Set up the off-server copy" |
| `BACKUP_COPY_TO holds a login: …`, `BACKUP_COPY_LOGIN or BACKUP_COPY_LOGIN_PASSWORD is empty: …` | the login is in the URL, or `BACKUP_COPY_LOGIN` is empty (the password cannot be: the stage and prod files require it, and without a copy it stays `none`) | step 2 of "Set up the off-server copy" |
| `required variable BACKUP_COPY_LOGIN_PASSWORD is missing a value` | `.env` lacks it or leaves it empty, also on a server without a copy | `none` when there is no copy, else the password of the login (step 2 of "Set up the off-server copy") |
| `BACKUP_COPY_TO is '…': the template copies to a rest-server …` | another kind of store, for example `sftp:` | a rest-server, or that store's own setup and proof in `docker/backup/copy.sh` |
| `the login BACKUP_COPY_LOGIN could delete the test set: the copy must be write-only for this server …` | the instance this server writes to is not append-only (or the login is the storage side's) | give this server a login on the `--append-only` instance |
| `the certificate file is not readable by the backup user (uid <u>): sudo chown <u>:<g> <path> && sudo chmod 600 <path>` | the file on the host belongs to another user | run the printed command, then `make backup-copy-check` |
| `make backup-copy-check runs only on a server: dev has no off-server copy`, `make backup-list FROM=copy runs only on a server: …`, `make restore FROM=copy runs only on a server: …` | dev has no copy | run it in the server's clone |
| `make backup-test runs only in dev; on a server make backup-drill checks the sets` | `make backup-test` in a server clone | `make backup-drill` |
| `no local set of db (the sets: …)` | no normal set exists yet | `make backup` (with `FROM=copy`: check `BACKUP_COPY_TO` and that this is the right environment) |
| `no local set db/<name> (the sets: …)` (or `no copy set …`), `no local safety set before-restore-… of db`, `--set is '…', not latest, before-restore or a set name like 20261019T030000Z` | `SET=` names no set of that store | take a name from `make backup-list` |
| `the drill of db failed: no set db/<name> to drill (the sets: …)` | `SET=` of `make backup-drill` names no set | take a name from `make backup-list` |
| `--store is '…', not a store of BACKUP_STORES (…)` | `S=` names no store | one of the names it lists |
| `the stores have no common newest set (a store's backup failed): name one with SET=` | no set name is in every store | fix the backup that failed, then `make backup`, which makes a set of every store; or restore one store with `S=` |
| `the safety set of db failed, so nothing was replaced: <why>; fix it, or restore without one: NO_SAFETY=1` | the database cannot be dumped as it is | fix the reason; for a database that is broken anyway, the same restore with `NO_SAFETY=1` |
| `WARNING: the safety set is not in the off-server copy yet: …; the next backup copies it` | the restore succeeded, the copy of the safety set did not | `make backup-copy-check` names the reason |
| `restore replaces the working database …: run again with CONFIRM=yes` | the guard of the service: a restore without a terminal was not confirmed (a `CONFIRM=yes` in the environment does not count) | read "Restore", then the same command with `CONFIRM=yes` on make's command line |
| `CONFIRM=yes is not on the command line of this make: it came from MAKEFLAGS or GNUMAKEFLAGS of the environment, or from a make that runs this one, which confirm nothing; nothing was replaced` | `CONFIRM=yes` reached make another way than the command line of `make restore` | type `make restore … CONFIRM=yes` itself (and remove `CONFIRM` from an exported `MAKEFLAGS`) |
| `you typed '<answer>', not <name>: nothing was replaced` | in a terminal, the answer was not the name of the database the restore would replace | read what it would replace (above it, in red); to go on, the same command again and the name |
| `NO_SAFETY is '…', not 1 (or empty: a safety set first); nothing was replaced` | `NO_SAFETY=` has another value | `NO_SAFETY=1`, or leave it out |
| `backup-status: the backup service does not run (<state>): make logs S=backup shows why; …` | the `backup` container is stopped or missing; what follows is read from the backup folder in a one-off container | `make logs S=backup`; `make restart` starts it again (a server not deployed yet: `make stage` or `make prod`) |
| `restore: the application is stopped: make restart starts it again` (on a server with no deploy recorded yet: `make stage` or `make prod` in place of `make restart`) | the restore ended; on a server the application does not run | after `restore: db OK: …`, the command the line names; after an error, fix it and run the same restore again with `NO_SAFETY=1` (the safety set of the first attempt stays) |
| `BACKUP_NOTIFY_URL is set, but the image has neither curl nor wget: add one to docker/backup/Dockerfile` (or `BACKUP_HEARTBEAT_URL is set, …`) | the Debian base image has neither | add `curl` to the `base` stage ("Notifications" above), then ship it |
| the heartbeat monitor alerts: the daily ping is missing | no daily run succeeded in time: the server, Docker or the service is down, or a step failed | check that the server is up, then `make status`, `make backup-status` and `make logs S=backup`; after the fix, the next daily run pings again |
| `WARNING: the heartbeat to BACKUP_HEARTBEAT_URL failed` | the run succeeded, but the monitor could not be reached or refused the URL | check `BACKUP_HEARTBEAT_URL` and that the monitor is reachable from this server |
| `BACKUP_USER <user> is not a user of this image` | `BACKUP_USER` in the Dockerfile does not match the base image | set `ENV BACKUP_USER` to the base image's database user, then ship it |
