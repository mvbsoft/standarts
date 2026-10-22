# D-0017. Shared templates, stack-specific pieces only when needed, proven by the standard's own samples

> English · [Українська](0017-templates-and-references.uk.md)

**Status:** accepted · **Date:** 2026-10-18 · **Rules:** —

## Context

Templates per language multiply files and drift apart. Yet some pieces really differ by language: the base image, the package manager, the tool commands.

## Decision

Templates are shared by default and parameterised by variables. A stack-specific piece exists only where a shared one cannot work. [`templates/project/`](../templates/project/) holds the files every project gets, of two kinds ([`templates/README.md`](../templates/README.md) lists every file): verbatim files that a project never edits (for example `scripts/project.sh` and `.githooks/pre-push`; the `Makefile` too, except its settings block and its "Project targets" block), and starting points that keep their structure and are filled in for the project (for example the compose files, `.env.example`, `README.md` and `AGENTS.md`). The `new` mode ([`prompt/new.md`](../prompt/new.md)) builds a project from them; the `adopt` mode brings an existing one to them. Release 1.0.0 is tested on the standard's own samples: `tests/stacks` holds a Python, a PHP and a TypeScript sample built from the templates with the same checks (`make check-stacks`), and `tests/project` holds a sample that goes through the whole path from `make dev` to deploy, rollback and restore. The check on a real project is the owner running `adopt` on one of their own projects; the first release waits for that run.

## Options considered

- **A full template set per stack.** Easy to start, expensive to keep consistent.
- **Only rules, no template files.** Every project writes its own `Makefile` and scripts, and the same targets start to behave differently.
- **copier** (cookiecutter has no update; cruft adds one to it). `copier update` regenerates the old version from an answers file, diffs it against the project and re-applies the project's changes, with conflict markers: it is a machine version of the file step of our `update`. It needs Jinja variables and a template tagged in git, an answers file written by hand for every adopted project, a clean tree and Python (in a container), and it cannot choose rules from the changelog or ask the owner. Not now; see Consequences.

## Consequences

Fewer files in the standard and in every project. A fix to a verbatim file is made once in the standard and reaches projects by an update. Until a project made from the templates has run `adopt`, they are proven only by the standard's own tests. Roadmap: after 1.0.0, apply two releases of the standard to the sample of `tests/project`, once with `update` and once with `copier update`, and compare the conflicts; if copier carries the verbatim files and most starting points without the agent, it takes over the file step of `update` only, and the agent keeps the rest (reading the changelog, choosing the rules a release touched, asking the owner, the registry).

## Sources

- <https://raw.githubusercontent.com/copier-org/copier/master/docs/updating.md> — “It regenerates a fresh project from the current template version.” and “Finally, it re-applies the previously obtained diff and then runs the post-migrations.”
- <https://copier.readthedocs.io/en/stable/updating/> — “The destination folder includes a valid `.copier-answers.yml` file.” and “The template is versioned with Git (with tags).”
- <https://copier.readthedocs.io/en/stable/comparisons/> — the Cookiecutter row has “Updates are possible through Cruft.”
- <https://cruft.github.io/cruft/> — “To update an existing project, that was created using cruft, run `cruft update` in the root of the project.”
