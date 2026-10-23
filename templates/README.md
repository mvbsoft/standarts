# Templates

Files a project receives. **Verbatim** files are copied unchanged, except the placeholders their
header or settings block names; a project never edits them, and a change goes into the standard.
The project's own formatter and type checker skip the verbatim files; for Python,
`extend-exclude = ["scripts/check-compose.py"]` under `[tool.ruff]` and
`exclude = ["scripts/check-compose.py"]` under `[tool.pyright]`. No test of the standard checks
these two settings, and `shellcheck`, which `LINT` runs on `scripts/` and the hooks, reads the
verbatim shell files.
**Starting points** give every project the same structure; the project fills them in and changes
them as it grows, keeping that structure. Each file that can hold a comment names its template and
version in its first lines (`CLAUDE.md` is the single line `@AGENTS.md`; JSON files cannot hold
comments).

| File in the project | Kind | Rule | When |
|---|---|---|---|
| `Makefile` from [project/Makefile](project/Makefile) | verbatim except the settings block at the top and the "Project targets" block at the end, and one written exception: [mutation testing](#mutation-testing-declined) | ENV-05, ENV-09 | always |
| `scripts/project.sh` from [project/scripts/](project/scripts/project.sh) | verbatim | ENV-04, ENV-05, ENV-09 | always |
| `.githooks/pre-push` from [project/.githooks/](project/.githooks/pre-push) | verbatim | QLT-02 | always |
| `scripts/check-compose.sh`, `scripts/check-compose.py` from [check-compose/](check-compose/scripts/) | verbatim; 4.0.0 also checks the digests in `FROM`, `COPY --from`, `RUN --mount from=` and `# syntax=` of `docker/<name>/Dockerfile`, and refuses the tag `latest` | [ENV-03](../standard/02-environments.md#env-03-compose-rule-check-m-if-there-is-stage-or-prod) | there is stage or prod |
| `.claude/plugins/` and the `settings.fragment.json` merge from [docker-lsp/](docker-lsp/) | verbatim except `<repo>`, `<owner>` and the language list | AI-07 | the owner wants language servers (S-21) |
| `.claude/hooks/check-file.sh`, `check-command.sh` (the checks, for any agent), `post-edit.sh`, `pre-bash.sh` (the Claude Code adapters that call them), `json-get.awk` and the `settings.fragment.json` merge from [agent-hooks/](agent-hooks/); a project copies the whole `.claude/hooks/` | verbatim | AI-05, AI-06 | the owner wants the agent's hooks (S-20) |
| `.claude/hooks/checks.conf` from [agent-hooks/](agent-hooks/.claude/hooks/checks.conf) | starting point: a `check` line for the formatter check, the linter and, where it checks one file with the project's settings, the type checker of each language the project has, the same tools as `LINT`; `allow` lines only for the host exceptions of registry section E | AI-05, AI-06, QLT-01 | the owner wants the agent's hooks (S-20) |
| `docker/backup/backup.sh`, `copy.sh` from [project/docker/backup/](project/docker/backup/backup.sh) | verbatim | OPS-01 | the project has backups (S-06) |
| `docker/backup/postgres.sh` from [project/docker/backup/](project/docker/backup/postgres.sh) | verbatim: the module of a Postgres store and the reference for the module of any other store, which the project writes next to it | OPS-01 | a Postgres store |
| `docker/status/Dockerfile`, `status.py` from [project/docker/status/](project/docker/status/status.py) | verbatim: the monitoring service (the compose files' `status` service runs it; `status-proxy` is a pinned image of wollomatic/socket-proxy) | OPS-04, ENV-08 | there is stage or prod, and the owner wants health monitoring |
| `docker/backup/Dockerfile` from [project/docker/backup/](project/docker/backup/Dockerfile) | starting point: the `FROM` names the project's database image; another store adds its client and server, and `BACKUP_USER` names the base image's database user; another kind of off-server copy needs its own client and its own proof that the server cannot delete from it; its header lists what `backup.sh` needs from the base image | OPS-01, ENV-08 | the project has backups (S-06) |
| `docs/how-to/backups.md` from [project/docs/how-to/](project/docs/how-to/backups.md) | starting point | DOC-01, OPS-01 | the project has backups (S-06) |
| `README.md` from [project/README.md](project/README.md) | starting point: the section "Working with this project" keeps the rows of every scenario that applies, with the commands unchanged | DOC-04 | always |
| `docs/how-to/operations.md` from [project/docs/how-to/](project/docs/how-to/operations.md) | starting point; its section "Monitoring" goes with the `status` service | DOC-01, DOC-04, OPS-04 | there is stage or prod |
| `docs/how-to/tuning.md` from [project/docs/how-to/](project/docs/how-to/tuning.md) | starting point: the method stays; one row per parameter the project tunes (the template's rows fit its limits and a PostgreSQL database) | DOC-01, OPS-02 | there is stage or prod |
| `scripts/tuning-check.sh` from [project/scripts/](project/scripts/tuning-check.sh) | starting point: a `limits` line per service with limits and a line per row of `tuning.md`; the PostgreSQL lines are the pattern for other components | OPS-02 | there is stage or prod |
| `AGENTS.md`, `CLAUDE.md` from [project/](project/AGENTS.md) | starting point; `CLAUDE.md` is verbatim | AI-01 | always |
| `docker-compose.dev.yml`, `.stage.yml`, `.prod.yml` from [project/](project/docker-compose.prod.yml) | starting point | ENV-01 to ENV-04 | per environment |
| `.env.example`, `.gitignore`, `.dockerignore` from [project/](project/.env.example) | starting point | PRN-04, ENV-04, ENV-07 | always |
| `.gitattributes` from [project/](project/.gitattributes) | starting point: `* text=auto eol=lf` stays, so every checkout has LF line endings even with `core.autocrlf=true`, and the scripts and the hook run in `sh` | ENV-05, QLT-02 | always |
| `trivy.yaml` from [project/](project/trivy.yaml) | starting point: `make image-scan` fails on critical findings that have a fix; the project tightens it as it can and lists each finding it accepts in `.trivyignore`, with the reason | QLT-01 | there is prod |

<a id="mutation-testing-declined"></a>
**Mutation testing declined.** It is the owner's choice (QLT-01, R). When the owner says no,
nothing of it goes into the project, and the agent removes these parts and records the answer in
section 0 of the registry: the `MUTATION` and `MUTATION_DIFF` settings of the `Makefile`; the
targets `mutation` and `mutation-diff` with their `.PHONY` names and help lines; the `mutation`
service of `docker-compose.dev.yml`; `MUTATION_CPUS` and `MUTATION_MEM` of `.env.example`; the
README row for them; and the paragraph under its tables. This is the one exception to "the `Makefile` is verbatim outside its two
blocks" and to "every project has every target" (ENV-05); the list is here and nowhere else.

Written for each project, by the rules and not from a template: `docker/<service>/Dockerfile`
(ENV-08) of the project's own services, the registry (DOC-03), the check commands in the
`Makefile` settings (`LINT`, `TEST`, `SECRETS`, `FIX` and the rest: QLT-01), and the allowlist of
the secret scan, `.gitleaks.toml`: `gitleaks dir` reads every file of the working tree, also the
ones git ignores (`.env`, caches, build outputs), so the allowlist names them and leaves
`.env.example` scanned, as [tests/stacks/.gitleaks.toml](../tests/stacks/.gitleaks.toml) does.
The samples in [tests/stacks/](../tests/stacks/run.sh) show these parts for Python, PHP and
TypeScript: a `dev` stage with the pinned tools of `LINT`, `TEST` and `SECRETS` (the stack's
formatter, linter, types and tests, `shellcheck`, `lychee`, `gitleaks`) and the language server,
the tool configs, the `make-settings` (`LINT`, `TEST`, `SECRETS`, `FIX`) and `checks.conf`.
`make check-stacks` proves them with `make gates`, run in the dev container without a network, and
with the hooks and the `docker-lsp` plugin.

The compose files' `backup` service starts as root only to give its folders to the database user
(`BACKUP_USER`), with the capabilities `CHOWN`, `SETUID` and `SETGID`, so its
`x-check-compose-allow` entries for the `user` and `cap_add` rules come with the template. The
`status-proxy` service mounts `/var/run/docker.sock` read-only, so its entry for the `docker-sock`
rule comes with the template too; it runs as `nobody`, and the standard's `tests/status` prove that
it forwards only the container list and this project's containers by name. These exceptions are
the standard's own and need no row in registry section E; any other exception does.
A project without data worth keeping, or whose owner declined backups (S-06), has no `backup`
service: it leaves out `docker/backup/`,
`docs/how-to/backups.md`, the `backup` service, the `backup-data` and `backup-drill` volumes and
those exceptions in the compose files, the `BACKUP_*` lines of `.env.example`, `BACKUP_CPUS` and
`BACKUP_MEM` in the first row of `docs/how-to/tuning.md`, the `backup` line of
`scripts/tuning-check.sh`, `docker/backup/data/` in `.gitignore` and `.dockerignore` and the
backup folder in `.gitleaks.toml`, `backup` in `IMAGES`, the `/disk/backup` mount of the `status` service (its `disk.backup` would
report a folder that does not exist), the backup rows and link of the README and the backup parts of
`docs/how-to/operations.md`; its backup targets refuse with `this project has no backup service`.
A project that does not want health monitoring leaves out `docker/status/`, the `status` and
`status-proxy` services and the `status-proxy` network in the stage and prod files (with the
`docker-sock` entry of `x-check-compose-allow`), the `STATUS_*`, `DISK_WARN` and `DOCKER_GID` lines
of `.env.example`, the `STATUS_*` limits in the first row of `docs/how-to/tuning.md`, the `status`
lines of `scripts/tuning-check.sh`, `status` in `IMAGES`, the
monitoring rows of the README and the section "Monitoring" of `docs/how-to/operations.md`.

[report-site/](report-site/README.md) is not copied into a project: it is the page on which the
agent shows the owner its report, questions and plan ([`prompt/start.md`](../prompt/start.md)).
