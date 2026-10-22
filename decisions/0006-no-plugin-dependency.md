# D-0006. The standard does not depend on any Claude Code plugin

> English · [Українська](0006-no-plugin-dependency.uk.md)

**Status:** accepted · **Date:** 2026-10-18 · **Rules:** AI-03

## Context

The first draft assumed a specific workflow plugin, and a later draft kept an adapter rule for it. The standard is meant for anyone, and not everyone has that plugin.

## Decision

No rule depends on a plugin, and the standard names none. The only bridge is one sentence in AI-03: a workflow plugin that runs the project's checks calls the same `make` targets (`make gates`, `make verify`), and its local state stays out of git. No adapter rule exists.

## Options considered

- **Build the standard around the workflow plugin.** Shorter for its users, unusable for everyone else.
- **An adapter rule per plugin.** Keeps one tool's details in a universal standard and has to follow that tool's changes.

## Consequences

The core rules stay universal. A plugin and the developer check the same thing, because both call `make`; anything else a plugin needs is the plugin's own business.
