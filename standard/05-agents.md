# Agents

> Version 1.0.0-draft · English · [Українська](05-agents.uk.md)

The standard does not tie a project to one coding agent. The core is what every agent follows: the
rules in `AGENTS.md`, the `make` targets, the gates, the git hook and the checks in the dev
container. An adapter connects one agent to that core. Claude Code is the first adapter and so far
the only one; another agent gets its own adapter in the same way, and the core does not change.
The standard does not depend on any particular plugin, and no rule mentions one.

## Core: any agent

### AI-01. `AGENTS.md` and `CLAUDE.md` (M)

All rules for agents are in `AGENTS.md`. `CLAUDE.md`, the entry point of Claude Code, is a single
line, `@AGENTS.md`. `AGENTS.md` is up to ~200 lines: `CLAUDE.md` imports it, imported files “also
load at launch”, and the official documentation says “target under 200 lines per CLAUDE.md file”
([memory](https://code.claude.com/docs/en/memory)); the rest are links into `docs/`. It links to
the README section "Working with this project" for the commands and when each check runs
([DOC-04](06-docs.md#doc-04-working-with-this-project-m)) and to registry section E for the host
exceptions; it does not repeat either. The tool inventory lives in the registry, not here.

`AGENTS.md` also holds the rules that keep an agent from doing damage. They are in the file, not in
the permission settings of one tool, because every agent has to see them:

- A command that does not end by itself is not run: `make logs` follows the logs for ever, and
  `make logs TAIL=<n>` prints the last lines and exits.
- A destructive command (`docker compose down -v`, `docker volume rm`, `docker volume prune`,
  `git push --no-verify`, `make restore`, a push or merge into `STAGE_BRANCH` or `PROD_BRANCH`,
  deleting data) and a `make` command that goes on despite a warned estimate (`RISK=yes`) are run
  only after the owner's explicit yes in that session, for that command. This is the one rule for
  these commands; other documents link to it. The exception is a proof copy that the standard's
  prompt sets up (`scripts/proof.sh`): inside it, a push to the copy's own bare remote (any branch,
  with or without uncommitted files), `git push --no-verify`, `make restore … CONFIRM=yes` in its
  server clones, and changing or deleting the data of its own stacks and volumes (`DROP TABLE` in
  its clone, `proof.sh clean`, `docker compose down -v` there) need no question, because the
  remote and the data are the proof's own. Starting, stopping or updating stage or prod on a server
  is never done by the agent.
- Before a `git push` with uncommitted changes the agent asks the owner: the gates check the
  working tree together with the commit ([QLT-02](04-quality.md)).
- Automatic fixes come first: `make fix` does what a program can do (format, simple lint
  fixes), and the agent edits by hand only the rest ([QLT-01](04-quality.md)).
- The agent does not say a task is done until `make gates` is green, and its report quotes the
  summary that `make gates` prints ([QLT-02](04-quality.md)).

The wording is in the template's [`AGENTS.md`](../templates/project/AGENTS.md); the reasons are in
[D-0024](../decisions/0024-agent-and-owner.md).

## Claude Code adapter

What follows connects Claude Code to the core. Its files are in
[`templates/agent-hooks/`](../templates/agent-hooks/) and [`templates/docker-lsp/`](../templates/docker-lsp/).

### AI-02. Global `~/.claude/CLAUDE.md` (M)

Only personal and machine rules: the conversation language, the Docker axiom. Nothing about a
specific project.

### AI-03. Global workflow plugin (O)

A plugin with sessions, reviewer agents or working standards is installed globally. When it is
installed, the project does not duplicate its skills and agents. No rule of the standard depends
on it. If such a plugin runs the project's checks, its configuration calls the same `make` targets
(`make gates`, `make verify`) instead of its own commands, so the plugin and the developer check
the same thing; its local state stays out of git.

### AI-04. Project skills (M, if any)

`.claude/skills/` hold only project-specific facts: how to start the project, test conventions,
this repository's migrations, a domain pattern. No more than ~10 skills; each is short and points
into `docs/` instead of retelling it. A skill name does not repeat a skill name of a global plugin.

### AI-05. Post-edit check hook (R)

The PostToolUse hook on `Edit` and `Write` runs the tools in the dev container
(`docker compose -f docker-compose.dev.yml exec -T dev …`), not on the host. It checks the changed
file's format (the formatter in its check mode, which never rewrites the file), lints it and, where
the tool checks a single file with the project's settings (Python: `pyright <file>`), its types
too. Not `tsc <file>`: TypeScript 6 refuses it with “error TS5112: tsconfig.json is present but
will not be loaded if files are specified on commandline” unless `--ignoreConfig` is given
([TypeScript 6.0](https://devblogs.microsoft.com/typescript/announcing-typescript-6-0/)), and then
`tsconfig.json` is not used; the types of TypeScript files are left to `make gates`. When a check
fails, the hook passes the tools' output to the agent with exit code 2, so the agent fixes the
file. It is the fallback when the language server does not answer, and the check for what the
language server does not cover.

The check itself does not depend on the agent: `check-file.sh <file>` takes a plain path, and its
exit code and stderr are the result. For Claude Code, `post-edit.sh` is a thin adapter that reads
the file's path from the JSON the hook receives and calls it; another agent calls `check-file.sh`
from its own adapter. The scripts `post-edit.sh`, `check-file.sh` and `json-get.awk` are copied
verbatim from [`templates/agent-hooks/`](../templates/agent-hooks/), and its
`settings.fragment.json` is merged into `.claude/settings.json`. The commands of each language are
the `check` lines of the project's `.claude/hooks/checks.conf`: the same tools and versions as
`make gates`.

If the tool is not found or the dev container is not running, the hook does not skip the check
silently: it writes `check NOT run: <reason>` to stderr and exits with code 2, which is how a
PostToolUse hook shows a message to the agent (M). The edit has already happened by then; the
message only reports.

### AI-06. "No host tools" hook (R)

Before every Bash tool call, a PreToolUse hook blocks running language tools directly on the host
(`python`, `pip`, `uv`, `node`, `npm`, `npx`, `pnpm`, `composer`, `php` and so on) and replies with
the `make` target or dev-container command to use instead. The host exceptions from
[PRN-01](01-principles.md) pass, and so do those of the registry, as `allow` lines of
`.claude/hooks/checks.conf`. The check reads every command of a list, a pipeline, `$( )` and
`sh -c '…'`; it stops habit, not a deliberate bypass.

As with AI-05, the check does not depend on the agent: `check-command.sh '<command>'` is the check
(exit code 2 with the reason on stderr means blocked), and `pre-bash.sh` is the Claude Code adapter
that reads the command from the hook's JSON and calls it. The hook matches the `Bash` tool only.
The PowerShell tool of Claude Code on Windows is not covered: a command run through it is not
checked ([D-0008](../decisions/0008-agent-hooks.md)).

### AI-07. Language servers for the agent (R)

Language servers give the agent errors after an edit, go-to-definition and find-references. They
sit in the `dev` stage of the Dockerfile with a pin: Python — pyright at the same version as in the
gates; TS — typescript-language-server; PHP — intelephense, with the Node.js it runs on copied into
the `dev` stage from a pinned `node` image. The pinned servers are the same for any agent; the
plugin below is only how Claude Code reaches them.

Claude Code connects to them through a `docker-lsp` plugin inside the repository: the files under
`templates/docker-lsp/.claude/plugins/` ([template](../templates/docker-lsp/)) are copied verbatim,
with only this project's languages, and `settings.fragment.json` is merged into
`.claude/settings.json`. A language the template lacks gets an entry of the same shape, and the
audit proposes it for the template in `proposals.md`. The marketplace is named `<repo>-tools` with
the relative path `./.claude/plugins`; the plugin is enabled as `docker-lsp@<repo>-tools`. The
launcher uses only `sh` and `docker`, so there is no host exception. The official `*-lsp` plugins
are not installed: they look for the server on the host, where the project's libraries are not.

What the agent can prove is that the servers are in the dev container and that the plugin's
command answers over LSP and names a type error; the standard's own tests do that for the samples
(`make check-stacks`). That Claude Code loads the plugin is a step for the owner at hand-over: a new
session in the project, and the Errors tab of `/plugin` is empty.

### AI-08. Browser for the agent (R for projects with a UI)

Playwright MCP runs in Docker in HTTP mode: a `browser` profile in `docker-compose.dev.yml` and an
entry in `.mcp.json`, with `--image-responses omit` and `--allowed-origins`. The flag lists trusted
origins, and that is all it does: the Playwright MCP README says it “does not serve as a security
boundary” and does not affect redirects
([README](https://raw.githubusercontent.com/microsoft/playwright-mcp/main/README.md)), so it
guides the browser and does not protect against a hostile page. The templates have no browser
profile yet; the agent writes it from this description.

The level is R, also for a Frontend project ([TYP-01](07-project-types.md)): while setting the
project up, the agent asks the owner whether it gets a browser and records the answer in the
registry.

### AI-09. Other plugins and MCP (M)

- Third-party plugins (O) are installed per project with pins; the same pin in every project where
  the plugin is enabled. A plugin that duplicates a global plugin or a built-in capability is not
  installed.
- An MCP server that needs authorisation is enabled only after it is authorised.
- Disabled or replaced plugins and empty marketplaces are removed.
- `.claude/settings.local.json` is in `.gitignore`, personal permissions only; never `enabledPlugins`
  for the team.
- Skills synced from the account are outside the standard.
