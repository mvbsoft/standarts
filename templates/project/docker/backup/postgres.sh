# project template 1.0.0 — the backup service (standard OPS-01); sourced by backup.sh.
# The PostgreSQL module: an example of a module, not the only kind. Another store gets a module of
# its own written to the same interface (the header of backup.sh, docs/how-to/backups.md).
# Needs PostgreSQL 15 or later: the backup role's password goes to the server through psql's
# \getenv (psql 15+), so it is never on a command line, and the role's rights are
# pg_read_all_data (14+). The tools are those of this image, the same version as the db service
# (the standard's catalog/README.md, Backups).
# Settings of the store <s> (the compose service of the database), BACKUP_<S>_<NAME>:
#   HOST (default: the service name), PORT (5432), DATABASE (postgres): the working database;
#   USER, PASSWORD: the read-only role the dumps run as, never a superuser or a role that owns
#     database objects (the module sets its password). Before each backup the module creates the
#     role if it is missing and keeps its rights: pg_read_all_data, BYPASSRLS when a table uses
#     row-level security, SELECT on every large object (before PostgreSQL 19 pg_read_all_data does
#     not cover them);
#   ADMIN_USER (postgres), ADMIN_PASSWORD: the superuser (the db service's POSTGRES_* values), for
#     those rights and for restore.
# A set: globals.sql (roles, without passwords), database.dump (pg_dump -Fc --create: the database
# with its settings and privileges), and in the manifest the row count of every table, the number
# of large objects, the roles and the settings, all read in the snapshot the dump was made in
# (globals.sql is dumped after it and checked against the roles and settings).
#
# Usage:   sourced by backup.sh for each store whose module is postgres (BACKUP_STORES=db:postgres).
#          The interface is postgres_backup, _check, _drill, _restore and _describe; pg_* and
#          psql_q are its helpers. They run in backup.sh's jobs and in $( ), where -e is off, so
#          every step ends in || die.
# Writes:  the set's files; the drill's server in /drill/<store>; on restore the working database;
#          exports the libpq PG* variables.
# Takes from backup.sh: say, die, at_exit, store_var, compare_facts.
# shellcheck shell=sh disable=SC2154 # dir, state, stores and the settings come from backup.sh

# ---- connections -----------------------------------------------------------
pg_conn() { # pg_conn <store> ro|admin: the libpq variables for the working database
  PGHOST=$(store_var "$1" HOST) PGPORT=$(store_var "$1" PORT) PGDATABASE=$(store_var "$1" DATABASE)
  PGHOST=${PGHOST:-$1} PGPORT=${PGPORT:-5432} PGDATABASE=${PGDATABASE:-postgres}
  if [ "$2" = admin ]; then
    PGUSER=$(store_var "$1" ADMIN_USER) PGPASSWORD=$(store_var "$1" ADMIN_PASSWORD)
    PGUSER=${PGUSER:-postgres}
    [ -n "$PGPASSWORD" ] || die "$1: BACKUP_$(printf '%s' "$1" | tr 'a-z-' 'A-Z_')_ADMIN_PASSWORD is empty"
  else
    PGUSER=$(store_var "$1" USER) PGPASSWORD=$(store_var "$1" PASSWORD)
    [ -n "$PGUSER" ] && [ -n "$PGPASSWORD" ] \
      || die "$1: BACKUP_$(printf '%s' "$1" | tr 'a-z-' 'A-Z_')_USER or _PASSWORD is empty (the read-only backup role)"
  fi
  export PGHOST PGPORT PGDATABASE PGUSER PGPASSWORD PGCONNECT_TIMEOUT=10 PGAPPNAME=backup
}
pg_drill_conn() { # the libpq variables for the drill's server of store $1
  PGHOST=/drill/$1/sock PGPORT=5432 PGDATABASE=postgres PGUSER=$(store_var "$1" ADMIN_USER)
  PGUSER=${PGUSER:-postgres}
  export PGHOST PGPORT PGDATABASE PGUSER
  unset PGPASSWORD
}
pg_why() { # the first error line of $1
  printf '%s\n' "$1" | grep -m 1 -E 'FATAL|ERROR|error|could not|failed' || printf '%s\n' "$1" | tail -n 1
}
psql_q() { psql -X -q -At -v ON_ERROR_STOP=1 "$@"; }

postgres_describe() { # the database a restore replaces: its name, then its host
  d=$(store_var "$1" DATABASE) h=$(store_var "$1" HOST)
  printf '%s\n%s\n' "${d:-postgres}" "${h:-$1}"
}

# ---- the backup role and the facts -----------------------------------------
pg_prepare_role() { # with the superuser: the backup role exists, can log in and has its rights
  role=$(store_var "$1" USER)
  k=BACKUP_$(printf '%s' "$1" | tr 'a-z-' 'A-Z_')
  # The module sets this role's password: on the superuser it would lock the owner out.
  [ "$role" != "$PGUSER" ] || die "$1: ${k}_USER must not be ${k}_ADMIN_USER"
  # Nor on a role that owns a database or tables (the application's role): it is not read-only,
  # and its password is the application's.
  out=$(psql_q -v u="$role" 2>&1 <<'SQL'
SELECT r.rolsuper, EXISTS (SELECT FROM pg_database WHERE datdba = r.oid) OR EXISTS (SELECT FROM pg_class WHERE relowner = r.oid)
  FROM pg_roles r WHERE r.rolname = :'u';
SQL
  ) || die "$1: cannot read the backup role $role as $PGUSER: $(pg_why "$out")"
  case "$out" in
    't|'*) die "$1: ${k}_USER $role is a superuser: the backup needs its own read-only role" ;;
    *'|t') die "$1: ${k}_USER $role owns database objects: the backup needs its own read-only role" ;;
  esac
  out=$(psql_q -v u="$role" 2>&1 <<'SQL'
SELECT format('CREATE ROLE %I LOGIN', :'u') WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'u') \gexec
SELECT format('GRANT pg_read_all_data TO %I', :'u') WHERE NOT pg_has_role(:'u', 'pg_read_all_data', 'MEMBER') \gexec
SELECT format('ALTER ROLE %I BYPASSRLS', :'u')
  WHERE EXISTS (SELECT FROM pg_class WHERE relrowsecurity) AND NOT (SELECT rolbypassrls FROM pg_roles WHERE rolname = :'u') \gexec
SELECT format('GRANT SELECT ON LARGE OBJECT %s TO %I', m.oid, :'u') FROM pg_largeobject_metadata m
  WHERE NOT EXISTS (SELECT FROM aclexplode(coalesce(m.lomacl, acldefault('L', m.lomowner))) a
    WHERE a.grantee = (SELECT oid FROM pg_roles WHERE rolname = :'u') AND a.privilege_type = 'SELECT') \gexec
SQL
  ) || die "$1: cannot prepare the backup role $role as $PGUSER: $(pg_why "$out")"
  if ! PGUSER=$role PGPASSWORD=$(store_var "$1" PASSWORD) psql_q -c 'SELECT 1' >/dev/null 2>&1; then
    # The password goes through the environment, not the command line (\getenv, psql 15+).
    out=$(BACKUP_ROLE_PASSWORD=$(store_var "$1" PASSWORD) psql_q -v u="$role" 2>&1 <<'SQL'
\getenv p BACKUP_ROLE_PASSWORD
SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', :'u', :'p') \gexec
SQL
    ) || die "$1: cannot set the password of the backup role $role: $(pg_why "$out")"
  fi
}

pg_facts() { # the manifest lines of the connected database; $1: the snapshot to read them in
  { [ -z "${1:-}" ] || printf "BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;\nSET TRANSACTION SNAPSHOT '%s';\n" "$1"
    cat <<'SQL'
SELECT format('SELECT %L || '' '' || count(*) FROM %I.%I', 'rows ' || format('%I.%I', n.nspname, c.relname), n.nspname, c.relname)
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.relkind = 'r' AND n.nspname <> 'information_schema' AND n.nspname !~ '^pg_'
  ORDER BY n.nspname, c.relname \gexec
SELECT 'largeobjects ' || count(*) FROM pg_largeobject_metadata;
SQL
    pg_role_sql
    [ -z "${1:-}" ] || echo 'COMMIT;'
  } | psql_q
}
pg_role_sql() { # the queries of the manifest's role and setting lines
  cat <<'SQL'
SELECT 'role ' || rolname FROM pg_roles WHERE rolname !~ '^pg_' ORDER BY 1;
SELECT 'setting ' || coalesce(r.rolname, '-') || ' ' || c
  FROM pg_db_role_setting s LEFT JOIN pg_roles r ON r.oid = s.setrole, unnest(s.setconfig) c
  WHERE s.setdatabase IN (0, (SELECT oid FROM pg_database WHERE datname = current_database())) ORDER BY 1;
SQL
}

pg_globals() { # pg_globals <store> <globals.sql>: the roles; only "already exists" errors are expected
  out=$(psql -X -q -d template1 -f "$2" 2>&1 >/dev/null) || die "$1: the roles of the set did not restore: $(pg_why "$out")"
  bad=$(printf '%s\n' "$out" | grep -E 'ERROR|FATAL' | grep -v 'already exists' || :)
  [ -z "$bad" ] || die "$1: the roles of the set did not restore: $(printf '%s\n' "$bad" | head -n 1)"
}

# ---- backup ----------------------------------------------------------------
# postgres_backup <store> <dir>: prepare the backup role as the superuser, then dump as that role;
# once more when a role or a role setting changed meanwhile.
postgres_backup() {
  pg_conn "$1" admin
  pg_prepare_role "$1"
  pg_conn "$1" ro
  pg_dump_set "$1" "$2"
  pg_same_roles "$1" "$2" && return 0
  say "backup: $1: a role or role setting changed during the backup: once more"
  pg_dump_set "$1" "$2"
  pg_same_roles "$1" "$2" || die "$1: the roles or role settings changed during the backup twice: back up again later"
}

# globals.sql cannot be read in the snapshot (pg_dumpall has no --snapshot): it is dumped after the
# snapshot, and the roles and settings read now must still be those of the manifest.
pg_same_roles() { # pg_same_roles <store> <dir>
  out=$(pg_role_sql | psql_q 2>&1) || die "$1: cannot read the roles: $(pg_why "$out")"
  [ "$out" = "$(grep -e '^role ' -e '^setting ' "$2/facts")" ]
}

pg_dump_set() { # pg_dump_set <store> <dir>: database.dump and facts in one snapshot, then globals.sql
  # One session exports a snapshot and holds it open; the dump and the row counts both read it, so
  # the manifest matches the dump while the database is in use.
  w=$(mktemp -d /tmp/backup-snapshot.XXXXXX) || die "$1: cannot create a temporary folder"
  at_exit "rm -rf '$w'"
  mkfifo "$w/in" || die "$1: cannot create $w/in"
  # A write to the fifo after the session ended must fail (|| :), not end the job with SIGPIPE.
  trap '' PIPE
  psql_q < "$w/in" > "$w/out" 2> "$w/err" &
  holder=$!
  at_exit "kill $holder 2>/dev/null || :"
  exec 3> "$w/in"
  printf 'BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;\nSELECT pg_export_snapshot();\n' >&3 || :
  i=0
  until snap=$(head -n 1 "$w/out") && [ -n "$snap" ]; do
    kill -0 "$holder" 2>/dev/null || die "$1: cannot connect as $PGUSER: $(pg_why "$(cat "$w/err")")"
    i=$((i + 1))
    [ "$i" -lt 300 ] || die "$1: no snapshot after 60 seconds"
    sleep 0.2
  done
  out=$(pg_dump -Fc --create --snapshot="$snap" -f "$2/database.dump" 2>&1) || die "$1: pg_dump failed: $(pg_why "$out")"
  out=$(pg_facts "$snap" 2>&1 > "$2/facts") || die "$1: cannot count the rows: $(pg_why "$out")"
  printf 'COMMIT;\n' >&3 || :
  exec 3>&-
  wait "$holder" || die "$1: the snapshot session failed: $(pg_why "$(cat "$w/err")")"
  out=$(pg_dumpall --globals-only --no-role-passwords -l "$PGDATABASE" -f "$2/globals.sql" 2>&1) \
    || die "$1: pg_dumpall failed: $(pg_why "$out")"
}

# postgres_check <store> <dir>: the dump reads back (pg_restore --list) and globals.sql has roles.
postgres_check() {
  out=$(pg_restore --list "$2/database.dump" 2>&1 >/dev/null) || die "$1: pg_restore cannot read the dump: $(pg_why "$out")"
  grep -q '^CREATE ROLE ' "$2/globals.sql" || die "$1: globals.sql has no roles"
}

# ---- drill and restore -----------------------------------------------------
# pg_drill_stop <dir>: stop the drill's server in <dir> if it runs, and remove <dir>.
pg_drill_stop() {
  [ ! -f "$1/data/postmaster.pid" ] || pg_ctl -D "$1/data" -m fast -w stop >/dev/null 2>&1 || :
  rm -rf "$1"
}

postgres_drill() { # a temporary server of this image's version on /drill, on a unix socket only
  w=/drill/$1
  pg_drill_stop "$w"
  mkdir -p "$w/sock" || die "$1: cannot create $w/sock"
  at_exit "pg_drill_stop '$w'"
  pg_drill_conn "$1"
  out=$(initdb -D "$w/data" -U "$PGUSER" -A trust --no-sync --no-instructions 2>&1) \
    || die "$1: initdb for the drill failed: $(pg_why "$out")"
  printf "listen_addresses = ''\nunix_socket_directories = '%s'\nfsync = off\n" "$w/sock" >> "$w/data/postgresql.conf" \
    || die "$1: cannot write the drill's postgresql.conf"
  pg_ctl -D "$w/data" -l "$w/log" -w -s start >/dev/null 2>&1 || die "$1: the drill's server did not start: $(tail -n 2 "$w/log")"
  pg_globals "$1" "$2/globals.sql"
  out=$(pg_restore -d template1 --create --clean --if-exists --exit-on-error "$2/database.dump" 2>&1) \
    || die "$1: pg_restore into the drill's server failed: $(pg_why "$out")"
  db=$(store_var "$1" DATABASE)
  out=$(PGDATABASE=${db:-postgres} pg_facts 2>&1 > "$w/facts") || die "$1: cannot count the restored rows: $(pg_why "$out")"
  compare_facts "$2" "$w/facts"
  pg_drill_stop "$w"
}

pg_connections() { # pg_connections <database> true|false: allow or refuse new connections
  psql_q -v d="$1" -v a="$2" <<'SQL'
SELECT format('ALTER DATABASE %I ALLOW_CONNECTIONS %s', :'d', :'a') FROM pg_database WHERE datname = :'d' \gexec
SQL
}

postgres_restore() { # into the working database: drop it, create it from the dump, compare
  pg_conn "$1" admin
  db=$PGDATABASE
  export PGDATABASE=template1
  pg_globals "$1" "$2/globals.sql"
  # No new connections while it is replaced; the end of the job allows them again in any case.
  at_exit "pg_connections '$db' true >/dev/null 2>&1 || :"
  out=$(pg_connections "$db" false 2>&1) || die "$1: cannot close $db to new connections: $(pg_why "$out")"
  out=$(echo "SELECT count(pg_terminate_backend(pid)) FROM pg_stat_activity WHERE datname = :'d' AND pid <> pg_backend_pid();" \
    | psql_q -v d="$db" 2>&1) \
    || die "$1: cannot close the connections to $db: $(pg_why "$out")"
  out=$(pg_restore -d template1 --create --clean --if-exists --exit-on-error "$2/database.dump" 2>&1) \
    || die "$1: pg_restore into $db failed: $(pg_why "$out") (the database may be incomplete: run the same restore again with NO_SAFETY=1, so that the safety set made before this one stays)"
  f=$(mktemp /tmp/backup-facts.XXXXXX) || die "$1: cannot create a temporary file"
  at_exit "rm -f '$f' '$f'.*"
  out=$(PGDATABASE=$db pg_facts 2>&1 > "$f") || die "$1: cannot count the restored rows: $(pg_why "$out")"
  # The working server may have more roles and role settings than the set; the set's must be there.
  compare_facts "$2" "$f" "role setting"
}
