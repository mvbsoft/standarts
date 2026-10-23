#!/bin/sh
# The proof copy of the standard's prompts (prompt/start.md section 3): a throwaway copy of the
# project in a temporary folder, whose remote is a bare repository there, with server clones where
# make stage and make prod build and deploy as on a server, on this machine, under names that no
# other stack of this machine uses. It never changes the project folder, its git or its remote.
#
# Usage:   sh "$STANDARD/scripts/proof.sh" create | stage | prod | clean | path
#          Run it in the project folder: the top folder of its git repository, or a folder without
#          .git (new mode). stage, prod, clean and path also run in a folder of the copy
#          ($t/p, $t/wt).
#
# Folders. $t is $TMPDIR/<repo>-proof-<6 hex> (/tmp/… without TMPDIR): <repo> is the name: of the
# stage file without -stage (else of prod without -prod, else of dev without -dev), the hex a hash
# of the project folder's path, so every project has its own. Every command prints $t; path prints
# only it.
#   $t/p              the copy: a git repository whose origin is $t/remote.git; its dev stack is
#                     <repo>-dev-proof (make dev in $t/p)
#   $t/remote.git     bare; its <STAGE_BRANCH> and <PROD_BRANCH> (the Makefile settings) are what the
#                     server clones deploy
#   $t/stage, $t/prod the server clones, made by stage and prod on first use
#   $t/wt             where a git worktree of the copy goes, made by hand: git -C "$t/p" worktree add "$t/wt"
#
# create  copies the project as it is now: every file git would commit, the ones not committed yet
#         included (changed, new or deleted; never an untracked .env, nothing .gitignore ignores),
#         as one commit on the project's last one (without .git: the only commit, on
#         <STAGE_BRANCH>). In that commit the stage and prod files have name: <repo>-proof-stage and
#         <repo>-proof-prod and the own images (IMAGES) <repo>-proof-<image>, and every external
#         network of NETWORKS has -proof after its name in .env.example. It pushes that commit as
#         HEAD:<STAGE_BRANCH> and HEAD:<PROD_BRANCH> (the copy's own branch may have another name)
#         and runs make bootstrap NAME=proof in $t/p. Refused when $t exists, when the Makefile
#         has BUILD_SECRETS (files git ignores, which the copy would lack), or when this machine has a
#         container or a volume of <repo>-dev-proof, <repo>-proof-stage or <repo>-proof-prod, or an
#         image <repo>-proof-* or <repo>-dev-proof-*: that is not this copy's.
# stage, prod
#         on first use: refused when this machine has a container or a volume of <repo>-proof-<env>;
#         clones <STAGE_BRANCH> (<PROD_BRANCH>) of $t/remote.git into $t/<env>, with a .env made from
#         .env.example: PROJECT_ENV=<env>; 32 random hex digits for every change-me; 0 for every
#         *_PORT, so Docker picks a free host port; DOCKER_GID the group of /var/run/docker.sock;
#         BACKUP_TIME the start of this hour (UTC), so the first daily backup is tomorrow;
#         BACKUP_COPY_TO=/backup/.copy,
#         a restic repository inside BACKUP_DIR; mode 600. Then, every time, make <env> in that clone
#         and make status (the ports Docker picked). A change gets there through the remote: commit
#         in $t/p, then git push origin HEAD:<STAGE_BRANCH> (HEAD:<PROD_BRANCH> for prod).
# clean   removes the stacks of the copy: <repo>-dev-proof, <repo>-proof-stage, <repo>-proof-prod,
#         and every compose project with a container started in $t or named by a compose file in a
#         folder of $t ($t/wt, a copy of an old stack): their containers, volumes and networks, the
#         images they built and <repo>-proof-*, and the networks create made; then $t, with the
#         backup sets the backup user of the server clones owns (removed by a root container of an
#         image the copy used). It works at any point, after a create or a deploy that failed too.
#         A project with a container started outside $t is not the copy's: clean leaves it alone,
#         names it, keeps $t (so clean can run again) and fails. A project that had a container or
#         a volume before create keeps its volumes and images.
# path    prints $t.
#
# Reads:   the project folder (its files, its git and its Makefile settings); TMPDIR; Docker.
# Writes:  $t; the containers, volumes, networks and images of the stacks of the copy.
# Output:  "proof: …" lines and the output of git, make and Docker; path prints only $t. Errors on
#          stderr as "ERROR: <what>".
# Exit:    0, or 1 after a line "ERROR: <what>" (a command that fails under set -e ends it with its
#          own status).
# Shell:   POSIX sh; needs git, docker, make and the POSIX tools. The .env values of the server
#          clones are test values of this copy only.
set -eu

# ---- globals ---------------------------------------------------------------

# sh has no local variables: every name is global. These are set in main and read everywhere;
# every other name is scratch.
#   cmd       the command (create, stage, prod, clean, path)
#   here src  the folder this runs in; the project folder
#   t         the folder of the copy; tp its physical path (cmd_clean, read by inside)
#   repo      <repo> of the project
#   in_copy   1 when this runs in a folder of the copy
#   git_mode  1 when the project folder has .git, else empty (set only outside the copy)

# ---- primitives ------------------------------------------------------------

say() { printf 'proof: %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
# envvar <file> <name>: a value of a .env file as Compose reads it (as in templates/project/scripts/project.sh).
envvar() {
  [ ! -f "$1" ] || sed -n "s/^$2=//p" "$1" | tail -n 1 | tr -d '\r' | sed \
    -e "s/^\"\([^\"]*\)\".*/\1/;t" -e "s/^'\([^']*\)'.*/\1/;t" \
    -e 's/[[:space:]]#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}
name_of() { [ ! -f "$1" ] || sed -n "s/^name: *[\"']\{0,1\}\([^\"' #]*\).*/\1/p" "$1" | head -n 1; }
# setting <folder> <name>: a setting of the Makefile in <folder>, as make reads it.
# shellcheck disable=SC2016 # $($*) is make's, not the shell's
setting() { make -s --no-print-directory -C "$1" -f Makefile --eval 'proof-setting-%: ; @printf "%s\n" "$($*)"' "proof-setting-$2"; }
rand() { od -An -N16 -tx1 /dev/urandom | tr -d ' \n'; }
# objects <project>: the containers and volumes of a compose project, as words.
objects() {
  { docker ps -a --filter "label=com.docker.compose.project=$1" --format 'container:{{.Names}}'
    docker volume ls --filter "label=com.docker.compose.project=$1" --format 'volume:{{.Name}}'; } | tr '\n' ' '
}
# proof_images: the images named for a proof copy of <repo>, one per line.
proof_images() { docker images --format '{{.Repository}}:{{.Tag}}' | grep -E "^($repo-proof-|$repo-dev-proof-)" || :; }

repo_of() { # repo_of <folder>: <repo> of the project in <folder>, from its compose files
  for e in stage prod; do
    n=$(name_of "$1/docker-compose.$e.yml")
    case "$n" in ?*-"$e") printf '%s' "${n%-"$e"}"; return 0 ;; esac
  done
  n=$(name_of "$1/docker-compose.dev.yml")
  # shellcheck disable=SC2016 # the literal ${DEV_SUFFIX:-} of the dev file's name:
  case "$n" in ?*'-dev${DEV_SUFFIX:-}') printf '%s' "${n%'-dev${DEV_SUFFIX:-}'}"; return 0 ;; ?*-dev) printf '%s' "${n%-dev}"; return 0 ;; esac
  return 1
}

# inside <path>: true when <path> is $t or in it, compared by its physical path when it exists.
# Runs in conditions only.
inside() {
  ip=$1
  [ ! -d "$ip" ] || ip=$(cd "$ip" && pwd -P)
  case "$ip/" in "$t/"*) return 0 ;; esac
  [ -z "${tp:-}" ] || case "$ip/" in "$tp/"*) return 0 ;; esac
  return 1
}

# ---- the copy --------------------------------------------------------------

# cmd_create
#   sh proof.sh create (the header says what it does).
#   Globals:   sets t to its physical path once made.
#   Returns:   0; dies on a refusal (nothing created) or a failure ($t is left for clean).
cmd_create() {
  [ -z "$in_copy" ] || die "this is a folder of the proof copy $t: run create in the project folder $src"
  [ ! -e "$t" ] || die "there is a proof copy already: $t; sh proof.sh clean removes it with its stacks; nothing was created"
  # A build secret is a file outside git, which the copy and its clones do not get: their builds would fail.
  secrets=''
  [ ! -f "$src/Makefile" ] || for s in $(setting "$src" BUILD_SECRETS); do secrets="$secrets ${s#*=}"; done
  [ -z "$secrets" ] || die "BUILD_SECRETS in the Makefile settings names${secrets}: files git ignores, which a proof copy" \
    "and its server clones do not get, so their builds would fail; a project with build secrets cannot be proven in a proof copy; nothing was created"
  for p in "$repo-dev-proof" "$repo-proof-stage" "$repo-proof-prod"; do
    o=$(objects "$p")
    [ -z "$o" ] || die "this machine has ${o% } of $p, which is not this proof copy's: stop and ask the owner; nothing was created"
  done
  i=$(proof_images | tr '\n' ' ')
  [ -z "$i" ] || die "this machine has images of an earlier proof copy of $repo: ${i% }; when no proof copy of $repo runs, docker rmi ${i% } removes them; nothing was created"
  mkdir -p "$t"
  t=$(cd "$t" && pwd -P)
  say "the proof copy of $src: $t"
  printf '%s\n%s\n' "$repo" "$src" > "$t/.proof"
  # The compose projects this machine had before: clean keeps their volumes and images.
  { docker ps -a --format '{{.Label "com.docker.compose.project"}}'
    docker volume ls --format '{{.Label "com.docker.compose.project"}}'; } | grep . | sort -u > "$t/.before" || :
  git init -q -b proof-copy "$t/p"
  sha='' branch=''
  if [ -n "$git_mode" ]; then
    sha=$(git -C "$src" rev-parse -q --verify HEAD) || sha=''
    branch=$(git -C "$src" symbolic-ref -q --short HEAD) || branch=''
    # The settings of the project's own git config that decide what git add reads from its files.
    for k in core.fileMode core.autocrlf core.eol core.symlinks core.ignoreCase core.precomposeUnicode; do
      ! v=$(git -C "$src" config --local --get "$k") || git -C "$t/p" config "$k" "$v"
    done
    ex=$(git -C "$src" rev-parse --path-format=absolute --git-path info/exclude)
    [ ! -f "$ex" ] || cp "$ex" "$t/p/.git/info/exclude"
    if [ -n "$sha" ]; then
      # The history of the project's last commit, read through an alternate and then copied into
      # the copy's own pack, so the copy needs nothing of the project's .git afterwards.
      printf '%s\n' "$(git -C "$src" rev-parse --path-format=absolute --git-common-dir)/objects" > "$t/p/.git/objects/info/alternates"
      git -C "$t/p" update-ref HEAD "$sha"
      git -C "$t/p" repack -a -d -q
      rm "$t/p/.git/objects/info/alternates"
      git -C "$t/p" read-tree HEAD
    fi
  fi
  # The files as they are: git add with the project folder as the work tree and the copy's index,
  # so the objects go into the copy only.
  git --git-dir="$t/p/.git" --work-tree="$src" add -A
  if [ -z "$sha" ] || ! git -C "$t/p" cat-file -e "HEAD:.env" 2>/dev/null; then
    git --git-dir="$t/p/.git" --work-tree="$src" rm -q --cached --ignore-unmatch -- .env
  fi
  git -C "$t/p" checkout-index -a -f -u
  [ -f "$t/p/Makefile" ] || die "the project has no Makefile (the standard's templates/project/Makefile); sh proof.sh clean removes $t"
  stage_branch=$(setting "$t/p" STAGE_BRANCH) prod_branch=$(setting "$t/p" PROD_BRANCH)
  [ -n "$stage_branch" ] && [ -n "$prod_branch" ] \
    || die "the Makefile settings have no STAGE_BRANCH or PROD_BRANCH; sh proof.sh clean removes $t"
  # The project's branch, or STAGE_BRANCH; the copy was made on the branch proof-copy.
  b=${branch:-$stage_branch}
  if [ -z "$sha" ]; then git -C "$t/p" symbolic-ref HEAD "refs/heads/$b"
  elif [ "$b" != proof-copy ]; then git -C "$t/p" branch -q -m "$b"; fi
  # The -proof names: no container, volume, network or image shared with a stack of this machine.
  images=$(setting "$t/p" IMAGES)
  for e in stage prod; do
    f=$t/p/docker-compose.$e.yml
    [ -f "$f" ] || continue
    set -- -e "s/^name:\([[:space:]]*[\"']\{0,1\}\)$repo-$e\([^a-z0-9_-]\{0,1\}\)/name:\1$repo-proof-$e\2/"
    for i in $images; do
      set -- "$@" -e "s/^\([[:space:]]*image:[[:space:]]*[\"']\{0,1\}\)$repo-$i:/\1$repo-proof-$i:/"
    done
    sed "$@" "$f" > "$f.new"
    mv "$f.new" "$f"
    [ "$(name_of "$f")" = "$repo-proof-$e" ] || die "the name: line of docker-compose.$e.yml did not become $repo-proof-$e; sh proof.sh clean removes $t"
  done
  : > "$t/.networks"
  for v in $(setting "$t/p" NETWORKS); do
    n=$(envvar "$t/p/.env.example" "$v")
    [ -n "$n" ] || continue
    sed "s|^$v=.*|$v=$n-proof|" "$t/p/.env.example" > "$t/p/.env.example.new"
    mv "$t/p/.env.example.new" "$t/p/.env.example"
    # Made by make bootstrap of the copy; clean removes it.
    docker network inspect "$n-proof" >/dev/null 2>&1 || printf '%s\n' "$n-proof" >> "$t/.networks"
  done
  git -C "$t/p" add -A
  git -C "$t/p" config user.name >/dev/null || git -C "$t/p" config user.name proof
  git -C "$t/p" config user.email >/dev/null || git -C "$t/p" config user.email proof@localhost
  git -C "$t/p" commit -q --no-verify --allow-empty -m "Proof copy of $src: its files as they are, the -proof names"
  git init -q --bare "$t/remote.git"
  git -C "$t/p" remote add origin "$t/remote.git"
  # Pushed before make bootstrap sets the hooks: the commit of the copy itself runs no gates.
  set -- "HEAD:refs/heads/$stage_branch"
  [ "$prod_branch" = "$stage_branch" ] || set -- "$@" "HEAD:refs/heads/$prod_branch"
  git -C "$t/p" push -q --no-verify origin "$@"
  git -C "$t/remote.git" symbolic-ref HEAD "refs/heads/$stage_branch"
  (cd "$t/p" && make --no-print-directory bootstrap NAME=proof) \
    || die "make bootstrap NAME=proof failed in $t/p (above); sh proof.sh clean removes $t"
  say "$t/p: commit $(git -C "$t/p" rev-parse HEAD) on its branch $(git -C "$t/p" symbolic-ref --short HEAD)," \
    "pushed to $t/remote.git as $stage_branch and $prod_branch; its dev stack: make dev in $t/p"
}

# ---- server clones ---------------------------------------------------------

server_env() { # server_env <clone> <env>: the clone's .env from its .env.example, mode 600
  # The start of this hour: past, so the backup service counts today's run as done (also just after
  # midnight, where an hour back would be yesterday's 23:00).
  bt=$(date -u +%H):00
  gid=$(stat -c %g /var/run/docker.sock 2>/dev/null) || gid=''
  : > "$1/.env.new"
  chmod 600 "$1/.env.new"
  while IFS= read -r l || [ -n "$l" ]; do
    case "$l" in
      '#'*|'') ;;
      *=*) k=${l%%=*}
        case "$k" in
          PROJECT_ENV) l="$k=$2" ;;
          DOCKER_GID) [ -z "$gid" ] || l="$k=$gid" ;;
          BACKUP_TIME) l="$k=$bt" ;;
          BACKUP_COPY_TO) l="$k=/backup/.copy" ;;
          *_PORT) l="$k=0" ;;
          *) case "$l" in *change-me*) l="$k=$(rand)" ;; esac ;;
        esac ;;
    esac
    printf '%s\n' "$l"
  done < "$1/.env.example" >> "$1/.env.new"
  mv "$1/.env.new" "$1/.env"
}

cmd_deploy() { # cmd_deploy stage|prod: sh proof.sh stage, prod (the header says what they do)
  e=$1
  [ -d "$t/p" ] && [ -d "$t/remote.git" ] || die "there is no proof copy at $t: run sh proof.sh create in the project folder first"
  say "the proof copy of $src: $t"
  if [ "$e" = stage ]; then b=$(setting "$t/p" STAGE_BRANCH); else b=$(setting "$t/p" PROD_BRANCH); fi
  c=$t/$e
  if [ ! -d "$c" ]; then
    o=$(objects "$repo-proof-$e")
    [ -z "$o" ] || die "this machine has ${o% } of $repo-proof-$e, which is not this proof copy's: stop and ask the owner; nothing was created"
    git -C "$t/remote.git" rev-parse -q --verify "refs/heads/$b" >/dev/null || die "$t/remote.git has no branch $b"
    rm -rf "$c.new"
    git clone -q -b "$b" "$t/remote.git" "$c.new"
    [ -f "$c.new/docker-compose.$e.yml" ] || { rm -rf "$c.new"; die "the branch $b has no docker-compose.$e.yml: this project has no $e"; }
    [ -f "$c.new/.env.example" ] || { rm -rf "$c.new"; die "the branch $b has no .env.example to make the $e clone's .env from"; }
    server_env "$c.new" "$e"
    mv "$c.new" "$c"
    say "the $e clone: $c, branch $b; its .env from .env.example (PROJECT_ENV=$e, test values for change-me, free ports, mode 600)"
    # Images of the commit before the first deploy of the copy: a make image-scan in $t/p builds
    # the same ones, and then make stage prints no build: line for them.
    tr=$(git -C "$c" rev-parse 'HEAD^{tree}')
    if [ "$e" = stage ]; then o=$t/prod; else o=$t/stage; fi
    [ -d "$o" ] || for i in $(setting "$c" IMAGES); do
      ! docker image inspect "$repo-proof-$i:$tr" >/dev/null 2>&1 \
        || say "note: $repo-proof-$i:$tr is on this machine before the first deploy (make image-scan in $t/p builds it too): make $e builds no $i"
    done
  fi
  (cd "$c" && make --no-print-directory "$e") || die "make $e failed in $c (above)"
  (cd "$c" && make --no-print-directory status) || :
}

# ---- clean -----------------------------------------------------------------

# cmd_clean
#   sh proof.sh clean (the header says what it does).
#   Globals:   sets tp (read by inside).
#   Returns:   0 when everything is removed; dies when something is left (it names it).
cmd_clean() {
  if [ ! -d "$t" ]; then
    left=''
    for p in "$repo-dev-proof" "$repo-proof-stage" "$repo-proof-prod"; do left="$left$(objects "$p")"; done
    left="$left$(proof_images | tr '\n' ' ')"
    [ -n "$left" ] || { say "nothing to clean: there is no proof copy at $t"; return 0; }
    die "there is no proof copy at $t, but this machine has ${left% } of a proof copy of $repo: they are not" \
      "this copy's (another proof copy may run); remove them by hand only when none runs"
  fi
  tp=$(cd "$t" && pwd -P)
  say "removing the proof copy $t"
  bad=''
  # Every compose project of the copy: the fixed names, those whose containers were started in $t,
  # and those the compose files of the folders of $t name (their containers may be gone already).
  lines=$(docker ps -a --format '{{.Label "com.docker.compose.project"}} {{.Label "com.docker.compose.project.working_dir"}}')
  cand="$repo-dev-proof $repo-proof-stage $repo-proof-prod"
  cand="$cand $(printf '%s\n' "$lines" | while read -r p wd; do [ -z "$p" ] || ! inside "${wd:-/nonexistent}" || printf '%s ' "$p"; done)"
  for d in "$t"/*/; do
    for f in "$d"compose.yaml "$d"compose.yml "$d"docker-compose.yaml "$d"docker-compose.yml "$d"docker-compose.*.yml; do
      [ -f "$f" ] || continue
      n=$( (cd "$d" && docker compose -f "$f" config 2>/dev/null) | sed -n 's/^name: //p' | head -n 1)
      cand="$cand $n"
    done
  done
  helpers='' removed='' kept=''
  # shellcheck disable=SC2086 # one word per project
  for p in $(printf '%s\n' $cand | sort -u); do
    outside=$(printf '%s\n' "$lines" | while read -r q wd; do [ "$q" != "$p" ] || inside "${wd:-/nonexistent}" || printf '%s ' "${wd:-?}"; done)
    if [ -n "$outside" ]; then
      say "NOT removed: $p, which also has containers started in ${outside% }: not this proof copy's"
      kept="$kept $p"
      continue
    fi
    helpers="$helpers $(docker ps -a --filter "label=com.docker.compose.project=$p" --format '{{.Image}}' | tr '\n' ' ')"
    ids=$(docker ps -aq --filter "label=com.docker.compose.project=$p")
    # shellcheck disable=SC2086 # one word per container
    [ -z "$ids" ] || docker rm -f $ids >/dev/null || bad=1
    if [ -f "$t/.before" ] && grep -qxF "$p" "$t/.before"; then
      say "$p had containers or volumes before the proof copy was made: its containers started in $t are removed, its volumes and images kept"
      continue
    fi
    vols=$(docker volume ls -q --filter "label=com.docker.compose.project=$p")
    # shellcheck disable=SC2086 # one word per volume
    [ -z "$vols" ] || docker volume rm $vols >/dev/null || bad=1
    nets=$(docker network ls -q --filter "label=com.docker.compose.project=$p")
    # shellcheck disable=SC2086 # one word per network
    [ -z "$nets" ] || docker network rm $nets >/dev/null || bad=1
    removed="$removed $p"
  done
  if [ -f "$t/.networks" ]; then
    while read -r n; do
      ! docker network inspect "$n" >/dev/null 2>&1 || docker network rm "$n" >/dev/null || bad=1
    done < "$t/.networks"
  fi
  # A project left alone keeps $t, so clean can run again once it is sorted out, and the images
  # named for the proof copy, which its containers may use.
  imgs=''
  if [ -n "$kept" ]; then
    bad=1
  else
    # The backup sets belong to the backup user of the server clones: a root container of an image
    # the copy used removes what this user cannot.
    rm -rf "$t" 2>/dev/null || :
    if [ -e "$t" ]; then
      helpers="$helpers $(proof_images | tr '\n' ' ')"
      set --
      for x in "$t"/* "$t"/.[!.]* "$t"/..?*; do
        [ -e "$x" ] || [ -L "$x" ] || continue
        set -- "$@" "/t/${x#"$t"/}"
      done
      # shellcheck disable=SC2086 # one word per image
      for i in $(printf '%s\n' $helpers | grep -v '^<none>' | awk '!seen[$0]++'); do
        docker image inspect "$i" >/dev/null 2>&1 || continue
        ! docker run --rm --network none --user 0:0 --entrypoint rm -v "$tp:/t" "$i" -rf "$@" >/dev/null 2>&1 || break
      done
      rm -rf "$t" 2>/dev/null || :
      [ ! -e "$t" ] || { say "NOT removed: $t (files of another user, and no image of the copy could remove them as root)"; bad=1; }
    fi
    imgs=$(proof_images)
  fi
  for p in $removed; do
    imgs="$imgs
$(docker images --filter "label=com.docker.compose.project=$p" --format '{{.Repository}}:{{.Tag}} {{.ID}}' \
      | awk '{ print ($1 ~ /<none>/) ? $2 : $1 }')"
  done
  for i in $(printf '%s\n' "$imgs" | grep . | sort -u); do
    docker rmi "$i" >/dev/null || { say "NOT removed: the image $i (above)"; bad=1; }
  done
  [ -z "$kept" ] || die "clean left ${kept# } alone (above), and kept $t: clean again once that is sorted out"
  [ -z "$bad" ] || die "clean did not remove everything (above)"
  say "removed: the stacks${removed:+ }${removed# }, their volumes, networks and images, and $t"
}

# ---- main ------------------------------------------------------------------

main() {
  # Nothing from the caller's environment reaches Compose or make: COMPOSE_PROJECT_NAME would give a
  # stack of the copy another stack's name, and MAKEFLAGS would pass variables to the copy's make.
  unset COMPOSE_FILE COMPOSE_PROJECT_NAME COMPOSE_PROFILES MAKEFLAGS GNUMAKEFLAGS MAKELEVEL MFLAGS

  cmd=${1:-}
  case "$cmd" in create|stage|prod|clean|path) ;; *) die "usage: sh proof.sh create | stage | prod | clean | path" ;; esac

  # The project folder and $t. A folder of the copy finds $t by the file .proof in it, which holds
  # <repo> and the project folder. A .proof elsewhere (copied, or left in an ordinary folder) must
  # not make that folder $t, which clean removes: $t has the name create gives the copy of that
  # project folder, and its remote.git. Its name only, since its parent is the TMPDIR of create.
  here=$(pwd -P)
  in_copy=''
  if [ -f "$here/../.proof" ]; then
    t=$(cd "$here/.." && pwd -P) in_copy=1
    repo=$(sed -n 1p "$t/.proof") src=$(sed -n 2p "$t/.proof")
    want=$repo-proof-$(printf '%s' "$src" | git hash-object --stdin | cut -c1-6)
    [ "${t##*/}" = "$want" ] && [ -d "$t/remote.git" ] \
      || die "$t has a file .proof, but is not the proof copy it names ($want of $src, with remote.git):" \
        "nothing was changed; run proof.sh in the project folder or in a folder of its proof copy"
  else
    src=$here
    if [ -e .git ]; then
      [ "$(git rev-parse --show-toplevel 2>/dev/null)" = "$src" ] || [ "$(cd "$(git rev-parse --show-toplevel)" && pwd -P)" = "$src" ] \
        || die "$src is not the top folder of its git repository: run proof.sh there"
      git_mode=1
    else
      git_mode=''
      ! top=$(git rev-parse --show-toplevel 2>/dev/null) \
        || die "$src has no .git, but is a folder of the git repository $top: run proof.sh in $top"
    fi
    repo=$(repo_of "$src") || die "$src has no docker-compose.stage.yml, docker-compose.prod.yml or docker-compose.dev.yml with a name: line: run proof.sh in the project folder"
    base=${TMPDIR:-/tmp}
    t=${base%/}/$repo-proof-$(printf '%s' "$src" | git hash-object --stdin | cut -c1-6)
  fi

  case "$cmd" in
    create) cmd_create ;;
    stage|prod) cmd_deploy "$cmd" ;;
    clean) cmd_clean ;;
    path) printf '%s\n' "$t" ;;
  esac
}

main "$@"
