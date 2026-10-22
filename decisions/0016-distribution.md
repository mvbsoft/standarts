# D-0016. Distribution: a public repository read by tag

> English · [Українська](0016-distribution.uk.md)

**Status:** accepted · **Date:** 2026-10-18 · **Rules:** —

## Context

The standard must be easy to apply on any machine without copying files by hand, and it should not tie its users to one tool.

## Decision

The repository is public. The short prompt in the README names the repository and a release tag; the agent fetches that release with a shallow `git clone` into `~/.cache/standards/<owner>/<repository>/<tag>/` (git is an allowed host tool; the repository is in the path, so a fork with the same tag never reuses another's folder) and follows `prompt/start.md`. A Claude Code plugin may be added later as a second way to deliver the same files.

## Options considered

- **A Claude Code plugin now.** Slash commands and updates, but it ties the standard to one tool.
- **A copy of the standard in every project.** Copies drift, and nobody knows which version a project follows.

## Consequences

Nothing is installed or copied by hand, and every project reads exactly the release it names.
