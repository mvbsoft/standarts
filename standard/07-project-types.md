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

A part of the column "Additionally mandatory" that the choices below list is strongly advised
([levels](README.md#how-to-read-it)): the owner may decline it.

<a id="the-core"></a>
#### The core

Every project has the core, and the owner is not asked about it:

- everything runs in Docker, and the host has only the tools of [PRN-01](01-principles.md);
- one compose file per environment, and dev always exists ([PRN-02](01-principles.md),
  [ENV-01](02-environments.md));
- the `make` targets and `scripts/project.sh`, one way of working in every project
  ([ENV-05](02-environments.md#env-05-make-targets-m), [PRN-10](01-principles.md));
- the Dockerfile stages `base`, `runtime` and `dev`, `.dockerignore` and the folder layout
  ([ENV-06](02-environments.md), [ENV-07](02-environments.md), [ENV-08](02-environments.md));
- `.env` readable by its owner only, and no secret in git ([PRN-04](01-principles.md));
- the registry, the README section "Working with this project" and `AGENTS.md`
  ([DOC-01](06-docs.md) to [DOC-04](06-docs.md), [AI-01](05-agents.md));
- the `pre-push` hook with `make gates`, and "done" meaning tests, docs and registry
  ([QLT-02](04-quality.md), [PRN-05](01-principles.md));
- the size limit of the container logs ([OPS-03](03-operations.md)).

When the profile has stage or prod, these come with them and are not asked either: images of the
same content ([PRN-03](01-principles.md), [ENV-02](02-environments.md)); the compose rule check
([ENV-03](02-environments.md)); deploy, rollback and restart through `make`
([ENV-09](02-environments.md)); third-party images pinned by digest; container limits and the
settings tuned to them ([OPS-02](03-operations.md)); the free-space warnings; and, when there is a
backup, a set right before each migration ([OPS-01](03-operations.md)).

<a id="the-choices"></a>
#### The choices

The parts below are the owner's choice; every rule or part not named in the core, the choices or
"A choice later" applies as its rule says. The agent asks about each part as a question, with what
it gives, an example and the risk without it ([`prompt/questions.md`](../prompt/questions.md)),
gives the default as its advice, and records the answer in registry section 0
([DOC-03](06-docs.md#doc-03-component-registry-m)). "Level" is the level the rule gives that part;
before the owner declines an M part, the agent explains the risk in detail. In "Can be declined",
"—" means the question asks for a fact or a value.

| ID | Part | Level | Default by type | Can be declined | Rule |
|---|---|---|---|---|---|
| S-01 | the project type and its languages | M | the agent finds them, the owner confirms | — | TYP-01 |
| S-02 | stage and prod | M | the table above ("Usual environments") | yes; whatever runs anywhere other than a developer machine keeps prod | [ENV-01](02-environments.md) |
| S-03 | the branches stage and prod deploy | M | `main` and `prod`, or other names | — | [ENV-09](02-environments.md) |
| S-04 | the size of the servers (CPU, memory) | as OPS-02 | "not known yet": the template's limits | — | [OPS-02](03-operations.md) |
| S-05 | a private dependency in the build | M | none | — | [ENV-09](02-environments.md) |
| S-06 | backups of the data (there is a data store) | M | with stage or prod: yes, strongly advised; dev only: no | yes, after the agent explains the risk | [OPS-01](03-operations.md) |
| S-07 | the backup folder on the server | M | `./docker/backup/data`, the folder the agent advises, or the owner's | — | [OPS-01](03-operations.md) |
| S-08 | the copy of the backups on another server | M | yes (a rest-server that only adds) | yes | [OPS-01](03-operations.md) |
| S-09 | the heartbeat of the backups (prod) | R | yes | yes | [OPS-01](03-operations.md) |
| S-10 | notifications of a failed backup | R | yes, when there is somewhere to send them | yes | [OPS-01](03-operations.md) |
| S-11 | linters (`LINT`) | M | the command the agent proposes | yes (`off`) | [QLT-01](04-quality.md) |
| S-12 | tests (`TEST`) | M | the command the agent proposes | yes (`off`) | [QLT-01](04-quality.md) |
| S-13 | end-to-end tests (`E2E`) | R | yes when there is a UI | yes (empty: `skip`; or `off`) | [QLT-01](04-quality.md) |
| S-14 | mutation testing | R | advised for logic; by hand, slow | yes (nothing of it is added) | [QLT-01](04-quality.md) |
| S-15 | the secret scan (`SECRETS`) | M | gitleaks | yes (`off`) | [QLT-01](04-quality.md) |
| S-16 | SAST and the dependency audit (`SECURITY`) | R (SAST), M (the audit) | the command the agent proposes | yes (empty: `skip`; or `off`) | [QLT-01](04-quality.md) |
| S-17 | health monitoring (the `status` service) | R | yes | yes | [OPS-04](03-operations.md) |
| S-18 | where the signals of monitoring go | R | not known yet: set up once a server exists | — | [OPS-04](03-operations.md) |
| S-19 | the archive of the logs of replaced containers | M | `.deploy/logs`, the folder the agent advises, or the owner's | yes (no archive) | [OPS-03](03-operations.md) |
| S-20 | the agent's hooks (the check after an edit, "no host tools") | R | yes | yes | [AI-05](05-agents.md), [AI-06](05-agents.md) |
| S-21 | language servers for the agent | R | yes | yes | [AI-07](05-agents.md) |
| S-22 | the browser for the agent (there is a UI) | R | yes | yes | [AI-08](05-agents.md) |
| S-23 | where the backlog lives | M | a file in the repository, or a tracker | — | [DOC-02](06-docs.md) |
| S-24 | the language of the documentation | M | the owner's language | — | [DOC-01](06-docs.md) |
| S-25 | an independent check of the work (an agent that made no change) | R | after each task and at the end | yes | [PRN-05](01-principles.md) |

#### A choice later

These are not asked yet and stay as their rules say, until tests prove that the skeleton works
without them ([D-0028](../decisions/0028-interactive-setup.md)): the compose rule check; stage and
prod of the same content; the backup set before a migration; the settings tuned to the limits where
OPS-02 makes them M; the image scan (`make image-scan`); CI, which the standard does not have yet
([known limits](README.md#known-limits)).
