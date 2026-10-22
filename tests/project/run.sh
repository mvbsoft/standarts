#!/bin/sh
# Builds a sample project from templates/project (with tests/project/sample as its application) and
# runs its make targets end to end against a local bare remote: dev, a project target, the base
# check targets alone, the group targets gates and verify with their summary, make fix, the
# pre-push hook (its question in a terminal, its warning without one), mutation testing in its own
# container with the limits of .env, image-scan (also through a symbolic link, after a failed git
# archive, and stopped with INT), exact own image names, build secrets, a stage deploy that builds
# its images on the server and migrates past the image's ENTRYPOINT, a re-deploy that builds
# nothing, make logs with and without TAIL, make migrate refused on a server, .env values read as
# Compose reads them, a failed migration, a failed build, a failed start, rollback with a kept and a
# removed image, restart (also with a new network name), the template's tuning-check, make images,
# the lock that lets one of them run at a time in a clone, a bad KEEP_IMAGES, the pruning of old
# images, a merge into the prod branch that reuses the image, a fix made only on prod, second copies
# (NAME=), parity and check-compose, the backup targets (S, SET, FROM, NO_SAFETY and CONFIRM only
# from make's command line; make restore confirmed by the database name typed when its input is a
# terminal, by CONFIRM=yes otherwise, never by one from MAKEFLAGS or a parent make; NO_SAFETY=1);
# and one copy of a stage, prod or dev project
# per machine (a second clone is refused), a deploy recorded before its tuning check, the log
# archive before containers are replaced, the log limits of dev, the free space before a deploy
# (make restart and make rollback count only the images they must build), a backup set before the
# migration of a deploy, the estimates (free space; a failed set or copy before the migration) that
# without a terminal stop unless RISK=yes is typed on make's command line, a
# .env the project had before, build secrets in the dev build, the application's own database
# role, a server .env other users can read, the Dockerfile check of make lint, and the status
# service of stage (deployed with the rest, GET /status with and without the token, a DOCKER_GID
# that is not the socket's group refused by make stage and make restart before anything changes
# and by no backup command, make restore or make images, DOCKER_GID written by make bootstrap) (standard ENV-02 to ENV-05, ENV-09, QLT-01, QLT-02, OPS-01, OPS-02, OPS-04). It prints how long the builds, a
# re-deploy and a rollback took. STDTEST_TRIVY=1 adds trivy to the sample's dev image, so make
# image-scan scans for real (it downloads trivy's vulnerability database, about 130 MiB).
# Everything it creates in Docker is named stdtest-dev*, stdtest-stage*, stdtest-prod*,
# stdtest-ports, stdtest-proxy*, stdtest-app*, stdtest-backup* or stdtest-status*; it removes all of it on exit, and
# nothing else, so other tests' stdtest* objects survive a parallel run.
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
ours='^stdtest-(dev|stage|prod|ports|proxy)'

# git records the mode of the hook; a hook without the executable bit is ignored by git.
mode=$(git -C "$root" ls-files -s templates/project/.githooks/pre-push 2>/dev/null | cut -c1-6) || mode=
if [ -n "$mode" ] && [ "$mode" != 100755 ]; then
  echo "FAIL: templates/project/.githooks/pre-push is $mode in git, not 100755: git would skip the hook"
  exit 1
fi

tmp=$(mktemp -d /tmp/stdtest.XXXXXX)
out=$tmp/out
cleanup() {
  status=$?
  set +e
  for c in $(docker ps -a --format '{{.Names}}' | grep -E "$ours"); do docker rm -f "$c" >/dev/null; done
  for v in $(docker volume ls -q | grep -E "$ours"); do docker volume rm "$v" >/dev/null; done
  for n in $(docker network ls --format '{{.Name}}' | grep -E "$ours"); do docker network rm "$n" >/dev/null; done
  for i in $(docker images --format '{{.Repository}}:{{.Tag}}' | grep -E '^stdtest-(app|backup|dev|status)'); do
    docker rmi "$i" >/dev/null
  done
  # The backup sets belong to the backup container's postgres user, so a root container removes them.
  docker run --rm --network none -v "$tmp:/t" busybox:latest sh -c 'rm -rf /t/*/docker/backup/data' >/dev/null 2>&1
  rm -rf "$tmp"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 1' INT TERM

# The test's own git identity and no user or system git config.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=stdtest GIT_AUTHOR_EMAIL=stdtest@example.invalid
export GIT_COMMITTER_NAME=stdtest GIT_COMMITTER_EMAIL=stdtest@example.invalid
unset COMPOSE_FILE COMPOSE_PROJECT_NAME COMPOSE_PROFILES MAKEFLAGS MAKELEVEL MFLAGS

step() { printf 'project: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; exit 1; }
# run <command>: its output goes to $out, its exit code to $code.
run() { if "$@" > "$out" 2>&1; then code=0; else code=$?; fi; }
expect_ok() { run "$@"; [ "$code" -eq 0 ] || { cat "$out"; fail "expected success: $*"; }; }
expect_fail() { run "$@"; [ "$code" -ne 0 ] || { cat "$out"; fail "expected a failure: $*"; }; }
has() { grep -qF -- "$1" "$out" || { cat "$out"; fail "the output lacks: $1"; }; }
in_dir() { d=$1; shift; (cd "$d" && "$@"); }
wait_for() { i=0; while [ ! -e "$1" ]; do i=$((i + 1)); [ "$i" -lt 600 ] || fail "timed out waiting for $1"; sleep 0.1; done; }
envvar() { sed -n "s/^$2=//p" "$1/.env"; }
same() { [ "$1" = "$2" ] || fail "$3: '$1', expected '$2'"; }
remote_sha() { git -C "$tmp/remote.git" rev-parse "$1"; }
cid() { docker inspect -f '{{.Id}}' "$1"; }
image_id() { docker image inspect -f '{{.Id}}' "$1"; }
image_of() { docker inspect -f '{{.Config.Image}}' "$1"; }
running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = true ] || fail "$1 is not running"; }
serves() { docker exec "$1" python app.py get /; }
commit() { git -C "$dev" commit -q -am "$1"; git -C "$dev" rev-parse HEAD; }
tree() { git -C "$dev" rev-parse "$1^{tree}"; }
app_image() { printf 'stdtest-app:%s' "$(tree "$1")"; }  # the images of a commit
backup_image() { printf 'stdtest-backup:%s' "$(tree "$1")"; }
status_image() { printf 'stdtest-status:%s' "$(tree "$1")"; }
built() {
  has "build: $(app_image "$1") from commit $1"; has "build: $(backup_image "$1") from commit $1"
  has "build: $(status_image "$1") from commit $1"
}
built_nothing() { ! grep -q '^build: ' "$out" || { cat "$out"; fail "$1 built an image"; }; }
clock() { t0=$(date +%s); }
took() { # took <what>: the seconds since clock, and the build times in the output
  printf 'project:   %s: %s s\n' "$1" "$(( $(date +%s) - t0 ))"
  sed -n 's/^build: \(.* built in .*\)/project:     \1/p' "$out"
}
server_clone() { # server_clone <folder> <env> <port> <status port>: a clone with .env from .env.example
  git clone -q "$tmp/remote.git" "$1"
  cp "$1/.env.example" "$1/.env"
  # The daily backup an hour ago: the first one is tomorrow, so none starts during the test.
  sed -i -e "s|^PROJECT_ENV=.*|PROJECT_ENV=$2|" -e "s|^DB_PASSWORD=.*|DB_PASSWORD=$2-secret|" \
    -e "s|^APP_PORT=.*|APP_PORT=$3|" -e "s|^BACKUP_DB_PASSWORD=.*|BACKUP_DB_PASSWORD=$2-backup|" \
    -e "s|^APP_DB_PASSWORD=.*|APP_DB_PASSWORD=$2app|" \
    -e "s|^BACKUP_COPY_PASSWORD=.*|BACKUP_COPY_PASSWORD=$2-copy|" \
    -e "s|^STATUS_TOKEN=.*|STATUS_TOKEN=$2-status-token-0123456789|" -e "s|^STATUS_PORT=.*|STATUS_PORT=$4|" \
    -e "s|^DOCKER_GID=.*|DOCKER_GID=$gid|" \
    -e "s|^BACKUP_TIME=.*|BACKUP_TIME=$(printf '%02d:00' $(( ($(date -u +%H | sed 's/^0//') + 23) % 24 )))|" "$1/.env"
  # Stage copies off the server to a local restic repository inside its BACKUP_DIR.
  [ "$2" != stage ] || sed -i 's|^BACKUP_COPY_TO=.*|BACKUP_COPY_TO=/backup/.copy|' "$1/.env"
  # Only the owner reads the secrets of a server (operations.md, the first server).
  chmod 600 "$1/.env"
}
# app_role <db container> <password>: rolsuper of the application's role, logged in as the
# application logs in (the password is checked).
app_role() {
  docker exec -e PGPASSWORD="$2" "$1" sh -c \
    'psql -X -tA -h "$(hostname)" -U app -d postgres -c "SELECT rolsuper FROM pg_roles WHERE rolname = current_user"'
}
add_dev_secret() { # the dev build gets the build secret stdtest from .env.stdtest-secret (docker-compose.dev.yml)
  sed -i 's|^\(    build: {context: ., dockerfile: docker/app/Dockerfile, target: dev\)}$|\1, secrets: [stdtest]}|' \
    "$dev/docker-compose.dev.yml"
  grep -q 'secrets: \[stdtest\]}$' "$dev/docker-compose.dev.yml" || fail "docker-compose.dev.yml has no dev build: line to add the secret to"
  printf 'secrets:\n  stdtest: {file: .env.stdtest-secret}\n' >> "$dev/docker-compose.dev.yml"
}
# archived <clone> <service>: how many files of the service the clone's log archive holds
archived() { find "$1/.deploy/logs" -name "*-$2.log" 2>/dev/null | wc -l; }
# own_kib: two times the own images as make stage counts them (each with its largest local
# version; docker images prints decimal units), in KiB; human <KiB>: as project.sh prints it.
own_kib() {
  t=0
  for n in stdtest-app stdtest-backup stdtest-status; do
    b=$(docker images --format '{{.Size}}' "$n" | awk '{ n = $0 + 0; u = $0; sub(/^[0-9.]+/, "", u)
      m = u == "kB" ? 1e3 : u == "MB" ? 1e6 : u == "GB" ? 1e9 : u == "TB" ? 1e12 : 1; k = sprintf("%.0f", n * m / 1024) + 0
      if (k > b) b = k } END { print b + 0 }')
    t=$((t + b))
  done
  echo "$t"
}
human() {
  awk -v k="$1" 'BEGIN { split("K M G T", u); i = 1; while (k >= 1024 && i < 4) { k /= 1024; i++ }
    printf((k < 10 && i > 1) ? "%.1f%s\n" : "%d%s\n", k, u[i]) }'
}
# Every git push of the test runs without a terminal (setsid: no controlling terminal), so the
# pre-push hook never waits for an answer; b2 gives it a terminal on purpose.
push() { d=$1; shift; in_dir "$d" setsid -w git push "$@"; }
ship() { expect_ok push "$dev" -q; }  # push the code; the hook runs the gates
# no_tty <command>: without a terminal (setsid: no controlling terminal), as an agent or a script
# runs it; make restore then takes only CONFIRM=yes.
no_tty() { setsid -w "$@"; }
# tty_make <answer> <folder> <make arguments>: make in a terminal (script gives it one), with the
# answer typed in; a make that still waits after 300 s fails the test.
tty_make() {
  printf '%s\n' "$1" > "$tmp/answer"; d=$2; shift 2
  run in_dir "$d" env SHELL=/bin/sh script -qefc "timeout --foreground 300 make $*" /dev/null < "$tmp/answer"
  [ "$code" != 124 ] || { cat "$out"; fail "make $* waited for an answer that never came (a docker call took the terminal input?)"; }
}
red=$(printf '\033[31m')
# The group of the Docker socket here: the DOCKER_GID of every server clone.
gid=$(stat -c %g /var/run/docker.sock)
# status_get <container> [<token>]: the HTTP code, then the body, of GET /status inside the status
# container, with that token or none.
status_get() {
  docker exec "$1" python -I -c 'import http.client, sys
c = http.client.HTTPConnection("127.0.0.1", 8080, timeout=10)
c.request("GET", "/status", headers={"Authorization": "Bearer " + sys.argv[1]} if sys.argv[1] else {})
r = c.getresponse()
print(r.status)
print(r.read().decode())' "${2:-}"
}
snap() { # the uncommitted state of a worktree: status, staged and unstaged diff, untracked files
  git -C "$1" status --porcelain --untracked-files=all
  git -C "$1" diff --cached
  git -C "$1" diff
  (cd "$1" && git -c core.quotePath=false ls-files -o --exclude-standard | sort | xargs cat)
}
# pinned <file> <image>: fail unless a third-party image is <name>:<tag>@sha256:<64 hex digits>.
pinned() {
  printf '%s\n' "$2" | grep -qE '^[^@ ]+:[^@:/ ]+@sha256:[0-9a-f]{64}$' \
    || fail "$1 has the image $2, not pinned as <name>:<tag>@sha256:<digest>"
}

# Host ports Docker reports free, for the dev, the stage and the prod clone.
docker run -d --name stdtest-ports -p 127.0.0.1::1 -p 127.0.0.1::2 -p 127.0.0.1::3 -p 127.0.0.1::4 \
  -p 127.0.0.1::5 busybox:latest \
  sleep 60 >/dev/null
dev_port=$(docker port stdtest-ports 1 | sed -n '1s/.*://p')
stage_port=$(docker port stdtest-ports 2 | sed -n '1s/.*://p')
prod_port=$(docker port stdtest-ports 3 | sed -n '1s/.*://p')
stage_status_port=$(docker port stdtest-ports 4 | sed -n '1s/.*://p')
prod_status_port=$(docker port stdtest-ports 5 | sed -n '1s/.*://p')
docker rm -f stdtest-ports >/dev/null

step "the sample project from the templates"
dev=$tmp/dev stage=$tmp/stage prod=$tmp/prod
mkdir "$dev"
cp -R "$root/templates/project/." "$dev/"
mkdir -p "$dev/scripts"
cp "$root/templates/check-compose/scripts/"* "$dev/scripts/"
cp -R "$root/tests/project/sample/." "$dev/"
if [ -n "${STDTEST_TRIVY:-}" ]; then
  # trivy 0.75.0, pinned by digest, in the dev stage (the last one) of the sample's Dockerfile.
  printf 'COPY --from=%s /usr/local/bin/trivy /usr/local/bin/trivy\n' \
    aquasec/trivy:0.75.0@sha256:af6acf9a6b85dfe389a1941505c0ce9efef52a4719635e1a962f022a3d855daa \
    >> "$dev/docker/app/Dockerfile"
fi
find "$dev" -type f -exec chmod 644 {} +
chmod 755 "$dev/.githooks/pre-push"
# The database image of the sample, pinned by its tag and digest (standard ENV-03).
pg=postgres:16.15-alpine@sha256:721873c34ceb9f8d8fc265984940dc982404c105f19ad51be9fdc5970a6080ea
docker image inspect "$pg" >/dev/null 2>&1 || docker pull -q "$pg" >/dev/null \
  || fail "$pg is not available and cannot be pulled"
# The placeholder of the database image, in its older and its newer wording.
pg_slot='<postgres image[^>]*>\(:<[a-z]*>@sha256:<digest>\)\{0,1\}'
for f in docker-compose.dev.yml docker-compose.stage.yml docker-compose.prod.yml; do
  sed -i -e 's|<repo>|stdtest|' \
    -e "s|$pg_slot|$pg|" \
    -e "s|<the image's data path>|/var/lib/postgresql/data|" \
    -e "s|<the image's postgres uid>:<gid>|70:70|" \
    -e 's|"<a command that checks the application, with authentication>"|"python", "app.py", "get", "/health"|' \
    -e 's|interval: [0-9]*s|interval: 1s|' \
    -e 's|^  db: {}$|&\n  data: {}|' "$dev/$f"
done
sed -i "s|$pg_slot|$pg|" "$dev/docker/backup/Dockerfile"
# Every third-party image the sample uses, in a Dockerfile (FROM, COPY --from) or a compose file
# (image:), is pinned by tag and digest; the stages of a Dockerfile and the own images are not
# third-party.
for f in "$dev"/docker/*/Dockerfile; do
  stages=" $(sed -n 's/^FROM .* [Aa][Ss] \([A-Za-z0-9_.-]*\)$/\1/p' "$f" | tr '\n' ' ')"
  sed -n -e 's/^FROM \([^ ]*\).*/\1/p' -e 's/^COPY --from=\([^ ]*\).*/\1/p' "$f" > "$tmp/images"
  while read -r i; do
    case "$stages" in *" $i "*) continue ;; esac
    pinned "${f#"$dev/"}" "$i"
  done < "$tmp/images"
done
for f in "$dev"/docker-compose.*.yml; do
  sed -n 's/^ *image: *\([^ #]*\).*/\1/p' "$f" | grep -v '^stdtest-' > "$tmp/images" || :
  while read -r i; do pinned "${f#"$dev/"}" "$i"; done < "$tmp/images"
done
rm "$tmp/images"
# The sample keeps its data in the named volume data, in every environment.
sed -i 's|^    tmpfs: \[/tmp\]$|&\n    volumes: ["data:/data"]|' "$dev/docker-compose.stage.yml" "$dev/docker-compose.prod.yml"
sed -i 's|^\(    volumes: \[.*run make dev}"\)\]$|\1, "data:/data"]|' "$dev/docker-compose.dev.yml"
sed -i -e 's|^MIGRATE =$|MIGRATE = python migrate.py|' -e 's|^RUN =$|RUN = python app.py|' \
  -e 's|^LINT =$|LINT = echo "gate words: a  b \\#1" \&\& sh -n scripts/tuning-check.sh|' \
  -e 's|^TEST =$|TEST = python -m unittest discover -s tests|' \
  -e 's|^SECRETS =$|SECRETS = echo "secrets: none found"|' \
  -e 's|^NETWORKS =$|NETWORKS = PROXY_NETWORK|' "$dev/Makefile"
for v in MIGRATE RUN LINT TEST SECRETS NETWORKS; do
  grep -q "^$v = ." "$dev/Makefile" || fail "the Makefile has no setting '$v =' to fill"
done
for v in E2E SECURITY FIX MUTATION MUTATION_DIFF; do
  grep -qx "$v =" "$dev/Makefile" || fail "the Makefile has no empty setting '$v ='"
done
for v in GATES VERIFY; do
  ! grep -q "$v" "$dev/Makefile" "$dev/scripts/project.sh" || fail "the Makefile or project.sh still names $v"
done
sed -i "s|^APP_PORT=.*|APP_PORT=$dev_port|" "$dev/.env.example"
printf '# The external network of the test.\nPROXY_NETWORK=stdtest-proxy\n' >> "$dev/.env.example"
# A project target of the sample, in the block for them at the end of the Makefile.
if [ "$(tail -n 1 "$dev/Makefile")" != "# $(printf '%094d' 0 | tr 0 -)" ] \
    || ! grep -q '^# ---- Project targets' "$dev/Makefile"; then
  fail "the Makefile does not end with the project-targets block"
fi
printf '.PHONY: hello\nhello: ## say hello (a project target of the sample)\n\t@echo "hello from a project target"\n' >> "$dev/Makefile"
if grep -n '^[^#]*<[a-z]' "$dev/Makefile" "$dev/.env.example" "$dev"/docker-compose.*.yml \
    "$dev/docker/backup/Dockerfile"; then
  fail "a placeholder above is not filled by this test"
fi
grep -q 'data:/data' "$dev/docker-compose.dev.yml" || fail "the dev data volume was not added"
git init -q -b main "$dev"
git -C "$dev" add -A
git -C "$dev" commit -q -m "the sample project"
c1=$(git -C "$dev" rev-parse HEAD)
git init -q --bare -b main "$tmp/remote.git"
git -C "$dev" remote add origin "$tmp/remote.git"
git -C "$dev" push -q -u origin main
git -C "$dev" push -q origin main:prod

step "a. make help, a project target, make dev: bootstrap, the stack, the migration, the addresses"
expect_ok in_dir "$dev" make help
# Every target under the group of where it works, in order, and the project target under "This
# project"; nothing else (no promote or image).
listed=$(awk '/^[^ ]/ { g = $0 } /^  [^ ]/ { printf "%s: %s\n", g, $1 }' "$out")
expected="Dev: dev run shell seed migrate down
Checks: lint test e2e security infra gates verify fix mutation mutation-diff image-scan
Servers: stage prod images rollback restart tuning-check
Any clone: status logs
Backups: backup backup-list backup-drill backup-status backup-copy-check backup-test restore
Service: help bootstrap parity check-compose
This project: hello"
! grep -q 'local stage' "$out" || { cat "$out"; fail "make help says local stage"; }
same "$listed" "$(printf '%s\n' "$expected" | awk -F ': ' '{ n = split($2, t, " "); for (i = 1; i <= n; i++) print $1 ": " t[i] }')" \
  "the groups and targets of make help"
expect_ok in_dir "$dev" make hello
has "hello from a project target"
# NAME counts only on make's command line: WSL, for one, sets NAME to the machine's name.
expect_ok in_dir "$dev" env NAME=from-the-environment make dev
has "bootstrap: created .env from .env.example"
has "migrate: schema 1"
has "127.0.0.1:$dev_port->8000/tcp"
docker network inspect stdtest-proxy >/dev/null || fail "make bootstrap did not create the network named in .env"
same "$(envvar "$dev" PROJECT_ENV)" dev "PROJECT_ENV in .env"
same "$(envvar "$dev" PROJECT_DIR)" "$dev" "PROJECT_DIR in .env"
same "$(envvar "$dev" HOST_UID)" "$(id -u)" "HOST_UID in .env"
same "$(envvar "$dev" HOST_GID)" "$(id -g)" "HOST_GID in .env"
same "$(envvar "$dev" DEV_SUFFIX)" "" "DEV_SUFFIX in .env"
same "$(envvar "$dev" DOCKER_GID)" "$gid" "DOCKER_GID in .env (the group of /var/run/docker.sock)"
same "$(git -C "$dev" config core.hooksPath)" .githooks "core.hooksPath"
running stdtest-dev-dev-1
running stdtest-dev-db-1
same "$(docker exec stdtest-dev-dev-1 cat /data/migrations.log)" "1 none" "the dev migration log"
# The log limits of stage and prod hold in dev too.
for c in stdtest-dev-dev-1 stdtest-dev-db-1; do
  same "$(docker inspect -f '{{.HostConfig.LogConfig.Type}} {{index .HostConfig.LogConfig.Config "max-size"}} {{index .HostConfig.LogConfig.Config "max-file"}}' "$c")" \
    "json-file 10m 3" "the log options of $c"
done
# The application logs in with its own role, which is no superuser, in dev as on a server.
same "$(docker exec stdtest-dev-dev-1 printenv DATABASE_URL)" "postgresql://app:change-me@db:5432/postgres" "DATABASE_URL in dev"
same "$(app_role stdtest-dev-db-1 change-me)" f "the dev application's role is a superuser"
docker exec stdtest-dev-db-1 psql -q -U postgres -c 'create table kept (x int)'
expect_ok in_dir "$dev" make down
[ -z "$(docker ps -aq --filter name=stdtest-dev-)" ] || fail "make down left containers"
docker network rm stdtest-proxy >/dev/null
expect_ok in_dir "$dev" make dev
docker network inspect stdtest-proxy >/dev/null || fail "make dev did not run make bootstrap with an existing .env"
same "$(docker exec stdtest-dev-db-1 psql -tA -U postgres -c "select count(*) from pg_tables where tablename = 'kept'")" \
  1 "the table created before make down"

step "b. the base check targets alone; make gates and make verify run only base targets and end with one summary; make fix"
# Stand-in commands that print their name, so the output shows which ran; a later assignment on
# the command line wins.
stand_in() {
  target=$1; shift
  in_dir "$dev" make "$target" 'LINT=echo lint-ran' 'TEST=echo test-ran' 'E2E=echo e2e-ran' \
    'SECRETS=echo secrets-ran' 'SECURITY=echo security-ran' 'FIX=echo fix-ran' "$@"
}
ran() { grep -x -e lint-ran -e test-ran -e e2e-ran -e secrets-ran -e security-ran -e fix-ran "$out" | tr '\n' ' '; }
summary() { sed -n "/^summary of make $1:\$/,/^make $1: /p" "$out"; }  # the summary, up to its verdict
for t in lint test e2e fix; do
  expect_ok stand_in "$t"
  same "$(ran)" "$t-ran " "what make $t ran"
  ! grep -q '^summary of' "$out" || { cat "$out"; fail "make $t printed a summary"; }
done
expect_ok stand_in security
same "$(ran)" "secrets-ran security-ran " "what make security ran"
expect_ok stand_in infra
same "$(ran)" "" "what make infra ran of the commands"
has "docker-compose.stage.yml: OK"
has "docker-compose.prod.yml: OK"
has "parity: OK"
has "drill: db/"
# A base target with no command refuses on its own. LINT, TEST and SECRETS are mandatory: empty
# is a setting not made yet, and off says the project does not want that check.
for t in LINT TEST; do
  b=$(printf '%s' "$t" | tr '[:upper:]' '[:lower:]')
  expect_fail stand_in "$b" "$t="
  has "$t is empty: set it in the Makefile settings, or $t = off if this project does not want this check"
  expect_ok stand_in "$b" "$t=off"
  has "$b: $t = off in the Makefile settings: not run"
  same "$(ran)" "" "what make $b ran with $t=off"
done
# make lint checks the Dockerfile of every own image with docker build --check, on the host, before
# LINT; with LINT=off only that; DOCKERFILE_CHECK=off leaves it out.
expect_ok stand_in lint
has "dockerfile-check: docker/app/Dockerfile"
has "dockerfile-check: docker/backup/Dockerfile"
has "dockerfile-check: OK"
expect_ok stand_in lint LINT=off
has "dockerfile-check: OK"
has "lint: LINT = off in the Makefile settings: not run"
same "$(ran)" "" "what make lint ran with LINT=off"
# In a group, LINT = off stays off in the summary, with the Dockerfile check that ran.
expect_ok stand_in gates LINT=off
same "$(summary gates | sed -n 2p)" "  lint      off   LINT = off; dockerfile-check: OK" \
  "the lint line of make gates with LINT=off"
same "$(ran)" "test-ran secrets-ran " "what make gates ran with LINT=off"
sed -i 's/^FROM base AS runtime$/FROM base as runtime/' "$dev/docker/app/Dockerfile"
expect_fail stand_in lint
has "FromAsCasing"
has "dockerfile-check: docker build --check found problems (above) in: docker/app/Dockerfile"
same "$(ran)" "lint-ran " "what make lint ran with a Dockerfile the check refuses"
expect_fail stand_in gates
same "$(summary gates | sed -n 2p)" \
  "  lint      FAIL  ERROR: dockerfile-check: docker build --check found problems (above) in: docker/app/Dockerfile" \
  "the lint line of make gates with a Dockerfile the check refuses"
expect_fail stand_in gates LINT=off
same "$(summary gates | sed -n 2p)" \
  "  lint      FAIL  ERROR: dockerfile-check: docker build --check found problems (above) in: docker/app/Dockerfile" \
  "the lint line of make gates with LINT=off and a Dockerfile the check refuses"
has "make gates: FAIL (lint)"
expect_ok stand_in lint DOCKERFILE_CHECK=off
has "lint: DOCKERFILE_CHECK = off in the Makefile settings: the Dockerfiles are not checked"
! grep -q '^dockerfile-check:' "$out" || { cat "$out"; fail "make lint checked the Dockerfiles with DOCKERFILE_CHECK=off"; }
same "$(ran)" "lint-ran " "what make lint ran with DOCKERFILE_CHECK=off"
git -C "$dev" checkout -q docker/app/Dockerfile
expect_fail stand_in fix FIX=
has "this project has no FIX command (set FIX in the Makefile settings)"
# E2E may stay empty: make e2e skips it, as make verify does.
expect_ok stand_in e2e E2E=
has "e2e: no E2E command in the Makefile settings: not run"
same "$(ran)" "" "what make e2e ran with E2E="
expect_fail stand_in security SECRETS=
has "SECRETS is empty: set it in the Makefile settings, or SECRETS = off if this project does not want this check"
expect_ok stand_in security SECRETS=off
same "$(ran)" "security-ran " "what make security ran with SECRETS=off"
# make gates: lint, test and the secret scan; nothing of e2e, security or infra.
expect_ok stand_in gates
same "$(ran)" "lint-ran test-ran secrets-ran " "what make gates ran"
! grep -q -e '^parity:' -e 'docker-compose.stage.yml:' "$out" || { cat "$out"; fail "make gates ran infra"; }
same "$(summary gates)" "summary of make gates:
  lint      ok    lint-ran
  test      ok    test-ran
  secrets   ok    secrets-ran
make gates: OK" "the summary of make gates"
# A failing base target hides none of the others: each runs, the summary has a line for each, with
# the last line of its output that says something (no colour codes, no rule of = signs), and the
# group fails. A check set to off is named so and is no failure.
expect_fail stand_in gates 'TEST=echo "Ran 2 tests"; printf "\033[31m=== 1 failed ===\033[0m\n\n"; exit 3' SECRETS=off
same "$(ran)" "lint-ran " "what a make gates with a failing test ran"
same "$(summary gates)" "summary of make gates:
  lint      ok    lint-ran
  test      FAIL  1 failed
  secrets   off   SECRETS = off in the Makefile settings
make gates: FAIL (test)" "the summary of make gates with a failing test"
# An empty mandatory setting fails the gates, and the others still run.
expect_fail stand_in gates SECRETS=
same "$(ran)" "lint-ran test-ran " "what a make gates with an empty SECRETS ran"
same "$(summary gates)" "summary of make gates:
  lint      ok    lint-ran
  test      ok    test-ran
  secrets   FAIL  SECRETS is empty: set it in the Makefile settings, or SECRETS = off if this project does not want this check
make gates: FAIL (secrets)" "the summary of make gates with an empty SECRETS"
for none in 'LINT= TEST= SECRETS=' 'LINT=off TEST=off SECRETS=off'; do
  # shellcheck disable=SC2086 # one word per setting
  expect_fail stand_in gates $none
  has "make gates has nothing to run: set LINT, TEST or SECRETS in the Makefile settings"
done
# make verify: every base target, also after one fails; then the summary. E2E and SECURITY are not
# mandatory: empty is skip, off is off.
expect_fail stand_in verify 'E2E=echo "e2e: the browser test failed"; exit 1'
same "$(ran)" "lint-ran test-ran secrets-ran security-ran " "what make verify ran of the commands"
has "e2e: the browser test failed"
has "parity: OK"
has "drill: db/"
same "$(summary verify)" "summary of make verify:
  lint      ok    lint-ran
  test      ok    test-ran
  e2e       FAIL  e2e: the browser test failed
  security  ok    security-ran
  infra     ok    OK
make verify: FAIL (e2e)" "the summary of make verify"
# A base target of several steps (security, infra) names the step that failed, not the last one:
# here the secret scan and parity fail, and SAST and backup-test after them pass.
sed -i 's/shm_size: 256m/shm_size: 128m/' "$dev/docker-compose.prod.yml"
expect_fail stand_in verify E2E=off 'SECRETS=echo "leak: config/app.php:12"; exit 1'
git -C "$dev" checkout -q docker-compose.prod.yml
has "drill: db/"
same "$(summary verify)" "summary of make verify:
  lint      ok    lint-ran
  test      ok    test-ran
  e2e       off   E2E = off in the Makefile settings
  security  FAIL  leak: config/app.php:12
  infra     FAIL  ERROR: parity: stage and prod differ beyond name: (ENV-02)
make verify: FAIL (security infra)" "the summary of make verify with a failed first step"
# make fix runs only by hand: neither the gates nor the pre-push hook run it.
expect_fail in_dir "$dev" make fix
has "this project has no FIX command (set FIX in the Makefile settings)"

step "b1. the sample's gates; a red gate refuses git push"
expect_ok in_dir "$dev" make gates
has "gate words: a  b #1"
has "  test      ok    OK"
has "make gates: OK"
sed -i 's/assertGreater(app.VERSION, 0)/assertGreater(0, app.VERSION)/' "$dev/tests/test_app.py"
commit "a failing test" >/dev/null
expect_fail push "$dev"
has "FAILED (failures=1)"
has "  test      FAIL  FAILED (failures=1)"
same "$(remote_sha main)" "$c1" "the remote main after a refused push"
# A tag is checked like a branch: a tag of the red commit is refused, a tag of another commit too.
git -C "$dev" tag -a -m "a red tag" red-tag
expect_fail push "$dev" origin red-tag
has "FAILED (failures=1)"
! git -C "$tmp/remote.git" rev-parse -q --verify refs/tags/red-tag >/dev/null || fail "the red tag reached the remote"
git -C "$dev" tag old-tag "$c1"
expect_fail push "$dev" origin old-tag
has "pre-push: the gates check the checked-out commit; check out old-tag and push it from there"
# A push that only deletes has nothing to check: it passes although the checked-out commit is red.
git -C "$tmp/remote.git" branch gone main
expect_ok push "$dev" -q origin --delete gone
! git -C "$tmp/remote.git" rev-parse -q --verify refs/heads/gone >/dev/null || fail "the deleted branch is still on the remote"
git -C "$dev" tag -d red-tag old-tag >/dev/null
git -C "$dev" reset -q --hard "$c1"

step "b2. the pre-push hook in a terminal: it lists the uncommitted files and asks; y runs the gates and pushes, anything else pushes nothing"
# tty_push <answer> <git push arguments>: git push from the dev clone in a terminal (script gives
# it one), with the answer typed in.
tty_push() {
  printf '%s\n' "$1" > "$tmp/answer"; shift
  run in_dir "$dev" env SHELL=/bin/sh script -qefc "git push $*" /dev/null < "$tmp/answer"
}
cp "$dev/.env" "$tmp/dev.env"
git -C "$dev" checkout -q -b hooktest
echo "a line that passes the gates" >> "$dev/README.md"
good=$(commit "a commit that passes")
# Uncommitted: a staged change, an unstaged change, an untracked file.
echo "staged" >> "$dev/docs/how-to/operations.md"
git -C "$dev" add docs/how-to/operations.md
echo "# an unstaged change" >> "$dev/app.py"
echo "untracked" > "$dev/notes.txt"
snap "$dev" > "$tmp/snap.dev"
for answer in n '' yes; do
  tty_push "$answer" -q origin hooktest
  [ "$code" -ne 0 ] || { cat "$out"; fail "a push answered '$answer' passed"; }
  has "pre-push: not committed in $dev:"
  has "M  docs/how-to/operations.md"
  has " M app.py"
  has "?? notes.txt"
  has "pre-push: the gates will check them together with the commit. Nothing forgotten to commit? Continue? [y/N]"
  has "pre-push: stopped; nothing was pushed"
  ! grep -q 'gate words' "$out" || { cat "$out"; fail "the gates ran after the answer '$answer'"; }
  ! git -C "$tmp/remote.git" rev-parse -q --verify refs/heads/hooktest >/dev/null || fail "the answer '$answer' pushed"
  snap "$dev" | cmp -s "$tmp/snap.dev" - || fail "the working tree changed after the answer '$answer'"
done
# y: the gates run on the working tree as it is, and the push goes on; nothing is set aside.
tty_push y -q origin hooktest
[ "$code" -eq 0 ] || { cat "$out"; fail "a push answered y"; }
has "gate words: a  b #1"
has "make gates: OK"
same "$(remote_sha hooktest)" "$good" "the remote hooktest after the answer y"
snap "$dev" | cmp -s "$tmp/snap.dev" - || fail "the working tree changed after the answer y"
cmp -s "$dev/.env" "$tmp/dev.env" || fail "the push changed .env"
same "$(git -C "$dev" stash list)" "" "git stash after the push"
# The gates see the uncommitted changes: one that breaks them refuses the push after y.
sed -i 's/assertGreater(app.VERSION, 0)/assertGreater(0, app.VERSION)/' "$dev/tests/test_app.py"
echo "another line" >> "$dev/README.md"
git -C "$dev" commit -q -m "another commit" README.md
next=$(git -C "$dev" rev-parse HEAD)
tty_push y -q origin hooktest
[ "$code" -ne 0 ] || { cat "$out"; fail "a push whose uncommitted change breaks the gates passed"; }
has "FAILED (failures=1)"
same "$(remote_sha hooktest)" "$good" "the remote hooktest after gates broken by an uncommitted change"
git -C "$dev" checkout -q tests/test_app.py
# Without a terminal (an IDE, an agent): no question; a warning that names the files, and the push
# goes on.
expect_ok push "$dev" -q origin hooktest
has "pre-push: WARNING: not committed in $dev, and the gates check them together with the commit:"
has " M app.py"
has "?? notes.txt"
! grep -q 'Continue?' "$out" || { cat "$out"; fail "the hook asked without a terminal"; }
same "$(remote_sha hooktest)" "$next" "the remote hooktest after a push without a terminal"
# A clean working tree: no question and no warning, also in a terminal.
git -C "$dev" reset -q --hard
rm "$dev/notes.txt"
echo "a third line" >> "$dev/README.md"
third=$(commit "a third commit")
tty_push '' -q origin hooktest
[ "$code" -eq 0 ] || { cat "$out"; fail "a push of a clean working tree in a terminal"; }
! grep -q -e 'not committed' -e 'Continue?' "$out" || { cat "$out"; fail "the hook named files of a clean working tree"; }
same "$(remote_sha hooktest)" "$third" "the remote hooktest after a push of a clean working tree"
# Another branch than the checked-out one, with other content: the hook cannot check it.
git -C "$dev" branch other "$c1"
expect_fail push "$dev" -q origin other:elsewhere
has "pre-push: the gates check the checked-out commit; check out other and push it from there"
git -C "$dev" checkout -q -f main
git -C "$dev" branch -q -D hooktest other

step "b3. the pre-push hook: files written during the gates, HEAD moved, a linked worktree, what git cannot add"
# Stand-in gates: with GATE_WRITES set, the gate writes into that file; with GATE_RUNS set, it runs
# that command.
mkdir "$tmp/fake"
cat > "$tmp/fake/make" <<'EOF'
#!/bin/sh
[ -z "${GATE_WRITES:-}" ] || echo "written by a gate" >> "$GATE_WRITES"
[ -z "${GATE_RUNS:-}" ] || eval "$GATE_RUNS"
EOF
chmod 755 "$tmp/fake/make"
fpush() { d=$1; shift; run in_dir "$d" env PATH="$tmp/fake:$PATH" "$@" setsid -w git push -q origin HEAD:refs/heads/hook-a; }
git -C "$dev" checkout -q -b hook-a
echo "a commit to push" >> "$dev/README.md"
commit "a commit to push" >/dev/null
# A file written during the gates (by a gate, or an edit of yours): the push is refused, and what
# was written stays where it is. Also in a file that was already changed, and in a new file.
echo "# an uncommitted change" >> "$dev/app.py"
for f in README.md app.py during.txt; do
  cp "$dev/app.py" "$tmp/app.py"
  fpush "$dev" GATE_WRITES="$f"
  [ "$code" -ne 0 ] || { cat "$out"; fail "a push during whose gates $f was written passed"; }
  has "pre-push: the gates changed files (a gate must only check; if these are your own edits made during the push, push again): $f"
  grep -qx "written by a gate" "$dev/$f" || fail "what was written into $f during the gates is gone"
  ! git -C "$tmp/remote.git" rev-parse -q --verify refs/heads/hook-a >/dev/null || fail "a push during whose gates $f was written reached the remote"
  git -C "$dev" checkout -q README.md
  cp "$tmp/app.py" "$dev/app.py"
  rm -f "$dev/during.txt"
done
# HEAD moved during the gates: refused.
fpush "$dev" GATE_RUNS='git checkout -q -b moved HEAD~1'
[ "$code" -ne 0 ] || { cat "$out"; fail "a push during which HEAD moved passed"; }
has "pre-push: HEAD moved during the push; nothing was pushed"
git -C "$dev" checkout -q hook-a
git -C "$dev" branch -q -D moved
# What git cannot add to its index is no change of the gates: an untracked repository inside this
# one, without a commit, and a dirty submodule; the push goes on, and they stay as they are.
git init -q "$dev/nested"
echo n > "$dev/nested/n"
fpush "$dev"
[ "$code" -eq 0 ] || { cat "$out"; fail "a push with an untracked repository inside"; }
same "$(cat "$dev/nested/n")" n "the untracked repository inside after the push"
rm -rf "$dev/nested"
git init -q -b main "$tmp/subrepo"
echo s > "$tmp/subrepo/s"
git -C "$tmp/subrepo" add s
git -C "$tmp/subrepo" commit -q -m s
git -C "$dev" -c protocol.file.allow=always submodule add -q "$tmp/subrepo" sub
git -C "$dev" commit -q -m "a submodule"
echo dirty >> "$dev/sub/s"
fpush "$dev"
[ "$code" -eq 0 ] || { cat "$out"; fail "a push with a dirty submodule"; }
grep -qx dirty "$dev/sub/s" || fail "the change in the submodule is not there after the push"
git -C "$dev" reset -q --hard HEAD~1
rm -rf "$dev/sub" "$dev/.git/modules/sub"
# A linked worktree checks its own files: what a gate writes there refuses its push, and the main
# worktree is not touched.
git -C "$dev" worktree add -q -b hook-b "$tmp/hook-b"
echo "the change of b" > "$tmp/hook-b/b.txt"
snap "$dev" > "$tmp/snap.dev"
run in_dir "$tmp/hook-b" env PATH="$tmp/fake:$PATH" GATE_WRITES=README.md setsid -w git push -q origin HEAD:refs/heads/hook-b
[ "$code" -ne 0 ] || { cat "$out"; fail "a push from a worktree during whose gates a file was written passed"; }
has "pre-push: WARNING: not committed in $tmp/hook-b, and the gates check them together with the commit:"
has "pre-push: the gates changed files (a gate must only check; if these are your own edits made during the push, push again): README.md"
snap "$dev" | cmp -s "$tmp/snap.dev" - || fail "a push from a linked worktree changed the main worktree"
# The hook never uses git stash.
same "$(git -C "$dev" stash list)" "" "git stash after the pushes of the hook"
git -C "$dev" checkout -q -f main
git -C "$dev" worktree remove --force "$tmp/hook-b"
git -C "$dev" branch -q -D hook-a hook-b

step "b5. make mutation and make mutation-diff: a container of their own, with the limits of .env, removed afterwards"
expect_fail in_dir "$dev" make mutation
has "this project has no MUTATION command (set MUTATION in the Makefile settings)"
dev_cid=$(cid stdtest-dev-dev-1)
sed -i -e 's/^MUTATION_CPUS=.*/MUTATION_CPUS=1/' -e 's/^MUTATION_MEM=.*/MUTATION_MEM=256m/' "$dev/.env"
# The CPU quota and period, then the memory limit: the cgroup v2 files, or the cgroup v1 ones
# printed the same way.
v1='/sys/fs/cgroup/cpu/cpu.cfs_quota_us /sys/fs/cgroup/cpu/cpu.cfs_period_us'
limits="cat /sys/fs/cgroup/cpu.max /sys/fs/cgroup/memory.max 2>/dev/null || { cat $v1 | xargs; cat /sys/fs/cgroup/memory/memory.limit_in_bytes; }"
clock
expect_ok in_dir "$dev" make mutation "MUTATION=$limits"
took "make mutation"
has "100000 100000"
has "268435456"
# make expands $(STAGE_BRANCH) in the setting, so MUTATION_DIFF can name the stage branch as its base.
# shellcheck disable=SC2016 # make expands $(STAGE_BRANCH), not this shell
diff_cmd='echo "base origin/$(STAGE_BRANCH)"; cat /sys/fs/cgroup/memory.max 2>/dev/null || cat /sys/fs/cgroup/memory/memory.limit_in_bytes'
expect_ok in_dir "$dev" make mutation-diff "MUTATION_DIFF=$diff_cmd"
has "base origin/main"
has "268435456"
[ -z "$(docker ps -aq --filter name=stdtest-dev-mutation)" ] || fail "make mutation left its container"
same "$(cid stdtest-dev-dev-1)" "$dev_cid" "the dev container after make mutation"
same "$(docker images -q stdtest-dev-mutation)" "" "an image of the mutation service (it uses the dev image)"
sed -i -e 's/^MUTATION_CPUS=.*/MUTATION_CPUS=2/' -e 's/^MUTATION_MEM=.*/MUTATION_MEM=4g/' "$dev/.env"

step "c. make image-scan: builds the images of the commit, whatever the working tree holds, saves them, removes the files"
mkdir -p "$dev/.claude/worktrees/x" && : > "$dev/.claude/worktrees/x/f"
# An uncommitted change and an untracked file neither block make image-scan nor reach the image.
sed -i 's/^VERSION = 1$/VERSION = 99/' "$dev/app.py"
echo "untracked in dev" > "$dev/stray.txt"
clock
run in_dir "$dev" make image-scan
took "make image-scan"
built "$c1"
has "image-scan: saved $(app_image "$c1") to build/image-scan/app.tar ("
has "image-scan: saved $(backup_image "$c1") to build/image-scan/backup.tar ("
has "image-scan: saved $(status_image "$c1") to build/image-scan/status.tar ("
[ ! -e "$dev/build" ] || fail "make image-scan left $dev/build"
if [ -z "${STDTEST_TRIVY:-}" ]; then
  # The sample's dev image has no trivy: the images are built and saved, then the scan refuses.
  [ "$code" -ne 0 ] || { cat "$out"; fail "make image-scan passed without trivy"; }
  has "make image-scan needs trivy in the dev image (standard QLT-01)"
else
  # trivy reads the saved files; whether the stock base images pass trivy.yaml depends on the
  # day's vulnerability database, so either end is accepted, after the own images (app, backup,
  # status) were scanned.
  has "image-scan: $(backup_image "$c1")"
  has "$dev/build/image-scan/app.tar"
  has "$dev/build/image-scan/backup.tar"
  if [ "$code" -eq 0 ]; then has "image-scan: OK"; else has "image-scan: trivy failed or found vulnerabilities (above) in:"; fi
  sed -n 's/^\(ERROR: \)\{0,1\}\(image-scan: .*\)/project:   \2/p' "$out"
fi
docker run --rm --entrypoint grep "$(app_image "$c1")" -q '^VERSION = 1$' /srv/app.py \
  || fail "the image was built from the working tree, not the commit"
git -C "$dev" checkout -q app.py
rm "$dev/stray.txt"
[ -f "$dev/docs/how-to/operations.md" ] && [ -f "$dev/.githooks/pre-push" ] || fail "the sample has no docs/ or .githooks/"
docker run --rm --entrypoint sh "$(app_image "$c1")" -c \
  '[ -f /srv/app.py ] && [ ! -e /srv/docs ] && [ ! -e /srv/.githooks ] && [ ! -e /srv/stray.txt ] && [ ! -e /srv/.env ]' \
  || fail "the image holds files .dockerignore excludes, or files not in the commit"
# Again: the images are there, nothing is built.
run in_dir "$dev" make image-scan
built_nothing "a second make image-scan"
has "image-scan: saved $(app_image "$c1")"
# A submodule is not in git archive: an image of a commit with one would lack its files.
mkdir "$dev/sub"
git -C "$dev" update-index --add --cacheinfo "160000,$c1,sub"
git -C "$dev" commit -q -m "a submodule"
expect_fail in_dir "$dev" make image-scan
has "has git submodules: an image built from it would lack their files; nothing was built"
git -C "$dev" reset -q --hard "$c1"
rm -rf "$dev/sub"
# The temporary files of the build go to TMPDIR; each case below checks that none is left.
mkdir "$tmp/tmpdir"
no_tmp() { same "$(ls -A "$tmp/tmpdir")" "" "the temporary files after $1"; [ ! -e "$dev/build" ] || fail "$1 left $dev/build"; }
# A commit git archive cannot read in full (an object is missing): the build stops before docker build.
git -C "$dev" checkout -q -b lost-object
echo "a file whose object goes missing" > "$dev/lost.txt"
git -C "$dev" add lost.txt
git -C "$dev" commit -q -m "a file whose object goes missing"
lost=$(git -C "$dev" rev-parse HEAD)
blob=$(git -C "$dev" rev-parse HEAD:lost.txt)
obj=$dev/.git/objects/$(printf '%s' "$blob" | cut -c1-2)/$(printf '%s' "$blob" | cut -c3-)
mv "$obj" "$tmp/lost-object"
expect_fail in_dir "$dev" env TMPDIR="$tmp/tmpdir" make image-scan
has "ERROR: git archive of commit $lost failed (above); nothing was scanned"
built_nothing "make image-scan of a commit git archive cannot read"
no_tmp "a failed git archive"
mv "$tmp/lost-object" "$obj"
git -C "$dev" checkout -q main
git -C "$dev" branch -q -D lost-object
if [ -z "${STDTEST_TRIVY:-}" ]; then
  # Stopped with INT (Ctrl-C) during the build: the unpacked commit and its archive are removed.
  git -C "$dev" checkout -q -b slow
  sed -i 's|^USER 10001:10001$|RUN sleep 60\n&|' "$dev/docker/app/Dockerfile"
  slow=$(commit "a slow build step")
  stopped() { # stopped <condition>: make image-scan, stopped with INT (to its process group) once the condition holds
    # A background job ignores INT; env gives make the default action back.
    (cd "$dev" && TMPDIR="$tmp/tmpdir" exec env --default-signal=INT setsid make image-scan) > "$out" 2>&1 & p=$!
    i=0; until eval "$1"; do i=$((i + 1)); [ "$i" -lt 600 ] || { cat "$out"; fail "timed out waiting for: $1"; }; sleep 0.1; done
    sleep 1
    kill -INT -"$p"
    if wait "$p"; then code=0; else code=$?; fi
    i=0; while kill -0 -"$p" 2>/dev/null; do i=$((i + 1)); [ "$i" -lt 300 ] || fail "the stopped make image-scan did not end"; sleep 0.1; done
    [ "$code" -ne 0 ] || { cat "$out"; fail "a stopped make image-scan passed"; }
  }
  # shellcheck disable=SC2016 # stopped evaluates the condition
  stopped 'grep -q "build: $(app_image "$slow") from commit" "$out"'
  no_tmp "make image-scan stopped during the build"
  ! docker image inspect "$(app_image "$slow")" >/dev/null 2>&1 || fail "a stopped build left an image"
  git -C "$dev" checkout -q main
  git -C "$dev" branch -q -D slow
  # A stand-in trivy in the dev container: it reads the saved file at the path it is given, and
  # waits while the project has the file .trivy-wait.
  cat > "$tmp/fake-trivy" <<'EOF'
#!/bin/sh
[ -f "$3" ] || { echo "fake trivy: no file $3"; exit 1; }
echo "fake trivy: read $3"
p=${3%/build/image-scan/*}
[ ! -e "$p/.trivy-wait" ] || : > "$p/.trivy-waiting"
while [ -e "$p/.trivy-wait" ]; do sleep 0.1; done
EOF
  docker exec -i -u 0 stdtest-dev-dev-1 sh -c 'cat > /usr/local/bin/trivy && chmod 755 /usr/local/bin/trivy' < "$tmp/fake-trivy"
  # Run through a symbolic link to the project: trivy in the dev container gets the physical path,
  # which the container mounts.
  ln -s "$tmp" "$tmp/via-link"
  expect_ok in_dir "$tmp/via-link/dev" env TMPDIR="$tmp/tmpdir" make image-scan
  has "fake trivy: read $dev/build/image-scan/app.tar"
  has "fake trivy: read $dev/build/image-scan/backup.tar"
  has "image-scan: OK"
  no_tmp "make image-scan through a symbolic link"
  # Stopped with INT during the scan: the saved images are removed.
  : > "$dev/.trivy-wait"
  # shellcheck disable=SC2016 # stopped evaluates the condition
  stopped '[ -e "$dev/.trivy-waiting" ]'
  rm -f "$dev/.trivy-wait" "$dev/.trivy-waiting"
  no_tmp "make image-scan stopped during the scan"
  docker exec -u 0 stdtest-dev-dev-1 rm /usr/local/bin/trivy
fi
# The own image is exactly <repo>-<image>: a name with more before or after it is not the app's.
for wrong in mystdtest-app stdtest-proof-app; do
  sed -i "s|^    image: stdtest-app:|    image: $wrong:|" "$dev/docker-compose.stage.yml"
  expect_fail in_dir "$dev" make image-scan
  # shellcheck disable=SC2016 # ${IMAGE_TAG:?} is text of the message
  has 'docker-compose.stage.yml has no image stdtest-app:${IMAGE_TAG:?} for app in IMAGES (the Makefile settings)'
  built_nothing "make image-scan with the image $wrong"
  git -C "$dev" checkout -q docker-compose.stage.yml
done
# The servers are other machines: they have none of the images built here.
docker rmi "$(app_image "$c1")" "$(backup_image "$c1")" "$(status_image "$c1")" >/dev/null

step "c2. BUILD_SECRETS: a build step reads the secret file, which the image never holds; a missing file refuses"
git -C "$dev" checkout -q -b secret
sed -i 's|^USER 10001:10001$|RUN --mount=type=secret,id=stdtest,required=true sha256sum /run/secrets/stdtest > /srv/secret.sha256\n&|' \
  "$dev/docker/app/Dockerfile"
sed -i 's|^BUILD_SECRETS =$|BUILD_SECRETS = stdtest=.env.stdtest-secret|' "$dev/Makefile"
add_dev_secret
sc=$(commit "a build step that reads a build secret")
expect_fail in_dir "$dev" make image-scan
has "the build secret stdtest needs the file .env.stdtest-secret (BUILD_SECRETS in the Makefile settings), which is not in this folder; nothing was built"
built_nothing "make image-scan without the secret file"
printf 'stdtest build secret %s\n' "$$" > "$dev/.env.stdtest-secret"
same "$(git -C "$dev" status --porcelain)" "" "git status with the secret file (.gitignore ignores .env.*)"
run in_dir "$dev" make image-scan
built "$sc"
same "$(docker run --rm --entrypoint cat "$(app_image "$sc")" /srv/secret.sha256 | cut -d' ' -f1)" \
  "$(sha256sum < "$dev/.env.stdtest-secret" | cut -d' ' -f1)" "the hash of the secret the build step read"
! docker run --rm --entrypoint cat "$(app_image "$sc")" /run/secrets/stdtest >/dev/null 2>&1 || fail "the image holds the secret file"
! docker history --no-trunc "$(app_image "$sc")" | grep -qF "stdtest build secret" || fail "the image history holds the secret"
! docker save "$(app_image "$sc")" | grep -qaF "stdtest build secret $$" || fail "a layer of the image holds the secret"
docker rmi "$(app_image "$sc")" "$(backup_image "$sc")" "$(status_image "$sc")" >/dev/null
rm "$dev/.env.stdtest-secret"
git -C "$dev" checkout -q main
git -C "$dev" branch -q -D secret

step "c3. a build secret read in the base stage: make dev builds it on a cold cache; docker-compose.dev.yml gives it to the dev build"
git -C "$dev" checkout -q -b devsecret
# A step of its own each run, so no cache of an earlier run builds it.
nonce=$(date +%s)-$$
sed -i "s|^WORKDIR /srv\$|&\nRUN --mount=type=secret,id=stdtest,required=true echo \"cold $nonce\" \&\& sha256sum /run/secrets/stdtest > /srv/secret.sha256|" \
  "$dev/docker/app/Dockerfile"
grep -q "cold $nonce" "$dev/docker/app/Dockerfile" || fail "the base stage has no WORKDIR /srv line to add the secret step after"
sed -i 's|^BUILD_SECRETS =$|BUILD_SECRETS = stdtest=.env.stdtest-secret|' "$dev/Makefile"
printf 'stdtest dev build secret %s\n' "$nonce" > "$dev/.env.stdtest-secret"
dev_id=$(cid stdtest-dev-dev-1)
expect_fail in_dir "$dev" make dev
has "BUILD_SECRETS has stdtest=.env.stdtest-secret, which docker-compose.dev.yml does not give the dev build"
same "$(cid stdtest-dev-dev-1)" "$dev_id" "the dev container after a refused make dev"
add_dev_secret
expect_ok in_dir "$dev" make dev
same "$(docker exec stdtest-dev-dev-1 cut -d' ' -f1 /srv/secret.sha256)" "$(sha256sum < "$dev/.env.stdtest-secret" | cut -d' ' -f1)" \
  "the hash of the secret the base stage read in the dev build"
! docker exec stdtest-dev-dev-1 test -e /run/secrets/stdtest || fail "the dev container holds the secret file"
rm "$dev/.env.stdtest-secret"
expect_fail in_dir "$dev" make dev
has "the build secret stdtest needs the file .env.stdtest-secret (BUILD_SECRETS in the Makefile settings), which is not in this folder; nothing was built"
git -C "$dev" checkout -q -f main
git -C "$dev" branch -q -D devsecret
expect_ok in_dir "$dev" make dev

step "d. make stage in a stage clone; each clone refuses the other's targets"
server_clone "$stage" stage "$stage_port" "$stage_status_port"
# The secrets of a server: a .env other users of the machine can read is refused.
for m in 644:-rw-r--r-- 640:-rw-r----- 604:-rw----r--; do
  chmod "${m%%:*}" "$stage/.env"
  expect_fail in_dir "$stage" make stage
  has ".env can be read or written by other users of this machine (${m#*:}): chmod 600 .env"
done
chmod 600 "$stage/.env"
sed -i 's|^DB_PASSWORD=.*|DB_PASSWORD=change-me|' "$stage/.env"
expect_fail in_dir "$stage" make stage
has "still change-me"
sed -i 's|^DB_PASSWORD=.*|DB_PASSWORD="change-me" # still the placeholder|' "$stage/.env"
expect_fail in_dir "$stage" make stage
has "still change-me"
sed -i 's|^DB_PASSWORD=.*|DB_PASSWORD=stage-secret|' "$stage/.env"
# The socket proxy of the status service runs in the group DOCKER_GID: another one than the
# socket's is refused before anything changes (the value of .env.example, for one).
sed -i 's|^DOCKER_GID=.*|DOCKER_GID=999999|' "$stage/.env"
expect_fail in_dir "$stage" make stage
has "ERROR: DOCKER_GID is '999999' in .env, but /var/run/docker.sock belongs to group $gid: set DOCKER_GID=$gid (the socket proxy of the status service reads the socket as that group); nothing was changed"
same "$(docker ps -aq --filter label=com.docker.compose.project=stdtest-stage)" "" "the stage containers after a refused DOCKER_GID"
[ ! -e "$stage/.deploy" ] || fail "a make stage refused for DOCKER_GID left .deploy"
sed -i "s|^DOCKER_GID=.*|DOCKER_GID=$gid|" "$stage/.env"
echo "a local change" >> "$stage/README.md"
expect_fail in_dir "$stage" make stage
has "this server clone has local changes"
git -C "$stage" checkout -q README.md
cp "$stage/.env" "$tmp/stage.env"
sed -i '/^APP_MEM=/d' "$stage/.env"
expect_fail in_dir "$stage" make stage
has "does not render with this .env"
cp "$tmp/stage.env" "$stage/.env"
# Untracked and ignored files in the server clone never reach the image: it is built from the commit.
echo "untracked on the server" > "$stage/stray.txt"
echo stray-ignored.txt >> "$stage/.git/info/exclude"
echo "ignored on the server" > "$stage/stray-ignored.txt"
clock
# The sample's runtime image has an ENTRYPOINT that serves and never ends: the migration runs past
# it (with timeout, so a migration that started the server instead fails here and does not hang).
expect_ok in_dir "$stage" timeout 600 make stage
took "make stage of a new stage clone, which builds the own images (app, backup, status)"
has "migrate: schema 1"
has "backup: none before the migration: nothing was deployed from this clone yet"
built "$c1"
has "prune: removed 0 old images; the images of the last 5 deployed commits stay"
has "OK: stage runs $c1"
has "tuning-check: ok"
# The free space where Docker keeps the images: no own image yet, so DISK_RESERVE alone.
has "space: "
has "free where Docker keeps the images (need 2.0G)"
# Nothing ran before, so nothing was replaced and no log was archived.
same "$(archived "$stage" app)" 0 "the archived app logs after the first deploy"
# The status service came up with the rest: its port only on 127.0.0.1, its proxy as nobody in the
# socket's group; GET /status answers 401 without the token and, with it, 200 and pass once the
# backup service, which make stage does not wait for, has had its first check (warn until then).
same "$(docker port stdtest-stage-status-1 8080)" "127.0.0.1:$stage_status_port" "the published port of status"
same "$(docker inspect -f '{{.Config.User}}' stdtest-stage-status-proxy-1)" "65534:$gid" "the user of the socket proxy"
same "$(image_of stdtest-stage-status-1)" "$(status_image "$c1")" "the stage status image"
run status_get stdtest-stage-status-1
same "$(head -n 1 "$out")" 401 "GET /status without the token"
! grep -q '"services"' "$out" || { cat "$out"; fail "GET /status without the token showed the services"; }
run status_get stdtest-stage-status-1 wrong-token-0123456789
same "$(head -n 1 "$out")" 401 "GET /status with a wrong token"
i=0
until run status_get stdtest-stage-status-1 stage-status-token-0123456789 && grep -q '"status": "pass"}$' "$out"; do
  i=$((i + 1)); [ "$i" -lt 60 ] || { cat "$out"; fail "GET /status of stage never answered pass"; }
  sleep 1
done
same "$(head -n 1 "$out")" 200 "GET /status with the token"
has '{"project": "stdtest-stage", "ok": true, '
for svc in app db backup status status-proxy; do has "\"$svc\": {\"status\": \"healthy\", "; done
has '"disk": {"docker": {"status": "healthy", '
has '"backup": {"status": "healthy", "free_bytes": '
! grep -qF stage-secret "$out" || { cat "$out"; fail "GET /status showed a value of .env"; }
# The application logs in with its own role: no superuser, and it may create in the schema public.
same "$(docker exec stdtest-stage-app-1 printenv DATABASE_URL)" "postgresql://app:stageapp@db:5432/postgres" "DATABASE_URL in stage"
same "$(app_role stdtest-stage-db-1 stageapp)" f "the stage application's role is a superuser"
docker exec -e PGPASSWORD=stageapp stdtest-stage-db-1 sh -c \
  'psql -X -q -v ON_ERROR_STOP=1 -h "$(hostname)" -U app -d postgres -c "CREATE TABLE app_made (x int); DROP TABLE app_made"' \
  || fail "the application's role cannot create a table"
# A database made before the role (a project that ran as the superuser): db creates the role again.
docker exec stdtest-stage-db-1 psql -q -U postgres -c 'DROP OWNED BY app; DROP ROLE app'
i=0
until [ "$(app_role stdtest-stage-db-1 stageapp 2>/dev/null)" = f ]; do
  i=$((i + 1)); [ "$i" -lt 60 ] || fail "db did not create the application's role again"; sleep 0.5
done
# A role of that name that is a superuser (an adopted database): db takes the rights away.
docker exec stdtest-stage-db-1 psql -q -U postgres -c 'ALTER ROLE app SUPERUSER'
i=0
until [ "$(app_role stdtest-stage-db-1 stageapp 2>/dev/null)" = f ]; do
  i=$((i + 1)); [ "$i" -lt 60 ] || fail "db did not take the superuser rights from the application's role"; sleep 0.5
done
# A build secret file of a server is checked as .env is.
printf 'x\n' > "$stage/.env.stdtest-perm"
chmod 644 "$stage/.env.stdtest-perm"
expect_fail in_dir "$stage" make images BUILD_SECRETS=stdtest=.env.stdtest-perm
has ".env.stdtest-perm can be read or written by other users of this machine (-rw-r--r--): chmod 600 .env.stdtest-perm"
rm "$stage/.env.stdtest-perm"
docker run --rm --entrypoint sh "$(app_image "$c1")" -c \
  '[ -f /srv/app.py ] && [ ! -e /srv/stray.txt ] && [ ! -e /srv/stray-ignored.txt ] && [ ! -e /srv/.env ]' \
  || fail "the image holds files of the server clone that are not in the commit"
app_img=$(image_id "$(app_image "$c1")")
app_id=$(cid stdtest-stage-app-1)
# The same commit again: nothing is built, nothing is replaced.
clock
expect_ok in_dir "$stage" make stage
took "make stage of the same commit again"
built_nothing "make stage of the same commit"
has "OK: stage runs $c1"
same "$(image_id "$(app_image "$c1")")" "$app_img" "the image after make stage of the same commit"
same "$(cid stdtest-stage-app-1)" "$app_id" "the stage app container after make stage of the same commit"
same "$(archived "$stage" app) $(archived "$stage" db) $(archived "$stage" backup)" "0 0 0" \
  "the archived logs after a deploy that replaced nothing"
grep -q " $c1\$" "$stage/.deploy/history" || fail ".deploy/history does not record $c1"
same "$(image_of stdtest-stage-app-1)" "$(app_image "$c1")" "the stage app image"
same "$(serves stdtest-stage-app-1)" "version 1" "the stage app"
# The second make stage ran the migration again, while version 1 served.
same "$(docker exec stdtest-stage-app-1 cat /data/migrations.log)" "$(printf '1 none\n1 version 1')" "the stage migration log"
# A deploy makes a backup set right before the migration (OPS-01).
awk '/^backup: db\/[0-9]+T[0-9]+Z OK / && !b { b = NR } /^migrate: / && !m { m = NR } END { exit !(b && m && b < m) }' "$out" \
  || { cat "$out"; fail "make stage made no backup set before the migration"; }
# That first set made the off-server copy's repository.
has "copy: no repository at /backup/.copy yet: creating it"
# A backup that fails, or only its off-server copy, is a risk the person decides: without a
# terminal the deploy stops before the migration (nothing runs or is recorded) unless RISK=yes.
deploys=$(wc -l < "$stage/.deploy/history")
# As the user the service runs as (BACKUP_USER, postgres): it owns the folder, and the container keeps
# no capability that lets root change it.
set_mode=$(docker exec -u postgres stdtest-stage-backup-1 stat -c %a /backup/db)
docker exec -u postgres stdtest-stage-backup-1 chmod 500 /backup/db
expect_fail in_dir "$stage" no_tty make stage < /dev/null
has "WARNING: the backup before the migration failed (above): no fresh set was made; if you go on: the migration runs without a fresh set, here or off the server"
has "ERROR: the backup before the migration failed (above): no fresh set was made: stopped here; to go on anyway, add RISK=yes to the make command line"
docker exec -u postgres stdtest-stage-backup-1 chmod "$set_mode" /backup/db
! grep -q '^migrate: ' "$out" || { cat "$out"; fail "make stage ran the migration after the backup failed"; }
same "$(docker exec stdtest-stage-app-1 cat /data/migrations.log)" "$(printf '1 none\n1 version 1')" "the stage migration log after a failed backup"
same "$(wc -l < "$stage/.deploy/history")" "$deploys" "the lines of .deploy/history after a failed backup"
same "$(cid stdtest-stage-app-1)" "$app_id" "the stage app container after a failed backup"
# Only the copy fails (its repository without its keys: restic stops at once, with no retry of a
# broken path): the local set is made, the deploy asks.
docker exec -u postgres stdtest-stage-backup-1 mv /backup/.copy/keys /backup/.copy/keys.off
expect_fail in_dir "$stage" no_tty make stage < /dev/null
has "WARNING: the backup before the migration made the local set, but its off-server copy failed (above); if you go on: the migration runs with a fresh set on this server only, none off the server"
has ": stopped here; to go on anyway, add RISK=yes to the make command line"
! grep -q '^migrate: ' "$out" || { cat "$out"; fail "make stage ran the migration after the copy failed"; }
# RISK=yes typed on the command line goes on: the migration runs with the local set only.
expect_ok in_dir "$stage" no_tty make stage RISK=yes < /dev/null
has "RISK=yes: going on"
has "migrate: "
has "OK: stage runs $c1"
docker exec -u postgres stdtest-stage-backup-1 mv /backup/.copy/keys.off /backup/.copy/keys
same "$(docker exec stdtest-stage-app-1 cat /data/migrations.log)" "$(printf '1 none\n1 version 1\n1 version 1')" "the stage migration log after RISK=yes"
db_id=$(cid stdtest-stage-db-1)
expect_ok in_dir "$stage" make status
has "environment: stage"
has "$c1"
expect_fail in_dir "$stage" make dev
has "this clone is PROJECT_ENV=stage"
expect_fail in_dir "$dev" make stage
has "this clone is PROJECT_ENV=dev"
# make logs follows until it is stopped; TAIL=<n> prints the last n lines and ends by itself;
# S=<service> shows only that service.
run in_dir "$stage" timeout 10 make logs S=db
same "$code" 124 "the exit code of make logs, which follows until timeout stops it"
has "database system is ready to accept connections"
expect_ok in_dir "$stage" timeout 60 make logs S=db TAIL=1000
has "database system is ready to accept connections"
! grep -q '^backup-1 ' "$out" || { cat "$out"; fail "make logs S=db showed another service"; }
expect_ok in_dir "$stage" timeout 60 make logs TAIL=5
grep -q '^backup-1 ' "$out" || { cat "$out"; fail "make logs TAIL=5 did not show every service"; }
# S counts only on make's command line, never from the environment.
expect_ok in_dir "$stage" env S=db timeout 60 make logs TAIL=5
grep -q '^backup-1 ' "$out" || { cat "$out"; fail "make logs took S=db from the environment"; }
expect_fail in_dir "$stage" make logs TAIL=x
has "TAIL=x is not a number of lines"
# make migrate is a dev target: on a server, make stage / make prod runs the migrations of the
# commit it deploys, under the lock of the clone; make migrate refuses and runs nothing.
expect_fail in_dir "$stage" make migrate
has "make migrate runs only in dev: on a server, make stage (make prod on prod) runs the migrations of the commit it deploys"
same "$(docker exec stdtest-stage-app-1 cat /data/migrations.log)" "$(printf '1 none\n1 version 1\n1 version 1')" "the stage migration log after a refused make migrate"
git clone -q "$tmp/remote.git" "$tmp/noenv"
expect_fail in_dir "$tmp/noenv" make status
has "no .env"
expect_fail in_dir "$tmp/noenv" make rollback
has "runs only in a stage or prod clone"

step "d2. .env values as Compose reads them: quotes, a comment after the value"
# project.sh and tuning-check.sh read .env with one and the same function.
fn() { sed -n '/^envvar() {$/,/^}$/p' "$1"; }
[ -n "$(fn "$dev/scripts/project.sh")" ] || fail "scripts/project.sh has no envvar() function"
same "$(fn "$dev/scripts/tuning-check.sh")" "$(fn "$dev/scripts/project.sh")" "envvar() of tuning-check.sh and of project.sh"
# Each form reads as Compose reads it (docker compose config, which creates nothing).
mkdir "$tmp/envvar"
# shellcheck disable=SC2016 # Compose interpolates it
printf 'services:\n  x:\n    image: busybox\n    environment: {V: "${V}"}\n' > "$tmp/envvar/c.yml"
for v in stage '"stage"' "'stage'" 'stage # the stage server' '"stage" # quoted, then a comment' \
    "'stage' # single quotes, then a comment" '"a #b"' 'a#b' "'a \"b\"'" 'stage   '; do
  printf 'V=%s\n' "$v" > "$tmp/envvar/.env"
  want=$(docker compose -p stdtest-envvar --env-file "$tmp/envvar/.env" -f "$tmp/envvar/c.yml" config --format json \
    | sed -n 's/^ *"V": "\(.*\)"$/\1/p' | sed 's/\\"/"/g')
  got=$(cd "$tmp/envvar" && sh -c "$(fn "$dev/scripts/project.sh"); envvar V")
  same "$got" "$want" "envvar for V=$v"
done
# In a server clone: a quoted PROJECT_ENV with a comment, and a quoted network name.
cp "$stage/.env" "$tmp/stage.env"
sed -i -e 's|^PROJECT_ENV=.*|PROJECT_ENV="stage" # the stage server|' -e 's|^PROXY_NETWORK=.*|PROXY_NETWORK="stdtest-proxy-quoted"|' "$stage/.env"
expect_ok in_dir "$stage" make restart
has "OK: stage runs $c1 (restarted with the current .env)"
has "tuning-check: ok"
docker network inspect stdtest-proxy-quoted >/dev/null 2>&1 || fail "make restart did not create the network named in quotes in .env"
if docker network inspect '"stdtest-proxy-quoted"' >/dev/null 2>&1; then
  docker network rm '"stdtest-proxy-quoted"' >/dev/null
  fail "make restart created a network whose name has the quotes"
fi
cp "$tmp/stage.env" "$stage/.env"
expect_ok in_dir "$stage" make restart
docker network rm stdtest-proxy-quoted >/dev/null

step "e. a failing migration: nothing is replaced"
sed -i 's/^VERSION = 1$/VERSION = 2/' "$dev/app.py"
sed -i 's/^FAIL = False$/FAIL = True/' "$dev/migrate.py"
commit "version 2 with a failing migration" >/dev/null
ship
app_id=$(cid stdtest-stage-app-1)
expect_fail in_dir "$stage" make stage
has "this migration fails on purpose"
has "the migration failed"
running stdtest-stage-app-1
same "$(cid stdtest-stage-app-1)" "$app_id" "the stage app container after a failed migration"
same "$(image_of stdtest-stage-app-1)" "$(app_image "$c1")" "the stage app image after a failed migration"
same "$(serves stdtest-stage-app-1)" "version 1" "the stage app after a failed migration"
same "$(tail -n 1 "$stage/.deploy/history" | cut -d' ' -f2)" "$c1" "the last deploy after a failed migration"
# The logs of the containers the deploy would replace (the own images changed; db did not) were
# saved before the migration.
same "$(archived "$stage" app) $(archived "$stage" db) $(archived "$stage" backup)" "1 0 1" \
  "the archived logs after a deploy whose migration failed"
# The checked-out commit is not the one that runs: make restart would skip its migration.
expect_fail in_dir "$stage" make restart
has "is not the one deployed last ($c1)"
same "$(cid stdtest-stage-app-1)" "$app_id" "the stage app container after a refused make restart"

step "e2. a build that fails: the deploy stops, nothing is replaced"
sed -i 's/^FAIL = True$/FAIL = False/' "$dev/migrate.py"
sed -i 's/^USER 10001:10001$/RUN echo "a broken line" \&\& exit 3\n&/' "$dev/docker/app/Dockerfile"
broken=$(commit "a broken Dockerfile line")
# Only the runtime image fails to build (the dev stage, built from base, never runs that line);
# the push skips the hook.
expect_ok push "$dev" -q --no-verify
expect_fail in_dir "$stage" make stage
has "a broken line"
has "ERROR: building stdtest-app for commit $broken failed (above); nothing was replaced"
running stdtest-stage-app-1
same "$(cid stdtest-stage-app-1)" "$app_id" "the stage app container after a failed build"
same "$(serves stdtest-stage-app-1)" "version 1" "the stage app after a failed build"
same "$(tail -n 1 "$stage/.deploy/history" | cut -d' ' -f2)" "$c1" "the last deploy after a failed build"
! docker image inspect "$(app_image "$broken")" >/dev/null 2>&1 || fail "a failed build left an image"
sed -i '/^RUN echo "a broken line"/d' "$dev/docker/app/Dockerfile"

step "f. a good commit, a failed start, make rollback with kept and removed images, and back to the branch"
c3=$(commit "version 2 with a working migration and a working Dockerfile")
ship
clock
expect_ok in_dir "$stage" make stage
took "make stage of a new commit"
built "$c3"
has "OK: stage runs $c3"
same "$(image_of stdtest-stage-app-1)" "$(app_image "$c3")" "the stage app image"
same "$(serves stdtest-stage-app-1)" "version 2" "the stage app"
# The replaced container's logs, with Docker's timestamps, are in the archive; the new one's are not.
same "$(archived "$stage" app)" 2 "the archived app logs after a deploy that replaced the app"
newest=$(find "$stage/.deploy/logs" -name '*-app.log' | sort | tail -n 1)
grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z app: version 1 serves$' "$newest" \
  || { cat "$newest"; fail "the archived log $newest lacks the old container's line"; }
! grep -q 'version 2' "$newest" || fail "the archived log $newest holds the new container's lines"
case "${newest##*/}" in [0-9][0-9][0-9][0-9][0-1][0-9][0-3][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z-app.log) ;;
  *) fail "the archived log is named ${newest##*/}, not <UTC>-app.log" ;; esac
docker logs stdtest-stage-app-1 2>&1 | grep -q 'app: version 2 serves' || fail "the new app container has no log line"
# The migration of the new image ran while the old version still served.
same "$(docker exec stdtest-stage-app-1 tail -n 1 /data/migrations.log)" "2 version 1" "the stage migration log"
sed -i -e 's/^VERSION = 2$/VERSION = 3/' -e 's/^HEALTHY = True$/HEALTHY = False/' "$dev/app.py"
commit "version 3 that never becomes healthy" >/dev/null
ship
expect_fail in_dir "$stage" make stage
has "a container did not become healthy"
c3_img=$(image_id "$(app_image "$c3")")
clock
expect_ok in_dir "$stage" make rollback
took "make rollback to a commit whose images are kept"
built_nothing "make rollback to a kept image"
has "migrate: skipped (rollback)"
has "OK: stage runs $c3"
same "$(git -C "$stage" rev-parse HEAD)" "$c3" "HEAD after a rollback from a failed start"
same "$(image_of stdtest-stage-app-1)" "$(app_image "$c3")" "the stage app image after a rollback"
same "$(image_id "$(app_image "$c3")")" "$c3_img" "the image after a rollback"
expect_ok in_dir "$stage" make rollback
built_nothing "make rollback to a kept image"
has "migrate: skipped (rollback)"
has "OK: stage runs $c1"
same "$(git -C "$stage" rev-parse HEAD)" "$c1" "HEAD after a rollback"
same "$(image_of stdtest-stage-app-1)" "$(app_image "$c1")" "the stage app image after a rollback"
same "$(serves stdtest-stage-app-1)" "version 1" "the stage app after a rollback"
# c1 three times (the last with RISK=yes), c3, the failed start of version 3; none by a rollback.
same "$(docker exec stdtest-stage-app-1 sh -c 'wc -l < /data/migrations.log')" 5 \
  "migrations run (none by a rollback)"
sed -i 's/^HEALTHY = False$/HEALTHY = True/' "$dev/app.py"
c5=$(commit "version 3 that becomes healthy")
ship
expect_ok in_dir "$stage" make stage
has "OK: stage runs $c5"
same "$(git -C "$stage" symbolic-ref --short HEAD)" main "the stage branch after make stage"
same "$(serves stdtest-stage-app-1)" "version 3" "the stage app"
same "$(cid stdtest-stage-db-1)" "$db_id" "the stage database container after every deploy"
# c3 was rolled back, so the commit that ran before c5 is c1. Its images were removed by hand
# (or pruned): the rollback builds them again from the commit.
docker rmi "$(app_image "$c1")" "$(backup_image "$c1")" "$(status_image "$c1")" >/dev/null
clock
expect_ok in_dir "$stage" make rollback
took "make rollback to a commit whose images were removed"
has "rollback: building the images of $c1 again (they were pruned)"
built "$c1"
has "migrate: skipped (rollback)"
has "OK: stage runs $c1"
same "$(serves stdtest-stage-app-1)" "version 1" "the stage app after a rollback that built its images"
expect_ok in_dir "$stage" make stage
built_nothing "make stage back to a kept image"
has "OK: stage runs $c5"
# A rollback that fails leaves the clone at the commit it tried, and says so.
sed -i 's|^APP_MEM=.*|APP_MEM=1k|' "$stage/.env"
expect_fail in_dir "$stage" make rollback
has "make rollback did not finish (above): this clone is left at $c1 (detached HEAD); make stage deploys the main branch again, make rollback deploys $c5"
cp "$tmp/stage.env" "$stage/.env"
expect_ok in_dir "$stage" make stage
has "OK: stage runs $c5"

step "g. make restart: a changed .env, the same commit"
# The stage branch gets a newer commit that stage does not deploy.
sed -i 's/^VERSION = 3$/VERSION = 4/' "$dev/app.py"
c6=$(commit "version 4")
ship
app_id=$(cid stdtest-stage-app-1)
deploys=$(wc -l < "$stage/.deploy/history")
expect_fail in_dir "$dev" make restart
has "make restart runs only in a stage or prod clone"
cp "$stage/.env" "$tmp/stage.env"
sed -i 's|^DB_PASSWORD=.*|DB_PASSWORD=change-me|' "$stage/.env"
expect_fail in_dir "$stage" make restart
has "still change-me"
cp "$tmp/stage.env" "$stage/.env"
status_id=$(cid stdtest-stage-status-proxy-1)
sed -i 's|^DOCKER_GID=.*|DOCKER_GID=999999|' "$stage/.env"
expect_fail in_dir "$stage" make restart
has "ERROR: DOCKER_GID is '999999' in .env, but /var/run/docker.sock belongs to group $gid: set DOCKER_GID=$gid"
same "$(cid stdtest-stage-status-proxy-1)" "$status_id" "the socket proxy container after a refused make restart"
same "$(cid stdtest-stage-app-1)" "$app_id" "the stage app container after a refused make restart"
cp "$tmp/stage.env" "$stage/.env"
sed -i 's|^APP_MEM=.*|APP_MEM=256M|' "$stage/.env"
logs_app=$(archived "$stage" app) logs_db=$(archived "$stage" db)
expect_ok in_dir "$stage" make restart
built_nothing "make restart"
# make restart replaced only the app, and saved its logs first.
same "$(archived "$stage" app) $(archived "$stage" db)" "$((logs_app + 1)) $logs_db" "the archived logs after make restart"
has "log-archive: .deploy/logs/"
has "OK: stage runs $c5 (restarted with the current .env)"
has "tuning-check: ok"
same "$(docker inspect -f '{{.HostConfig.Memory}}' stdtest-stage-app-1)" 268435456 "the stage app memory limit after make restart"
[ "$(cid stdtest-stage-app-1)" != "$app_id" ] || fail "make restart did not recreate the app container"
same "$(cid stdtest-stage-db-1)" "$db_id" "the stage database container after make restart (its configuration did not change)"
same "$(git -C "$stage" rev-parse HEAD)" "$c5" "HEAD after make restart"
same "$(remote_sha main)" "$c6" "the remote main"
same "$(serves stdtest-stage-app-1)" "version 3" "the stage app after make restart"
same "$(wc -l < "$stage/.deploy/history")" "$deploys" "the lines of .deploy/history after make restart"
# An image of the running commit removed by hand: make restart builds it again.
docker rmi -f "$(app_image "$c5")" >/dev/null
expect_ok in_dir "$stage" make restart
has "build: $(app_image "$c5") from commit $c5"
! grep -q "rollback:" "$out" || { cat "$out"; fail "make restart said rollback"; }
has "OK: stage runs $c5 (restarted with the current .env)"
same "$(image_of stdtest-stage-app-1)" "$(app_image "$c5")" "the stage app image after make restart built it again"
# An empty LOG_ARCHIVE_DIR archives nothing, also when make restart replaces a container.
cp "$stage/.env" "$tmp/stage.env"
sed -i -e 's|^LOG_ARCHIVE_DIR=.*|LOG_ARCHIVE_DIR=|' -e 's|^LOG_LEVEL=.*|LOG_LEVEL=debug|' "$stage/.env"
logs_app=$(archived "$stage" app)
app_id=$(cid stdtest-stage-app-1)
expect_ok in_dir "$stage" make restart
[ "$(cid stdtest-stage-app-1)" != "$app_id" ] || fail "make restart did not replace the app with a changed LOG_LEVEL"
same "$(archived "$stage" app)" "$logs_app" "the archived app logs with an empty LOG_ARCHIVE_DIR"
! grep -q "log-archive:" "$out" || { cat "$out"; fail "make restart archived logs with an empty LOG_ARCHIVE_DIR"; }
cp "$tmp/stage.env" "$stage/.env"
expect_ok in_dir "$stage" make restart
same "$(archived "$stage" app)" "$((logs_app + 1))" "the archived app logs after make restart set LOG_LEVEL back"
# A stopped container is archived too: Docker keeps its logs until it is removed.
docker stop stdtest-stage-app-1 >/dev/null
sed -i 's|^LOG_LEVEL=.*|LOG_LEVEL=debug|' "$stage/.env"
logs_app=$(archived "$stage" app)
expect_ok in_dir "$stage" make restart
same "$(archived "$stage" app)" "$((logs_app + 1))" "the archived app logs of a stopped container"
# The same tag on an image with a new ID: Compose replaces the container, so its logs are saved.
orig=$(image_id "$(app_image "$c5")")
docker tag "$(app_image "$c5")" stdtest-app:orig
printf 'FROM %s\nLABEL stdtest.relabel=1\n' "$(app_image "$c5")" | docker build -q -t "$(app_image "$c5")" -t stdtest-app:relabel - >/dev/null
[ "$(image_id "$(app_image "$c5")")" != "$orig" ] || fail "the relabelled app image has the old ID"
app_id=$(cid stdtest-stage-app-1)
expect_ok in_dir "$stage" make restart
[ "$(cid stdtest-stage-app-1)" != "$app_id" ] || fail "make restart did not replace the app of an image with a new ID"
same "$(archived "$stage" app)" "$((logs_app + 2))" "the archived app logs after the image got a new ID"
docker tag stdtest-app:orig "$(app_image "$c5")"
docker rmi stdtest-app:orig >/dev/null
same "$(image_id "$(app_image "$c5")")" "$orig" "the app image of the commit after the tag went back"
# The archive refuses before anything is replaced: a folder it cannot write, and a disk without
# room for it (a tmpfs, with a DISK_RESERVE that the disk of the images has).
cp "$tmp/stage.env" "$stage/.env"
mkdir "$tmp/ro-logs"
chmod 555 "$tmp/ro-logs"
sed -i "s|^LOG_ARCHIVE_DIR=.*|LOG_ARCHIVE_DIR=$tmp/ro-logs|" "$stage/.env"
app_id=$(cid stdtest-stage-app-1)
expect_fail in_dir "$stage" make restart
has "ERROR: saving the logs of app to $tmp/ro-logs failed (above); nothing was replaced"
same "$(cid stdtest-stage-app-1)" "$app_id" "the stage app container after the archive could not be written"
shm=$(mktemp -d /dev/shm/stdtest.XXXXXX)
reserve=$(( $(df -Pk "$shm" | awk 'NR == 2 {print $4}') + 1048576 ))
sed -i -e "s|^LOG_ARCHIVE_DIR=.*|LOG_ARCHIVE_DIR=$shm|" -e "s|^DISK_RESERVE=.*|DISK_RESERVE=${reserve}K|" "$stage/.env"
expect_fail in_dir "$stage" no_tty make restart < /dev/null
has "ERROR: not enough free space for the log archive in $shm (LOG_ARCHIVE_DIR): need "
has ": stopped here; to go on anyway, add RISK=yes to the make command line"
same "$(cid stdtest-stage-app-1)" "$app_id" "the stage app container after the archive had no room"
rmdir "$shm" "$tmp/ro-logs"
cp "$tmp/stage.env" "$stage/.env"
expect_ok in_dir "$stage" make restart
same "$(archived "$stage" app)" "$((logs_app + 3))" "the archived app logs after make restart went back to the image of the commit"
docker rmi stdtest-app:relabel >/dev/null
# make images builds a missing image of the checked-out commit and starts nothing; dev has none.
app_id=$(cid stdtest-stage-app-1)
backup_id=$(cid stdtest-stage-backup-1)
docker rmi -f "$(backup_image "$c5")" >/dev/null
expect_ok in_dir "$stage" make images
has "build: $(backup_image "$c5") from commit $c5"
! grep -q "^build: $(app_image "$c5")" "$out" || { cat "$out"; fail "make images built an image this machine has"; }
has "OK: the images of $c5 are on this machine; nothing was started"
same "$(cid stdtest-stage-app-1)" "$app_id" "the stage app container after make images"
same "$(cid stdtest-stage-backup-1)" "$backup_id" "the stage backup container after make images"
expect_fail in_dir "$dev" make images
has "make images runs only in a stage or prod clone"
# A changed network name in .env: make restart creates that network before it starts anything.
sed -i 's|^PROXY_NETWORK=.*|PROXY_NETWORK=stdtest-proxy-restart|' "$stage/.env"
expect_ok in_dir "$stage" make restart
docker network inspect stdtest-proxy-restart >/dev/null 2>&1 || fail "make restart did not create the network named in .env"
sed -i 's|^PROXY_NETWORK=.*|PROXY_NETWORK=stdtest-proxy|' "$stage/.env"
docker network rm stdtest-proxy-restart >/dev/null

step "g1. one make stage, prod, rollback, restart, images or restore at a time in a clone"
deploys=$(wc -l < "$stage/.deploy/history")
in_dir "$stage" make restart > "$tmp/restart.out" 2>&1 & r=$!
wait_for "$stage/.deploy/lock/owner"
expect_fail in_dir "$stage" make rollback
has "ERROR: make restart (pid "
has ") is running in this clone; nothing was changed: run make rollback again after it ends"
wait "$r" || { cat "$tmp/restart.out"; fail "the make restart that held the lock"; }
grep -q "OK: stage runs $c5 (restarted with the current .env)" "$tmp/restart.out" || { cat "$tmp/restart.out"; fail "the make restart that held the lock"; }
same "$(git -C "$stage" rev-parse HEAD)" "$c5" "HEAD after a refused make rollback"
same "$(wc -l < "$stage/.deploy/history")" "$deploys" "the lines of .deploy/history after a refused make rollback"
[ ! -e "$stage/.deploy/lock" ] || fail "make restart left its lock"
# The lock of a make that still runs (here this test's shell) refuses make stage before it updates.
mkdir "$stage/.deploy/lock"
echo "$$ restore" > "$stage/.deploy/lock/owner"
expect_fail in_dir "$stage" make stage
has "ERROR: make restore (pid $$) is running in this clone; nothing was changed: run make stage again after it ends"
same "$(git -C "$stage" rev-parse HEAD)" "$c5" "HEAD after a refused make stage"
# A lock whose make no longer runs is taken over.
sh -c 'exit 0' & dead=$!
wait "$dead"
echo "$dead restore" > "$stage/.deploy/lock/owner"
expect_ok in_dir "$stage" make images
has "OK: the images of $c5 are on this machine; nothing was started"
[ ! -e "$stage/.deploy/lock" ] || fail "make images left the lock it took over"
# A lock without an owner is not taken over: a person removes it.
mkdir "$stage/.deploy/lock"
expect_fail in_dir "$stage" make rollback
has "ERROR: .deploy/lock has no owner: if no make stage, prod, rollback, restart, images or restore runs in this clone, remove .deploy/lock; nothing was changed"
same "$(git -C "$stage" rev-parse HEAD)" "$c5" "HEAD after a make rollback refused by a lock without an owner"
same "$(wc -l < "$stage/.deploy/history")" "$deploys" "the lines of .deploy/history after a make rollback refused by a lock without an owner"
rmdir "$stage/.deploy/lock" || fail "a refused make rollback removed or filled the lock without an owner"

step "g2. each deploy keeps the images of the last 5 deployed commits and touches no other image"
# Images that are not the project's, or not tagged with a tree hash, stay.
docker tag busybox:latest stdtest-app:by-hand
docker tag busybox:latest "stdtest-application:$(printf '%040d' 0 | tr 0 a)"
busybox=$(image_id busybox:latest)
# A KEEP_IMAGES that is not a whole number of at least 1 stops the deploy before anything is built or replaced.
app_id=$(cid stdtest-stage-app-1)
for bad in 0 x; do
  expect_fail in_dir "$stage" make stage KEEP_IMAGES=$bad
  has "KEEP_IMAGES=$bad in the Makefile settings is not a whole number of at least 1"
  built_nothing "make stage with KEEP_IMAGES=$bad"
done
same "$(cid stdtest-stage-app-1)" "$app_id" "the stage app container after a refused KEEP_IMAGES"
same "$(tail -n 1 "$stage/.deploy/history" | cut -d' ' -f2)" "$c5" "the last deploy after a refused KEEP_IMAGES"
clock
expect_ok in_dir "$stage" make stage
took "make stage of the next commit"
built "$c6"
has "OK: stage runs $c6"
for p in 1 2; do
  echo "a change to the README, $p" >> "$dev/README.md"
  commit "README $p" >/dev/null
  ship
  expect_ok in_dir "$stage" make stage
done
tip=$(git -C "$dev" rev-parse HEAD)
has "OK: stage runs $tip"
# Deployed, newest first: tip, the one before, c6, c5, c1, c3: the images of c3 go.
has "prune: removed 3 old images; the images of the last 5 deployed commits stay"
keep=$(for c in "$tip" "$tip~1" "$c6" "$c5" "$c1"; do tree "$c"; done | sort)
for n in stdtest-app stdtest-backup stdtest-status; do
  same "$(docker images --format '{{.Tag}}' "$n" | grep -xE '[0-9a-f]{40}' | sort)" "$keep" "the tree-hash tags of $n after the prune"
done
docker image inspect stdtest-app:by-hand "stdtest-application:$(printf '%040d' 0 | tr 0 a)" >/dev/null \
  || fail "the prune removed an image that is not the project's own"
same "$(image_id busybox:latest)" "$busybox" "busybox:latest after the prune"
# The dev image (the gates of each push run docker compose up --build; from the cache when only the code changed) is not an own image of a server either.
[ -n "$(docker images -q stdtest-dev-dev)" ] || fail "the prune removed the dev image"

step "g3. make tuning-check (the template's script): no swap beyond the memory limit; a changed .env value fails until make restart applies it; a size without a unit is refused"
for s in app db backup status status-proxy; do
  same "$(docker inspect -f '{{.HostConfig.MemorySwap}}' "stdtest-stage-$s-1")" \
    "$(docker inspect -f '{{.HostConfig.Memory}}' "stdtest-stage-$s-1")" "the memory and swap limit of $s"
done
expect_ok in_dir "$stage" make tuning-check
sed -n 's/^\(tuning-check: .*\)/project:   \1/p' "$out"
for p in "app cpus" "app memory" "app memswap" "db memswap" "backup memswap" "status cpus" "status memswap" \
    "status-proxy cpus" "status-proxy memswap" "db shared_buffers" "db effective_cache_size"; do
  has "tuning-check: ok $p"
done
sed -i 's|^DB_SHARED_BUFFERS=.*|DB_SHARED_BUFFERS=128MB|' "$stage/.env"
expect_fail in_dir "$stage" make tuning-check
has "tuning-check: FAIL db shared_buffers: 256MB, expected 128MB (DB_SHARED_BUFFERS)"
has "tuning-check: ok db effective_cache_size"
expect_ok in_dir "$stage" make restart
has "tuning-check: ok db shared_buffers"
same "$(docker exec stdtest-stage-db-1 psql -tA -U postgres -c 'SHOW shared_buffers')" 128MB "shared_buffers after make restart"
# A size without a unit is refused: 16384 is 128MB to PostgreSQL (8kB blocks), bytes to pg_size_bytes.
sed -i 's|^DB_SHARED_BUFFERS=.*|DB_SHARED_BUFFERS=16384|' "$stage/.env"
expect_fail in_dir "$stage" make tuning-check
has "tuning-check: FAIL db shared_buffers: not checked, expected a size with a unit in DB_SHARED_BUFFERS, such as 256MB (it is '16384')"
# A deploy whose tuning check fails is recorded before the check: the command fails, the history
# names the commit that runs, and make restart applies the fixed .env.
echo "a change to the README, 3" >> "$dev/README.md"
tip=$(commit "README 3")
ship
expect_fail in_dir "$stage" make stage
has "OK: stage runs $tip"
has "tuning-check: FAIL db shared_buffers: not checked"
has "ERROR: tuning-check failed (above), and stage runs $tip, recorded in .deploy/history: a value from .env: set it in .env, then make restart; a value in the code: fix it and ship again"
same "$(tail -n 1 "$stage/.deploy/history" | cut -d' ' -f2)" "$tip" "the last deploy after a failed tuning check"
same "$(serves stdtest-stage-app-1)" "version 4" "the stage app after a deploy whose tuning check failed"
sed -i 's|^DB_SHARED_BUFFERS=.*|DB_SHARED_BUFFERS=128MB|' "$stage/.env"
expect_ok in_dir "$stage" make restart
has "tuning-check: ok db shared_buffers"
has "OK: stage runs $tip (restarted with the current .env)"

step "g4. too little free space (an estimate): without a terminal make stage, images, restart, rollback, restore, the log archive, make backup and backup-drill refuse before they change anything; RISK=yes on the command line goes on"
cp "$stage/.env" "$tmp/stage.env"
app_id=$(cid stdtest-stage-app-1)
deploys=$(wc -l < "$stage/.deploy/history")
migrations=$(docker exec stdtest-stage-app-1 cat /data/migrations.log)
# A new commit waits on the branch: a refused make stage neither takes it nor builds it.
echo "a change to the README, 4" >> "$dev/README.md"
next=$(commit "README 4")
ship
sed -i 's|^DISK_RESERVE=.*|DISK_RESERVE=900T|' "$stage/.env"
# make restart and make rollback count only the own images they must build: here one each, removed
# (the running backup container keeps its image). make images RISK=yes builds the backup image of
# $tip again below; the app image of the rollback's commit stays removed.
docker rmi -f "$(backup_image "$tip")" >/dev/null
before=$(awk '{print $2}' "$stage/.deploy/history" | grep -vx "$tip" | tail -n 1)
docker rmi -f "$(app_image "$before")" >/dev/null
for t in stage images restart rollback 'restore CONFIRM=yes'; do
  # shellcheck disable=SC2086 # the target and its arguments
  expect_fail in_dir "$stage" no_tty make $t < /dev/null
  has "WARNING: not enough free space where Docker keeps the images: need "
  has ", the own images, and DISK_RESERVE=900T), have "
  has "; if you go on: a build or a pull may fill that disk"
  has ": stopped here; to go on anyway, add RISK=yes to the make command line"
  built_nothing "make $t with too little free space"
done
# RISK counts only when it was typed on the command line of this make.
expect_fail in_dir "$stage" no_tty env RISK=yes make images < /dev/null
has ": stopped here; to go on anyway, add RISK=yes to the make command line"
expect_fail in_dir "$stage" no_tty env MAKEFLAGS=RISK=yes make images < /dev/null
has "ERROR: RISK=yes is not on the command line of this make: it came from MAKEFLAGS or GNUMAKEFLAGS of the environment, or from a make that runs this one, which accept no risk: stopped here"
built_nothing "make images with RISK=yes from MAKEFLAGS"
expect_ok in_dir "$stage" no_tty make images RISK=yes < /dev/null
has "WARNING: not enough free space where Docker keeps the images: need "
has "RISK=yes: going on"
has "build: $(backup_image "$tip") from commit $tip"
same "$(cid stdtest-stage-app-1)" "$app_id" "the stage app container after the refusals for free space"
same "$(git -C "$stage" rev-parse HEAD)" "$tip" "HEAD after the refusals for free space"
same "$(wc -l < "$stage/.deploy/history")" "$deploys" "the lines of .deploy/history after the refusals for free space"
same "$(docker exec stdtest-stage-app-1 cat /data/migrations.log)" "$migrations" "the stage migration log after the refusals for free space"
sed -i 's|^DISK_RESERVE=.*|DISK_RESERVE=5|' "$stage/.env"
expect_fail in_dir "$stage" make images
has "DISK_RESERVE is '5' in .env, not a size like 2G or 500M (or 0)"
# The need is two times the own images (each with its largest version here) plus DISK_RESERVE.
sed -i 's|^DISK_RESERVE=.*|DISK_RESERVE=0|' "$stage/.env"
expect_ok in_dir "$stage" make images
has "free where Docker keeps the images (need $(human $((2 * $(own_kib)))))"
# The free space is read in the first image of the file that has df: one without it is passed
# over (here db's, an image FROM scratch), and with none that has df the check is skipped.
mkdir "$tmp/nodf"
printf 'x\n' > "$tmp/nodf/f"
printf 'FROM scratch\nCOPY f /f\n' > "$tmp/nodf/Dockerfile"
docker build -q -t stdtest-nodf:1 "$tmp/nodf" >/dev/null
sed -i 's|^    image: postgres:.*|    image: stdtest-nodf:1|' "$stage/docker-compose.stage.yml"
grep -q '^    image: stdtest-nodf:1$' "$stage/docker-compose.stage.yml" || fail "the stage file has no image: line of postgres to replace"
expect_ok in_dir "$stage" make images
has "free where Docker keeps the images (need "
sed -i 's|^    image: .*|    image: stdtest-nodf:1|' "$stage/docker-compose.stage.yml"
expect_ok in_dir "$stage" make images IMAGES=
has "space: not checked: no image of docker-compose.stage.yml on this machine has df (tried: stdtest-nodf:1)"
git -C "$stage" checkout -q docker-compose.stage.yml
docker rmi stdtest-nodf:1 >/dev/null
rm -rf "$tmp/nodf"
# Every own image of $tip is here, so make restart checks no space for images; its log archive
# (the backup and status containers get the new DISK_RESERVE) does not fit DISK_RESERVE=900T.
sed -i 's|^DISK_RESERVE=.*|DISK_RESERVE=900T|' "$stage/.env"
expect_fail in_dir "$stage" no_tty make restart < /dev/null
has "space: not checked: the own images of $tip are on this machine, so nothing is built"
has "WARNING: not enough free space for the log archive in .deploy/logs (LOG_ARCHIVE_DIR): need "
has "; if you go on: the logs may fill that disk"
has ": stopped here; to go on anyway, add RISK=yes to the make command line"
same "$(cid stdtest-stage-app-1)" "$app_id" "the stage app container after the log archive had no room"
expect_ok in_dir "$stage" no_tty make restart RISK=yes < /dev/null
has "RISK=yes: going on"
has "log-archive: .deploy/logs/"
has "OK: stage runs $tip (restarted with the current .env)"
# The backup service now runs with DISK_RESERVE=900T: its refusals for the free space (exit 3) ask.
for t in backup backup-drill; do
  expect_fail in_dir "$stage" no_tty make "$t" < /dev/null
  has "going on can fill the disk: "
  has "ERROR: the backup service found too little free space for make $t (above): stopped here; to go on anyway, add RISK=yes to the make command line"
  expect_ok in_dir "$stage" no_tty make "$t" RISK=yes < /dev/null
  has "; going on (--risk), which can fill the disk: "
  has "RISK=yes: going on"
done
# make restore goes past both estimates with RISK=yes, then still needs CONFIRM=yes.
expect_fail in_dir "$stage" no_tty make restore RISK=yes < /dev/null
has "WARNING: not enough free space where Docker keeps the images: need "
has "WARNING: the backup service found too little free space for make restore (above)"
has "restore replaces the working database postgres on db: run again with CONFIRM=yes"
same "$(cid stdtest-stage-app-1)" "$app_id" "the stage app container after make restore RISK=yes without CONFIRM"
running stdtest-stage-app-1
# make rollback RISK=yes: the app image of the commit it returns to is missing, and the log archive
# of the make that runs its steps does not fit either; RISK=yes reaches that make too.
expect_ok in_dir "$stage" no_tty make rollback RISK=yes < /dev/null
has "WARNING: not enough free space where Docker keeps the images: need "
has "WARNING: not enough free space for the log archive in .deploy/logs (LOG_ARCHIVE_DIR): need "
same "$(grep -c '^RISK=yes: going on$' "$out")" 2 "the estimates make rollback RISK=yes went past"
has "OK: stage runs $before"
# make stage RISK=yes deploys the branch again: the backup service, still with DISK_RESERVE=900T,
# refuses the set before the migration on the free space alone; on the yes it makes the set with
# --risk, and the migration runs after it.
expect_ok in_dir "$stage" no_tty make stage RISK=yes < /dev/null
has "WARNING: the backup service found too little free space for the set before the migration (above)"
has "; going on (--risk), which can fill the disk: "
awk '/^backup: db\/[0-9]+T[0-9]+Z OK / && !b { b = NR } /^migrate: / && !m { m = NR } END { exit !(b && m && b < m) }' "$out" \
  || { cat "$out"; fail "make stage RISK=yes made no backup set before the migration"; }
has "OK: stage runs $next"
cp "$tmp/stage.env" "$stage/.env"
expect_ok in_dir "$stage" make restart
# The new commit again, with room for it: nothing to ask.
expect_ok in_dir "$stage" make stage
has "OK: stage runs $next"
tip=$next

step "h. the project merges into the prod branch; make prod reuses the image of stage; a fix made only on prod is built there"
git -C "$dev" fetch -q origin
git -C "$dev" checkout -q -b prod origin/prod
git -C "$dev" merge -q --no-ff -m "merge main into prod" main
merged=$(git -C "$dev" rev-parse HEAD)
same "$(app_image "$merged")" "$(app_image "$tip")" "the image of the merge commit"
expect_ok push "$dev" -q origin prod
same "$(remote_sha prod)" "$merged" "the remote prod after the merge"
server_clone "$prod" prod "$prod_port" "$prod_status_port"
clock
expect_ok in_dir "$prod" make prod
took "make prod of a merge whose content stage built on this machine"
built_nothing "make prod of a merge with the content stage deployed"
has "OK: prod runs $merged"
same "$(image_of stdtest-prod-app-1)" "$(app_image "$tip")" "the prod app image"
same "$(serves stdtest-prod-app-1)" "version 4" "the prod app"
# A fix made only on prod: other content, so prod builds its own image.
echo "# a fix made only on prod" >> "$dev/app.py"
hot=$(commit "a fix made only on prod")
expect_ok push "$dev" -q origin prod
expect_ok in_dir "$prod" make prod
built "$hot"
has "OK: prod runs $hot"
same "$(image_of stdtest-prod-app-1)" "$(app_image "$hot")" "the prod app image after the fix"
git -C "$dev" checkout -q main

step "i. a git worktree and make dev NAME=2 get their own dev projects"
dev_id=$(cid stdtest-dev-dev-1)
git -C "$dev" worktree add -q "$tmp/wt"
cp "$dev/.env" "$tmp/wt/.env"
expect_fail in_dir "$tmp/wt" make dev
has "PROJECT_DIR in .env is '$dev', not this folder (a .env from elsewhere?): set PROJECT_DIR=$tmp/wt in .env"
! grep -q delete "$out" || { cat "$out"; fail "the message advises to delete .env"; }
rm "$tmp/wt/.env"
expect_ok in_dir "$tmp/wt" make dev
# The folder name and the first 6 hex digits of the hash of the worktree's path.
wts=-wt-$(printf '%s' "$tmp/wt" | git hash-object --stdin | cut -c1-6)
has "DEV_SUFFIX=$wts"
same "$(envvar "$tmp/wt" DEV_SUFFIX)" "$wts" "DEV_SUFFIX in the worktree .env"
same "$(envvar "$tmp/wt" APP_PORT)" "" "APP_PORT in the worktree .env"
wt_port=$(docker port "stdtest-dev$wts-dev-1" 8000 | sed -n '1s/.*://p')
[ -n "$wt_port" ] && [ "$wt_port" != "$dev_port" ] || fail "the worktree port is '$wt_port'"
has "127.0.0.1:$wt_port->8000/tcp"
docker volume inspect "stdtest-dev${wts}_db" "stdtest-dev${wts}_data" >/dev/null || fail "the worktree has no own volumes"
# Two worktrees with the same folder name in different places get different dev projects.
mkdir "$tmp/a" "$tmp/b"
git -C "$dev" worktree add -q --detach "$tmp/a/fix"
git -C "$dev" worktree add -q --detach "$tmp/b/fix"
expect_ok in_dir "$tmp/a/fix" make bootstrap
expect_ok in_dir "$tmp/b/fix" make bootstrap
fa=$(envvar "$tmp/a/fix" DEV_SUFFIX) fb=$(envvar "$tmp/b/fix" DEV_SUFFIX)
case "$fa $fb" in "-fix-"??????" -fix-"??????) ;; *) fail "the DEV_SUFFIX of two worktrees named fix: '$fa' and '$fb'" ;; esac
[ "$fa" != "$fb" ] || fail "two worktrees named fix in different places share DEV_SUFFIX $fa"
same "$(cid stdtest-dev-dev-1)" "$dev_id" "the main dev container after make dev in the worktree"
git clone -q "$tmp/remote.git" "$tmp/dev2"
: > "$tmp/compose.yaml"
expect_fail in_dir "$tmp/dev2" make dev NAME=2
has "default-named compose file"
[ ! -f "$tmp/dev2/.env" ] || fail "a failed bootstrap left an .env"
rm "$tmp/compose.yaml"
expect_ok in_dir "$tmp/dev2" make dev NAME=2
same "$(envvar "$tmp/dev2" DEV_SUFFIX)" -2 "DEV_SUFFIX with NAME=2"
running stdtest-dev-2-dev-1
same "$(cid stdtest-dev-dev-1)" "$dev_id" "the main dev container after make dev NAME=2"
# NAME counts only when make bootstrap creates .env: the same NAME again says nothing, another one
# is named as ignored, and .env stays as it is.
cp "$tmp/dev2/.env" "$tmp/dev2.env"
expect_ok in_dir "$tmp/dev2" make bootstrap NAME=2
! grep -q 'NAME=' "$out" || { cat "$out"; fail "make bootstrap NAME=2 spoke of NAME in the copy NAME=2 made"; }
expect_ok in_dir "$tmp/dev2" make bootstrap NAME=5
has "WARNING: NAME=5 is ignored: this clone already has .env (DEV_SUFFIX=-2); NAME applies only when make bootstrap creates .env"
expect_ok in_dir "$dev" make bootstrap NAME=5
has "WARNING: NAME=5 is ignored: this clone already has .env (DEV_SUFFIX=); NAME applies only when make bootstrap creates .env"
cmp -s "$tmp/dev2/.env" "$tmp/dev2.env" || fail "make bootstrap NAME=5 changed the .env of the copy"
# A folder name with a character sed treats as special in a replacement.
git clone -q "$tmp/remote.git" "$tmp/r&d"
expect_ok in_dir "$tmp/r&d" make bootstrap NAME=3
same "$(envvar "$tmp/r&d" PROJECT_DIR)" "$tmp/r&d" "PROJECT_DIR in the .env of a folder with &"
# A plain second clone would get the dev project of the first: refused before it creates .env,
# with the way to a stack of its own; the first clone's containers stay as they are.
git clone -q "$tmp/remote.git" "$tmp/dev3"
expect_fail in_dir "$tmp/dev3" make dev
has "ERROR: the dev project stdtest-dev already runs from $dev (its containers, stopped ones too, name that folder): a second clone would take them over and share its database; make dev NAME=<n>, with a name no other clone uses, gives this clone a dev stack of its own; nothing was created"
[ ! -e "$tmp/dev3/.env" ] && [ ! -e "$tmp/dev3/.env.new" ] || fail "a refused bootstrap left an .env"
same "$(cid stdtest-dev-dev-1)" "$dev_id" "the dev container after a refused second clone"
# Stopped containers count: Compose would start them again from the other folder.
docker stop stdtest-dev-dev-1 >/dev/null
expect_fail in_dir "$tmp/dev3" make bootstrap
has "the dev project stdtest-dev already runs from $dev "
docker start stdtest-dev-dev-1 >/dev/null
expect_ok in_dir "$tmp/dev3" make bootstrap NAME=3
same "$(envvar "$tmp/dev3" DEV_SUFFIX)" -3 "DEV_SUFFIX with NAME=3"
# A .env with the dev project of another clone (made by hand, or older than this check): every dev
# command refuses, and says how to give this clone its own.
sed -i -e 's|^DEV_SUFFIX=.*|DEV_SUFFIX=|' "$tmp/dev3/.env"
for t in dev lint backup backup-list backup-drill backup-status backup-test restore; do
  expect_fail in_dir "$tmp/dev3" no_tty make "$t"
  has "ERROR: the dev project stdtest-dev also has containers from $dev (stopped ones count): two clones of one dev project take over each other's containers and share its database. Stop it there (make down in that folder, or docker compose -p stdtest-dev down when it is gone), or give this clone a dev stack of its own: DEV_SUFFIX=-<n> and APP_PORT= (empty: a free port) in its .env, then make dev"
done
same "$(cid stdtest-dev-dev-1)" "$dev_id" "the dev container after a refused clone with the same dev project"
rm -rf "$tmp/dev3"
# A project that already had its own .env (Laravel, Symfony): bootstrap keeps it, names what it
# lacks of .env.example, and the messages never advise deleting it.
git clone -q "$tmp/remote.git" "$tmp/laravel"
printf 'APP_NAME=Laravel\nAPP_KEY=base64:c3RkdGVzdA==\nDB_PASSWORD=local-secret\nPROXY_NETWORK=stdtest-proxy\n' > "$tmp/laravel/.env"
cp "$tmp/laravel/.env" "$tmp/laravel.env"
expect_ok in_dir "$tmp/laravel" make bootstrap
has "WARNING: .env lacks variables of .env.example: PROJECT_ENV PROJECT_DIR HOST_UID HOST_GID DEV_SUFFIX APP_PORT"
has "Add them to .env (the comment above each in .env.example says what it is), or let the agent add them"
! grep -qE ' DB_PASSWORD[ .]' "$out" || { cat "$out"; fail "make bootstrap named DB_PASSWORD, which .env has"; }
cmp -s "$tmp/laravel/.env" "$tmp/laravel.env" || fail "make bootstrap changed the project's own .env"
expect_fail in_dir "$tmp/laravel" make dev
has "this clone is PROJECT_ENV= in .env; make dev runs only in a clone with PROJECT_ENV=dev"
echo PROJECT_ENV=dev >> "$tmp/laravel/.env"
expect_fail in_dir "$tmp/laravel" make dev
has "PROJECT_DIR in .env is '', not this folder (a .env from elsewhere?): set PROJECT_DIR=$tmp/laravel in .env; HOST_UID and HOST_GID are the ids of your user (id -u, id -g)"
! grep -q delete "$out" || { cat "$out"; fail "the message advises to delete .env"; }
rm -rf "$tmp/laravel"
# A project without stage and prod: the targets that do not apply refuse.
rm "$tmp/dev2/docker-compose.stage.yml" "$tmp/dev2/docker-compose.prod.yml" "$tmp/dev2/scripts/tuning-check.sh"
expect_fail in_dir "$tmp/dev2" make image-scan
has "no stage or prod"
expect_fail in_dir "$tmp/dev2" make tuning-check
has "no scripts/tuning-check.sh"
# parity and check-compose have nothing to check there, so make infra passes.
expect_ok in_dir "$tmp/dev2" make infra
# A project without a backup service: the backup targets refuse.
rm -r "$tmp/dev2/docker/backup"
for t in backup backup-list backup-drill restore-drill backup-status backup-copy-check backup-test restore; do
  expect_fail in_dir "$tmp/dev2" make "$t"
  has "this project has no backup service (docker/backup/, standard OPS-01)"
done
git -C "$tmp/dev2" checkout -q -- .
# The two extra dev stacks are done: each holds a network, and a machine has few address pools
# (stage and prod with their status-proxy networks come next).
expect_ok in_dir "$tmp/wt" make down
expect_ok in_dir "$tmp/dev2" make down

step "j. make parity and make check-compose"
expect_ok in_dir "$dev" make parity check-compose
has "parity: OK"
has "docker-compose.stage.yml: OK"
has "docker-compose.prod.yml: OK"
sed -i 's/shm_size: 256m/shm_size: 128m/' "$dev/docker-compose.prod.yml"
expect_fail in_dir "$dev" make parity
has "parity: stage and prod differ"
git -C "$dev" checkout -q docker-compose.prod.yml
sed -i 's/^name: stdtest-prod$/name: stdtest-stage/' "$dev/docker-compose.prod.yml"
expect_fail in_dir "$dev" make parity
has "the same name:"
git -C "$dev" checkout -q docker-compose.prod.yml
sed -i 's/^name: stdtest-prod$/name: "stdtest-stage" # the same/' "$dev/docker-compose.prod.yml"
expect_fail in_dir "$dev" make parity
has "the same name:"
git -C "$dev" checkout -q docker-compose.prod.yml

step "k. backups: verify and backup-test in dev; backup, list, drill, status, copy-check, health and restore from the copy; S, SET, FROM, NO_SAFETY and CONFIRM only from make's command line; restore asks for the database name in a terminal"
# The sample's own make verify: it has no E2E or SECURITY command, and infra ends with make
# backup-test.
expect_ok in_dir "$dev" make verify
has "drill: db/"
same "$(summary verify)" "summary of make verify:
  lint      ok    gate words: a  b #1
  test      ok    OK
  e2e       skip  no E2E command in the Makefile settings
  security  ok    secrets: none found
  infra     ok    OK
make verify: OK" "the summary of the sample's make verify"
expect_ok in_dir "$dev" make backup-test
grep -qx OK "$out" || { cat "$out"; fail "make backup-test did not print OK"; }
expect_fail in_dir "$stage" make backup-test
has "make backup-test runs only in dev; on a server make backup-drill checks the sets"
# Dev: a set in the volume backup-data, the list, the status; no off-server copy there.
expect_ok in_dir "$dev" make backup
dev_set=$(sed -n 's|^backup: db/\([0-9]\{8\}T[0-9]\{6\}Z\) OK .*|\1|p' "$out")
[ -n "$dev_set" ] || { cat "$out"; fail "make backup in dev named no set"; }
expect_ok in_dir "$dev" make backup-list
grep -qE "^db +$dev_set +[0-9-]+ [0-9:]+ +[0-9.]+[KMGT] +normal +local\$" "$out" \
  || { cat "$out"; fail "make backup-list in dev does not list $dev_set as a normal local set"; }
expect_fail in_dir "$dev" make backup-list FROM=copy
has "make backup-list FROM=copy runs only on a server: dev has no off-server copy"
expect_fail in_dir "$dev" make backup-list S=nope
has "ERROR: --store is 'nope', not a store of BACKUP_STORES (db)"
# S, SET and FROM from the environment count not: here they would name no store, and the copy.
expect_ok in_dir "$dev" env S=nope SET=20000101T000000Z FROM=copy make backup-list
has "$dev_set"
expect_ok in_dir "$dev" make backup-status
has "healthy: no newest set is older than 26h (BACKUP_MAX_AGE), no failed drill"
has "the newest: $dev_set"
has "last backup: ok at "
# make restore in dev: a person types the database name in a terminal; without a terminal only
# CONFIRM=yes on make's command line confirms it, never one from the environment.
docker exec stdtest-dev-db-1 psql -q -U postgres -c 'CREATE TABLE after_backup (x int)'
after_backup() { docker exec stdtest-dev-db-1 psql -tA -U postgres -c "SELECT count(*) FROM pg_tables WHERE tablename = 'after_backup'"; }
expect_fail in_dir "$dev" no_tty env CONFIRM=yes make restore
has "restore: would restore db from $dev_set (local)"
has "restore replaces the working database postgres on db: run again with CONFIRM=yes"
same "$(after_backup)" 1 "the table made after the backup, after make restore with CONFIRM=yes in the environment"
expect_fail in_dir "$dev" no_tty make restore NO_SAFETY=yes CONFIRM=yes
has "ERROR: NO_SAFETY is 'yes', not 1 (or empty: a safety set first); nothing was replaced"
tty_make nope "$dev" restore
[ "$code" -ne 0 ] || { cat "$out"; fail "make restore in a terminal passed with a wrong name"; }
has "$red"
has "restore: would restore db from $dev_set (local)"
has "restore: to replace the database postgres on db (db), type its name: "
has "ERROR: you typed 'nope', not postgres: nothing was replaced"
same "$(after_backup)" 1 "the table made after the backup, after a wrong name in a terminal"
# In a terminal CONFIRM=yes does not stand for the name.
tty_make '' "$dev" restore CONFIRM=yes
[ "$code" -ne 0 ] || { cat "$out"; fail "make restore CONFIRM=yes in a terminal passed without the name"; }
has "ERROR: you typed '', not postgres: nothing was replaced"
same "$(after_backup)" 1 "the table made after the backup, after CONFIRM=yes and no name in a terminal"
tty_make postgres "$dev" restore
[ "$code" -eq 0 ] || { cat "$out"; fail "make restore in a terminal with the database name typed"; }
has "restore: db OK: equal to the manifest of $dev_set"
same "$(after_backup)" 0 "the table made after the backup, after make restore with the database name typed"
docker exec stdtest-dev-db-1 psql -q -U postgres -c 'CREATE TABLE after_backup (x int)'
# CONFIRM=yes that is not on the command line of make restore itself confirms nothing: from an
# exported MAKEFLAGS or GNUMAKEFLAGS, or from a make that runs make restore.
for v in MAKEFLAGS GNUMAKEFLAGS; do
  expect_fail in_dir "$dev" no_tty env "$v=CONFIRM=yes" make restore
  has "ERROR: CONFIRM=yes is not on the command line of this make: it came from MAKEFLAGS or GNUMAKEFLAGS of the environment, or from a make that runs this one, which confirm nothing; nothing was replaced"
  same "$(after_backup)" 1 "the table made after the backup, after make restore with $v=CONFIRM=yes"
done
# shellcheck disable=SC2016 # $(MAKE) is make's, not the shell's
printf 'all:\n\t$(MAKE) -C %s restore\n' "$dev" > "$tmp/parent.mk"
expect_fail no_tty make -f "$tmp/parent.mk" CONFIRM=yes
has "ERROR: CONFIRM=yes is not on the command line of this make: it came from MAKEFLAGS"
same "$(after_backup)" 1 "the table made after the backup, after make restore from a parent make with CONFIRM=yes"
rm "$tmp/parent.mk"
# A terminal is the input of make restore, not one the process merely has: with its input and
# output redirected, make restore CONFIRM=yes restores without asking.
run in_dir "$dev" env SHELL=/bin/sh script -qefc "timeout --foreground 300 make restore CONFIRM=yes < /dev/null > $tmp/restore.out 2>&1" /dev/null < /dev/null
cp "$tmp/restore.out" "$out"
[ "$code" != 124 ] || { cat "$out"; fail "make restore CONFIRM=yes with its input redirected waited for an answer"; }
[ "$code" -eq 0 ] || { cat "$out"; fail "make restore CONFIRM=yes with its input redirected, in a process with a terminal"; }
has "restore: db OK: equal to the manifest of $dev_set"
! grep -q 'type its name' "$out" || { cat "$out"; fail "make restore asked for the name with its input redirected"; }
same "$(after_backup)" 0 "the table made after the backup, after make restore CONFIRM=yes with its input redirected"
# S= reaches the service in every backup target that takes it: a store BACKUP_STORES lacks is refused.
expect_fail in_dir "$dev" make backup-test S=nope
has "ERROR: --store is 'nope', not a store of BACKUP_STORES (db)"
# Stage: the sets, copied off the server.
docker exec stdtest-stage-db-1 psql -q -U postgres -c 'CREATE TABLE kept (x int); INSERT INTO kept SELECT generate_series(1, 100)'
expect_ok in_dir "$stage" make backup
has "copy: db/"
# S= takes one store, and refuses a name BACKUP_STORES lacks; S from the environment counts not.
expect_ok in_dir "$stage" make backup S=db
has "backup: db/"
expect_fail in_dir "$stage" make backup S=nope
has "ERROR: --store is 'nope', not a store of BACKUP_STORES (db)"
expect_ok in_dir "$stage" env S=nope make backup
has "backup: db/"
expect_ok in_dir "$stage" make backup-list
stage_set=$(awk '$1 == "db" && $2 ~ /^[0-9]+T[0-9]+Z$/ {print $2}' "$out" | tail -n 1)
[ -n "$stage_set" ] || { cat "$out"; fail "make backup-list lists no set of db"; }
grep -qE "^db +$stage_set +[0-9-]+ [0-9:]+ +[0-9.]+[KMGT] +normal +local, copied\$" "$out" \
  || { cat "$out"; fail "make backup-list does not list $stage_set as copied"; }
expect_ok in_dir "$stage" make backup-list FROM=copy
grep -qE "^db +$stage_set +[0-9-]+ [0-9:]+ +- +normal +copy\$" "$out" \
  || { cat "$out"; fail "make backup-list FROM=copy does not list $stage_set in the copy"; }
expect_ok in_dir "$stage" env FROM=copy make backup-list
grep -q 'local, copied$' "$out" || { cat "$out"; fail "make backup-list took FROM=copy from the environment"; }
# The drill: the newest set, or the one SET= names; SET from the environment counts not.
expect_ok in_dir "$stage" make backup-drill
has "drill: db/$stage_set OK: restored and equal to the manifest"
expect_ok in_dir "$stage" make restore-drill
has "drill: db/$stage_set OK: restored and equal to the manifest"
expect_fail in_dir "$stage" make backup-drill SET=20000101T000000Z
has "no set db/20000101T000000Z to drill (the sets: "
expect_ok in_dir "$stage" env SET=20000101T000000Z make backup-drill
has "drill: db/$stage_set OK"
expect_ok in_dir "$stage" make backup-drill S=db SET="$stage_set"
has "drill: db/$stage_set OK"
expect_fail in_dir "$stage" make backup-drill S=nope
has "ERROR: --store is 'nope', not a store of BACKUP_STORES (db)"
# make backup-copy-check runs the service's copy-check: the test set, the refused delete (skipped
# for the local folder of the test), the read check.
expect_ok in_dir "$stage" make backup-copy-check
has "copy-check: the test set "
has "copy-verify: /backup/.copy OK"
same "$(tail -n 1 "$out")" OK "make backup-copy-check"
expect_ok in_dir "$stage" make backup-status
has "backup-status: the backup service runs ("
has "healthy: no newest set or copy is older than 26h (BACKUP_MAX_AGE), no failed drill or check of the copy"
has "db: the newest copy: "
has "last copy-check: ok at "
# The backup targets of a server check .env as make stage does.
chmod 640 "$stage/.env"
expect_fail in_dir "$stage" make backup-status
has ".env can be read or written by other users of this machine (-rw-r-----): chmod 600 .env"
chmod 600 "$stage/.env"
# Health: a newest set older than BACKUP_MAX_AGE makes the service unhealthy.
docker exec -u postgres stdtest-stage-backup-1 sh -c 'cp /backup/.state/set.db /tmp/set.db && echo $(( $(date +%s) - 100000 )) > /backup/.state/set.db'
expect_fail docker exec stdtest-stage-backup-1 backup health
has "unhealthy: the newest set of db was made 27h46m ago (BACKUP_MAX_AGE=26h)"
expect_fail in_dir "$stage" make backup-status
has "unhealthy: the newest set of db was made 27h46m ago (BACKUP_MAX_AGE=26h)"
docker exec -u postgres stdtest-stage-backup-1 cp /tmp/set.db /backup/.state/set.db
expect_ok docker exec stdtest-stage-backup-1 backup health
# Dev has no off-server copy.
expect_fail in_dir "$dev" make backup-copy-check
has "make backup-copy-check runs only on a server: dev has no off-server copy"
expect_fail in_dir "$dev" no_tty make restore FROM=copy
has "make restore FROM=copy runs only on a server: dev has no off-server copy"
# make restore checks first: without CONFIRM=yes, or with a set that does not exist, nothing stops.
expect_fail in_dir "$stage" no_tty make restore FROM=copy SET=latest
has "restore: would restore db from $stage_set (copy)"
has "restore replaces the working database postgres on db: run again with CONFIRM=yes"
running stdtest-stage-app-1
# CONFIRM, SET and FROM from the environment count not.
expect_fail in_dir "$stage" no_tty env CONFIRM=yes SET=20000101T000000Z FROM=copy make restore
has "restore: would restore db from $stage_set (local)"
has "restore replaces the working database postgres on db: run again with CONFIRM=yes"
running stdtest-stage-app-1
expect_fail in_dir "$stage" no_tty make restore SET=20000101T000000Z CONFIRM=yes
has "ERROR: no local set db/20000101T000000Z"
! grep -q "restore: stopping" "$out" || { cat "$out"; fail "make restore stopped the application for a set that does not exist"; }
running stdtest-stage-app-1
expect_fail in_dir "$stage" no_tty make restore S=nope CONFIRM=yes
has "ERROR: --store is 'nope', not a store of BACKUP_STORES (db)"
! grep -q "restore: stopping" "$out" || { cat "$out"; fail "make restore S=nope stopped the application"; }
running stdtest-stage-app-1
# With the backup service stopped, make backup-status says so and reads the backup folder; the
# check and the refusal of make restore run in a one-off container: nothing starts.
stage_compose() { in_dir "$stage" env IMAGE_TAG="$(git -C "$stage" rev-parse 'HEAD^{tree}')" docker compose -f docker-compose.stage.yml "$@"; }
stage_compose stop backup >/dev/null 2>&1
expect_fail in_dir "$stage" make backup-status
has "backup-status: the backup service does not run (exited): make logs S=backup shows why; what its backup folder holds:"
has "last backup: ok at "
expect_fail in_dir "$stage" no_tty make restore
has "restore: would restore db from "
has "restore replaces the working database postgres on db: run again with CONFIRM=yes"
[ "$(docker inspect -f '{{.State.Running}}' stdtest-stage-backup-1)" = false ] || fail "make backup-status or make restore without CONFIRM=yes started the backup service"
running stdtest-stage-app-1
stage_compose start backup >/dev/null 2>&1
# Backups, a restore and make images never depend on monitoring: a DOCKER_GID that is not the
# socket's refuses none of them (only the commands that start status-proxy check it).
sed -i 's|^DOCKER_GID=.*|DOCKER_GID=999999|' "$stage/.env"
for t in backup-list backup-status images; do
  expect_ok in_dir "$stage" make "$t"
  ! grep -q "DOCKER_GID is '999999'" "$out" || { cat "$out"; fail "make $t refused a wrong DOCKER_GID"; }
done
# A restore from the copy into an empty database; make restore stops the application first.
docker rm -f stdtest-stage-db-1 >/dev/null
docker volume rm stdtest-stage_db >/dev/null
expect_ok in_dir "$stage" no_tty make restore FROM=copy SET=latest CONFIRM=yes
grep -qx "restore: stopping app for the restore" "$out" || { cat "$out"; fail "the output lacks the line: restore: stopping app for the restore"; }
has "copy: fetched db/"
has "restore: db OK: equal to the manifest"
grep -qx "restore: the application is stopped: make restart starts it again" "$out" \
  || { cat "$out"; fail "the output lacks the line: restore: the application is stopped: make restart starts it again"; }
same "$(docker exec stdtest-stage-db-1 psql -tA -U postgres -c 'SELECT count(*) FROM kept')" 100 "the rows after the restore"
[ "$(docker inspect -f '{{.State.Running}}' stdtest-stage-app-1)" = false ] || fail "the application runs after make restore"
# The status service and its proxy write nothing: they go on reporting during the restore.
running stdtest-stage-status-1
running stdtest-stage-status-proxy-1
sed -i "s|^DOCKER_GID=.*|DOCKER_GID=$gid|" "$stage/.env"
# The safety set that restore made: make backup-list names it, copied; SET=before-restore drills it.
expect_ok in_dir "$stage" make backup-list
safety=$(awk '$1 == "db" && $2 ~ /^before-restore-/ {print $2}' "$out")
grep -qE "^db +$safety +[0-9-]+ [0-9:]+ +[0-9.]+[KMGT] +before-restore +local, copied\$" "$out" \
  || { cat "$out"; fail "make backup-list does not list one copied safety set after make restore"; }
expect_ok in_dir "$stage" make backup-drill SET=before-restore
has "drill: db/$safety OK: restored and equal to the manifest"
# On a server not deployed yet, make stage starts the application, not make restart. NO_SAFETY
# from the environment counts not: a safety set comes first.
mv "$stage/.deploy/history" "$tmp/stage.history"
expect_ok in_dir "$stage" no_tty env NO_SAFETY=1 make restore CONFIRM=yes
has "backup: db/before-restore-"
has "restore: the application is stopped: make stage starts it again"
mv "$tmp/stage.history" "$stage/.deploy/history"
# NO_SAFETY=1 on the command line: no safety set; the one there stays.
expect_ok in_dir "$stage" make backup-list
safety=$(awk '$1 == "db" && $2 ~ /^before-restore-/ {print $2}' "$out")
expect_ok in_dir "$stage" no_tty make restore CONFIRM=yes NO_SAFETY=1
has "restore: db: no safety set (NO_SAFETY=1)"
has "restore: db OK: equal to the manifest"
! grep -q '^backup: db/before-restore-' "$out" || { cat "$out"; fail "make restore NO_SAFETY=1 made a safety set"; }
expect_ok in_dir "$stage" make backup-list
same "$(awk '$1 == "db" && $2 ~ /^before-restore-/ {print $2}' "$out")" "$safety" "the safety set after make restore NO_SAFETY=1"
expect_ok in_dir "$stage" make restart
has "OK: stage runs $tip (restarted with the current .env)"
running stdtest-stage-app-1
# The application's role came back with the restored roles and still logs in.
same "$(app_role stdtest-stage-db-1 stageapp)" f "the stage application's role after a restore into an empty database"
# The restored backup role has no password; the next backup sets it from .env again.
expect_ok in_dir "$stage" make backup
has "backup: db/"
# An unhealthy backup service (here a failed drill) does not block a deploy: it runs, is recorded
# and warns.
docker exec -u postgres stdtest-stage-backup-1 sh -c 'echo "failed $(date +%s) a drill that failed on purpose" > /backup/.state/drill'
expect_ok in_dir "$stage" make stage
has "WARNING: backup unhealthy: the last drill failed: a drill that failed on purpose (docs/how-to/backups.md)"
has "OK: stage runs $tip"
grep -q " $tip\$" "$stage/.deploy/history" || fail ".deploy/history does not record $tip"
docker exec -u postgres stdtest-stage-backup-1 rm /backup/.state/drill

step "l. a changed APP_DB_PASSWORD; one copy of stage per machine: a second clone is refused, and only warned once the first one's containers are gone"
# A changed password of the application's role: make restart recreates db and app, and db sets it.
sed -i 's|^APP_DB_PASSWORD=.*|APP_DB_PASSWORD=stageapp2|' "$stage/.env"
expect_ok in_dir "$stage" make restart
same "$(docker exec stdtest-stage-app-1 printenv DATABASE_URL)" "postgresql://app:stageapp2@db:5432/postgres" "DATABASE_URL after a changed APP_DB_PASSWORD"
same "$(app_role stdtest-stage-db-1 stageapp2)" f "the application's role with the changed password"
! app_role stdtest-stage-db-1 stageapp >/dev/null 2>&1 || fail "the old password of the application's role still logs in"
# A second stage clone on this machine is refused before it changes anything.
server_clone "$tmp/stage2" stage "$stage_port" "$stage_status_port"
app_id=$(cid stdtest-stage-app-1)
for t in stage images restore backup backup-list backup-drill backup-status backup-copy-check; do
  expect_fail in_dir "$tmp/stage2" make "$t"
  has "ERROR: stdtest-stage already runs from $stage (its containers, stopped ones too, name that folder): a second copy of stage on this machine would take over its containers, volumes and data, so a machine runs one copy of stage; nothing was changed. To run it from this folder instead, stop it in that folder with docker compose -p stdtest-stage down (the volumes stay, and this folder's make stage uses them)"
done
same "$(cid stdtest-stage-app-1)" "$app_id" "the stage app container after a refused second clone"
[ ! -e "$tmp/stage2/.deploy" ] || fail "a refused second stage clone has .deploy"
# The first clone reached through a symbolic link is no other folder, and neither is a container
# that Compose labelled with the link's path (docker compose run by hand from there).
ln -s "$stage" "$tmp/stage-link"
expect_ok in_dir "$tmp/stage-link" make images
(cd "$tmp/stage-link" && IMAGE_TAG=$(git rev-parse 'HEAD^{tree}') docker compose -f docker-compose.stage.yml \
  run -d --no-deps --name stdtest-stage-oneoff --entrypoint sleep app 60) >/dev/null
same "$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' stdtest-stage-oneoff)" \
  "$tmp/stage-link" "the folder label of a container run from the link"
expect_ok in_dir "$stage" make images
docker rm -f stdtest-stage-oneoff >/dev/null
# Stopped as the message says, the first copy leaves only its volumes, which carry no folder: the
# second clone's first deploy uses them and says so.
in_dir "$tmp" docker compose -p stdtest-stage down >/dev/null 2>&1
expect_ok in_dir "$tmp/stage2" make stage
has "WARNING: the volumes of stdtest-stage exist, but no container of it: this first deploy of this clone uses their data"
has "OK: stage runs $tip"
expect_fail in_dir "$stage" make images
has "ERROR: stdtest-stage already runs from $tmp/stage2 "
# Dev: after make down only the volumes are left; a plain clone is only warned that it uses them.
expect_ok in_dir "$dev" make down
git clone -q "$tmp/remote.git" "$tmp/dev4"
expect_ok in_dir "$tmp/dev4" make bootstrap
has "WARNING: the volumes of stdtest-dev exist, but no container of it: this clone's dev stack uses their data"

echo "project tests: OK"
