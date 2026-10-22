# Catalog

What has been researched so far about tuning ([OPS-02](../standard/03-operations.md)), backups
([OPS-01](../standard/03-operations.md)), their monitors and healthchecks
([OPS-04](../standard/03-operations.md#ops-04-health-monitoring-r-for-stage-and-prod)) per technology. It is a starting point
for an audit, not a complete list and not a set of values to copy: the audit checks every row
against the exact version the project runs and adds a component researched for the first time.

## Tuning

| Component | What to tune | Why the factory value does not fit | How `tuning-check` reads the actual value |
|---|---|---|---|
| PostgreSQL | `shared_buffers`, `effective_cache_size`, `work_mem`, `maintenance_work_mem`, `max_connections` (counting the connection pool), the container's `shm_size`, WAL checkpoints, autovacuum | [1] for `shared_buffers`; the audit researches the rest for the exact version | `SHOW <parameter>` |
| Nginx in the application container | `gzip` and `gzip_types` (or brotli), cache headers for static files, keepalive, `worker_processes` (`auto` counts the host's CPUs, not the container's quota), `client_max_body_size`. A front proxy on the server only forwards, so compression happens here | [2] | `curl -sI -H 'Accept-Encoding: gzip'` from inside the network shows `Content-Encoding: gzip` |
| PHP | opcache: `opcache.enable`, `opcache.memory_consumption`, `opcache.validate_timestamps=0` in stage and prod (the code in a baked image changes only with a new container); php-fpm: `pm`, `pm.max_children`, `pm.max_requests`; Composer's optimised autoloader in the `runtime` stage | [3] | values as php-fpm sees them, not the CLI: `opcache.enable_cli` defaults to 0, so the CLI reports different values |

Not researched yet; the first audit of a project that uses them researches them in full: MongoDB
(WiredTiger cache size and whether it follows the container limit), Redis (`maxmemory`,
`maxmemory-policy`), Node.js (heap size against the container limit, number of processes), Python
application servers (number of workers, timeouts).

## Backups

| Store | Tool | Notes |
|---|---|---|
| PostgreSQL | `pg_dump` per database, `pg_dumpall --globals-only --no-role-passwords` for roles and tablespaces; the database's own settings and privileges come with `--create` [7] | consistent while the database is in use [4]; a read-only role with `pg_read_all_data`, plus `BYPASSRLS` where row-level security is used [5], because without it `pg_dump` stops with an error on such a table [20] (tested 2026-10-19); before PostgreSQL 19 that role does not read large objects [14], and their read right is granted per object [16], so a database that has them grants the role `SELECT` on each existing one, and on new ones from PostgreSQL 18 once with `ALTER DEFAULT PRIVILEGES` for the role that creates them [15], before 18 on each one as it is created; a file-level copy needs a stopped server [6], so it is not used. The template's module holds one session open that exports a snapshot; `pg_dump --snapshot` and the manifest's row counts both read it, so they match while the database is in use [17]. With `--no-role-passwords`, `pg_dumpall` reads `pg_roles`, not `pg_authid` [18], so no password hash enters the set; role passwords come from `.env` (`pg_read_all_data` can read `pg_authid` itself, hashes included; tested 2026-10-19). The official documentation says pg_dump is generally not the right choice for regular backups of production databases; the standard accepts that for small databases ([D-0010](../decisions/0010-backups.md)) |
| Off-server copy (any store) | restic, from the `backup` image | restic encrypts everything it stores [8]; without the password the copy cannot be read [9]. The server's credentials may only add: the template's example is rest-server with `--append-only --private-repos` (repository `rest:https://<host>:<port>/<login>/`, user and password from `RESTIC_REST_USERNAME` / `RESTIC_REST_PASSWORD`, `--cacert` for a self-signed certificate) [33]; measured 2026-10-21 (rest-server 0.14.0, restic 0.19.1): backup, `snapshots` and `check` work from the server, and `forget`, `prune` and a raw DELETE or POST of an existing snapshot, pack, index, key or `config` get 403. An SFTP store is not write-only even with the requests `remove`, `rmdir` and `posix-rename` denied (`sftp-server -P` [34]): restic needs `rename` and `setstat`, so the key could `chmod` and overwrite a snapshot and move `config` away, and every command leaves a lock that blocks `check` and a storage-side `prune` until `unlock` (measured 2026-10-21); a store that cannot be proven to refuse deletes and overwrites does not meet [OPS-01](../standard/03-operations.md). Rotation therefore runs on the storage side, with credentials of its own, for example with plain restic on the same folder: `forget --group-by host,tags --keep-daily --keep-weekly` and `prune`; each set is stored with `backup --tag <service>`: every set has its own path, and by default `forget` groups snapshots by host and paths and applies the policy per group, so without `--group-by host,tags` nothing would ever be removed [11]. A server that is broken into can add junk sets, which a plain count-based rotation would let push the real sets out (measured 2026-10-21: both rotation steps planned to delete every real set); `--keep-within` stops that (the template keeps every set of the last 7 days, `--keep-within 7d`, and the newest `before-restore` set). The server checks the copy by reading it: `check --read-data-subset` reads part of the stored data back [12]. In a container, set a static `hostname` [13]. Exit code 10 means the repository does not exist and 12 a wrong password [19]: the template creates a missing repository with `restic init` and names a wrong password as such. restic 0.19.1 has `backup --time` (the template stores each set with its own time, so `forget` keeps the same sets as the local rotation) (tested 2026-10-19). History of the dropped path: on 2026-10-19 the copy was tested end to end with a local-path repository and against an SFTP server (atmoz/sftp, OpenSSH 10.3p1) on the Alpine and Debian bases (the SFTP form is `sftp:user@host:/path` with key login only and no prompt [10]); the template no longer copies over SFTP, and another store needs its own client and its own proof that the server cannot delete or overwrite ([D-0010](../decisions/0010-backups.md)) |
| The `backup` image and its start | built from `postgres:16-alpine` (16.15), Docker 29.7.2 | the base image declares `VOLUME /var/lib/postgresql/data`, so the service mounts a tmpfs there (without it, Docker creates an anonymous volume); it has `gosu` and no ssh client. Docker creates a missing bind-mount source as `0:0`, mode `755`, so the service starts as root only to give `BACKUP_DIR` and `/drill` to `postgres`, then drops to it with `gosu`; without `CHOWN` the `chown` fails, without `SETUID` or `SETGID` the switch to `postgres` fails (all tested 2026-10-19) |

The heartbeat of the `backup` service (`BACKUP_HEARTBEAT_URL`) goes to a monitor on another
machine that alerts when the daily ping is missing. Researched so far (from the docs; neither was
run against the template, which was tested with a local HTTP listener only, 2026-10-19):

| Monitor | Notes |
|---|---|
| Healthchecks.io (hosted, or self-hosted: open source, BSD 3-clause [24]) | a check with a simple schedule: Period, the expected time between pings, and Grace Time, the wait before an alert when the check is late [21] (for a daily backup: 1 day and 2 hours); the check URL is `https://hc-ping.com/<uuid>` and takes HEAD, GET and POST [22], on a self-hosted instance `SITE_ROOT` + `/ping/` + the UUID [24]; alerts go through the integrations enabled for the check, several at once [23] |
| Uptime Kuma (self-hosted [25]) | a monitor of type Push; the app asks to call its URL every Heartbeat Interval seconds [26] (for a daily backup: 86400) and marks the monitor down, then notifies, after Retries checks at the Heartbeat Retry Interval [26] (Retries 1 at 7200 s is a 2-hour grace); the push URL is `<base URL>/api/push/<push token>?status=up&msg=OK&ping=` and the method is ignored [27]; notifications through Telegram, Slack, e-mail (SMTP) and 90+ services [25] |

## Healthchecks

The `status` service reports what Docker keeps of a container's healthcheck, so a check has to prove
that the service answers its protocol, not that its process exists. Measured on 2026-10-21 (Docker
Engine 29.7.2, Compose v5.5.0; one-off runs, not part of a test) with `init: true`, `interval: 2s`,
`timeout: 2s`, `retries: 3`; a hung server was made with `docker exec -u 0 <container> sh -c 'kill
-STOP -1'`, after which each check below but the proxy's (not broken separately) turned unhealthy, with the
output `Health check exceeded timeout (2s)`.

| Service | Check | Pitfall |
|---|---|---|
| PostgreSQL 16 | `["CMD","pg_isready","-U","postgres"]` | does not authenticate: “It is not necessary to supply correct user name, password, or database name values” [28]; `pg_isready -U nobody` also exits 0. The template's `db` check goes further and logs in as the application's role (the compose files) |
| Redis 7 | env `REDISCLI_AUTH` and `["CMD-SHELL","redis-cli ping \| grep -qx PONG"]` | a plain `redis-cli ping` against a server with `--requirepass` prints `NOAUTH Authentication required.`, exits 0 and stays healthy; PING “returns the bulk string `PONG`” [29] |
| MySQL 8.0 | `["CMD","mysqladmin","ping","-h","127.0.0.1"]` | exits 0 even on `Access denied` [30]: it proves that the server answers, not that it serves queries; a check with credentials was not tried |
| MariaDB 10.6 | `["CMD","healthcheck.sh","--connect","--innodb_initialized"]` | the strongest of the stock checks: it logs in as its own user, from `.my-healthcheck.cnf` in the data directory [31] |
| nginx 1.27 | `["CMD","wget","-q","-O","/dev/null","http://127.0.0.1/health"]` and `location = /health { return 200 "ok\n"; }` | `wget` exits 1 on a 404 and on a refused connection; `curl -fsS` exits 22 on a 404, and curl without `-f` exits 0 on a 404 (documented, not run) |
| socket proxy (wollomatic 1.13.1) | `["CMD","/healthcheck"]` with `-allowhealthcheck` | — |

Rules that follow from the measurements:
- The check fails on an error reply: take the exit code from the reply (`grep -qx PONG`, `curl -f`),
  not from the client's own exit code.
- It prints a short line or nothing: the `output` of `status` is the raw text, and Docker keeps only
  the first 4096 bytes of it, in the last 5 results [32].
- `timeout` is shorter than `interval`. A hung check turns the container unhealthy after about
  `retries × (interval + timeout)`; with 2 s, 2 s and 3 that was within 15 s.
- A slow starter has `start_period` and `start_interval`: a failure inside `start_period` is not
  counted toward `retries`, and during it Docker checks every `start_interval` (5 s by default),
  not every `interval` [32].
- A check never prints a secret: its output is shown by `status` and sent to the monitor.

## Sources

1. <https://www.postgresql.org/docs/current/runtime-config-resource.html> — “The default is
   typically 128 megabytes (`128MB`), but might be less if your kernel settings will not support
   it”; “If you have a dedicated database server with 1GB or more of RAM, a reasonable starting
   value for `shared_buffers` is 25% of the memory in your system.”
2. <https://nginx.org/en/docs/http/ngx_http_gzip_module.html> — the defaults are “gzip off;” and
   “gzip_types text/html;”.
   <https://github.com/nginx/nginx/blob/master/src/os/unix/ngx_posix_init.c> — `auto` takes
   `ngx_ncpu = sysconf(_SC_NPROCESSORS_ONLN);`, the CPUs online on the host.
3. <https://www.php.net/manual/en/opcache.configuration.php> — the defaults table lists
   `opcache.memory_consumption` 128 and `opcache.enable_cli` 0; “When this directive is disabled,
   you must reset OPcache manually via opcache_reset(), opcache_invalidate() or by restarting the
   Web server for changes to the filesystem to take effect.”
   <https://www.php.net/manual/en/install.fpm.configuration.php> — `pm.max_children` “sets the
   limit on the number of simultaneous requests that will be served”; `pm.max_requests` “Default
   value: 0.”
4. <https://www.postgresql.org/docs/current/app-pgdump.html> — “It makes consistent exports even if
   the database is being used concurrently.”; “except in simple cases, pg_dump is generally not the
   right choice for taking regular backups of production databases.”
5. <https://www.postgresql.org/docs/18/predefined-roles.html> — “`pg_read_all_data` allows
   reading all data (tables, views, sequences), as if having `SELECT` rights on those objects and
   `USAGE` rights on all schemas. This role does not bypass row-level security (RLS) policies. If RLS
   is being used, an administrator may wish to set `BYPASSRLS` on roles which this role is granted
   to.”
6. <https://www.postgresql.org/docs/current/backup-file.html> — “The database server must be shut
   down in order to get a usable backup.”
7. <https://www.postgresql.org/docs/current/app-pgdump.html> — “With `--create`, the output also
   includes the database's comment if any, and any configuration variable settings that are
   specific to this database”; “Access privileges for the database itself are also dumped, unless
   `--no-acl` is specified.”; “For the archive formats, you can specify the option when you call
   pg_restore.”
   <https://www.postgresql.org/docs/current/app-pg-dumpall.html> — “Dump only global objects (roles
   and tablespaces), no databases.”
8. <https://raw.githubusercontent.com/restic/restic/master/doc/design.rst> — “All data stored by
   restic in the repository is encrypted with AES-256 in counter mode and authenticated using
   Poly1305-AES.”
9. <https://raw.githubusercontent.com/restic/restic/master/doc/030_preparing_a_new_repo.rst> —
   “Remembering your password is important! If you lose it, you won't be able to access data stored
   in the repository.”
10. <https://raw.githubusercontent.com/restic/restic/master/doc/030_preparing_a_new_repo.rst> —
    “$ restic -r sftp:user@host:/srv/restic-repo init”; “Passwordless login is important since
    automatic backups are not possible if the server prompts for credentials.”; “For automated
    backups, restic supports specifying the repository location in the environment variable
    ``RESTIC_REPOSITORY``.”; “Specifying the path to a file with the password via the option ``--password-file`` or the
    environment variable ``RESTIC_PASSWORD_FILE``”.
11. <https://raw.githubusercontent.com/restic/restic/master/doc/060_forget.rst> — “The latter can
    be automated with the ``--prune`` option of ``forget``, which runs ``prune`` automatically if
    any snapshots were actually removed.”; “restic first loads the list of all snapshots and groups
    them by their host name and paths.”; “The policy is then applied to each group of snapshots
    individually.”
12. <https://raw.githubusercontent.com/restic/restic/master/doc/045_working_with_repos.rst> —
    “Alternatively, use the ``--read-data-subset`` parameter to check only a subset of the
    repository pack files at a time.”
13. <https://raw.githubusercontent.com/restic/restic/master/doc/020_installation.rst> — “Make sure
    to set a static hostname using ``--hostname`` when creating a Docker container, otherwise Docker
    will assign a random hostname each time.”
14. <https://www.postgresql.org/docs/19/release-19.html> — “Allow roles pg_read_all_data and
    pg_write_all_data to read/write large objects”.
15. <https://www.postgresql.org/docs/18/release-18.html> — “Allow ALTER DEFAULT PRIVILEGES to
    define large object default privileges”.
16. <https://www.postgresql.org/docs/18/sql-grant.html> — “GRANT { { SELECT | UPDATE } [, ...] |
    ALL [ PRIVILEGES ] } ON LARGE OBJECT loid [, ...]”.
17. <https://www.postgresql.org/docs/16/app-pgdump.html> — `--snapshot`: “This option is useful
    when needing to synchronize the dump with a logical replication slot (see Chapter 49) or with a
    concurrent session.”
18. <https://www.postgresql.org/docs/16/app-pg-dumpall.html> — `--no-role-passwords`: “Since
    password values aren't needed when this option is specified, the role information is read from
    the catalog view pg_roles instead of pg_authid.”
19. <https://raw.githubusercontent.com/restic/restic/master/doc/075_scripting.rst> — in the table
    of exit codes, `10`: “Repository does not exist (since restic 0.17.0)”; `12`: “Wrong password
    (since restic 0.17.1)”.
20. <https://www.postgresql.org/docs/current/app-pgdump.html> — `--enable-row-security`: “By
    default, pg_dump will set row_security to off, to ensure that all data is dumped from the
    table. If the user does not have sufficient privileges to bypass row security, then an error is
    thrown.”
21. <https://healthchecks.io/docs/configuring_checks/> — “Period is the expected time between
    pings.”; “Grace Time is the additional time to wait before sending an alert when a check is
    late.”
22. <https://healthchecks.io/docs/http_api/> — “HEAD, GET, and POST request methods.”; the success
    endpoint “HEAD|GET|POST https://hc-ping.com/<uuid>”.
23. <https://healthchecks.io/docs/configuring_notifications/> — “You can set up multiple ways to
    receive notifications when checks in your account change state.”
24. <https://healthchecks.io/docs/self_hosted/> — “Healthchecks is open-source, and is licensed
    under the BSD 3-clause license.”
    <https://healthchecks.io/docs/self_hosted_configuration/> — `PING_ENDPOINT`: “Default:
    SITE_ROOT + /ping/”.
25. <https://github.com/louislam/uptime-kuma> — “Uptime Kuma is an easy-to-use self-hosted
    monitoring tool.”; the monitor types include “Push”; “Notifications via Telegram, Discord,
    Gotify, Slack, Pushover, Email (SMTP), and 90+ notification services”.
26. <https://raw.githubusercontent.com/louislam/uptime-kuma/master/src/lang/en.json> — the Push
    monitor's form: “You should call this URL every {0} seconds.”; Retries: “Maximum retries before
    the service is marked as down and a notification is sent”.
    <https://raw.githubusercontent.com/louislam/uptime-kuma/master/server/model/monitor.js> — a push
    monitor without a push in its interval fails with “No heartbeat in the time window”, and while
    retries remain the next check comes after the retry interval.
27. <https://github.com/louislam/uptime-kuma/wiki/Internal-API> — “**Endpoint:**
    `/api/push/<pushToken>`”; “(Method is generally ignored)”; the page also says this API is “not
    officially supported for third-party integrations”.
    <https://raw.githubusercontent.com/louislam/uptime-kuma/master/src/pages/EditMonitor.vue> — the
    push URL it shows: `this.$root.baseURL + "/api/push/" + this.monitor.pushToken +
    "?status=up&msg=OK&ping="`.
28. <https://www.postgresql.org/docs/16/app-pg-isready.html> — “It is not necessary to supply
    correct user name, password, or database name values to obtain the server status”.
29. <https://redis.io/docs/latest/commands/ping/> — PING “returns the bulk string `PONG`”; it
    verifies “the server's ability to serve data - an error is returned when this isn't the case”.
30. <https://dev.mysql.com/doc/refman/8.0/en/mysqladmin.html> — “This is 0 even in case of an error
    such as `Access denied`, because this means that the server is running but refused the
    connection”.
31. <https://mariadb.com/kb/en/using-healthcheck-sh/> — `--connect`: “Active when an external user
    can connect to the TCP port”; `--innodb_initialized`: “True when InnoDB has completed
    initializing, including any rollback or crash recovery”; the healthcheck user's config is
    “stored in `.my-healthcheck.cnf` in the datadir”.
32. <https://docs.docker.com/reference/dockerfile/#healthcheck> — “`--start-interval=DURATION`
    (default: `5s`)”; “Probe failure during that period will not be counted towards the maximum
    number of retries.”; “only the first 4096 bytes are stored currently”.
    <https://raw.githubusercontent.com/moby/moby/master/daemon/health.go> — `maxOutputLen = 4096`,
    `maxLogEntries = 5`.
33. <https://raw.githubusercontent.com/restic/rest-server/v0.14.0/README.md> — “The `--append-only`
    mode allows creation of new backups but prevents deletion and modification of existing backups.
    This can be useful when backing up systems that have a potential of being hacked.”; “To prevent
    your users from accessing each others' repositories, you may use the `--private-repos` flag”.
    <https://raw.githubusercontent.com/restic/restic/v0.19.1/doc/060_forget.rst> — “Security
    considerations in append-only mode”: the repository “can only be written to and read from, while
    delete and overwrite operations are denied. Restic's `rest-server` features an append-only mode,
    but few other standard backends do.”
    <https://raw.githubusercontent.com/restic/restic/v0.19.1/doc/030_preparing_a_new_repo.rst> —
    `RESTIC_REST_USERNAME` / `RESTIC_REST_PASSWORD` for the `rest:` backend.
34. <https://man.openbsd.org/sftp-server> — `-P`: “Specifies a comma-separated list of SFTP protocol
    requests that are banned by the server.”
