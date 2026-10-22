# D-0008. Hooks check in the container and never fail silently

> English · [Українська](0008-agent-hooks.uk.md)

**Status:** accepted · **Date:** 2026-10-18 · **Rules:** AI-05, AI-06

## Context

A post-edit hook that looks for a linter on the host, finds nothing and exits quietly makes the agent believe the file was checked.

## Decision

The PostToolUse hook runs its tools in the dev container; when it cannot run them, it writes `check NOT run: <reason>` to stderr and exits with code 2 (mandatory). A PreToolUse hook blocks language tools on the host and names the `make` target or the dev-container command to use instead (recommended). The checks are `sh` scripts from `templates/agent-hooks/` that do not depend on any agent: `check-file.sh <file>` and `check-command.sh '<command>'` take plain arguments and answer with exit code 2 and the reason on stderr. They take the commands of each language from the project's `.claude/hooks/checks.conf`. Claude Code reaches them through two thin adapters, `post-edit.sh` and `pre-bash.sh`, which read the hook's JSON with `awk` (the host has no JSON tool) and call the check; another agent writes its own adapter and the checks stay. The hooks run with `"onFailure": "block"`, so a hook that cannot start blocks too instead of letting the call through. The PreToolUse matcher is `Bash`: Claude Code's PowerShell tool is not covered.

## Options considered

- **Hooks on the host.** Breaks PRN-01 and checks against different library versions.
- **No hooks, gates only.** Errors surface late, at the end of a task.
- **Permission rules of one agent (`permissions.deny`) instead of the PreToolUse script.** The rule would live in one tool's settings and other agents would not see it; the script stays.
- **The agent itself inside a dev container.** The hooks would call the tools directly and need no "check NOT run" path. Not chosen, for the reasons in [D-0005](0005-language-servers.md): the agent's credentials and the writable workspace sit inside the container, and the dev container has no Docker of its own. A project that wants it records it as a deviation in its registry.

## Consequences

The agent always knows whether a file was checked. Exit code 2 in PostToolUse only reports; it cannot undo the edit. A command run through the PowerShell tool on Windows is not checked by the PreToolUse hook, and AI-06 says so.

## Verified

Checked on 2026-10-19, Docker Engine 29.7.2 (Docker Desktop, WSL 2), Compose v5.5.0, git 2.43.0, GNU awk on the host; dev images from python:3.12.13-slim@sha256:229a2c5bfa27522db7815ea81f9bed70af17ccb9de9fc7ad142b1877b5830d36, php:8.2-cli (PHP 8.2.33)@sha256:0ca296c0ae905940c0a333a15de437f3acaa81743333a9437221f6a44e3f0981, node:22-bookworm-slim (Node.js 22.23.3)@sha256:c3de60bf2f9dd0ac6370e6117950ff62d6e339527e7472301c9c78a017978392 and composer:2 (2.10.3)@sha256:af98f42dfff7c68ba8d53c2164fd9fde1087b7d449514baa38c418b1f6bc4bac.
- The post-edit hook gets the JSON the hooks reference documents and checks in the dev container: `tests/stacks/run.sh` (`make check-stacks`) on a Python (ruff 0.17.1, pyright 1.1.414), a PHP (php-cs-fixer 3.95.27, phpstan 2.3.1) and a TypeScript (prettier 3.9.10, eslint 10.13.0) sample; a clean file exits 0 with no output in 0.9–4.4 s; a lint error exits 2 in 1.0–1.6 s (run again on 2026-10-21 with the checks split from the adapters, agent-hooks 1.1.0) with the linter's message on stderr (ruff `F401`, phpstan `Function undefined_function not found.`, eslint `@typescript-eslint/no-unused-vars`); pyright also reports a type error of the one file; a file no `check` line names exits 0.
- The checks work without any agent's adapter: the same test calls `check-file.sh` and `check-command.sh` with plain arguments, from another folder and without `CLAUDE_PROJECT_DIR`, and gets the same exit codes and messages (a clean file 0, a lint error 2, `npm install` 2 with the dev-container command, `git status` 0); a long command goes to `check-command.sh -` on stdin.
- The post-edit hook never passes silently: with the dev stack stopped (`make down`), and with a `check` tool that the dev image lacks, it exits 2 with `check NOT run: <reason>`.
- The pre-bash hook blocks host language tools: the same test; `npm install`, `python x.py`, `cd src && npx eslint .`, `FOO=1 composer install`, `sh -c 'pip install x'`, `./node_modules/.bin/vitest`, `vendor/bin/phpunit` and `echo $(php -v)` exit 2 with the dev-container command; `git status`, `make gates`, `make dev && make gates`, `docker compose -f docker-compose.dev.yml exec -T dev npm test`, `ls -la | grep python`, `cat README.md` and a `git commit -m` naming npm exit 0 with no output; `allow` and `block` lines of `checks.conf` work. In a one-off run outside the test, the scripts behaved the same under GNU awk, mawk and busybox awk (37 command forms).
Not checked: a real Claude Code session (no `claude` on the WSL path, and it was not installed): that Claude Code shows the exit-2 stderr to the agent, runs the exec form `sh <script>` and honours `"onFailure": "block"` (v2.1.295 or later) rests on the quotes below. A Windows host without WSL (backslash paths; the PowerShell tool, which the `Bash` matcher does not cover).

## Sources

- <https://code.claude.com/docs/en/hooks> — “`PostToolUse` | No | Shows stderr to Claude; the tool already ran”
- <https://code.claude.com/docs/en/hooks> — “`PreToolUse` | Yes | Blocks the tool call”
- <https://code.claude.com/docs/en/hooks> — “To surface a warning to Claude from a `PostToolUse` or `PostToolUseFailure` hook, exit 2 instead so Claude sees the stderr even though the tool already ran.”
- <https://code.claude.com/docs/en/hooks> — “To block the action instead, set `"onFailure": "block"` on a `command` or `http` hook. Requires Claude Code v2.1.295 or later.”
- <https://code.claude.com/docs/en/hooks> — “A hook that blocks by exiting 2 routes the same way as `"deny"`: Claude sees the stderr message as the denial reason.”
- <https://code.claude.com/docs/en/hooks> — “A command hook runs as exec form when `args` is set, and shell form when `args` is omitted.”
