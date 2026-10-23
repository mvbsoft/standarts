# Standards

> Version 1.0.0-draft · English · [Українська](README.uk.md)

One standard for how software projects are organised, whatever the language: environments, Docker,
quality gates, shipping and deploying, backups, documentation and the setup for AI agents (Claude
Code is the one adapter so far). Every
project built by it is worked with the same way: the same `make` commands set it up, develop,
check, ship, deploy and roll it back, and its README starts with the same table of what to run when.
An AI agent applies the standard: it creates a new project, or audits an existing one, asks the
owner what only the owner can decide, plans the changes and carries them out after approval.

> **Draft.** No release exists yet. Until `v1.0.0` the prompt below is for testing only:
> clone `main` yourself and, in the prompt, give `STANDARD_DIR=<that folder>` in place of the
> `STANDARD_REPO`, `STANDARD_REF` and fetch lines.

**New here? Start with [the standard on one page](GUIDE.md):** a map of what you do in each
situation, which `make` command does it and where the details are.

## Use it in a project

Requirements on the machine: Linux, or WSL 2 on Windows with the project inside WSL (not on a
Windows drive), the host tools and versions that
[PRN-01](standard/01-principles.md) lists, and an agent (Claude Code is the one supported so far).
Nothing else is installed: every language tool runs in the project's dev container.

Open the agent in the project's root folder and paste:

```text
Apply the project standard to this project.
STANDARD_REPO=mvbsoft/standarts
STANDARD_REF=v1.0.0
Fetch that release with
  git clone --depth 1 --branch "$STANDARD_REF" "https://github.com/$STANDARD_REPO.git" "$HOME/.cache/standards/$STANDARD_REPO/$STANDARD_REF"
(skip it if the folder exists), then read and follow $HOME/.cache/standards/$STANDARD_REPO/$STANDARD_REF/prompt/start.md.
```

The prompt is in English because the agent runs it; the agent answers you in the language you write in.
The agent picks the mode by itself; for a project that already has a registry it asks whether to
update or to set up again:

| The project | Mode | Result |
|---|---|---|
| has no registry yet | adopt | an audit report in `~/audits/<repo>/<date>/`, a plan in the project's backlog, the changes after approval |
| was set up by an older release | update | only the rules and templates that changed between the two releases and the questions the new release adds; then the agent offers to revisit your earlier answers one by one |
| is set up, and you want to go through all your choices again (stage, mutation testing, backups) | set up again | the agent asks every question from the start, shows your current answers, and brings the project to the new ones |
| does not exist yet (empty folder) | new | the skeleton of a new project that meets the standard, proven to work, committed after approval |

The report stays outside every repository and can be deleted after the migration. If something in
it could improve the standard, the report includes an anonymised `proposals.md`; send it as an issue
here if you want to. What the standard does not solve yet, and what you can do about it yourself:
[known limitations](standard/README.md#known-limits).

## What is inside

| Folder | What it is | Language |
|---|---|---|
| [`GUIDE.md`](GUIDE.md) | the whole standard on one page, by situation | English + Ukrainian |
| [`standard/`](standard/README.md) | the rules, each with an ID such as `ENV-02` | English + Ukrainian |
| [`decisions/`](decisions/) | why the rules that choose between alternatives are as they are: context, options, sources | English + Ukrainian |
| [`prompt/`](prompt/start.md) | what the agent follows: start, adopt, new, update | English |
| [`templates/`](templates/README.md) | files a project receives, and the page that shows the agent's report | English |
| [`catalog/`](catalog/README.md) | tuning and backup notes per technology | English |
| [`tests/`](tests/) | tests of the templates | English |
| [`CHANGELOG.md`](CHANGELOG.md) | what changed in each release, by rule ID | English |

A project gets only what its type needs: compose files, a Dockerfile, the `Makefile` with its
scripts, a git hook, `docs/` and the Claude Code settings ([the list](templates/README.md)). Nothing
from this repository is copied in except the templates.

## Versions

Releases are git tags `vMAJOR.MINOR.PATCH` on `main`. A major release means projects must change
something (a new rule or part that projects cannot decline is major), a minor one adds rules or templates that projects may take
up, a patch only clarifies text. Each project's registry names the release it follows. How the
standard itself is developed: [CONTRIBUTING](CONTRIBUTING.md); who helped it:
[CONTRIBUTORS](CONTRIBUTORS.md). Licence: [MIT](LICENSE).
