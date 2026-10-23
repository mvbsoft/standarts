#!/bin/sh
# Builds the backup image from templates/project/docker/backup and proves it against a seeded
# Postgres in a small hardened compose project (standard OPS-01): the backup folder the service
# takes and the ones it refuses, the set and its manifest, an interrupted backup, drills that pass
# and fail (also of a named set), rotation, too little free space, the write-only copy on an
# append-only rest-server that the server's login cannot delete from, copy-check and its failures,
# the read check of the copy, restore --check and --plan, a missing copy that a restore never
# creates, restore from the copy (also of a set a planted snapshot shadows), the safety set before a restore, the CONFIRM guard, list and
# status, one store of two (--store), the health rules, a killed daily run, the notification and
# its tool, the heartbeat after a good daily run only, the refused superuser and owner roles,
# non-root and read_only. The images are pinned by tag and digest; a missing one is pulled.
# Everything it creates in Docker is named bktest*; it removes all of it on exit.
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)

step() { printf 'backup: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; exit 1; }
pg=postgres:16.15-alpine@sha256:721873c34ceb9f8d8fc265984940dc982404c105f19ad51be9fdc5970a6080ea
restic_img=restic/restic:0.19.1@sha256:136600b6ff6843d61d355f7f71f460a166429f35de6fd11b568fece3c9a4d510
rs_img=restic/rest-server:0.14.0@sha256:d2aff06f47eb38637dff580c3e6bce4af98f386c396a25d32eb6727ec96214a5
bb=busybox:1.38.0@sha256:dc2d74b28e4cf8984fa52af1f39bc7c3d9c73760b41a74d629f5d11b1ab28616
alp=alpine:3.20.10@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc
for i in "$pg" "$restic_img" "$rs_img" "$bb" "$alp"; do
  docker image inspect "$i" >/dev/null 2>&1 || docker pull -q "$i" >/dev/null || fail "$i is not local and cannot be pulled"
done

tmp=$(mktemp -d /tmp/bktest.XXXXXX)
out=$tmp/out
cleanup() {
  status=$?
  set +e
  docker compose -p bktest -f "$tmp/compose.yml" down -v --remove-orphans >/dev/null 2>&1
  for c in $(docker ps -a --format '{{.Names}}' | grep '^bktest'); do docker rm -f "$c" >/dev/null; done
  for v in $(docker volume ls -q | grep '^bktest'); do docker volume rm "$v" >/dev/null; done
  for n in $(docker network ls --format '{{.Name}}' | grep '^bktest'); do docker network rm "$n" >/dev/null; done
  docker rmi bktest-backup:1 >/dev/null 2>&1
  # The sets belong to the container's postgres user and the copy to rest-server's root, so a root
  # container removes them.
  docker run --rm --network none -v "$tmp:/t" "$alp" sh -c 'rm -rf /t/* /t/.[!.]*' >/dev/null 2>&1
  rm -rf "$tmp"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 1' INT TERM
unset COMPOSE_FILE COMPOSE_PROJECT_NAME COMPOSE_PROFILES

# run <command>: its output goes to $out, its exit code to $code.
run() { if "$@" > "$out" 2>&1; then code=0; else code=$?; fi; }
expect_ok() { run "$@"; [ "$code" -eq 0 ] || { cat "$out"; fail "expected success: $*"; }; }
expect_fail() { run "$@"; [ "$code" -ne 0 ] || { cat "$out"; fail "expected a failure: $*"; }; }
has() { grep -qF -- "$1" "$out" || { cat "$out"; fail "the output lacks: $1"; }; }
lacks() { ! grep -qF -- "$1" "$out" || { cat "$out"; fail "the output has: $1"; }; }
same() { [ "$1" = "$2" ] || fail "$3: '$1', expected '$2'"; }
dc() { docker compose -p bktest -f "$tmp/compose.yml" "$@"; }
bk() { dc exec -T backup backup "$@"; }                     # as make does on a server
bkrun() { dc run --rm -T "$@"; }                             # as make does in dev
inb() { dc exec -T -u postgres backup sh -c "$1"; }          # look inside, as the postgres user
sql() { dc exec -T db psql -X -q -At -U postgres -d postgres -c "$1"; }
sets() { inb 'ls -1 /backup/db' | grep -E '^[0-9]{8}T[0-9]{6}Z$' | sort | tr '\n' ' ' | sed 's/ $//'; }
newest() { inb 'ls -1 /backup/db' | grep -E '^[0-9]{8}T[0-9]{6}Z$' | sort | tail -n 1; }
safety() { inb 'ls -1 /backup/db' | grep -E '^before-restore-[0-9]{8}T[0-9]{6}Z$' | sort | tr '\n' ' ' | sed 's/ $//'; }
asroot() { docker run --rm --network none -v "$tmp:/t" "$alp" sh -c "$1"; }  # look at the host folders as root
# rrestic <login> <password> <instance> <args>: restic on the copy, as the server (prod, through the
# append-only instance rs) or as the storage side (admin, through the full-access instance rsadmin).
rrestic() {
  l=$1 p=$2 h=$3; shift 3
  docker run --rm --network bktest_default -e RESTIC_PASSWORD=copy-secret -e RESTIC_CACHE_DIR=/tmp/c \
    -e RESTIC_REST_USERNAME="$l" -e RESTIC_REST_PASSWORD="$p" "$restic_img" -r "rest:http://$h:8000/prod/" "$@"
}
snapshots() { rrestic prod prod-secret rs snapshots --json | grep -o '"short_id"' | wc -l | tr -d ' '; }  # in the copy
health_is() { # wait up to 30 s for the compose health status $1
  i=0
  while [ "$(docker inspect -f '{{.State.Health.Status}}' bktest-backup-1)" != "$1" ]; do
    i=$((i + 1)); [ "$i" -lt 30 ] || fail "the backup container is not $1: $(docker inspect -f '{{json .State.Health}}' bktest-backup-1)"
    sleep 1
  done
}
up_backup() { expect_ok dc up -d --wait backup; }
withdir() { o=$BKT_DIR; BKT_DIR=$1; shift; "$@"; BKT_DIR=$o; }  # withdir <folder> <command>: with BKT_DIR=<folder>

step "the image from the template, a seeded database, an append-only rest-server"
mkdir -p "$tmp/ctx/docker" "$tmp/www/cgi-bin" "$tmp/rs"
cp -R "$root/templates/project/docker/backup" "$tmp/ctx/docker/"
sed -i "s|<postgres image>:<version>@sha256:<digest>|$pg|" "$tmp/ctx/docker/backup/Dockerfile"
expect_ok docker build -q --target runtime -t bktest-backup:1 -f "$tmp/ctx/docker/backup/Dockerfile" "$tmp/ctx"
# The webhook: a CGI script that keeps the body of the last POST.
cat > "$tmp/www/cgi-bin/hook" <<'EOF'
#!/bin/sh
head -c "$CONTENT_LENGTH" > /tmp/msg
printf 'Content-Type: text/plain\r\n\r\nok\n'
EOF
# The heartbeat monitor: a CGI script that logs the method of every request.
cat > "$tmp/www/cgi-bin/ping" <<'EOF'
#!/bin/sh
echo "$REQUEST_METHOD" >> /tmp/pings
printf 'Content-Type: text/plain\r\n\r\nok\n'
EOF
chmod 755 "$tmp/www/cgi-bin/hook" "$tmp/www/cgi-bin/ping"
# The storage machine: two rest-server instances on one folder. rs, append-only, with the server's
# login prod; rsadmin, full access, with the storage side's login admin (docs/how-to/backups.md).
docker run --rm --network none --entrypoint htpasswd "$rs_img" -B -b -n prod prod-secret > "$tmp/rs-prod.htpasswd"
docker run --rm --network none --entrypoint htpasswd "$rs_img" -B -b -n admin admin-secret > "$tmp/rs-admin.htpasswd"
cat > "$tmp/compose.yml" <<EOF
name: bktest
services:
  db:
    image: $pg
    user: "70:70"
    environment: {POSTGRES_PASSWORD: admin-secret}
    volumes: ["db:/var/lib/postgresql/data"]
    tmpfs: [/tmp, /var/run/postgresql]
    read_only: true
    cap_drop: [ALL]
    security_opt: ["no-new-privileges:true"]
    healthcheck: {test: ["CMD", "pg_isready", "-U", "postgres"], interval: 1s, retries: 60}
  backup:
    image: bktest-backup:1
    hostname: bktest-backup
    read_only: true
    init: true
    cap_drop: [ALL]
    cap_add: [CHOWN, SETUID, SETGID]
    security_opt: ["no-new-privileges:true"]
    tmpfs: [/tmp, /var/lib/postgresql/data]
    environment:
      BACKUP_STORES: "db:postgres"
      BACKUP_DB_USER: backup
      BACKUP_DB_PASSWORD: backup-secret
      BACKUP_DB_ADMIN_PASSWORD: admin-secret
      BACKUP_TIME: "00:00"
      BACKUP_KEEP_DAILY: \${BKT_KEEP_DAILY:-7}
      BACKUP_KEEP_WEEKLY: \${BKT_KEEP_WEEKLY:-4}
      BACKUP_DRILL_DAY: \${BKT_DRILL_DAY:-7}
      BACKUP_COPY_TO: \${BKT_COPY_TO:-}
      BACKUP_COPY_PASSWORD: copy-secret
      BACKUP_COPY_LOGIN: prod
      BACKUP_COPY_LOGIN_PASSWORD: prod-secret
      BACKUP_MAX_AGE: 26h
      BACKUP_NOTIFY_URL: http://hook:8080/cgi-bin/hook
      BACKUP_HEARTBEAT_URL: \${BKT_HEARTBEAT_URL:-}
      DISK_RESERVE: \${BKT_RESERVE:-2G}
    volumes: ["\${BKT_DIR:?}:/backup", "drill:/drill"]
    depends_on: {db: {condition: service_healthy}, hook: {condition: service_started}}
    healthcheck: {test: ["CMD", "backup", "health"], interval: 2s, timeout: 30s, retries: 1}
  hook:
    image: $bb
    command: ["httpd", "-f", "-p", "8080", "-h", "/www"]
    volumes: ["$tmp/www:/www:ro"]
  rs:
    image: $rs_img
    environment: {OPTIONS: "--append-only --private-repos --htpasswd-file /htpasswd"}
    volumes: ["$tmp/rs:/data", "$tmp/rs-prod.htpasswd:/htpasswd:ro"]
  rsadmin:
    image: $rs_img
    environment: {OPTIONS: "--htpasswd-file /htpasswd"}
    volumes: ["$tmp/rs:/data", "$tmp/rs-admin.htpasswd:/htpasswd:ro"]
volumes:
  db: {}
  drill: {}
EOF
export BKT_DIR="$tmp/sets"
expect_ok dc up -d --wait db rs rsadmin
dc exec -T db psql -X -q -v ON_ERROR_STOP=1 -U postgres >/dev/null <<'SQL'
CREATE TABLE items (id int PRIMARY KEY, name text);
INSERT INTO items SELECT g, 'item ' || g FROM generate_series(1, 1000) g;
CREATE SCHEMA shop;
CREATE TABLE shop.orders (id serial PRIMARY KEY, item int REFERENCES items);
INSERT INTO shop.orders (item) SELECT 1 + g % 10 FROM generate_series(1, 250) g;
CREATE TABLE "odd name" (x int);
INSERT INTO "odd name" VALUES (1), (2), (3);
CREATE TABLE secrets (v text);
INSERT INTO secrets VALUES ('a'), ('b');
ALTER TABLE secrets ENABLE ROW LEVEL SECURITY;
CREATE ROLE app_reader LOGIN PASSWORD 'reader';
GRANT SELECT ON items TO app_reader;
ALTER ROLE app_reader SET statement_timeout = '5s';
ALTER DATABASE postgres SET work_mem = '8MB';
SELECT lo_from_bytea(0, 'the large object');
SQL

step "a. the scheduler starts; Docker created BACKUP_DIR as root and it now belongs to postgres, marked as the service's"
[ ! -e "$BKT_DIR" ] || fail "$BKT_DIR exists before the start"
up_backup
health_is healthy
same "$(asroot 'stat -c "%u:%g %a" /t/sets')" "70:70 700" "the owner and mode of BACKUP_DIR"
same "$(asroot 'sed -n "s/^host //p" /t/sets/.backup-folder')" bktest-backup "the host in the mark of BACKUP_DIR"
docker image inspect -f '{{json .Config.Env}}' bktest-backup:1 > "$out"
lacks "BACKUP_DIR"
expect_ok dc logs backup
has "scheduler: daily at 00:00 UTC"
# Every process of the service but the init runs as postgres without capabilities.
procs=$(docker exec bktest-backup-1 sh -c 'for f in /proc/[0-9]*/status; do
  awk "/^Name:/ {n = \$2} /^Uid:/ {u = \$2} /^CapEff:/ {c = \$2} END {print n, u, c}" "$f"; done' | grep -E '^(backup|sleep) ' | sort -u)
printf '%s\n' "$procs" | grep -q '^backup 70 0000000000000000$' || fail "the scheduler does not run as uid 70 without capabilities: $procs"
! printf '%s\n' "$procs" | grep -qv ' 70 0000000000000000$' || fail "a process runs as another user or with capabilities: $procs"
same "$(docker inspect -f '{{.HostConfig.ReadonlyRootfs}}' bktest-backup-1)" true "read_only"
expect_fail inb 'touch /usr/local/x'
has "Read-only file system"

step "a2. the backup folder: someone else's files or another environment's folder are refused and left as they are; an empty one is taken"
mkdir -p "$tmp/foreign/sub" "$tmp/foreign/.git"
echo notes > "$tmp/foreign/notes.txt"
before=$(asroot 'cd /t/foreign && find . -exec stat -c "%u:%g %a %n" {} \; | sort')
withdir "$tmp/foreign" expect_fail bkrun backup health
has "ERROR: the backup folder (BACKUP_DIR on the host; in dev the volume backup-data) holds files the service did not make (.git notes.txt sub"
has "so the backup service does not use it and changed nothing: give it an empty or missing folder of its own, one per environment"
same "$(asroot 'cd /t/foreign && find . -exec stat -c "%u:%g %a %n" {} \; | sort')" "$before" "the foreign folder after the refusal"
mkdir "$tmp/other"
printf 'The backup service of one environment made this folder; nothing else may write here.\nhost bktest-backup-prod\n' > "$tmp/other/.backup-folder"
withdir "$tmp/other" expect_fail bkrun backup health
has "belongs to the backup service of bktest-backup-prod, not of bktest-backup"
same "$(asroot 'stat -c %u /t/other')" "$(id -u)" "the owner of the other environment's folder after the refusal"
mkdir "$tmp/empty"
chmod 755 "$tmp/empty"
withdir "$tmp/empty" expect_ok bkrun backup health
same "$(asroot 'stat -c "%u:%g %a" /t/empty; ls -A /t/empty')" "70:70 700
.backup-folder
.state" "an empty folder after the service took it"
# The sets of an earlier release, before the mark: .state and store folders of sets, all of the
# service's user. Taken and marked; one file of anyone else's next to them, and it is refused.
asroot 'mkdir -p /t/old/.state /t/old/db/20200101T030000Z && echo x > /t/old/db/20200101T030000Z/manifest   && chown -R 70:70 /t/old && chmod 700 /t/old'
withdir "$tmp/old" expect_ok bkrun backup health
same "$(asroot 'sed -n "s/^host //p" /t/old/.backup-folder; ls /t/old/db')" "bktest-backup
20200101T030000Z" "the earlier release's folder after the service took it"
asroot 'mkdir -p /t/old2/.state /t/old2/db/20200101T030000Z && echo x > /t/old2/notes.txt && chown -R 70:70 /t/old2'
withdir "$tmp/old2" expect_fail bkrun backup health
has "holds files the service did not make (.state db notes.txt"
[ -z "$(asroot 'ls /t/old2/.backup-folder 2>/dev/null')" ] || fail "the refused folder got the mark"

step "b. a backup set: layout, manifest, checksums, owner"
expect_ok bk backup
has "backup: db/"
s1=$(newest)
[ -n "$s1" ] || fail "no set after make backup"
same "$(inb "ls -1 /backup/db/$s1" | tr '\n' ' ')" "database.dump globals.sql manifest " "the files of a set"
inb "cat /backup/db/$s1/manifest" > "$out"
for line in "rows public.items 1000" "rows shop.orders 250" 'rows public."odd name" 3' "rows public.secrets 2" \
    "largeobjects 1" "role app_reader" "role backup" "setting - work_mem=8MB" "setting app_reader statement_timeout=5s"; do
  grep -qxF "$line" "$out" || { cat "$out"; fail "the manifest lacks: $line"; }
done
same "$(grep -c -e '^sha256 [0-9a-f]\{64\} database.dump$' -e '^sha256 [0-9a-f]\{64\} globals.sql$' "$out")" 2 \
  "the checksum lines of the manifest"
inb "cd /backup/db/$s1 && sed -n 's/^sha256 \([0-9a-f]*\) \(.*\)/\1  \2/p' manifest | sha256sum -c -" >/dev/null \
  || fail "the checksums of the manifest do not match the files"
inb "grep -q 'CREATE ROLE app_reader' /backup/db/$s1/globals.sql" || fail "globals.sql lacks the role app_reader"
! inb "grep -qi 'PASSWORD' /backup/db/$s1/globals.sql" || fail "globals.sql holds role passwords"
same "$(asroot "stat -c '%u %a' /t/sets/db/$s1 /t/sets/db/$s1/database.dump" | tr '\n' ' ')" \
  "70 700 70 600 " "the owner and mode of a set"

step "c. a backup killed halfway leaves no final set; the next one removes the leftover"
dc exec -T db psql -X -q -U postgres -c 'BEGIN; LOCK TABLE items IN ACCESS EXCLUSIVE MODE; SELECT pg_sleep(120);' \
  >/dev/null 2>&1 &
locker=$!
sleep 1
bk backup > "$tmp/killed" 2>&1 &
bkpid=$!
i=0
until inb 'ls -d /backup/db/.tmp-*' >/dev/null 2>&1 && [ -n "$(sql "SELECT 1 FROM pg_stat_activity WHERE wait_event_type = 'Lock' AND application_name = 'backup'")" ]; do
  i=$((i + 1)); [ "$i" -lt 60 ] || fail "the backup did not reach pg_dump"
  sleep 0.5
done
docker kill bktest-backup-1 >/dev/null
wait "$bkpid" || :
sql "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE query LIKE '%pg_sleep(120)%' AND pid <> pg_backend_pid()" >/dev/null
wait "$locker" || :
asroot 'ls -d /t/sets/db/.tmp-*' >/dev/null || fail "no unfinished .tmp- set after the kill"
same "$(asroot 'ls -1 /t/sets/db | grep -c "^[0-9]"')" 1 "final sets after the kill"
up_backup
expect_ok bk backup
has "removing the unfinished db/.tmp-"
s2=$(newest)
[ "$s2" != "$s1" ] || fail "no new set after the kill"
same "$(sets)" "$s2" "the sets after the next backup (one per day is kept)"
[ -z "$(inb 'ls -d /backup/db/.tmp-* 2>/dev/null')" ] || fail "a .tmp- set is left"

step "d. a drill passes; a damaged set or a wrong manifest fails it and turns the health unhealthy"
expect_ok bk restore-drill
has "drill: db/$s2 OK"
same "$(inb 'ls -A /drill')" "" "/drill after a drill"
expect_ok bk health
has "healthy"
inb "cp /backup/db/$s2/database.dump /backup/good.dump && printf x >> /backup/db/$s2/database.dump"
expect_fail bk restore-drill
has "ERROR: the drill of db failed: db/$s2: database.dump: the checksum does not match the manifest"
expect_fail bk health
has "unhealthy: the last drill failed: db/$s2: database.dump"
health_is unhealthy
same "$(dc exec -T hook cat /tmp/msg)" "backup on bktest-backup: drill failed: the drill of db failed: db/$s2: database.dump: the checksum does not match the manifest, so the set is damaged" \
  "the notification"
inb "mv /backup/good.dump /backup/db/$s2/database.dump && sed -i 's/^rows public.items 1000$/rows public.items 999/' /backup/db/$s2/manifest"
expect_fail bk restore-drill
has "the restored store differs from the manifest: expected rows public.items 999; restored rows public.items 1000;"
same "$(inb 'ls -A /drill')" "" "/drill after a failed drill"
inb "sed -i 's/^rows public.items 999$/rows public.items 1000/' /backup/db/$s2/manifest"
expect_ok bk restore-drill
health_is healthy

step "d2. a drill of a named set; a named set that does not exist fails"
inb "cp -a /backup/db/$s2 /backup/db/20200111T030000Z"
expect_ok bk drill --set 20200111T030000Z
has "drill: db/20200111T030000Z OK"
lacks "drill: db/$s2"
expect_fail bk restore-drill --set 20000101T000000Z
has "ERROR: the drill of db failed: no set db/20000101T000000Z to drill (the sets: 20200111T030000Z $s2)"
expect_fail bk drill --sett x
has "ERROR: drill: unknown option --sett"
inb "rm -rf /backup/db/20200111T030000Z"
expect_ok bk drill
health_is healthy
# Too little free space in /drill is an estimate: a drill by hand refuses with exit 3 (project.sh
# asks) before it writes there, is not counted as failed and notifies nothing; --risk goes on with a
# warning.
dc exec -T hook rm -f /tmp/msg
run bkrun -e DISK_RESERVE=1000000T backup drill
same "$code" 3 "the exit code of a drill refused for free space"
has "ERROR: not enough free space for the drill in /drill (the volume backup-drill): need "
has "for the set, its size, and DISK_RESERVE=1000000T), have "
has ": free some space; going on can fill the disk: the drill then fails, and what else writes to that disk can fail"
lacks "the drill of db failed"
lacks "drill: db/"
same "$(inb 'ls -A /drill')" "" "/drill after a drill refused for free space"
same "$(inb 'cut -d " " -f 1 /backup/.state/drill')" ok "the drill state after a drill refused for free space"
! dc exec -T hook test -e /tmp/msg || fail "a drill refused for free space sent a notification: $(dc exec -T hook cat /tmp/msg)"
expect_ok bkrun -e DISK_RESERVE=1000000T backup drill --risk
has "WARNING: not enough free space for the drill in /drill (the volume backup-drill): need "
has "; going on (--risk), which can fill the disk: the drill then fails, and what else writes to that disk can fail"
has "drill: db/$s2 OK"
health_is healthy

step "e. rotation keeps the newest set of the last KEEP_DAILY days and KEEP_WEEKLY weeks"
for n in 20200110T030000Z 20200109T030000Z 20200103T030000Z 20191227T030000Z; do
  inb "cp -a /backup/db/$s2 /backup/db/$n"
done
export BKT_KEEP_DAILY=2 BKT_KEEP_WEEKLY=3
up_backup
expect_ok bk backup
s3=$(newest)
has "rotation: removed db/$s2"
has "rotation: removed db/20200109T030000Z"
has "rotation: removed db/20191227T030000Z"
same "$(sets)" "20200103T030000Z 20200110T030000Z $s3" "the sets after rotation"

step "e2. too little free space: a backup by hand refuses with exit 3 before it writes anything; --risk goes on with a warning"
dc exec -T hook rm -f /tmp/msg
last=$(inb 'cat /backup/.state/last.backup')
run bkrun -e DISK_RESERVE=1000000T backup backup
same "$code" 3 "the exit code of a backup refused for free space"
has "ERROR: not enough free space for the backup in the backup folder (BACKUP_DIR on the host; in dev the volume backup-data): need "
has "for the new sets, the size of the last ones, and DISK_RESERVE=1000000T), have "
has ": free some space; going on can fill the disk: the set then fails halfway, and what else writes to that disk (the database, the app) can fail"
same "$(sets)" "20200103T030000Z 20200110T030000Z $s3" "the sets after a refused backup"
[ -z "$(inb 'ls -d /backup/db/.tmp-* 2>/dev/null')" ] || fail "a refused backup left a .tmp- set"
same "$(inb 'cat /backup/.state/last.backup')" "$last" "the last backup result after a backup refused for free space"
! dc exec -T hook test -e /tmp/msg || fail "a backup refused for free space sent a notification: $(dc exec -T hook cat /tmp/msg)"
expect_ok bkrun -e DISK_RESERVE=1000000T backup backup --risk
has "WARNING: not enough free space for the backup in the backup folder (BACKUP_DIR on the host; in dev the volume backup-data): need "
has "; going on (--risk), which can fill the disk: the set then fails halfway, and what else writes to that disk (the database, the app) can fail"
has "rotation: removed db/$s3"
s3=$(newest)
has "backup: db/$s3 OK"
same "$(sets)" "20200103T030000Z 20200110T030000Z $s3" "the sets after a backup with --risk"
expect_fail bkrun -e DISK_RESERVE=lots backup health
has "ERROR: DISK_RESERVE is 'lots', not a size like 2G or 500M"

step "f. the copy: created on first use, every set copied, never rotated or deleted from the server"
export BKT_COPY_TO=rest:http://rs:8000/prod/
up_backup
expect_ok bk backup
s4=$(newest)
has "copy: no repository at rest:http://rs:8000/prod/ yet: creating it"
has "copy: db/20200103T030000Z -> rest:http://rs:8000/prod/"
has "copy: db/20200110T030000Z -> rest:http://rs:8000/prod/"
has "copy: db/$s3 -> rest:http://rs:8000/prod/"
has "copy: db/$s4 -> rest:http://rs:8000/prod/"
lacks "prod-secret"
lacks "rotation removed"
same "$(snapshots)" 4 "snapshots in the copy"
export BKT_KEEP_DAILY=1 BKT_KEEP_WEEKLY=1
up_backup
expect_ok bk backup
s5=$(newest)
same "$(sets)" "$s5" "the local sets with KEEP 1 and 1"
same "$(snapshots)" 5 "snapshots in the copy with KEEP 1 and 1 (the storage side rotates it)"
expect_ok bk health
has "healthy: no newest set or copy is older than 26h"

step "f2. the server's login can add to the copy, but cannot forget or delete anything"
id=$(rrestic prod prod-secret rs snapshots --json | grep -o '"id":"[0-9a-f]*"' | head -n 1 | cut -d'"' -f4)
[ -n "$id" ] || fail "no snapshot id in the copy"
expect_fail rrestic prod prod-secret rs forget "$id"
has "403 Forbidden"
expect_fail rrestic prod prod-secret rs forget --group-by host,tags --keep-last 1 --prune
has "403 Forbidden"
# A refused forget can leave its lock (restic stops at the 403); locks are the one thing the
# server's login may delete.
expect_ok rrestic prod prod-secret rs unlock --remove-all
same "$(snapshots)" 5 "snapshots after the server's forget"
expect_ok rrestic prod prod-secret rs check
has "no errors were found"
# The backup service's own restic, with its own settings, is refused the same way.
expect_fail dc exec -T -u postgres -e RESTIC_REPOSITORY=rest:http://rs:8000/prod/ -e RESTIC_PASSWORD=copy-secret \
  -e RESTIC_REST_USERNAME=prod -e RESTIC_REST_PASSWORD=prod-secret -e RESTIC_CACHE_DIR=/tmp/c backup restic forget "$id"
has "403 Forbidden"
expect_ok rrestic prod prod-secret rs unlock --remove-all
same "$(snapshots)" 5 "snapshots after the service's forget"

step "g. copy-check: write, read back, delete refused; and each failure with its reason"
expect_ok bk copy-check
has "copy-check: the test set "
has "copy-check: deleting it was refused: the copy is write-only for this server"
has "copy-verify: rest:http://rs:8000/prod/ OK: the structure and 10% of the data read back without errors"
same "$(tail -n 1 "$out")" OK "copy-check"
same "$(snapshots)" 6 "snapshots after copy-check (the test set stays)"
# The storage side's full-access login can delete: a copy-check with it fails.
expect_fail bkrun -e BACKUP_COPY_TO=rest:http://rsadmin:8000/prod/ -e BACKUP_COPY_LOGIN=admin \
  -e BACKUP_COPY_LOGIN_PASSWORD=admin-secret backup copy-check
has "ERROR: the login BACKUP_COPY_LOGIN could delete the test set: the copy must be write-only for this server"
expect_fail bkrun -e BACKUP_COPY_PASSWORD=wrong backup copy-check
has "ERROR: wrong password for the repository rest:http://rs:8000/prod/"
expect_fail bkrun -e BACKUP_COPY_LOGIN_PASSWORD=wrong backup copy-check
has "ERROR: cannot open the repository rest:http://rs:8000/prod/: the rest-server refused the login BACKUP_COPY_LOGIN"
expect_fail bkrun -e BACKUP_COPY_TO=rest:http://rs:8000/other/ backup copy-check
has "the rest-server refused the login BACKUP_COPY_LOGIN"
expect_fail bkrun -e BACKUP_COPY_TO=rest:http://prod:prod-secret@rs:8000/prod/ backup copy-check
has "ERROR: BACKUP_COPY_TO holds a login: put it in BACKUP_COPY_LOGIN and BACKUP_COPY_LOGIN_PASSWORD"
expect_fail bkrun -e BACKUP_COPY_LOGIN= backup copy-check
has "ERROR: BACKUP_COPY_LOGIN or BACKUP_COPY_LOGIN_PASSWORD is empty"
expect_fail bkrun -e BACKUP_COPY_TO=sftp:backup@192.0.2.1:/srv/backups backup copy-check
has "ERROR: BACKUP_COPY_TO is 'sftp:backup@192.0.2.1:/srv/backups': the template copies to a rest-server"
expect_fail bkrun -e BACKUP_COPY_TO=/nonexistent/repo backup copy-check
has "ERROR: the repository /nonexistent/repo is missing and cannot be created: restic: create repository at /nonexistent/repo failed"
echo cert > "$tmp/cacert"
chmod 600 "$tmp/cacert"
expect_fail bkrun -e BACKUP_COPY_CACERT="$tmp/cacert" -v "$tmp/cacert:/etc/backup-copy/cacert:ro" backup copy-check
has "ERROR: the certificate file is not readable by the backup user (uid 70): sudo chown 70:70 $tmp/cacert && sudo chmod 600 $tmp/cacert"
same "$(snapshots)" 6 "snapshots after the failed copy-checks"

step "g2. copy-verify and copy-check read the copy back; a damaged pack fails them, is notified and turns the health unhealthy"
expect_ok bk copy-verify
has "copy-verify: rest:http://rs:8000/prod/ OK: the structure and 10% of the data read back without errors"
pack=$(asroot 'find /t/rs/prod/data -type f | sort | head -n 1')
asroot "cp -p $pack /t/good.pack && printf x | dd of=$pack bs=1 seek=100 conv=notrunc 2>/dev/null"
dc exec -T hook rm -f /tmp/msg
expect_fail dc exec -T -e BACKUP_COPY_READ=100% backup backup copy-verify
has "ERROR: the check of the copy at rest:http://rs:8000/prod/ failed: restic: "
expect_fail bk health
has "unhealthy: the last check of the copy failed: the check of the copy at rest:http://rs:8000/prod/ failed"
dc exec -T hook grep -q '^backup on bktest-backup: copy-verify failed: the check of the copy' /tmp/msg \
  || fail "no notification of the failed copy-verify"
# copy-check ends with the same read check: it fails on the damage too, and passes once it is gone,
# which clears the unhealthy state.
expect_fail dc exec -T -e BACKUP_COPY_READ=100% backup backup copy-check
has "ERROR: the check of the copy at rest:http://rs:8000/prod/ failed: restic: "
asroot "cp -p /t/good.pack $pack && rm /t/good.pack"
expect_fail bkrun -e BACKUP_COPY_READ=all backup health
has "ERROR: BACKUP_COPY_READ is 'all', not a percentage like 10% (or 0: the structure only)"
expect_fail bk health
expect_ok bk copy-check
has "copy-verify: rest:http://rs:8000/prod/ OK"
health_is healthy

step "h. restore --check and --plan say what a restore replaces; a refused restore replaces and notifies nothing"
expect_ok bk restore --check
same "$(cat "$out")" "restore: would restore db from $s5 (local)
restore: db: replaces the database postgres on db with the local set $s5 of $(printf '%s' "$s5" | sed 's/^\(....\)\(..\)\(..\)T\(..\)\(..\)\(..\)Z$/\1-\2-\3 \4:\5:\6/') UTC; what was written after that set is lost
restore: db: first a safety set before-restore-<now> of it as it is now" "restore --check"
expect_ok bk restore --check --from copy --set "$s5" --no-safety
has "restore: would restore db from $s5 (copy)"
has "restore: db: no safety set (NO_SAFETY=1)"
expect_ok bk restore --plan
same "$(cat "$out")" "$(printf 'db\tpostgres\tdb\t%s\t%s\tlocal\tsafety' "$s5" "$(printf '%s' "$s5" | sed 's/^\(....\)\(..\)\(..\)T\(..\)\(..\)\(..\)Z$/\1-\2-\3 \4:\5:\6/')")" "restore --plan"
# Both in one call, from one reading of the sets (make restore in a terminal): the plan line of a
# store, then its check lines.
expect_ok bk restore --check --plan
same "$(cat "$out")" "$(printf 'db\tpostgres\tdb\t%s\t%s\tlocal\tsafety' "$s5" "$(printf '%s' "$s5" | sed 's/^\(....\)\(..\)\(..\)T\(..\)\(..\)\(..\)Z$/\1-\2-\3 \4:\5:\6/')")
restore: would restore db from $s5 (local)
restore: db: replaces the database postgres on db with the local set $s5 of $(printf '%s' "$s5" | sed 's/^\(....\)\(..\)\(..\)T\(..\)\(..\)\(..\)Z$/\1-\2-\3 \4:\5:\6/') UTC; what was written after that set is lost
restore: db: first a safety set before-restore-<now> of it as it is now" "restore --check --plan"
# A mistyped BACKUP_COPY_TO: a restore only opens the repository, it never creates one.
expect_fail dc exec -T -e BACKUP_COPY_TO=rest:http://rs:8000/prod/typo/ backup backup restore --check --from copy
has "ERROR: no repository at rest:http://rs:8000/prod/typo/ (BACKUP_COPY_TO): nothing to restore from"
[ -z "$(asroot 'ls -d /t/rs/prod/typo 2>/dev/null')" ] || fail "restore --check --from copy created the repository prod/typo"
run bkrun -e DISK_RESERVE=1000000T backup restore --check --plan
same "$code" 3 "the exit code of restore --check refused for free space"
has "ERROR: not enough free space for the restore in the backup folder"
has ": free some space; going on can fill the disk: the safety set or the set from the copy then fails, and the restore stops before it replaces anything; what else writes to that disk can fail"
lacks "restore: would restore"
expect_ok dc exec -T -e DISK_RESERVE=1000000T backup backup restore --check --plan --risk
case "$(sed -n 1p "$out")" in "WARNING: not enough free space for the restore in the backup folder"*) ;;
  *) cat "$out"; fail "restore --check --plan --risk does not start with the warning" ;; esac
same "$(sed -n 2p "$out")" "$(printf 'db\tpostgres\tdb\t%s\t%s\tlocal\tsafety' "$s5" "$(printf '%s' "$s5" | sed 's/^\(....\)\(..\)\(..\)T\(..\)\(..\)\(..\)Z$/\1-\2-\3 \4:\5:\6/')")" \
  "the plan line of restore --check --plan --risk"
has "restore: would restore db from $s5 (local)"
dc exec -T hook rm -f /tmp/msg
expect_fail bk restore --check --set 20200101T000000Z
has "ERROR: no local set db/20200101T000000Z (the sets: $s5)"
expect_fail bk restore --check --set before-restore
has "ERROR: no local safety set before-restore-… of db (the sets: $s5)"
expect_fail bk restore --from copy
has "ERROR: restore replaces the working database postgres on db: run again with CONFIRM=yes"
expect_fail bk restore --set yesterday
has "ERROR: --set is 'yesterday', not latest, before-restore or a set name like 20261019T030000Z"
expect_fail bk restore --sett "$s5"
has "ERROR: restore: unknown option --sett"
! dc exec -T hook test -e /tmp/msg || fail "a refused restore sent a notification: $(dc exec -T hook cat /tmp/msg)"
same "$(sql 'SELECT count(*) FROM items')" 1000 "items after a refused restore"
same "$(safety)" "" "safety sets after refused restores"

step "i. restore --from copy into a fresh, empty database equals the manifest"
expect_ok dc rm -sf db
expect_ok docker volume rm bktest_db
expect_ok dc up -d --wait db
same "$(sql "SELECT count(*) FROM pg_class WHERE relname = 'items'")" 0 "items in the fresh database"
# A session left open on the database: the restore closes it.
dc exec -T db psql -X -q -U postgres -c 'SELECT pg_sleep(120)' >/dev/null 2>&1 &
sleeper=$!
sleep 1
expect_ok dc exec -T -e CONFIRM=yes backup backup restore --from copy --set latest --no-safety
has "copy: fetched db/$s5 from rest:http://rs:8000/prod/"
has "restore: no safety set (NO_SAFETY=1)"
has "restore: db OK: equal to the manifest of $s5"
wait "$sleeper" || :
same "$(sql 'SELECT count(*) FROM items') $(sql 'SELECT count(*) FROM shop.orders') $(sql 'SELECT count(*) FROM secrets')" \
  "1000 250 2" "the restored row counts"
same "$(sql "SELECT convert_from(lo_get(oid), 'UTF8') FROM pg_largeobject_metadata")" "the large object" "the restored large object"
same "$(sql "SELECT array_to_string(setconfig, ',') FROM pg_db_role_setting WHERE setdatabase = (SELECT oid FROM pg_database WHERE datname = 'postgres')")" \
  "work_mem=8MB" "the restored database setting"
same "$(sql "SELECT rolname FROM pg_roles WHERE rolname IN ('app_reader', 'backup') ORDER BY 1" | tr '\n' ' ')" "app_reader backup " "the restored roles"
same "$(sql "SELECT datallowconn FROM pg_database WHERE datname = 'postgres'")" t "connections to postgres after the restore"
[ -z "$(inb 'ls -d /backup/db/.fetch-* 2>/dev/null')" ] || fail "the fetched set is left"
same "$(safety)" "" "safety sets after a restore with --no-safety"
# The restored backup role has no password (globals.sql has none); the next backup sets it again.
expect_ok bk backup
s6=$(newest)
expect_ok dc exec -T -e CONFIRM=yes backup backup restore --from copy --set "$s6" --no-safety
has "copy: fetched db/$s6 from rest:http://rs:8000/prod/"
expect_fail dc exec -T -e CONFIRM=yes backup backup restore --from copy --set 20200101T000000Z
has "ERROR: no copy set db/20200101T000000Z (the sets: "

step "i2. the safety set: made before a restore, ignored by latest and the drill, restored by name, one only, copied, kept by rotation"
sql "INSERT INTO items VALUES (7000, 'written after the set')" >/dev/null
# (1) the restore makes before-restore-<time> of the database as it is, then replaces it.
expect_ok dc exec -T -e CONFIRM=yes backup backup restore --set "$s6"
b1=$(safety)
printf '%s\n' "$b1" | grep -Eqx 'before-restore-[0-9]{8}T[0-9]{6}Z' || { cat "$out"; fail "no single safety set after a restore: '$b1'"; }
[ "$(grep -n "^backup: db/$b1 OK" "$out" | cut -d: -f1)" -lt "$(grep -n "^restore: db from the local set $s6" "$out" | cut -d: -f1)" ] \
  || { cat "$out"; fail "the safety set was not made before the restore"; }
has "restore: db OK: equal to the manifest of $s6"
inb "grep -qx 'rows public.items 1001' /backup/db/$b1/manifest" || fail "the safety set does not hold the state before the restore"
same "$(sql 'SELECT count(*) FROM items')" 1000 "items after the restore"
# (4) it is copied off the server at once, tagged so the storage side can rotate it.
has "copy: db/$b1 -> rest:http://rs:8000/prod/"
rrestic prod prod-secret rs snapshots --json --tag db,before-restore > "$out"
has "\"paths\":[\"/backup/db/$b1\"]"
# (2) latest and the drill take the newest normal set, not the safety set.
expect_ok bk restore --check
has "restore: would restore db from $s6 (local)"
expect_ok bk drill
has "drill: db/$s6 OK"
lacks "before-restore"
# (3) restored by name: the state before the restore comes back; its new safety set replaces it.
expect_ok bk restore --check --set before-restore
has "restore: would restore db from $b1 (local)"
expect_ok dc exec -T -e CONFIRM=yes backup backup restore --set before-restore
has "restore: db OK: equal to the manifest of $b1"
has "restore: removed the older safety set db/$b1"
same "$(sql "SELECT name FROM items WHERE id = 7000")" "written after the set" "the row after restoring the safety set"
b2=$(safety)
{ [ "$b2" != "$b1" ] && printf '%s\n' "$b2" | grep -Eqx 'before-restore-[0-9]{8}T[0-9]{6}Z'; } || fail "not one new safety set: '$b2' (was $b1)"
expect_ok bk restore --check --set "$b2" --no-safety
has "restore: would restore db from $b2 (local)"
# (5) --no-safety restores without one; the safety set stays as it was.
expect_ok dc exec -T -e CONFIRM=yes backup backup restore --set "$s6" --no-safety
has "restore: no safety set (NO_SAFETY=1)"
lacks "backup: db/before-restore-"
same "$(safety)" "$b2" "the safety sets after a restore with --no-safety"
# Too little free space goes on with --risk, with a warning.
expect_ok dc exec -T -e CONFIRM=yes -e DISK_RESERVE=1000000T backup backup restore --set "$s6" --no-safety --risk
has "WARNING: not enough free space for the restore in the backup folder"
has "; going on (--risk), which can fill the disk: the safety set or the set from the copy then fails, and the restore stops before it replaces anything; what else writes to that disk can fail"
has "restore: db OK: equal to the manifest of $s6"
# A safety set that cannot be made stops the restore before anything is replaced.
sql "INSERT INTO items VALUES (7001, 'kept')" >/dev/null
expect_fail dc exec -T -e CONFIRM=yes -e BACKUP_DB_USER=postgres backup backup restore --set "$s6"
has "ERROR: the safety set of db failed, so nothing was replaced: db: BACKUP_DB_USER must not be BACKUP_DB_ADMIN_USER; fix it, or restore without one: NO_SAFETY=1"
run dc exec -T -e CONFIRM=yes -e DISK_RESERVE=1000000T backup backup restore --set "$s6"
same "$code" 3 "the exit code of a restore refused for free space"
has "ERROR: not enough free space for the restore in the backup folder"
lacks "backup: db/before-restore-"
same "$(sql "SELECT count(*) FROM items WHERE id = 7001")" 1 "the row after the refused restores"
same "$(safety)" "$b2" "the safety sets after the refused restores"
# (6) rotation neither counts nor removes it; the health counts normal sets only.
expect_ok bkrun -e BACKUP_KEEP_DAILY=1 -e BACKUP_KEEP_WEEKLY=1 backup backup
s7=$(newest)
same "$(sets) | $(safety)" "$s7 | $b2" "the sets after rotation"
# list shows both kinds; status shows the sets and the last results.
expect_ok bk list
grep -Eq '^store +set +made \(UTC\) +size +kind +where$' "$out" || { cat "$out"; fail "list has no header"; }
grep -Eq "^db +$s7 +[0-9-]+ [0-9:]+ +[0-9.]+[KMG] +normal +local, copied$" "$out" || { cat "$out"; fail "list lacks the normal set $s7"; }
grep -Eq "^db +$b2 +[0-9-]+ [0-9:]+ +[0-9.]+[KMG] +before-restore +local, copied$" "$out" || { cat "$out"; fail "list lacks the safety set $b2"; }
expect_ok bk list --from copy --store db
grep -Eq "^db +$b2 .* before-restore +copy$" "$out" || { cat "$out"; fail "list --from copy lacks the safety set $b2"; }
expect_ok bk status
has "healthy: no newest set or copy is older than 26h"
has "db: 1 sets; the newest: $s7 ("
has "; safety set: $b2"
has "last backup: ok at "
has "last restore: failed at "
has "last drill: ok at "
has "last copy-verify: ok at "
has "free space in the backup folder (BACKUP_DIR on the host; in dev the volume backup-data): "

step "i3. the storage side rotates the copy with a login of its own; --keep-within keeps the real sets against garbage"
# Garbage the server's login could add: an empty set dated after every real one, an old safety set.
expect_ok rrestic prod prod-secret rs backup --host bktest-backup --tag db --time "$(date -u -d '+1 hour' '+%Y-%m-%d %H:%M:%S')" /etc/hostname
expect_ok rrestic prod prod-secret rs backup --host bktest-backup --tag db,before-restore --time "2020-01-01 00:00:00" /etc/hostname
# The commands of docs/how-to/backups.md, through the full-access instance.
expect_ok rrestic admin admin-secret rsadmin forget --group-by host,tags --keep-daily 1 --keep-weekly 1   --keep-within 7d --keep-tag before-restore
expect_ok rrestic admin admin-secret rsadmin forget --tag before-restore --group-by host,tags --keep-last 1 --keep-within 7d
expect_ok rrestic admin admin-secret rsadmin prune
rrestic prod prod-secret rs snapshots --json > "$out"
has "\"paths\":[\"/backup/db/$s7\"]"
has "\"paths\":[\"/backup/db/$b2\"]"
lacks "/backup/db/20200103T030000Z"
lacks "\"time\":\"2020-01-01T00:00:00"
expect_ok rrestic prod prod-secret rs check
expect_ok bk restore --check --from copy --set "$b2"
has "restore: would restore db from $b2 (copy)"

step "i4. a restore from the copy with a safety set, from the rest-server and from a local-folder copy"
# The safety set is made after the set is fetched into the store's folder: it must not take the
# fetched set for a leftover.
expect_ok dc exec -T -e CONFIRM=yes backup backup restore --from copy --set "$s7"
has "copy: fetched db/$s7 from rest:http://rs:8000/prod/"
has "backup: db/before-restore-"
has "restore: db OK: equal to the manifest of $s7"
lacks "removing the unfinished"
[ "$(safety)" != "$b2" ] || fail "no new safety set after a restore from the copy"
# A local folder as the copy, as the template's project test uses.
expect_ok bkrun -e BACKUP_COPY_TO=/backup/.copy backup backup
has "copy: no repository at /backup/.copy yet: creating it"
s8=$(newest)
expect_ok bkrun -e BACKUP_COPY_TO=/backup/.copy -e CONFIRM=yes backup restore --from copy --set latest
has "copy: fetched db/$s8 from /backup/.copy"
has "restore: db OK: equal to the manifest of $s8"
lacks "removing the unfinished"
[ -z "$(inb 'ls -d /backup/db/.fetch-* 2>/dev/null')" ] || fail "the fetched set is left"

step "i5. a snapshot the server's login adds with the path of a real set does not shadow it: the oldest is fetched"
real=$(rrestic prod prod-secret rs snapshots --json --path "/backup/db/$s7" | grep -o '"short_id":"[0-9a-f]*"' | cut -d'"' -f4)
[ -n "$real" ] || fail "no snapshot of db/$s7 in the copy"
# Another valid set (with a marker row) planted under the name of $s7, as a broken-into server can.
sql "INSERT INTO items VALUES (8000, 'planted')" >/dev/null
expect_ok bk backup
sp=$(newest)
sql "DELETE FROM items WHERE id = 8000" >/dev/null
expect_ok docker run --rm --network bktest_default -e RESTIC_PASSWORD=copy-secret -e RESTIC_CACHE_DIR=/tmp/c \
  -e RESTIC_REST_USERNAME=prod -e RESTIC_REST_PASSWORD=prod-secret -v "$tmp/sets/db/$sp:/backup/db/$s7:ro" "$restic_img" \
  -r rest:http://rs:8000/prod/ backup --host bktest-backup --tag db "/backup/db/$s7"
expect_ok dc exec -T -e CONFIRM=yes backup backup restore --from copy --set "$s7" --no-safety
same "$(sql 'SELECT count(*) FROM items WHERE id = 8000')" 0 "the planted row after a restore of db/$s7 from the copy"
has "WARNING: the copy holds 2 snapshots of db/$s7 ($real "
has "the oldest, $real, is fetched"
has "copy: fetched db/$s7 from rest:http://rs:8000/prod/ (snapshot $real)"
has "restore: db OK: equal to the manifest of $s7"

step "j. health: the newest set or copy too old, the grace before the first set, the scheduler"
old=$(( $(date +%s) - 30 * 3600 ))
inb "cp /backup/.state/set.db /backup/.state/set.db.good && echo $old > /backup/.state/set.db"
expect_fail bk health
has "unhealthy: the newest set of db was made 30h0m ago (BACKUP_MAX_AGE=26h)"
health_is unhealthy
expect_fail bk status
has "unhealthy: the newest set of db was made 30h0m ago"
inb "mv /backup/.state/set.db.good /backup/.state/set.db && echo $old > /backup/.state/copy.db"
expect_fail bk health
has "unhealthy: the newest copy of db was made 30h0m ago"
inb "date +%s > /backup/.state/copy.db"
health_is healthy
export BKT_DIR="$tmp/sets2" BKT_COPY_TO=
up_backup
expect_ok bk health
has "healthy"
inb "echo $old > /backup/.state/started"
expect_fail bk health
has "unhealthy: there is no set of db yet, and the service started 30h0m ago"
# A missed day: the scheduler makes it up at once; a daily run killed halfway is made up at the
# next start.
inb 'echo 20000101 > /backup/.state/last-run'
dc exec -T db psql -X -q -U postgres -c 'BEGIN; LOCK TABLE items IN ACCESS EXCLUSIVE MODE; SELECT pg_sleep(120);' \
  >/dev/null 2>&1 &
locker=$!
sleep 1
expect_ok dc restart backup
i=0
until [ -n "$(sql "SELECT 1 FROM pg_stat_activity WHERE wait_event_type = 'Lock' AND application_name = 'backup'")" ]; do
  i=$((i + 1)); [ "$i" -lt 60 ] || { dc logs backup; fail "the daily run did not reach pg_dump"; }
  sleep 0.5
done
docker kill bktest-backup-1 >/dev/null
sql "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE query LIKE '%pg_sleep(120)%' AND pid <> pg_backend_pid()" >/dev/null
wait "$locker" || :
same "$(asroot 'cat /t/sets2/.state/last-run')" 20000101 "last-run after a killed daily run"
expect_ok dc up -d backup
i=0
until [ -n "$(newest)" ]; do i=$((i + 1)); [ "$i" -lt 60 ] || { dc logs backup; fail "the scheduler made no set"; }; sleep 1; done
health_is healthy
expect_ok dc logs backup
has "the daily run"

step "k. backup-test (dev): a set, a drill, and the set is gone"
before=$(sets)
expect_ok bkrun backup backup-test --store db
has "drill: db/"
same "$(tail -n 1 "$out")" OK "backup-test"
same "$(sets)" "$before" "the sets after backup-test"

step "l. two stores: --check and restore take the newest set both have; a missing set replaces nothing; --store takes one"
sql "CREATE DATABASE shop2" >/dev/null
dc exec -T db psql -X -q -U postgres -d shop2 -c 'CREATE TABLE t (x int); INSERT INTO t VALUES (1), (2)' >/dev/null
confirm=
two() { # the backup command with a second store db2: the database shop2 on the same server
  bkrun -e BACKUP_STORES="db:postgres db2:postgres" -e BACKUP_DB2_HOST=db -e BACKUP_DB2_DATABASE=shop2 \
    -e BACKUP_DB2_USER=backup -e BACKUP_DB2_PASSWORD=backup-secret -e BACKUP_DB2_ADMIN_PASSWORD=admin-secret \
    -e BACKUP_KEEP_DAILY=7 -e CONFIRM="$confirm" backup "$@"
}
expect_ok two backup
x=$(newest)
has "backup: db2/$x OK"
# Older sets: 20200105 of both stores, 20200106 of db only; then db2 loses its newest set.
inb "cp -a /backup/db/$x /backup/db/20200105T030000Z && cp -a /backup/db2/$x /backup/db2/20200105T030000Z \
  && cp -a /backup/db/$x /backup/db/20200106T030000Z && rm -rf /backup/db2/$x"
expect_ok two restore --check
same "$(grep '^restore: would' "$out" | tr '\n' ';')" "restore: would restore db from 20200105T030000Z (local);restore: would restore db2 from 20200105T030000Z (local);" \
  "restore --check of two stores"
has "restore: db2: replaces the database shop2 on db with the local set 20200105T030000Z"
expect_ok two restore --check --store db
same "$(grep '^restore: would' "$out")" "restore: would restore db from $x (local)" "restore --check --store db"
expect_ok two backup --store db2
has "backup: db2/"
lacks "backup: db/"
expect_ok two drill --store db2
has "drill: db2/"
lacks "drill: db/"
expect_fail two backup --store nope
has "ERROR: --store is 'nope', not a store of BACKUP_STORES (db db2)"
inb "rm -rf /backup/db2/$(inb 'ls -1 /backup/db2' | grep -E '^[0-9]{8}T[0-9]{6}Z$' | sort | tail -n 1)"
n=$(sql 'SELECT count(*) FROM items')
sql "INSERT INTO items VALUES (5000, 'marker')" >/dev/null
confirm=yes
expect_fail two restore --set "$x"
has "ERROR: no local set db2/$x (the sets: 20200105T030000Z)"
same "$(sql 'SELECT count(*) FROM items')" $((n + 1)) "items after a restore with a missing set (nothing replaced)"
expect_ok two restore
has "backup: db/before-restore-"
has "backup: db2/before-restore-"
has "restore: db OK: equal to the manifest of 20200105T030000Z"
has "restore: db2 OK: equal to the manifest of 20200105T030000Z"
same "$(sql 'SELECT count(*) FROM items')" "$n" "items after the restore of two stores"
inb "mv /backup/db2/20200105T030000Z /backup/db2/20200104T030000Z"
expect_fail two restore --check
has "ERROR: the stores have no common newest set (a store's backup failed): name one with SET="
confirm=

step "m. the backup role is never a superuser or an owner; the notification needs curl or wget"
expect_fail bkrun -e BACKUP_DB_USER=postgres backup backup
has "ERROR: db: BACKUP_DB_USER must not be BACKUP_DB_ADMIN_USER"
sql "CREATE ROLE su_test SUPERUSER LOGIN" >/dev/null
expect_fail bkrun -e BACKUP_DB_USER=su_test backup backup
has "ERROR: db: BACKUP_DB_USER su_test is a superuser: the backup needs its own read-only role"
same "$(sql "SELECT rolpassword IS NULL FROM pg_authid WHERE rolname = 'su_test'")" t "the superuser's password after the refusal"
sql "DROP ROLE su_test" >/dev/null
# Nor a role that owns a table or a database (the application's role); refused before any change.
sql "CREATE ROLE own_test LOGIN" >/dev/null
sql "CREATE TABLE own_t (x int)" >/dev/null
sql "ALTER TABLE own_t OWNER TO own_test" >/dev/null
for what in table database; do
  expect_fail bkrun -e BACKUP_DB_USER=own_test backup backup
  has "ERROR: db: BACKUP_DB_USER own_test owns database objects: the backup needs its own read-only role"
  same "$(sql "SELECT rolpassword IS NULL FROM pg_authid WHERE rolname = 'own_test'") $(sql "SELECT pg_has_role('own_test', 'pg_read_all_data', 'MEMBER')")" \
    "t f" "the owner role's password and rights after the refusal ($what)"
  [ "$what" = database ] || { sql "DROP TABLE own_t" >/dev/null; sql "CREATE DATABASE own_db OWNER own_test" >/dev/null; }
done
sql "DROP DATABASE own_db" >/dev/null
sql "DROP ROLE own_test" >/dev/null
# Without /usr/bin on PATH the image has no wget (busybox's is /usr/bin/wget) and no curl.
expect_fail bkrun -u 70:70 -e PATH=/bin --entrypoint /usr/local/lib/backup/backup.sh backup health
has "ERROR: BACKUP_NOTIFY_URL is set, but the image has neither curl nor wget: add one to docker/backup/Dockerfile"
expect_fail bkrun -u 70:70 -e PATH=/bin -e BACKUP_NOTIFY_URL= -e BACKUP_HEARTBEAT_URL=http://hook:8080/cgi-bin/ping \
  --entrypoint /usr/local/lib/backup/backup.sh backup health
has "ERROR: BACKUP_HEARTBEAT_URL is set, but the image has neither curl nor wget: add one to docker/backup/Dockerfile"

step "n. the heartbeat: one GET after a good daily run, none after a failure; a failed ping only warns"
# daily_run: a new container's scheduler makes up the missed day at once; waits until the run ends.
daily_run() {
  inb 'echo 20000101 > /backup/.state/last-run'
  dc exec -T hook rm -f /tmp/pings /tmp/msg
  expect_ok dc up -d --no-deps --force-recreate --wait backup
  i=0
  until [ "$(inb 'cat /backup/.state/last-run')" = "$(date -u +%Y%m%d)" ]; do
    i=$((i + 1)); [ "$i" -lt 120 ] || { dc logs backup; fail "the daily run did not end"; }
    sleep 0.5
  done
  expect_ok dc logs backup
}
pings() { dc exec -T hook sh -c 'cat /tmp/pings 2>/dev/null' | tr '\n' ' '; }
today=$(date -u +%u)
export BKT_HEARTBEAT_URL=http://hook:8080/cgi-bin/ping BKT_DRILL_DAY="$today"
daily_run
has "drill: db/"
has "heartbeat: sent"
same "$(pings)" "GET " "the requests to the monitor after a good daily run with a drill"
# A failed step (here the copy) sends no ping; the failure is notified as before. The copy that
# fails does not stop the local rotation (here of an old set), which runs before the failure is
# reported.
inb "cp -a /backup/db/$(newest) /backup/db/20200101T030000Z"
export BKT_COPY_TO=/nonexistent/repo BKT_DRILL_DAY=$((today % 7 + 1))
daily_run
has "ERROR: the repository /nonexistent/repo is missing and cannot be created"
has "rotation: removed db/20200101T030000Z"
has "ERROR: the copy failed: the repository /nonexistent/repo is missing and cannot be created"
! inb 'test -e /backup/db/20200101T030000Z' || fail "the rotation did not run after a failed copy"
same "$(pings)" "" "the requests to the monitor after a daily run with a failure"
dc exec -T hook grep -q '^backup on bktest-backup: backup failed: ' /tmp/msg || fail "no notification of the failed daily run"
# By hand, a backup whose copy fails ends with exit 4: the local set is made, the copy is not.
run bkrun backup backup
same "$code" 4 "the exit code of a backup whose copy failed"
has "ERROR: the copy failed: the repository /nonexistent/repo is missing and cannot be created"
has "backup: db/$(newest) OK"
# The scheduled jobs have no one to ask: too little free space fails them as before (exit 1, the
# result kept, notified), without the way out of --risk.
export BKT_COPY_TO='' BKT_RESERVE=1000000T
daily_run
has "ERROR: not enough free space for the backup in the backup folder (BACKUP_DIR on the host; in dev the volume backup-data): need "
has "for the new sets, the size of the last ones, and DISK_RESERVE=1000000T), have "
lacks "going on"
same "$(pings)" "" "the requests to the monitor after a daily run refused for free space"
dc exec -T hook grep -q '^backup on bktest-backup: backup failed: not enough free space for the backup in the backup folder' /tmp/msg \
  || fail "no notification of the daily run refused for free space: $(dc exec -T hook cat /tmp/msg)"
dc exec -T hook grep -q ': free some space$' /tmp/msg || fail "the notification lacks ': free some space': $(dc exec -T hook cat /tmp/msg)"
inb 'grep -q "^failed .* not enough free space for the backup" /backup/.state/last.backup' || fail "the daily run refused for free space was not kept as failed"
unset BKT_RESERVE
# A monitor that refuses the ping: a warning only; the run ends (last-run) and notifies nothing.
export BKT_COPY_TO='' BKT_HEARTBEAT_URL=http://hook:8080/cgi-bin/missing
daily_run
has "WARNING: the heartbeat to BACKUP_HEARTBEAT_URL failed"
! dc exec -T hook test -e /tmp/msg || fail "a failed heartbeat sent a notification: $(dc exec -T hook cat /tmp/msg)"

step "o. set -e does not apply inside a job: a command that fails there stops the job all the same"
# A module whose check makes the store's folder read-only, so the rename of the finished set fails.
cat > "$tmp/fail.sh" <<'EOF'
fail_backup() { echo data > "$2/data" && echo "rows t 1" > "$2/facts"; }
fail_check() { chmod a-w "${2%/*}"; }
EOF
expect_fail bkrun -v "$tmp/fail.sh:/usr/local/lib/backup/fail.sh:ro" -e BACKUP_STORES=fail:fail -e BACKUP_COPY_TO= \
  -e BACKUP_NOTIFY_URL= backup backup
same "$code" 1 "the exit code of a backup whose set failed"
has "ERROR: the backup of fail failed: cannot rename /backup/fail/.tmp-"
! grep -q "^backup: fail/.* OK" "$out" || { cat "$out"; fail "the backup reported a set it did not finish"; }
! inb 'test -e /backup/.state/set.fail' || fail "the backup recorded a set it did not finish"
inb 'chmod u+w /backup/fail && rm -rf /backup/fail'

echo "backup tests: OK"
