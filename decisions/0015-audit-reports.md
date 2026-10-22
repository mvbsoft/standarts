# D-0015. Audit reports are temporary, shown on one page; only proposals come back

> English · [Українська](0015-audit-reports.uk.md)

**Status:** accepted · **Date:** 2026-10-18 · **Rules:** —

## Context

An audit describes a private project: paths, services, weaknesses. Storing every audit centrally would leak that and pile up reports nobody reads. The owner also has to read the findings, answer the questions and approve the plan, which is hard across several md files and a long chat.

## Decision

The report lives in `~/audits/<repo>/<date>/`, outside every repository, and can be deleted after the migration. The agent writes only md files in a fixed format; the owner reads them on one page per project, built from [`templates/report-site/`](../templates/report-site/README.md), with the tabs State, Questions and Plan. Where the page can store data, it saves the owner's answers itself and the agent reads them; a button that copies the answers for the chat is always there as a fallback. If the page cannot be shown, the agent says what did not start, why, and how to make it work (for example, open the session in the Claude app), then continues with the md files and asks the questions in the chat. The plan goes into the project's own backlog. What could improve the standard is written as an anonymised `proposals.md`, which the owner may send as an issue to the standard's repository.

## Options considered

- **A central archive of audits in the standard's repository.** Leaks project details and grows without bound.
- **Reports inside the project's git.** Raw outputs can contain secrets.
- **Only md files and the chat.** Works everywhere, but answers to many questions get lost in a long chat.
- **A page the agent writes anew for every project.** Each page looks and works differently; one template keeps them the same.

## Consequences

The standard learns from projects without seeing their internals. The owner answers in one place, and nothing is lost when the page is unavailable, because the md files hold everything it shows.
