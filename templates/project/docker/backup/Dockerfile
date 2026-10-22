# project template 1.0.0 — the backup service (standard OPS-01, ENV-08); docs/how-to/backups.md.
# Built FROM the project's Postgres image, the same as the db service, so pg_dump, pg_restore and
# the drill's server are the working database's version. Another store adds its client and server
# to base (and its module next to postgres.sh), and BACKUP_USER names the base image's database user.
# backup.sh needs from the base: gosu, flock, sha256sum, stat, mkfifo, df, du, and curl or wget for
# BACKUP_NOTIFY_URL and BACKUP_HEARTBEAT_URL (the Alpine Postgres images have busybox wget; the
# Debian ones have neither: apt-get install curl). The copy goes to a rest-server over HTTP(S) and
# needs nothing more. Every third-party image is pinned as <image>:<version>@sha256:<digest>
# (standard ENV-03).
FROM <postgres image>:<version>@sha256:<digest> AS base
# restic: the binary of the official image.
COPY --from=restic/restic:0.19.1@sha256:136600b6ff6843d61d355f7f71f460a166429f35de6fd11b568fece3c9a4d510 /usr/bin/restic /usr/local/bin/restic
# The user every backup command runs as: the database user of the base image.
ENV BACKUP_USER=postgres

FROM base AS runtime
COPY docker/backup/*.sh /usr/local/lib/backup/
RUN chmod 755 /usr/local/lib/backup/*.sh \
 && ln -s /usr/local/lib/backup/backup.sh /usr/local/bin/backup \
 && mkdir -m 700 /backup /drill \
 && chown "$BACKUP_USER:$(id -g "$BACKUP_USER")" /backup /drill
# The sets are always in /backup (a bind mount of the host folder BACKUP_DIR, or a volume in dev).
# Starts as root only to give /backup, when it is empty or the service's own, and /drill to
# BACKUP_USER, then every command runs as that user (backup.sh).
USER root
ENTRYPOINT ["backup"]
CMD ["run"]

# dev is runtime itself: the dev container runs these scripts and mounts no code (standard ENV-08).
FROM runtime AS dev
