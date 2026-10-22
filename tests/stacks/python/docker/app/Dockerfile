# The Python sample of tests/stacks (standard ENV-08, QLT-01, AI-07).
# base: Python and the runtime libraries from the lock file; this sample has none (it uses only the
# standard library), so base is the pinned image.
FROM python:3.12.13-slim@sha256:229a2c5bfa27522db7815ea81f9bed70af17ccb9de9fc7ad142b1877b5830d36 AS base
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /srv

# The gate tools and the language server, from requirements-dev.txt, in a stage of their own: dev
# copies only the finished virtual environment.
FROM base AS tools
COPY requirements-dev.txt /tmp/
RUN python -m venv /opt/dev && /opt/dev/bin/pip install --no-cache-dir --disable-pip-version-check \
    -r /tmp/requirements-dev.txt

FROM base AS runtime
COPY . ./
USER 10001:10001
CMD ["python", "hello.py"]

# dev: base and the tools, never the code: the dev stack mounts the code from disk, so a code change
# does not rebuild this image; only a change of base, of requirements-dev.txt or of a tool image does.
FROM base AS dev
COPY --from=tools /opt/dev /opt/dev
ENV PATH=/opt/dev/bin:$PATH
# The tools every stack shares, each a single static binary from its own pinned image: the secret
# scan gitleaks 8.30.1 (SECRETS), ShellCheck 0.11.0 (the image of the tag stable of 2025-08-04) and
# the link check lychee 0.24.2 (LINT, lychee --offline: no network request).
COPY --from=ghcr.io/gitleaks/gitleaks:v8.30.1@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f /usr/bin/gitleaks /usr/local/bin/gitleaks
COPY --from=koalaman/shellcheck:v0.11.0@sha256:bb596a0d169b85ddd81d8b6d3a2ff6d5baf5fca10b97f575ebc647c3dff62b3d /bin/shellcheck /usr/local/bin/shellcheck
COPY --from=lycheeverse/lychee:0.24.2-alpine@sha256:2255c0b916cc8fc4193f59a4549358a6bae0f7d4ea16b5e1dd4c3b2733c35504 /usr/local/bin/lychee /usr/local/bin/lychee
