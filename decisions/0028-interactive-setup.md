# D-0028. Interactive setup: the owner chooses each part the skeleton can do without

> English · [Українська](0028-interactive-setup.uk.md)

**Status:** accepted · **Date:** 2026-10-22 · **Rules:** TYP-01, DOC-03, PRN-09; prompts: [`questions.md`](../prompt/questions.md), [`start.md`](../prompt/start.md)

## Context

M used to mean "no choice": a project received backups, stage, the agent's hooks and the rest whether it needed them or not, and the owner was asked only about a few parts. Owners differ: one keeps data worth a backup and another keeps none; one needs stage and another does not. A part that cannot be declined becomes dead weight, or the project drops it quietly and the registry does not say why. Asking about every part is the opposite risk: some fifty questions, and the owner stops reading them.

## Decision

- **The parts TYP-01 lists under "The choices" are the owner's choice.** Every other rule or part applies as its rule says. The core (Docker, one compose file per environment, the `make` targets, the registry, `AGENTS.md` and the rest of TYP-01 "The core") is never asked about, and what comes with stage or prod comes with them. The 24 choices and the default of each are TYP-01 "The choices"; the questions, in plain words with an example and the risk, are [`questions.md`](../prompt/questions.md).
- **The levels stay, with a new meaning.** M is the core, or strongly advised: the agent explains in detail what declining risks. R is advised, O is offered ([standard](../standard/README.md#how-to-read-it)).
- **A declined part is an answer, not a deviation.** It is a row of registry section 0 with its reason and date (DOC-03); an audit and an update do not report it as a deviation (PRN-09).
- **One question at a time, by topic.** About six topics: the environments; data and backups; the quality checks; security; monitoring and logs; the agent's tools. What the facts of the project already answer is not asked, only said ([`start.md`](../prompt/start.md)).
- **A choice only where the skeleton already works without the part, proven by tests.** A part the owner would choose but the skeleton is not yet proven without is listed under "A choice later" in TYP-01 and applies as its rule says until such a test exists.

## Options considered

- **Keep M as "no choice".** Simple to audit, but a project carries parts nobody wants, or drops them without a record.
- **Ask about the core too.** Full freedom, but a project without Docker, `make` or the registry is no longer worked the way every other one is (PRN-10), and the standard's tools do not fit it.
- **Drop the levels.** Every part becomes an equal question, and the owner cannot tell advice that protects data from a convenience.
- **Record a declined part as a deviation in section E.** Every audit would report the owner's own choice again, and section E would mix choices with debts that something has to remove.
- **All questions in one list, or only ready sets by project type.** A list of some fifty is not read; a set alone hides the part one would change. Defaults by type with each part asked on its own, and the facts answering what they can, keep both.
- **Every part a choice already in this release.** More freedom at once, but a choice the skeleton was never tested without can leave a project that does not deploy.

## Consequences

The owner decides each part once, with its risk in front of them, and section 0 shows the reason. An audit and an update stop reporting what was declined on purpose. For a choice, its level says how hard the agent advises, not whether the owner may say no; the core is never declined. The parts under "A choice later" stay fixed until a test proves the skeleton works without them.

## Verified

Declining backups (S-06): the project template's test (`tests/project/run.sh`, step m, 2026-10-22) deploys a copy of the sample with a database and without the backup service to stage twice, migrating each time, and every backup command refuses with its message.

Not checked yet (2026-10-22): no automated test runs the prompts, so that the agent asks one question at a time, skips what the facts answer and writes section 0 as DOC-03 says is proven only by the owner's run of `adopt` on a real project, before the release.
