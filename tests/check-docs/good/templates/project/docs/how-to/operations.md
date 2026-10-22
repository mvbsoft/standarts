# Runbook

## Update

`make stage` prints `OK: stage runs <commit>`, then `make status` shows the services.
See [Update](#update).

## Images

After each deploy prune removes the older images:
`prune: removed N old images; the images of the last 5 deployed commits stay`.

## Restore

The restore first shows, for each store,
`restore: db: replaces the database <name> on <host> with the local set <set>`; then it stops
every service but `backup` and names them (for example `restore: stopping app db for the restore`).

## Status

`make logs S=status` shows each change of the status once, as
`status: now <status>: pushing to <VAR>` (or `status: now fail: no push, empty STATUS_PUSH_FAIL_URL`),
and a failed push as `status: push failed: HTTPError: Not Found`.

## When something fails

| What you see | What it means | What to do |
|---|---|---|
| `building <repo>-<image> for commit <sha> failed (above); nothing was replaced` | a build step failed | fix it, ship again |
| `unhealthy: the newest set of db was made … ago (BACKUP_MAX_AGE=…)` | an old set | `make backup-status` |
| `"error": "cannot read the containers: …"` in `GET /status`, with `"status": "fail"` | the socket | check the proxy |
| `status: STATUS_TOKEN has fewer than 16 characters: set a long random one in .env` | a short token | a longer one |
| `parity` or `check-compose` fails | the files break a rule | fix the files |
| `unhealthy: the last drill failed: …` | a drill failed | `make backup-status` |
| `the backup folder (…) belongs to uid <u> and cannot be read` | not the service's folder | give it one |
| `required variable … is missing a value` | a setting is empty | set it |
