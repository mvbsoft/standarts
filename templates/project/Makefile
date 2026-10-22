# project template 1.0.0 — from the standard's templates/project; change only the settings block
# and the project-targets block, with one written exception: mutation testing declined
# (templates/README.md of the standard, "Mutation testing declined").
# Every project has the same targets with the same behaviour (standard ENV-05, ENV-09).
# `make help` lists them by where they work. The host needs only the tools of standard PRN-01.

# ---- Settings: this project's values ---------------------------------------------------------
# Own images: docker/<name>/Dockerfile, built on the server by make stage / make prod from the
# commit as <repo>-<name>:<tree> (the image: lines of the stage and prod files), where <tree> is the
# git tree hash of the commit (git rev-parse <commit>^{tree}): commits with the same content, such
# as a merge into the prod branch, a re-deploy or a rollback, reuse the images already built there.
IMAGES = app backup status
# How many deployed commits keep their images on a server, for make rollback; each deploy removes
# the images of older ones. A whole number of at least 1: make dev and a deploy refuse another.
KEEP_IMAGES = 5
# Build secrets, for a private dependency the build fetches: space-separated <id>=<file> pairs,
# the file relative to the project folder and outside git (a name .gitignore ignores, such as
# .env.<name>), on every machine that builds the images. Each is passed to docker build as
# --secret id=<id>,src=<file>; a Dockerfile step reads it with RUN --mount=type=secret,id=<id>, and
# the image never holds it. The dev build gets each one too, from docker-compose.dev.yml (its
# comments show how); make dev refuses when the two differ. Empty means none.
BUILD_SECRETS =
# The stage and prod service that runs the migrations (in a one-off container of the new image).
APP = app
# Commands, written as in a shell: quotes work; write $$ for a $ that the container's shell
# expands (so $(…) is written $$(…)) and \# for a #, which make would otherwise read as a comment.
# Empty means "this project has none". All run in the dev container, but for three: MIGRATE runs
# on a server in a one-off container of $(APP) as sh -c past the image's ENTRYPOINT, so the
# runtime image needs /bin/sh (in dev in the dev container); MUTATION and MUTATION_DIFF run in the
# mutation container (the dev image with the limits MUTATION_CPUS and MUTATION_MEM of .env).
MIGRATE =
SEED =
RUN =
# The checks (standard QLT-01), one base target each, none part of another:
#   LINT     make lint: the code does not run: format check, lint, types, shellcheck, the links
#            of the docs (lychee --offline), architecture contracts
#   TEST     make test: the code runs, fast and offline: unit tests, tests against a real
#            database, property-based tests
#   E2E      make e2e: the whole application runs, slowly: the API contract, the browser, calls
#            to outside APIs
#   SECRETS  the secret scan (gitleaks), offline; SECURITY: SAST and the dependency audit, which
#            needs the network; make security runs SECRETS, then SECURITY
# LINT, TEST and SECRETS are mandatory: empty (not set up yet) refuses, and fails make gates and
# make verify; off says this project does not want that check (the summary shows off). E2E and
# SECURITY may stay empty (the summary shows skip) or be off.
# make infra has no setting: check-compose, parity, then backup-test when there is a backup
# service. The group targets add no checks of their own: make gates runs LINT, TEST and SECRETS
# (the pre-push hook runs it), make verify runs lint, test, e2e, security and infra; both end with
# a summary of one line per base target.
LINT =
TEST =
E2E =
SECRETS =
SECURITY =
# Run by hand only, never by the gates or a hook: FIX (make fix) the fixers of the LINT tools in
# their safe mode, such as ruff format and ruff check --fix; mutation testing. MUTATION_DIFF names
# its base itself, for example infection --git-diff-lines --git-diff-base=origin/$(STAGE_BRANCH)
# (standard QLT-01).
FIX =
# Mutation testing (QLT-01, R): removed as a whole when the owner says no (templates/README.md of the standard, "Mutation testing declined").
MUTATION =
MUTATION_DIFF =
# make lint also checks the Dockerfile of every own image (IMAGES) with docker build --check, on
# the host, before LINT, also with LINT = off (its summary line stays off unless the check fails);
# off says this project does not want that check.
DOCKERFILE_CHECK =
# The .env variables that hold the names of the external networks the compose files expect (for
# example PROXY_NETWORK); make bootstrap creates those networks.
NETWORKS =
# The branches the servers follow (standard ENV-09).
STAGE_BRANCH = main
PROD_BRANCH = prod
# ----------------------------------------------------------------------------------------------

SHELL := /bin/sh
.DEFAULT_GOAL := help
DEV := docker compose -f docker-compose.dev.yml
P := sh scripts/project.sh
# NAME (the name of a dev copy), S (one service), SET, FROM, NO_SAFETY, CONFIRM and RISK count only
# on make's command line, never from the environment: WSL, for one, sets NAME to the machine's name,
# and a CONFIRM=yes exported in a shell would confirm every make restore. RISK=yes goes on after a
# warned estimate (free space, a failed backup before a migration) when the input is not a
# terminal; in a terminal the command asks y/N instead. project.sh gets them as DEV_NAME, ARG_S,
# ARG_SET, ARG_FROM, ARG_NO_SAFETY, ARG_CONFIRM and ARG_RISK.
arg = $(if $(filter command line,$(origin $(1))),$($(1)))
DEV_NAME := $(call arg,NAME)
ARG_S := $(call arg,S)
ARG_SET := $(call arg,SET)
ARG_FROM := $(call arg,FROM)
ARG_NO_SAFETY := $(call arg,NO_SAFETY)
ARG_CONFIRM := $(call arg,CONFIRM)
ARG_RISK := $(call arg,RISK)
# GNU make counts the variables of an exported MAKEFLAGS or GNUMAKEFLAGS, and those a parent make
# passes down, as command-line ones too; CONFIRM=yes and RISK=yes count only when ps shows them on
# the command line of this make, whose process id this is.
MAKE_PID := $(shell echo $$PPID)
export IMAGES APP MIGRATE SEED RUN LINT TEST E2E SECRETS SECURITY FIX MUTATION MUTATION_DIFF \
	DOCKERFILE_CHECK STAGE_BRANCH PROD_BRANCH NETWORKS KEEP_IMAGES BUILD_SECRETS DEV_NAME ARG_S \
	ARG_SET ARG_FROM ARG_NO_SAFETY ARG_CONFIRM ARG_RISK MAKE_PID

.PHONY: help bootstrap dev shell down logs seed run migrate lint test e2e security infra gates \
	verify fix mutation mutation-diff parity check-compose image-scan stage prod images restart \
	rollback status tuning-check backup backup-list backup-drill restore-drill backup-status \
	backup-copy-check backup-test restore

##@ Dev

dev: ## build what changed, start the dev stack, migrate, print the addresses (NAME=<n>: a copy of its own)
	@$(P) bootstrap
	@$(P) need dev
	$(DEV) up -d --build --wait
	@$(P) migrate
	@$(DEV) ps --format 'table {{.Service}}\t{{.Status}}\t{{.Ports}}'

run: ## run the application in the dev container
	@$(P) in-dev RUN

shell: ## a shell in the dev container
	$(DEV) exec dev sh

seed: ## fill the dev database with test data
	@$(P) in-dev SEED

migrate: ## run the migrations in the dev container (on a server, make stage / make prod runs them)
	@$(P) migrate

down: ## stop the dev stack; the data stays
	$(DEV) down

##@ Checks

lint: ## base: the code does not run: the Dockerfiles, then LINT (format, lint, types)
	@$(P) lint

test: ## base: the code runs, fast and offline (TEST)
	@$(P) test

e2e: ## base: the whole application runs (E2E): the API contract, the browser
	@$(P) e2e

security: ## base: the secret scan (SECRETS), then SAST and the dependency audit (SECURITY)
	@$(P) security

infra: ## base: check-compose, parity, then backup-test when there is a backup service
	@$(P) infra

gates: ## group: lint, test and the secret scan, then a summary; the git pre-push hook runs it
	@$(P) group gates

verify: ## group: lint, test, e2e, security and infra, then a summary; before a finished task is merged
	@$(P) group verify

fix: ## by hand: the automatic fixers (FIX); then git diff and make gates
	@$(P) in-dev FIX

# Mutation testing (QLT-01, R): removed as a whole when the owner says no (the MUTATION settings above).
mutation: ## by hand: mutation testing
	@$(P) in-dev MUTATION

mutation-diff: ## by hand: mutation testing of the code changed on this branch
	@$(P) in-dev MUTATION_DIFF

image-scan: ## by hand: build the images of this commit and scan them (the images stay)
	@$(P) image-scan

##@ Servers

stage: ## (stage clone) update to the stage branch, build its images if missing, deploy
	@$(P) deploy stage

prod: ## (prod clone) update to the prod branch, build its images if missing, deploy
	@$(P) deploy prod

# Internal: the deploy steps of make stage, make prod and make rollback, which run them under the
# lock of this clone (.deploy/lock) after the check of the free space; not run by hand. The logs
# of the containers it may replace are saved before the migration, which may already recreate a
# changed dependency; the migration step makes a backup set first (OPS-01); the deploy is recorded before the tuning check, so a failed check fails
# the command and leaves a true history.
deploy-stage deploy-prod: deploy-%:
	@$(P) need $*
	@$(P) bootstrap
	@$(MAKE) --no-print-directory parity check-compose
	@$(P) images $*
	@$(P) log-archive $*
	@$(P) migrate deploy
	@$(P) up $*
	@$(P) record $*
	@$(P) prune
	@$(P) tuning-check deploy

images: ## build the missing images of the checked-out commit, pull the others; start nothing
	@$(P) images

rollback: ## deploy the commit deployed before the current one
	@$(P) rollback

restart: ## apply a changed .env to the commit that runs now
	@$(P) restart

tuning-check: ## actual settings of the running services against the expected ones
	@$(P) tuning-check

##@ Any clone

status: ## the environment, the checked-out and last deployed commit, and the health of every service of this clone
	@$(P) status

logs: ## follow the logs of this clone's stack (S=<service>: only that one; TAIL=<n>: the last n lines, then end)
	@$(P) logs '$(TAIL)' $(ARG_S)

##@ Backups

backup: ## a set of every store now (S=<service>: of one), then the off-server copy and rotation
	@$(P) backup backup

backup-list: ## the sets of every store (S=: of one), the names SET= takes (FROM=copy: those of the off-server copy, on a server)
	@$(P) backup list

backup-drill: ## restore the newest sets (SET=<set>: that one; S=: one store) into a temporary database and compare them
	@$(P) backup drill

# The old name of make backup-drill.
restore-drill: backup-drill

backup-status: ## the backup service: its health and why, the newest sets, the last result of every job, the free space
	@$(P) backup status

backup-copy-check: ## (server) prove the off-server copy: a test set written and read back, its delete refused, the read check
	@$(P) backup copy-check

backup-test: ## (dev) back up the seed database (S=: one store), drill it, delete the set
	@$(P) backup backup-test

restore: ## the one target that replaces data (SET=<set>|latest|before-restore, FROM=local|copy, S=, NO_SAFETY=1): asks for the database name (input not a terminal: CONFIRM=yes)
	@$(P) restore

##@ Service

# A "##@ <group>" line starts a group: make help lists each target with a "## " text under the
# group above it, and leaves out a group with no such target.
help: ## list the commands
	@awk -F ':.*## ' '/^##@ / { g = substr($$0, 5) } /^[a-zA-Z0-9_-]+:.*## / { if (g != "") printf "%s%s\n", (n++ ? "\n" : ""), g; g = ""; printf "  %-18s %s\n", $$1, $$2 }' Makefile

bootstrap: ## prepare this clone; make dev and a deploy run it every time
	@$(P) bootstrap

parity: ## stage and prod files differ only in the name: line
	@$(P) parity

check-compose: ## the compose rules of the stage and prod files
	@$(P) check-compose

# ---- Project targets: this project's own commands (standard ENV-05) ---------------------------
# A target here has a "## " help text, so make help lists it under "This project", its own
# `.PHONY: <target>` line, and a row in the README section "Working with this project"; its name is
# not one of the targets above. An update of the standard keeps this block as it keeps the
# settings block.
##@ This project
# ----------------------------------------------------------------------------------------------
