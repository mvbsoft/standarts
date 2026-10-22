# report-site

The page on which the agent shows the owner a report, its questions and its plan
([`prompt/start.md`](../../prompt/start.md), section 3). It is not copied into a project.

- **Source of truth:** the md files of the report folder. The page only renders them, on three tabs:
  "State" (`00-summary.md`, `01-current-state.md`, `02-deviations.md`), "Questions"
  (`questions.md`) and "Plan" (`03-target-and-plan.md`, `04-registry.md`, `05-sources.md`,
  `proposals.md`). A missing file is skipped. The formats are in
  [`prompt/adopt.md`](../../prompt/adopt.md), section "Report".
- **Publishing (Claude app):** publish `index.html` verbatim as an artifact, with the md files as
  supporting files at the same names (type `text/markdown`) and the capability `db`. Update the
  same artifact when the files change. If the publishing tool takes files only from certain folders
  (in Claude Code: the working folder or the scratchpad), copy `index.html` and the md files into
  such a folder outside the project and publish from there; the report folder stays the source.
- **Answers:** the owner picks an option or "own option" and may comment. Where the page can store
  data, every answer is saved as the document `answers/<question id>` with the fields `choice`
  (the option letter or `other`), `note` and `updatedAt`; read them from the artifact's database
  (collection `answers`) when the owner says they answered. The button "Copy answers" always
  works too: the owner pastes the text into the chat.
- **No page possible:** say what did not start, why, and how to make it work; then use the md files
  and the chat ([`prompt/start.md`](../../prompt/start.md), section 3).
