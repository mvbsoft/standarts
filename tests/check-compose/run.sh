#!/bin/sh
# Runs templates/check-compose against the fixtures: good must pass, bad must report every rule.
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
for case in good bad; do
  cp -R "$root/tests/check-compose/$case" "$tmp/$case"
  cp -R "$root/templates/check-compose/scripts" "$tmp/$case/scripts"
  if sh "$tmp/$case/scripts/check-compose.sh" > "$tmp/$case.out" 2>&1; then code=0; else code=1; fi
  if [ "$case" = good ] && [ "$code" -ne 0 ]; then
    echo "FAIL good: expected exit 0"; cat "$tmp/$case.out"; fail=1
  fi
  if [ "$case" = bad ] && [ "$code" -eq 0 ]; then
    echo "FAIL bad: expected a non-zero exit"; fail=1
  fi
done
cp -R "$root/tests/check-compose/good" "$tmp/prod-only"
rm "$tmp/prod-only/docker-compose.stage.yml"
cp -R "$root/templates/check-compose/scripts" "$tmp/prod-only/scripts"
sh "$tmp/prod-only/scripts/check-compose.sh" > "$tmp/prod-only.out" 2>&1 \
  || { echo "FAIL prod-only: expected exit 0"; cat "$tmp/prod-only.out"; fail=1; }
mkdir "$tmp/none"
cp -R "$root/templates/check-compose/scripts" "$tmp/none/scripts"
if sh "$tmp/none/scripts/check-compose.sh" > "$tmp/none.out" 2>&1; then
  echo "FAIL none: expected a non-zero exit without stage and prod files"; fail=1
fi
for rule in user cap_add; do
  grep -q "exception db: $rule" "$tmp/good.out" || { echo "FAIL good: the $rule exception is not printed"; fail=1; }
done
for rule in ports build own-image user image healthcheck restart depends_on limits logging \
    no-new-privileges cap_drop read_only privileged network_mode docker-sock "cache: cap_add: .*(NET_ADMIN)" \
    "unknown rule 'typo-rule'" "healthcheck: no reason given" "no service 'ghost'" \
    "secret DB_PASSWORD is not required" "secret JWT_SECRET is not required" \
    "secret API_TOKEN is not required" "secret SESSION_KEY is not required" \
    "IMAGE_TAG must be required" "migrate: own-image: .*(fixture-app:v1)" \
    "legacy: own-image: .*(ghcr.io/example/fixture-app:0000000000000000000000000000000000000000)" \
    "sized: memswap: .*(memswap_limit not set, memory 536870912)" \
    "swapping: memswap: .*(memswap_limit 1073741824, memory 536870912)" \
    "debug: privileged" "cron: ports: .*a random port->9000" "cache: image" "proxy: image" \
    "db: image: .*(redis:latest)" "sized: image" "swapping: image" \
    "floating: image: .*(busybox:latest@sha256:" \
    "worker: depends_on: dependency without condition: service_healthy (migrate: service_completed_successfully)" \
    "docker/app/Dockerfile:1: # syntax=docker/dockerfile:1 is not pinned by version and digest" \
    "docker/app/Dockerfile:2: FROM python:3.12.13-slim is not pinned by version and digest" \
    "docker/app/Dockerfile:4: FROM \${TOOLS} is not pinned by version and digest" \
    "docker/app/Dockerfile:6: COPY --from=busybox:1.36.1 is not pinned by version and digest" \
    "docker/app/Dockerfile:7: RUN --mount from=alpine:3.20 is not pinned by version and digest" \
    "docker/app/Dockerfile:11: COPY --from=busybox:latest@sha256:.* is not pinned by version and digest" \
    "docker/app/Dockerfile:17: FROM busybox:1.36.1 is not pinned by version and digest"; do
  grep -q "docker-compose.stage.yml: .*$rule" "$tmp/bad.out" || { echo "FAIL bad: missing: $rule"; fail=1; }
done
# Pinned by a tag and a digest: not reported. In a Dockerfile, FROM and --from of an earlier stage
# (tools, line 10) is not an image, and $((1<<3)) on line 12 starts no heredoc that would hide line 17:
# the seven lines above are all, once, though four services run the image.
if grep -q "docker-compose.stage.yml: debug: image" "$tmp/bad.out"; then
  echo "FAIL bad: alpine:3.20@sha256:… reported as not pinned"; fail=1
fi
[ "$(grep -c "docker-compose.stage.yml: docker/app/Dockerfile:" "$tmp/bad.out")" -eq 7 ] \
  || { echo "FAIL bad: expected 7 Dockerfile lines"; fail=1; grep "Dockerfile:" "$tmp/bad.out" || :; }
# Without .env.example nothing renders: the script says so instead of guessing at a variable.
cp -R "$root/tests/check-compose/good" "$tmp/no-example"
rm "$tmp/no-example/.env.example"
cp -R "$root/templates/check-compose/scripts" "$tmp/no-example/scripts"
if sh "$tmp/no-example/scripts/check-compose.sh" > "$tmp/no-example.out" 2>&1; then
  echo "FAIL no-example: expected a non-zero exit"; fail=1
fi
for f in docker-compose.stage.yml docker-compose.prod.yml; do
  grep -q "check-compose: $f: not checked: there is no .env.example" "$tmp/no-example.out" \
    || { echo "FAIL no-example: $f: missing the no .env.example line"; cat "$tmp/no-example.out"; fail=1; }
done
if grep -q "a variable is missing" "$tmp/no-example.out"; then
  echo "FAIL no-example: blames a missing variable"; fail=1
fi
grep -q "docker-compose.stage.yml: worker: user" "$tmp/bad.out" || { echo "FAIL bad: missing: user: root on an own image"; fail=1; }
# The USER of the runtime stage follows FROM <stage>: the last USER along the chain; an image from
# outside counts as root.
py=python:3.12.13-slim@sha256:229a2c5bfa27522db7815ea81f9bed70af17ccb9de9fc7ad142b1877b5830d36
user_case() { # user_case <name> pass|fail <Dockerfile lines>
  c=$1 want=$2; shift 2
  cp -R "$root/tests/check-compose/good" "$tmp/$c"
  cp -R "$root/templates/check-compose/scripts" "$tmp/$c/scripts"
  printf '%s\n' "$@" > "$tmp/$c/docker/app/Dockerfile"
  if sh "$tmp/$c/scripts/check-compose.sh" > "$tmp/$c.out" 2>&1; then code=0; else code=1; fi
  if [ "$want" = pass ] && [ "$code" -ne 0 ]; then echo "FAIL $c: expected exit 0"; cat "$tmp/$c.out"; fail=1; fi
  if [ "$want" = fail ] && ! grep -q "docker-compose.stage.yml: app: user: service runs as root" "$tmp/$c.out"; then
    echo "FAIL $c: expected app: user"; cat "$tmp/$c.out"; fail=1
  fi
}
user_case inherited pass "FROM $py AS base" "RUN useradd -u 10001 app" "USER app" \
  "FROM base AS runtime" 'CMD ["python", "-c", "print(1)"]'
user_case inherited-twice pass "FROM $py AS base" "USER 10001" "FROM base AS deps" \
  "FROM --platform=linux/amd64 deps AS Runtime" "FROM runtime AS dev" "USER root"
user_case root-in-between fail "FROM $py AS base" "USER 10001" "FROM base AS deps" "USER root" \
  "FROM deps AS runtime"
user_case outside-image fail "FROM $py AS base" "USER 10001" "FROM $py AS runtime"
[ "$fail" -eq 0 ] && echo "check-compose tests: OK"
exit "$fail"
