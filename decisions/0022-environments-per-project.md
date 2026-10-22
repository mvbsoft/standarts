# D-0022. Each project has the environments it needs, with one fence

> English · [Українська](0022-environments-per-project.uk.md)

**Status:** accepted · **Date:** 2026-10-18 · **Rules:** TYP-01, ENV-01

## Context

A library needs no prod, and a service that others use cannot live without one. Asking the same question on every audit wastes the owner's time; never asking lets a deployed project run without the protections of prod. Stage and prod files written only once a server exists are written in a hurry and never tested.

## Decision

The agent proposes the environments from the project type (TYP-01), the owner confirms them once, and the registry (section 0) records them; an update does not ask again. One fence holds whatever the owner chooses: anything that runs anywhere other than a developer machine has a prod file. If the profile lists stage or prod, those files are complete and proven in a proof copy on the developer machine before a server exists (a temporary local copy with its own bare repository and server clones, [`prompt/start.md`](../prompt/start.md) section 3); only what depends on a real server (TLS, the domain, the off-server backup target) waits, recorded in registry section E with the trigger "the server exists".

## Options considered

- **dev, stage and prod in every project.** Simple to state, but a library would carry files and checks that protect nothing.
- **The agent decides by type on every run.** No question for the owner, but the answer can change between runs and nobody approved it.
- **Write stage and prod when the server appears.** Less work up front, and the first deploy becomes the first test.
- **Prove them on a clean virtual machine.** A truer test, but no prompt can create one, so the rule could not be followed and the owner would believe a check had happened that had not. The proof copy runs the same files on the developer machine; what it cannot show waits for the server.

## Consequences

The choice is made once and is visible in the registry. A project that starts serving others moves under prod rules by the fence, not by memory. The first real server receives files that have already run in the proof copy, not on a machine of its own.
