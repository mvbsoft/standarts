# D-0003. Several environments and copies on one machine

> English · [Українська](0003-several-environments.uk.md)

**Status:** accepted · **Date:** 2026-10-18 · **Rules:** ENV-04

## Context

Dev and a stage or prod copy sometimes run on the same machine. Two stacks can collide on host ports, data and external networks, and a command meant for one environment can run in the clone of another. A second copy of the same environment, for example a git worktree for a parallel agent session or a second clone of stage, has the same `name:` as the first, so Compose treats both as one project: the second `make dev` or `make stage` recreates the first one's containers and shares its volumes, and no one can tell which copy runs or where the data is written.

## Decision

One environment is one clone of the repository in its own folder with its own `.env`. `PROJECT_ENV` in `.env` (`dev`, `stage` or `prod`) says which environment the clone runs, and the targets of the other environments refuse to run there. The different `name:` of each compose file separates containers, networks and named volumes; host ports and external network names come from `.env`.

A second dev copy needs no setting by hand. When `make dev` runs in a linked worktree without an `.env`, `make bootstrap` writes one with `DEV_SUFFIX` set to the folder name and a short hash of its path, so that worktrees with the same folder name in different places do not meet (the dev file has `name: <project>-dev${DEV_SUFFIX:-}`) and the `*_PORT` variables empty, so Docker picks free host ports and `make dev` prints them. Any other second clone gets the same with `make dev NAME=<n>`, and without it `make dev` refuses in a second plain clone. Stage and prod keep fixed names, and a machine runs one copy of each: `make stage`, `make prod` and the commands that work on a running stack refuse while containers of the project, stopped ones too, carry another folder in the label Compose gives them, with no setting that allows a second copy. Volumes carry no folder, so after `docker compose -p <project> down` nothing can tell whose they are; the first deploy of a clone that finds the volumes and no container warns and goes on.

Tested on 2026-10-18 (Docker Engine 29.7.2, Compose v5.5.0): `git rev-parse --path-format=absolute --git-dir` differs from `--git-common-dir` exactly in a linked worktree, and a worktree has no gitignored `.env`; a set-but-empty variable in `127.0.0.1:${APP_PORT-8000}:8000` gives no host port, so Docker publishes the container port on a free host port of its choice.

Measured on 2026-10-21 (Docker Engine 29.7.2, Compose v5.5.0; one-off run, with `tests/project` checking the refusals): every container carries the label `com.docker.compose.project.working_dir` with the folder of the first `-f` file, and volumes carry only the project and the volume name. An `up -d` from a second folder with the same `name:` recreated the containers whose configuration or relative bind mount differed and reused the others, so one project ended up with containers from two folders, and the named volume was shared; a stopped container of the first folder was started again by the second. After `down` without `-v` the volume stayed, and the second folder's new containers read the first one's data. The filter on the project label matches the exact value, so a dev copy with its own `DEV_SUFFIX` is a different project and is not refused. Compose takes the folder from the logical `$PWD` without resolving symlinks, so the script compares physical paths.

## Options considered

- **One clone, several `.env` files switched by hand.** Easy to start prod with dev data or the reverse.
- **One virtual machine per environment.** Strong isolation, but much heavier than needed.
- **A second copy configured by hand** (its own name and ports in `.env`). Works when remembered; when forgotten, the two copies silently share containers and data.
- **An override that allows a second stage or prod copy on one machine.** Rejected: the damage is silent and lands in the data, so a machine runs one copy of stage and one of prod, and the refusal has no bypass.

## Consequences

Stacks of different environments cannot write into each other's data or take each other's ports, and `make prod` cannot run in a dev clone. Prod secrets never sit in a development clone. Parallel sessions each get their own dev database, filled by `make seed`. Parity is not affected, because only the dev name changes. A second stage or prod copy on one machine is refused; the price is stopping the first copy in its folder before running the second, and a gap that only a warning covers (volumes left after `down`).

## Sources

- <https://docs.docker.com/compose/intro/compose-application-model/> — “A project's name, set with the top-level `name` attribute, is used to group resources together and isolate them from other applications or other installation of the same Compose-specified application”
- <https://docs.docker.com/compose/how-tos/networking/> — “When you run `docker compose up`, Compose creates a network named `<project-name>_default` and attaches all services to it.”
- <https://raw.githubusercontent.com/git/git/master/Documentation/git-rev-parse.adoc> — “--git-common-dir:: Show `$GIT_COMMON_DIR` if defined, else `$GIT_DIR`.”
- <https://raw.githubusercontent.com/git/git/master/Documentation/git-worktree.adoc> — “Within a linked worktree, `$GIT_DIR` is set to point to this private directory (e.g. `/path/main/.git/worktrees/test-next` in the example) and `$GIT_COMMON_DIR` is set to point back to the main worktree's `$GIT_DIR` (e.g. `/path/main/.git`).”
