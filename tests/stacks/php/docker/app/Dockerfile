# The PHP sample of tests/stacks (standard ENV-08, QLT-01, AI-07). PHP 8.2.33.
# base: PHP and the runtime packages, the require of composer.lock; this sample has none (it requires
# only php), so base is the pinned image.
FROM php:8.2.33-cli@sha256:0ca296c0ae905940c0a333a15de437f3acaa81743333a9437221f6a44e3f0981 AS base
WORKDIR /srv

# The gate tools, the require-dev of composer.lock, installed by Composer 2.10.3 in its own image
# (it has unzip and git) for the platform PHP 8.2.33 set in composer.json; plain PHP files.
FROM composer:2.10.3@sha256:af98f42dfff7c68ba8d53c2164fd9fde1087b7d449514baa38c418b1f6bc4bac AS tools
COPY composer.json composer.lock /opt/dev/
RUN cd /opt/dev && composer install --no-interaction --no-progress --no-scripts

# The language server, intelephense from its own lock file, and the Node.js 22.23.3 it runs on.
FROM node:22.23.3-bookworm-slim@sha256:c3de60bf2f9dd0ac6370e6117950ff62d6e339527e7472301c9c78a017978392 AS lsp
COPY docker/app/lsp/package.json docker/app/lsp/package-lock.json /opt/lsp/
RUN cd /opt/lsp && npm ci --no-audit --no-fund

FROM base AS runtime
COPY . ./
USER 10001:10001
CMD ["php", "hello.php"]

# dev: base, the tools and the language server, never the code: the dev stack mounts the code from
# disk, so a code change does not rebuild this image; only a change of base, of a lock file or of
# a tool image does.
FROM base AS dev
COPY --from=tools /opt/dev /opt/dev
COPY --from=lsp /usr/local/bin/node /usr/local/bin/node
COPY --from=lsp /opt/lsp /opt/lsp
ENV PATH=/opt/dev/vendor/bin:/opt/lsp/node_modules/.bin:$PATH
# The tools every stack shares, each a single static binary from its own pinned image: the secret
# scan gitleaks 8.30.1 (SECRETS), ShellCheck 0.11.0 (the image of the tag stable of 2025-08-04) and
# the link check lychee 0.24.2 (LINT, lychee --offline: no network request).
COPY --from=ghcr.io/gitleaks/gitleaks:v8.30.1@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f /usr/bin/gitleaks /usr/local/bin/gitleaks
COPY --from=koalaman/shellcheck:v0.11.0@sha256:bb596a0d169b85ddd81d8b6d3a2ff6d5baf5fca10b97f575ebc647c3dff62b3d /bin/shellcheck /usr/local/bin/shellcheck
COPY --from=lycheeverse/lychee:0.24.2-alpine@sha256:2255c0b916cc8fc4193f59a4549358a6bae0f7d4ea16b5e1dd4c3b2733c35504 /usr/local/bin/lychee /usr/local/bin/lychee
