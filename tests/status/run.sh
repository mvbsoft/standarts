#!/bin/sh
# Builds the status image from templates/project/docker/status and proves it in a small hardened
# compose project with the socket proxy, healthy and breakable services, a push receiver and a
# second compose project: the token (401, also while failing), the envelope and its fields, the
# overall status (pass, warn while a service starts, fail) with 200 or 503, unknown when the
# inspect is refused without a health in the list, no ms or output from before a restart, no
# environment or command line in the answer, the proxy that refuses every write, logs and another
# project's containers, the free-space threshold (DISK_WARN, DISK_RESERVE), the push to the success
# or the failure address (none when that one is empty) and a failing push, a stopped and a removed
# service, a stopped proxy, a backup folder it can measure but not read, non-root. The images are
# pinned by tag and digest; a missing one is pulled. Everything it creates in Docker is named
# stdstatus*; it removes all of it on exit.
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)

step() { printf 'status: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; exit 1; }
proxy_img=wollomatic/socket-proxy:1.13.1@sha256:3935b709275e4ec35d6ed5a5c4a1f0d01ed31eec5e7234efc3357ecd47689002
bb=busybox:1.38.0@sha256:dc2d74b28e4cf8984fa52af1f39bc7c3d9c73760b41a74d629f5d11b1ab28616
py=python:3.12.13-slim@sha256:229a2c5bfa27522db7815ea81f9bed70af17ccb9de9fc7ad142b1877b5830d36
for i in "$proxy_img" "$bb" "$py"; do
  docker image inspect "$i" >/dev/null 2>&1 || docker pull -q "$i" >/dev/null || fail "$i is not local and cannot be pulled"
done

tmp=$(mktemp -d /tmp/stdstatus.XXXXXX)
out=$tmp/out
cleanup() {
  status=$?
  set +e
  docker compose -p stdstatus -f "$tmp/compose.yml" down -v --remove-orphans >/dev/null 2>&1
  docker compose -p stdstatusx -f "$tmp/other.yml" down -v --remove-orphans >/dev/null 2>&1
  for c in $(docker ps -a --format '{{.Names}}' | grep '^stdstatus'); do docker rm -f "$c" >/dev/null; done
  for v in $(docker volume ls -q | grep '^stdstatus'); do docker volume rm "$v" >/dev/null; done
  for n in $(docker network ls --format '{{.Name}}' | grep '^stdstatus'); do docker network rm "$n" >/dev/null; done
  docker rmi stdstatus-status:1 >/dev/null 2>&1
  rm -rf "$tmp"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 1' INT TERM
unset COMPOSE_FILE COMPOSE_PROJECT_NAME COMPOSE_PROFILES STATUS_PUSH_URL STATUS_PUSH_FAIL_URL STATUS_PUSH_INTERVAL \
  DISK_WARN DISK_RESERVE

# run <command>: its output goes to $out, its exit code to $code.
run() { if "$@" > "$out" 2>&1; then code=0; else code=$?; fi; }
expect_ok() { run "$@"; [ "$code" -eq 0 ] || { cat "$out"; fail "expected success: $*"; }; }
has() { grep -qE -- "$1" "$out" || { cat "$out"; fail "the output lacks: $1"; }; }
lacks() { ! grep -qF -- "$1" "$out" || { cat "$out"; fail "the output has: $1"; }; }
dc() { docker compose -p stdstatus -f "$tmp/compose.yml" "$@"; }
probe() { dc exec -T status python -I - "$@" < "$root/tests/status/probe.py"; }
# proxy_is <code> <method> <path>: what the socket proxy answers the status container.
proxy_is() {
  got=$(probe proxy "$2" "$3")
  [ "$got" = "$1" ] || fail "the proxy answered $got to $2 $3, expected $1"
}
# until_has <regex>: wait up to 40 s until the summary of GET /status has a matching line.
until_has() {
  i=0
  while :; do
    run probe summary
    grep -qE -- "$1" "$out" && return 0
    i=$((i + 1)); [ "$i" -lt 40 ] || { cat "$out"; fail "GET /status never showed: $1"; }
    sleep 1
  done
}
# restart_status <VAR=value>...: recreate the status service with these settings.
restart_status() { expect_ok env "$@" docker compose -p stdstatus -f "$tmp/compose.yml" up -d --wait status; }
# pushes <path>: how many POSTs the receiver has got on <path>.
pushes() { dc logs --no-log-prefix sink | grep -c "^PUSH $1 " || :; }
# until_pushes <path> <n>: wait up to 30 s until the receiver has got <n> POSTs on <path>.
until_pushes() {
  i=0
  until [ "$(pushes "$1")" -ge "$2" ]; do
    i=$((i + 1)); [ "$i" -lt 30 ] || { dc logs status sink; fail "the receiver got fewer than $2 pushes on $1"; }
    sleep 1
  done
}
# status_logs <text>: wait up to 30 s until the status service has logged <text>.
status_logs() {
  i=0
  until dc logs --no-log-prefix status 2>&1 | grep -qF -- "$1"; do
    i=$((i + 1)); [ "$i" -lt 30 ] || { dc logs status; fail "the status service never logged: $1"; }
    sleep 1
  done
}

step "the image from the template"
mkdir -p "$tmp/ctx/docker"
cp -R "$root/templates/project/docker/status" "$tmp/ctx/docker/"
expect_ok docker build -q --target runtime -t stdstatus-status:1 -f "$tmp/ctx/docker/status/Dockerfile" "$tmp/ctx"
user=$(docker image inspect -f '{{.Config.User}}' stdstatus-status:1)
case "${user%%:*}" in ''|0|root) fail "the status image runs as '${user:-root}'" ;; esac

# The proxy and the status service as in the template's stage and prod compose files, with
# shorter intervals; the test services break and heal on demand. slow checks every 15 s, so after
# a restart it stays starting, with only the results from before, for that long. odd has a name
# outside <project>-<service>-<n>, so the proxy refuses its inspect.
cat > "$tmp/compose.yml" <<'EOF'
name: stdstatus
x-hard: &hard
  init: true
  read_only: true
  cap_drop: [ALL]
  security_opt: ["no-new-privileges:true"]
services:
  status-proxy:
    <<: *hard
    image: @PROXY@
    user: "65534:${DOCKER_GID:?}"
    command:
      - -loglevel=INFO
      - -listenip=0.0.0.0
      - -allowfrom=status
      - -allowhealthcheck
      - -allowGET=(?:/v1\.[0-9]+)?/containers/(?:json|${COMPOSE_PROJECT_NAME}-[a-z0-9_-]+-[0-9]+/json)
    volumes: ["/var/run/docker.sock:/var/run/docker.sock:ro"]
    networks: [status-proxy]
    healthcheck: {test: ["CMD", "/healthcheck"], interval: 2s, timeout: 2s, retries: 3}
    deploy: {resources: {limits: {cpus: "0.25", memory: 32M}}}
    memswap_limit: 32M
  status:
    <<: *hard
    image: stdstatus-status:1
    ports: ["127.0.0.1::8080"]
    environment:
      STATUS_PROJECT: "${COMPOSE_PROJECT_NAME}"
      STATUS_TOKEN: "${STATUS_TOKEN:?}"
      STATUS_PUSH_URL: "${STATUS_PUSH_URL-}"
      STATUS_PUSH_FAIL_URL: "${STATUS_PUSH_FAIL_URL-}"
      STATUS_PUSH_INTERVAL: "${STATUS_PUSH_INTERVAL:-2s}"
      DISK_WARN: "${DISK_WARN:-10%}"
      DISK_RESERVE: "${DISK_RESERVE:-1M}"
    volumes: ["small:/disk/backup:ro"]
    networks: [default, status-proxy]
    healthcheck: {test: ["CMD", "status", "health"], interval: 2s, timeout: 5s, retries: 3}
    depends_on: {status-proxy: {condition: service_healthy}}
    deploy: {resources: {limits: {cpus: "0.5", memory: 64M}}}
    memswap_limit: 64M
  good:
    image: @BB@
    init: true
    command: ["sleep", "1000000"]
    volumes: ["small:/fill"]
    healthcheck: {test: ["CMD-SHELL", "echo fine"], interval: 1s, timeout: 2s, retries: 2}
  bad:
    image: @BB@
    init: true
    environment: {PLANTED_PASSWORD: "stdstatus-planted-env-s3cret"}
    command: ["sh", "-c", "sleep 1000000", "stdstatus-planted-cmd-s3cret"]
    healthcheck: {test: ["CMD-SHELL", "if [ -e /tmp/broken ]; then echo broken-output; exit 1; fi; echo fine"], interval: 1s, timeout: 2s, retries: 2}
  slow:
    image: @BB@
    init: true
    command: ["sleep", "1000000"]
    healthcheck: {test: ["CMD-SHELL", "echo slow-fine"], interval: 15s, timeout: 2s, retries: 2}
  odd:
    image: @BB@
    init: true
    container_name: stdstatus-odd
    command: ["sleep", "1000000"]
    healthcheck: {test: ["CMD-SHELL", "echo odd-fine"], interval: 1s, timeout: 2s, retries: 2}
  sink:
    image: @PY@
    command: ["python", "-I", "-u", "/sink.py"]
    volumes: ["./sink.py:/sink.py:ro"]
    healthcheck: {test: ["CMD", "python", "-c", "import socket; socket.create_connection(('127.0.0.1', 8000))"], interval: 2s, timeout: 2s, retries: 3}
  intruder:
    image: @BB@
    init: true
    command: ["sleep", "1000000"]
    networks: [status-proxy]
    healthcheck: {test: ["CMD-SHELL", "true"], interval: 2s, timeout: 2s, retries: 2}
volumes:
  small: {driver: local, driver_opts: {type: tmpfs, device: tmpfs, o: "size=16m"}}
networks:
  default: {}
  status-proxy: {internal: true}
EOF
cat > "$tmp/other.yml" <<'EOF'
name: stdstatusx
services:
  web:
    image: @BB@
    init: true
    command: ["sleep", "1000000"]
    healthcheck: {test: ["CMD-SHELL", "echo fine"], interval: 1s, timeout: 2s, retries: 2}
EOF
# The push receiver: one line PUSH <path> <content type> <body> per POST; 404 on /missing.
cat > "$tmp/sink.py" <<'EOF'
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        print("PUSH", self.path, self.headers.get("Content-Type"), body.decode(), flush=True)
        self.send_response(404 if self.path == "/missing" else 204)
        self.end_headers()
ThreadingHTTPServer(("0.0.0.0", 8000), H).serve_forever()
EOF
sed -i "s|@PROXY@|$proxy_img|; s|@BB@|$bb|; s|@PY@|$py|" "$tmp/compose.yml" "$tmp/other.yml"
DOCKER_GID=$(stat -c %g /var/run/docker.sock)
STATUS_TOKEN=stdstatus-token-0123456789abcdef
export DOCKER_GID STATUS_TOKEN

step "a second compose project, then this one, with 12 of the 16 MB of the backup disk used"
expect_ok docker compose -p stdstatusx -f "$tmp/other.yml" up -d --wait
expect_ok dc up -d --wait good
expect_ok dc exec -T good dd if=/dev/zero of=/fill/used bs=1M count=12
# As the backup service keeps BACKUP_DIR: only its owner may enter it.
expect_ok dc exec -T good chmod 700 /fill
expect_ok dc up -d --wait
run dc exec -T status id -u
[ "$(cat "$out")" != 0 ] || fail "the status service runs as root"
[ "$(docker inspect -f '{{.Config.User}}' stdstatus-status-proxy-1)" = "65534:$DOCKER_GID" ] || fail "the proxy does not run as 65534:$DOCKER_GID"

step "the token"
run probe get /status none; has '^401$'; lacks "services"
run probe get /status wrong; has '^401$'; lacks "services"
run probe get /health none; has '^200$'; lacks "services"

step "all healthy: status pass, 200, every field"
until_has '^status pass$'
has '^code 200$'
has '^ok True$'
has '^keys checked_at disk ok project services status$'
has '^project stdstatus$'
for s in good bad slow sink intruder status status-proxy; do
  has "^service $s healthy keys=failing,ms,output,status failing=0 ms=[0-9]+ "
done
has "^service good healthy .* output='fine\\\\n'$"
has '^disk docker healthy keys=free_bytes,free_pct,min_free_bytes,status$'
has '^disk backup healthy '
lacks stdstatusx
run dc exec -T status ls /disk/backup
[ "$code" -ne 0 ] || fail "the status service can read the backup folder"

step "a refused inspect: the health from the list, no ms or output; without it unknown, a failure"
until_has '^service odd '
has "^service odd healthy keys=failing,ms,output,status failing=0 ms=None output=None$"
proxy_is 403 GET "/containers/stdstatus-odd/json"
# On this engine the list has the health (Docker API 1.52 and later); the older case in the code.
run probe unit
has '^refused-no-health unknown$'
has '^failed-no-health unknown$'
has '^refused-with-health healthy$'
has '^overall-unknown fail$'
has '^overall-starting warn$'

step "no push while STATUS_PUSH_URL is empty"
run dc logs --no-log-prefix sink
lacks PUSH

step "one service unhealthy: status fail, 503, its failing streak and raw output; 401 first"
expect_ok dc exec -T bad touch /tmp/broken
until_has '^service bad unhealthy '
has '^code 503$'
has '^status fail$'
has '^ok False$'
has "^service bad unhealthy keys=failing,ms,output,status failing=[1-9][0-9]* ms=[0-9]+ output='broken-output\\\\n'$"
has '^service good healthy '
run probe get /status none; has '^401$'; lacks "services"

step "no environment, command line or token in the answer"
run probe get /status right
has '^503$'
has '"bad"'
lacks stdstatus-planted-env-s3cret
lacks stdstatus-planted-cmd-s3cret
lacks PLANTED_PASSWORD
lacks "$STATUS_TOKEN"

step "healed: status pass again"
expect_ok dc exec -T bad rm /tmp/broken
until_has '^status pass$'
has '^code 200$'

step "restarted: starting is warn (200), no ms or output from before the restart"
expect_ok docker restart -t 1 stdstatus-slow-1
until_has '^service slow starting '
has "^service slow starting keys=failing,ms,output,status failing=0 ms=None output=None$"
has '^status warn$'
has '^code 200$'
has '^ok True$'
until_has "^service slow healthy .* ms=[0-9]+ output='slow-fine\\\\n'$"
has '^status pass$'

step "the proxy: list and own inspect only"
id=$(docker inspect -f '{{.Id}}' stdstatus-good-1)
proxy_is 200 GET "/containers/json"
proxy_is 200 GET "/v1.52/containers/stdstatus-good-1/json"
proxy_is 403 GET "/v1.52/containers/$id/json"
proxy_is 403 GET "/containers/stdstatusx-web-1/json"
proxy_is 403 GET "/v1.52/containers/stdstatusx-web-1/json"
proxy_is 403 GET "/containers/stdstatus-good-1/logs?stdout=1"
proxy_is 403 GET "/containers/stdstatus-good-1/archive?path=/etc/hostname"
proxy_is 403 GET "/containers/json/../stdstatus-good-1/logs?stdout=1"
proxy_is 403 GET "/info"
proxy_is 405 POST "/containers/create"
proxy_is 405 POST "/containers/stdstatus-good-1/stop"
proxy_is 405 POST "/containers/stdstatus-good-1/start"
proxy_is 405 POST "/containers/stdstatus-good-1/exec"
proxy_is 405 DELETE "/containers/stdstatus-good-1"
[ "$(docker inspect -f '{{.State.Status}}' stdstatus-good-1)" = running ] || fail "a refused request stopped the container"
run dc exec -T intruder wget -q -O - http://status-proxy:2375/containers/json
has '403 Forbidden'

step "the proxy stopped: an error, status fail, the status service unhealthy, then back"
expect_ok docker stop -t 1 stdstatus-status-proxy-1
until_has '^error cannot read the containers: '
has '^code 503$'
has '^status fail$'
i=0
until [ "$(docker inspect -f '{{.State.Health.Status}}' stdstatus-status-1)" = unhealthy ]; do
  i=$((i + 1)); [ "$i" -lt 30 ] || fail "the status service stayed healthy without the proxy"
  sleep 1
done
expect_ok docker start stdstatus-status-proxy-1
until_has '^status pass$'

step "the free-space threshold"
# Right after a restart the status service sees itself starting; wait until only the disk is left.
restart_status DISK_WARN=50%
until_has '^service status healthy '
has '^disk backup unhealthy '
lacks 'service bad unhealthy'
has '^status fail$'
has '^code 503$'
restart_status DISK_WARN=1% DISK_RESERVE=8M
until_has '^service status healthy '
has '^disk backup unhealthy '
has '^disk docker healthy '
has '^status fail$'
restart_status DISK_WARN=0 DISK_RESERVE=0
until_has '^status pass$'
has '^disk backup healthy '

step "the push: pass and warn to STATUS_PUSH_URL, fail to STATUS_PUSH_FAIL_URL"
restart_status STATUS_PUSH_URL=http://sink:8000/ok STATUS_PUSH_FAIL_URL=http://sink:8000/fail STATUS_PUSH_INTERVAL=1s
until_pushes /ok 2
[ "$(pushes /fail)" -eq 0 ] || fail "a push went to the failure address while nothing failed"
run dc logs --no-log-prefix sink
has '^PUSH /ok application/json \{"project": "stdstatus", "ok": true, '
lacks stdstatus-planted-env-s3cret
lacks stdstatus-planted-cmd-s3cret
expect_ok dc exec -T bad touch /tmp/broken
until_pushes /fail 2
run dc logs --no-log-prefix sink
has '^PUSH /fail application/json \{"project": "stdstatus", "ok": false, .*"status": "fail"\}$'
n=$(pushes /ok)
sleep 3
[ "$(pushes /ok)" -eq "$n" ] || fail "a push went to the success address while bad failed"
status_logs "now fail: pushing to STATUS_PUSH_FAIL_URL"

step "fail with STATUS_PUSH_FAIL_URL empty: no push at all; healed: STATUS_PUSH_URL again"
restart_status STATUS_PUSH_URL=http://sink:8000/ok STATUS_PUSH_INTERVAL=1s
status_logs "now fail: no push, empty STATUS_PUSH_FAIL_URL"
# Counted once the new instance runs: the one it replaced may have pushed until it stopped.
before=$(dc logs --no-log-prefix sink | grep -c '^PUSH ' || :)
sleep 3
[ "$(dc logs --no-log-prefix sink | grep -c '^PUSH ' || :)" -eq "$before" ] || fail "a push was sent while failing with STATUS_PUSH_FAIL_URL empty"
n=$(pushes /ok)
expect_ok dc exec -T bad rm /tmp/broken
until_pushes /ok $((n + 2))

step "a push answered 404, and one that cannot connect: only logged"
restart_status STATUS_PUSH_URL=http://sink:8000/missing STATUS_PUSH_INTERVAL=1s
status_logs "push failed: HTTPError: Not Found"
restart_status STATUS_PUSH_URL=http://sink:9/push STATUS_PUSH_INTERVAL=1s
status_logs "push failed: URLError"
run dc logs --no-log-prefix status
lacks 'sink:9'
[ "$(docker inspect -f '{{.State.Health.Status}}' stdstatus-status-1)" = healthy ] || fail "a failing push made the status service unhealthy"

step "a stopped service is down, a removed one is missing: fail"
expect_ok docker stop -t 1 stdstatus-good-1
until_has '^service good down '
has '^service status healthy '
has '^status fail$'
has '^code 503$'
expect_ok docker rm stdstatus-good-1
until_has '^service good missing '
has '^service status healthy '
has '^status fail$'
expect_ok dc up -d --wait good
until_has '^status pass$'

step "OK"
