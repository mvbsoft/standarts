# D-0007. A repository is self-contained

> English · [Українська](0007-self-contained-repository.uk.md)

**Status:** accepted · **Date:** 2026-10-18 · **Rules:** PRN-07

## Context

Projects that call a neighbouring repository's scripts by absolute path work only on the machine where that path exists, and break silently when the neighbour changes.

## Decision

A clone, Docker and `make bootstrap` are enough. Files in git have no paths into other repositories and no absolute machine paths. Anything shared travels by version: a tagged image, a locked package or a plugin from git.

## Options considered

- **Shared scripts by relative path to a sibling checkout.** Convenient on one machine, broken everywhere else.

## Consequences

Any machine can build any project; a change to shared code reaches a project only when the project moves to a new version.
