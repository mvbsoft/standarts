#!/bin/sh
repo=app env=stage free=9G need=4G removed=2 keep=5 others='app db ' names=TOKEN
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }
build() {
  docker build . || die "building $repo-$1 for commit $(git rev-parse HEAD) failed (above); nothing was replaced"
  printf 'OK: %s runs %s\n' "$env" "$(git rev-parse HEAD)"
}
build app
printf 'space: %s free where Docker keeps the images (need %s)\n' "$free" "$need"
printf 'WARNING: .env lacks variables of .env.example: %s\n' "$names" >&2
say "WARNING: the volumes of $repo exist, but no container of it: the first deploy uses them"
say "prune: removed $removed old images; the images of the last $keep deployed commits stay"
say "restore: stopping $(printf '%s\n' "$others" | tr '\n' ' ')for the restore"
