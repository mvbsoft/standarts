# project template 1.0.0 — the backup service (standard OPS-01); sourced by backup.sh.
# The off-server copy with restic, write-only: this server adds sets and never deletes or changes
# one; the storage side rotates the copy with a login of its own (docs/how-to/backups.md).
# Repository BACKUP_COPY_TO: a rest-server run with --append-only --private-repos,
# rest:https://<host>:<port>/<login>/ (or a local folder, for tests only); restic encrypts it with
# BACKUP_COPY_PASSWORD. The rest-server login of this server is BACKUP_COPY_LOGIN and
# BACKUP_COPY_LOGIN_PASSWORD, never in the URL, which the messages show. A server with a
# certificate of its own: the certificate file is mounted read-only at the path below
# (BACKUP_COPY_CACERT names it on the host).
#
# Usage:   sourced by backup.sh, after the modules; its functions run in backup.sh's jobs, where
#          -e is off, so every step ends in || die.
# Reads:   BACKUP_COPY_TO and BACKUP_COPY_READ (as $copy_to and $copy_read), BACKUP_COPY_PASSWORD,
#          BACKUP_COPY_LOGIN, BACKUP_COPY_LOGIN_PASSWORD; the certificate file below.
# Writes:  the copy; $state/copied.<store> (the sets copied), $state/copy.<store> (the time of the
#          newest), $state/restic-cache; exports the RESTIC_* variables restic reads.
# Takes from backup.sh: dir, state, stores, copy_to, copy_read, errfile; say, die, at_exit, lock,
#          result, sets_of, safety_of, is_safety, set_time.
# shellcheck shell=sh disable=SC2154 # dir, state, stores and the settings come from backup.sh
cacert=/etc/backup-copy/cacert

# ---- restic ----------------------------------------------------------------
restic_run() {
  if [ -s "$cacert" ]; then restic --retry-lock 10m --cacert "$cacert" "$@"; else restic --retry-lock 10m "$@"; fi
}

copy_why() { # the reason in restic's output $1, in one line
  case "$1" in
    *"401 Unauthorized"*) echo "the rest-server refused the login BACKUP_COPY_LOGIN: a wrong login or password, or a path that does not start with /<login>/ (--private-repos)" ;;
    *"x509: "*|*"tls: "*) echo "the rest-server's certificate is not trusted: BACKUP_COPY_CACERT must name it (docs/how-to/backups.md): $(printf '%s\n' "$1" | grep -m 1 -o -e 'x509: .*' -e 'tls: .*')" ;;
    *"dial tcp"*) echo "the rest-server cannot be reached: $(printf '%s\n' "$1" | grep -m 1 -o 'dial tcp.*')" ;;
    *) line=$(printf '%s\n' "$1" | grep -v '^ *$' | grep -m 1 -i -e fatal -e error) \
         || line=$(printf '%s\n' "$1" | grep -v '^ *$' | tail -n 1)
       printf 'restic: %s\n' "$(printf '%s\n' "$line" | sed 's/^\(Fatal: \)*//')" ;;
  esac
}

copy_owner_fix() { # the commands that give the host file $1 to the backup user
  printf 'sudo chown %s:%s %s && sudo chmod 600 %s' "$(id -u)" "$(id -g)" "$1" "$1"
}

# copy_ready init|open: the repository opens with the password; init creates a missing one, open
# dies instead. Exports the RESTIC_* variables and sets $host, which the other functions use.
copy_ready() {
  [ -n "$copy_to" ] || die "BACKUP_COPY_TO is empty: set it in .env (docs/how-to/backups.md)"
  [ -n "${BACKUP_COPY_PASSWORD:-}" ] || die "BACKUP_COPY_PASSWORD is empty: set it in .env"
  case "$copy_to" in
    rest:http://*@*|rest:https://*@*)
      die "BACKUP_COPY_TO holds a login: put it in BACKUP_COPY_LOGIN and BACKUP_COPY_LOGIN_PASSWORD, which the messages never show" ;;
    rest:http://*|rest:https://*)
      [ -n "${BACKUP_COPY_LOGIN:-}" ] && [ -n "${BACKUP_COPY_LOGIN_PASSWORD:-}" ] \
        || die "BACKUP_COPY_LOGIN or BACKUP_COPY_LOGIN_PASSWORD is empty: the rest-server login of this server (docs/how-to/backups.md)"
      export RESTIC_REST_USERNAME="$BACKUP_COPY_LOGIN" RESTIC_REST_PASSWORD="$BACKUP_COPY_LOGIN_PASSWORD"
      [ ! -s "$cacert" ] || [ -r "$cacert" ] \
        || die "the certificate file is not readable by the backup user (uid $(id -u)): $(copy_owner_fix "${BACKUP_COPY_CACERT:-<BACKUP_COPY_CACERT>}")" ;;
    /*) ;;
    *) die "BACKUP_COPY_TO is '$copy_to': the template copies to a rest-server, rest:https://<host>:<port>/<login>/ (or, for tests, a local folder); another kind of store needs its own setup and its own proof (docs/how-to/backups.md)" ;;
  esac
  export RESTIC_REPOSITORY="$copy_to" RESTIC_PASSWORD="$BACKUP_COPY_PASSWORD" RESTIC_CACHE_DIR="$state/restic-cache"
  host=$(hostname)
  if out=$(restic_run cat config 2>&1 >/dev/null); then return 0; else code=$?; fi
  case "$code:$1" in
    # A restore only reads: a mistyped BACKUP_COPY_TO must not become a new, empty repository.
    10:open) die "no repository at $copy_to (BACKUP_COPY_TO): nothing to restore from" ;;
    10:init) say "copy: no repository at $copy_to yet: creating it"
             out=$(restic_run init 2>&1) || die "the repository $copy_to is missing and cannot be created: $(copy_why "$out")" ;;
    12:*) die "wrong password for the repository $copy_to: BACKUP_COPY_PASSWORD is not the one it was created with" ;;
    *) die "cannot open the repository $copy_to: $(copy_why "$out")" ;;
  esac
}

# ---- copy and fetch --------------------------------------------------------
copy_all() { # copy every local set not copied yet; nothing in the copy is ever deleted from here
  copy_ready init
  for p in $stores; do
    s=${p%%:*}
    touch "$state/copied.$s" || die "cannot write $state/copied.$s"
    for n in $(sets_of "$s"; safety_of "$s"); do
      ! grep -qx "$n" "$state/copied.$s" || continue
      # The tags and the time of the set let the storage side's rotation keep the same sets as the
      # local one, and the newest safety set (tag before-restore) apart from them.
      tags=$s
      ! is_safety "$n" || tags=$s,before-restore
      out=$(restic_run backup --tag "$tags" --host "$host" --time "$(set_time "$n")" "$dir/$s/$n" 2>&1) \
        || die "the copy of $s/$n failed: $(copy_why "$out")"
      printf '%s\n' "$n" >> "$state/copied.$s" || die "cannot write $state/copied.$s"
      is_safety "$n" || date +%s > "$state/copy.$s" || die "cannot write $state/copy.$s"
      say "copy: $s/$n -> $copy_to ($(printf '%s\n' "$out" | sed -n 's/^snapshot \([0-9a-f]*\) saved$/snapshot \1/p'))"
    done
  done
}

copied_prune() { # forget the names of local sets that rotation removed
  for p in $stores; do
    s=${p%%:*}
    [ -f "$state/copied.$s" ] || continue
    { sets_of "$s"; safety_of "$s"; } | grep -F -x -f "$state/copied.$s" > "$state/copied.$s.new" || :
    mv "$state/copied.$s.new" "$state/copied.$s" || die "cannot write $state/copied.$s"
  done
}

copy_sets() { # copy_sets <store>: the names of the store's sets in the copy, oldest first -> $names
  out=$(restic_run snapshots --json --tag "$1" --host "$host" 2>&1) \
    || die "cannot list the sets of $1 in $copy_to: $(copy_why "$out")"
  # shellcheck disable=SC2034 # restore_find and list (backup.sh) read names
  names=$(printf '%s\n' "$out" | grep -o '"paths":\["[^"]*"\]' \
    | sed -n "s|^\"paths\":\[\"$dir/$1/\(\(before-restore-\)\{0,1\}[0-9]\{8\}T[0-9]\{6\}Z\)\"\]$|\1|p" | sort -u)
}

# Where fetch_set <store> <name> puts the set.
copy_fetched_dir() { printf '%s' "$dir/$1/.fetch-$$$dir/$1/$2"; }

fetch_set() { # fetch_set <store> <name>: restore that set from the copy (copy_ready open first)
  t=$dir/$1/.fetch-$$
  rm -rf "$t" || die "cannot remove $t"
  mkdir -p "$t" || die "cannot create $t"
  at_exit "rm -rf '$t'"
  out=$(restic_run restore latest --tag "$1" --host "$host" --path "$dir/$1/$2" --target "$t" 2>&1) \
    || die "cannot fetch the set $1/$2 from $copy_to: $(copy_why "$out")"
  [ -d "$(copy_fetched_dir "$1" "$2")" ] || die "the copy at $copy_to has no set $1/$2 of host $host"
  say "copy: fetched $1/$2 from $copy_to"
}

# ---- checks of the copy ----------------------------------------------------
# copy_check: a small test set is written, read back and compared; then deleting it must be
# refused, which proves the login write-only; then the read check of the copy (read_copy). The
# test set stays (the storage side's rotation removes it, tag copy-check).
copy_check() {
  lock
  copy_ready init
  t=$(mktemp -d "$state/copy-check.XXXXXX") || die "cannot create a folder in $state"
  at_exit "rm -rf '$t'"
  mkdir "$t/set" || die "cannot create $t/set"
  head -c 65536 /dev/urandom > "$t/set/test" || die "cannot write the test set"
  out=$(restic_run backup --tag copy-check --host "$host" "$t/set" 2>&1) || die "the test copy failed: $(copy_why "$out")"
  id=$(printf '%s\n' "$out" | sed -n 's/^snapshot \([0-9a-f]*\) saved$/\1/p')
  [ -n "$id" ] || die "restic saved no snapshot of the test set: $(copy_why "$out")"
  out=$(restic_run restore "$id" --target "$t/back" 2>&1) || die "the test set cannot be read back: $(copy_why "$out")"
  cmp -s "$t/set/test" "$t/back$t/set/test" || die "the test set read back from $copy_to differs from what was written"
  say "copy-check: the test set $id was written and read back"
  case "$copy_to" in
    /*) say "copy-check: $copy_to is a local folder (for tests only): the delete check is skipped" ;;
    *) restic_run forget "$id" >/dev/null 2>&1 || :
       # A refused forget can leave its lock behind (restic stops at the refusal); unlock removes
       # stale locks of this host only.
       restic_run unlock >/dev/null 2>&1 || :
       restic_run cat snapshot "$id" >/dev/null 2>&1 \
         || die "the login BACKUP_COPY_LOGIN could delete the test set: the copy must be write-only for this server (rest-server --append-only, docs/how-to/backups.md)"
       say "copy-check: deleting it was refused: the copy is write-only for this server" ;;
  esac
  read_copy
  say OK
}

copy_verify() { lock; copy_ready open; read_copy; }

# read_copy: restic check of the copy, reading BACKUP_COPY_READ of its data, so it is known to read
# back. Its result is the health's "check of the copy", from copy-verify and copy-check alike.
read_copy() {
  if [ "$copy_read" = 0 ]; then set --; else set -- --read-data-subset "$copy_read"; fi
  if ! out=$(restic_run check "$@" 2>&1); then
    printf 'the check of the copy at %s failed: %s\n' "$copy_to" "$(copy_why "$out")" > "$errfile"
    result copy-verify failed
    die "$(cat "$errfile")"
  fi
  result copy-verify ok
  say "copy-verify: $copy_to OK: the structure$([ "$copy_read" = 0 ] || printf ' and %s of the data' "$copy_read") read back without errors"
}
