# <project name> — rules for agents

<!-- project template 1.0.0 — a starting point (standard AI-01): up to ~200 lines; links, not copies. -->

This project follows the standard `<STANDARD_REPO>` at the release named in
[the registry](docs/reference/project-registry.md) (`Standard:`).

## Commands

- Everything runs in containers; on the host only the tools of standard PRN-01. Host
  exceptions, if any: [registry section E](docs/reference/project-registry.md).
- Which command to run in which situation, and when each check runs: the section
  [Working with this project](README.md#working-with-this-project) of the README. Use those `make`
  targets. A command no target covers (one test file, a linter on one file) runs in the dev
  container: `docker compose -f docker-compose.dev.yml exec -T dev <command>`; never on the host
  and never through another compose file.
- Do not run a command that does not end by itself: `make logs` follows the logs for ever,
  `make run` runs the application, and so do a watcher or `tail -f`. For logs run
  `make logs TAIL=200` (`S=<service>`: one service), which prints the last lines and ends; for the
  rest, ask the owner to run it in a terminal.

## Before you say a task is done

- Let the programs do what they can: `make fix` first (format, import order, the simple findings
  of the lint tools), then `git diff` to see what it changed, and fix by hand only what is left.
- Do not say a task is done until `make gates` is green, and put the summary it prints (one line
  per check) into your report. A finished task also needs `make verify` before it is merged.
- A change ships with its tests and the docs it affects; a new or removed component, a changed
  reason or backup status, or a new deviation updates the registry in the same commit.
- A migration must work with the previous release as well (`make rollback` runs no migration) and
  be safe to run twice. Remove or rename a column or a table only in a later release, after no
  running version uses it.

## Git

- Before any `git push`, run `git status`. If it lists uncommitted files, ask the owner in this
  session whether to commit them first or to push as it is, and push only after the answer: the
  gates check the working tree together with the commit, so what they pass may not be what is
  pushed.

## Destructive commands

- `docker compose down -v`, `docker volume rm`, `docker volume prune`, `git push --no-verify`,
  `make restore`, a push or merge into `<STAGE_BRANCH>` or `<PROD_BRANCH>` (the servers deploy what
  those branches hold) and deleting data, and a `make` command that goes on despite a warned
  estimate (`RISK=yes`), are run only after the owner's explicit yes in this session, for that
  command. A yes for one command is not a yes for the next. `make restore` asks
  a person for the database name; an agent has no terminal, so it adds `CONFIRM=yes` on the
  command line only after that yes.
- The exception is a proof copy that the standard's prompt sets up (`scripts/proof.sh`): inside
  it, a push to the copy's own bare remote (any branch, with or without uncommitted files),
  `git push --no-verify`, `make restore ... CONFIRM=yes` in its server clones, and changing or
  deleting the data of its own stacks and volumes (`DROP TABLE` in its clone, `proof.sh clean`,
  `docker compose down -v` there) need no question, because the remote and the data are the
  proof's own.
- Starting, stopping or updating stage or prod on a server is never done by you.

## Project rules

<only what is specific to this project: its domain terms, conventions, where things live.>
