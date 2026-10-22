# D-0002. Stage and prod files differ only in `name:`

> English · [Українська](0002-stage-prod-parity.uk.md)

**Status:** accepted · **Date:** 2026-10-18 · **Rules:** PRN-03, ENV-02

## Context

Stage exists to prove what prod will run. If the two files drift (a different limit, user or service), a green stage proves nothing about prod.

## Decision

Stage and prod are two complete files that differ only in the `name:` line; everything that may differ comes from the server `.env`. [ENV-02](../standard/02-environments.md#env-02-stage--prod-parity-m-if-there-are-stage-and-prod) lists what may differ through `.env` (such as secrets, sizes, the log level, ports) and what may not and stays literal in the files (images and versions, the set of services, commands, the user, healthchecks). `make parity` renders both files with `docker compose config --no-interpolate` under one project name (so `name:` and the names derived from it are equal) and fails on any other difference (it compares before the variables are filled in, so keeping the second list out of `.env` is a rule of the project). It is a step of `make infra` and of `make stage` / `make prod`, before anything starts.

## Options considered

- **One shared file plus per-server overrides.** Less text, but the real prod configuration exists only after merging, and reviews miss what the merge changes.
- **Two files compared by a person.** Works until someone forgets.

## Consequences

Drift fails `make infra` and is caught before every deploy. The price is keeping two nearly identical files, which the check makes cheap.

## Sources

- <https://12factor.net/dev-prod-parity> — “all deploys of the app (developer environments, staging, production) should be using the same type and version of each of the backing services.”
- <https://raw.githubusercontent.com/docker/compose/main/docs/reference/compose_config.md> — “`docker compose config` renders the actual data model to be applied on the Docker Engine.”
- <https://raw.githubusercontent.com/docker/compose/main/docs/reference/compose_config.md> — `--no-interpolate`: “Don't interpolate environment variables”
