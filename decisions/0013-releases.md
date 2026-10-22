# D-0013. The standard lives in git and is released only without open questions

> English · [Українська](0013-releases.uk.md)

**Status:** accepted · **Date:** 2026-10-18 · **Rules:** —

## Context

Projects must point at an exact version of the standard, and a half-decided rule must never reach them.

## Decision

The standard is a git repository. Work happens on the `next` branch; `main` holds only releases, tagged `vMAJOR.MINOR.PATCH`. Open questions and research are the owner's working material and stay outside git. `make release` refuses while any question is open, while the working tree is not clean, or while `make check` or `make check-stacks` fails (`make check` includes the document check, which fails on a missing translation or one that differs in version or rule IDs). A major version means projects must change something (a new mandatory rule is major), a minor one adds rules or templates that projects may take up, a patch only clarifies text.

## Options considered

- **No versions, always the latest text.** Projects silently change meaning under their feet.
- **Questions in git.** Half-made decisions become public history.

## Consequences

Every project registry names the release it follows, and an update is the difference between two releases.
