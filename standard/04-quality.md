# Quality tools

> Version 1.0.0-draft · English · [Українська](04-quality.uk.md)

### QLT-01. Tool categories (M)

The standard sets categories, not names: the names in the table are the usual choice for each
language ([D-0026](../decisions/0026-quality-tools.md)). Another tool of the same category is
allowed if it is recorded in the registry with a reason. Versions, and why a version is chosen or
excluded, are in D-0026; the pins are in the images and lock files of the project.

| Category | Level | Python | TypeScript / React | PHP | Where | Command |
|---|---|---|---|---|---|---|
| Format | M | ruff format | prettier | php-cs-fixer | dev | `lint` |
| Lint | M | ruff (with S, PL, C90, B, …) | eslint (+ typescript-eslint, react-hooks) | phpstan / psalm + rector `--dry-run` | dev | `lint` |
| Types | M | pyright strict | tsc strict + `noUncheckedIndexedAccess` | phpstan max | dev | `lint` |
| Shell lint | M, if there are `*.sh` files | shellcheck over every script in git | same | same | dev | `lint` |
| Documentation links | R | lychee `--offline` | same | same | dev | `lint` |
| Architecture contracts | R (≥3 packages) | import-linter | eslint-plugin-boundaries / dependency-cruiser | deptrac | dev | `lint` |
| Dockerfile check | R | `docker build --check` of the Dockerfile of every own image | same | same | host | `lint` |
| Offline tests | M | pytest | vitest | phpunit | dev | `test` |
| Tests against a real database | R | pytest against a real Postgres (tmpfs) | | | dev | `test` |
| Property-based tests | O (where there is a "whole input domain") | hypothesis | fast-check | | dev | `test`, if present |
| API contract | R, if there is OpenAPI | schemathesis | client generated from OpenAPI | | dev | `e2e` |
| Browser end-to-end tests | R, if there is a UI | Playwright in the dev image | Playwright | | dev | `e2e` |
| Secrets | M | gitleaks (pinned, offline) | same | same | dev | `security`, and `gates` |
| SAST | R | semgrep (`--metrics off`, rules from local files) | semgrep | semgrep / psalm taint | dev | `security` |
| Dependency audit | M | pip-audit | npm audit | composer audit | dev, network | `security` |
| Image scan | M, if there is prod | trivy image | same | same | dev, network | `image-scan` |
| Automatic fixes | R | ruff format + `ruff check --fix --no-unsafe-fixes` | prettier `--write` + `eslint --fix` | `php-cs-fixer fix --allow-risky=no` | dev | `fix` |
| Mutation testing | R, the owner's choice | cosmic-ray + hand-written mutants for security checks | StrykerJS | Infection | dev, its own container with the limits `MUTATION_CPUS` / `MUTATION_MEM` | `mutation`, `mutation-diff` |
| Coverage | O (diagnostics on the diff) | coverage.py | vitest --coverage | pcov | dev | — |

"dev" means the dev container, which has no Docker of its own; "host" is the machine's own Docker,
which the dev container cannot reach. The `Command` column is the base command that runs the
category ([QLT-03](#qlt-03-when-each-check-runs-m)). The semgrep rules are files of the project: a
project never ships copies of Semgrep-maintained registry rules, whose licence allows internal
business use only. `gitleaks dir` reads every file of the working tree, also the ones git ignores
(`.env`, caches, build output), so a project gives gitleaks an allowlist of them in
`.gitleaks.toml`, as [`tests/stacks/.gitleaks.toml`](../tests/stacks/.gitleaks.toml) does for its
samples; `.env.example` is in git and stays scanned.

The owner chooses mutation testing when the standard is applied: `prompt/new.md` and
`prompt/adopt.md` ask. Yes adds the `mutation` service, its commands and settings, the language's
tool and the proof; no adds none of it, and the choice goes into the registry.

`make image-scan` builds the own images of the checked-out commit on the host, the same way a
server builds them ([ENV-09](02-environments.md#env-09-ship-deploy-and-roll-back-m-if-there-is-stage-or-prod)),
and trivy in the dev container scans each of them; it names every image that failed. A stock base
image has many findings (a dated count is in [D-0020](../decisions/0020-one-way-of-working.md)), so
a scan of every severity is always red: the template's `trivy.yaml` fails on CRITICAL findings that
have a fix, the project tightens it as it can (adds HIGH, then drops `ignore-unfixed`), and a
finding it accepts goes into `.trivyignore` with its reason. The scan downloads trivy's database,
so it needs the network, and the images it builds stay on the machine. Its level is M wherever there
is prod, the same in ENV-09 and QLT-03: a change reaches `PROD_BRANCH` only after the scan passed
on it.

`make fix` runs the fixers of the same tools in their safe mode: for ruff and php-cs-fixer, the
fixes and rules the tool itself does not call unsafe or risky; rector stays `--dry-run`, because it
refactors code and its changes are read as a diff. It is run by hand, by a person or an agent,
never by a gate or a hook, because a gate only checks (QLT-02). A fixer changes the form of the
code and, by each tool's own definition, not what it does; none of them guarantees it, so after
`make fix` read `git diff` and run `make gates`. The point is that a program makes the simple edits
at once and the same way every time, and the agent takes only what a program cannot
([D-0026](../decisions/0026-quality-tools.md) has the sources).

Every mutation tool mutates all the code by default. So `MUTATION_DIFF` is the project's command
and names the base of `make mutation-diff` itself, normally the stage branch as the clone has it
(`origin/<stage branch>`: run `git fetch` first when it may be stale); the PHP and Python forms
need git in the dev image ([D-0020](../decisions/0020-one-way-of-working.md)):
- PHP, Infection: `infection --git-diff-lines --git-diff-base=origin/$(STAGE_BRANCH)` (make
  expands `$(STAGE_BRANCH)` in the setting) mutates only the changed lines; the default base is
  `master`.
- Python, cosmic-ray: after `cosmic-ray init <config> <session>`, `cr-filter-git --config <config>
  <session>` skips every mutation outside the lines changed against the `branch` of the config's
  `[cosmic-ray.filters.git-filter]` (`master` by default; it does not follow the stage branch, so
  set it to `origin/<stage branch>` and change both together), and `cosmic-ray exec <config>
  <session>` runs the mutations that have no result yet.
- TypeScript, StrykerJS: no git mode; `--incremental` compares the code and the tests with its own
  previous report (`reports/stryker-incremental.json`; `--incrementalFile` moves it, for example
  into `.cache/`) and tests only the changed code. The base is the previous run: the first run
  without a report (a new clone, a new worktree, a cleared folder) mutates all the code. It does
  not see changes to snapshots, dependencies or environment variables.

### QLT-02. Gate rules (M)

- Gates only check: a formatter or fixer runs in its check mode and never rewrites files; a gate
  that changes a file makes the pre-push hook refuse the push.
- Every gate tool has an exact version pin in the image or the lock file. A tool taken into the
  image as a binary or from another image (such as gitleaks, lychee, trivy) is pinned by its
  version and by an image digest or checksum, never by a tag alone
  ([D-0026](../decisions/0026-quality-tools.md)).
- No network tool is part of `gates`; network checks belong to `verify` and `image-scan`. Lint,
  tests and the secret scan run in the dev container and need no network once the image is built.
  The Dockerfile check of `lint` is the one step on the host: when a base image is not on the
  machine, `docker build --check` may need the image's registry to read its metadata (D-0026).
- Three checks are mandatory settings of the project: lint (`LINT`), tests (`TEST`) and the secret
  scan (`SECRETS`). An empty setting (not set up yet) is a failure, never a pass: its command
  refuses to run, and `make gates` and `make verify` end FAIL. A project that does not want a
  check says `off`: that is the owner's recorded choice (asked when the standard is applied,
  written in the registry), and it shows as `off` in the summary. The e2e (`E2E`) and security
  (`SECURITY`) settings may stay empty (shown as `skip`) or be `off`.
- `gates` holds only fast checks and finishes in a few minutes on a developer machine (aim for under
  five); a slower check moves to `verify`. A gate that is too slow gets skipped, and a skipped gate
  checks nothing.
- `make gates` and `make verify` run each base command, also after an earlier one failed, and end
  with a summary of one line per base command: `ok`, `FAIL`, `off` or `skip`, and the last
  meaningful line of its output (the first failing step's, when there are several). The agent quotes it
  and calls a task done only when `make gates` is green ([AI-01](05-agents.md)).
- The git `pre-push` hook from
  [`templates/project/.githooks/`](../templates/project/.githooks/pre-push) runs `make gates` in
  the working tree, which must hold the commit being pushed; when the gates fail, git pushes
  nothing. The gates see the files as they are, uncommitted changes included, and the hook does not
  hide them: in a terminal it lists them and asks whether anything was forgotten to commit, and
  only a yes (`y`) goes on; where it cannot ask (an IDE, an agent, a script) it prints the list as a
  warning and goes on. It does not tell an agent from a person: the agent asks the owner in the
  session before it pushes with uncommitted changes ([AI-01](05-agents.md)). A push of a branch or a tag whose content differs from
  the checked-out commit is refused, because the gates check only that commit; so is a push during
  whose gates `HEAD` moved or a file changed (a gate that rewrites a file, or an edit of your own
  made meanwhile: push again). The hook never uses `git stash`. `make bootstrap` installs the hook
  (`git config core.hooksPath .githooks`), because git does not copy hooks with a clone.
  `git push --no-verify` skips it, for an emergency only; when an agent may use it is in
  [AI-01](05-agents.md).
- The gates are local, and a push can go round them: `git push --no-verify`, a merge in a web
  interface, an IDE or another client that runs no hooks, a clone where `make bootstrap` never ran.
  Whoever wants a guarantee adds a CI of their own; it calls the same `make` commands (`gates`,
  `verify`) and does not repeat the checks in its own wording. The standard adds no CI.

### QLT-03. When each check runs (M)

Base commands run the checks of one area each and include no other base command; group commands add
no checks of their own, but `gates` runs the `SECRETS` step of `security` alone (its summary line is
`secrets`). A command that changes files or takes long is started by hand and is in no group.

| Command | Kind | Runs | Why there |
|---|---|---|---|
| `lint` | base | the code does not run: the Dockerfile check first, then format check, lint, types, shell lint, documentation links, architecture contracts | fast; runs offline in the dev container, except the Dockerfile check on the host |
| `test` | base | the code runs, fast, without network: unit tests, tests against a real database, property-based tests | fast and offline, so it is safe in every push |
| `e2e` | base | the whole application runs, slowly: the API contract, the browser, and calls to outside APIs where the project has them | slow, and may need the network |
| `security` | base | the secret scan (the `SECRETS` step), then SAST and the dependency audit | the audit needs the network |
| `infra` | base | `check-compose`, `parity`, and the test backup where the project has a backup; the first two also run in every deploy | needs Docker and takes time, so they are not in `gates` |
| `gates` | group | `lint`, `test` and the `SECRETS` step of `security` (summary line `secrets`) | the fast, offline part: before every push |
| `verify` | group | `lint`, `test`, `e2e`, `security` and `infra` | everything, when a task is finished |
| `fix` | by hand | the automatic fixers in their safe mode | it changes files, which a gate must not |
| `mutation`, `mutation-diff` | by hand | mutation testing of all code, or of the changed code | slow, and it runs in a container of its own |
| `image-scan` | by hand | the own images of the checked-out commit, built and scanned | builds images, needs the network and disk, and new vulnerabilities appear without a change of the code |

| When | What | Who starts it |
|---|---|---|
| after every edit by the agent | format, lint and, where possible, types of that file ([AI-05](05-agents.md)) | the agent's hook, by itself |
| before every `git push` | `make gates` | the git hook, by itself |
| when a task is finished, before it is merged | `make verify` | the developer or the agent |
| before a change is merged to `PROD_BRANCH` | `make image-scan` (it builds the images of the checked-out commit and scans them) | the developer or the agent |
| every `STATUS_PUSH_INTERVAL` | the health of every service and the free space of Docker's disk and of the backup folder, sent to the monitor ([OPS-04](03-operations.md)) | the `status` service, by itself |
| daily, and weekly a restore drill | the `backup` service's set, copy and drill ([OPS-01](03-operations.md)) | the `backup` service, by itself |
| before a large change is merged | `make mutation-diff` (the changed code), or `make mutation` (all code) when you want a full picture; where the owner chose mutation testing | the developer or the agent |
| when the gates fail on formatting or simple lint findings | `make fix`, then `git diff` and `make gates`; the agent runs it before it edits such things by hand | the developer or the agent |

The project's README carries the second table in its first section
([DOC-04](06-docs.md#doc-04-working-with-this-project-m)), without the rows that do not apply (no
[AI-05](05-agents.md) hook, no backup, no status service, no prod, no mutation testing), and `AGENTS.md` links to it,
so the agent follows it too.
