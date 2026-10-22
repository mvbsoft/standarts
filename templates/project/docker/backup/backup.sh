#!/bin/sh
# project template 1.0.0 — the backup service (standard OPS-01); change it in the standard's templates.
# The one command of the backup image (docs/how-to/backups.md).
#
# Usage: backup <command> [<options>]
#   run (the default)  the scheduler: daily at BACKUP_TIME (UTC) a set of every store, the
#                      off-server copy, rotation; on BACKUP_DRILL_DAY a drill and a check of the
#                      copy as well; after a daily run without a failure, a GET to
#                      BACKUP_HEARTBEAT_URL
#   backup [--store <s>] [--risk]  a set of every store (or of one) now, then the copy and rotation
#   drill [--store <s>] [--set <name>|latest|before-restore] [--risk]   restore the newest normal
#                      set (or the named one) into a temporary server and compare, when /drill has
#                      room for the set and DISK_RESERVE; restore-drill is its old name
#   restore [--store <s>] [--set <name>|latest|before-restore] [--from local|copy] [--no-safety]
#           [--risk]   into the working stores; needs CONFIRM=yes. latest: the newest normal set
#                      every store has; before-restore: the safety set. Every set is found and
#                      checked, and a safety set before-restore-<UTC time> of every store is made
#                      (unless --no-safety), before the first store is replaced.
#   restore --check …  only finds and checks the sets and says what a restore would replace;
#   restore --plan …   the same as one tab-separated line per store; --check --plan: both, from
#                      one reading of the sets; none of them needs CONFIRM
#   --risk             backup, drill and restore by hand: too little free space (an estimate) is
#                      a warning, and the command goes on; without it they refuse with exit 3
#   list [--store <s>] [--from local|copy]   the sets: name, time, size, kind, where
#   status             the health line, then the newest sets and the last result of every job
#   backup-test [--store <s>]      (dev) a set, a drill on it, then the set is deleted
#   copy-check         prove the off-server copy: a small test set is written, read back and
#                      compared, and deleting it must be refused
#   copy-verify        restic check of the copy, reading BACKUP_COPY_READ of its data
#   health             exit 0 or 1 for the compose healthcheck, one line why
#
# Reads:   the settings below (BACKUP_*, DISK_RESERVE); a module reads BACKUP_<STORE>_*, copy.sh
#          BACKUP_COPY_*; restore reads CONFIRM. The sets in /backup, the drill's space in /drill.
# Writes:  the sets, /backup/.state (the results, the times the health reads, the lock) and the
#          mark /backup/.backup-folder; a restore the working stores; with BACKUP_COPY_TO the copy.
# Output:  what it does on stdout (restore --plan: one tab-separated line per store); errors as
#          "ERROR: <why>" on stderr. A failed job POSTs one line to BACKUP_NOTIFY_URL.
# Exit:    0 ok; 1 a failure or a refusal, or unhealthy (health, status); 3 backup, drill or
#          restore (also --check, --plan) refused on the free-space estimate alone, before anything
#          changed, for project.sh to ask (not kept as a failed job, not notified); 4 backup: every
#          set was made and rotated, the copy failed. run ends with 0 on TERM or INT; its jobs refuse
#          too little free space as a failure (exit 1, notified): no one is there to ask.
# Shell:   POSIX sh (dash or BusyBox ash, as the base image has). Started as root (the compose
#          service), it gives the folders to BACKUP_USER and runs again as that user (drop_root).
#
# Stores: BACKUP_STORES lists <compose service>:<module> pairs, for example "db:postgres". A module
# is the file <module>.sh next to this one (postgres.sh is an example) with five functions:
#   <module>_backup <store> <dir>    write the store's files into <dir>, and the lines the restored
#                                    store must match (row counts and so on) into <dir>/facts
#   <module>_check <store> <dir>     check that the files of a new set can be read back
#   <module>_drill <store> <dir>     restore the set into a temporary server under /drill, compare
#   <module>_restore <store> <dir>   restore the set into the working store, compare
#   <module>_describe <store>        two lines: the name of the working store a person confirms a
#                                    restore with (a database name), then where it is (its host)
# A job runs in a subshell whose result is tested, where `set -e` does not apply: every command of a
# module or a job that can fail ends in `|| die "<why>"`, or a failure goes on unnoticed.
set -eu

# ---- settings and globals --------------------------------------------------
lib=/usr/local/lib/backup
# The sets folder in the container is fixed; on a server it is the host folder BACKUP_DIR (.env),
# in dev the volume backup-data. The messages name those.
dir=/backup
here='the backup folder (BACKUP_DIR on the host; in dev the volume backup-data)'
state=$dir/.state
# The mark of a folder the service made: only such a folder, an empty one, or one with the sets of
# an earlier release (earlier_sets) is used.
marker=$dir/.backup-folder
# The database user of the base image (Dockerfile); every command runs as it.
user=${BACKUP_USER:-postgres}
# die keeps the error here, for the notification (notify_failure) and the job's result.
errfile=/tmp/backup-error.$$
stores=${BACKUP_STORES:-db:postgres}
time=${BACKUP_TIME:-03:00}
keep_daily=${BACKUP_KEEP_DAILY:-7}
keep_weekly=${BACKUP_KEEP_WEEKLY:-4}
drill_day=${BACKUP_DRILL_DAY:-7}
max_age=${BACKUP_MAX_AGE:-26h}
copy_to=${BACKUP_COPY_TO:-}
copy_read=${BACKUP_COPY_READ:-10%}
reserve=${DISK_RESERVE:-2G}
# Set by one function and read by others (sh has no local variables):
#   store_opt name from check text plan safety risk   the options (options); --store also
#             narrows stores to that one store
#   asks      set for backup, drill and restore run by hand: too little free space refuses with
#             exit 3 (short); weighed: the drill weighed the space of every set first (drill_all)
#   pick      the set a restore reads (restore_find); names: the sets of one store (copy_sets for
#             the copy), read by restore_find and list
#   new       the safety set this restore made (safety_sets), empty without one
#   host      the host the copy's sets are tagged with (copy_ready, copy.sh)
#   cleanups  what at_exit collected for the subshell of sub; test_mode: set by backup_test
#   job_name  the job that job runs

# ---- primitives ------------------------------------------------------------
say() { printf '%s\n' "$*"; }
# die <message>: "ERROR: <message>" on stderr, the message into $errfile, exit 1. In a subshell
# (sub, $( )) the exit ends only that subshell: the caller tests it (sub … || …,
# v=$(…) || die). quit <code> <message>: the same with exit <code> (3 and 4: Exit above).
die() { quit 1 "$*"; }
quit() { printf 'ERROR: %s\n' "$2" >&2; printf '%s\n' "$2" > "$errfile" 2>/dev/null || :; exit "$1"; }
# at_exit <command>: run <command> when the current subshell (sub) ends, however it ends.
# sub <function> <args>: run the function in a subshell with its own at_exit commands. Called in
# a condition (if sub …, sub … || …), -e is off inside, so every step checks itself.
at_exit() { cleanups="$1; ${cleanups:-}"; }
sub() { (cleanups=; trap 'eval "${cleanups:-:}"' EXIT; "$@"); }

seconds() { # 26h, 90m, 2d or 3600 (seconds) -> seconds
  n=${1%[smhd]}
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  case "$1" in *d) echo $((n * 86400)) ;; *h) echo $((n * 3600)) ;; *m) echo $((n * 60)) ;; *) echo "$n" ;; esac
}
kib() { # 2G, 500M, 64K, 1T or 0 -> KiB
  n=${1%[KMGT]}
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  case "$1" in *K) echo "$n" ;; *M) echo $((n * 1024)) ;; *G) echo $((n * 1048576)) ;; *T) echo $((n * 1073741824)) ;;
    0) echo 0 ;; *) return 1 ;; esac
}
human() { # KiB -> 1.5G, 300M, 12K
  awk -v k="$1" 'BEGIN { split("K M G T", u); i = 1; while (k >= 1024 && i < 4) { k /= 1024; i++ }
    printf((k < 10 && i > 1) ? "%.1f%s\n" : "%d%s\n", k, u[i]) }'
}

# ---- the backup folder and the start as root -------------------------------
foreign() { # the refusal of a backup folder that is not the service's; $1: what is wrong with it
  printf 'ERROR: %s %s, so the backup service does not use it and changed nothing: give it an empty or missing folder of its own, one per environment (docs/how-to/backups.md)\n' "$here" "$1" >&2
  exit 1
}
marked_by() { sed -n 's/^host //p' "$marker" 2>/dev/null; }  # the host name in the mark
# earlier_sets: the folder holds what an earlier release of the service left before it marked its
# folder, and nothing else: .state and store folders of sets, all of the user the service runs as.
earlier_sets() {
  [ -d "$state" ] || return 1
  for f in "$dir"/* "$dir"/.[!.]*; do
    [ -e "$f" ] || continue
    [ "$(stat -c %u "$f")" = "$(id -u)" ] || return 1
    case "${f##*/}" in .state) continue ;; .*) return 1 ;; esac
    [ -d "$f" ] && printf '%s\n' "${f##*/}" | grep -Eq '^[a-z0-9][a-z0-9_-]*$' || return 1
    for g in "$f"/* "$f"/.[!.]*; do
      [ -e "$g" ] || continue
      [ -d "$g" ] && [ "$(stat -c %u "$g")" = "$(id -u)" ] || return 1
      printf '%s\n' "${g##*/}" | grep -Eq '^(\.tmp-|\.fetch-)|^(before-restore-)?[0-9]{8}T[0-9]{6}Z$' || return 1
    done
  done
}
entries() { find "$dir" -mindepth 1 -maxdepth 1 | sed 's|.*/||' | LC_ALL=C sort | head -n "$1" | tr '\n' ' '; }  # the first $1 names in it

# drop_root <args>: started as root, give the backup folder and /drill to BACKUP_USER, then run
# this script again as that user (exec: it does not return). Started as that user: nothing.
drop_root() {
  if [ "$(id -u)" = 0 ]; then
    # Root only gives the backup folder (a bind mount, which Docker creates as root, 0:0 mode 755,
    # when it is missing) and /drill to that user, then drops to it: the folder only when it is
    # empty or marked as the service's, never someone else's files. Capabilities: CHOWN for this,
    # SETUID and SETGID for gosu; the commands themselves run as that user without any.
    uid=$(id -u "$user") || { echo "ERROR: BACKUP_USER $user is not a user of this image" >&2; exit 1; }
    gid=$(id -g "$user")
    if [ "$(stat -c %u "$dir")" != "$uid" ]; then
      if [ -f "$marker" ]; then
        [ "$(marked_by)" = "$(hostname)" ] || foreign "belongs to the backup service of $(marked_by), not of $(hostname)"
        chown -R "$uid:$gid" "$dir" \
          || { echo "ERROR: cannot give $dir to the $user user (the container lacks the CHOWN capability?)" >&2; exit 1; }
      elif [ -r "$dir" ] && [ -x "$dir" ]; then
        [ -z "$(entries 1)" ] || foreign "holds files the service did not make ($(entries 3)…)"
        chmod 700 "$dir" 2>/dev/null || :
        chown "$uid:$gid" "$dir" \
          || { echo "ERROR: cannot give $dir to the $user user (the container lacks the CHOWN capability?)" >&2; exit 1; }
      else
        foreign "belongs to uid $(stat -c %u "$dir") and cannot be read"
      fi
    fi
    if [ "$(stat -c %u /drill)" != "$uid" ]; then
      chmod 700 /drill 2>/dev/null || :
      chown -R "$uid:$gid" /drill \
        || { echo "ERROR: cannot give /drill to the $user user (the container lacks the CHOWN capability?)" >&2; exit 1; }
    fi
    exec gosu "$user" "$0" "$@"
  fi
}

# ---- jobs and notifications ------------------------------------------------
# job <name> <function> <args>: runs the function in a subshell; a failure is notified as
# "<name> failed". The last result of every job is kept for status. Returns the exit code of the
# function (3 or 4, Exit above; any other failure 1); 3 is a refusal before anything changed, for
# project.sh to ask: not kept and not notified.
job() {
  rm -f "$errfile"
  job_name=$1; shift
  if sub "$@"; then result "$job_name" ok; return 0; else rc=$?; fi
  case "$rc" in 3) return 3 ;; 4) ;; *) rc=1 ;; esac
  result "$job_name" failed
  notify_failure "$job_name"
  return "$rc"
}
# result <job> ok|failed: the job's last result in $state/last.<job> (on a failure with the first
# line of $errfile), for status and the health.
result() {
  why=
  [ "$2" = ok ] || why=$(head -n 1 "$errfile" 2>/dev/null || :)
  printf '%s %s %s\n' "$2" "$(date +%s)" "$why" > "$state/last.$1" 2>/dev/null || :
}

http() { # http <url> [<body>]: a GET, or a POST of <body>, with curl or wget, 20 s at most
  if command -v curl >/dev/null; then
    if [ $# -gt 1 ]; then curl -fsS -m 20 -o /dev/null --data-raw "$2" "$1"; else curl -fsS -m 20 -o /dev/null "$1"; fi
  elif command -v wget >/dev/null; then
    if [ $# -gt 1 ]; then wget -q -T 20 -O /dev/null --post-data="$2" "$1"; else wget -q -T 20 -O /dev/null "$1"; fi
  else false; fi
}

notify_failure() { # POST one line to BACKUP_NOTIFY_URL, if it is set
  [ -n "${BACKUP_NOTIFY_URL:-}" ] || return 0
  msg="backup on $(hostname): $1 failed: $(head -n 1 "$errfile" 2>/dev/null || echo 'see the logs')"
  http "$BACKUP_NOTIFY_URL" "$msg" || say "WARNING: the notification to BACKUP_NOTIFY_URL failed"
}

heartbeat() { # GET BACKUP_HEARTBEAT_URL, if it is set: the monitor elsewhere alerts when it is missing
  [ -n "${BACKUP_HEARTBEAT_URL:-}" ] || return 0
  if http "$BACKUP_HEARTBEAT_URL"; then say "heartbeat: sent"
  else say "WARNING: the heartbeat to BACKUP_HEARTBEAT_URL failed"; fi
}

# ---- settings check and options --------------------------------------------
# check_settings: die on a setting that is not valid; then mark the backup folder as this
# service's (or refuse one that is not) and make $state. It runs before every command.
check_settings() {
  for p in $stores; do
    printf '%s\n' "$p" | grep -Eq '^[a-z0-9][a-z0-9_-]*:[a-z0-9_]+$' \
      || die "BACKUP_STORES: '$p' is not <compose service>:<module>"
    [ -f "$lib/${p#*:}.sh" ] || die "BACKUP_STORES: no module ${p#*:} ($lib/${p#*:}.sh)"
  done
  printf '%s\n' "$time" | grep -Eq '^([01][0-9]|2[0-3]):[0-5][0-9]$' || die "BACKUP_TIME is '$time', not HH:MM (UTC)"
  case "$keep_daily" in ''|*[!0-9]*|0) die "BACKUP_KEEP_DAILY is '$keep_daily', not a number of 1 or more" ;; esac
  case "$keep_weekly" in ''|*[!0-9]*) die "BACKUP_KEEP_WEEKLY is '$keep_weekly', not a number" ;; esac
  case "$drill_day" in [1-7]) ;; *) die "BACKUP_DRILL_DAY is '$drill_day', not 1 to 7 (Monday is 1)" ;; esac
  seconds "$max_age" >/dev/null || die "BACKUP_MAX_AGE is '$max_age', not like 26h, 90m, 2d"
  kib "$reserve" >/dev/null || die "DISK_RESERVE is '$reserve', not a size like 2G or 500M"
  printf '%s\n' "$copy_read" | grep -Eq '^(0|[0-9]+(\.[0-9]+)?%)$' \
    || die "BACKUP_COPY_READ is '$copy_read', not a percentage like 10% (or 0: the structure only)"
  url_var=
  [ -z "${BACKUP_HEARTBEAT_URL:-}" ] || url_var=BACKUP_HEARTBEAT_URL
  [ -z "${BACKUP_NOTIFY_URL:-}" ] || url_var=BACKUP_NOTIFY_URL
  [ -z "$url_var" ] || command -v curl >/dev/null || command -v wget >/dev/null \
    || die "$url_var is set, but the image has neither curl nor wget: add one to docker/backup/Dockerfile"
  [ -r "$dir" ] && [ -w "$dir" ] && [ -x "$dir" ] || die "$here is not writable by the $user user (uid $(id -u))"
  if [ -f "$marker" ]; then
    [ "$(marked_by)" = "$(hostname)" ] || foreign "belongs to the backup service of $(marked_by), not of $(hostname)"
  elif [ -z "$(entries 1)" ] || earlier_sets; then
    printf '%s\nhost %s\n' "The backup service of one environment made this folder; nothing else may write here." \
      "$(hostname)" > "$marker" || die "cannot write $marker"
  else
    foreign "holds files the service did not make ($(entries 3)…)"
  fi
  # A folder that root could only chown (it belonged to another user) gets its mode now.
  chmod 700 "$dir" 2>/dev/null || :
  mkdir -p "$state" 2>/dev/null && [ -w "$state" ] || die "$state is not writable by the $user user (uid $(id -u))"
}

# The value of BACKUP_<STORE>_<NAME> (store db, name USER: BACKUP_DB_USER).
# eval builds the variable's name: the store passed check_settings ([a-z0-9_-]), NAME is the
# module's own word.
store_var() {
  k=$(printf '%s' "$1" | tr 'a-z-' 'A-Z_')
  eval "printf '%s' \"\${BACKUP_${k}_$2:-}\""
}
describe() { # describe <store>:<module>: "<name> on <host>" of the working store
  d=$("${1#*:}_describe" "${1%%:*}") || die "${1%%:*}: ${1#*:}_describe failed"
  printf '%s on %s' "$(printf '%s\n' "$d" | sed -n 1p)" "$(printf '%s\n' "$d" | sed -n 2p)"
}

allowed() { # the options of a command
  case "$1" in
    backup) echo --store --risk ;;
    backup-test) echo --store ;;
    drill|restore-drill) echo --store --set --risk ;;
    restore) echo --check --plan --store --set --from --no-safety --risk ;;
    list) echo --store --from ;;
  esac
}
usage() {
  case "$1" in
    backup) echo "backup [--store <store>] [--risk]" ;;
    backup-test) echo "backup-test [--store <store>]" ;;
    drill|restore-drill) echo "$1 [--store <store>] [--set <name>|latest|before-restore] [--risk]" ;;
    restore) echo "restore [--check] [--plan] [--store <store>] [--set <name>|latest|before-restore] [--from local|copy] [--no-safety] [--risk]" ;;
    list) echo "list [--store <store>] [--from local|copy]" ;;
    *) echo "$1" ;;
  esac
}
# options <command> <args>: the options of the command -> $store_opt, $name, $from, $check,
# $text, $plan, $safety, $risk; --store narrows $stores to that store. Dies on a wrong option.
options() {
  c=$1; shift
  store_opt='' name=latest from=local check='' text='' plan='' safety=1 risk=''
  while [ $# -gt 0 ]; do
    case " $(allowed "$c") " in *" $1 "*) ;; *) die "$c: unknown option $1 ($(usage "$c"))" ;; esac
    case "$1" in
      --store) [ $# -ge 2 ] || die "--store needs a store of BACKUP_STORES"; store_opt=$2; shift 2 ;;
      --set) [ $# -ge 2 ] || die "--set needs a set name or latest"; name=$2; shift 2 ;;
      --from) [ $# -ge 2 ] || die "--from needs local or copy"; from=$2; shift 2 ;;
      --check) check=1 text=1; shift ;;
      --plan) check=1 plan=1; shift ;;
      --no-safety) safety=; shift ;;
      --risk) risk=1; shift ;;
    esac
  done
  case "$from" in local|copy) ;; *) die "--from is '$from', not local or copy" ;; esac
  case "$name" in latest|before-restore) ;; *)
    printf '%s\n' "$name" | grep -Eq '^(before-restore-)?[0-9]{8}T[0-9]{6}Z$' \
      || die "--set is '$name', not latest, before-restore or a set name like 20261019T030000Z" ;;
  esac
  [ -n "$store_opt" ] || return 0
  for p in $stores; do
    [ "${p%%:*}" != "$store_opt" ] || { stores=$p; return 0; }
  done
  die "--store is '$store_opt', not a store of BACKUP_STORES ($(for p in $stores; do printf '%s ' "${p%%:*}"; done | sed 's/ $//'))"
}

# ---- sets ------------------------------------------------------------------
# A set is $dir/<store>/<UTC time>/, a safety set $dir/<store>/before-restore-<UTC time>/ (made by
# restore). A set is written as .tmp-<name> and renamed once it is checked.
list_sets() { # list_sets <store> <prefix>: the finished sets <prefix><UTC time> of a store, oldest first
  for f in "$dir/$1/$2"2*Z; do
    case "${f##*/}" in "$2"[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z)
      [ ! -d "$f" ] || printf '%s\n' "${f##*/}" ;;
    esac
  done
}
sets_of() { list_sets "$1" ''; }                # the normal sets: rotation, latest and the drill
safety_of() { list_sets "$1" before-restore-; }  # the safety sets: only named ones take them
is_safety() { case "$1" in before-restore-*) return 0 ;; *) return 1 ;; esac; }
set_time() { printf '%s\n' "${1#before-restore-}" | sed 's/^\(....\)\(..\)\(..\)T\(..\)\(..\)\(..\)Z$/\1-\2-\3 \4:\5:\6/'; }
lock() { # one backup, drill, restore or copy check at a time
  exec 9>> "$state/lock"
  flock -n 9 || { say "waiting for the backup, drill or restore that is running"; flock 9 || die "cannot lock $state/lock"; }
}

size_of() { du -sk "$1" | cut -f1; }  # KiB
last_size() { # last_size <store>: KiB of its newest set, 0 when it has none
  n=$(sets_of "$1" | tail -n 1)
  [ -n "$n" ] || n=$(safety_of "$1" | tail -n 1)
  if [ -n "$n" ]; then size_of "$dir/$1/$n"; else echo 0; fi
}
# short <what was found> <what can go wrong>: a free-space estimate says no. With --risk a warning,
# and the command goes on; by hand (asks) a refusal with exit 3, for project.sh to ask; a scheduled
# job (and backup-test) fails with exit 1, as any failure.
short() {
  if [ -n "$risk" ]; then say "WARNING: $1; going on (--risk), which can fill the disk: $2"; return 0; fi
  [ -n "$asks" ] || die "$1: free some space"
  quit 3 "$1: free some space; going on can fill the disk: $2"
}
# need_space <what> <KiB> <what can go wrong>: refuse (short), before anything changes, when the
# backup folder has less free space than <KiB> (a new set takes about what the store's last one
# took) plus DISK_RESERVE.
need_space() {
  have=$(df -Pk "$dir" | awk 'NR == 2 {print $4}')
  case "$have" in ''|*[!0-9]*) die "cannot read the free space of $dir (df -Pk)" ;; esac
  need=$(($2 + $(kib "$reserve")))
  [ "$have" -ge "$need" ] || short "not enough free space for the $1 in $here: need $(human "$need") ($(human "$2") for the new sets, the size of the last ones, and DISK_RESERVE=$reserve), have $(human "$have")" "$3"
}

verify_set() { # the checksums of the set in $1 against its manifest
  [ -f "$1/manifest" ] || die "$1 has no manifest: not a finished set"
  grep -q '^sha256 ' "$1/manifest" || die "$1/manifest lists no files"
  bad=$(grep '^sha256 ' "$1/manifest" | while read -r _ sum f; do
    [ "$(sha256sum "$1/$f" 2>/dev/null | cut -d' ' -f1)" = "$sum" ] || printf ' %s' "$f"
  done)
  [ -z "$bad" ] || die "${1#"$dir"/}:$bad: the checksum does not match the manifest, so the set is damaged"
}

compare_facts() { # compare_facts <set> <facts of the restored store> [<kinds that may have more>]
  grep -v -e '^sha256 ' -e '^#' "$1/manifest" | LC_ALL=C sort > "$2.want"
  LC_ALL=C sort "$2" > "$2.have"
  if [ -n "${3:-}" ]; then # for these kinds, only what the manifest lists must be there
    for k in $3; do grep "^$k " "$2.want" >> "$2.extra" || :; done
    grep -v -F -x -f "$2.have" "$2.extra" > "$2.missing" || :
    for k in $3; do sed -i "/^$k /d" "$2.want" "$2.have" || die "cannot edit $2.want"; done
    [ ! -s "$2.missing" ] || die "${1#"$dir"/}: the restored store lacks: $(head -n 3 "$2.missing" | tr '\n' ';')"
  fi
  if ! diff "$2.want" "$2.have" > "$2.diff"; then
    die "${1#"$dir"/}: the restored store differs from the manifest: expected $(sed -n 's/^-\([^-]\)/\1/p' "$2.diff" | head -n 2 | tr '\n' ';') restored $(sed -n 's/^+\([^+]\)/\1/p' "$2.diff" | head -n 2 | tr '\n' ';')"
  fi
}

# make_set <store> <module> <set name>: write one set as .tmp-<name>, add its manifest, check it,
# then rename it. It runs in sub or in a condition: -e is off, so every step checks itself.
make_set() {
  sd=$dir/$1
  mkdir -p "$sd" || die "cannot create $sd"
  for t in "$sd"/.tmp-* "$sd"/.fetch-*; do
    # A restore makes its safety set after it fetched the set from the copy: that one is in use.
    [ "$t" != "$sd/.fetch-$$" ] || continue
    [ ! -e "$t" ] || { say "backup: removing the unfinished $1/${t##*/}"; rm -rf "$t" || die "cannot remove $t"; }
  done
  t=$sd/.tmp-$3
  mkdir "$t" || die "cannot create $t"
  "$2_backup" "$1" "$t" || die "$1: $2_backup failed"
  { printf '# backup set %s/%s\n' "$1" "$3"
    for f in "$t"/*; do
      case "${f##*/}" in facts|manifest.new) ;; *) printf 'sha256 %s %s\n' "$(sha256sum "$f" | cut -d' ' -f1)" "${f##*/}" ;; esac
    done
    cat "$t/facts"
  } > "$t/manifest.new" || die "$1: cannot write the manifest of $3"
  rm "$t/facts" || die "cannot remove $t/facts"
  mv "$t/manifest.new" "$t/manifest" || die "cannot rename $t/manifest.new"
  verify_set "$t"
  "$2_check" "$1" "$t" || die "$1: $2_check failed"
  mv "$t" "$sd/$3" || die "cannot rename $t to $sd/$3: the set is not finished"
  # The health counts normal sets only: a safety set is no daily backup.
  [ "${test_mode:-}" = 1 ] || is_safety "$3" || date +%s > "$state/set.$1" || die "cannot write $state/set.$1"
  say "backup: $1/$3 OK ($(du -sh "$sd/$3" | cut -f1); tables: $(grep -c "^rows " "$sd/$3/manifest" || :))"
}

# ---- backup and rotation ---------------------------------------------------
# backup_all: the job backup: a set of every store (a failed store does not stop the others), then
# the copy and rotation.
backup_all() {
  lock
  est=0
  for p in $stores; do est=$((est + $(last_size "${p%%:*}"))); done
  need_space backup "$est" "the set then fails halfway, and what else writes to that disk (the database, the app) can fail"
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  failed=
  for p in $stores; do
    sub make_set "${p%%:*}" "${p#*:}" "$stamp" || failed="$failed ${p%%:*}"
  done
  [ -z "$failed" ] || die "the backup of$failed failed: $(head -n 1 "$errfile" 2>/dev/null)"
  # A copy that fails does not stop the rotation, or the sets would fill this disk while the
  # storage side is down; the failure is reported after it.
  copied=1
  [ -z "$copy_to" ] || sub copy_all || copied=
  rotate_all
  [ -n "$copied" ] || quit 4 "the copy failed: $(head -n 1 "$errfile" 2>/dev/null)"
}

# Keeps the newest set of each of the last KEEP_DAILY days and KEEP_WEEKLY ISO weeks, here only:
# the off-server copy is rotated by the storage side. The safety set is not counted or removed.
rotate_all() {
  for p in $stores; do
    s=${p%%:*}
    for n in $(sets_of "$s" | sort -r | while read -r m; do
        printf '%s %s %s\n' "$m" "${m%%T*}" "$(date -u -d "$(set_time "$m")" +%G%V)"
      done | awk -v kd="$keep_daily" -v kw="$keep_weekly" '
        { keep = 0
          if (!($2 in day)) { day[$2] = 1; if (++days <= kd) keep = 1 }
          if (!($3 in week)) { week[$3] = 1; if (++weeks <= kw) keep = 1 }
          if (!keep) print $1 }'); do
      rm -rf "${dir:?}/$s/$n" || die "rotation: cannot remove $s/$n"
      say "rotation: removed $s/$n"
    done
  done
  copied_prune
}

# ---- drill -----------------------------------------------------------------
# drill_space <set dir>: refuse (short), before the drill writes anything, when /drill has less
# free space than the set takes (the restored store takes at least that) plus DISK_RESERVE.
drill_space() {
  have=$(df -Pk /drill | awk 'NR == 2 {print $4}')
  case "$have" in ''|*[!0-9]*) die "cannot read the free space of /drill (df -Pk)" ;; esac
  z=$(size_of "$1")
  need=$((z + $(kib "$reserve")))
  [ "$have" -ge "$need" ] || short "not enough free space for the drill in /drill (the volume backup-drill): need $(human "$need") ($(human "$z") for the set, its size, and DISK_RESERVE=$reserve), have $(human "$have")" \
    "the drill then fails, and what else writes to that disk can fail"
}

drill_store() { # drill_store <store> <module> <set dir>
  [ -n "${weighed:-}" ] || drill_space "$3"
  verify_set "$3"
  "$2_drill" "$1" "$3" || die "$1: $2_drill failed"
  say "drill: ${3#"$dir"/} OK: restored and equal to the manifest"
}

drill_set() { # drill_set <store>: the set the drill takes (the newest normal one, or --set), or nothing
  case "$name" in
    latest) sets_of "$1" | tail -n 1 ;;
    before-restore) safety_of "$1" | tail -n 1 ;;
    *) [ ! -d "$dir/$1/$name" ] || echo "$name" ;;
  esac
}

drill_all() { # the newest normal set of every store, or the set --set names
  lock
  # By hand the free space of every set is weighed before the first drill, so that a refusal
  # (exit 3) comes before any drill; a scheduled drill weighs it per store, as a failure.
  if [ -n "$asks" ]; then
    for p in $stores; do n=$(drill_set "${p%%:*}"); [ -z "$n" ] || drill_space "$dir/${p%%:*}/$n"; done
    weighed=1
  fi
  failed=
  for p in $stores; do
    s=${p%%:*}
    n=$(drill_set "$s")
    if [ -n "$n" ]; then
      sub drill_store "$s" "${p#*:}" "$dir/$s/$n" || failed="$failed $s"
    elif [ "$name" = latest ]; then
      printf 'no set of %s to drill\n' "$s" > "$errfile"; failed="$failed $s"
    else
      printf 'no set %s/%s to drill (the sets: %s)\n' "$s" "$name" "$({ sets_of "$s"; safety_of "$s"; } | tr '\n' ' ' | sed 's/ $//')" > "$errfile"
      failed="$failed $s"
    fi
  done
  if [ -n "$failed" ]; then
    msg=$(head -n 1 "$errfile" 2>/dev/null)
    printf 'failed %s %s\n' "$(date +%s)" "$msg" > "$state/drill"
    die "the drill of$failed failed: $msg"
  fi
  # Only the drill of the newest set of every store clears a failed one (the health).
  [ -n "$store_opt" ] || [ "$name" != latest ] || printf 'ok %s\n' "$(date +%s)" > "$state/drill" \
    || die "cannot write $state/drill"
}

backup_test() { # dev: a set of every store, a drill on it, then the set is deleted
  lock
  test_mode=1
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  for p in $stores; do
    s=${p%%:*}
    make_set "$s" "${p#*:}" "$stamp" || die "$s: the backup failed"
    at_exit "rm -rf '$dir/$s/$stamp'"
    drill_store "$s" "${p#*:}" "$dir/$s/$stamp" || die "$s: the drill failed"
  done
  say OK
}

# ---- restore ---------------------------------------------------------------
keep_common() { # the lines of $1 that are also lines of $2
  printf '%s\n' "$1" | while read -r n; do
    [ -z "$n" ] || ! printf '%s\n' "$2" | grep -qx "$n" || printf '%s\n' "$n"
  done
}

restore_find() { # the one set every store restores from -> $pick; local sets are verified
  [ "$from" = local ] || copy_ready open
  common='' first=1
  for p in $stores; do
    s=${p%%:*}
    if [ "$from" = copy ]; then copy_sets "$s"; else names=$(sets_of "$s"; safety_of "$s"); fi
    list=$(printf '%s' "$names" | tr '\n' ' ')
    case "$name" in
      latest) names=$(printf '%s\n' "$names" | grep -v '^before-restore-' || :)
        [ -n "$names" ] || die "no $from set of $s (the sets: ${list:-none})" ;;
      before-restore) names=$(printf '%s\n' "$names" | grep '^before-restore-' || :)
        [ -n "$names" ] || die "no $from safety set before-restore-… of $s (the sets: ${list:-none})" ;;
      *) printf '%s\n' "$names" | grep -qx "$name" || die "no $from set $s/$name (the sets: ${list:-none})" ;;
    esac
    if [ -n "$first" ]; then common=$names first=; else common=$(keep_common "$common" "$names"); fi
  done
  pick=$name
  case "$name" in latest|before-restore) pick=$(printf '%s\n' "$common" | grep . | tail -n 1) ;; esac
  [ -n "$pick" ] || die "the stores have no common newest set (a store's backup failed): name one with SET="
  [ "$from" = copy ] || for p in $stores; do verify_set "$dir/${p%%:*}/$pick"; done
}

restore_space() { # a safety set and a set fetched from the copy each take about the last set's size
  est=0
  for p in $stores; do
    z=$(last_size "${p%%:*}")
    [ -z "$safety" ] || est=$((est + z))
    [ "$from" = local ] || est=$((est + z))
  done
  need_space restore "$est" "the safety set or the set from the copy then fails, and the restore stops before it replaces anything; what else writes to that disk can fail"
}

restore_check() { # restore --check and --plan: what a restore would do; replaces nothing
  lock
  restore_find
  restore_space
  for p in $stores; do
    s=${p%%:*}
    d=$("${p#*:}_describe" "$s") || die "$s: ${p#*:}_describe failed"
    if [ -n "$plan" ]; then
      # <store> <name> <host> <set> <its UTC time> local|copy safety|no-safety
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$s" "$(printf '%s\n' "$d" | sed -n 1p)" "$(printf '%s\n' "$d" | sed -n 2p)" \
        "$pick" "$(set_time "$pick")" "$from" "$([ -n "$safety" ] && echo safety || echo no-safety)"
      [ -n "$text" ] || continue
    fi
    say "restore: would restore $s from $pick ($from)"
    say "restore: $s: replaces the database $(describe "$p") with the $from set $pick of $(set_time "$pick") UTC; what was written after that set is lost"
    if [ -n "$safety" ]; then say "restore: $s: first a safety set before-restore-<now> of it as it is now"
    else say "restore: $s: no safety set (NO_SAFETY=1)"; fi
  done
}

# safety_sets: a set before-restore-<now> of every store as it is now, then only that one stays
# (and the one this restore reads, until it ends).
safety_sets() {
  new=before-restore-$(date -u +%Y%m%dT%H%M%SZ)
  for p in $stores; do
    sub make_set "${p%%:*}" "${p#*:}" "$new" \
      || die "the safety set of ${p%%:*} failed, so nothing was replaced: $(head -n 1 "$errfile" 2>/dev/null); fix it, or restore without one: NO_SAFETY=1"
  done
  for p in $stores; do
    for n in $(safety_of "${p%%:*}"); do
      [ "$n" = "$new" ] || [ "$n" = "$pick" ] || drop_safety "${p%%:*}" "$n"
    done
  done
}
drop_safety() { rm -rf "${dir:?}/$1/$2" || die "cannot remove $1/$2"; say "restore: removed the older safety set $1/$2"; }

restore() { # into the working stores; nothing is replaced before the set of every store is ready
  lock
  restore_find
  restore_space
  if [ "$from" = copy ]; then
    for p in $stores; do fetch_set "${p%%:*}" "$pick"; verify_set "$(copy_fetched_dir "${p%%:*}" "$pick")"; done
  fi
  new=
  if [ -n "$safety" ]; then safety_sets; else say "restore: no safety set (NO_SAFETY=1)"; fi
  for p in $stores; do
    s=${p%%:*}
    d=$dir/$s/$pick
    [ "$from" = local ] || d=$(copy_fetched_dir "$s" "$pick")
    say "restore: $s from the $from set $pick"
    "${p#*:}_restore" "$s" "$d" || die "$s: ${p#*:}_restore failed"
    say "restore: $s OK: equal to the manifest of $pick"
  done
  # A safety set restored from is the working state now; the new safety set replaces it.
  if [ -n "$new" ] && is_safety "$pick"; then
    for p in $stores; do [ ! -d "$dir/${p%%:*}/$pick" ] || drop_safety "${p%%:*}" "$pick"; done
  fi
  # The safety set goes off the server now; when that fails, the next backup copies it.
  [ -z "$new" ] || [ -z "$copy_to" ] || sub copy_all \
    || say "WARNING: the safety set is not in the off-server copy yet: $(head -n 1 "$errfile" 2>/dev/null); the next backup copies it"
}

# ---- list, health and status -----------------------------------------------
list() { # the sets of every store (or of one), for choosing SET=
  if [ "$from" = copy ]; then copy_ready open; fi
  printf '%-10s %-32s %-20s %6s  %-14s %s\n' store set "made (UTC)" size kind where
  for p in $stores; do
    s=${p%%:*}
    if [ "$from" = copy ]; then copy_sets "$s"; else names=$(sets_of "$s"; safety_of "$s"); fi
    for n in $names; do
      kind=normal; ! is_safety "$n" || kind=before-restore
      if [ "$from" = copy ]; then size=- where=copy
      else
        size=$(human "$(size_of "$dir/$s/$n")") where=local
        ! grep -qx "$n" "$state/copied.$s" 2>/dev/null || where="local, copied"
      fi
      printf '%-10s %-32s %-20s %6s  %-14s %s\n' "$s" "$n" "$(set_time "$n")" "$size" "$kind" "$where"
    done
  done
}

# health: the health line; unhealthy exits 1 (an exit, not a return: status reads the line from
# $(health), where -e is off).
health() {
  now=$(date +%s)
  max=$(seconds "$max_age") || { say "unhealthy: BACKUP_MAX_AGE is '$max_age', not like 26h"; exit 1; }
  start=$(cat "$state/started" 2>/dev/null) || start=$now
  bad=
  for p in $stores; do
    s=${p%%:*}
    for kind in set copy; do
      [ "$kind" = set ] || [ -n "$copy_to" ] || continue
      if t=$(cat "$state/$kind.$s" 2>/dev/null); then what="the newest $kind of $s was made"
      else t=$start what="there is no $kind of $s yet, and the service started"; fi
      age=$((now - t))
      [ "$age" -le "$max" ] || bad="${bad:-$what $((age / 3600))h$((age % 3600 / 60))m ago (BACKUP_MAX_AGE=$max_age)}"
    done
  done
  if [ -z "$bad" ] && [ -f "$state/drill" ] && read -r result _ why < "$state/drill" && [ "$result" = failed ]; then
    bad="the last drill failed: $why"
  fi
  if [ -z "$bad" ] && [ -n "$copy_to" ] && [ -f "$state/last.copy-verify" ] \
      && read -r result _ why < "$state/last.copy-verify" && [ "$result" = failed ]; then
    bad="the last check of the copy failed: $why"
  fi
  [ -z "$bad" ] || { say "unhealthy: $bad"; exit 1; }
  say "healthy: no newest set$([ -z "$copy_to" ] || printf " or copy") is older than $max_age (BACKUP_MAX_AGE), no failed drill$([ -z "$copy_to" ] || printf " or check of the copy")"
}

status() { # the health line, then what the sets and the jobs are: for a person, not for scripts
  if h=$(health); then code=0; else code=1; fi
  say "$h"
  for p in $stores; do
    s=${p%%:*}
    n=$(sets_of "$s" | tail -n 1) b=$(safety_of "$s" | tail -n 1)
    say "$s: $(sets_of "$s" | grep -c . || :) sets; the newest: ${n:-none}$([ -z "$n" ] || printf ' (%s UTC, %s)' "$(set_time "$n")" "$(human "$(size_of "$dir/$s/$n")")"); safety set: ${b:-none}"
    [ -z "$copy_to" ] || say "$s: the newest copy: $(t=$(cat "$state/copy.$s" 2>/dev/null) && date -u -d "@$t" '+%Y-%m-%d %H:%M UTC' || echo none)"
  done
  for j in backup drill copy-verify copy-check restore; do
    if [ -f "$state/last.$j" ] && read -r r t why < "$state/last.$j"; then
      say "last $j: $r at $(date -u -d "@$t" '+%Y-%m-%d %H:%M UTC')${why:+: $why}"
    else say "last $j: none since the backup folder was made"; fi
  done
  say "free space in $here: $(human "$(df -Pk "$dir" | awk 'NR == 2 {print $4}')") (DISK_RESERVE=$reserve)"
  exit "$code"
}

# ---- scheduler -------------------------------------------------------------
daily() { # the scheduled work of one day; the heartbeat only when every step succeeded
  ok=1
  job backup backup_all || ok=
  if [ "$(date -u +%u)" = "$drill_day" ]; then
    job drill drill_all || ok=
    [ -z "$copy_to" ] || job copy-verify copy_verify || ok=
  fi
  [ -z "$ok" ] || heartbeat
}

# scheduler: the command run: every 30 s, the daily run once a day after BACKUP_TIME (UTC); TERM
# and INT end it with 0.
scheduler() {
  date +%s > "$state/started"
  hm=1$(printf '%s' "$time" | tr -d :)
  # The first start after today's time waits for tomorrow; a later start makes up a missed day.
  [ -f "$state/last-run" ] || [ "1$(date -u +%H%M)" -lt "$hm" ] || date -u +%Y%m%d > "$state/last-run"
  say "scheduler: daily at $time UTC: a set of $stores$([ -z "$copy_to" ] || printf ', the copy'), rotation (keep $keep_daily daily, $keep_weekly weekly); drill$([ -z "$copy_to" ] || printf ' and a check of the copy') on day $drill_day$([ -z "${BACKUP_HEARTBEAT_URL:-}" ] || printf '; the heartbeat after a run without a failure')"
  trap 'exit 0' TERM INT
  while :; do
    today=$(date -u +%Y%m%d)
    if [ "1$(date -u +%H%M)" -ge "$hm" ] && [ "$(cat "$state/last-run" 2>/dev/null)" != "$today" ]; then
      say "scheduler: $(date -u +%Y-%m-%dT%H:%M:%SZ) the daily run"
      daily
      # Written after the run: a run that is stopped or killed halfway is made up at the next start.
      printf '%s\n' "$today" > "$state/last-run"
    fi
    sleep 30 & wait $! || :
  done
}

# ---- main ------------------------------------------------------------------
# main <command> [<options>]: start as the user, check the settings and the options, load the
# modules of the stores and copy.sh, then run the command.
main() {
  drop_root "$@"
  umask 077
  cmds='run backup drill restore-drill restore list status backup-test copy-check copy-verify health'
  cmd=${1:-run}
  [ $# -eq 0 ] || shift
  case " $cmds " in *" $cmd "*) ;; *) die "unknown command '$cmd' ($(echo "$cmds" | sed 's/ /, /g'))" ;; esac
  check_settings
  options "$cmd" "$@"
  asks=
  case "$cmd" in backup|drill|restore-drill|restore) asks=1 ;; esac
  for m in $(for p in $stores; do echo "${p#*:}"; done | sort -u); do
    # shellcheck source=/dev/null
    . "$lib/$m.sh"
  done
  # shellcheck source=/dev/null
  . "$lib/copy.sh"
  case "$cmd" in
    run) scheduler ;;
    backup) job backup backup_all ;;
    drill|restore-drill) job drill drill_all ;;
    restore) # the options and CONFIRM are checked before the job: a refusal is not a failure to notify
      if [ -n "$check" ]; then sub restore_check; exit; fi
      what=
      for p in $stores; do what="$what${what:+, }$(describe "$p")"; done
      [ "${CONFIRM:-}" = yes ] || die "restore replaces the working database $what: run again with CONFIRM=yes"
      job restore restore ;;
    list) list ;;
    status) status ;;
    backup-test) job backup-test backup_test ;;
    copy-check) job copy-check copy_check ;;
    copy-verify) job copy-verify copy_verify ;;
    health) health ;;
  esac
}

main "$@"
