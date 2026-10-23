# Start

You were asked to bring the current project in line with the standard, or to create a new project
by it. This file decides what to do and loads everything else.

## 1. Get the standard

The owner's prompt gives `STANDARD_REPO` (a GitHub repository) and `STANDARD_REF` (a release tag
such as `v1.0.0`). Fetch that exact release into a cache outside the project, with git only. The
folder is named after both, so a fork with the same tag never shares it:

```sh
dest="$HOME/.cache/standards/$STANDARD_REPO/$STANDARD_REF"
[ -d "$dest" ] || git clone --quiet --depth 1 --branch "$STANDARD_REF" \
  "https://github.com/$STANDARD_REPO.git" "$dest"
git -C "$dest" describe --tags --exact-match HEAD
```

The last command must print `STANDARD_REF`; anything else (a folder left half-cloned by an
interrupted run, for example) means: remove `$dest` and clone again.

If the prompt gives `STANDARD_DIR` instead, use that local folder as it is; this is only for testing
the standard itself, never for real projects. From here on, `$STANDARD` means the release folder.
Read `$STANDARD/standard/README.md` and every file it lists, in full, before anything else.

## 2. Choose the mode

| What you find in the current folder | Mode | Next file |
|---|---|---|
| `docs/reference/project-registry.md` whose `Standard:` field names a release that is not a tag of `STANDARD_REPO` (a draft: `git ls-remote --tags "https://github.com/$STANDARD_REPO.git" "refs/tags/<that name>"` prints nothing) | adopt; compare every file that came from a template with the template in `$STANDARD` by its content (`diff`), never by the version in its header | [`adopt.md`](adopt.md) |
| `docs/reference/project-registry.md` whose `Standard:` field names an older release | ask the owner: **update** (the new release, by the answers the registry records) or **set up again** (every question again, below) | [`update.md`](update.md), or [`adopt.md`](adopt.md) as set up again |
| `docs/reference/project-registry.md` of this release | ask the owner: **set up again**, or nothing to do | [`adopt.md`](adopt.md) as set up again |
| an existing project (code, compose files, a Dockerfile) without such a registry | adopt | [`adopt.md`](adopt.md) |
| `docs/reference/project-registry.md` whose `Standard:` field names a newer release | — | stop and tell the owner which release to use |
| an empty folder, or only a `.git` folder and a README | new | [`new.md`](new.md) |

**Update** applies a new release: it keeps every answer the registry records, asks only the
questions the new release adds, and offers to revisit earlier answers one by one. To go through
all of them (stage no longer wanted, mutation testing added, another backup folder), the owner sets
the project up again: adopt runs as if the project had never been set up, asks every question of
[`questions.md`](questions.md) and of adopt phase 0 again, shows the answer the registry records
next to each as a reference (never as the answer), and its plan adds or removes the parts the new
answers change.

Say which mode you chose and why in one sentence (for the two rows that ask, ask first), then
follow the next file.

## 3. Rules for every mode

**Talking to the owner**
- First find the owner's language: the language they write in or, when that is not clear, ask.
  Talk in it, ask every question translated into it as you go (the prompt files and
  [`questions.md`](questions.md) are the English source and are never translated in the
  repository), and write report files in it, except tables of technical names, paths and commands,
  which stay as they are. This is the language of the conversation; the language of the project's
  documentation is a question of its own (S-24).
- Stop after every phase of the mode file: say in a few lines what the phase found or did, show
  the questions it raised, and wait for the owner's answer before the next phase. In a run without a
  person (`claude -p` and the like) never wait: write the questions into the report's open
  questions, build the plan on your recommended option and mark each such choice `assumption`.
  Such a run ends with the report and changes nothing in the project (except what `make bootstrap`
  writes): adopt stops after phase 5, update before its step 4, and new after step 2, with the plan
  of step 2 in `00-summary.md` and its questions in the report's `questions.md`.
- The setup questions are those of [`questions.md`](questions.md), asked one at a time, theme by
  theme, in its order, each with your recommendation first; the ones the facts or the registry
  answer are said, not asked, as that file says. In Claude Code, ask each in a choice window (the
  AskUserQuestion tool); in another agent, one question per message, with its options numbered.
  They are asked in the conversation, never on the report page.
- Every question to the owner is written so that it reads without the standard: the problem in
  plain words with one concrete example, the options with their pros and cons, your recommendation
  and why, and the facts behind it (file and line, a command and its output, or a URL with a quoted
  sentence).

**Facts**
- Every claim cites a file and line, a command and its output, or a URL with a quoted sentence.
  A claim you could not check is marked `NOT VERIFIED` with an estimated confidence.
- Research reads the raw page itself with your web tool (the `.md` version where one exists, never
  a search summary), and quotes the sentence.

**What you may run and change**
- On the host run only the tools [PRN-01](../standard/01-principles.md) lists; every language tool
  runs in a container. If a tool is missing, report it as a `blocker`; never install anything on
  the host.
- In dev you may build images, start and stop the dev stack and run the targets of the standard's
  `Makefile` ([ENV-05](../standard/02-environments.md)), including `make gates`, `make verify` and
  `make image-scan` (before adopt phase 6 and update step 4, `make fix`, `make seed`,
  `make migrate`, `make restore` and `make dev`, which runs the migrations, only after the owner's
  yes: they change the code or the dev data), but push nothing to the project's remote:
  branches are pushed only in a proof copy (next point). A target of the project's own `Makefile` (adopt, or the block "Project
  targets") may do anything, such as reset the dev database: read its recipe first, run it only
  when it writes no data, and otherwise ask the owner. Say at the start that builds take time and
  disk space. Destructive commands follow the one rule of
  [AI-01](../standard/05-agents.md#ai-01-agentsmd-and-claudemd-m), which the project's `AGENTS.md`
  has in the same words ([its template](../templates/project/AGENTS.md#destructive-commands)),
  with its exception for a proof copy (next point).
- Never start, stop or update stage or prod on a server. A proof that needs them (new step 4,
  adopt's standard tasks) runs in a **proof copy** on this machine: a throwaway copy of the
  project in a temporary folder `$t` (`$TMPDIR/<repo>-proof-<6 hex>`, one per project folder):
  `$t/p`, whose `origin` is a bare repository `$t/remote.git` with the stage and prod branches,
  and server clones of it (`$t/stage`, `$t/prod`) with their own `.env`, where `make stage` and
  `make prod` build the images of their commit as on a real server. Its dev stack is
  `<repo>-dev-proof` ([ENV-04](../standard/02-environments.md)), and its stage and prod files name
  `<repo>-proof-stage`, `<repo>-proof-prod` and `<repo>-proof-<image>`, so it shares no
  container, volume or image with a stack of this machine. The standard's script makes it, deploys
  it and removes it; never do these steps by hand. Read its header first: it says what each
  command does, what it takes and where the folders are. Run it in the project folder (`stage`,
  `prod`, `clean` and `path` also in `$t/p` or `$t/wt`); `t=$(sh "$STANDARD/scripts/proof.sh" path)`
  gives `$t`.

  ```
  sh "$STANDARD/scripts/proof.sh" <create|stage|prod|clean|path>
  ```

  - `create` copies the project as it is now, files not committed yet included, as one commit in
    which the stage and prod files carry the `-proof` names and every external network of the
    `Makefile` setting `NETWORKS` gets `-proof` after its name in `.env.example`; it makes the
    bare remote, pushes that commit as `HEAD:<STAGE_BRANCH>` and `HEAD:<PROD_BRANCH>` (the copy
    may have no local branch of that name), and runs `make bootstrap NAME=proof`. It refuses when
    a container, volume or image of the proof's names already exists on this machine: that is not
    yours, so stop and ask the owner. It also refuses, before it creates anything, when the
    `Makefile` setting `BUILD_SECRETS` names files (git ignores them, so the copy would lack them):
    then no proof runs in a proof copy, and each goes into the report as not verified.
  - `stage` and `prod` make the server clone on first use, with a `.env` from `.env.example`:
    `PROJECT_ENV`, random test values for every `change-me`, `0` for every `*_PORT` (Docker picks
    a free host port: `make status`, which the script runs after each deploy, shows it, and it
    changes when the container is recreated), `DOCKER_GID`, `BACKUP_TIME` the start of this hour in
    UTC (no daily backup during the proof), `BACKUP_COPY_TO=/backup/.copy` (a repository inside the backup
    folder, for the proof only), mode 600. Then, every time, `make stage` or `make prod` there.
  - A later change is committed in `$t/p` and pushed there: `git push origin HEAD:<STAGE_BRANCH>`
    (and `HEAD:<PROD_BRANCH>` for prod); then `stage` or `prod` deploys it.
  - A `git worktree` of the copy is made at `$t/wt` (`git -C "$t/p" worktree add "$t/wt"`); its
    dev stack is `<repo>-dev-wt-<6 hex>`: `make bootstrap` in `$t/wt` writes the suffix to
    `DEV_SUFFIX` in `$t/wt/.env` and prints it. Any other stack the proof starts by hand (adopt's
    old-stack copy) lives in a folder directly in `$t`. The script checks the volumes of its own
    stacks; before a stack you start by hand runs for the first time,
    `docker volume ls --filter label=com.docker.compose.project=<its name>` prints no volume. If
    it prints one, that stack is not yours: stop and ask the owner.
  - A deliberately broken Dockerfile line is a failing step in the `runtime` stage after the
    code `COPY` (`RUN false`): a parse error breaks the dev build too, so the hook refuses the
    push. A deliberately failing migration fails the gates too when the tests apply the
    migrations; that one commit is pushed with `git push --no-verify` (a proof copy is the
    exception of [AI-01](../standard/05-agents.md#ai-01-agentsmd-and-claudemd-m)).
  - At the end, and before a new attempt after a failure, `clean`: it removes every stack of the
    copy (also those of `$t/wt` and of a folder in `$t`), their volumes, networks and images, and
    `$t` with the backup sets the server clones' backup user owns, also after a proof that failed
    before its first deploy. A stack with a container started outside `$t` is not the copy's:
    `clean` leaves it alone, names it, keeps `$t` and fails; tell the owner. A stack that existed
    before `create` keeps its volumes and images. List in the report what `docker volume ls` and
    `docker images` show of the proof's names: nothing is the expected answer.
- The dev stack is what `docker-compose.dev.yml` starts. A project without that file has no dev
  stack yet: in adopt phases 0–5 start none of its compose files unless the owner has confirmed
  which one is safe to start here and that this machine is not a server; run language tools with
  `docker run --rm` in a pinned image, the project mounted read-only.
- Files from `$STANDARD/templates/` are used as [`templates/README.md`](../templates/README.md)
  says: a verbatim file is copied unchanged except its named placeholders; a starting point keeps
  its structure and is filled in for the project. A `settings.fragment.json` is merged key by key
  into `.claude/settings.json` instead.
- Never touch production. Read another of the owner's projects only if the owner named it in this
  session, only to read, and from its `.env` only variable names, never values.
- Write to an issue tracker or another remote service only while executing a plan the owner has
  approved (adopt phase 6, new step 5, update step 4), and only what that plan says (its tasks in
  the backlog and their status).
- Outside the project folder, change files only in the report folder (`~/audits/<repo>/`), the
  standard's cache (`~/.cache/standards/`) and temporary folders you delete afterwards. A change
  anywhere else, for example in `~/.claude/`, goes into the plan as an owner step with the exact
  command.
- Subagents may read and research for you (adopt phases 1 and 2); they change nothing, and you check
  what they report before you rely on it.

**The page for the owner**
- The owner reads the report, answers its questions (`Q-<n>` of the report's `questions.md`; the
  setup questions are asked in the conversation, above) and sees the plan on one page per project,
  built from [`$STANDARD/templates/report-site/`](../templates/report-site/README.md). You write
  only the md files it reads; the page shows them. Publish it if your environment can publish a
  page (in the Claude app: an artifact), give the owner the link, and read the answers the page
  saved; the page also has a button that copies the answers for pasting into the chat.
- If the page cannot be shown, say plainly what did not start, why (for example "this terminal has
  no tool that publishes pages"), and how to make it work as intended (for example "open this
  session in the Claude app"). Then continue with the same md files in the report folder, and ask
  the questions in the chat, one at a time as above.
