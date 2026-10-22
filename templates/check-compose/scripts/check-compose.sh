#!/bin/sh
# check-compose 4.0.0 — from the standard's templates/check-compose; change it there, not here.
# Checks the rules of standard ENV-01 on whichever of the stage and prod files exist, rendered from
# .env.example, with every profile, so a service behind a profile is checked too.
#
# Usage:   sh scripts/check-compose.sh   (it works in the folder above scripts/, the repo root)
# Reads:   docker-compose.stage.yml, docker-compose.prod.yml and .env.example there.
# Output:  "check-compose: <file>: …" lines on stdout; for each file checked the last one is OK or
#          FAIL (scripts/check-compose.py). What docker compose itself reports goes to stderr.
# Exit:    0 every file passes; 1 a file fails or cannot be checked, or neither file exists.
# Shell:   POSIX sh. The host needs only docker and sh: the checks run in a python image pinned by
#          version and digest.
set -eu
cd "$(dirname "$0")/.."
img=python:3.12.13-slim@sha256:229a2c5bfa27522db7815ea81f9bed70af17ccb9de9fc7ad142b1877b5830d36
status=0
found=0
for f in docker-compose.stage.yml docker-compose.prod.yml; do
  [ -f "$f" ] || continue
  found=1
  if [ ! -f .env.example ]; then
    echo "check-compose: $f: not checked: there is no .env.example to render it from; add one with every variable the file requires (change-me for a secret)"
    status=1; continue
  fi
  if ! json=$(env -u COMPOSE_FILE -u COMPOSE_PROJECT_NAME -u COMPOSE_PROFILES \
      docker compose -f "$f" --env-file .env.example --profile '*' config --no-env-resolution --format json); then
    echo "check-compose: $f: does not render from .env.example (a variable is missing?)"; status=1; continue
  fi
  printf '%s' "$json" | docker run --rm -i --network none -v "$PWD:/repo:ro" -w /repo "$img" \
    python -I scripts/check-compose.py "$f" || status=1
done
[ "$found" -eq 1 ] || { echo "check-compose: neither docker-compose.stage.yml nor docker-compose.prod.yml exists"; status=1; }
exit "$status"
