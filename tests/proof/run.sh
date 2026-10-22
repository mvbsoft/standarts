#!/bin/sh
# Tests scripts/proof.sh, the proof copy of prompt/start.md section 3, on a sample project built from
# templates/project with tests/project/sample as its application:
#   A. a project with git and files not committed yet: create (the copy holds those files, one
#      commit pushed as the stage and the prod branch, the -proof names, make bootstrap NAME=proof,
#      the project's git untouched, a second create refused), make dev in the copy and in a worktree
#      $t/wt, copies of an old stack in $t (one running, one stopped with its volume, one under the
#      name of a stack this machine had before create, whose volume clean keeps), stage and prod
#      (the server clones with their .env: chmod 600, no change-me, STATUS_TOKEN, DOCKER_GID, free
#      ports, BACKUP_COPY_TO=/backup/.copy, BACKUP_TIME the start of this hour), a re-deploy that builds
#      nothing, a change pushed and deployed, backup sets owned by the backup user and
#      make backup-copy-check OK, then clean: nothing of the copy is left in Docker or on disk;
#   B. create refused while a volume of a proof name exists, and for a project with build secrets;
#   C. a folder without .git (new mode) and no git identity: the copy gets its own git with the
#      branches of the Makefile; an own image of the commit there before the first deploy is
#      noted; a deploy that fails before its first start, with no backup image built; clean refuses a stack of a proof name that runs from another folder and leaves it
#      alone, then removes everything else.
# Usage: sh tests/proof/run.sh [<proof.sh>] (another proof.sh, to see the test fail on a broken one).
# Everything it creates in Docker is named stdproof*; it removes all of it on exit, and nothing
# else, so other tests' objects survive a parallel run.
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
proof=${1:-$root/scripts/proof.sh}
[ -f "$proof" ] || { echo "FAIL: $proof does not exist"; exit 1; }
proof=$(cd "$(dirname "$proof")" && pwd)/$(basename "$proof")
# The pinned images of the sample's application and database (the first run downloads them).
py=python:3.12.13-slim@sha256:229a2c5bfa27522db7815ea81f9bed70af17ccb9de9fc7ad142b1877b5830d36
pg=postgres:16.15-alpine@sha256:721873c34ceb9f8d8fc265984940dc982404c105f19ad51be9fdc5970a6080ea
for i in "$py" "$pg"; do
  docker image inspect "$i" >/dev/null 2>&1 || docker pull -q "$i" >/dev/null \
    || { echo "FAIL: $i is not on this machine and cannot be pulled"; exit 1; }
done

tmp=$(mktemp -d /tmp/stdproof.XXXXXX)
out=$tmp/out
cleanup() {
  status=$?
  set +e
  for c in $(docker ps -a --format '{{.Names}}' | grep '^stdproof'); do docker rm -f "$c" >/dev/null; done
  for v in $(docker volume ls -q | grep '^stdproof'); do docker volume rm "$v" >/dev/null; done
  for n in $(docker network ls --format '{{.Name}}' | grep '^stdproof'); do docker network rm "$n" >/dev/null; done
  for i in $(docker images --format '{{.Repository}}:{{.Tag}}' | grep '^stdproof'); do docker rmi "$i" >/dev/null; done
  # The backup sets belong to the backup container's user, so a root container removes them.
  docker run --rm --network none --user 0:0 --entrypoint sh -v "$tmp:/t" "$py" -c 'rm -rf /t/* /t/.[!.]*' >/dev/null 2>&1
  rm -rf "$tmp"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 1' INT TERM

# The test's own git identity and no user or system git config; proof.sh puts its folder in TMPDIR.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=stdproof GIT_AUTHOR_EMAIL=stdproof@example.invalid
export GIT_COMMITTER_NAME=stdproof GIT_COMMITTER_EMAIL=stdproof@example.invalid
export TMPDIR="$tmp"
unset COMPOSE_FILE COMPOSE_PROJECT_NAME COMPOSE_PROFILES MAKEFLAGS MAKELEVEL MFLAGS

step() { printf 'proof: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; exit 1; }
run() { if "$@" > "$out" 2>&1; then code=0; else code=$?; fi; }
expect_ok() { run "$@"; [ "$code" -eq 0 ] || { cat "$out"; fail "expected success: $*"; }; }
expect_fail() { run "$@"; [ "$code" -ne 0 ] || { cat "$out"; fail "expected a failure: $*"; }; }
has() { grep -qF -- "$1" "$out" || { cat "$out"; fail "the output lacks: $1"; }; }
lacks() { ! grep -qF -- "$1" "$out" || { cat "$out"; fail "the output has: $1"; }; }
in_dir() { d=$1; shift; (cd "$d" && "$@"); }
same() { [ "$1" = "$2" ] || fail "$3: '$1', expected '$2'"; }
envvar() { sed -n "s/^$2=//p" "$1/.env" | tail -n 1; }
running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = true ] || fail "$1 is not running"; }
# Every git push runs without a terminal (setsid), so the pre-push hook never waits for an answer.
push() { d=$1; shift; in_dir "$d" setsid -w git push "$@"; }
gid=$(stat -c %g /var/run/docker.sock)
# this_hour [<hours later>]: the BACKUP_TIME proof.sh writes now, the start of this hour in UTC
# (or that many hours after it).
this_hour() { printf '%02d:00' $(( ($(date -u +%H | sed 's/^0//') + ${1:-0}) % 24 )); }
# left: every Docker object whose name starts with stdproof, one per line (empty: none).
left() {
  { docker ps -a --format 'container {{.Names}}'; docker volume ls --format 'volume {{.Name}}'
    docker network ls --format 'network {{.Name}}'; docker images --format 'image {{.Repository}}:{{.Tag}}'
  } | grep ' stdproof' || :
}
nothing_left() {
  l=$(left)
  [ -z "$l" ] || { printf '%s\n' "$l"; fail "$1: the objects above are left"; }
}

# sample <folder>: the sample project from the templates, with <repo> = stdproof.
sample() {
  s=$1
  mkdir "$s"
  cp -R "$root/templates/project/." "$s/"
  mkdir -p "$s/scripts"
  cp "$root/templates/check-compose/scripts/"* "$s/scripts/"
  cp -R "$root/tests/project/sample/." "$s/"
  find "$s" -type f -exec chmod 644 {} +
  chmod 755 "$s/.githooks/pre-push"
  pg_slot='<postgres image[^>]*>\(:<[a-z]*>@sha256:<digest>\)\{0,1\}'
  for f in docker-compose.dev.yml docker-compose.stage.yml docker-compose.prod.yml; do
    sed -i -e 's|<repo>|stdproof|' -e "s|$pg_slot|$pg|" \
      -e "s|<the image's data path>|/var/lib/postgresql/data|" \
      -e "s|<the image's postgres uid>:<gid>|70:70|" \
      -e 's|"<a command that checks the application, with authentication>"|"python", "app.py", "get", "/health"|' \
      -e 's|interval: [0-9]*s|interval: 1s|' -e 's|^  db: {}$|&\n  data: {}|' "$s/$f"
  done
  sed -i "s|$pg_slot|$pg|" "$s/docker/backup/Dockerfile"
  sed -i 's|^    tmpfs: \[/tmp\]$|&\n    volumes: ["data:/data"]|' "$s/docker-compose.stage.yml" "$s/docker-compose.prod.yml"
  sed -i 's|^\(    volumes: \[.*run make dev}"\)\]$|\1, "data:/data"]|' "$s/docker-compose.dev.yml"
  sed -i -e 's|^MIGRATE =$|MIGRATE = python migrate.py|' -e 's|^RUN =$|RUN = python app.py|' \
    -e 's|^LINT =$|LINT = sh -n scripts/tuning-check.sh|' \
    -e 's|^TEST =$|TEST = python -m unittest discover -s tests|' \
    -e 's|^SECRETS =$|SECRETS = echo "secrets: none found"|' \
    -e 's|^NETWORKS =$|NETWORKS = PROXY_NETWORK|' "$s/Makefile"
  printf '# The external network of the test.\nPROXY_NETWORK=stdproof-proxy\n' >> "$s/.env.example"
  # Twelve hours from now, so a clone that kept this value is told from one proof.sh set.
  sed -i "s|^BACKUP_TIME=.*|BACKUP_TIME=$(this_hour 12)|" "$s/.env.example"
  if grep -n '^[^#]*<[a-z]' "$s/Makefile" "$s/.env.example" "$s"/docker-compose.*.yml "$s/docker/backup/Dockerfile"; then
    fail "a placeholder above is not filled by this test"
  fi
}

step "A. a project with git and uncommitted files: create"
src=$tmp/stdproof
sample "$src"
git init -q -b main "$src"
git -C "$src" add -A
git -C "$src" commit -q -m "the sample project"
# Not committed yet: a changed file, a new file, a deleted file; ignored: .env and a secret file.
printf 'An uncommitted line.\n' >> "$src/README.md"
printf 'not committed yet\n' > "$src/notes.txt"
rm "$src/docs/how-to/backups.md"
printf 'X=1\n' > "$src/.env"
printf 'secret\n' > "$src/.env.secret"
git_state() {
  git -C "$src" rev-parse HEAD; git -C "$src" for-each-ref; git -C "$src" status --porcelain --untracked-files=all
  git -C "$src" config --local --list; git -C "$src" stash list; git -C "$src" worktree list
}
before=$(git_state)
# A stack of this machine stopped before create, its volume kept: a copy of it in $t that uses the
# same project name must not lose that volume in clean.
docker volume create --label com.docker.compose.project=stdproof-mine stdproof-mine_data >/dev/null
expect_ok in_dir "$src" sh "$proof" create
t=$(cd "$src" && sh "$proof" path)
same "$t" "$(dirname "$t")/stdproof-proof-$(printf '%s' "$src" | git hash-object --stdin | cut -c1-6)" "the proof folder"
same "$(dirname "$t")" "$tmp" "the parent of the proof folder (TMPDIR)"
has "$t"
has "bootstrap: a second copy: its own dev stack (DEV_SUFFIX=-proof) on free ports"
same "$(git_state)" "$before" "the project's git state after create"
[ -f "$t/p/notes.txt" ] || fail "the copy lacks the new file not committed yet"
grep -qx 'An uncommitted line.' "$t/p/README.md" || fail "the copy lacks the uncommitted change"
[ ! -e "$t/p/docs/how-to/backups.md" ] || fail "the copy still has the file deleted in the project"
[ ! -e "$t/p/.env.secret" ] || fail "the copy has an ignored file"
same "$(git -C "$t/p" status --porcelain)" "" "git status in the copy"
same "$(git -C "$t/p" ls-files -s .githooks/pre-push | cut -c1-6)" 100755 "the mode of the pre-push hook in the copy"
head=$(git -C "$t/p" rev-parse HEAD)
same "$(git -C "$t/remote.git" rev-parse main)" "$head" "the stage branch of the remote"
same "$(git -C "$t/remote.git" rev-parse prod)" "$head" "the prod branch of the remote"
same "$(git -C "$t/p" ls-tree --name-only HEAD notes.txt)" notes.txt "notes.txt in the pushed commit"
same "$(git -C "$t/p" remote get-url origin)" "$t/remote.git" "the origin of the copy"
same "$(git -C "$t/p" config core.hooksPath)" .githooks "core.hooksPath of the copy"
for e in stage prod; do
  f=$t/p/docker-compose.$e.yml
  grep -qx "name: stdproof-proof-$e" "$f" || fail "$f has no name: stdproof-proof-$e"
  for i in app backup status; do
    grep -qxF "    image: stdproof-proof-$i:\${IMAGE_TAG:?}" "$f" || fail "$f has no image stdproof-proof-$i"
  done
  ! grep -q 'image: stdproof-\(app\|backup\|status\):' "$f" || fail "$f still names an image of the project"
done
same "$(envvar "$t/p" DEV_SUFFIX)" -proof "DEV_SUFFIX of the copy"
same "$(envvar "$t/p" APP_PORT)" "" "APP_PORT of the copy"
same "$(envvar "$t/p" PROXY_NETWORK)" stdproof-proxy-proof "the external network of the copy"
docker network inspect stdproof-proxy-proof >/dev/null 2>&1 || fail "make bootstrap did not create the copy's network"
! docker network inspect stdproof-proxy >/dev/null 2>&1 || fail "the copy created the project's own network"
expect_fail in_dir "$src" sh "$proof" create
has "$t"
same "$(git_state)" "$before" "the project's git state after a refused create"

step "A. make dev in the copy and in a worktree; a copy of an old stack, running and stopped"
expect_ok in_dir "$t/p" make dev
running stdproof-dev-proof-dev-1
git -C "$t/p" worktree add -q "$t/wt"
expect_ok in_dir "$t/wt" make dev
wt=stdproof-dev$(envvar "$t/wt" DEV_SUFFIX)
case "$wt" in stdproof-dev-wt-??????) ;; *) fail "the worktree's dev stack is $wt" ;; esac
running "$wt-dev-1"
# A folder of the copy finds the copy too.
same "$(cd "$t/wt" && sh "$proof" path)" "$t" "proof.sh path in the worktree of the copy"
# Both dev stacks stop (their containers and volumes stay for clean): a machine has a limited
# number of address pools for networks, and stage and prod need four. The gates start dev again.
expect_ok in_dir "$t/wt" make down
expect_ok in_dir "$t/p" make down
for o in old olddown mine; do
  mkdir "$t/$o"
  # No network: a machine has a limited number of address pools for them.
  printf 'name: stdproof-%s\nservices:\n  s:\n    image: %s\n    command: ["sleep", "600"]\n    network_mode: none\n    volumes: ["data:/data"]\nvolumes:\n  data: {}\n' \
    "$o" "$py" > "$t/$o/docker-compose.yml"
  docker compose -f "$t/$o/docker-compose.yml" up -d --quiet-pull >/dev/null 2>&1 || fail "the old stack $o did not start"
done
docker compose -f "$t/olddown/docker-compose.yml" down >/dev/null 2>&1
docker volume inspect stdproof-olddown_data >/dev/null 2>&1 || fail "the stopped old stack has no volume"

step "A. stage and prod: the server clones, their .env, the deploy"
# Each clone's BACKUP_TIME is compared with this_hour before and after the clone was made, so a new
# hour in between does not fail.
bt_before=$(this_hour)
expect_ok in_dir "$src" sh "$proof" stage
lacks "note: "
tree=$(git -C "$t/p" rev-parse "HEAD^{tree}")
has "build: stdproof-proof-app:$tree from commit $head"
has "build: stdproof-proof-backup:$tree from commit $head"
has "OK: stage runs $head"
running stdproof-proof-stage-app-1
running stdproof-proof-stage-status-1
same "$(git -C "$t/stage" rev-parse HEAD)" "$head" "the commit of the stage clone"
for e in stage prod; do
  # prod deploys the same commit: its images are there already.
  [ "$e" = stage ] || { bt_before=$(this_hour); expect_ok in_dir "$src" sh "$proof" prod; has "OK: prod runs $head"
    lacks "note: "
    ! grep -q '^build: ' "$out" || { cat "$out"; fail "make prod built an image of the commit stage built"; }; }
  c=$t/$e
  same "$(envvar "$c" PROJECT_ENV)" "$e" "PROJECT_ENV of the $e clone"
  # shellcheck disable=SC2012 # ls -l is the POSIX way to read the mode of one file
  same "$(ls -l "$c/.env" | cut -c1-10)" "-rw-------" "the mode of the $e clone's .env"
  ! grep -q '^[^#]*change-me' "$c/.env" || fail "the $e clone's .env still has change-me"
  tok=$(envvar "$c" STATUS_TOKEN)
  [ "${#tok}" -ge 16 ] || fail "STATUS_TOKEN of the $e clone has ${#tok} characters"
  same "$(envvar "$c" DOCKER_GID)" "$gid" "DOCKER_GID of the $e clone"
  same "$(envvar "$c" APP_PORT) $(envvar "$c" STATUS_PORT)" "0 0" "the ports of the $e clone (0: Docker picks a free one)"
  port=$(docker port "stdproof-proof-$e-app-1" 8000 | sed -n '1s/.*://p')
  case "$port" in ''|0|*[!0-9]*) fail "the $e application has no free host port: '$port'" ;; esac
  has "127.0.0.1:$port->8000/tcp"
  same "$(envvar "$c" PROXY_NETWORK)" stdproof-proxy-proof "the external network of the $e clone"
  same "$(envvar "$c" BACKUP_COPY_TO)" /backup/.copy "BACKUP_COPY_TO of the $e clone (a local copy inside BACKUP_DIR)"
  bt=$(envvar "$c" BACKUP_TIME)
  [ "$bt" = "$bt_before" ] || [ "$bt" = "$(this_hour)" ] \
    || fail "BACKUP_TIME of the $e clone is '$bt', not the start of this hour ($(this_hour) UTC)"
done
running stdproof-proof-prod-app-1
# prod stops (its volumes stay for clean), for the networks the gates of the push need.
IMAGE_TAG=$tree docker compose -f "$t/prod/docker-compose.prod.yml" --project-directory "$t/prod" down >/dev/null 2>&1 \
  || fail "the prod stack did not stop"
expect_ok in_dir "$src" sh "$proof" stage
! grep -q '^build: ' "$out" || { cat "$out"; fail "a re-deploy built an image"; }
has "OK: stage runs $head"

step "A. a change committed in the copy, pushed, deployed"
printf 'a change\n' > "$t/p/change.txt"
git -C "$t/p" add change.txt
git -C "$t/p" commit -q -m "a change"
head2=$(git -C "$t/p" rev-parse HEAD)
expect_ok push "$t/p" -q origin HEAD:main
has "make gates: OK"
expect_ok in_dir "$src" sh "$proof" stage
has "build: stdproof-proof-app:$(git -C "$t/p" rev-parse "HEAD^{tree}") from commit $head2"
has "OK: stage runs $head2"
# Backup sets on disk, owned by the backup service's user.
expect_ok in_dir "$t/stage" make backup
d=$t/stage/docker/backup/data
[ -d "$d" ] && [ "$(stat -c %u "$d")" != "$(id -u)" ] || fail "the stage backup folder is not the backup user's"
# The off-server copy the clone's .env names: the copy steps of prompt/new.md work there.
expect_ok in_dir "$t/stage" make backup-copy-check
has "copy-check: the test set "
same "$(tail -n 1 "$out")" OK "make backup-copy-check in the stage clone"
same "$(git_state)" "$before" "the project's git state after the deploys"

step "A. clean: nothing of the copy is left"
expect_ok in_dir "$src" sh "$proof" clean
has "removed: the stacks stdproof-dev-proof $wt stdproof-old stdproof-olddown stdproof-proof-prod stdproof-proof-stage,"
has "stdproof-mine had containers or volumes before the proof copy was made"
[ ! -e "$t" ] || { ls -la "$t"; fail "clean left $t"; }
same "$(docker ps -aq --filter label=com.docker.compose.project=stdproof-mine)" "" "the containers of the copy of stdproof-mine"
docker volume inspect stdproof-mine_data >/dev/null 2>&1 || fail "clean removed the volume of stdproof-mine, which was there before create"
docker volume rm stdproof-mine_data >/dev/null
nothing_left "after clean"
same "$(git_state)" "$before" "the project's git state after clean"
expect_ok in_dir "$src" sh "$proof" clean
has "nothing to clean"

step "B. create refused while a volume of a proof name exists"
docker volume create --label com.docker.compose.project=stdproof-proof-stage stdproof-proof-stage_db >/dev/null
expect_fail in_dir "$src" sh "$proof" create
has "stdproof-proof-stage"
[ ! -e "$t" ] || fail "a refused create left $t"
docker volume rm stdproof-proof-stage_db >/dev/null

step "B. create refused at once for a project with build secrets, files git ignores"
cp "$src/Makefile" "$tmp/Makefile.kept"
sed -i 's|^BUILD_SECRETS =$|BUILD_SECRETS = token=.env.token|' "$src/Makefile"
grep -qx 'BUILD_SECRETS = token=.env.token' "$src/Makefile" || fail "the Makefile has no empty BUILD_SECRETS setting"
printf 'secret\n' > "$src/.env.token"
expect_fail in_dir "$src" sh "$proof" create
has "BUILD_SECRETS in the Makefile settings names .env.token"
[ ! -e "$t" ] || fail "a refused create left $t"
cp "$tmp/Makefile.kept" "$src/Makefile"
rm "$src/.env.token"

step "C. a folder without .git, no git identity: create"
new=$tmp/stdproof-new
sample "$new"
# The application's build fails in the runtime stage: the deploy stops before its first start,
# before the backup image (after app in IMAGES) is built.
sed -i 's|^COPY \. \./$|&\nRUN false|' "$new/docker/app/Dockerfile"
grep -qx 'RUN false' "$new/docker/app/Dockerfile" || fail "the sample's Dockerfile has no COPY . ./ line"
expect_ok in_dir "$new" env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL \
  sh "$proof" create
tn=$(cd "$new" && sh "$proof" path)
[ ! -e "$new/.git" ] || fail "create made a .git in the project folder"
same "$(git -C "$tn/p" symbolic-ref --short HEAD)" main "the branch of the copy (STAGE_BRANCH)"
same "$(git -C "$tn/remote.git" rev-parse main)" "$(git -C "$tn/p" rev-parse HEAD)" "the stage branch of the remote"
same "$(git -C "$tn/remote.git" rev-parse prod)" "$(git -C "$tn/p" rev-parse HEAD)" "the prod branch of the remote"
same "$(git -C "$tn/p" status --porcelain)" "" "git status in the copy"
grep -qx 'PROXY_NETWORK=stdproof-proxy-proof' "$tn/p/.env.example" || fail "the copy's .env.example keeps the project's network"

step "C. a deploy that fails before its first start, with no backup image"
# An own image of the commit there before the first deploy, as make image-scan in $t/p leaves it
# (REVIEW №3): proof.sh says that make stage builds no such image.
treen=$(git -C "$tn/p" rev-parse "HEAD^{tree}")
docker tag "$py" "stdproof-proof-status:$treen"
expect_fail in_dir "$new" sh "$proof" stage
has "note: stdproof-proof-status:$treen is on this machine before the first deploy (make image-scan in $tn/p builds it too): make stage builds no status"
has "building stdproof-proof-app for commit"
same "$(docker images -q 'stdproof-proof-backup')" "" "the backup image after the failed build"

step "C. clean leaves a stack of a proof name that runs from another folder"
docker run -d --name stdproof-foreign --label com.docker.compose.project=stdproof-proof-prod \
  --label "com.docker.compose.project.working_dir=$tmp/elsewhere" "$py" sleep 600 >/dev/null
expect_fail in_dir "$new" sh "$proof" clean
has "NOT removed: stdproof-proof-prod, which also has containers started in $tmp/elsewhere"
running stdproof-foreign
[ -d "$tn" ] || fail "clean removed $tn although it left a project alone"
docker rm -f stdproof-foreign >/dev/null
expect_ok in_dir "$new" sh "$proof" clean
[ ! -e "$tn" ] || { ls -la "$tn"; fail "clean left $tn"; }
nothing_left "after clean of the copy without git"

step "OK"
