#!/bin/sh
# agent-hooks template 1.1.0 — from the standard's templates/agent-hooks; change it there, not here.
# The Claude Code adapter of check-command.sh: the PreToolUse hook for Bash (standard AI-06,
# D-0008). It hands the command to check-command.sh on stdin, so that a command of any length fits.
#
# Usage:   the PreToolUse hook command of .claude/settings.json; stdin: the JSON Claude Code sends,
#          with the command at tool_input.command.
# Output:  the reason of a block, on stderr, which Claude Code shows the agent.
# Exit:    that of check-command.sh: 2 blocks the call; 0 leaves the call to the normal permission
#          flow.
set -u
here=$(cd "$(dirname "$0")" && pwd)
LC_ALL=C awk -v want=tool_input.command -f "$here/json-get.awk" | sh "$here/check-command.sh" -
