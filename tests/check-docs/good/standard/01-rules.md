# Rules

> Version 1.0.0

### ENV-01. One file per environment

Each environment has one file. The file names the environment. Back to [the top](#rules), to
[the second notes](#notes-1) and to [a heading with code](#the-make-stage-target--and-its-checks).

A passage in a code block or a table is not prose, so it may repeat:

```
The deploy builds every image from the commit itself, so nothing uncommitted on the server
reaches it. A build that fails leaves the old version running, and the output names the step
that failed, so the next deploy can start from a clean state.
## Not a heading
```

| What | Why |
|---|---|
| deploy | The deploy builds every image from the commit itself, so nothing uncommitted on the server reaches it. A build that fails leaves the old version running, and the output names the step that failed, so the next deploy can start from a clean state. |

## Notes

The first notes.

## Notes

The second notes, linked as #notes-1 (a link to [#not-a-heading](#rules) inside `code` is not checked).

## The `make stage` target — and [its checks](../GUIDE.md)
