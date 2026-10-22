#!/bin/sh
# agent-hooks template 1.1.0 — from the standard's templates/agent-hooks; change it there, not here.
# The check of a file an agent has just edited (standard AI-05, D-0008), the same for any agent: it
# checks the file in the dev container (docker compose -f docker-compose.dev.yml exec -T dev …)
# with every `check` line of .claude/hooks/checks.conf that names its extension, each given the
# file as its last argument. It never passes a file it did not check.
#
# Usage:   sh .claude/hooks/check-file.sh <file>
#          An agent's adapter takes the file from what the agent sends and runs this: post-edit.sh
#          for Claude Code.
# Reads:   .claude/hooks/checks.conf of the checkout the file is in; that checkout's dev container.
# Output:  nothing when the checks pass; on stderr the output of the checks that failed, or
#          `check NOT run: <reason>` when they could not run.
# Exit:    0 the checks passed, or the file is not one the project checks (without a file it
#          checks nothing); 2 a check failed or could not run.
# Shell:   POSIX sh; git and docker.
set -u

notrun() { printf 'check NOT run: %s\n' "$*" >&2; exit 2; }  # notrun <reason>: no check ran: exit 2

file=${1-}
[ -n "$file" ] || exit 0
file=$(printf '%s' "$file" | tr '\134' /)  # Windows separators
[ -f "$file" ] || exit 0

# The project of the edited file: the checkout it is in (a worktree has its own dev stack). A file
# outside a checkout with docker-compose.dev.yml is not this project's.
dir=$(dirname "$file")
root=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -f "$root/docker-compose.dev.yml" ] || exit 0
# The file by its physical path, which is under the checkout as git names it (git resolves symbolic
# links) and as the dev container mounts it (PROJECT_DIR): the path given may run through a link.
file=$root/$(git -C "$dir" rev-parse --show-prefix)${file##*/}
conf=$root/.claude/hooks/checks.conf
[ -f "$conf" ] || notrun "$conf is missing: it names the checks of each language (templates/agent-hooks)"

# The check lines for this file: `check <.ext or file name>[,…] <command>`.
name=${file##*/}
case "$name" in *.*) ext=.${name##*.} ;; *) ext= ;; esac
cmds=$(awk -v ext="$ext" -v name="$name" '
  $1 == "check" {
    n = split($2, k, ",")
    for (i = 1; i <= n; i++) if ((ext != "" && k[i] == ext) || k[i] == name) {
      sub(/^[ \t]*check[ \t]+[^ \t]+[ \t]+/, ""); print; break
    }
  }' "$conf")
[ -n "$cmds" ] || exit 0

# dc <args>: docker compose of the file's checkout and its dev stack.
dc() { docker compose -f "$root/docker-compose.dev.yml" --project-directory "$root" "$@"; }
running=$(dc ps --status running --services 2>&1) || notrun "docker compose failed: $(printf '%s' "$running" | head -n 3)"
printf '%s\n' "$running" | grep -qx dev || notrun "the dev container is not running: start it with make dev"

q() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }  # q <text>: <text> quoted for sh
# One script for the container: every check runs; 127 (not found) means it did not run.
script='rc=0 notrun=0'
nl='
'
while IFS= read -r c; do
  [ -n "$c" ] || continue
  script="$script${nl}o=\$( { $c \"\$1\"; } 2>&1 ); r=\$?"
  script="$script${nl}if [ \$r -eq 127 ] || [ \$r -eq 126 ]; then printf 'check NOT run: %s: not found in the dev container (add it to the dev stage of the Dockerfile)\\n%s\\n' $(q "$c") \"\$o\"; notrun=1"
  script="$script${nl}elif [ \$r -ne 0 ]; then printf '\$ %s %s\\n%s\\n' $(q "$c") \"\$1\" \"\$o\"; rc=1; fi"
done <<EOF
$cmds
EOF
script="$script${nl}[ \$notrun -eq 0 ] || exit 3${nl}exit \$rc"

out=$(dc exec -T dev sh -c "$script" check "$file" 2>&1)
rc=$?
[ "$rc" -ne 0 ] || exit 0
# Long output is cut: the agent needs the first errors, and Claude Code shortens long hook output.
lines=$(printf '%s\n' "$out" | wc -l)
out=$(printf '%s\n' "$out" | head -n 150)
[ "$lines" -le 150 ] || out="$out${nl}… $((lines - 150)) more lines"
if [ "$rc" -eq 3 ]; then printf '%s\n' "$out" >&2; exit 2; fi
case "$out" in
  "\$ "*|*"${nl}\$ "*) printf 'check failed: %s\n%s\n' "$file" "$out" >&2 ;;
  *) notrun "docker compose exec failed (exit $rc): $out" ;;
esac
exit 2
