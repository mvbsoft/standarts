# Documentation and registry

> Version 1.0.0-draft · English · [Українська](06-docs.uk.md)

### DOC-01. Documentation set (M)

Documentation follows Diátaxis (tutorials, how-to guides, reference, explanation), and decisions
follow ADR (one file, one decision). Which language the documentation is written in is the
project's choice. Required pages:

| Page | Contents | Required when |
|---|---|---|
| `README.md` | starts with the section "Working with this project" ([DOC-04](#doc-04-working-with-this-project-m)) | always |
| `docs/how-to/operations.md` | the server runbook: every server scenario of DOC-04 | there is stage or prod |
| `docs/how-to/backups.md` | how the backup works, how to set up and check the off-server copy, how to check a restore and how to restore | there is a backup ([OPS-01](03-operations.md)) |
| `docs/how-to/tuning.md` | every tuned parameter: what, why, how it is derived, how to change it, how to check it, the source | there is stage or prod ([OPS-02](03-operations.md)) |
| `docs/reference/project-registry.md` | the component registry ([DOC-03](#doc-03-component-registry-m)) | always |
| `docs/adr/` | the project's architecture decisions | from the first decision |

### DOC-02. Backlog and session state (M)

The task backlog lives in one place: a file in the repository or an issue tracker. A workflow
plugin's session state stays out of git ([AI-03](05-agents.md)). Neither duplicates `docs/`.

### DOC-03. Component registry (M)

`docs/reference/project-registry.md` is one short file that says what files cannot say: why each
component is there, what holds data and is backed up, the owner's answers to the questions asked
when the standard was applied, and where the project deviates from the standard. It is an **entry
point**, not a copy: versions, image stages, pins and settings live only in their own files, and
every row links to the file that defines the component. A version bump therefore changes only that
file ([PRN-05](01-principles.md)). What the files already show is not repeated: the targets of the
quality tools are in the `Makefile`, the agent's hooks and skills in the agent's own folder, the
list of documents in `docs/`; an audit counts them afresh each time.

```markdown
# Project registry — <project name>

Standard: <version, for example v1.0.0> · Last reconciled: <date, commit>

## 0. Profile and decisions
Type: service | library | frontend | pipeline | ML · Languages: … · Environments: dev, [stage], [prod]
| Question | Answer | Why |

## A. Components and tools | Component | Defined in | Problem it solves | Environments | Persistent? Backed up? |

## E. Deviations from the standard | Rule (ID) | Deviation | Reason | ADR | What removes it |
```

The sections keep the letters 0, A and E, so that every reference to "section E" stays valid. No
other columns are added; if more is needed, it is a link to a reference page.

- **Section 0** is where the owner's answers live. When the standard is applied, the agent asks the
  owner what to switch on and what off, and every answer is written here with its reason: for each
  mandatory check (`LINT`, `TEST`, `SECRETS`) its command or `off`; the environments; the backup
  folder; the folder for archived logs; mutation testing, the agent's browser
  ([AI-08](05-agents.md)) and health monitoring ([OPS-04](03-operations.md)), each yes or no. An update reads these answers and does not ask
  again; it asks only about what the new release added after they were given. To change an answer,
  the owner sets the project up again ([`prompt/start.md`](../prompt/start.md)): that goes through
  all the questions afresh, with the current answers shown for reference, and brings the project to
  the new answers by adding or removing parts.
- **Section A** lists every component, and every tool with the problem it solves
  ([PRN-06](01-principles.md)); a row says whether the component holds data and whether it is
  backed up.
- **Section E** lists every deviation, with what removes it ([PRN-09](01-principles.md)).

The `Standard` field in the header is the version of the standard the project was last reconciled
against; an update to a new version starts from it.

### DOC-04. Working with this project (M)

The README of every project starts with the section "Working with this project", taken from
[`templates/project/README.md`](../templates/project/README.md) with the project's names filled in
(translated if the project's documentation is not in English; the commands stay as they are, and
the links to this section in `AGENTS.md` and `docs/how-to/operations.md` follow its heading). It
holds two tables and nothing project-specific beyond names and addresses:

1. **Which command in which situation**: for each scenario below that applies to the project, the
   command, what it does, and what happens when something goes wrong and what to do then.
   - first time on a machine; daily development and running the application (`make dev`,
     `make run`); dependencies or a Dockerfile changed; test data; a second copy for parallel work;
   - before a push; the simple findings of the checks (`make fix`); one kind of check; finishing a
     task (`make verify`);
   - shipping a change to stage (`make stage`); checking the images before prod
     (`make image-scan`); deploying to prod; a changed value in a server's `.env`
     (`make restart`); rolling back; seeing what runs and whether it is healthy; being told when something fails (the status service,
     [OPS-04](03-operations.md));
   - backing up now and checking a restore (`make backup`, `make backup-drill`); seeing which sets
     exist and the state of the backups (`make backup-list`, `make backup-status`); restoring data
     (`make restore`); setting up or changing the off-server copy (`make backup-copy-check`)
     ([OPS-01](03-operations.md));
   - each command of the project's own, from the `Makefile` block "Project targets"
     ([ENV-05](02-environments.md#env-05-make-targets-m)).

   A scenario or check the owner switched off in registry section 0 (mutation testing, health
   monitoring, a check set to `off`, a stage or prod that does not exist) has no row: the project
   drops it from both tables.
2. **When each check runs** ([QLT-03](04-quality.md)).

`docs/how-to/operations.md` is the full server runbook from the same template folder, with every
one of these scenarios step by step: the first server from scratch (read access to the repository,
clone, `.env`, `PROJECT_ENV`, the front proxy, the first `make stage` / `make prod`, which builds
the images on the server); an update; moving stage to prod; one copy of each environment per
machine; a failed image build; a failed migration; a container that does not become healthy; a
rollback; a server reboot; a full disk; the logs of replaced containers; a changed secret or other
`.env` value (`make restart`); health monitoring ([OPS-04](03-operations.md)); checking and
restoring a backup; moving to a new server from the off-server copy, before the first
`make stage` / `make prod`.
