# D-0023. The registry keeps only what files cannot say

> English · [Українська](0023-registry-only-what-files-cannot-say.uk.md)

**Status:** accepted · **Date:** 2026-10-18 · **Rules:** DOC-03, PRN-05

## Context

An earlier registry listed versions, image stages and pins next to the reason for each component, and had tables for the quality tools, the Claude Code components and the rules and docs, each with a "Meets the standard" column. Every version bump then had to change two files, and the registry drifted from the files it described. The extra tables repeated the `Makefile`, the hook settings and the list of `.md` files, and a tick went stale with the next commit, while an audit counts all of it afresh anyway.

## Decision

`docs/reference/project-registry.md` holds only what no other file can say: why each component is there, what holds data and is backed up, the owner's answers when the standard was applied, and where the project deviates from the standard. It has section 0 (the profile and the owner's decisions, each with its reason), section A (components and tools, with the problem each solves) and section E (deviations), and every row links to the file that defines the component. The sections keep their letters so that references to "section E" stay valid. An update reads the answers, asks only the questions a release adds and offers to revisit the earlier ones; setting the project up again goes through all of them. Versions, stages, pins and settings live only in their own files, so a version bump changes only that file.

## Options considered

- **A full inventory with versions.** Everything in one place, and wrong after the next bump.
- **No registry.** Nothing to keep in sync, but the reason for a component, the owner's answers and the list of deviations live nowhere.
- **Keep the tables for tools, agent components and docs, with the "Meets the standard" column.** Complete at the moment of writing, wrong after the next commit, and the audit recounts them.
- **Keep the owner's answers in the chat only.** Nothing to maintain, but the next update asks again and the answers cannot be reviewed.

## Consequences

The registry changes only when a component, its reason, what is backed up, an answer of the owner or a deviation changes (PRN-05). Reading a version means opening its file, which the registry links to.
