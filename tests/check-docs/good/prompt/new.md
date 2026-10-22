# New project

Prove the hooks: with the dev stack stopped, the edit hook prints
`check NOT run: the dev container is not running` and `exit 2`. A Dockerfile line that fails in
`make stage` stops it with
`building <repo>-<img> for commit <sha> failed (above); nothing was replaced`, and the scan ends
with a `scan: OK` line.

With stage, `make stage` prints the free space it checked
(`space: <free> free where Docker keeps the images (need <X>)`); a first deploy of a clone whose
volumes are left says so (`WARNING: the volumes of <project> exist, but no container of it: …`).
Without a variable of `.env.example` in `.env`, `make dev` says:
`WARNING: .env lacks variables of .env.example: <names>`.
