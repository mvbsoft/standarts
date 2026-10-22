# The standard's own checks. The host needs only make, sh, git and docker.
PYTHON := python:3.12.13-slim@sha256:229a2c5bfa27522db7815ea81f9bed70af17ccb9de9fc7ad142b1877b5830d36
# koalaman/shellcheck:stable of 2025-08-04 (the v0.11.0 release), pinned by digest
SHELLCHECK := koalaman/shellcheck@sha256:bb596a0d169b85ddd81d8b6d3a2ff6d5baf5fca10b97f575ebc647c3dff62b3d
SHELL_FILES := $(wildcard $(shell git ls-files --cached --others --exclude-standard '*.sh')) templates/project/.githooks/pre-push

.PHONY: check check-docs lint test check-stacks release

check: check-docs lint test

check-docs:
	docker run --rm --network none -v "$(CURDIR):/repo:ro" -w /repo $(PYTHON) python -I scripts/check-docs.py

lint:
	docker run --rm --network none -v "$(CURDIR):/repo:ro" -w /repo $(SHELLCHECK) $(SHELL_FILES)

test:
	sh tests/check-compose/run.sh
	sh tests/project/run.sh
	sh tests/backup/run.sh
	sh tests/status/run.sh
	sh tests/check-docs/run.sh
	sh tests/proof/run.sh

# Not part of check: its first run downloads the pinned tools of three stacks (about 2 minutes
# once they are cached). STACKS="python php ts" picks some.
check-stacks:
	sh tests/stacks/run.sh

release:
	sh scripts/release.sh "$(VERSION)"
