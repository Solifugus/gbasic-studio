# gBASIC Studio — STU-0 skeleton

This is the first executable slice of **gBASIC Studio** (see
`docs/gbasic_studio_plan.md`, phase **STU-0**). STU-0 builds the persistent
**backbone**, not an editor: you can launch Studio, create/open a workspace, close
it, relaunch, and find the working context restored.

The domain model and persistence are pure-gBASIC stdlib libraries — headless and
fully testable without a display:

- `stdlib/studio_store.bas` — crash-safe, versioned persistence (atomic write, defensive read)
- `stdlib/studio_model.bas` — the domain model (settings / session / workspace / project / document), stable ids, forward/back-compatible normalization
- `stdlib/studio.bas` — the application object + startup/shutdown lifecycle
- `stdlib/studio_shell.bas` — the GTK 4 shell (a view over the model; display only)

`examples/studio/studio.bas` is the thin entry point.

## Run

Headless (no display needed):

```sh
GBASIC_PATH=stdlib ./gbasic examples/studio/studio.bas startup   /tmp/mystudio
GBASIC_PATH=stdlib ./gbasic examples/studio/studio.bas build     /tmp/mystudio   # create + persist
GBASIC_PATH=stdlib ./gbasic examples/studio/studio.bas startup   /tmp/mystudio   # restored
```

GUI (needs the GTK 4 typelib `gir1.2-gtk-4.0` + a display):

```sh
GBASIC_PATH=stdlib ./gbasic examples/studio/studio.bas gui ~/.gbasic-studio
```

## Modes

| Mode | Display? | What it does |
|---|---|---|
| `startup <home>` | no | run the startup pipeline, print the model summary |
| `build <home>` | no | startup, build a canned workspace, shut down (persist) |
| `roundtrip <home>` | no | build + shut down + relaunch; print restored summary |
| `stress <home>` | no | 30 atomic save/reload cycles; assert every reload loads |
| `cycles <home>` | no | 50 startup/shutdown cycles (memory/leak probe) |
| `smoke` | yes | build the shell over a canned workspace, print a transcript, quit |
| `stu3_smoke <home> [file]` | yes | shell + a real editor tab; derive execution sections from the live buffer and resolve the document's cursor to a section id, then quit |
| `stu4_smoke <home> [file]` | yes | shell + run bar + output pane; run the section under the cursor and drive the child from a GTK timeout until it finishes, then quit |
| `stu5_smoke <home> [file]` | yes | as `stu4_smoke`, plus the results pane: the finished run is recorded, persisted, read back from disk and rendered, then the section is edited so the stale-content mark appears |
| `gui` (default) | yes | startup + shell + run the GTK loop |

`examples/studio/sections.bas` is a separate headless driver for the STU-3
execution-section engine (`stdlib/studio_sections.bas`); it takes a scenario mode and
no home, e.g. `GBASIC_PATH=stdlib ./gbasic examples/studio/sections.bas derive`. See
`docs/gbasic_studio_stu3.md`.

`examples/studio/sessions.bas` is the headless driver for the STU-4 execution-session
engine (`stdlib/studio_session.bas`); it takes a scenario mode and a scratch directory,
e.g. `GBASIC_PATH=stdlib ./gbasic examples/studio/sessions.bas clean /tmp/scratch`. See
`docs/gbasic_studio_stu4.md`, and `docs/gbasic_studio_stu4b.md` for the STU-4B modes
(`hoist*` declaration hoisting, `split*` output separation, `map`, `stream`).

`examples/studio/results.bas` is the headless driver for the STU-5A persistent
results store (`stdlib/studio_results.bas`); it takes a scenario mode, a scratch
directory, and a throwaway Studio home, e.g.
`GBASIC_PATH=stdlib ./gbasic examples/studio/results.bas persist /tmp/scratch /tmp/home`.
Modes: `persist history fingerprint orphan refused signal truncate evict concurrent
compat store view`. See `docs/gbasic_studio_stu5a.md`.

## Automated tests

`tests/run_studio.sh` — the headless backbone suite (empty startup, save/restore,
corrupt-session recovery, future-version rejection, atomic-save stress, and a
valgrind-clean 50-cycle memory probe). Runs everywhere; no display or GI needed.
`tests/run_gui_parse.sh` parse-checks this file in CI so the shell can't silently
rot.

## Manual display checklist (STU-0 shell)

The shell is display-only, so it is verified by hand (and by the parse smoke).
With a display available:

```sh
GBASIC_PATH=stdlib G_DEBUG=fatal-criticals ./gbasic examples/studio/studio.bas smoke
```

Expect a deterministic transcript and a clean exit with no GLib criticals:

```
shell-built
workspace=member-analytics
projects=1
app-exited
```

For the interactive shell (`gui` mode), confirm:

- [ ] a window titled `gBASIC Studio — <workspace>` opens at the session's size
- [ ] a header strip with the brand label and a (placeholder) `Menu` button
- [ ] a resizable split: a navigation pane listing projects/documents on the left
- [ ] a placeholder editor area on the right (`(editor area — STU-2)`)
- [ ] a status bar reading `ready — <workspace> — N project(s)`
- [ ] closing the window exits cleanly

The editor, section widgets, inspector, and dynamic tab strip are later phases
(STU-1/STU-2+); STU-0 only proves the shell mounts from the model.
