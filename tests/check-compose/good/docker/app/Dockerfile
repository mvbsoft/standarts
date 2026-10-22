# syntax=docker/dockerfile:1.10@sha256:0000000000000000000000000000000000000000000000000000000000000000
# The parser directive above names the BuildKit frontend, an image too (zeros: check-compose pulls nothing).
# Third-party images are pinned by a tag and a digest; a stage name, a stage number and scratch are not images.
# syntax=docker/dockerfile:1 (only the first lines are directives: this one is a comment)
FROM python:3.12.13-slim@sha256:229a2c5bfa27522db7815ea81f9bed70af17ccb9de9fc7ad142b1877b5830d36 AS base
# << inside a word or in quotes is not a heredoc: the lines after it are read.
RUN echo $((1<<3)) "use <<EOF in a script"
FROM scratch AS empty
FROM base AS runtime
COPY --from=base /etc/hostname /tmp/hostname
COPY --from=0 /etc/hosts /tmp/hosts
RUN --mount=type=bind,from=empty,target=/empty \
    useradd -u 10001 app
USER app
RUN python - <<'EOF'
from pathlib import Path
EOF
CMD ["python", "-c", "print(1)"]
FROM runtime AS dev
COPY --link --from=restic/restic:0.19.1@sha256:136600b6ff6843d61d355f7f71f460a166429f35de6fd11b568fece3c9a4d510 \
  /usr/bin/restic /usr/local/bin/restic
# A tag that is not major.minor is a version too; only latest is not.
COPY --from=node:22-bookworm-slim@sha256:c3de60bf2f9dd0ac6370e6117950ff62d6e339527e7472301c9c78a017978392 \
  /usr/local/bin/node /usr/local/bin/node
USER root
