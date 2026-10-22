# Update: move a project to a newer release

The project's registry names the release it was last reconciled against (`Standard:` in
`docs/reference/project-registry.md`). You bring it to the release in `$STANDARD`. An update only
applies the new release: the owner's answers in section 0 of the registry stay as they are and are
not asked again. To change one, the owner sets the project up again ([`start.md`](start.md)
section 2).

1. Read the `Standard:` field. Read `$STANDARD/CHANGELOG.md` from the entry after that release up to
   and including the target release. Collect every rule ID and template the entries name, and
   every setting, variable, target or file they remove or rename. Fetch the release named in
   `Standard:` the same way as in start.md, into its own cache folder
   (`$HOME/.cache/standards/$STANDARD_REPO/<that release>`).
2. For those rules and templates only, run [`adopt.md`](adopt.md) phases 0–5: orient, collect the
   facts, research what is open, compare, ask, plan. Rules the changelog does not mention are not
   re-audited, unless a fact you collect shows that one of them is broken now; record that as a
   finding too. A part the registry records as left out by the owner (mutation testing, health
   monitoring, a check set to `off`, for example) stays out: its changes are not applied, and
   its absence is not a finding. Ask the owner only about what the new release adds and the
   registry has no answer for, as [`new.md`](new.md) step 1 asks it, and record the answers in
   section 0.
3. In the plan, compare each project file that came from a template with that template in the
   release named in `Standard:`. A **verbatim** template that changed is copied again, with its
   placeholders filled as before and, for the `Makefile`, the project's settings block and its
   "Project targets" block kept (a setting the new release adds gets its default, and its value is
   a question for the owner unless the registry answers it; a project target whose name the new
   release now uses for a standard target is a finding to resolve with the owner; the parts the
   owner left out, as the list in [`templates/README.md`](../templates/README.md#mutation-testing-declined) names them for
   mutation testing, are removed from the new copy again). A setting, a
   `.env` variable or a target that the new release removes or renames is a finding too: its value
   moves to the new name the changelog gives, or, where the changelog gives none, it is removed
   with the owner's yes. Never leave it behind: an old setting the new `Makefile` no longer reads
   switches its check off without a word. A
   project change to a verbatim file is a finding to resolve with the owner first, never something
   to overwrite silently. A **starting point** that changed gets the template's change
   (`diff -u <old release>/templates/<file> "$STANDARD"/templates/<file>`) applied to the project's
   file as a task; where it meets the project's own edits, ask the owner.
4. After the owner approves the plan, execute it as in adopt phase 6. The last task sets the
   registry's `Standard:` field to the target release.

The report goes to the same place and has the same files as an adopt report; `00-summary.md` starts
with the two releases and the list of changelog entries it covers. Its steps for the owner, as in
adopt phase 6, list the variables `.env.example` gained, renamed or removed (for the `.env` of every server
and every working copy) and every step the changelog gives for running servers, such as a command
to run once on each.
