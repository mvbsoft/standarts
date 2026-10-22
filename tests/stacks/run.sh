#!/bin/sh
# Builds one small project per stack from templates/project, with tests/stacks/<stack> as its
# application, templates/agent-hooks as its hooks and templates/docker-lsp as its language-server
# plugin, and proves for each (standard QLT-01, QLT-02, ENV-08, AI-05, AI-06, AI-07):
#   - make bootstrap and make dev start the dev stack; make gates (LINT, TEST and SECRETS of
#     <stack>/make-settings) is green with a summary line ok for lint, test and secrets, and its
#     lint passes docker build --check of the sample's Dockerfile;
#   - make gates is red, with the tool's message and a FAIL line, on a planted lint error, a shell
#     script shellcheck rejects, a secret (gitleaks) and a broken link of the docs (lychee
#     --offline); a red make gates after a code change leaves the dev image as it was (same
#     creation time and layers);
#   - make fix (FIX) undoes spoiled formatting: afterwards git sees no change and make gates is
#     green;
#   - make gates is green in a dev container without network (network_mode: none);
#   - the post-edit hook, fed the JSON Claude Code sends, passes a clean file, returns exit 2 with
#     the linter's message for a bad one, and says `check NOT run` when it cannot check; the
#     pre-bash hook blocks host language tools and names the command to run instead, and lets git,
#     make and docker through; the checks behind both hooks (check-file.sh, check-command.sh) do
#     the same when called with plain arguments, as another agent's adapter calls them;
#   - TypeScript: tsc <file> refuses with TS5112 (TypeScript 6), so no check line runs it;
#   - the language server, started exactly as the docker-lsp plugin starts it (which also starts a
#     stopped dev container), reports a type error over LSP.
# STACKS="python php ts" picks the stacks. It prints the build, gates, hook and language-server
# times, the dev image sizes and the versions of the shared tools. The first run downloads the
# tools (pinned in each sample).
# Everything it creates in Docker is named $STACKS_PREFIX-* (default stdstacks); it removes all of
# it on exit, and nothing else.
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
prefix=${STACKS_PREFIX:-stdstacks}
stacks=${STACKS:-python php ts}
py=python:3.12.13-slim@sha256:229a2c5bfa27522db7815ea81f9bed70af17ccb9de9fc7ad142b1877b5830d36

tmp=$(mktemp -d "/tmp/$prefix.XXXXXX")
out=$tmp/out err=$tmp/err
cleanup() {
  status=$?
  set +e
  [ -z "${killer:-}" ] || kill "$killer" 2>/dev/null
  for c in $(docker ps -a --format '{{.Names}}' | grep "^$prefix-"); do docker rm -f "$c" >/dev/null; done
  for v in $(docker volume ls -q | grep "^$prefix-"); do docker volume rm "$v" >/dev/null; done
  for n in $(docker network ls --format '{{.Name}}' | grep "^$prefix-"); do docker network rm "$n" >/dev/null; done
  for i in $(docker images --format '{{.Repository}}:{{.Tag}}' | grep "^$prefix-"); do docker rmi "$i" >/dev/null; done
  rm -rf "$tmp"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 1' INT TERM

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=stdtest GIT_AUTHOR_EMAIL=stdtest@example.invalid
export GIT_COMMITTER_NAME=stdtest GIT_COMMITTER_EMAIL=stdtest@example.invalid
unset COMPOSE_FILE COMPOSE_PROJECT_NAME COMPOSE_PROFILES MAKEFLAGS MAKELEVEL MFLAGS

step() { printf 'stacks: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; exit 1; }
run() { if "$@" > "$out" 2> "$err"; then code=0; else code=$?; fi; }
both() { cat "$out" "$err"; }
expect_ok() { run "$@"; [ "$code" -eq 0 ] || { both; fail "expected success: $*"; }; }
expect_fail() { run "$@"; [ "$code" -ne 0 ] || { both; fail "expected a failure: $*"; }; }
has() { cat "$out" "$err" | grep -qF -- "$1" || { both; fail "the output lacks: $1"; }; }
in_dir() { dir=$1; shift; (cd "$dir" && "$@"); }
now() { date +%s.%N; }
since() { awk -v a="$1" -v b="$(now)" 'BEGIN { printf "%.1f", b - a }'; }
measure() { printf '%-7s %s\n' "$s" "$*" >> "$tmp/measure"; }
running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = true ]; }

# hook <script> <code> <tool> <field> <value>: the hook fed the JSON Claude Code sends; exit code and
# stderr in $code and $err, as Claude Code reads them.
hook() {
  printf '{"session_id":"stacks","transcript_path":"/dev/null","cwd":"%s","permission_mode":"default","hook_event_name":"%s","tool_name":"%s","tool_input":{"%s":"%s"},"tool_use_id":"toolu_stacks"}' \
    "$d" "$2" "$3" "$4" "$5" > "$tmp/hook.json"
  if (cd "$d" && CLAUDE_PROJECT_DIR=$d sh "$d/.claude/hooks/$1" < "$tmp/hook.json" > "$out" 2> "$err"); then code=0
  else code=$?; fi
}
edited() { hook post-edit.sh PostToolUse Edit file_path "$1"; }
bash_cmd() { hook pre-bash.sh PreToolUse Bash command "$1"; }
expect_code() { [ "$code" -eq "$1" ] || { both; fail "$2: exit $code, expected $1"; }; }
# direct <check script> <argument>…: a check behind the hooks called as another agent's adapter
# calls it: plain arguments, no JSON, from another folder, without CLAUDE_PROJECT_DIR.
direct() {
  script=$1; shift
  if (cd / && env -u CLAUDE_PROJECT_DIR sh "$d/.claude/hooks/$script" "$@" < /dev/null > "$out" 2> "$err"); then code=0
  else code=$?; fi
}
silent() { [ ! -s "$out" ] && [ ! -s "$err" ] || { both; fail "$s: $1 printed something"; }; }
# summary <base target> <state>: the summary of the last make gates has that line.
summary() { grep -Eq "^  $1 +$2( |\$)" "$out" || { both; fail "$s: the summary lacks the line: $1 $2"; }; }
# The dev image by its content: its layers and the time its config was made, which a build from the
# cache keeps. Not by its ID: with the containerd image store the ID names an index that also holds
# the build's provenance attestation, new on every build, even one that rebuilt nothing.
dev_image() { docker image inspect -f '{{.Created}} {{json .RootFS.Layers}}' "$name-dev-dev"; }

# plant <stack> <kind>: a lint or a type error in a file of the stack; sets $f to that file and
# $expect to the text the tool's message contains.
plant() {
  # shellcheck disable=SC2016 # $name is a PHP variable, $1 one of the planted script
  case "$1:$2" in
    python:lint) f=$d/hello.py; awk '{ print } NR == 1 { print ""; print "import os" }' "$f" > "$f.new"
      mv "$f.new" "$f"; expect=F401 ;;
    python:type) f=$d/typeerr.py; printf 'from hello import greet\n\ngreet(1)\n' > "$f"; expect='Argument of type' ;;
    ts:lint) f=$d/src/hello.ts; printf 'const unused = 1;\n' >> "$f"; expect=no-unused-vars ;;
    ts:type) f=$d/src/typeerr.ts; printf 'import { greet } from "./hello.ts";\n\ngreet(1);\n' > "$f"
      expect="not assignable to parameter of type 'string'" ;;
    php:lint) f=$d/src/Hello.php; sed -i 's|return "Hello, {$name}!";|return undefined_function($name);|' "$f"
      expect=undefined_function ;;
    php:type) f=$d/src/TypeErr.php; printf '<?php\n\ndeclare(strict_types=1);\n\nnamespace App;\n\nHello::greet(42);\n' > "$f"
      expect="Expected type 'string'" ;;
    # Spoiled formatting, which the formatter of the stack puts back byte for byte.
    python:format) f=$d/hello.py
      sed -i -e 's/def greet(name: str) -> str:/def greet( name:str )->str :/' \
        -e "s/return f\"Hello, {name}!\"/return  f'Hello, {name}!'/" "$f"; expect=hello.py ;;
    ts:format) f=$d/src/hello.ts
      sed -i -e 's/greet(name: string): string {/greet( name : string ) : string{/' -e 's/^  return/      return/' \
        -e 's/`;$/`/' "$f"; expect=hello.ts ;;
    php:format) f=$d/src/Hello.php
      sed -i -e 's/greet(string $name): string/greet( string $name ):string/' -e 's/^        return/            return/' "$f"
      expect=Hello.php ;;
    # The same in every stack: a script that shellcheck rejects, a secret, a broken link.
    *:shell) f=$d/scripts/stacks-bad.sh; printf '#!/bin/sh\necho $1\n' > "$f"; expect=SC2086 ;;
    # The token is put together here, so that no scanner takes this file for a leak.
    *:secret) f=$d/notes.txt; printf 'token = "%s%s"\n' ghp_ R8x2Kq7Lm4Zt9Vb1Nc6Hj3Wy5Pd0Fs8Ga2Qe > "$f"
      expect=github-pat ;;
    *:link) f=$d/README.md; printf '\nSee [the missing page](docs/stacks-missing.md).\n' >> "$f"
      expect='stacks-missing.md' ;;
  esac
}
unplant() { git -C "$d" checkout -q -- . && git -C "$d" clean -qfd -e .env; }

# lsp <server> <file> <language id>: the server started as the plugin starts it, an LSP session
# with the client in a container, the type error in its diagnostics.
lsp() {
  docker run --rm --network none -v "$d/.claude/plugins:/p:ro" -v "$root/tests/stacks:/t:ro" $py \
    python -I /t/lsp-client.py args /p/docker-lsp/.claude-plugin/plugin.json "$1" "$d" > "$tmp/lsp-args"
  lsp_file=$2 lsp_lang=$3
  set --
  while IFS= read -r a; do set -- "$@" "$a"; done < "$tmp/lsp-args"
  rm -f "$tmp/to" "$tmp/from"
  mkfifo "$tmp/to" "$tmp/from"
  t=$(now)
  # The server opens its output first and the client its input first, so neither open blocks.
  "$@" > "$tmp/from" < "$tmp/to" 2> "$tmp/lsp-server.err" &
  server=$!
  if docker run --rm -i --network none -v "$root/tests/stacks:/t:ro" -v "$d:$d:ro" $py \
      python -I /t/lsp-client.py check "$d" "$lsp_file" "$lsp_lang" "$expect" < "$tmp/from" > "$tmp/to" 2> "$tmp/lsp-report"; then
    code=0
  else code=$?; fi
  total=$(since "$t")
  (sleep 30; kill "$server" 2>/dev/null) & killer=$!
  wait "$server" 2>/dev/null || :
  kill "$killer" 2>/dev/null || :; killer=
  [ "$code" -eq 0 ] || { cat "$tmp/lsp-report" "$tmp/lsp-server.err"; fail "$s: no diagnostic with: $expect"; }
}

step "the hook and plugin settings are valid JSON of the documented shape"
docker run --rm --network none -v "$root/templates:/t:ro" $py python -I -c '
import json
hooks = json.load(open("/t/agent-hooks/settings.fragment.json"))["hooks"]
for event, matcher, script in (("PreToolUse", "Bash", "pre-bash.sh"), ("PostToolUse", "Edit|Write", "post-edit.sh")):
    group = hooks[event][0]
    handler = group["hooks"][0]
    assert group["matcher"] == matcher and handler["type"] == "command" and handler["command"] == "sh", event
    assert handler["args"] == ["${CLAUDE_PROJECT_DIR}/.claude/hooks/" + script], event
json.load(open("/t/docker-lsp/settings.fragment.json"))
json.load(open("/t/docker-lsp/.claude/plugins/.claude-plugin/marketplace.json"))
plugin = json.load(open("/t/docker-lsp/.claude/plugins/docker-lsp/.claude-plugin/plugin.json"))
assert set(plugin["lspServers"]) >= {"pyright", "typescript", "php"}
' || fail "a settings fragment or the plugin manifest"

for s in $stacks; do
  [ -d "$root/tests/stacks/$s" ] || fail "no sample tests/stacks/$s"
  d=$tmp/$s name=$prefix-$s
  step "$s: the project from the templates"
  mkdir "$d"
  cp -R "$root/templates/project/." "$d/"
  # Dev only: no stage, prod, backup or status, and no database. docs/how-to/backups.md stays:
  # the README links it, and lychee checks the links.
  rm -rf "$d/docker/backup" "$d/docker/status" "$d/docker-compose.stage.yml" "$d/docker-compose.prod.yml"
  awk '/^[a-z]/ { top = $1; svc = "" } /^  [a-z][a-z0-9_-]*:/ { svc = $1 }
    top == "volumes:" || svc == "db:" || svc == "backup:" || /DATABASE_URL|depends_on/ { next } { print }' \
    "$d/docker-compose.dev.yml" > "$tmp/compose" && mv "$tmp/compose" "$d/docker-compose.dev.yml"
  sed -i "s|<repo>|$name|" "$d/docker-compose.dev.yml"
  # An empty APP_PORT: Docker picks a free host port.
  sed -i 's|^APP_PORT=.*|APP_PORT=|' "$d/.env.example"
  awk -v f="$root/tests/stacks/$s/make-settings" '
    BEGIN { while ((getline l < f) > 0) { k = l; sub(/ =.*/, "", k); set[k] = l } }
    /^[A-Z_]+ =/ { k = $0; sub(/ =.*/, "", k); if (k in set) { print set[k]; delete set[k]; next } }
    { print }
    END { for (k in set) { print "no setting " k " in the Makefile" > "/dev/stderr"; exit 1 } }' \
    "$d/Makefile" > "$tmp/Makefile" || fail "$s: a setting of tests/stacks/$s/make-settings"
  mv "$tmp/Makefile" "$d/Makefile"
  cp -R "$root/templates/agent-hooks/.claude" "$root/templates/docker-lsp/.claude" "$d/"
  sed -i -e "s|<repo>|$name|" -e 's|<owner>|stdtest|' "$d/.claude/plugins/.claude-plugin/marketplace.json"
  cp -R "$root/tests/stacks/$s/." "$d/"
  cp "$root/tests/stacks/.gitleaks.toml" "$d/"
  rm "$d/make-settings"
  # The registry (standard DOC-03), which new and adopt write and the README links.
  mkdir -p "$d/docs/reference"
  printf '# Project registry\n\nThe %s sample of tests/stacks.\n' "$s" > "$d/docs/reference/project-registry.md"
  if [ -f "$d/ignore" ]; then cat "$d/ignore" >> "$d/.gitignore"; cat "$d/ignore" >> "$d/.dockerignore"; rm "$d/ignore"; fi
  if grep -n '^[^#]*<[a-z]' "$d/Makefile" "$d/docker-compose.dev.yml" \
      "$d/.claude/hooks/checks.conf" "$d/.claude/plugins/.claude-plugin/marketplace.json"; then
    fail "$s: a placeholder above is not filled"
  fi
  git init -q -b main "$d"
  git -C "$d" add -A
  git -C "$d" commit -q -m "the $s sample"

  step "$s: make bootstrap, make dev"
  expect_ok in_dir "$d" make bootstrap
  has "bootstrap: created .env from .env.example"
  t=$(now)
  expect_ok in_dir "$d" make dev
  measure "make dev (build and start): $(since "$t") s"
  running "$name-dev-dev-1" || fail "$s: the dev container is not running after make dev"
  measure "dev image: $(docker image ls --format '{{.Size}}' "$name-dev-dev") on disk, $(docker image inspect -f '{{.Size}}' "$name-dev-dev" | awk '{ printf "%.0f MB", $1 / 1000000 }') as docker image inspect counts it"

  # shellcheck disable=SC2016 # the dev container's shell expands them
  measure "shared tools: $(in_dir "$d" docker compose -f docker-compose.dev.yml exec -T dev sh -c \
    'printf "gitleaks %s, shellcheck %s, " "$(gitleaks version)" "$(shellcheck --version | sed -n "s/^version: //p")"; lychee --version' 2>&1)"

  step "$s: make gates, green, with its summary"
  t=$(now)
  expect_ok in_dir "$d" make gates
  measure "make gates: $(since "$t") s"
  summary lint ok; summary test ok; summary secrets ok
  has "make gates: OK"
  # make lint checks the Dockerfile of the sample's one image (IMAGES = app) with docker build --check.
  has "Check complete, no warnings found."

  step "$s: make gates, red on a lint error; the code change leaves the dev image as it was"
  image=$(dev_image)
  plant "$s" lint
  t=$(now)
  expect_fail in_dir "$d" make gates
  measure "make gates, red, after a code change (the dev image is cached): $(since "$t") s"
  has "$expect"
  # The PHP lint error is a call of an undefined function, so there the tests fail too.
  summary lint FAIL; summary secrets ok
  has "make gates: FAIL (lint"
  [ "$(dev_image)" = "$image" ] || fail "$s: a change of the code rebuilt the dev image (ENV-08)"
  unplant

  step "$s: make gates, red on a shell script shellcheck rejects and on a secret"
  plant "$s" shell; shell_expect=$expect
  plant "$s" secret
  expect_fail in_dir "$d" make gates
  has "$shell_expect"; has "$expect"; has "notes.txt"
  summary lint FAIL; summary test ok; summary secrets FAIL
  unplant

  step "$s: make gates, red on a broken link of the docs"
  plant "$s" link
  expect_fail in_dir "$d" make gates
  has "$expect"
  summary lint FAIL
  unplant

  step "$s: make fix puts spoiled formatting back; make gates is green after it"
  plant "$s" format
  expect_fail in_dir "$d" make lint
  has "$expect"
  expect_ok in_dir "$d" make fix
  [ -z "$(git -C "$d" status --porcelain)" ] || { git -C "$d" status --short; git -C "$d" diff; fail "$s: make fix changed more than the spoiled formatting"; }
  expect_ok in_dir "$d" make gates
  summary lint ok

  step "$s: make gates in a dev container without network"
  # The dev service without its ports (inline or a list), which network_mode: none does not allow.
  awk '/^  [a-z][a-z0-9_-]*:/ { svc = $1 } skip && /^      / { next } { skip = 0 }
    svc == "dev:" && /^    ports:/ { skip = 1; next } { print }
    $0 == "  dev:" { print "    network_mode: none" }' "$d/docker-compose.dev.yml" > "$tmp/compose"
  mv "$tmp/compose" "$d/docker-compose.dev.yml"
  expect_ok in_dir "$d" make gates
  summary lint ok; summary test ok; summary secrets ok
  [ "$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$name-dev-dev-1")" = none ] \
    || fail "$s: the dev container of make gates had a network"
  [ "$(dev_image)" = "$image" ] || fail "$s: a change of the compose file rebuilt the dev image"
  unplant
  expect_ok in_dir "$d" make dev

  if [ "$s" = ts ]; then
    step "$s: tsc <file> refuses with TS5112, so no check line of checks.conf runs it (AI-05)"
    expect_fail in_dir "$d" docker compose -f docker-compose.dev.yml exec -T dev tsc src/hello.ts
    has "error TS5112"
    ! grep -Eq '^check[[:space:]]+[^[:space:]]+[[:space:]]+tsc([[:space:]]|$)' "$d/.claude/hooks/checks.conf" \
      || fail "$s: a check line runs tsc <file>"
  fi

  step "$s: the post-edit hook"
  for f in $(git -C "$d" ls-files | grep -E '\.(py|ts|php)$'); do
    t=$(now)
    edited "$d/$f"
    expect_code 0 "post-edit of the clean $f"
    [ ! -s "$out" ] && [ ! -s "$err" ] || { both; fail "$s: post-edit printed something for the clean $f"; }
    measure "post-edit hook, clean $f: $(since "$t") s"
  done
  edited "$d/README.md"
  expect_code 0 "post-edit of README.md, which no check line names"
  plant "$s" lint
  t=$(now)
  edited "$f"
  expect_code 2 "post-edit of a file with a lint error"
  measure "post-edit hook, lint error: $(since "$t") s"
  has "check failed: $f"
  has "$expect"
  # STACKS_SHOW=1 prints what Claude Code would show the agent.
  [ -z "${STACKS_SHOW:-}" ] || { printf -- '--- post-edit, exit %s, stderr:\n' "$code"; cat "$err"; }
  [ ! -s "$out" ] || { both; fail "$s: post-edit wrote to stdout"; }
  # The same file by a path through a symbolic link: checked at the path the dev container mounts.
  ln -sfn "$d" "$tmp/link-$s"
  edited "$tmp/link-$s/${f#"$d"/}"
  expect_code 2 "post-edit of a file with a lint error, by a path through a symbolic link"
  has "check failed: $f"
  has "$expect"
  unplant
  if [ "$s" = python ]; then  # pyright checks one file, so the hook reports its type errors too
    plant "$s" type
    edited "$f"
    expect_code 2 "post-edit of a file with a type error"
    has "$expect"
    has "reportArgumentType"
    unplant
  fi
  printf 'check .py,.ts,.php no-such-tool\n' >> "$d/.claude/hooks/checks.conf"
  for f in hello.py src/hello.ts src/Hello.php; do [ ! -f "$d/$f" ] || break; done
  edited "$d/$f"
  expect_code 2 "post-edit with a check tool that the dev container lacks"
  has "check NOT run: no-such-tool: not found in the dev container"
  unplant

  step "$s: the pre-bash hook"
  # A quoted or arithmetic << starts no here-document, so the line after it is still a command.
  # shellcheck disable=SC2016 # the hook gets the commands as written, JSON-escaped
  for c in "npm install" "python x.py" "cd src && npx eslint ." "FOO=1 composer install" "sh -c 'pip install x'" \
      "./node_modules/.bin/vitest" "vendor/bin/phpunit" "echo \$(php -v)" "sudo -u bob python x" \
      "timeout -s KILL 5 python x" 'sh <<EOF\npip install x\nEOF' 'echo \"<<EOF\"\npython x.py' \
      "echo '<<EOF'\\npython x.py" 'grep -rn \"<<\" foo\npython x.py' 'echo $((1<<2))\npython x'; do
    bash_cmd "$c"
    expect_code 2 "pre-bash for: $c"
    has "Language tools run in the dev container"
    has "docker compose -f docker-compose.dev.yml exec -T dev "
  done
  bash_cmd "npm install"
  has "docker compose -f docker-compose.dev.yml exec -T dev npm install"
  # shellcheck disable=SC2016 # the hook gets the commands as written; the last one is JSON-escaped
  for c in "git status" "make gates" "make dev && make gates" "docker compose -f docker-compose.dev.yml exec -T dev npm test" \
      "ls -la | grep python" "cat README.md" "git commit -m 'npm install; python x'" "command -v python3" \
      "command -V node" 'git commit -m \"$(cat <<'"'"'EOF'"'"'\nFix tests\n\npytest now runs in the dev container\nEOF\n)\"'; do
    bash_cmd "$c"
    expect_code 0 "pre-bash for: $c"
    [ ! -s "$out" ] && [ ! -s "$err" ] || { both; fail "$s: pre-bash printed something for: $c"; }
  done
  printf 'allow npm\nblock hello-tool\n' >> "$d/.claude/hooks/checks.conf"
  bash_cmd "npm install"
  expect_code 0 "pre-bash for npm with allow npm in checks.conf"
  bash_cmd "hello-tool --version"
  expect_code 2 "pre-bash for hello-tool with block hello-tool in checks.conf"
  unplant

  step "$s: the checks behind the hooks, called with plain arguments (another agent's adapter)"
  for f in hello.py src/hello.ts src/Hello.php; do [ ! -f "$d/$f" ] || break; done
  direct check-file.sh "$d/$f"
  expect_code 0 "check-file.sh of the clean $f"; silent "check-file.sh of the clean $f"
  direct check-file.sh "$d/README.md"
  expect_code 0 "check-file.sh of README.md"; silent "check-file.sh of README.md"
  direct check-file.sh
  expect_code 0 "check-file.sh without a file"; silent "check-file.sh without a file"
  plant "$s" lint
  direct check-file.sh "$f"
  expect_code 2 "check-file.sh of a file with a lint error"
  has "check failed: $f"; has "$expect"
  unplant
  nl='
'
  for c in "npm install" "cd src && npx eslint ." "sh <<EOF${nl}pip install x${nl}EOF"; do
    direct check-command.sh "$c"
    expect_code 2 "check-command.sh for: $c"
    has "Language tools run in the dev container"
  done
  has "docker compose -f docker-compose.dev.yml exec -T dev pip install x"
  for c in "git status" "make gates" "git commit -m 'npm install'" ""; do
    direct check-command.sh "$c"
    expect_code 0 "check-command.sh for: $c"; silent "check-command.sh for: $c"
  done
  # A long command goes on stdin: sh check-command.sh - (the Claude Code adapter does so).
  if (cd / && printf 'npm install' | sh "$d/.claude/hooks/check-command.sh" - > "$out" 2> "$err"); then code=0
  else code=$?; fi
  expect_code 2 "check-command.sh - with npm install on stdin"
  has "docker compose -f docker-compose.dev.yml exec -T dev npm install"

  step "$s: the language server, started as the plugin starts it, from a stopped dev stack"
  expect_ok in_dir "$d" make down
  ! running "$name-dev-dev-1" || fail "$s: make down left the dev container running"
  edited "$d/README.md"
  expect_code 0 "post-edit of README.md with the dev stack down"
  for f in hello.py src/hello.ts src/Hello.php; do [ ! -f "$d/$f" ] || break; done
  edited "$d/$f"
  expect_code 2 "post-edit with the dev stack down"
  has "check NOT run: the dev container is not running"
  plant "$s" type
  case "$s" in python) lsp pyright "$f" python ;; ts) lsp typescript "$f" typescript ;; php) lsp php "$f" php ;; esac
  running "$name-dev-dev-1" || fail "$s: the plugin's command did not start the dev container"
  measure "language server: $(sed -n 's/.*"initialized_s": \([0-9.]*\).*"diagnostics_s": \([0-9.]*\).*/initialized after \1 s, the type error after \2 s/p' "$tmp/lsp-report") (session $total s, from a stopped stack)"
  measure "  its message: $(sed -n 's/^diagnostic: //p' "$tmp/lsp-report")"
  unplant
  expect_ok in_dir "$d" make down
done

step "OK"
cat "$tmp/measure"
