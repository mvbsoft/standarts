# Contributing

> English · [Українська](CONTRIBUTING.uk.md)

## Proposing a change

Open an issue with the **Proposal** template. If the proposal comes from an audit, attach the
report's `proposals.md`; it is anonymised and contains no project details. Describe what happened
in the project, which rule it concerns and what you suggest.

## Making a change

Work happens on the `next` branch; `main` holds only releases. Every change follows these rules:

1. **Both languages in one commit.** A change to `standard/`, `decisions/`, `GUIDE`, `README` or
   `CONTRIBUTING` updates the `.md` file and its `.uk.md` translation together.
2. **Rule IDs are permanent.** A new rule takes the next free number of its section. An ID is never
   renumbered or reused; a removed rule keeps its heading with the text "Removed in vX.Y.Z" and a
   link to the decision that removed it. Until the first release (`v1.0.0`) nothing has reached a
   project, so rules and records are still edited in place.
3. **Every decision is recorded.** A rule that chooses between real alternatives, or a change to what
   such a rule requires, comes with a record in `decisions/` (context, options considered,
   consequences, sources). A record that is overturned stays and gets the status "superseded by
   D-NNNN".
4. **Facts have sources.** A statement about a tool or a technology cites the official
   documentation: the URL and a verbatim quote from the page itself, not from a summary.
5. **Templates are tested.** A changed template gets a new version (in its header line; in a JSON
   template, the `version` of its main file, which the whole folder shares) and a test in `tests/`
   that fails without the change.
6. **The changelog names what changed.** Add a line under `Unreleased` in `CHANGELOG.md` with the
   rule IDs and templates it touches; mark it **breaking** when projects must change something.
7. **The checks pass, and you know what they cover.** `make check` runs, in containers on Linux or
   WSL 2, the document checks, shellcheck over every shell script and the tests under `tests/`:
   check-compose, the project template, the backup service, the status service, the document
   check itself and the proof copy (`scripts/proof.sh`, about 3 minutes).
   Those tests start real containers and take tens of minutes. Each pins the images it needs by
   digest and fetches a missing one itself, so the first run downloads them. `make check` does
   not cover the language stacks, the agent hooks and the docker-lsp plugin (`make check-stacks`;
   its first run downloads the pinned tools of three stacks), the real trivy scan of the project
   test (only with `STDTEST_TRIVY=1`) and `templates/report-site`, which has no test. Run what
   your change touches before you push.

## Releasing

The maintainer runs `make release VERSION=X.Y.Z` on `next`. It refuses while any open question
remains, while `make check` or `make check-stacks` fails or while the working tree is not clean. Otherwise it sets the version
in every document, turns `Unreleased` into the release entry, merges `next` into `main` and tags
`vX.Y.Z`. Pushing the branch and the tag is a separate, manual step.

Open questions and research are the maintainer's working notes, kept locally in `.work/`, which
git ignores.
