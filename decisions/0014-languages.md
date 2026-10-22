# D-0014. English is the primary language, with Ukrainian translations

> English · [Українська](0014-languages.uk.md)

**Status:** accepted · **Date:** 2026-10-18 · **Rules:** —

## Context

The owner reads Ukrainian most comfortably; tools, sources and other users work in English.

## Decision

English is primary. Everything an agent reads or runs (prompts, templates, catalog, changelog) is in English only. Everything a person decides on (the standard, decisions, README, the GUIDE, contributing guide, open questions) exists in English and in Ukrainian, side by side as `<name>.md` and `<name>.uk.md`, updated in the same commit. Nothing exists in Ukrainian only. `make check-docs` fails when the two versions differ in rule IDs or version, and it checks more: that every relative link and every `#heading` anchor (by GitHub's slug rules) resolves, that the messages the template's docs quote as output are printed by the template's scripts, and that no passage of 200 characters or more is repeated word for word between two documents (a fact has one place; the others link to it). `scripts/check-docs.py` starts with the exact rules.

## Options considered

- **English only.** One copy, but harder for the owner to review.
- **Ukrainian only.** Unusable for others and for tools.

## Consequences

Two copies to maintain, made safe by the check.
