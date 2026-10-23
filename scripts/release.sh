#!/bin/sh
# Releases the standard: `make release VERSION=X.Y.Z`, run on `next`.
# Refuses while a question is open, a check fails or the tree is dirty. Pushing is left to the maintainer.
set -eu
cd "$(dirname "$0")/.."
v=${1:-}
fail() { echo "release: $*"; exit 1; }

echo "$v" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || fail "usage: make release VERSION=X.Y.Z"
[ "$(git rev-parse --abbrev-ref HEAD)" = next ] || fail "run it on the next branch"
[ -z "$(git status --porcelain)" ] || fail "the working tree is not clean"
! git rev-parse -q --verify "refs/tags/v$v" >/dev/null || fail "tag v$v already exists"
! git rev-parse -q --verify refs/heads/main >/dev/null || git merge-base --is-ancestor main next \
  || fail "main has commits that next has not, so main cannot fast-forward: merge main into next (git merge main), then release again"
for q in .work/QUESTIONS.md .work/QUESTIONS.uk.md; do
  [ -f "$q" ] || fail "$q is missing, so open questions cannot be checked"
done
open=$(cat .work/QUESTIONS.md .work/QUESTIONS.uk.md | grep -c '^### Q-' || true)
[ "$open" -eq 0 ] || fail "$open question headings remain in .work/QUESTIONS.md and .work/QUESTIONS.uk.md"
sed -n '/^## Unreleased/,/^## /p' CHANGELOG.md | grep -q '^- ' || fail "CHANGELOG.md has nothing under Unreleased"
for f in README.md README.uk.md; do
  grep -q '^STANDARD_REF=' "$f" || fail "$f has no line STANDARD_REF= in its prompt"
done
make check
make check-stacks

for f in $(git ls-files '*.md'); do
  grep -Eq '^> (Version|Версія) ' "$f" || continue
  sed -E "s/^> (Version|Версія) [^ ]+/> \1 $v/" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
done
# The prompt of each README fetches the release it names.
for f in README.md README.uk.md; do
  sed "s/^STANDARD_REF=.*/STANDARD_REF=v$v/" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
done
awk -v head="## v$v — $(date -u +%Y-%m-%d)" '{ print } /^## Unreleased$/ { print ""; print head }' CHANGELOG.md > CHANGELOG.md.tmp \
  && mv CHANGELOG.md.tmp CHANGELOG.md
make check-docs

git commit --quiet -am "Release v$v"
if git rev-parse -q --verify refs/heads/main >/dev/null; then
  git checkout --quiet main && git merge --quiet --ff-only next
else
  git checkout --quiet -b main
fi
git tag -a "v$v" -m "v$v"
git checkout --quiet next
echo "release: v$v is tagged on main. Push with: git push origin main next v$v"
