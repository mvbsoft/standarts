# Principles

> Version 1.0.0-draft · English · [Українська](01-principles.uk.md)

## Axioms

### PRN-01. Everything runs in Docker (M)

A project comes up on a bare server from containers. The host has only the tools below. This is
the one list of host tools: other documents point here instead of repeating it.

| Tool | Developer machine | Server (stage, prod) |
|---|---|---|
| Docker Engine 25.0 or newer (the healthchecks use `start_interval`) and the Docker Compose plugin (`docker compose`), tested with Compose v5.5.0 | yes | yes |
| Docker Buildx, for builds that use build secrets or `RUN --mount`; 0.15.0 or newer where `make lint` runs `docker build --check` | yes | yes |
| `git` 2.31 or newer (the scripts use `git rev-parse --path-format`) | yes | yes |
| `make`, POSIX `sh`, `ps` from procps, `stat` from GNU coreutils and `tar` (`sh` runs the `make` targets, the hooks and the language-server launcher) | yes | yes |
| the coding agent (Claude Code, the one supported so far, [05-agents](05-agents.md)); Node.js, only if a global Claude Code plugin requires it | yes | no |
| `gh`, for GitHub pull requests and issues (O; no template or prompt calls it) | if used | no |

Anything else that runs on the host is an exception under [PRN-09](#prn-09-exceptions-m), recorded
in section E of the registry with its reason.

Sources of the minimum versions: the Dockerfile reference, “This option requires Docker Engine version 25.0 or later.” ([start interval](https://docs.docker.com/reference/dockerfile/#healthcheck)); the Docker build checks page, “Buildx version 0.15.0 and later” ([checks](https://docs.docker.com/build/checks/)); the Git 2.31.0 release notes, “`git rev-parse` can be explicitly told to give output as absolute” or relative “with the `--path-format=(absolute|relative)` option” ([notes](https://raw.githubusercontent.com/git/git/master/Documentation/RelNotes/2.31.0.adoc)).

### PRN-02. One file, one environment (M)

`docker-compose.dev.yml` is dev, `docker-compose.stage.yml` is stage, `docker-compose.prod.yml` is
prod; `docker-compose.<role>.yml` is for special roles (for example `agents`). There is no
default-named file (`compose.yaml`, `compose.yml`, `docker-compose.yaml`, `docker-compose.yml`) and
no `*.override.*` file, neither in the repository nor in its parent folders, so a bare
`docker compose up` fails and starts nothing. A file is chosen only by an explicit `-f`; people do it
through `make`. `COMPOSE_FILE`, `COMPOSE_PROJECT_NAME` and `COMPOSE_PROFILES` are set nowhere: not
in `.env`, not in `.env.example`, not in a shell profile (`COMPOSE_PROJECT_NAME` beats the file's
`name:`, `COMPOSE_PROFILES` starts services a profile keeps off, `COMPOSE_FILE` picks a file
whenever `-f` is left out). Every file has its own `name:`.

### PRN-03. Stage and prod run images of the same content (M)

Code is baked into the image. Every own image of the project is built on the server that runs it,
by `make stage` / `make prod`, from the committed files of the deployed commit, and tagged with the
git tree hash of that commit; there is no image registry
([ENV-09](02-environments.md#env-09-ship-deploy-and-roll-back-m-if-there-is-stage-or-prod),
[D-0025](../decisions/0025-images-built-on-the-server.md)). Commits with the same content have the
same tree hash, so a server builds an image once and reuses it. Stage and prod build the same
content: every third-party image of the stage and prod files and every base image in the
Dockerfiles of the own images is pinned by version and digest, which `make check-compose` checks
([ENV-03](02-environments.md#env-03-compose-rule-check-m-if-there-is-stage-or-prod)), and
dependencies are installed from lock files. That keeps the two builds equal in content, though not
byte for byte: packages a build installs from the operating system's repositories can still differ
([known limits](README.md#known-limits)). Stage and prod differ only in configuration, through the
server's env file.

### PRN-04. Fail closed (M)

Secrets have no default values (`${X:?}`). A server's `.env` and a build-secret file can be read by
their owner alone, and a deploy refuses otherwise. A healthcheck checks the service with
authentication. Gates are not green when they did not run.

### PRN-05. Done means tests, docs and registry (M)

A change ships with its tests and the docs it affects. A change that adds or removes a component
or a tool, changes why it is there, changes what is backed up, changes an answer of the owner, or
adds a deviation updates the component registry (`docs/reference/project-registry.md`,
[DOC-03](06-docs.md#doc-03-component-registry-m)) in the same commit. A version bump changes only
the file that holds the version.

### PRN-06. Nothing "just in case" (M)

A tool is added only for a named problem, and that problem is recorded in the registry.

## Repository and machine

### PRN-07. The repository is self-contained (M)

A clone of the repository, Docker and `make bootstrap` are enough for everything to work in any
folder on any machine. Files in git contain no paths into neighbouring repositories
(`../other-repo/…`) and no absolute machine paths (`/home/…`, `C:\…`), and scripts do not call
another repository's code directly. Anything shared between repositories travels only by version:
a tagged Docker image, a package in a lock file, or a plugin from a git source. If the dev box needs
to read a neighbouring repository's code, a variable in `.env` gives its path, and the project still
starts without it.

### PRN-08. What is global and what is per project (M)

| Global (machine or account) | Per project |
|---|---|
| global Claude Code plugins; `~/.claude/CLAUDE.md`; permission mode, model, effort; marketplaces as git sources, not absolute paths into someone else's repository; the host tools from PRN-01 | compose files, Dockerfiles, `Makefile`, lock files, `.env.example`; project skills, commands and hooks; pinned `enabledPlugins`; the registry |
| nothing project-specific: no `~/.claude/skills/` for one repository | nothing machine-specific: no absolute paths in git files; a working-folder path only as a variable with a default |

### PRN-09. Exceptions (M)

An exception to the standard is allowed only when all of these hold:
1. it is recorded in section E of the registry with its reason;
2. there is an ADR if the exception changes an architectural decision;
3. it states what removes it (an event or a date).

Host exceptions are listed only there; `AGENTS.md` links to that section instead of repeating it.
A part the owner declined when the standard was applied is not an exception: its answer is in
registry section 0 ([DOC-03](06-docs.md#doc-03-component-registry-m)).
"It has always been this way" is not a reason.

### PRN-10. Every project is worked the same way (M)

Whatever the language, every project is set up, developed, checked, shipped, deployed and rolled
back with the same `make` targets ([ENV-05](02-environments.md#env-05-make-targets-m)), and its
README starts with the same section that says which command to run in which situation
([DOC-04](06-docs.md#doc-04-working-with-this-project-m)). Someone who knows one project knows how to
work with every other; what differs between projects lives in a few named settings, never in a
different way of working.
