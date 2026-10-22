#!/bin/sh
# agent-hooks template 1.1.0 — from the standard's templates/agent-hooks; change it there, not here.
# The Claude Code adapter of check-file.sh: the PostToolUse hook for Edit and Write (standard AI-05,
# D-0008). It runs check-file.sh on the edited file.
#
# Usage:   the PostToolUse hook command of .claude/settings.json; stdin: the JSON Claude Code sends,
#          with the file at tool_input.file_path.
# Output:  that of check-file.sh, on stderr, which Claude Code shows the agent on exit 2.
# Exit:    that of check-file.sh: 0 lets the agent go on; 2 makes Claude Code show the agent the
#          stderr (the edit has already happened).
set -u
here=$(cd "$(dirname "$0")" && pwd)
file=$(LC_ALL=C awk -v want=tool_input.file_path -f "$here/json-get.awk")
exec sh "$here/check-file.sh" "$file"
