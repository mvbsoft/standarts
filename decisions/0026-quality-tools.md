# D-0026. Quality tools: a named default per category, pinned, and offline in the gates

> English · [Українська](0026-quality-tools.uk.md)

**Status:** accepted · **Date:** 2026-10-20 · **Rules:** QLT-01, QLT-02

## Context

The projects checked code with different tools, some pinned and some not, some needing the network in a step that must work offline. A gate that downloads something on first use fails without network, and a gate whose version floats turns red on a day nobody changed the code. The usual tools also change: in 2026 TypeScript 7 shipped without a compiler API, ESLint 10 dropped `.eslintrc`, `qossmic/deptrac` became `deptrac/deptrac`, gitleaks went to security fixes only, and malicious trivy releases were published with compromised credentials.

## Decision

QLT-01 sets categories and names the usual tool per language (its table is the one list of names); each was chosen because it is maintained, runs offline once installed (for `gates`), and has an exact pin in the lock file or the image. The versions and the reasons for them are here, so that updating a tool does not change a rule.

TypeScript is pinned at 6.0.x for everything, the compiler and the tools alike, until typescript-eslint supports TypeScript 7: TypeScript 7 has no compiler API yet, and typescript-eslint 8.71.2 accepts TypeScript below 6.1. ESLint 10 reads only the flat config (`eslint.config.js`). The PHP package is `deptrac/deptrac`, which replaces the abandoned `qossmic/deptrac`.

Documentation links are checked by lychee with `--offline`: it checks the links inside the repository and makes no network request, so it runs in `gates`, not in `verify`. External links are not checked.

Network tools (pip-audit, npm audit, composer audit, trivy) run only in `verify` and `image-scan`. `uv audit` replaces pip-audit when it leaves preview; in uv 0.13.1 it is still a preview feature. pip-audit reads an export of `uv.lock` (`uv export --format pylock.toml`), because it cannot read `uv.lock` itself. semgrep runs with `--metrics off` and reads its rules from files in the project; a project never ships copies of Semgrep-maintained registry rules.

Every tool has an exact version. A tool taken into the image as a binary or from another image (such as gitleaks, lychee, trivy) is pinned by version and by image digest or checksum, so a re-pushed tag cannot change it. trivy is 0.72.0 or later: 0.72.0 fixes a path traversal in its plugin manager (GHSA-8rc5-4fr6-64pw, CVE-2026-63328), and that excludes 0.69.4 to 0.69.6, the releases and Docker Hub images published with compromised credentials in March 2026 (GHSA-69fq-xp46-6x23, CVE-2026-33634). pyright is installed with its `nodejs` extra, so its first run downloads no Node.js.

`gitleaks dir` scans the files of a folder, not of git, so it also reads the ones git ignores (the local `.env`, caches, build output; seen while building the samples, 2026-10-21). A project gives it an allowlist of those in `.gitleaks.toml`; the samples of `tests/stacks` have one.

`make lint` also checks the Dockerfile of every own image with `docker build --check`, on the host before the tools of `LINT` (level R). It needs no new tool: Docker's own checks, Buildx 0.15.0 or later. It reads the Dockerfile and the metadata of its base images, and builds nothing. It runs also when `LINT` is `off`: the `lint` line of the summary then shows `off` (`LINT = off; dockerfile-check: OK`) and shows `FAIL` only if the Dockerfile check fails. The check itself is skipped only by `DOCKERFILE_CHECK = off` in the settings.

`make fix` runs each tool's fixer in its safe mode, by hand only. ruff: `ruff format` and `ruff check --fix --no-unsafe-fixes`; ruff applies only safe fixes by default, a project that sets `unsafe-fixes = true` would change what a plain `--fix` does, and the flag on the command line overrides that setting (it cannot undo `extend-safe-fixes`). prettier: `--write`; its first requirement is the same behaviour as before. eslint: `--fix` applies fixes, never suggestions; the safety of a fix is a guideline for rule authors, not enforced, and `--fix` may also delete a now-unneeded `eslint-disable` comment (derived from ESLint's source, not run). php-cs-fixer: `fix --allow-risky=no`, so a config that allows risky rules does not change `make fix`. rector stays `--dry-run`. None of the tools promises that behaviour is unchanged (the docs say "intended", "meant"), which is why `make fix` is followed by `git diff` and `make gates`.

## Options considered

- **Black + flake8 + mypy for Python.** Three tools where ruff and pyright are two; pyright is 3–5× faster on large code bases by its own account. mypy stays an allowed choice for a project that needs a mypy plugin.
- **ty instead of pyright.** Faster, but in beta with no stable diagnostics.
- **`uv audit` now.** One tool less, but a preview feature may change between uv versions.
- **mutmut instead of cosmic-ray.** Simpler, but it remembers its own earlier work and re-tests the functions whose source changed, not the lines changed against a git branch, and needs `fork`; `make mutation-diff` needs cosmic-ray's `cr-filter-git`.
- **Biome instead of prettier + eslint.** One fast tool, but 97% Prettier-compatible by its own account, and its coverage of the typed and react-hooks rules was not checked. Allowed through the registry.
- **Opengrep instead of Semgrep CE.** An LGPL fork with more taint analysis in the open engine; allowed through the registry.
- **Betterleaks instead of gitleaks.** The successor by the same authors; its v2 is not stable yet.
- **TypeScript 7 for `tsc`, TypeScript 6 for the tools** (the npm alias the TypeScript 7 announcement suggests). Faster type checks, but two TypeScript packages in one project; one version is simpler.
- **A link-check script in each project.** Every project writes and keeps the same script; lychee is one pinned binary.
- **lychee with the network.** It would check external links too, but a network check cannot be a gate, and an external page that is down would turn it red.
- **hadolint for the Dockerfiles.** It also lints the shell in `RUN`, but it is GPL-3.0 and one more image; `docker build --check` needs nothing new. `trivy config` on the Dockerfiles, with the trivy already pinned, can follow later.
- **`ruff check --fix --unsafe-fixes`, or php-cs-fixer with risky rules, in `make fix`.** More is fixed at once, but the meaning of the code can change.
- **rector in `make fix`.** It refactors code (its PHP 8.2 set decorates classes `readonly`, for one), so its changes are read as a diff, which is what `--dry-run` shows.
- **`eslint --fix --fix-type layout`.** The safest, as layout fixes keep the program structure, but with typescript-eslint's `recommended` rules the sample has no layout rule, so it would fix nothing.

## Consequences

LINT, TEST and SECRETS are meant to run without network, and the samples prove it: `tests/stacks` runs `make gates` with the dev container on `network_mode: none`. A version moves only through a reviewed change of a lock file or a Dockerfile. Upgrading phpstan with `max`, or ruff across a minor version, can add work; that is the cost of exact pins. The Dockerfile check runs on the host; when a base image is not local it reads the image's metadata from the registry (not run offline). TypeScript projects stay on 6.0.x although TypeScript 7 is out. Watch points: `uv audit` leaving preview, typescript-eslint supporting TypeScript 7 (after TypeScript 7.1 ships an API), and pcov on new PHP versions. gitleaks stays; look again when Betterleaks v2 is stable.

## Verified

Checked on 2026-10-19, Docker Engine 29.7.2 (Docker Desktop, WSL 2), Compose v5.5.0, with `tests/stacks/run.sh` (`make check-stacks`) on a Python, a PHP (8.2.33) and a TypeScript (Node.js 22.23.3) sample built from `templates/project`, with the tools pinned in each sample: ruff 0.17.1, pyright 1.1.414 (`pyright[nodejs]`), pytest 9.1.1; php-cs-fixer 3.95.27, phpstan 2.3.1, rector 2.7.0, phpunit 11.5.57; typescript 6.0.3, eslint 10.13.0, typescript-eslint 8.71.2, prettier 3.9.10, vitest 5.0.5.
- `make gates` in the dev container runs format check, lint, types and tests of each sample: `ruff format --check`, `ruff check`, pyright strict, pytest; `php-cs-fixer check`, phpstan at level max, `rector process --dry-run`, phpunit; `prettier --check`, eslint with `eslint.config.js` and typescript-eslint, `tsc` with `strict` and `noUncheckedIndexedAccess`, `vitest run`. It is green on the clean sample and red on a planted lint error with the tool's message (ruff `F401`, phpstan `undefined_function`, eslint `no-unused-vars`).
- typescript-eslint 8.71.2 works with TypeScript 6.0.3 and ESLint 10.13.0 with a flat config.
- Outside the test (one-off run, 2026-10-19), pyright 1.1.414 from `pyright[nodejs]` checked a file in the Python dev image with `--network none`.
- trivy: `tests/project/run.sh` with `STDTEST_TRIVY=1` puts trivy 0.75.0, pinned by digest, into the sample's dev image, and `make image-scan` scans the saved own images with it (the test checks the scan lines of `app` and `backup`, not of `status`); without that variable the test uses a stand-in trivy and proves the refusal when the dev image has none.
- shellcheck v0.11.0, pinned by digest, lints this repository's own scripts in `make lint`.

Checked on 2026-10-21 with `tests/stacks/run.sh`, after the samples' LINT gained shellcheck and lychee and their SECRETS gained gitleaks (gitleaks v8.30.1, ShellCheck 0.11.0, lychee 0.24.2, each copied into the dev stage from an image pinned by digest; lychee needs the CA bundle even with `--offline`):
- `make gates` is green on each clean sample with the `ok` summary lines for lint, test and secrets, and red with a `FAIL` line on a planted lint error, on a shell script shellcheck rejects (`SC2086`), on a planted secret (`github-pat`) and on a broken link of the documentation (lychee `--offline`). A red gate after a code change leaves the dev image as it was (the same creation time and layers; the image ID changes on every build under the containerd image store, because the index holds a new provenance attestation).
- `make gates` is green with the dev container on `network_mode: none` (the image must already be built); in a one-off run (2026-10-21) a mutation that made TEST open a network address turned it red there; the test does not repeat that.
- `make fix` undoes spoiled formatting on each sample: afterwards `git status` shows no change and `make gates` is green.
- `make lint` passes `docker build --check` on the samples' Dockerfiles (`Check complete, no warnings found.`). `tests/project/run.sh` proves that a Dockerfile with a finding (`FROM base as runtime` among stages written with `AS`) makes lint FAIL.
- Timing (one-off, 2026-10-21): `make gates` took 13.0 to 13.7 s on the three samples.

Not checked: semgrep; pip-audit, npm audit and composer audit; psalm; import-linter, deptrac, eslint-plugin-boundaries and dependency-cruiser; eslint-plugin-react-hooks; schemathesis and Playwright; the mutation tools (`tests/project/run.sh` runs `make mutation` with a stand-in command); coverage tools and pcov on PHP 8.5; hypothesis and fast-check; the host-side Dockerfile check without network; whether `ruff format`, import sorting or any fixer changes behaviour (the tools' own documents give "intended", not a guarantee).

## Sources

- <https://devblogs.microsoft.com/typescript/announcing-typescript-7-0/> — “While TypeScript 7.0 is here, it does not ship with an API.”
- <https://registry.npmjs.org/@typescript-eslint/eslint-plugin> — version 8.71.2, `peerDependencies.typescript`: “>=4.8.4 <6.1.0”
- <https://raw.githubusercontent.com/eslint/eslint/main/docs/src/use/migrate-to-10.0.0.md> — “Starting with ESLint v10.0.0, the old configuration format is no longer supported.”
- <https://raw.githubusercontent.com/RobertCraigie/pyright-python/main/README.md> — “If it is not, then we download node at runtime using nodeenv, then install the pyright npm package using `npm`”; “It's highly recommended to install `pyright` with the `nodejs` extra”
- <https://raw.githubusercontent.com/microsoft/pyright/main/docs/mypy-comparison.md> — “It is not unusual for pyright to be 3x to 5x faster than mypy when type checking large code bases.”
- <https://raw.githubusercontent.com/astral-sh/ty/main/README.md> — “ty is currently in beta.”
- <https://raw.githubusercontent.com/astral-sh/ruff/main/docs/formatter.md> — “The Ruff formatter is an extremely fast Python code formatter designed as a drop-in replacement for Black”
- <https://raw.githubusercontent.com/prettier/prettier/main/docs/install.md> — “Even a patch release of Prettier can result in slightly different formatting”
- <https://raw.githubusercontent.com/biomejs/biome/main/packages/@biomejs/biome/README.md> — Biome “scores 97% compatibility with Prettier”
- <https://getrector.com/documentation> — “To see preview of suggested changed, run process command with --dry-run option”
- <https://raw.githubusercontent.com/rectorphp/rector/main/README.md> — “Rector will show you diff of files that it *would* change. To *make* the changes, drop `--dry-run`”
- <https://raw.githubusercontent.com/rectorphp/rector-src/main/rules/Php82/Rector/Class_/ReadOnlyClassRector.php> — “Decorate read-only class with `readonly` attribute”
- <https://repo.packagist.org/p2/qossmic/deptrac.json> — `"abandoned": "deptrac/deptrac"`
- <https://raw.githubusercontent.com/vimeo/psalm/6.x/docs/security_analysis/index.md> — “You can enable this mode with the `--taint-analysis` command line flag.”
- <https://docs.astral.sh/uv/concepts/preview/> — “The uv audit and uv tool audit commands check project and installed-tool dependencies for known vulnerabilities.” (listed among the preview features)
- <https://astral.sh/blog/uv-audit> — “Both of these features are in preview for now. They're considered unstable and there may be breaking changes as we iterate on their design.”
- <https://raw.githubusercontent.com/pypa/pip-audit/main/README.md> — “At the moment, only `pyproject.toml` and `pylock.*.toml` are supported.”
- <https://semgrep.dev/docs/licensing> — “They are available only for internal business use.”
- <https://semgrep.dev/docs/metrics> — “`--metrics off` : metrics are never sent”
- <https://semgrep.dev/docs/semgrep-code/semgrep-pro-engine-intro> — “Semgrep Community Edition (CE), can only analyze interactions within a single function”
- <https://raw.githubusercontent.com/opengrep/opengrep/main/README.md> — “Welcome to Opengrep, a fork of Semgrep, under the LGPL 2.1 license”
- <https://raw.githubusercontent.com/gitleaks/gitleaks/master/README.md> — “Future releases will be security patches only.”
- <https://raw.githubusercontent.com/betterleaks/betterleaks/main/README.md> — “Until the first stable v2 release, package managers and the Docker `latest` tag may still provide v1.”
- <https://github.com/advisories/GHSA-69fq-xp46-6x23> — “On March 19, 2026, a threat actor used compromised credentials to publish a malicious Trivy v0.69.4 release”; not affected: “trivy images referenced by digest.”
- <https://api.github.com/advisories/GHSA-69fq-xp46-6x23> — the advisory's `cve_id` field: `CVE-2026-33634`
- <https://api.github.com/repos/aquasecurity/trivy/security-advisories> — GHSA-8rc5-4fr6-64pw, “Path Traversal in Trivy Plugin Manager Allows Arbitrary File Write”, fixed in 0.72.0
- <https://api.github.com/advisories/GHSA-8rc5-4fr6-64pw> — CVE-2026-63328; “Fixed in Trivy `0.72.0`. Users should upgrade to that release or later.”
- <https://raw.githubusercontent.com/lycheeverse/lychee/master/README.md> — “`--offline` Only check local files and block network requests”
- <https://docs.docker.com/build/checks/> — “Instead of executing the build steps, this command only runs the checks and reports any issues it finds.”; “Buildx version 0.15.0 and later”
- <https://github.com/hadolint/hadolint> — “GPL-3.0 license”
- <https://raw.githubusercontent.com/sixty-north/cosmic-ray/master/docs/source/how-tos/filters.rst> — “The `cr-filter-git` filter looks for edited or new lines from the given git branch.”
- <https://raw.githubusercontent.com/boxed/mutmut/main/README.rst> — “Between runs, mutmut only re-tests mutants in functions whose source changed.”; “Mutmut must be run on a system with `fork` support.”
- <https://pecl.php.net/rest/r/pcov/1.0.12.xml> — `<da>2024-12-04 09:09:53</da>`, “- PHP 8.4 compatibility”
- <https://raw.githubusercontent.com/astral-sh/ruff/main/docs/linter.md> — “Ruff only applies safe fixes by default.”; “Specifically, an unsafe fix could lead to a change in runtime behavior, the removal of comments, or both”; “The safety of fixes can be adjusted per rule using the lint.extend-safe-fixes and lint.extend-unsafe-fixes settings.”
- <https://raw.githubusercontent.com/astral-sh/ruff/main/crates/ruff/src/args.rs> — `--unsafe-fixes`: “Include fixes that may not retain the original intent of the code. Use `--no-unsafe-fixes` to disable.”
- <https://docs.astral.sh/ruff/settings/#unsafe-fixes> — “Enable application of unsafe fixes.”
- <https://raw.githubusercontent.com/prettier/prettier/main/docs/rationale.md> — “The first requirement of Prettier is to output valid code that has the exact same behavior as before formatting.”
- <https://raw.githubusercontent.com/eslint/eslint/main/docs/src/use/core-concepts/index.md> — “Fixes safely correct the violation without changing application logic.”; “Suggestions may change application logic and so cannot be automatically applied.”
- <https://raw.githubusercontent.com/eslint/eslint/main/docs/src/extend/custom-rules.md> — “Avoid any fixes that could change the runtime behavior of code and cause it to stop working.”
- <https://raw.githubusercontent.com/eslint/eslint/main/docs/src/use/command-line-interface.md> — `--fix-type`: “`layout` - apply fixes that do not change the program structure (AST)”
- <https://raw.githubusercontent.com/PHP-CS-Fixer/PHP-CS-Fixer/master/doc/usage.rst> — “A rule is considered risky if it could change code behaviour. By default no risky rules are run.”
