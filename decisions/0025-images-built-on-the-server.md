# D-0025. Images are built on the server, without a registry

> English · [Українська](0025-images-built-on-the-server.uk.md)

**Status:** accepted · **Date:** 2026-10-19 · **Rules:** PRN-03, ENV-01, ENV-03, ENV-07, ENV-08, ENV-09, QLT-01, QLT-03

## Context

[D-0018](0018-images-from-a-registry.md) built every own image once on the developer machine and had the servers pull it from an image registry. That needs a registry account, a login with a token on every machine, someone who runs `make image` before each deploy, and a build machine with the servers' CPU type. On 2026-10-19 the owner chose fewer moving parts: no registry, and each server builds the images it runs.

## Decision

Every own image (each name in `IMAGES` in the `Makefile` settings) is built on the server by `make stage` / `make prod`, after the update and the checks and before the migration, for every image that server lacks for the deployed commit. The image is `<repo>-<name>:<tree hash of the commit>`; the stage and prod files name it `<repo>-<name>:${IMAGE_TAG:?}` and have no `build:`. The build context is the commit itself: `git archive` of the commit with no line-ending conversion, unpacked into a temporary folder so that `.dockerignore` applies, then `docker build --target runtime`; nothing uncommitted, untracked or ignored in the server clone reaches an image, and a commit with git submodules is refused. Third-party images are still pulled. A failed build stops the deploy with `building <repo>-<name> for commit <sha> failed (above); nothing was replaced`, and the old version keeps serving.

After each deploy, own images whose tag is a tree hash but not the tree of the running commit or of one of the last `KEEP_IMAGES` (default 5) distinct deployed commits are removed; other images and tags stay. `make rollback` normally finds its images still on the server; if they were removed, it builds them again from that commit, still without migrations. `make restart` and `make restore` on a server build a missing image of the checked-out commit first, and `make images` builds and pulls the images of the checked-out commit without starting anything (for a cut-over). `make image-scan` builds the images of the checked-out commit on the dev machine the same way and scans them before a change is merged to the prod branch. A project may run the same `make` targets from its CI; the standard does not require one.

## Options considered

- **A. Build on the developer machine and push to a registry** (the old D-0018). Stage and prod run the same bytes, and a deploy only pulls. Needs a registry, a token on every machine, a build machine with the servers' CPU type, and someone to run the build before each deploy.
- **B. Build in CI and push to a registry.** The same bytes and fast deploys, and the build runs by itself. Needs a registry and a CI the project may not have, and credentials for both.
- **C. Build on each server from the commit** (chosen). No registry and no extra step: `make stage` / `make prod` stay the only commands. Stage and prod build the same content, not the same bytes.
- **`docker save` / `docker load`.** No registry, but the archive is copied to every server by hand, and nothing keeps old images for a rollback.
- **A deploy tool that builds on the server (Kamal, Dokku, Coolify, CapRover).** Each brings its own app model or control plane in place of the Compose files and `make` targets; the comparison is in [D-0021](0021-ship-deploy-rollback.md). Kamal pushes the image to a registry.

## Consequences

Before a build the deploy checks the free space and warns and asks when it is below (an estimate, ENV-09) twice the sum of the own images (each at its largest version on the machine, as `docker image ls` shows its size) plus `DISK_RESERVE` of `.env`; measured on 2026-10-21 (one-off run), a rebuild with a changed 20 MB layer added about 40 MB to the images and about 40 MB to the build cache, and on the containerd store `docker image inspect` underestimates disk use by about 3.5 times. The space is read with `df` in a container, because on Docker Desktop a `df` of the Docker root on the host reads another disk (the distro's, 6% used, while the VM's disk was 17% used) and the containerd store keeps images in a separate path.

A build uses the server's CPU, memory and network while the old version keeps serving, so the first deploy and a deploy of new content take longer than a pull, and the server needs to reach the base images and the package sources the Dockerfiles name. A private dependency needs build credentials on the server: a file outside git, named in the `Makefile` setting `BUILD_SECRETS`, that the build mounts as a BuildKit secret and never bakes into the image; a missing file stops the deploy before anything is built. An image is built for the platform of the machine that builds it, and here that is the server itself, so the CPU type no longer matters. Stage and prod build the same commit content; base images pinned by digest (ENV-03 refuses a third-party image or a `FROM` without one, in the compose files and in the Dockerfiles of the own images) and dependencies installed from lock files keep the two builds equal in content, but not byte for byte: the same commit built twice gives different image digests. Without the digest, a tag that is pushed again gives two builds of one commit different bases: shown on 2026-10-20 with a local base image rebuilt under the same tag (a model of a registry tag, not a registry). Operating-system packages (`apt-get install`, `apk add`) are not pinned and are taken as they are on the day of the build, so stage and prod can differ in them; the owner accepted this trade-off (2026-10-21; not measured), and the rule is to deploy prod soon after stage. The build is outside the limits of `.env`, so on a small server it competes with the running services for memory. The standard does not add `oom_score_adj` to the database to protect it: measured on 2026-10-21 (Docker Engine 29.7.2, Compose v5.5.0; one-off run), Compose applies the value, but build steps already run at `-500`, inherited from `dockerd`, so a database at `-500` has no advantage over the build and the larger of the two is killed; the case of a whole small server running out of memory, and what a build gets on a plain Linux server, were not measured. Keep a reserve of memory. The tree hash as the tag still lets a re-deploy, a rollback, or a merge, squash or rebase into the prod branch that changes nothing else reuse an image already built on that machine (one cycle tested; after a squash merge the stage branch has to be reset to the prod branch, or the next squash merge conflicts). Stage and prod on one machine share the image names, so the prune of one may remove images the other would roll back to, and that rollback then builds them again. The build cache grows on the server; no target prunes it, and the project's runbook says how. The guarantee of D-0018 that prod runs exactly the image stage ran no longer holds.

## Verified

Checked on 2026-10-19, Docker 29.7.2, Compose v5.5.0, git 2.43.0 (WSL2), with `tests/project/run.sh` (stage and prod clones of a sample project on one machine); the cold build and the digest comparison were one-off runs on the same machine, not steps of that test.
- A cold build: `docker build --no-cache` of the sample's images; app 1.7 s (43 MB), backup 3.8 s (127 MB).
- Deploys: `make stage` of a new stage clone with both builds 16–20 s; the same commit again 6–8 s, building nothing, with the same image ID and the same container; a new commit 11–15 s; `make prod` of a merge whose tree this machine had already built 16–17 s, building nothing.
- Rollback: with the images kept 6–7 s; after they were removed 9–11 s, building them again.
- What reaches the image: untracked files, files ignored through `.git/info/exclude` and `.env` in the server clone; none of them was in the image.
- A broken Dockerfile line: the deploy stopped, the old container kept serving and `.deploy/history` was unchanged.
- Prune: exactly the images of the last 5 deployed trees stayed, and other tags and images were not touched.
- Same content, other bytes: the same commit built twice; the image digests differed (BuildKit timestamps, the config's `Created`).
- Build secrets: a `RUN --mount=type=secret` step read the file named in `BUILD_SECRETS` (the image held the hash it wrote); the file's content was neither in the image's files, its history nor its saved layers; without the file the build stopped before anything was built.
Not checked: stage and prod on separate machines, a real remote server, a real private package source behind a build secret, and the growth of the build cache over many deploys.

## Sources

- <https://raw.githubusercontent.com/git/git/master/Documentation/git-archive.adoc> — “Creates an archive of the specified format containing the tree structure for the named tree, and writes it out to the standard output.”
- <https://raw.githubusercontent.com/docker/docs/main/content/manuals/build/building/secrets.md> — “Build arguments and environment variables are inappropriate for passing secrets to your build”; “because they persist in the final image.”; “Secret mounts expose secrets to the build containers, as files or environment variables.”
- <https://raw.githubusercontent.com/docker/buildx/master/docs/reference/buildx_build.md> — `--platform`: “The default value is the platform of the BuildKit daemon where the build runs.”
