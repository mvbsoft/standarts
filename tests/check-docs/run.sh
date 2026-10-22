#!/bin/sh
# Runs scripts/check-docs.py against fixture trees: good must pass; every other case is good with
# one change and must fail with its message. Like make check-docs: the pinned python image, no
# network, the tree read-only. CHECK_DOCS_PYTHON=python3 runs it with a python of the host instead.
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
py=python:3.12.13-slim@sha256:229a2c5bfa27522db7815ea81f9bed70af17ccb9de9fc7ad142b1877b5830d36
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0

check() { # check <case>: runs check-docs in $tmp/<case>, the output in $tmp/<case>.out, the exit in $code
  if [ -n "${CHECK_DOCS_PYTHON-}" ]; then
    if (cd "$tmp/$1" && "$CHECK_DOCS_PYTHON" -I "$root/scripts/check-docs.py") > "$tmp/$1.out" 2>&1
    then code=0; else code=1; fi
  elif docker run --rm --network none --name "stdtest-docs-$1" -v "$tmp/$1:/repo:ro" \
      -v "$root/scripts/check-docs.py:/check-docs.py:ro" -w /repo "$py" python -I /check-docs.py \
      > "$tmp/$1.out" 2>&1
  then code=0; else code=1; fi
}
new() { cp -R "$root/tests/check-docs/good" "$tmp/$1"; }
red() { # red <case> <pattern>: the case must fail, and a line of its output match the pattern
  check "$1"
  if [ "$code" -eq 0 ]; then echo "FAIL $1: expected a non-zero exit"; cat "$tmp/$1.out"; fail=1
  elif ! grep -q "^check-docs: $2" "$tmp/$1.out"; then
    echo "FAIL $1: missing: $2"; cat "$tmp/$1.out"; fail=1
  fi
}

new good
check good
if [ "$code" -ne 0 ] || ! grep -q "^check-docs: OK" "$tmp/good.out"; then
  echo "FAIL good: expected exit 0 and OK"; cat "$tmp/good.out"; fail=1
fi

# The checks that were there before: a missing twin, a missing file.
new no-twin
rm "$tmp/no-twin/GUIDE.uk.md"
red no-twin "GUIDE.uk.md: missing"
new broken-link
printf '\nSee [nothing](nowhere.md).\n' >> "$tmp/broken-link/GUIDE.md"
red broken-link "GUIDE.md: broken link nowhere.md"

# Anchors: to another file, in Ukrainian, a repeated heading counted once too often, the same file.
new anchor
printf '\nSee [ENV-02](standard/01-rules.md#env-02-two-files).\n' >> "$tmp/anchor/README.md"
red anchor "README.md:[0-9]*: broken anchor standard/01-rules.md#env-02-two-files"
new anchor-uk
printf '\nДив. [правило](01-rules.uk.md#env-01-два-файли).\n' >> "$tmp/anchor-uk/standard/01-rules.uk.md"
red anchor-uk "standard/01-rules.uk.md:[0-9]*: broken anchor 01-rules.uk.md#env-01-два-файли"
new anchor-repeated
printf '\nSee [the third notes](standard/01-rules.md#notes-2).\n' >> "$tmp/anchor-repeated/GUIDE.md"
red anchor-repeated "GUIDE.md:[0-9]*: broken anchor standard/01-rules.md#notes-2"
new anchor-same-file
printf '\nSee [below](#when-nothing-fails).\n' >> "$tmp/anchor-same-file/templates/project/docs/how-to/operations.md"
red anchor-same-file "templates/project/docs/how-to/operations.md:[0-9]*: broken anchor #when-nothing-fails"

# Quoted messages: a row no script prints; a script that says it differently from the docs.
new message
printf '%s\n' "| \`the lock .deploy/lock is stale: remove it\` | a killed make | remove it |" \
  >> "$tmp/message/templates/project/docs/how-to/operations.md"
red message "templates/project/docs/how-to/operations.md:[0-9]*: quoted message is in no script of the template: \`the lock .deploy/lock is stale: remove it\`"
new message-changed
sed 's/nothing was replaced/nothing was changed/' "$root/tests/check-docs/good/templates/project/scripts/project.sh" \
  > "$tmp/message-changed/templates/project/scripts/project.sh"
red message-changed "templates/project/docs/how-to/operations.md:[0-9]*: quoted message is in no script of the template: \`building <repo>"
new message-prints
sed 's/OK: %s runs/OK: %s is at/' "$root/tests/check-docs/good/templates/project/scripts/project.sh" \
  > "$tmp/message-prints/templates/project/scripts/project.sh"
red message-prints "templates/project/README.md:[0-9]*: quoted message is in no script of the template: \`OK: stage runs <commit>\`"
# A message made of parts: the reason in a variable of its own, the start in a variable.
new message-part
sed 's/the last drill failed/the drill failed/' "$root/tests/check-docs/good/templates/project/docker/backup/backup.sh" \
  > "$tmp/message-part/templates/project/docker/backup/backup.sh"
red message-part "templates/project/docs/how-to/operations.md:[0-9]*: quoted message is in no script of the template: \`unhealthy: the last drill failed: …\`"
new message-start
sed 's/the backup folder (BACKUP_DIR)/the backup directory (BACKUP_DIR)/' \
  "$root/tests/check-docs/good/templates/project/docker/backup/backup.sh" > "$tmp/message-start/templates/project/docker/backup/backup.sh"
red message-start "templates/project/docs/how-to/operations.md:[0-9]*: quoted message is in no script of the template: \`the backup folder (…) belongs to uid <u>"
# Prompts and GUIDE quote output after "prints", "stops it with", "a `…` line", "виводить".
new prompt-message
sed 's/the dev container is not running/the dev container is down/' \
  "$root/tests/check-docs/good/templates/agent-hooks/.claude/hooks/check-file.sh" \
  > "$tmp/prompt-message/templates/agent-hooks/.claude/hooks/check-file.sh"
red prompt-message "prompt/new.md:4: quoted message is in no script of the template: \`check NOT run: the dev container is not running\`"
new prompt-line
sed 's/scan: OK/scan: done/' "$root/tests/check-docs/good/templates/agent-hooks/.claude/hooks/check-file.sh" \
  > "$tmp/prompt-line/templates/agent-hooks/.claude/hooks/check-file.sh"
red prompt-line "prompt/new.md:7: quoted message is in no script of the template: \`scan: OK\`"
new guide-uk
printf '\n%s\n' "Потім \`make stage\` виводить \`OK: stage is up at <commit>\`." >> "$tmp/guide-uk/GUIDE.uk.md"
red guide-uk "GUIDE.uk.md:[0-9]*: quoted message is in no script of the template: \`OK: stage is up at <commit>\`"
# The other forms: after "says:"; in parentheses after "prints …" and "says so"; a span that
# starts with a prefix the scripts print (prune: …), after a colon of any phrase.
P=templates/project/scripts/project.sh
new prompt-colon
sed 's/lacks variables of/misses variables of/' "$root/tests/check-docs/good/$P" > "$tmp/prompt-colon/$P"
red prompt-colon "prompt/new.md:[0-9]*: quoted message is in no script of the template: \`WARNING: .env lacks variables of .env.example: <names>\`"
new prompt-paren
sed 's/free where Docker keeps/free where Docker stores/' "$root/tests/check-docs/good/$P" > "$tmp/prompt-paren/$P"
red prompt-paren "prompt/new.md:[0-9]*: quoted message is in no script of the template: \`space: <free> free where Docker keeps the images (need <X>)\`"
new prompt-paren-says
sed 's/exist, but no container of it/exist, but no container uses them/' "$root/tests/check-docs/good/$P" > "$tmp/prompt-paren-says/$P"
red prompt-paren-says "prompt/new.md:[0-9]*: quoted message is in no script of the template: \`WARNING: the volumes of <project> exist, but no container of it: …\`"
new message-prefix
sed 's/prune: removed/prune: deleted/' "$root/tests/check-docs/good/$P" > "$tmp/message-prefix/$P"
red message-prefix "templates/project/docs/how-to/operations.md:[0-9]*: quoted message is in no script of the template: \`prune: removed N old images; the images of the last 5 deployed commits stay\`"
# How a message is made: a variable for two words (app db), a part from printf '%s on %s', and
# the branches of a Python conditional in an f-string.
new message-words
sed 's/)for the restore"/)before the restore"/' "$root/tests/check-docs/good/$P" > "$tmp/message-words/$P"
red message-words "templates/project/docs/how-to/operations.md:[0-9]*: quoted message is in no script of the template: \`restore: stopping app db for the restore\`"
B=templates/project/docker/backup/backup.sh
new message-whole-part
sed "s/'%s on %s'/'%s at %s'/" "$root/tests/check-docs/good/$B" > "$tmp/message-whole-part/$B"
red message-whole-part "templates/project/docs/how-to/operations.md:[0-9]*: quoted message is in no script of the template: \`restore: db: replaces the database <name> on <host>"
S=templates/project/docker/status/status.py
new message-branch
sed "s/else 'no push, empty'/else 'no push, blank'/" "$root/tests/check-docs/good/$S" > "$tmp/message-branch/$S"
red message-branch "templates/project/docs/how-to/operations.md:[0-9]*: quoted message is in no script of the template: \`status: now fail: no push, empty STATUS_PUSH_FAIL_URL\`"
new message-name
sed 's/push failed: /push broke: /' "$root/tests/check-docs/good/$S" > "$tmp/message-name/$S"
red message-name "templates/project/docs/how-to/operations.md:[0-9]*: quoted message is in no script of the template: \`status: push failed: HTTPError: Not Found\`"

# Repeats: the same two sentences in prose of two files, English and Ukrainian.
passage="The deploy builds every image from the commit itself, so nothing uncommitted on the server reaches it. A build that fails leaves the old version running, and the output names the step that failed, so the next deploy can start from a clean state."
new repeat
printf '\n%s\n' "$passage" >> "$tmp/repeat/standard/01-rules.md"
red repeat "decisions/0001-one-file.md:[0-9]*: the same passage as standard/01-rules.md:[0-9]*"
uk="Розгортання збирає кожен образ із самого коміту, тож ніщо незакомічене на сервері в нього не потрапляє. Збірка, що не вдалася, лишає стару версію працювати, а вивід називає крок, який не вдався, тож наступне розгортання починає з чистого стану."
new repeat-uk
printf '\n%s\n' "$uk" >> "$tmp/repeat-uk/GUIDE.uk.md"
printf '\n%s\n' "$uk" >> "$tmp/repeat-uk/standard/01-rules.uk.md"
red repeat-uk "GUIDE.uk.md:[0-9]*: the same passage as standard/01-rules.uk.md:[0-9]*"
# English and Ukrainian are not compared: the English passage in a Ukrainian file is no repeat.
new repeat-languages
printf '\n%s\n' "$passage" >> "$tmp/repeat-languages/decisions/0001-one-file.uk.md"
check repeat-languages
if [ "$code" -ne 0 ]; then echo "FAIL repeat-languages: expected exit 0"; cat "$tmp/repeat-languages.out"; fail=1; fi

[ "$fail" -eq 0 ] && echo "check-docs tests: OK"
exit "$fail"
