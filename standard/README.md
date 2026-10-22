# Standard

> Version 1.0.0-draft · English · [Українська](README.uk.md)

One standard for how projects are organised, whatever the language. It fixes **principles, rules
for choosing and the way things are described**, not specific packages. The English version is the
primary one; the Ukrainian version is its translation, updated in the same commit.

## How to read it

Every rule is a heading with an identifier and a level, for example `ENV-02 … (M)`. Identifiers never
change, so a project registry, a decision or a report can point at a rule.

| Mark | Meaning |
|---|---|
| **M** | mandatory |
| **R** | recommended; declining it is recorded in the registry with a reason |
| **O** | optional |

## Sections

| File | Contents |
|---|---|
| [01-principles](01-principles.md) | axioms, self-contained repositories, global versus project, exceptions, one way of working (`PRN`) |
| [02-environments](02-environments.md) | dev, stage, prod, compose, `make`, folders, Dockerfile, deploy (`ENV`) |
| [03-operations](03-operations.md) | backups, tuning to resources, logs, health monitoring (`OPS`) |
| [04-quality](04-quality.md) | quality tools by category, gate rules, when each check runs (`QLT`) |
| [05-agents](05-agents.md) | rules for any agent, and the Claude Code adapter: skills, plugins, hooks, language servers (`AI`) |
| [06-docs](06-docs.md) | documentation, backlog, component registry, the README section (`DOC`) |
| [07-project-types](07-project-types.md) | what is added or dropped by project type (`TYP`) |

Per-technology tuning and backup notes live in [`catalog/`](../catalog/). Files a project receives,
verbatim or as starting points, live in [`templates/`](../templates/README.md). Why each decision
was made lives in [`decisions/`](../decisions/).

## Known limits

The standard has the limits below for now. We are working on them and deciding how best to
implement each. Meanwhile the agent or the person applying the standard can solve any of them in
their own project; a solution that departs from a rule is recorded as a deviation
([PRN-09](01-principles.md#prn-09-exceptions-m)).

- **Data loss of up to about a day.** Backups are daily dumps ([OPS-01](03-operations.md)), so a
  server lost just before the next dump loses what was written since the last one, and the
  off-server copy has the same gap. Backing up the database log continuously is a later addition.
  *You can:* run `make backup` before a risky change; add continuous log archiving yourself.
- **Secrets are plain text in `.env` on the server.** Whoever can read that file as its owner or as
  root reads every secret; the deploy only refuses when other users of the machine can
  ([PRN-04](01-principles.md#prn-04-fail-closed-m)). Encrypting `.env` or using a secret store is a
  later addition. *You can:* keep access to the server narrow, give the project its own account,
  and replace a secret that leaked.
- **A few seconds of downtime in every deploy, and no automatic rollback.** Compose stops the old
  container before it starts the new one; if the new one never becomes healthy, the service stays
  down until someone runs `make rollback`
  ([ENV-09](02-environments.md#env-09-ship-deploy-and-roll-back-m-if-there-is-stage-or-prod)).
  Switching traffic without a gap needs a front proxy, which the standard does not include yet.
  *You can:* put such a proxy in front and run two copies of the application; set up health
  monitoring ([OPS-04](03-operations.md)) so that you hear about a failed deploy at once.
- **The gates run on the developer machine and can be skipped.** The `pre-push` hook runs
  `make gates`; `git push --no-verify`, a merge in a web interface, an IDE that does not run hooks
  and a clone without `make bootstrap` all skip it, and `make verify` and `make image-scan` run only
  when someone starts them ([QLT-02](04-quality.md)). *You can:* add a CI that calls the same
  `make` targets (`gates`, `verify`) instead of repeating the checks, and protect the branches.
- **Operating-system packages can differ between stage and prod.** A build installs packages
  (`apt-get install`, `apk add`) at the version current on that day, so two builds made on different
  days can hold different packages ([D-0025](../decisions/0025-images-built-on-the-server.md)). *You can:* deploy prod soon
  after stage.
- **A build on the server runs outside the limits of `.env`.** On a small server it can compete
  with the running services for memory ([D-0025](../decisions/0025-images-built-on-the-server.md)).
  *You can:* keep memory to spare on the server while a build runs.
- **Proven on one machine so far.** Deploy, rollback, backups and the copy were exercised with stage
  and prod clones and a local bare repository on one machine, not on a remote server
  ([D-0021](../decisions/0021-ship-deploy-rollback.md)). *You can:* read the runbook before the
  first `make stage` on a real server, and report what had to change.
- **One server per environment.** If it is lost, the service is down until it is restored on a new
  server from the off-server copy. Several servers per environment are a later addition. *You can:*
  practise the restore from the copy: `make backup-drill` restores local sets only, the copy is
  proven by `make backup-copy-check` after it is set up and checked by the backup service every week, and a restore from it is practised
  in a proof copy or on stage with `make restore FROM=copy` (the runbook of the backups, "A new
  server from the off-server copy").
- **Monitoring sees health, not load.** The status service reports what Docker records as the
  health of each container and the free disk space; it does not measure CPU or memory
  ([OPS-04](03-operations.md)). *You can:* add a tool for that and record it in the registry.
