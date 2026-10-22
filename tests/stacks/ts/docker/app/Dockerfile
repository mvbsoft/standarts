# The TypeScript sample of tests/stacks (standard ENV-08, QLT-01, AI-07). Node.js 22.23.3.
# base: Node.js and the runtime packages, the dependencies of package-lock.json; this sample has
# none (only devDependencies), so base is the pinned image.
FROM node:22.23.3-bookworm-slim@sha256:c3de60bf2f9dd0ac6370e6117950ff62d6e339527e7472301c9c78a017978392 AS base
WORKDIR /srv

# The gate tools and the language server, the devDependencies of package-lock.json, in a stage of
# their own: dev copies only the finished node_modules.
FROM base AS tools
COPY package.json package-lock.json /opt/dev/
RUN cd /opt/dev && npm ci --no-audit --no-fund

FROM base AS runtime
COPY . ./
USER 10001:10001
# Node.js 22.18 and later run TypeScript by stripping its types.
CMD ["node", "src/main.ts"]

# dev: base and the tools, never the code: the dev stack mounts the code from disk, so a code change
# does not rebuild this image; only a change of base, of the lock file or of a tool image does. The
# tools are in /node_modules, the last folder Node.js and TypeScript search for a package from any
# path, so the mounted code finds them (eslint.config.js imports typescript-eslint).
FROM base AS dev
COPY --from=tools /opt/dev/node_modules /node_modules
ENV PATH=/node_modules/.bin:$PATH
# The tools every stack shares, each a single static binary from its own pinned image: the secret
# scan gitleaks 8.30.1 (SECRETS), ShellCheck 0.11.0 (the image of the tag stable of 2025-08-04) and
# the link check lychee 0.24.2 (LINT, lychee --offline: no network request).
COPY --from=ghcr.io/gitleaks/gitleaks:v8.30.1@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f /usr/bin/gitleaks /usr/local/bin/gitleaks
COPY --from=koalaman/shellcheck:v0.11.0@sha256:bb596a0d169b85ddd81d8b6d3a2ff6d5baf5fca10b97f575ebc647c3dff62b3d /bin/shellcheck /usr/local/bin/shellcheck
COPY --from=lycheeverse/lychee:0.24.2-alpine@sha256:2255c0b916cc8fc4193f59a4549358a6bae0f7d4ea16b5e1dd4c3b2733c35504 /usr/local/bin/lychee /usr/local/bin/lychee
# lychee refuses to start without the system's CA certificates, also with --offline, and this base
# image has none (Node.js has its own): the bundle of the lychee image.
COPY --from=lycheeverse/lychee:0.24.2-alpine@sha256:2255c0b916cc8fc4193f59a4549358a6bae0f7d4ea16b5e1dd4c3b2733c35504 /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
