# syntax=docker/dockerfile:1
FROM python:3.12.13-slim AS base
ARG TOOLS=alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc
FROM ${TOOLS} AS tools
FROM base AS runtime
COPY --from=busybox:1.36.1 /bin/true /tmp/true
RUN --mount=type=cache,target=/root/.cache \
    --mount=type=bind,from=alpine:3.20,target=/alpine \
    useradd -u 10001 app
COPY --from=tools /etc/hostname /tmp/hostname
COPY --from=busybox:latest@sha256:dc2d74b28e4cf8984fa52af1f39bc7c3d9c73760b41a74d629f5d11b1ab28616 /bin/true /tmp/true2
RUN echo $((1<<3)) "use <<EOF in a script"
USER app
CMD ["python", "-c", "print(1)"]
FROM runtime AS dev
USER root
FROM busybox:1.36.1 AS late
