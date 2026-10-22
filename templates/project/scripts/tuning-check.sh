#!/bin/sh
# project template 1.0.0 — a starting point (standard OPS-02): one check per row of
# docs/how-to/tuning.md, against what the running services of this clone report. Keep the checks
# of the limits (one line per service with limits); add a line per parameter the project tunes.
#
# Usage:   sh scripts/tuning-check.sh: make tuning-check runs it in a stage or prod clone; make
#          stage, make prod and make restart end with it.
# Reads:   .env (PROJECT_ENV and the variables the checks name); IMAGE_TAG from make, else the
#          tree of HEAD; the running containers of docker-compose.<env>.yml.
# Output:  one line per parameter on stdout: "tuning-check: ok <parameter>" or
#          "tuning-check: FAIL <parameter>: <actual>, expected <expected>".
# Exit:    0 when every check passes; 1 on any FAIL, or outside a stage or prod clone.
# Shell:   POSIX sh; needs docker and the POSIX tools. There is no die: every check runs, also
#          after one fails, and the status comes at the end. The check lines at the bottom are the
#          project's own: plain lines, one per parameter, with short helper names (limits,
#          pg_size, same, ok, fail) that the standard's templates/README.md and the project's own
#          lines use.
set -eu
cd "$(dirname "$0")/.."

# ---- values ----------------------------------------------------------------

# A value of .env as Compose reads it: the last line of the variable; a value in quotes without
# them and without what follows them; any other value without a comment after a blank and without
# the blanks around it. The same function is in scripts/project.sh.
envvar() {
  [ ! -f .env ] || sed -n "s/^$1=//p" .env | tail -n 1 | tr -d '\r' | sed \
    -e "s/^\"\([^\"]*\)\".*/\1/;t" -e "s/^'\([^']*\)'.*/\1/;t" \
    -e 's/[[:space:]]#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}
# A size in bytes, with Docker's units (512M, 1g, 1.5G, 268435456: b, k, m, g, t, 1024 apart);
# ? when it is not a size.
bytes() {
  printf '%s\n' "$1" | awk '{
    if (!match($0, /^[0-9]+(\.[0-9]+)?/)) { print "?"; exit }
    n = substr($0, 1, RLENGTH); u = tolower(substr($0, RLENGTH + 1)); sub(/^ /, "", u); sub(/i?b$/, "", u)
    m = u == "" ? 1 : u == "k" ? 1024 : u == "m" ? 1048576 : u == "g" ? 1073741824 : u == "t" ? 1099511627776 : 0
    if (m == 0) print "?"; else printf "%.0f\n", n * m }'
}
# CPUs in Docker's NanoCpus (1.5 -> 1500000000); ? when it is not a number.
nanocpus() {
  printf '%s\n' "$1" | awk '/^[0-9]+(\.[0-9]+)?$/ { printf "%.0f\n", $0 * 1e9; next } { print "?" }'
}

# ---- report ----------------------------------------------------------------

ok() { echo "tuning-check: ok $1"; }  # ok <parameter>
fail() { echo "tuning-check: FAIL $1: $2, expected $3"; status=1; }  # fail <parameter> <actual> <expected>; sets status=1
same() { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1" "$2" "$4"; fi; }  # same <parameter> <actual> <expected> <shown>

# ---- checks ----------------------------------------------------------------

running() { docker compose -f "docker-compose.$e.yml" ps -q "$1" 2>/dev/null | head -n 1; }  # running <service>: its container id, or nothing

limits() { # limits <service> <CPUs variable> <memory variable>: the container's limits against .env
  cpus=$(envvar "$2") mem=$(envvar "$3")
  id=$(running "$1")
  [ -n "$id" ] || { fail "$1" "not running" "a running container with $2=$cpus, $3=$mem"; return 0; }
  got=$(docker inspect -f '{{.HostConfig.NanoCpus}} {{.HostConfig.Memory}} {{.HostConfig.MemorySwap}}' "$id")
  same "$1 cpus" "$(echo "$got" | cut -d' ' -f1)" "$(nanocpus "$cpus")" "$(nanocpus "$cpus") ($2=$cpus)"
  same "$1 memory" "$(echo "$got" | cut -d' ' -f2)" "$(bytes "$mem")" "$(bytes "$mem") ($3=$mem)"
  # memswap_limit equal to the memory limit: no swap beyond it.
  same "$1 memswap" "$(echo "$got" | cut -d' ' -f3)" "$(bytes "$mem")" "$(bytes "$mem") ($3=$mem, no swap)"
}

pg_size() { # pg_size <service> <parameter> <variable>: a size setting of a running PostgreSQL against .env
  want=$(envvar "$3")
  case "$want" in
    ''|*[!0-9A-Za-z.\ ]*) fail "$1 $2" "not checked" "a size in $3 (it is '$want')"; return 0 ;;
    *[A-Za-z]*) ;;
    # Without a unit, PostgreSQL reads the number in the parameter's own unit (8kB blocks for
    # shared_buffers), but pg_size_bytes reads it as bytes: a correct value would fail.
    *) fail "$1 $2" "not checked" "a size with a unit in $3, such as 256MB (it is '$want')"; return 0 ;;
  esac
  id=$(running "$1")
  [ -n "$id" ] || { fail "$1 $2" "not running" "$want ($3)"; return 0; }
  # PostgreSQL converts both to bytes itself: 256MB and 262144kB are equal.
  if ! got=$(docker exec "$id" psql -X -A -t -F ' ' -U postgres -c \
      "SELECT current_setting('$2'), pg_size_bytes(current_setting('$2')), pg_size_bytes('$want')" 2>&1); then
    fail "$1 $2" "no answer ($(echo "$got" | head -n 1))" "$want ($3)"; return 0
  fi
  shown=$(echo "$got" | cut -d' ' -f1)
  if [ "$(echo "$got" | cut -d' ' -f2)" = "$(echo "$got" | cut -d' ' -f3)" ]; then ok "$1 $2"
  else fail "$1 $2" "$shown" "$want ($3)"; fi
}

# ---- the checks of this project --------------------------------------------

# Globals: e (the environment, read by running), status (0; fail sets it to 1), IMAGE_TAG
# (exported, for docker compose).
e=$(envvar PROJECT_ENV)
case "$e" in
  stage|prod) ;;
  *) echo "tuning-check: runs only in a stage or prod clone (this one is PROJECT_ENV=$e)"; exit 1 ;;
esac
IMAGE_TAG=${IMAGE_TAG:-$(git rev-parse 'HEAD^{tree}')}
export IMAGE_TAG
status=0

# The limits of every service (docker-compose.<env>.yml, .env).
limits app APP_CPUS APP_MEM
limits db DB_CPUS DB_MEM
limits backup BACKUP_CPUS BACKUP_MEM
limits status STATUS_CPUS STATUS_MEM
limits status-proxy STATUS_PROXY_CPUS STATUS_PROXY_MEM
# PostgreSQL: the numbers the command: of db passes with -c.
pg_size db shared_buffers DB_SHARED_BUFFERS
pg_size db effective_cache_size DB_EFFECTIVE_CACHE_SIZE
# The project's own parameters: one line each, as in docs/how-to/tuning.md.

exit "$status"
