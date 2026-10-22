#!/bin/sh
store=db age=0 why=${1:-a checksum} uid=$(id -u) pick=db-1
here='the backup folder (BACKUP_DIR)'
say() { printf '%s\n' "$*"; }
foreign() { printf 'ERROR: %s %s, so the service does not use it\n' "$here" "$1" >&2; exit 1; }
describe() { printf '%s on %s' "$1" "$2"; }
echo "unhealthy: the newest set of $store was made ${age}s ago (BACKUP_MAX_AGE=${BACKUP_MAX_AGE-})"
bad="the last drill failed: $why"
say "unhealthy: $bad"
[ "$uid" = 0 ] || foreign "belongs to uid $uid and cannot be read"
say "restore: $store: replaces the database $(describe "$store" "$(hostname)") with the local set $pick"
