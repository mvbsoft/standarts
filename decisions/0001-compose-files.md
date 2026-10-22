# D-0001. Three compose files and no default-named file

> English · [Українська](0001-compose-files.uk.md)

**Status:** accepted · **Date:** 2026-10-18 · **Rules:** PRN-02

## Context

Compose picks up a file by itself when it is not given one: a default-named file in the working folder or a parent folder, its override twin, or whatever `COMPOSE_FILE` names, including from `.env`. A project whose bare `docker compose up` starts something can start the wrong environment by accident.

## Decision

Each environment has its own complete file: `docker-compose.dev.yml`, `docker-compose.stage.yml`, `docker-compose.prod.yml`. No default-named file and no override file exist, `COMPOSE_FILE`, `COMPOSE_PROJECT_NAME` and `COMPOSE_PROFILES` are never set, and `make` always passes `-f`. A bare `docker compose up` fails with `no configuration file provided`.

## Options considered

- **A default file for dev plus override files for servers.** Familiar, but a bare `up` starts dev anywhere, and a forgotten override silently changes what runs.
- **One file with profiles.** A profile only decides whether a service starts; it has no setting of its own that changes limits, mounts or users, so dev and prod would share them. For settings that differ per environment the Compose documentation points to separate or merged files.

## Consequences

Every command names its file, so starting the wrong environment by accident is impossible. The cost is running `make` targets instead of plain compose commands.

## Sources

- <https://docs.docker.com/compose/how-tos/multiple-compose-files/merge/> — “If not provided, Compose searches the working directory and its parent directories for a `compose.yaml` and a `compose.override.yaml` file.”
- <https://docs.docker.com/compose/how-tos/multiple-compose-files/merge/> — “When you run `docker compose up` it reads the overrides automatically.”
- <https://docs.docker.com/compose/how-tos/environment-variables/variable-interpolation/> — “An `.env` file can also be used to declare pre-defined environment variables used to control Compose behavior and files to be loaded.”
- <https://github.com/compose-spec/compose-go/blob/main/loader/loader.go> — “no configuration file provided”
- <https://docs.docker.com/compose/how-tos/project-name/> — “The COMPOSE_PROJECT_NAME environment variable.” comes before “The top-level `name:` attribute in your Compose file.” in “The precedence order for each method, from highest to lowest”
- <https://raw.githubusercontent.com/docker/docs/main/content/reference/compose-file/services.md> (`profiles`) — “`profiles` defines a list of named profiles for the service to be enabled under. If unassigned, the service is always started but if assigned, it is only started if the profile is activated.”
- <https://raw.githubusercontent.com/docker/docs/main/content/manuals/compose/how-tos/multiple-compose-files/_index.md> — “Using multiple Compose files lets you customize a Compose application for different environments or workflows.”
- <https://github.com/compose-spec/compose-spec/blob/main/15-profiles.md> — “A service or a job is ignored by Compose when none of the listed `profiles` match the active ones, unless it is explicitly targeted by a command.”
