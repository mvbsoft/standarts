# Project types

> Version 1.0.0-draft · English · [Українська](07-project-types.uk.md)

### TYP-01. What is added and what is dropped by type (M)

The project type and its environments are recorded in the registry profile ([DOC-03](06-docs.md)).
The agent proposes the environments from the table below, the owner confirms them once, and an
update does not ask again. Whatever runs anywhere other than a developer machine has prod
([ENV-01](02-environments.md)). If the profile lists stage or prod, those files are complete and
proven in a proof copy on the developer machine before a server exists (a temporary local copy with
its own bare repository and server clones: [`prompt/start.md`](../prompt/start.md), section 3);
only what depends on a real server (TLS, the domain, the off-server backup target) waits, with the
trigger "the server exists" in registry section E.

All other rules of the standard apply to every type. A repository may have several types; it takes
the additional items of each, and an item is dropped only if no type of the repository requires it.

| Type | Usual environments | Additionally mandatory | Does not apply |
|---|---|---|---|
| Service with a database (backend, API) | dev, stage, prod | backups, migrations, tests against a real database | — |
| Frontend | dev, stage, prod (dev only if it is never deployed) | browser end-to-end tests, an API client generated from OpenAPI | database backups, migrations |
| Pipeline or agents that run untrusted code | dev, prod (+ stage when others depend on it) | isolation of untrusted code (a separate container, uid, capabilities), hand-written mutants for security checks | — |
| Library or plugin (for example, a Claude Code plugin) | dev | — (a library that publishes versions adds its own target for it in the `Makefile` block "Project targets", [ENV-05](02-environments.md#env-05-make-targets-m)) | `docker-compose.stage.yml`, `docker-compose.prod.yml`, backups, tuning to resources, the proof of a running service (its proof is `make gates`); `make image-scan` and the deploy targets stay in the `Makefile` but refuse ([ENV-05](02-environments.md#env-05-make-targets-m)) |
| ML | dev; prod when the model is served | separate heavy images, `deploy.resources` for GPU and memory | — |

Recommended additions are not listed in the table; the agent asks the owner when the standard is
applied and records the answer in the registry. For a Frontend project (any project with a UI) one
of them is the browser for the agent ([AI-08](05-agents.md)).
