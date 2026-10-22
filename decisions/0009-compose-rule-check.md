# D-0009. A script checks the compose rules

> English · [Українська](0009-compose-rule-check.uk.md)

**Status:** accepted · **Date:** 2026-10-18 · **Rules:** ENV-03

## Context

`make parity` only proves that stage and prod are the same. If both are wrong in the same way (a database port open to the world, a password with a default), parity is green.

## Decision

`make check-compose` renders each of the stage and prod files that exists from `.env.example` and checks the rules of ENV-01: ports, secrets, pins (a third-party image of the file is `<image>:<version>@sha256:<digest>`, and the version is not `latest`), non-root, healthchecks, restart, limits with `memswap_limit` equal to the memory limit, log rotation and container hardening, including `cap_add` only as an exception with its reason. It also fails on `build:` in stage or prod (`make stage` and `make prod` build the own images from the commit), checks that the project's own images are `<repo>-<name>:${IMAGE_TAG:?}` (`<repo>` is the file's `name:` without `-stage` / `-prod`) with a non-root `USER` in the `runtime` stage of their Dockerfile or in a stage it is built from, and checks every base image of those Dockerfiles (`FROM`, `COPY --from`, `RUN --mount … from=` and the `# syntax=` line of every stage, the `dev` stage included) for the same version and digest, except `scratch` and an earlier stage; an image named through a variable is refused, and the Dockerfile check has no exception. It accepts `depends_on` only with `service_healthy`: one-shot services are not used, because migrations are a `make` step ([D-0019](0019-migrations-make-step.md)). Without a `.env.example` it says so and fails, because it renders the files from it; it does not report a missing variable. It is a step of `make infra` (so of `make verify`) and of `make stage` / `make prod`. Deliberate exceptions live in the top-level `x-check-compose-allow` key with a reason, and the script prints them on every run. A project's own exception also has a row in registry section E; the ones the standard's own template carries (the root start of the `backup` service, [OPS-01](../standard/03-operations.md); the read-only socket proxy of the status service, [OPS-04](../standard/03-operations.md)) need none. The script is one template for every project.

## Options considered

- **Rely on the audit prompt.** Checks only when someone runs it.
- **Add it once a project has a server.** The rules would be checked only after they had already drifted.
- **KICS** (also hadolint, `trivy config`, Checkov). Compared on 2026-10-21 from the tools' documentation and query sources; none was run. KICS is the only one of them that reads Compose files, and it covers part of the rules (`docker.sock`, `privileged`, `cap_add`, healthcheck, limits, `no-new-privileges`). From its sources it reads the file as written, not rendered, it cannot express the stage and prod rules (own-image tags, `memswap_limit`, log rotation, `depends_on`, `${X:?}` secrets), and its restart query, “Restart Policy On Failure Not Set To 5”, wants a count of 5 where ENV-01 wants `always`. Using it next to the script would add a second tool and a second exception list.
- **`trivy config`, hadolint.** They read Dockerfiles only; trivy's table marks Compose “-”. A Dockerfile lint beyond the `USER` and pin checks is `docker build --check` in `make lint` ([D-0026](0026-quality-tools.md)); `trivy config` on the Dockerfiles can be added later, with the trivy already in the dev image.

## Consequences

The rules the script lists (ENV-03) are enforced by a machine, not by memory; the rest of the environment table is checked by the audit. Compose on a server cannot build an image from the clone's folder, and an own image always carries the tag of a commit's content; own images are built only by `make stage` / `make prod`, from the committed files ([D-0025](0025-images-built-on-the-server.md)). The host still needs only docker and sh; the checks run in a python image pinned by version and digest. Since check-compose 4.0.0 a third-party image without a digest, in a compose file or in the Dockerfile of an own image, fails the check.

## Sources

- <https://docs.docker.com/engine/network/packet-filtering-firewalls/> — “Packets are routed before the firewall rules can be applied, effectively ignoring your firewall configuration.”
- <https://docs.kics.io/latest/queries/dockercompose-queries/> — the query “Restart Policy On Failure Not Set To 5”.
- <https://trivy.dev/docs/latest/coverage/iac/docker/> — “It supports the following configurations.”; the table lists Dockerfile and Containerfile with a check and Compose with “-”.
- <https://docs.docker.com/build/checks/> — “Instead of executing the build steps, this command only runs the checks and reports any issues it finds.”
