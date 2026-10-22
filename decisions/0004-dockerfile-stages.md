# D-0004. Dockerfile stages: base, runtime, dev

> English · [Українська](0004-dockerfile-stages.uk.md)

**Status:** accepted · **Date:** 2026-10-18 · **Rules:** ENV-08

## Context

Development needs linters, type checkers and language servers; production must not contain them. Two unrelated Dockerfiles drift apart in language version and libraries.

## Decision

One Dockerfile per service with three stages: `base` (pinned language and production libraries), `runtime` (base + code, non-root user, start command; the image that goes to stage and prod) and `dev` (base + development tools, never the code). Dev builds `target: dev` and gets the code only from the mount; `make stage` and `make prod` build `target: runtime` on the server ([D-0025](0025-images-built-on-the-server.md)). Libraries are installed before the code is copied, and only `runtime` copies it. The exception is the template's two service images, `backup` and `status`, tools that run the scripts of their own image and mount no code: their `dev` stage is their `runtime`, which copies only their own scripts (`docker/backup/*.sh`, `docker/status/status.py`).

## Options considered

- **Separate dev and prod Dockerfiles.** Simple to read, but versions drift and nothing proves that dev matches prod.
- **Tools on the host, only services in containers.** Breaks PRN-01.
- **`dev` built from `runtime`.** Dev would have the start command and the user of the image that runs, but `runtime` copies the code, so every code change rebuilds `dev`, and `make dev`, `make gates` and the pre-push hook run `up --build`.

## Consequences

Dev and prod share the language version and libraries by construction; a code change does not reinstall the libraries of `base`, and does not rebuild the dev image, which holds no code: it is rebuilt only when `base`, its tools or the lock file change. Measured on 2026-10-19 on the Python sample of `tests/stacks` (one-off run, not repeated by a test), the rebuild of the dev image after a code change: 27.1 s with `dev` built from `runtime` and the tools installed in it (which also needs the network), 21.4 s with the tools copied from a tools stage, 0.9 s with `dev` built from `base` with no code. A stage that only prepares tools for `dev` to copy is allowed. The `backup` dev image, measured the same day (one-off run) on the template's `docker/backup/Dockerfile`: after a change to the application's code every build step was cached, and the image kept its creation time and layers.

Since 2026-10-21 `tests/stacks` checks the claim on the three samples: after a change to the code the dev image keeps its `Created` time and its layers, and a change to the code that `COPY`s into the dev stage fails the test. It compares `Created` and the layers and not the image ID, because with the containerd image store the ID is the digest of the image index, which holds a provenance attestation that is new on every build: measured on 2026-10-21 (Docker Engine 29.7.2, one-off run), the same cached build twice gave the IDs `2866f700…` and `9db98048…` with the same `Created`, the same 9 layers and the same platform manifest `99fa5121…`.

## Sources

- <https://docs.docker.com/build/building/multi-stage/> — “You can selectively copy artifacts from one stage to another, leaving behind everything you don't want in the final image.”
- <https://github.com/compose-spec/compose-spec/blob/main/build.md> — “`target` defines the stage to build as defined inside a multi-stage `Dockerfile`.”
- <https://docs.docker.com/build/cache/optimize/> — “By installing dependencies in earlier layers of the Dockerfile, there is no need to rebuild those layers when a project file has changed.”
