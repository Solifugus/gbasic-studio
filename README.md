# gBASIC Studio

An IDE for gBASIC, written in gBASIC.

Studio is a separate project from the language. It depends on gBASIC the way any
application depends on its runtime — through the interpreter and its standard
library — and nothing in gBASIC depends on Studio.

## Status

**The model and persistence layer are built and tested, and the shell now
responds to input.** Phases STU-0 through STU-5A are complete as libraries;
STU-2B wired the first interactions on top of them and STU-2C made a cold start
go all the way through.

What works when you click it: a browser row (a file opens into a tab, a
directory expands, a project becomes active), a notebook tab, typing in the
editor (the tab's dirty marker follows), and the New Project / New File /
New Folder / Save / Refresh buttons. From an empty home you can now make a
project, make a file in it, type into it, save it, and close the window — and it
is all still there next time, because closing now writes the session.

New File and New Folder land in whatever the browser has selected: a directory,
the directory holding the selected file, or the project root. Neither asks for a
name; they mint `untitled-N.bas` / `new-folder-N`, for the same reason New
Project does not ask — a modal dialog is an async GTK surface with no signal a
test can synthesise, so it belongs to the phase that designs how such a dialog
gets covered.

What still does not respond: closing a tab, renaming or deleting anything, the
run/stop strip (STU-4's widgets are built but only driven by the smoke modes),
the results pane, and anything STU-5 onward. A conflicting external change shows
as an ordinary dirty marker — the tab does not distinguish it from your own
unsaved edits. Closing the window saves *which* documents were open, not what
was typed into them: Studio has no draft store, so unsaved buffers are lost and
it says so on stderr as it exits.

Interaction is covered by tests rather than by hand. The rule STU-2B established
is that a signal handler is an *adapter* — read one value off the widget, call
one `studio_ui` function, redraw — so what a click MEANS lives in `lib/studio_ui.bas`
and is asserted headlessly. The display tier then synthesises real GTK signals
(there is no `gi.emit`; `GtkListBoxRow.activate`, `GtkNotebook.set_current_page`,
`GtkTextBuffer`'s text setter and `GtkButton.activate` emit what is needed) to
prove the handlers are actually connected.

See `docs/gbasic_studio_design.md` for what Studio is meant to be, and
`docs/gbasic_studio_plan.md` for the phase sequence (STU-0..STU-11).

## Running it

```sh
./studio                      # gui mode, home at ~/.gbasic-studio
./studio gui ~/my-studio-home # explicit
./studio gui ~/.gbasic-studio ~/development/myproject   # open an existing folder
./studio startup /tmp/probe   # a headless mode, prints the model summary
```

The launcher finds gBASIC through two overridable variables, both defaulting to
a sibling checkout:

```sh
GBASIC=/usr/local/bin/gbasic GBASIC_STDLIB=/usr/local/share/gbasic/stdlib ./studio
```

An empty home renders `(no workspace open)`; click **New Project** and Studio
creates a workspace plus a project directory under `<home>/projects/` and shows
it, then **New File** gives you something to type in. To work on a directory you
already have, pass it as the third argument (above) — there is no Open Folder
button yet. To start from a canned workspace instead:

```sh
./studio build /tmp/demo-home
./studio gui   /tmp/demo-home
```

## Tests

```sh
tests/run_studio.sh           # 108 cases, headless; honours GBASIC / GBASIC_STDLIB
```

Golden-file based: a driver plus a `.out` holding expected stdout, compared
byte-for-byte. The suite builds the sibling gBASIC first if `GBASIC` points into
a source tree, so an interpreter change is what gets tested rather than a stale
binary. Display tiers (`sections_gui`, `sessions_gui`, `results_gui`, `ui_gui`,
`ui_gui_cold`, `ui_gui_new`) SKIP cleanly without GTK 4 or a display.

## Layout

```
app/studio.bas     entry point; dispatches modes (gui + the headless lifecycle)
lib/*.bas          the libraries — model, docs, sections, session, results, shell
tests/run_studio.sh
tests/drivers/     harness programs for the STU-2B/3/4/5A tiers
tests/studio/      goldens
tests/helpers/     a shell helper for the signal-escalation case
docs/              design, phase records, and the GTK requirements survey
```

Libraries resolve through `GBASIC_PATH="lib:$GBASIC_STDLIB"`. The entry point
lives in `app/` rather than at the root deliberately: gBASIC also searches the
*importing file's* directory recursively, so an entry beside `lib/` would find
every library twice and warn about it.

## What Studio uses from gBASIC

Studio drove a lot of the platform work, and consumes it rather than
reimplementing it: `source_outline` (structural sections), `try_decode` (reading
JSON that may be corrupt without raising), `process.start`/`poll`/`read`/`stop`
(running a section in a child), `--line-buffered` and `print to error` (getting
that child's output promptly and separably), `atomic_replace` (crash-safe
writes), and the `persist`, `filetree`, `gtk`, `sourceeditor` and `gi` libraries.
