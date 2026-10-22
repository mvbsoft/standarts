# D-0018. Images are built once and servers pull them from an image registry

> English · [Українська](0018-images-from-a-registry.uk.md)

**Status:** superseded by [D-0025](0025-images-built-on-the-server.md) · **Date:** 2026-10-18 · **Rules:** PRN-03, ENV-08, ENV-09

On 2026-10-19 the owner chose to build the images on the server, without a registry; this record is kept as history.

## Context

If each server builds its own image, stage and prod run two builds of the same commit, and nothing proves they are the same: a base image or a package can change between the two builds. A server that builds also needs the build context, the build cache and the time.

## Decision

Every own image is built once on the developer machine by `make image`, from the `runtime` stage of a commit, tagged with the git tree hash of that commit (`git rev-parse <commit>^{tree}`) and pushed to the project's image registry (`IMAGE_PREFIX` in `.env`, for example `ghcr.io/<owner>/<repo>`). Stage and prod files have no `build:`; servers only pull, each logged in once with a read-only token, and never build again. The tree hash is the hash of the commit's content, so the merge, squash or rebase commit a project creates on the prod branch, with the same content as the stage commit, uses the image already built. If the prod branch has its own changes, `make prod` stops with `no image … for the content of commit …`, and `make image` is run on that branch. A rollback uses the previous commit, whose image is still in the registry.

## Options considered

- **An image registry.** One build, the same bytes on every server, and old tags stay available for a rollback. Needs an account and a token on every machine.
- **`docker save` / `docker load`.** No registry, but the archive is copied to every server by hand, and nothing keeps old images for a rollback.
- **Build on each server.** No extra service, but two builds of one commit can differ, and a server needs build tools and time.
- **The commit SHA as the tag.** Names the exact commit, but the merge commit a project creates on the prod branch has a new SHA, so prod either needs a build of its own or a step that moves the prod branch to the stage commit and bypasses the project's pull requests and branch protection.

## Consequences

The servers never build. Tested on 2026-10-19: a `--no-ff` merge, a squash merge and a rebase of the stage branch onto the prod branch each give a commit with the same tree hash as the stage commit (one cycle tested; after a squash merge, the stage branch has to be reset to the prod branch, or the next squash merge conflicts); a hotfix made on the prod branch before the merge gives a different tree hash, so that commit needs its own `make image`. An image is built for the platform of the machine that builds it, so the servers' images are built on a machine with the servers' CPU type: an image built on an ARM machine (for example a Mac with an M chip) does not run on an Intel/AMD server without emulation, and the other way round. With GitHub Container Registry, a login needs a personal access token (classic): `write:packages` on the developer machine, `read:packages` on servers. A new package of a personal account is private, which suits a private project; pulling it needs the login.

## Sources

- <https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry> — “GitHub Packages only supports authentication using a personal access token (classic).”
- <https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry> — “Select the `read:packages` scope to download container images and read their metadata.”
- <https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry> — “Select the `write:packages` scope to download and upload container images and read and write their metadata.”
- <https://docs.github.com/en/packages/learn-github-packages/configuring-a-packages-access-control-and-visibility> — “When you first publish a package that is scoped to your personal account, the default visibility is private and only you can see the package.”
- <https://raw.githubusercontent.com/docker/docs/main/content/manuals/build/building/multi-platform.md> — “This is why you can't run a `linux/amd64` container on an arm64 host (without using emulation), or a Windows container on a Linux host.”
- <https://raw.githubusercontent.com/docker/buildx/master/docs/reference/buildx_build.md> — `--platform`: “The default value is the platform of the BuildKit daemon where the build runs.”
