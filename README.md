# gBASIC Studio

An IDE for gBASIC, written in gBASIC.

Studio is a separate project from the language. It depends on gBASIC the way any
application depends on its runtime — through the interpreter and its standard
library — and nothing in gBASIC depends on Studio.

## Status

**The model and persistence layer are built and tested, and the shell now
responds to input.** Phases STU-0 through STU-6 — the design's MVP — are complete;
STU-2B wired the first interactions on top of them, STU-2C made a cold start go
all the way through, STU-2D made the browser editable, STU-2E made Run work, and
STU-5A′ pointed the panes at the caret.

What works when you click it: a browser row (a file opens into a tab, a
directory expands, a project becomes active), a notebook tab, typing in the
editor (the tab's dirty marker follows), and the New Project / New File /
New Folder / Rename / Delete / Close / Save / Refresh buttons. From an empty home
you can make a project, make a file in it, name it, type into it, save it, rename
it, delete it, and close the window — and what is left is still there next time,
because closing now writes the session. The status bar says what each click did,
including what it refused to do and why.

New File, New Folder, Rename and **Open Folder** read the header's **name
field** — the last one as a path. Leave it empty
and creation mints `untitled-N.bas` / `new-folder-N`; type into it and that is
the name. It is a field rather than a dialog on purpose: a GtkEntry's text can be
set programmatically, so the display tier types into it and clicks Rename for
real, which no test could do to a modal dialog.

Creation lands in whatever the browser has selected: a directory, the directory
holding the selected file, or the project root.

**Delete takes two clicks** — the first arms it and says so in the status bar,
the second does it, and clicking anything else in between cancels. Closing a tab
with unsaved text works the same way. A directory is only deleted when it is
empty; recursive deletion is a different promise and does not belong behind a
button that can be pressed twice by accident.

**Run Section works** (STU-2E), which is the point of the whole thing: put the
caret in a section and press Run, and Studio replays the sections above it in a
fresh child interpreter and then runs yours. Prefix output and target output are
shown separately — the replay really does re-issue the earlier sections' side
effects, and hiding that would be a lie. Stop and Force Stop end a run that will
not; the strip shows all eight session states, including `unresponsive`. Every
finished run becomes a durable result under the section's stable id, with the
history behind it and a mark on any result whose section has been edited since.

A caret outside every section — the blank last line of a file, where it very
often sits — resolves to the nearest section rather than refusing.

**The panes follow the caret.** The run strip names the section you are in before
you press Run, and the results pane shows that section's history — move the caret
and both change. A caret in the whitespace between sections belongs to the section
above it; on a file's trailing blank line, to the last one.

**A run now reports its variables.** The materialized prefix ends with an
epilogue that asks `reflect` what the target section left behind — name, kind,
type, category, whether it can be serialized, and a count — so the data an
inspector needs exists. It is shallow on purpose: a section that built a
million-row array reports the count and nothing else until something asks for
more. A section that raised never reaches the epilogue, and that is reported as
`absent` rather than as an error.

They are stored with the run and shown under its output, **changed first** —
`~` for a variable the section altered, `+` for one it created — because a second
dump is taken before the section runs and the two are diffed.

Each variable comes with a **bounded preview**: a scalar shows its value, a record
its fields, an array of records a table with the element's fields as columns. The
bound is the point — a 500-element array is sampled to 50 and says `... 450 more`,
so inspecting never copies a large structure. A results file written by an older
Studio still loads; its results simply have no variable capture.

**A result from an earlier session is cold.** Reopening a project restores the
cheap layer instantly — files, caret, run history — and deliberately does not
replay anything: running your code on open, side effects and all, before you
asked for it would be worse than the wait it saves. So the strip says
`cold — recorded in an earlier session; Run to rebuild the state`, and Run is how
you get the state back.

What is not there: expansion beyond the preview's bound. Looking deeper than the
sample means re-running the section, because the child that held the values is
gone — that is the replay model, not an oversight, and Studio says `... N more`
rather than pretending otherwise. There is also no interactive table widget; the
table is rendered as text in the results pane.

**Unsaved work survives closing the window.** A dirty buffer is written beside the
workspace on the way out and put back on the way in — still unsaved, so the
decision to write it to your file remains yours. If the file changed on disk
while Studio was closed, the draft still comes back and the document is flagged
as a conflict rather than either fact being hidden.

**A tab says which kind of trouble it is in.** `*` is your unsaved edits, `~` is
the file having changed on disk underneath them, and `!` is the file being gone.
Those first two used to look identical, which mattered: **Save on a `~` tab
overwrites whatever else wrote the file**, so it now takes two clicks and says
what it is about to do.

**A read-only assistant (STU-6).** Studio keeps a semantic action history — files
opened, sections selected and run, errors raised, in its own vocabulary rather
than as keystrokes — and an assistant answers *"where was I?"* from it. The
assistant is read-only **structurally**, not by policy: there is no write tool in
the registry to permit or forbid, dispatch goes through a fixed table that
refuses any name it does not hold, and nothing a model says is ever evaluated as
source. It needs `ANTHROPIC_API_KEY` in the environment; without one the pane
says so and the rest of Studio is unaffected.

The history is bounded. The newest few hundred events keep their detail and
everything older is compacted into per-kind rollups — still a true statement
about what happened, just a coarser one — so the log cannot grow until Studio
gets slow.

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
already have, type its path into the header's name field and press **Open
Folder**, or pass it as the third argument (above). To start from a canned
workspace instead:

```sh
./studio build /tmp/demo-home
./studio gui   /tmp/demo-home
```

## Tests

```sh
tests/run_studio.sh           # 125 cases, headless; honours GBASIC / GBASIC_STDLIB
tests/run_studio_agent.sh     # 7 cases, headless AND offline — no network, no key
```

Golden-file based: a driver plus a `.out` holding expected stdout, compared
byte-for-byte. The suite builds the sibling gBASIC first if `GBASIC` points into
a source tree, so an interpreter change is what gets tested rather than a stale
binary. Display tiers (`sections_gui`, `sessions_gui`, `results_gui`, `ui_gui`,
`ui_gui_cold`, `ui_gui_new`, `ui_gui_name`, `ui_gui_solo`, `ui_gui_run`,
`ui_gui_cursor`) SKIP cleanly without GTK 4 or a display.

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
