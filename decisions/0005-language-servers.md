# D-0005. Language servers run in the dev container

> English · [Українська](0005-language-servers.uk.md)

**Status:** accepted · **Date:** 2026-10-18 · **Rules:** AI-07

## Context

Claude Code gets diagnostics and code navigation from language servers. The official language-server plugins start the server from the host, where the project's libraries are not installed, and that also breaks PRN-01.

## Decision

Language servers are installed in the `dev` stage with pins. A small `docker-lsp` plugin inside the repository (`templates/docker-lsp/`) starts each server with `docker compose exec -T dev`, so the launcher needs only `sh` and `docker`. Official `*-lsp` plugins are not installed.

## Options considered

- **Official LSP plugins with servers on the host.** The project's libraries are not there, so diagnostics are wrong, and the host gains a toolchain.
- **No language servers, only the post-edit hook.** Works, but loses go-to-definition and immediate diagnostics.
- **The agent itself inside a dev container (Dev Containers spec, `devcontainer` CLI, Anthropic's Claude Code Feature).** Language servers, hooks and tools would all run where the agent runs, so no `docker-lsp` plugin would be needed. Not chosen: the agent's credentials and the writable workspace sit inside the container, the dev container has no Docker of its own so `make` targets that start containers would need the host's socket, and the workflow assumes an editor with Dev Containers support. It fits an agent that runs unattended with permission prompts off, which Anthropic documents. A project that wants it records it as a deviation in its registry; the standard does not change.

## Consequences

The agent sees the same errors the gates see. The plugin is two JSON files per repository, copied verbatim from the template. The servers in the `dev` stage serve any agent; only the plugin is Claude Code's. That Claude Code loads the plugin cannot be shown by the agent that sets the project up (it cannot start a session of its own), so the owner checks it at hand-over: a new session, and the Errors tab of `/plugin` is empty.

## Verified

Checked on 2026-10-19, Docker Engine 29.7.2 (Docker Desktop, WSL 2), Compose v5.5.0; dev images from python:3.12.13-slim@sha256:229a2c5bfa27522db7815ea81f9bed70af17ccb9de9fc7ad142b1877b5830d36, php:8.2-cli (PHP 8.2.33)@sha256:0ca296c0ae905940c0a333a15de437f3acaa81743333a9437221f6a44e3f0981 and node:22-bookworm-slim (Node.js 22.23.3)@sha256:c3de60bf2f9dd0ac6370e6117950ff62d6e339527e7472301c9c78a017978392.
- The `docker-lsp` plugin's command, taken from `plugin.json` with `${CLAUDE_PROJECT_DIR}` set to the project, starts a stopped dev stack and serves LSP over stdio through `docker compose exec -T`: `tests/stacks/run.sh` (`make check-stacks`) with a small LSP client in a container (initialize, initialized, didOpen of a file with a type error); initialize answered after 0.5–0.9 s and `publishDiagnostics` named the error after 1.3–1.6 s (the whole session 2.2–2.6 s, run again on 2026-10-21): pyright-langserver 1.1.414 `Argument of type "Literal[1]" cannot be assigned to parameter "name" of type "str"`, typescript-language-server 6.0.2 with TypeScript 6.0.3 `Argument of type 'number' is not assignable to parameter of type 'string'.`, intelephense 1.18.5 `Expected type 'string'. Found '42'.`. The code has the same path inside and outside, so file URIs need no mapping; pyright-langserver is the gates' pyright, and typescript-language-server uses the gates' TypeScript.
Not checked: the plugin inside a real Claude Code session (marketplace loading, `enabledPlugins`, the `/plugin` Errors tab), because `claude` is not installed in WSL; whether intelephense, which bundles Application Insights, sends telemetry from the dev container; a Windows host without WSL.

## Sources

- <https://code.claude.com/docs/en/plugins/code-intelligence> — “You install the plugin from Anthropic's official marketplace and the language server binary on your machine.”
- <https://code.claude.com/docs/en/plugins/components> — “Claude Code starts `command` by name from the user's `PATH`.”
- <https://code.claude.com/docs/en/plugins/manifest-reference> — “`lspServers` takes a `.json` file path, an inline map of server name to config, or an array of either.”
- <https://code.claude.com/docs/en/plugins/org> — “If you use a local `directory` or `file` source with a relative path, the path resolves against your repository's main checkout.”
- <https://code.claude.com/docs/en/devcontainer> — “commands Claude runs execute inside it rather than on the host machine, while edits to your project files appear in your local repository as you work.”
- <https://code.claude.com/docs/en/devcontainer> — “dev containers do not prevent a malicious project from exfiltrating anything accessible inside the container, including the Claude Code credentials stored in `~/.claude`”
- <https://containers.dev/implementors/spec/> — “Docker Compose configurations use docker-compose (which may be Docker Compose V1 or aliased Docker Compose V2) to create and manage a set of containers required for an application.”
