#!/bin/sh
# project template 1.0.0 — from the standard's templates/project; change it there, not here.
#
# The steps behind the Makefile targets (standard ENV-04, ENV-05, ENV-09).
#
# Usage:   sh scripts/project.sh <step> [<argument>…]: the Makefile runs it (P := sh
#          scripts/project.sh); the steps are the case in main, at the bottom.
# Reads:   the Makefile settings, through the environment: IMAGES, APP, MIGRATE, SEED, RUN, LINT,
#          TEST, E2E, SECRETS, SECURITY, FIX, MUTATION, MUTATION_DIFF, DOCKERFILE_CHECK,
#          STAGE_BRANCH, PROD_BRANCH, NETWORKS, KEEP_IMAGES, BUILD_SECRETS; the make arguments
#          that count only on make's command line: DEV_NAME for NAME, ARG_S, ARG_SET, ARG_FROM,
#          ARG_NO_SAFETY, ARG_CONFIRM, ARG_RISK, and MAKE_PID (that make); ROLLBACK (make rollback) and
#          CHECK_DETAIL (a group target) from this script's own make runs; .env: PROJECT_ENV,
#          PROJECT_DIR, DEV_SUFFIX, LOG_ARCHIVE_DIR, DISK_RESERVE, DOCKER_GID; .deploy/history.
# Writes:  .env (make bootstrap), .deploy/ (history, lock), build/image-scan/, the log archive,
#          and the images, containers, volumes and networks of this clone's stack.
# Output:  what a step does on stdout ("<step>: …", "OK: …", "WARNING: …"); errors on stderr as
#          "ERROR: …".
# Exit:    0 ok; 1 failure (die); 130 interrupted (INT, TERM, HUP); else the status of a command
#          that failed under set -e (a check's own command, git, docker).
# Shell:   POSIX sh (dash, BusyBox ash, bash as sh); needs git, docker, make and the POSIX tools.
#          set -e is only a net: every command whose failure matters ends in || die "…".
set -eu

# ---- settings and globals --------------------------------------------------

cd "$(dirname "$0")/.."
# The physical path of the clone (git resolves symbolic links), the one make bootstrap writes as
# PROJECT_DIR and the dev container mounts: a path made here is valid in the container too.
top=$(git rev-parse --show-toplevel)
cd "$top"

# sh has no local variables: every name is global. These carry a value from one function to
# another; every other name is scratch, which any call to another function may overwrite.
#   top                     the clone's physical path (cmd_bootstrap sets it again, from git)
#   ctx arc scan_dir sum_dir temporary files and folders, removed by on_exit
#   stopped                 the make target that starts a stopped application (cmd_restore)
#   locked                  1 while this script holds .deploy/lock (lock_take)
#   name cfg                the compose project and the rendered compose file (env_need)
#   own built_tag ownrefs   the own images of the checked-out commit (image_build)
#   reserve r               DISK_RESERVE as written and in KiB (disk_reserve)
#   f                       the compose file of this clone (cmd_backup, for backup_status)

# ---- exit handling ---------------------------------------------------------

# What a step leaves behind is removed however the script ends: the steps set these variables, and
# INT, TERM and HUP end the script through exit, because dash and BusyBox sh do not run the EXIT
# trap when a signal ends them.
ctx='' arc='' scan_dir='' stopped='' locked='' sum_dir=''
on_exit() {
  [ -z "$ctx" ] || rm -rf "$ctx"
  [ -z "$arc" ] || rm -f "$arc"
  [ -z "$scan_dir" ] || { rm -rf "$scan_dir"; rmdir build 2>/dev/null || :; }
  [ -z "$stopped" ] || say "restore: the application is stopped: $stopped starts it again"
  [ -z "$locked" ] || rm -rf .deploy/lock
  [ -z "$sum_dir" ] || rm -rf "$sum_dir"
}
trap on_exit EXIT
trap 'exit 130' INT TERM HUP

# ---- primitives ------------------------------------------------------------

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# A value of .env as Compose reads it: the last line of the variable; a value in quotes without
# them and without what follows them; any other value without a comment after a blank and without
# the blanks around it. The same function is in scripts/tuning-check.sh.
envvar() {
  [ ! -f .env ] || sed -n "s/^$1=//p" .env | tail -n 1 | tr -d '\r' | sed \
    -e "s/^\"\([^\"]*\)\".*/\1/;t" -e "s/^'\([^']*\)'.*/\1/;t" \
    -e 's/[[:space:]]#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}
project_env() { envvar PROJECT_ENV; }
sha() { git rev-parse HEAD; }
# The image tag of a commit: its tree hash, equal for commits with the same content (a merge or a
# squash into the prod branch, a re-deploy, a rollback), so an image built once on a machine fits
# them all there.
tag() { git rev-parse "${1:-HEAD}^{tree}"; }
file_of() { printf 'docker-compose.%s.yml' "$1"; }
branch_of() { if [ "$1" = stage ]; then printf '%s' "$STAGE_BRANCH"; else printf '%s' "$PROD_BRANCH"; fi; }
name_of() { sed -n "s/^name: *[\"']\{0,1\}\([^\"' #]*\).*/\1/p" "$1"; }  # the name: value without quotes or comment
suffix_of() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9\n' '-'; }  # a DEV_SUFFIX without its -

kib() { # 2G, 500M, 64K, 1T or 0 -> KiB (the units of DISK_RESERVE, as the backup service reads it)
  n=${1%[KMGT]}
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  case "$1" in *K) echo "$n" ;; *M) echo $((n * 1024)) ;; *G) echo $((n * 1048576)) ;; *T) echo $((n * 1073741824)) ;;
    0) echo 0 ;; *) return 1 ;; esac
}
human() { # KiB -> 1.5G, 300M, 12K
  awk -v k="$1" 'BEGIN { split("K M G T", u); i = 1; while (k >= 1024 && i < 4) { k /= 1024; i++ }
    printf((k < 10 && i > 1) ? "%.1f%s\n" : "%d%s\n", k, u[i]) }'
}

# ---- env: the environment of this clone ------------------------------------

env_private() { # env_private <file>: refuse a file of secrets that other users of this machine can read or write
  # shellcheck disable=SC2012 # ls -l is the POSIX way to read the mode of one file
  m=$(ls -ld "$1" | cut -c1-10)
  case "$m" in ????------) ;; *) die "$1 can be read or written by other users of this machine ($m): chmod 600 $1" ;; esac
}

# env_socket_group <env>
#   The socket proxy of the status service runs in the group DOCKER_GID of .env; one that is not
#   the group of /var/run/docker.sock here cannot read the socket, so the proxy and the status
#   service would not start. Only the commands that start or recreate the proxy check it (make
#   stage, prod, restart, rollback), before anything changes; backups, a restore and make images
#   never depend on monitoring. A file without the proxy has nothing to check.
#   Returns:   0; dies on a refusal.
env_socket_group() {
  grep -q '^  status-proxy:' "$(file_of "$1")" 2>/dev/null || return 0
  g=$(stat -c %g /var/run/docker.sock 2>/dev/null) \
    || die "/var/run/docker.sock cannot be read here, but the socket proxy of the status service mounts it; nothing was changed"
  [ "$(envvar DOCKER_GID)" = "$g" ] \
    || die "DOCKER_GID is '$(envvar DOCKER_GID)' in .env, but /var/run/docker.sock belongs to group $g: set DOCKER_GID=$g (the socket proxy of the status service reads the socket as that group); nothing was changed"
}

# env_others_of <project>
#   The other folders whose containers (stopped and one-off ones too: Compose starts a stopped one
#   again, and a one-off one uses the volumes) belong to the compose project <project>, from the
#   folder label Compose gives each container. A folder is compared by its physical path, as this
#   script runs Compose from it. Volumes carry no folder: the data of a copy whose containers were
#   removed is not seen here.
#   Globals:   reads top.
#   Outputs:   the folders on stdout, each followed by a blank; nothing when there is none.
#   Note:      runs in $( ); a failing docker gives no folder (|| :), so it never fails.
env_others_of() {
  docker ps -a --filter "label=com.docker.compose.project=$1" \
      --format '{{.Label "com.docker.compose.project.working_dir"}}' | sort -u \
    | while read -r wd; do (cd "$wd" 2>/dev/null && pwd -P) || printf '%s\n' "$wd"; done \
    | sort -u | grep -vxF "$top" | sed 's/$/ /' | tr -d '\n' || :
}

# env_dev_secrets
#   The dev build gets every build secret too (BUILD_SECRETS), from the file named there: refuse a
#   malformed entry, a missing file, or a docker-compose.dev.yml that does not pass it on.
#   Globals:   reads cfg (env_need), top, BUILD_SECRETS.
#   Returns:   0; dies on a refusal (nothing built).
env_dev_secrets() {
  for s in ${BUILD_SECRETS:-}; do
    case "$s" in ?*=?*) ;; *) die "BUILD_SECRETS in the Makefile settings has $s, not <id>=<file>; nothing was built" ;; esac
    [ -f "${s#*=}" ] || die "the build secret ${s%%=*} needs the file ${s#*=} (BUILD_SECRETS in the Makefile settings), which is not in this folder; nothing was built"
    if ! printf '%s\n' "$cfg" | grep -qxF "    file: $top/${s#*=}" || ! printf '%s\n' "$cfg" | grep -qxF "        - source: ${s%%=*}"; then
      die "BUILD_SECRETS has ${s%%=*}=${s#*=}, which docker-compose.dev.yml does not give the dev build:" \
        "add secrets: [${s%%=*}] to build: of dev and ${s%%=*}: {file: ${s#*=}} to the top-level secrets: (the comments there show both)"
    fi
  done
}

# env_typed <word>
#   True when <word> is a word of the command line of the make that runs this script (MAKE_PID,
#   from the Makefile). GNU make also counts the variables of an exported MAKEFLAGS or GNUMAKEFLAGS,
#   and those a parent make passes down, as command-line ones; ps shows what was typed.
#   Returns:   0 typed; 1 not typed, or no such make.
#   Note:      runs in a condition.
env_typed() {
  a=$(ps -ww -o args= -p "${MAKE_PID:-0}" 2>/dev/null) || return 1
  case " $a " in *" $1 "*) return 0 ;; esac
  return 1
}

# risk_ask <what was found> <what can go wrong>
#   An estimate (free space, a backup before a migration) found a risk. A command stops by itself
#   only on what is certain; here the person decides: in a terminal a y/N question, without one
#   only RISK=yes typed on the command line of this make goes on.
#   Outputs:   a WARNING line on stdout.
#   Returns:   0 to go on; dies otherwise, before what the warning is about.
risk_ask() {
  say "WARNING: $1; if you go on: $2"
  if [ -t 0 ]; then
    printf 'Go on anyway? [y/N] ' >&2
    answer=''
    read -r answer || :
    case "$answer" in y|yes) return 0 ;; esac
    die "you answered '$answer', not y: stopped here"
  fi
  [ "${ARG_RISK:-}" = yes ] \
    || die "$1: stopped here; to go on anyway, add RISK=yes to the make command line"
  env_typed RISK=yes || die "RISK=yes is not on the command line of this make: it came from MAKEFLAGS or" \
    "GNUMAKEFLAGS of the environment, or from a make that runs this one, which accept no risk: stopped here"
  say "RISK=yes: going on"
}

# risk_pass: RISK=yes for a make this script starts (make stage, prod, rollback run their steps in
# one), when this make's own command line has it; else nothing.
risk_pass() { [ "${ARG_RISK:-}" != yes ] || ! env_typed RISK=yes || printf 'RISK=yes'; }

# env_need <env>
#   Refuse to run the targets of another environment in this clone (ENV-04). On a server also a
#   value still change-me and a file of secrets other users can read; anywhere a second copy of the
#   stack on this machine; in dev a build secret the dev build lacks.
#   Globals:   sets name (the compose project; empty when the file does not render) and cfg (the
#              rendered file), read by cmd_deploy and env_dev_secrets.
#   Returns:   0; dies on a refusal (nothing changed).
env_need() {
  [ -f .env ] || die "no .env: on a server, create it from .env.example (docs/how-to/operations.md); in dev, run make dev"
  [ "$(project_env)" = "$1" ] || die "this clone is PROJECT_ENV=$(project_env) in .env; make $1 runs only in a clone with PROJECT_ENV=$1"
  case "$1" in
    dev) here=$(git rev-parse --path-format=absolute --show-toplevel)
      [ "$(envvar PROJECT_DIR)" = "$here" ] \
        || die "PROJECT_DIR in .env is '$(envvar PROJECT_DIR)', not this folder (a .env from elsewhere?): set PROJECT_DIR=$here in .env; HOST_UID and HOST_GID are the ids of your user (id -u, id -g)" ;;
    *) ! grep -q '^[^#]*change-me' .env || die "a value in .env is still change-me: set it (docs/how-to/operations.md, the first server)"
      # The secrets of a server: only its owner reads them.
      env_private .env
      for s in ${BUILD_SECRETS:-}; do [ ! -f "${s#*=}" ] || env_private "${s#*=}"; done ;;
  esac
  # The rendered file, for the name of the project and the build secrets of dev. A file that does
  # not render changes nothing: the step that uses it fails on its own and names the variable.
  name=''
  cfg=$(IMAGE_TAG=$(tag) docker compose -f "$(file_of "$1")" config 2>/dev/null) || return 0
  name=$(printf '%s\n' "$cfg" | sed -n 's/^name: //p')
  if [ "$1" = dev ]; then
    others=$(env_others_of "$name")
    [ -z "$others" ] || die "the dev project $name also has containers from $others(stopped ones count):" \
      "two clones of one dev project take over each other's containers and share its database." \
      "Stop it there (make down in that folder, or docker compose -p $name down when it is gone)," \
      "or give this clone a dev stack of its own:" \
      "DEV_SUFFIX=-<n> and APP_PORT= (empty: a free port) in its .env, then make dev"
    env_dev_secrets
  else
    others=$(env_others_of "$name")
    [ -z "$others" ] || die "$name already runs from $others(its containers, stopped ones too, name that folder):" \
      "a second copy of $1 on this machine would take over its containers, volumes and data, so a machine" \
      "runs one copy of $1; nothing was changed. To run it from this folder instead, stop it in that folder" \
      "with docker compose -p $name down (the volumes stay, and this folder's make $1 uses them)"
  fi
}

# ---- dev: the dev container ------------------------------------------------

# dev_run <setting>
#   Run the project command held by the Makefile setting named <setting> (LINT, TEST, RUN, FIX, …)
#   in the dev container; MUTATION and MUTATION_DIFF in a one-off container of their own.
#   Returns:   the command's status.
dev_run() {
  # The setting named by $1: eval reads a variable whose name is in a variable.
  eval "c=\${$1-}"
  [ -n "$c" ] || die "this project has no $1 command (set $1 in the Makefile settings)"
  env_need dev
  # Quiet: a check's output, and the last line of it in a summary, are the command's own.
  docker compose --progress quiet -f docker-compose.dev.yml up -d --build --wait >/dev/null
  case "$1" in
    # Mutation testing: in a container of its own, from the dev image, with the limits MUTATION_CPUS
    # and MUTATION_MEM of .env; it is removed afterwards.
    MUTATION|MUTATION_DIFF) docker compose --progress quiet -f docker-compose.dev.yml --profile mutation \
        run --rm -T mutation sh -c "$c" ;;
    *) docker compose -f docker-compose.dev.yml exec -T dev sh -c "$c" ;;
  esac
}

# ---- disk ------------------------------------------------------------------

disk_reserve() { # sets reserve (DISK_RESERVE of .env, 2G when it is not set) and r (that in KiB)
  reserve=$(envvar DISK_RESERVE)
  reserve=${reserve:-2G}
  r=$(kib "$reserve") || die "DISK_RESERVE is '$reserve' in .env, not a size like 2G or 500M (or 0)"
}

# disk_space <env> [<commit>]
#   Warn and ask (risk_ask), before anything is built, pulled or replaced, when the disk where
#   Docker keeps the images has less free space than two times the own images (new versions built
#   next to the ones that run; each own image counts with its largest version on this machine)
#   plus DISK_RESERVE of .env. With <commit> (make restart, make rollback) only the own images of
#   that commit this machine lacks count, and with none missing nothing is checked. df reads it in
#   a container of an image of the file that this machine has, the others first, then the own
#   ones, until one has df: on Docker Desktop, and with the containerd image store, a df of
#   DockerRootDir on the host reads another disk.
#   Globals:   sets reserve, r (disk_reserve) and own (image_own).
#   Outputs:   a "space: …" line on stdout.
#   Returns:   0, also when it cannot measure (it says so) and when the space is short and the
#              person goes on (risk_ask); else dies.
disk_space() {
  disk_reserve
  f=$(file_of "$1")
  imgs=$(IMAGE_TAG=$(tag) docker compose -f "$f" config --images 2>/dev/null) || return 0
  own=$(image_own "$f")
  ownnames='' sum=0 ownlocal='' lacks=''
  for p in $own; do
    ownnames="$ownnames ${p#*=}"
    ownlocal="$ownlocal $(docker images --format '{{.Repository}}:{{.Tag}}' "${p#*=}" | head -n 1)"
    [ -z "${2:-}" ] || ! docker image inspect "${p#*=}:$(tag "$2")" >/dev/null 2>&1 || continue
    lacks=1
    big=0
    for s in $(docker images --format '{{.Size}}' "${p#*=}"); do
      # docker images prints decimal units (230MB, 1.64GB): the space the image takes on disk.
      k=$(printf '%s\n' "$s" | awk '{ n = $0 + 0; u = $0; sub(/^[0-9.]+/, "", u)
        m = u == "kB" ? 1e3 : u == "MB" ? 1e6 : u == "GB" ? 1e9 : u == "TB" ? 1e12 : 1; printf "%.0f\n", n * m / 1024 }')
      [ "$k" -le "$big" ] || big=$k
    done
    sum=$((sum + big))
  done
  [ -z "${2:-}" ] || [ -n "$lacks" ] \
    || { say "space: not checked: the own images of $2 are on this machine, so nothing is built"; return 0; }
  probes=''
  for i in $(printf '%s\n' "$imgs" | sort -u); do
    case "$ownnames " in *" ${i%%:*} "*) continue ;; esac
    ! docker image inspect "$i" >/dev/null 2>&1 || probes="$probes $i"
  done
  probes="$probes $ownlocal"
  case "$probes" in *[!' ']*) ;; *) probes='' ;; esac
  [ -n "$probes" ] || { say "space: not checked: no image of $f is on this machine yet (a first deploy replaces nothing)"; return 0; }
  have='' tried=''
  for i in $probes; do
    tried="$tried $i"
    have=$(docker run --rm --network none --entrypoint df "$i" -Pk / 2>/dev/null | awk 'NR == 2 {print $4}')
    case "$have" in ''|*[!0-9]*) have='' ;; *) break ;; esac
  done
  [ -n "$have" ] || { say "space: not checked: no image of $f on this machine has df (tried:$tried)"; return 0; }
  need=$((2 * sum + r))
  if [ "$have" -lt "$need" ]; then
    risk_ask "not enough free space where Docker keeps the images: need $(human "$need") (2 × $(human "$sum"), the own images, and DISK_RESERVE=$reserve), have $(human "$have")" \
      "a build or a pull may fill that disk, and a full disk stops every container that writes there, the database too; free some space first (docs/how-to/operations.md, a full disk)"
    return 0
  fi
  say "space: $(human "$have") free where Docker keeps the images (need $(human "$need"))"
}

# ---- lock ------------------------------------------------------------------

# lock_take <target>
#   One make stage, prod, rollback, restart, images or restore at a time in this clone: take
#   .deploy/lock, or take over one whose make no longer runs. on_exit removes it.
#   Globals:   sets locked=1.
#   Returns:   0 with the lock; dies when another make holds it (nothing changed); exit 130 on a
#              signal noted while the lock was taken.
lock_take() {
  mkdir -p .deploy
  n=0
  while :; do
    # INT, TERM or HUP between the mkdir and locked=1 would leave a lock without an owner that no
    # one removes: there a signal is only noted, and the script ends once locked is set.
    sig=''
    trap 'sig=1' INT TERM HUP
    if mkdir .deploy/lock 2>/dev/null; then locked=1; fi
    trap 'exit 130' INT TERM HUP
    [ -z "$sig" ] || exit 130
    [ -z "$locked" ] || break
    pid='' what=''
    { read -r pid what < .deploy/lock/owner; } 2>/dev/null || :
    # A lock whose make no longer runs is taken over; one waiter moves its owner file away and
    # checks that it moved that one, not a new one.
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null && mv .deploy/lock/owner ".deploy/lock/owner.$$" 2>/dev/null; then
      if [ "$(cut -d' ' -f1 ".deploy/lock/owner.$$")" = "$pid" ]; then rm -rf .deploy/lock
      else mv ".deploy/lock/owner.$$" .deploy/lock/owner; fi
      continue
    fi
    [ -n "$pid" ] || [ "$n" -ge 3 ] || { n=$((n + 1)); sleep 1; continue; }  # the other make is starting
    [ -n "$pid" ] || die ".deploy/lock has no owner: if no make stage, prod, rollback, restart, images or restore runs in this clone, remove .deploy/lock; nothing was changed"
    die "make $what (pid $pid) is running in this clone; nothing was changed: run make $1 again after it ends"
  done
  printf '%s %s\n' "$$" "$1" > .deploy/lock/owner
}

# ---- net: external networks ------------------------------------------------

net_create() { # create the external networks named in NETWORKS that this machine lacks
  for v in ${NETWORKS:-}; do
    n=$(envvar "$v")
    [ -n "$n" ] || die "$v is empty in .env: it names an external network (NETWORKS in the Makefile settings)"
    docker network inspect "$n" >/dev/null 2>&1 || docker network create "$n" >/dev/null
  done
}

# ---- image: the own images -------------------------------------------------

image_keep() { # the KEEP_IMAGES setting (5 when empty), refused unless a whole number of at least 1
  k=${KEEP_IMAGES:-5}
  case "$k" in *[!0-9]*) ;; *[1-9]*) printf '%s' "$k"; return 0 ;; esac
  die "KEEP_IMAGES=$k in the Makefile settings is not a whole number of at least 1"
}

# image_own <compose file>
#   The own images of the file (ENV-09): <repo> is the file's name: without -stage or -prod; the
#   file must have the image: line <repo>-<image>:${IMAGE_TAG:?} exactly. Read without .env, so it
#   is the same in dev and on a server. (config --images cannot be combined with
#   --no-interpolate: it fails on the variables in typed fields such as the limits.)
#   Outputs:   <image>=<repo>-<image>, one line per image in IMAGES.
#   Note:      runs in $( ): its die ends the substitution, and set -e then the caller.
image_own() {
  repo=$(name_of "$1")
  case "$repo" in *-stage) repo=${repo%-stage} ;; *-prod) repo=${repo%-prod} ;; esac
  names=$(docker compose -f "$1" --profile '*' config --no-interpolate) || die "$1 cannot be read (above)"
  names=$(printf '%s\n' "$names" | sed -n "s/^    image: [\"']\{0,1\}\([^\"']*\)[\"']\{0,1\}\$/\1/p")
  for i in $IMAGES; do
    printf '%s\n' "$names" | grep -qxF "$repo-$i:\${IMAGE_TAG:?}" \
      || die "$1 has no image $repo-$i:\${IMAGE_TAG:?} for $i in IMAGES (the Makefile settings)"
    printf '%s=%s\n' "$i" "$repo-$i"
  done
}

# image_build <compose file> [<end of the failure message>]
#   Build every own image of the checked-out commit that this machine lacks (ENV-09).
#   Globals:   sets own (<image>=<name> words), built_tag and ownrefs (<name>:<tag> words) for the
#              steps after it; ctx and arc while it builds (on_exit removes them).
#   Arguments: $2 ends every failure message (default: nothing was replaced).
#   Outputs:   "build: …" lines on stdout.
#   Returns:   0; dies on the first failure.
image_build() {
  own=$(image_own "$1")
  bc=$(sha) built_tag=$(tag)
  ownrefs='' todo=''
  for p in $own; do
    ownrefs="$ownrefs ${p#*=}:$built_tag"
    docker image inspect "${p#*=}:$built_tag" >/dev/null 2>&1 || todo="$todo $p"
  done
  [ -n "$todo" ] || return 0
  [ "${ROLLBACK:-}" != 1 ] || say "rollback: building the images of $bc again (they were pruned)"
  ! git ls-tree -r "$bc" | grep -q '^160000 ' \
    || die "commit $bc has git submodules: an image built from it would lack their files; nothing was built"
  # Build secrets (a private dependency's credentials): BuildKit mounts each file only into the
  # RUN steps that ask for it (RUN --mount=type=secret,id=<id>), so it never becomes part of the
  # image. The file path is relative to this folder, where docker build runs.
  secrets=''
  for s in ${BUILD_SECRETS:-}; do
    case "$s" in ?*=?*) ;; *) die "BUILD_SECRETS in the Makefile settings has $s, not <id>=<file>; ${2:-nothing was replaced}" ;; esac
    [ -f "${s#*=}" ] || die "the build secret ${s%%=*} needs the file ${s#*=} (BUILD_SECRETS in the Makefile settings), which is not in this folder; ${2:-nothing was replaced}"
    secrets="$secrets --secret id=${s%%=*},src=${s#*=}"
  done
  # The build context is the commit itself, unpacked so that .dockerignore applies: nothing
  # uncommitted, untracked, gitignored or dockerignored in this folder reaches the image. git archive
  # applies the line-ending settings of the machine; core.autocrlf=true would give the image CRLF
  # scripts that do not run. The archive goes to a file first: in a pipe, a git archive that fails
  # halfway would go unnoticed, and tar can unpack the part it got without an error.
  ctx=$(mktemp -d)
  arc=$(mktemp)
  git -c core.autocrlf=false -c core.eol=lf archive --format=tar -o "$arc" "$bc" \
    || die "git archive of commit $bc failed (above); ${2:-nothing was replaced}"
  tar -x -C "$ctx" -f "$arc" || die "unpacking commit $bc failed (above); ${2:-nothing was replaced}"
  for p in $todo; do
    i=${p%%=*} n=${p#*=}
    say "build: $n:$built_tag from commit $bc"
    s=$(date +%s)
    # shellcheck disable=SC2086 # one word per option
    docker build --target runtime $secrets -f "$ctx/docker/$i/Dockerfile" -t "$n:$built_tag" "$ctx" \
      || die "building $n for commit $bc failed (above); ${2:-nothing was replaced}"
    say "build: $n:$built_tag built in $(( $(date +%s) - s )) s"
  done
  rm -rf "$ctx" "$arc"
  ctx='' arc=''
}

# image_get <env>
#   The images of the checked-out commit: build the own ones this machine lacks, pull the others.
#   Globals:   sets own, built_tag, ownrefs (image_build).
#   Returns:   0; dies on a failure (nothing replaced).
image_get() {
  f=$(file_of "$1")
  imgs=$(IMAGE_TAG=$(tag) docker compose -f "$f" config --images) \
    || die "$f does not render with this .env (the error above names the variable); nothing was replaced"
  image_build "$f"
  # Sorted, so the first missing image named is always the same one.
  for img in $(printf '%s\n' "$imgs" | sort); do
    case " $ownrefs " in *" $img "*) continue ;; esac
    docker image inspect "$img" >/dev/null 2>&1 || docker pull --quiet "$img" >/dev/null \
      || die "pulling $img failed (above); nothing was replaced"
  done
}

# image_prune
#   Remove the own images of the commits not among the last KEEP_IMAGES deployed ones (ENV-09).
#   Outputs:   a "prune: …" line on stdout.
image_prune() {
  keep=$(image_keep) || exit 1
  # The trees of the last $keep distinct commits of .deploy/history, newest first, and of the
  # commit that runs now.
  keep_trees=" $(tag) $(awk '{ c[NR] = $2 } END { for (i = NR; i > 0; i--) print c[i] }' .deploy/history \
    | awk '!seen[$0]++' | head -n "$keep" | while read -r c; do git rev-parse -q --verify "$c^{tree}" || :; done \
    | tr '\n' ' ')"
  own=$(image_own "$(file_of "$(project_env)")")
  removed=0
  for p in $own; do
    # Only tags that are tree hashes: an image tagged by hand stays. docker rmi refuses an image a
    # container uses.
    for t in $(docker images --format '{{.Tag}}' "${p#*=}" | grep -xE '[0-9a-f]{40}|[0-9a-f]{64}' || :); do
      case "$keep_trees" in *" $t "*) continue ;; esac
      ! docker rmi "${p#*=}:$t" >/dev/null 2>&1 || removed=$((removed + 1))
    done
  done
  say "prune: removed $removed old images; the images of the last $keep deployed commits stay"
}

# ---- deploy: the steps of make stage and make prod -------------------------

# deploy_migrate [deploy]
#   In dev the migration command (make migrate); on a server only as a step of a deploy, after a
#   backup set when the file has the backup service and this clone deployed before (OPS-01); a
#   failed set, or only its copy, asks (risk_ask).
#   Returns:   0; the command's status in dev; dies when the migration fails on a server, or the
#              backup did and the person does not go on (nothing replaced).
deploy_migrate() {
  e=$(project_env)
  case "$e" in
    # A deploy runs it under the lock of the clone, after env_need and image_get; by hand it would
    # run beside a deploy, a rollback or a restore, or with an image this server has not built.
    stage|prod) [ "${1:-}" = deploy ] \
      || die "make migrate runs only in dev: on a server, make stage (make prod on prod) runs the migrations of the commit it deploys" ;;
  esac
  [ -n "${MIGRATE:-}" ] || return 0
  [ "${ROLLBACK:-}" != 1 ] || { say "migrate: skipped (rollback)"; return 0; }
  case "$e" in
    dev) docker compose -f docker-compose.dev.yml exec -T dev sh -c "$MIGRATE" ;;
    stage|prod)
      # A fresh set of the data the migration changes, but on the first deploy of this clone (no
      # .deploy/history). The service exits 3 when it refuses on the free space alone, 4 when only
      # the off-server copy failed.
      f=$(file_of "$e")
      if IMAGE_TAG=$(tag) docker compose -f "$f" config --services | grep -qx backup; then
        if [ -f .deploy/history ]; then
          say "backup: a set before the migration"
          rc=0
          backup_run "$f" backup || rc=$?
          # Refused on the free-space estimate alone (exit 3): on a yes the set is made anyway.
          if [ "$rc" = 3 ]; then
            risk_ask "the backup service found too little free space for the set before the migration (above)" \
              "what it says above"
            rc=0
            backup_run "$f" backup --risk || rc=$?
          fi
          case "$rc" in
            0) ;;
            4) risk_ask "the backup before the migration made the local set, but its off-server copy failed (above)" \
                 "the migration runs with a fresh set on this server only, none off the server" ;;
            *) risk_ask "the backup before the migration failed (above): no fresh set was made" \
                 "the migration runs without a fresh set, here or off the server; if it damages the data, only an older set can bring it back" ;;
          esac
        else say "backup: none before the migration: nothing was deployed from this clone yet"; fi
      fi
      say "migrate: $MIGRATE (image of $(sha))"
      # Past the image's ENTRYPOINT, which may be the server itself: compose run replaces only its
      # command. So the runtime image needs /bin/sh.
      IMAGE_TAG=$(tag) docker compose -f "$(file_of "$e")" run --rm --entrypoint sh "$APP" -c "$MIGRATE" \
        || die "the migration failed; the application was not replaced and its running version keeps running" ;;
    *) die "unknown PROJECT_ENV=$e in .env" ;;
  esac
}

# deploy_log_archive <env>
#   Before a deploy, a rollback or make restart replaces containers, the logs Docker holds of each
#   one it may replace (its configuration or its image changed, or the file no longer has its
#   service), stopped ones too, go to LOG_ARCHIVE_DIR/<UTC>-<service>.log of .env: Docker removes a
#   container's logs with it (OPS-03). Empty LOG_ARCHIVE_DIR: no archive. Nothing here removes an
#   archived file: the folder grows until its owner removes old ones.
#   Globals:   sets name; reserve, r (disk_reserve).
#   Outputs:   a "log-archive: <file>" line per file on stdout.
#   Returns:   0; dies when a file cannot be written, or the space is short and the person does not
#              go on (risk_ask); nothing replaced.
deploy_log_archive() {
  dir=$(envvar LOG_ARCHIVE_DIR)
  [ -n "$dir" ] || return 0
  f=$(file_of "$1")
  name=$(IMAGE_TAG=$(tag) docker compose -f "$f" config | sed -n 's/^name: //p')
  hashes=$(IMAGE_TAG=$(tag) docker compose -f "$f" config --hash '*')
  todo=''
  for id in $(docker ps -aq --filter "label=com.docker.compose.project=$name" --filter label=com.docker.compose.oneoff=False); do
    # shellcheck disable=SC2046 # one word per field
    set -- $(docker inspect -f '{{index .Config.Labels "com.docker.compose.service"}} {{index .Config.Labels "com.docker.compose.config-hash"}} {{index .Config.Labels "com.docker.compose.container-number"}} {{.Config.Image}} {{.Image}}' "$id")
    # Compose recreates a container whose configuration hash or image changed.
    if [ "$(printf '%s\n' "$hashes" | awk -v s="$1" '$1 == s {print $2}')" != "$2" ] \
        || [ "$(docker image inspect -f '{{.Id}}' "$4" 2>/dev/null)" != "$5" ]; then
      todo="$todo $id=$1$( [ "$3" = 1 ] || printf -- '-%s' "$3")"
    fi
  done
  [ -n "$todo" ] || return 0
  # The logs of the containers are for the owner only (a new folder 700, the files 600).
  umask 077
  mkdir -p "$dir"
  # Each container's logs are at most the 10 MB × 3 of its logging options.
  disk_reserve
  # shellcheck disable=SC2086 # one word per container
  n=$(printf '%s\n' $todo | wc -l)
  have=$(df -Pk "$dir" | awk 'NR == 2 {print $4}')
  need=$((n * 30720 + r))
  [ "$have" -ge "$need" ] || risk_ask "not enough free space for the log archive in $dir (LOG_ARCHIVE_DIR): need $(human "$need") (30M for the logs of each of $n containers, and DISK_RESERVE=$reserve), have $(human "$have")" \
    "the logs may fill that disk (old files of the archive are yours to remove), and a log file that cannot be written stops the command before anything is replaced"
  t=$(date -u +%Y%m%dT%H%M%SZ)
  for p in $todo; do
    docker logs --timestamps "${p%%=*}" > "$dir/$t-${p#*=}.log" 2>&1 \
      || die "saving the logs of ${p#*=} to $dir failed (above); nothing was replaced"
    say "log-archive: $dir/$t-${p#*=}.log"
  done
}

# deploy_up <env> [<message on failure>]
#   Start the stack of the checked-out commit and wait until it is healthy.
#   Outputs:   on a failure the state of the containers and the last logs of the failed ones.
#   Returns:   0, also with an unhealthy backup service (a WARNING); dies when another service
#              does not become healthy.
deploy_up() {
  f=$(file_of "$1")
  # Every service but backup must become healthy. An unhealthy backup service (a failed drill, an
  # old set) only warns: the release runs, and the backups need attention.
  svcs=$(IMAGE_TAG=$(tag) docker compose -f "$f" config --services)
  # shellcheck disable=SC2046 # one word per service
  if ! IMAGE_TAG=$(tag) docker compose -f "$f" up -d --wait --remove-orphans $(printf '%s\n' "$svcs" | grep -vx backup); then
    IMAGE_TAG=$(tag) docker compose -f "$f" ps --all
    for s in $(IMAGE_TAG=$(tag) docker compose -f "$f" ps --all --format '{{.Service}} {{.State}} {{.Health}}' \
        | awk '$2 != "running" || $3 == "unhealthy" {print $1}'); do
      IMAGE_TAG=$(tag) docker compose -f "$f" logs --tail 20 "$s"
    done
    die "${2:-a container did not become healthy; the previous containers are already replaced: run make rollback}"
  fi
  printf '%s\n' "$svcs" | grep -qx backup || return 0
  IMAGE_TAG=$(tag) docker compose -f "$f" up -d backup || :
  h=$(IMAGE_TAG=$(tag) docker compose -f "$f" exec -T backup backup health 2>&1) \
    || say "WARNING: backup unhealthy: ${h#unhealthy: } (docs/how-to/backups.md)"
}

deploy_record() { # deploy_record <env>: add the commit that now runs to .deploy/history
  mkdir -p .deploy
  printf '%s %s%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(sha)" "${ROLLBACK:+ rollback}" >> .deploy/history
  say "OK: $1 runs $(sha)"
}

# deploy_before <commit>
#   The deployed commit make rollback returns to from <commit>, read from .deploy/history.
#   Outputs:   the commit on stdout; nothing when there is none.
deploy_before() {
  awk -v n="$1" '$3 == "rollback" { while (k > 0 && s[k] != $2) k--; if (k == 0) s[++k] = $2; next }
    s[k] != $2 { s[++k] = $2 } END { while (k > 0 && s[k] == n) k--; if (k > 0) print s[k] }' .deploy/history
}

# ---- check: the checks (QLT-01) --------------------------------------------

# A base target runs one kind of check; a group target runs base targets, each in a process of its
# own, every one also after another failed, and ends with a summary of one line per base target. A
# check's setting is its command, empty (not set up yet) or off (the project does not want that
# check). LINT, TEST and SECRETS are mandatory, so empty refuses (and fails in a group); E2E and
# SECURITY may stay empty.

check_state() { # check_state <base target>: run, or off|<why>, skip|<why>, fail|<why> when it runs nothing
  case "$1" in
    lint) v=${LINT:-} n=LINT ;; test) v=${TEST:-} n=TEST ;; secrets) v=${SECRETS:-} n=SECRETS ;;
    e2e) v=${E2E:-} n=E2E ;;
    security) n=SECRETS v=${SECRETS:-}
      [ "$v" != off ] || case "${SECURITY:-}" in ''|off) ;; *) v=run ;; esac ;;
    *) v=run ;;
  esac
  case "$v" in
    off) echo "off|$n = off in the Makefile settings" ;;
    '') if [ "$n" = E2E ]; then echo "skip|no E2E command in the Makefile settings"
        else echo "fail|$n is empty: set it in the Makefile settings, or $n = off if this project does not want this check"; fi ;;
    *) echo run ;;
  esac
}

# The last line of a check's output that says something: without colour codes, carriage returns
# and the blanks and = signs around it (a test runner's rule), at most 100 characters.
check_last_line() {
  e=$(printf '\033')
  tr '\r' '\n' < "$1" | sed -e "s/$e\[[0-9;]*[A-Za-z]//g" -e 's/^[[:space:]=]*//' -e 's/[[:space:]=]*$//' \
    | grep -v '^[-=*_~#]*$' | tail -n 1 | cut -c1-100
}

# check_step <command>…
#   One step of a base target of several (lint, security, infra). In a group, the first step that
#   fails gives the summary line its detail (CHECK_DETAIL names the file for it).
#   Outputs:   the command's output and errors, on stdout.
#   Returns:   the command's status.
#   Note:      called as check_step … || rc=1, so -e is off inside; the status goes through a file,
#              since a pipe keeps only tee's.
check_step() {
  o=$(mktemp)
  { if "$@" 2>&1; then r=0; else r=$?; fi; echo "$r" > "$o.rc"; } | tee "$o"
  r=$(cat "$o.rc")
  if [ "$r" != 0 ] && [ -n "${CHECK_DETAIL:-}" ] && [ ! -s "$CHECK_DETAIL" ]; then check_last_line "$o" > "$CHECK_DETAIL"; fi
  rm -f "$o" "$o.rc"
  return "$r"
}

check_line() { printf '  %-9s %-5s %s\n' "$1" "$2" "$3" >> "$sum_dir/summary"; }  # one line of a group's summary

check_dockerfile() { # docker build --check of the Dockerfile of every own image (IMAGES), on the host (QLT-01)
  failed=''
  for i in $IMAGES; do
    d=docker/$i/Dockerfile
    [ -f "$d" ] || die "IMAGES in the Makefile settings has $i, but there is no $d"
    say "dockerfile-check: $d"
    # It reads the Dockerfile and the metadata of its base images (the local ones, else from their
    # registry), and builds nothing.
    docker build --check -q -f "$d" . || failed="$failed $d"
  done
  [ -z "$failed" ] || die "dockerfile-check: docker build --check found problems (above) in:$failed"
  say "dockerfile-check: OK"
}

check_compose() { # the compose rules of the stage and prod files that exist (ENV-03)
  [ -f docker-compose.stage.yml ] || [ -f docker-compose.prod.yml ] || return 0
  sh scripts/check-compose.sh
}

# check_parity
#   Stage and prod differ only in name: (ENV-02), and the names differ (ENV-04).
#   Outputs:   the diff and an error, or "parity: OK".
check_parity() {
  [ -f docker-compose.stage.yml ] && [ -f docker-compose.prod.yml ] || return 0
  [ "$(name_of docker-compose.stage.yml)" != "$(name_of docker-compose.prod.yml)" ] \
    || die "parity: stage and prod have the same name:, so on one machine they would share containers and volumes (ENV-04)"
  a=$(mktemp) b=$(mktemp)
  # One project name for both files, so the name: line and the names Compose derives from it (the
  # default network, the volumes) are equal; every other difference is an error.
  for f in stage:"$a" prod:"$b"; do
    docker compose -p parity -f "docker-compose.${f%%:*}.yml" config --no-interpolate > "${f#*:}" \
      || { rm -f "$a" "$b"; die "parity: docker-compose.${f%%:*}.yml cannot be read (above)"; }
  done
  if diff -u "$a" "$b"; then rm -f "$a" "$b"; say "parity: OK"
  else rm -f "$a" "$b"; die "parity: stage and prod differ beyond name: (ENV-02)"; fi
}

# ---- backup: the backup service (OPS-01) -----------------------------------

backup_has() { [ -d docker/backup ] || die "this project has no backup service (docker/backup/, standard OPS-01)"; }

# backup_run <compose file> <argument>…
#   The backup command: in dev in a one-off container of the dev build (quiet: the output is the
#   service's own), on a server in the running service, else in a one-off container.
#   Returns:   the backup command's status.
#   Note:      cmd_restore runs it in a condition, so -e is off inside.
backup_run() {
  f=$1; shift
  if [ "$f" = docker-compose.dev.yml ]; then
    docker compose --progress quiet -f "$f" --profile backup run --rm -T --build backup "$@"
  elif IMAGE_TAG=$(tag) docker compose -f "$f" ps --status running --services | grep -qx backup; then
    IMAGE_TAG=$(tag) docker compose -f "$f" exec -T backup backup "$@"
  else
    IMAGE_TAG=$(tag) docker compose -f "$f" run --rm --no-deps -T backup "$@"
  fi
}

# backup_status
#   make backup-status on a server when the backup service does not run: its state, then what the
#   backup folder holds (the sets, the last result of every job), read in a one-off container.
#   When the service runs, it says so and the service's status follows.
#   Globals:   reads f (cmd_backup).
#   Returns:   0 when the service runs; else exit 1 (the script ends here).
backup_status() {
  s=$(IMAGE_TAG=$(tag) docker compose -f "$f" ps --all --format '{{.State}} {{.Health}}' backup)
  st=${s%% *} health=${s#"${s%% *}"}
  health=${health# }
  [ "$st" != running ] || { say "backup-status: the backup service runs${health:+ ($health)}"; return 0; }
  say "backup-status: the backup service does not run (${st:-no container}): make logs S=backup shows why;" \
    "what its backup folder holds:"
  # What the folder holds is shown whatever the one-off container returns: the step fails anyway.
  backup_run "$f" status || :
  exit 1
}

# ---- cmd: the make targets -------------------------------------------------

# cmd_bootstrap
#   make bootstrap (make dev and every deploy run it too): refuse a bad setting and a
#   default-named compose file; create .env from .env.example when there is none (a second copy of
#   the project gets a dev stack of its own); in dev set the git hooks; create the external
#   networks.
#   Globals:   sets top again (from git) when it creates .env; name, others.
#   Writes:    .env, git config core.hooksPath, Docker networks.
cmd_bootstrap() {
  # The settings first: a deploy (and make dev) refuses a bad one before it changes anything.
  image_keep >/dev/null
  d=$(pwd)
  while :; do
    for f in compose.yaml compose.yml docker-compose.yaml docker-compose.yml; do
      [ ! -e "$d/$f" ] || die "$d/$f is a default-named compose file: a bare docker compose up would use it (PRN-02)"
    done
    [ "$d" != / ] || break
    d=$(dirname "$d")
  done
  if [ ! -f .env ]; then
    top=$(git rev-parse --path-format=absolute --show-toplevel)
    # PROJECT_DIR goes into a sed replacement, where & | and \ are special.
    esc=$(printf '%s' "$top" | sed 's/[&|\\]/\\&/g')
    copy=${DEV_NAME:-}
    if [ -z "$copy" ] && [ "$(git rev-parse --path-format=absolute --git-dir)" != \
         "$(git rev-parse --path-format=absolute --git-common-dir)" ]; then
      # A worktree: its folder name, and a short hash of its path, so that worktrees with the same
      # folder name in different places (…/a/fix, …/b/fix) get different dev projects.
      copy=$(basename "$top")-$(printf '%s' "$top" | git hash-object --stdin | cut -c1-6)
    fi
    # The group of the Docker socket, for the status service's socket proxy on a server; where it
    # cannot be read (no such socket, a stat without -c), the value of .env.example stays.
    gid=$(stat -c %g /var/run/docker.sock 2>/dev/null) || gid=''
    # Written to a temporary file first, so a failed bootstrap leaves no half-filled .env.
    sed -e "s|^PROJECT_ENV=.*|PROJECT_ENV=dev|" -e "s|^PROJECT_DIR=.*|PROJECT_DIR=$esc|" \
      -e "s|^HOST_UID=.*|HOST_UID=$(id -u)|" -e "s|^HOST_GID=.*|HOST_GID=$(id -g)|" \
      -e "${gid:+s|^DOCKER_GID=.*|DOCKER_GID=$gid|}" .env.example > .env.new
    if [ -n "$copy" ]; then
      suffix=$(suffix_of "$copy")
      sed -e "s|^DEV_SUFFIX=.*|DEV_SUFFIX=-$suffix|" -e 's|^\([A-Z0-9_]*_PORT\)=.*|\1=|' .env.new > .env.tmp
      mv .env.tmp .env.new
      say "bootstrap: a second copy: its own dev stack (DEV_SUFFIX=-$suffix) on free ports"
    fi
    # One clone per dev project (ENV-04): a plain second clone would get the dev project of the
    # first one. Its volumes carry no folder: with no container left, they are only named.
    name=$(docker compose --env-file .env.new -f docker-compose.dev.yml config 2>/dev/null | sed -n 's/^name: //p')
    if [ -n "$name" ]; then
      others=$(env_others_of "$name")
      [ -z "$others" ] || { rm -f .env.new; die "the dev project $name already runs from $others(its containers," \
        "stopped ones too, name that folder): a second clone would take them over and share its database;" \
        "make dev NAME=<n>, with a name no other clone uses, gives this clone a dev stack of its own; nothing was created"; }
      [ -z "$(docker volume ls -q --filter "label=com.docker.compose.project=$name")" ] \
        || say "WARNING: the volumes of $name exist, but no container of it: this clone's dev stack uses their data" \
          "(of another clone after its make down, or of an earlier clone in this folder); make dev NAME=<n> gives it its own"
    fi
    mv .env.new .env
    say "bootstrap: created .env from .env.example"
  else
    if [ -n "${DEV_NAME:-}" ] && [ "$(envvar DEV_SUFFIX)" != "-$(suffix_of "$DEV_NAME")" ]; then
      say "WARNING: NAME=$DEV_NAME is ignored: this clone already has .env (DEV_SUFFIX=$(envvar DEV_SUFFIX));" \
        "NAME applies only when make bootstrap creates .env"
    fi
    # A .env the project had before (a framework's own, such as Laravel's) or one older than
    # .env.example: name what it lacks (but IMAGE_TAG, which make sets); nothing is written into it.
    missing=$(sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' .env.example | grep -vx IMAGE_TAG | while read -r v; do
      grep -q "^$v=" .env || printf '%s ' "$v"; done)
    [ -z "$missing" ] || say "WARNING: .env lacks variables of .env.example: ${missing% }. Add them to .env" \
      "(the comment above each in .env.example says what it is), or let the agent add them"
  fi
  if [ -d .githooks ]; then
    case "$(project_env)" in
      dev) git config core.hooksPath .githooks
        # git skips a hook that is not executable, and a commit made on Windows may have lost the bit.
        [ -x .githooks/pre-push ] || say "WARNING: .githooks/pre-push is not executable, so git skips it:" \
          "run git update-index --chmod=+x .githooks/pre-push && chmod +x .githooks/pre-push, then commit" ;;
      stage|prod) ;;
      *) say "WARNING: the git hooks were not set (git config core.hooksPath .githooks): PROJECT_ENV is" \
           "'$(project_env)' in .env, not dev; set PROJECT_ENV=dev and run make bootstrap again" ;;
    esac
  fi
  net_create
}

# cmd_image_scan
#   make image-scan: build the images of the checked-out commit, save them, and scan the files
#   with trivy in the dev container (QLT-01).
#   Globals:   sets scan_dir (on_exit removes it); own, built_tag (image_build).
#   Returns:   0; dies when trivy fails or finds vulnerabilities in any image.
cmd_image_scan() {
  env_need dev
  if [ -f docker-compose.stage.yml ]; then f=docker-compose.stage.yml
  elif [ -f docker-compose.prod.yml ]; then f=docker-compose.prod.yml
  else die "this project has no stage or prod, so make image-scan does not apply (TYP-01)"; fi
  image_build "$f" "nothing was scanned"
  # In the project folder, which the dev container mounts at the same path; build/ is in .gitignore
  # and .dockerignore.
  scan_dir=$(pwd)/build/image-scan
  mkdir -p "$scan_dir"
  for p in $own; do
    i=${p%%=*} n=${p#*=}
    docker save -o "$scan_dir/$i.tar" "$n:$built_tag"
    say "image-scan: saved $n:$built_tag to build/image-scan/$i.tar ($(( $(wc -c < "$scan_dir/$i.tar") / 1048576 )) MiB)"
  done
  docker compose -f docker-compose.dev.yml up -d --build --wait >/dev/null
  docker compose -f docker-compose.dev.yml exec -T dev sh -c 'command -v trivy' >/dev/null \
    || die "make image-scan needs trivy in the dev image (standard QLT-01)"
  # Every image is scanned, also after one fails. trivy reads trivy.yaml and .trivyignore of the project.
  failed=
  for p in $own; do
    i=${p%%=*} n=${p#*=}
    say "image-scan: $n:$built_tag"
    docker compose -f docker-compose.dev.yml exec -T dev trivy image --input "$scan_dir/$i.tar" --exit-code 1 \
      || failed="$failed $n"
  done
  [ -z "$failed" ] || die "image-scan: trivy failed or found vulnerabilities (above) in:$failed"
  say "image-scan: OK"
}

# cmd_deploy <env>
#   make stage, make prod: update to the branch, then the deploy steps of the updated Makefile
#   (make deploy-<env>).
#   Globals:   reads name (env_need).
cmd_deploy() {
  [ -f "$(file_of "$1")" ] || die "this project has no $1 ($(file_of "$1") does not exist)"
  env_need "$1"
  env_socket_group "$1"
  lock_take "$1"
  [ -z "$(git status --porcelain --untracked-files=no)" ] || die "this server clone has local changes; nothing was updated"
  disk_space "$1"
  # The first deploy of this clone, with volumes of its project already there: the guard of env_need
  # sees containers, not volumes, so this is only said.
  if [ ! -f .deploy/history ] && [ -n "$name" ] && [ -z "$(docker ps -aq --filter "label=com.docker.compose.project=$name")" ] \
      && [ -n "$(docker volume ls -q --filter "label=com.docker.compose.project=$name")" ]; then
    say "WARNING: the volumes of $name exist, but no container of it: this first deploy of this clone uses their" \
      "data (of a clone that ran here before, or of another clone of this machine after docker compose -p $name down)"
  fi
  branch=$(branch_of "$1")
  git fetch --quiet origin "$branch"
  git checkout --quiet "$branch"
  git merge --ff-only --quiet "origin/$branch" || die "$branch cannot be fast-forwarded to origin/$branch"
  # The commit may add the proxy: its file is checked too, before any container changes.
  env_socket_group "$1"
  risk=$(risk_pass)
  make --no-print-directory "deploy-$1" ${risk:+"$risk"}
}

cmd_images() { # make images: the images make stage / make prod would build and pull, and nothing else
  e=$(project_env)
  case "$e" in stage|prod) ;; *) die "make images runs only in a stage or prod clone" ;; esac
  env_need "$e"
  lock_take images
  disk_space "$e"
  image_get "$e"
  say "OK: the images of $(sha) are on this machine; nothing was started"
}

cmd_restart() { # make restart: apply a changed .env to the commit that runs now: no checkout, no migration
  e=$(project_env)
  case "$e" in stage|prod) ;; *) die "make restart runs only in a stage or prod clone" ;; esac
  env_need "$e"
  env_socket_group "$e"
  lock_take restart
  # After a make stage / make prod that stopped halfway, the checked-out commit is not the one
  # that runs, and starting it here would skip its migrations.
  last=$( [ ! -f .deploy/history ] || tail -n 1 .deploy/history | cut -d' ' -f2)
  [ "$last" = "$(sha)" ] \
    || die "the checked-out commit $(sha) is not the one deployed last (${last:-none}): run make $e or make rollback first"
  disk_space "$e" "$(sha)"
  # A changed network name in .env needs that network.
  net_create
  # The images of the running commit are on this machine; one removed by hand is built again.
  image_get "$e"
  deploy_log_archive "$e"
  # up -d recreates only the containers whose configuration changed; docker compose restart
  # would keep the old .env values.
  deploy_up "$e" "a container did not become healthy with the changed .env: set the previous values back in .env and run make restart"
  # Not recorded in .deploy/history: the commit did not change, so make rollback is not affected.
  cmd_tuning_check "$e runs $(sha), restarted with the current .env"
  say "OK: $e runs $(sha) (restarted with the current .env)"
}

# cmd_rollback
#   make rollback: check out the commit that ran before the current one and run its deploy steps
#   (make deploy-<env> with ROLLBACK=1: no migrations).
cmd_rollback() {
  e=$(project_env)
  case "$e" in stage|prod) ;; *) die "make rollback runs only in a stage or prod clone" ;; esac
  [ -f .deploy/history ] || die "nothing deployed yet"
  env_need "$e"
  env_socket_group "$e"
  lock_take rollback
  # The commit that ran before the current one. Each line of .deploy/history is a commit that started;
  # a rollback line returns to an earlier entry, so the commits it skipped drop out. After a failed
  # start the checked-out commit was never recorded, so the last entry left is the answer.
  now=$(sha)
  prev=$(deploy_before "$now")
  [ -n "$prev" ] || die "no earlier deployed commit"
  disk_space "$e" "$prev"
  say "rollback: $now -> $prev (no migrations)"
  git checkout --quiet --detach "$prev"
  risk=$(risk_pass)
  ROLLBACK=1 make --no-print-directory "deploy-$e" ${risk:+"$risk"} \
    || die "make rollback did not finish (above): this clone is left at $prev (detached HEAD); make $e deploys the $(branch_of "$e") branch again, make rollback deploys $(deploy_before "$prev" | grep . || echo 'nothing (no earlier deployed commit)')"
}

cmd_status() { # make status: the environment, the checked-out and the last deployed commit, the containers
  [ -f .env ] || die "no .env in this clone (docs/how-to/operations.md)"
  e=$(project_env)
  say "environment: $e · checked out: $(sha)"
  [ ! -f .deploy/history ] || say "last deploy: $(tail -n 1 .deploy/history)"
  case "$e" in stage|prod) IMAGE_TAG=$(tag) docker compose -f "$(file_of "$e")" ps ;;
    *) docker compose -f docker-compose.dev.yml ps ;; esac
}

cmd_logs() { # cmd_logs <lines> [<service>…]: follow the logs of this clone's stack; with <lines>, print that many and end
  n=$1; shift
  case "$n" in '') set -- -f --tail 100 "$@" ;; *[!0-9]*) die "TAIL=$n is not a number of lines" ;; *) set -- --tail "$n" "$@" ;; esac
  f=docker-compose.dev.yml
  case "$(project_env)" in stage|prod) f=$(file_of "$(project_env)") ;; esac
  IMAGE_TAG=$(tag) docker compose -f "$f" logs "$@"
}

# cmd_check <base target>
#   make lint, test, e2e, security, infra, and secrets (part of security and of gates). make lint
#   checks the Dockerfiles first, also with LINT = off.
#   Returns:   0; 1 when a step failed; dies on a mandatory check that is empty.
cmd_check() {
  s=$(check_state "$1")
  case "$s" in fail\|*) die "${s#fail|}" ;; esac
  rc=0
  if [ "$1" = lint ]; then
    if [ "${DOCKERFILE_CHECK:-}" = off ]; then say "lint: DOCKERFILE_CHECK = off in the Makefile settings: the Dockerfiles are not checked"
    else check_step sh scripts/project.sh dockerfile-check || rc=1; fi
  fi
  case "$s" in off\|*|skip\|*) say "$1: ${s#*|}: not run"; return "$rc" ;; esac
  case "$1" in
    lint) check_step sh scripts/project.sh in-dev LINT || rc=1; return "$rc" ;;
    test) dev_run TEST ;; e2e) dev_run E2E ;; secrets) dev_run SECRETS ;;
    security)
      rc=0
      [ "${SECRETS:-}" = off ] || check_step sh scripts/project.sh in-dev SECRETS || rc=1
      case "${SECURITY:-}" in ''|off) ;; *) check_step sh scripts/project.sh in-dev SECURITY || rc=1 ;; esac
      return "$rc" ;;
    infra)
      rc=0
      check_step sh scripts/project.sh check-compose || rc=1
      check_step sh scripts/project.sh parity || rc=1
      [ ! -d docker/backup ] || check_step sh scripts/project.sh backup backup-test || rc=1
      return "$rc" ;;
  esac
}

# cmd_group gates|verify
#   make gates, make verify: every base target of the group, each also after another failed, then
#   the summary.
#   Globals:   sets sum_dir (on_exit removes it).
#   Outputs:   each target's output under a "---- make <group>: <target>" line, then the summary.
#   Returns:   0 when every target passed; else exit 1 after the summary.
cmd_group() {
  g=$1
  case "$g" in gates) set -- lint test secrets ;; verify) set -- lint test e2e security infra ;; esac
  todo=''
  for b in "$@"; do [ "$(check_state "$b")" != run ] || todo=1; done
  [ -n "$todo" ] || die "make $g has nothing to run: set LINT, TEST or SECRETS in the Makefile settings"
  sum_dir=$(mktemp -d)
  failed=''
  for b in "$@"; do
    s=$(check_state "$b")
    case "$s" in
      fail\|*) check_line "$b" FAIL "${s#fail|}"; failed="$failed $b"; continue ;;
      # LINT = off still runs the Dockerfile check: the line stays off, or FAIL when that fails.
      off\|*) [ "$b" = lint ] && [ "${DOCKERFILE_CHECK:-}" != off ] || { check_line "$b" off "${s#off|}"; continue; } ;;
      skip\|*) check_line "$b" skip "${s#skip|}"; continue ;;
    esac
    say "---- make $g: $b"
    # The output goes to the screen and to a file; the exit code through a file, since a pipe
    # keeps only tee's.
    : > "$sum_dir/detail"
    { if CHECK_DETAIL=$sum_dir/detail sh scripts/project.sh check "$b" 2>&1; then r=0; else r=$?; fi
      echo "$r" > "$sum_dir/rc"; } | tee "$sum_dir/out"
    if [ "$(cat "$sum_dir/rc")" != 0 ]; then s=FAIL; failed="$failed $b"
    elif [ "$s" = run ]; then s=ok
    else s=off; echo "LINT = off; dockerfile-check: OK" > "$sum_dir/detail"; fi
    if [ -s "$sum_dir/detail" ]; then d=$(cat "$sum_dir/detail"); else d=$(check_last_line "$sum_dir/out"); fi
    check_line "$b" "$s" "${d:-no output}"
  done
  say "summary of make $g:"
  cat "$sum_dir/summary"
  if [ -n "$failed" ]; then say "make $g: FAIL (${failed# })"; exit 1; fi
  say "make $g: OK"
}

# cmd_backup <command>
#   A command of the backup service in this clone's environment (OPS-01), with the make arguments
#   it takes: S= (backup, backup-test, drill, list), SET= (drill), FROM= (list).
#   Globals:   sets f (read by backup_status).
#   Returns:   the backup command's status.
cmd_backup() {
  backup_has
  c=$1
  e=$(project_env)
  set -- "$c"
  case "$c" in backup|backup-test|drill|list) [ -z "${ARG_S:-}" ] || set -- "$@" --store "$ARG_S" ;; esac
  [ "$c" != drill ] || [ -z "${ARG_SET:-}" ] || set -- "$@" --set "$ARG_SET"
  [ "$c" != list ] || [ -z "${ARG_FROM:-}" ] || set -- "$@" --from "$ARG_FROM"
  case "$e" in
    dev) env_need dev
      [ "$c" != copy-check ] || die "make backup-copy-check runs only on a server: dev has no off-server copy"
      [ "$c" != list ] || [ "${ARG_FROM:-}" != copy ] || die "make backup-list FROM=copy runs only on a server: dev has no off-server copy"
      f=docker-compose.dev.yml ;;
    stage|prod)
      [ "$c" != backup-test ] || die "make backup-test runs only in dev; on a server make backup-drill checks the sets"
      env_need "$e"
      f=$(file_of "$e")
      [ "$c" != status ] || backup_status ;;
    *) die "unknown PROJECT_ENV=$e in .env" ;;
  esac
  case "$c" in backup|drill) ;; *) backup_cmd "$@"; return ;; esac
  # The service refuses a backup or a drill that may not fit with exit 3 (an estimate): it says
  # what it found and what can go wrong, and goes on with --risk.
  rc=0
  backup_cmd "$@" || rc=$?
  [ "$rc" = 3 ] || return "$rc"
  t=backup
  [ "$c" = backup ] || t=backup-drill
  risk_ask "the backup service found too little free space for make $t (above)" "what it says above"
  backup_cmd "$@" --risk
}

# backup_cmd <argument>…: the backup command in this clone's environment (f of cmd_backup): in dev
# through backup_run, on a server in the running service.
backup_cmd() {
  if [ "$f" = docker-compose.dev.yml ]; then backup_run "$f" "$@"
  else IMAGE_TAG=$(tag) docker compose -f "$f" exec -T backup backup "$@"; fi
}

# cmd_restore
#   make restore, with S=, SET=, FROM= and NO_SAFETY=1 of make. It first shows what the restore
#   would replace. When its input is a terminal (a person at the keyboard), it shows that in red
#   and the person types the name of every database it replaces; otherwise (an agent, a script)
#   only CONFIRM=yes typed on the command line of this make confirms it.
#   Globals:   sets f, stopped (on_exit says how to start the application again).
#   Returns:   the restore's status; exit 1 when the check fails or nothing confirms it.
cmd_restore() {
  backup_has
  e=$(project_env)
  set -- --set "${ARG_SET:-latest}" --from "${ARG_FROM:-local}"
  [ -z "${ARG_S:-}" ] || set -- "$@" --store "$ARG_S"
  case "${ARG_NO_SAFETY:-}" in
    '') ;; 1) set -- "$@" --no-safety ;;
    *) die "NO_SAFETY is '$ARG_NO_SAFETY', not 1 (or empty: a safety set first); nothing was replaced" ;;
  esac
  case "$e" in
    dev) env_need dev
      [ "${ARG_FROM:-local}" != copy ] || die "make restore FROM=copy runs only on a server: dev has no off-server copy"
      f=docker-compose.dev.yml ;;
    stage|prod)
      env_need "$e"
      lock_take restore
      # A new server restores before its first deploy: the backup image may not be built yet, and
      # its build needs room.
      disk_space "$e"
      image_get "$e"
      f=$(file_of "$e") ;;
    *) die "unknown PROJECT_ENV=$e in .env" ;;
  esac
  # First the check (the arguments, the set of every store, the checksums of the local sets, the
  # free space), so nothing stops for a restore that cannot run; it names what a restore replaces.
  # Docker gets no input (< /dev/null): what a person types is the answer to the question below.
  if [ -t 0 ]; then
    # One call gives the check's lines and the plan, one tab-separated line per store whose second
    # field is the name of the database: the sets are read once before the restore itself.
    tab=$(printf '\t')
    rc=0
    chk=$(backup_run "$f" restore --check --plan "$@" < /dev/null 2>&1) || rc=$?
    if [ "$rc" = 3 ]; then
      printf '%s\n' "$chk" | awk -F "$tab" 'NF != 7'
      restore_risk
      set -- "$@" --risk
      rc=0
      chk=$(backup_run "$f" restore --check --plan "$@" < /dev/null 2>&1) || rc=$?
    fi
    if [ "$rc" != 0 ]; then
      printf '%s\n' "$chk" | awk -F "$tab" 'NF != 7'
      exit 1
    fi
    red='' plain=''
    [ ! -t 1 ] || { red=$(printf '\033[31m') plain=$(printf '\033[0m'); }
    printf '%s%s%s\n' "$red" "$(printf '%s\n' "$chk" | awk -F "$tab" 'NF != 7')" "$plain"
    # CONFIRM does not count here. The loop reads the plan; the answers come from the terminal (3).
    exec 3<&0
    while IFS=$tab read -r s n h _; do
      printf 'restore: to replace the database %s on %s (%s), type its name: ' "$n" "$h" "$s" >&2
      answer=''
      read -r answer <&3 || :
      [ -n "$n" ] && [ "$answer" = "$n" ] || die "you typed '$answer', not $n: nothing was replaced"
    done <<EOF
$(printf '%s\n' "$chk" | awk -F "$tab" 'NF == 7')
EOF
    exec 3<&-
  else
    rc=0
    backup_run "$f" restore --check "$@" < /dev/null || rc=$?
    if [ "$rc" = 3 ]; then
      restore_risk
      set -- "$@" --risk
      rc=0
      backup_run "$f" restore --check "$@" < /dev/null || rc=$?
    fi
    [ "$rc" = 0 ] || exit 1
    if [ "${ARG_CONFIRM:-}" != yes ]; then
      # The service's refusal names what a restore would replace.
      backup_run "$f" restore "$@" < /dev/null || :
      exit 1
    fi
    env_typed CONFIRM=yes || die "CONFIRM=yes is not on the command line of this make: it came from MAKEFLAGS or" \
      "GNUMAKEFLAGS of the environment, or from a make that runs this one, which confirm nothing; nothing was replaced"
  fi
  case "$e" in
    dev) docker compose --progress quiet -f "$f" --profile backup run --rm -T --build -e CONFIRM=yes backup restore "$@" < /dev/null ;;
    stage|prod)
      # Nothing may write while the database is replaced: everything that runs stops but backup,
      # and status with its proxy, which write nothing and go on reporting (the stopped ones as down).
      others=$(IMAGE_TAG=$(tag) docker compose -f "$f" ps --status running --services | grep -vxE 'backup|status|status-proxy' || :)
      # Set before the stop, so that a stop that fails halfway says it too. A server not deployed
      # yet has nothing for make restart to start.
      stopped="make restart"
      [ -f .deploy/history ] || stopped="make $e"
      if [ -n "$others" ]; then
        say "restore: stopping $(printf '%s\n' "$others" | tr '\n' ' ')for the restore"
        # shellcheck disable=SC2086 # one word per service
        IMAGE_TAG=$(tag) docker compose -f "$f" stop $others
      fi
      # Without --wait: an unhealthy backup service (old sets, a failed drill) must not block a restore.
      # It starts the stores backup depends on, not the application.
      IMAGE_TAG=$(tag) docker compose -f "$f" up -d backup
      IMAGE_TAG=$(tag) docker compose -f "$f" exec -T -e CONFIRM=yes backup backup restore "$@" < /dev/null ;;
  esac
}

# restore_risk: the restore's check refused for the free space alone (exit 3, an estimate)
restore_risk() { risk_ask "the backup service found too little free space for make restore (above)" "what it says above"; }

# cmd_tuning_check [<what runs>]
#   make tuning-check; with <what runs>, as the end of a deploy or restart, which stands.
#   Returns:   0 when every check passes; else exit 1, or with <what runs> a die that says what
#              to do.
cmd_tuning_check() {
  [ -f scripts/tuning-check.sh ] || die "this project has no scripts/tuning-check.sh: it has no stage or prod, or the tuning task is not done (OPS-02)"
  IMAGE_TAG=$(tag) sh scripts/tuning-check.sh && return 0
  [ -n "${1:-}" ] || exit 1
  die "tuning-check failed (above), and $1: a value from .env: set it in .env, then make restart;" \
    "a value in the code: fix it and ship again"
}

# ---- main ------------------------------------------------------------------

# main <step> [<argument>…]: the step names are what the Makefile runs; each one's function is
# above (env_need for need, dev_run for in-dev, and so on).
main() {
  cmd=$1; shift
  case "$cmd" in
    need) env_need "$@" ;;
    bootstrap) cmd_bootstrap ;;
    in-dev) dev_run "$@" ;;
    migrate) deploy_migrate "$@" ;;
    parity) check_parity ;;
    check-compose) check_compose ;;
    image-scan) cmd_image_scan ;;
    deploy) cmd_deploy "$@" ;;
    lint|test|e2e|security|infra) cmd_check "$cmd" ;;
    check) cmd_check "$@" ;;
    group) cmd_group "$@" ;;
    images) if [ $# -gt 0 ]; then image_get "$@"; else cmd_images; fi ;;
    up) deploy_up "$@" ;;
    restart) cmd_restart ;;
    record) deploy_record "$@" ;;
    prune) image_prune ;;
    rollback) cmd_rollback ;;
    status) cmd_status ;;
    logs) cmd_logs "$@" ;;
    backup) cmd_backup "$@" ;;
    log-archive) deploy_log_archive "$@" ;;
    dockerfile-check) check_dockerfile ;;
    tuning-check) case "${1:-}" in
        deploy) cmd_tuning_check "$(project_env) runs $(sha), recorded in .deploy/history" ;;
        *) cmd_tuning_check ;;
      esac ;;
    restore) cmd_restore ;;
    *) die "unknown step $cmd" ;;
  esac
}

main "$@"
