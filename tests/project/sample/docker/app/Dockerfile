# The sample application of tests/project (standard ENV-08). Only the Python standard library,
# so the build needs no network.
# base: Python and the runtime libraries from the lock file; the sample has none. The base image
# is pinned by its tag and digest.
FROM python:3.12.13-slim@sha256:229a2c5bfa27522db7815ea81f9bed70af17ccb9de9fc7ad142b1877b5830d36 AS base
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
# The mount point of the named volume with the sample's data: the runtime user writes it on a
# server, the host user in dev.
RUN mkdir -m 1777 /data
WORKDIR /srv

FROM base AS runtime
# Everything the commit has, minus .dockerignore (tests/project checks that docs/ and .githooks/ stay out).
COPY . ./
USER 10001:10001
# The start command as an ENTRYPOINT that serves and never ends, as Go or Rust images often have
# it: the migration on a server must bypass it (tests/project).
ENTRYPOINT ["python", "app.py"]

# dev: base and the dev tools, never the code, which the dev stack mounts from disk. The sample's
# tools (unittest) come with Python, so dev adds nothing.
FROM base AS dev
