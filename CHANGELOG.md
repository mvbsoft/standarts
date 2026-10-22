# Changelog

Every release lists what changed, by rule ID (`ENV-02`) and template. **Breaking** marks a change
that projects must act on; the update prompt re-audits the rules and templates named here.

## Unreleased

- First version of the standard: `GUIDE.md`, the whole standard on one page; rules `PRN`, `ENV`,
  `OPS` (with `OPS-04`, health monitoring), `QLT`, `AI` (chapter `05-agents`: a core for any agent
  and the Claude Code adapter), `DOC`, `TYP`; "Known limits" in `standard/README.md`; decisions
  D-0001 to D-0027; the prompts `start` (modes: new, adopt, update, set up again), `adopt`, `new`,
  `update`; `scripts/proof.sh`, the proof copy for stage and prod on one machine.
- The template `project` 1.0.0:
  - checks in two floors: base commands `lint`, `test`, `e2e`, `security`, `infra` and group
    commands `gates` (the pre-push hook) and `verify`, with a summary line per check (`ok`, `FAIL`,
    `off`, `skip`); `LINT`, `TEST` and `SECRETS` are mandatory or deliberately `off`; `fix`,
    `mutation`, `mutation-diff` and `image-scan` by hand; `docker build --check` in `lint`;
  - own images built on the server by `make stage` / `make prod` (D-0025); every third-party image
    pinned as `<image>:<version>@sha256:<digest>`; one copy of stage and of prod per machine;
    a free-space check before deploy, images, rollback, restart, restore and the backup drill
    (`DISK_RESERVE`); the
    logs of replaced containers kept in `LOG_ARCHIVE_DIR`; `.env` and build secrets readable by
    the owner only; the application's own database role (`APP_DB_USER`), never the superuser; a
    backup set right before the migration of a server deploy (with the `backup` service, not on a
    clone's first deploy); a check that is only an estimate (free space, the backup before the
    migration) explains the risk and asks, `RISK=yes` without a terminal;
  - the `backup` service: local sets, a write-only off-server copy through rest-server
    (`--append-only`, rotation on the storage side), a safety set before every restore, and the
    make commands `backup`, `backup-list`, `backup-drill`, `backup-status`, `backup-copy-check`,
    `backup-test`, `restore` (a typed database name in a terminal, `CONFIRM=yes` without one);
  - the `status` service behind a read-only socket proxy: `GET /status` with a token (200 pass or
    warn, 503 fail) and pushes to two addresses (`STATUS_PUSH_URL`, `STATUS_PUSH_FAIL_URL`);
  - `docs/how-to/tuning.md`, `scripts/tuning-check.sh`, PostgreSQL settings as `-c` flags from
    `.env`, `memswap_limit` equal to the memory limit, `trivy.yaml`, `.gitattributes` with LF.
- `check-compose` 4.0.0 (digests also in the Dockerfiles of own images, the tag `latest` refused),
  `agent-hooks` 1.1.0 (`check-file.sh` and `check-command.sh` for any agent; `post-edit.sh` and
  `pre-bash.sh` adapt them to Claude Code), `docker-lsp` 1.1.0, `report-site` 1.0.0.
- The repository's own checks: `make check` (documents with anchors, quoted messages and repeats;
  check-compose; the project template; the backup and status services; the proof copy) and
  `make check-stacks` (Python, PHP and TypeScript samples); the catalog with healthchecks.
