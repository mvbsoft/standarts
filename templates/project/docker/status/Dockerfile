# project template 1.0.0 — the status service (standard ENV-08; docs/how-to/operations.md). It asks
# Docker, only through the socket proxy (service status-proxy), for the health of this compose
# project's containers and answers GET /status with a token. Python standard library only, so
# base holds no libraries. Every third-party image is pinned as <image>:<version>@sha256:<digest>
# (standard ENV-03).
FROM python:3.12.13-slim@sha256:229a2c5bfa27522db7815ea81f9bed70af17ccb9de9fc7ad142b1877b5830d36 AS base
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1

FROM base AS runtime
COPY docker/status/status.py /usr/local/lib/status/status.py
# /disk: every free-space folder is mounted under it read-only (/disk/backup: BACKUP_DIR).
RUN chmod 755 /usr/local/lib/status/status.py \
 && ln -s /usr/local/lib/status/status.py /usr/local/bin/status \
 && mkdir -m 755 /disk
# nobody: it needs no file of its own; the socket is the proxy's, never mounted here.
USER 65534:65534
EXPOSE 8080
ENTRYPOINT ["status"]
CMD ["serve"]

# dev is runtime itself, as for backup: the service is a tool, not in the dev stack, and its test
# is the standard's tests/status (standard ENV-08).
FROM runtime AS dev
