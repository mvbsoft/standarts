# D-0024. How the agent works with the owner

> English · [Українська](0024-agent-and-owner.uk.md)

**Status:** accepted · **Date:** 2026-10-18 · **Rules:** AI-01 (the rules in `AGENTS.md`); prompt: [`start.md`](../prompt/start.md) section 3, [`adopt.md`](../prompt/adopt.md))

## Context

The agent that applies the standard works in a real project, on a real machine, next to the owner's other projects and secrets. Left alone, it can run a long way on a wrong assumption, touch something it should not, or settle a conflict between the project's rules and the standard by chance.

## Decision

- **It stops after every phase** and waits for the owner. In a run without a person (for example `claude -p`) it never waits: questions go into the report, and each choice it makes for the owner is marked `assumption`. Such a run ends with the report and changes nothing in the project.
- **It may build and run dev**, including images and `make gates`, and `make image-scan`, but pushes nothing to the project's remote. It says at the start that builds take time and disk. It never starts, stops or updates stage or prod on a server; a proof that needs them runs in a temporary local copy with its own bare repository, which it stops and deletes afterwards. It never runs `docker compose down -v` or deletes volumes, except those of its own proof copy when the proof ends ([`start.md`](../prompt/start.md) section 3).
- **It reads other projects only when the owner names them** in the session, only to read, and from their `.env` only variable names.
- **Subagents only read and research**; they change nothing, and the agent checks what they report.
- **A conflict between the project's `AGENTS.md` and the standard goes to the owner** as a deviation with the action `owner decision` and a question with options; the plan does not touch it until the owner decides.
- **The rules for every day are in `AGENTS.md`**, so every agent sees them, not only Claude Code: no command that never ends (`make logs TAIL=<n>` prints the last lines and exits), no destructive command and no push or merge into the stage or prod branch without the owner's explicit yes in that session, a question to the owner before a push with uncommitted changes, `make fix` before editing by hand, and no "done" until `make gates` is green with its summary in the report.
- **Secrets: names only.** Configs are read with `config --no-interpolate`, and before the last message gitleaks scans the report folder.

## Options considered

- **One autonomous run to the end.** Fast, but a wrong guess in the first phase spreads through the whole plan.
- **The agent settles conflicts itself.** Which instruction wins is then arbitrary.
- **Free access to the machine.** Simpler to write, and one mistake can touch production or another project.
- **Permission settings of one tool (Claude Code's `permissions.ask`) for the dangerous commands.** Only that tool's agent would follow them; `AGENTS.md` is the one file the standard asks every agent to follow.

## Consequences

The owner sees and approves every step, and the agent never decides alone what the owner should. A non-interactive run still produces a full report, with its guesses marked. Runs take longer because they wait for answers.

## Sources

- <https://code.claude.com/docs/en/memory> — “if two instructions contradict each other, Claude may pick one arbitrarily”
- <https://agents.md/> — “explicit user chat prompts override everything”
