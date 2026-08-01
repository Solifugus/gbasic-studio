# CLAUDE.md

Guidance for Claude Code working in this repository.

## What this is

gBASIC Studio — an IDE for gBASIC, written in gBASIC. It is a separate project
from the language, which lives at `~/development/gbasic`. Studio depends on
gBASIC the way any application depends on its runtime; nothing in gBASIC depends
on Studio.

**Read `README.md` first for status.** The model and persistence layers are built
and tested (phases STU-0 through STU-5A), and STU-2B wired the shell's first
input handlers on top of them: browser rows, tabs, editor edits, and the
Save / Refresh / New Project buttons all respond. STU-2C added New File and
New Folder (a cold start now reaches a file you can type in), opening an existing
directory from the command line, and saving the session when the window closes.
STU-2D added the name field, Rename, Delete and Close — the last two behind a
two-click confirmation — plus a status line that reports every outcome. The
run/stop strip and everything STU-5 onward still do not respond; see README.

## Build & run

There is nothing to compile — Studio is gBASIC source. It needs an interpreter
and gBASIC's standard library, both overridable and both defaulting to a sibling
checkout:

```sh
./studio                       # gui mode, home at ~/.gbasic-studio
./studio gui /tmp/demo-home    # explicit mode + home
./studio gui /tmp/demo-home ~/src/proj   # gui + an existing folder as a project
./studio startup /tmp/probe    # a headless mode; prints the model summary
GBASIC=/usr/local/bin/gbasic GBASIC_STDLIB=/usr/local/share/gbasic/stdlib ./studio
```

An empty home renders `(no workspace open)`; **New Project** creates a workspace
and a project directory under `<home>/projects/`, and **New File** puts something
in it. Closing the gui window runs `studio.persist`, so the home is written on
exit — unsaved *buffers* are not (there is no draft store; the exit path warns on
stderr). `./studio build <home>` still writes a canned workspace headlessly if
you want content without clicking.

## Tests

```sh
tests/run_studio.sh            # 115 cases, headless; honours GBASIC / GBASIC_STDLIB
```

Golden-file based: a driver plus a `.out` of expected stdout, compared
byte-for-byte, so update the `.out` when output changes *intentionally* and say
so. The suite builds the sibling gBASIC first when `GBASIC` points into a source
tree, so an interpreter change is what gets tested rather than a stale binary.
Display tiers (`sections_gui`, `sessions_gui`, `results_gui`, `ui_gui`,
`ui_gui_cold`, `ui_gui_new`, `ui_gui_name`, `ui_gui_solo`) SKIP cleanly without
GTK 4 or a display.
`ui_gui_new` is the only case that spans two processes: the GUI builds a project
from nothing and closes, and a second interpreter run reopens the same home —
because a process asserting its own memory cannot show that anything reached
disk. Valgrind tiers SKIP if
valgrind is absent. The `ui_gui*` tiers discard stderr like the other
loop-running tiers: GTK's allocation warnings vary by version and theme, and
`G_DEBUG=fatal-criticals` turns a real GTK critical into a nonzero exit anyway.

Before a release, also run against what users actually have:

```sh
GBASIC=/usr/local/bin/gbasic GBASIC_STDLIB=/usr/local/share/gbasic/stdlib tests/run_studio.sh
```

## Architecture

```
app/studio.bas   entry point; dispatches modes, owns the GTK application object
                 and the callback-scope global, and is the ONLY place with
                 gi.connect
lib/studio.bas          app lifecycle over the model (launch/create/open/shutdown)
lib/studio_model.bas    workspace / project / session / settings schema
lib/studio_docs.bas     document manager: open, dirty, save, close, external change
lib/studio_sections.bas execution sections over source_outline, with stable ids
lib/studio_session.bas  replay-first execution in a child interpreter, 8 states
lib/studio_results.bas  durable per-run results, retention, truncation, standing
lib/studio_ui.bas       what an interaction MEANS — the browser/tab row models and
                        one function per interaction, over plain data, no GTK
lib/studio_shell.bas    the GTK view — renders model state and reconciles on
                        redraw; holds no decisions
```

**The interaction rule (STU-2B), which later phases must follow.** A signal
handler is an ADAPTER: read one plain value off the widget, call one
`studio_ui` function, ask for a redraw. Nothing else. Every decision lives in
`studio_ui` as an ordinary function over plain data that `tests/drivers/ui.bas`
calls directly, so the untestable surface is only the widget-to-value read —
which the `ui_gui` display tier covers by synthesising real signals. **Logic in a
handler is a design failure, not a testing inconvenience.**

Two consequences worth knowing before you touch the shell:

- `studio_ui.nav_rows` produces the browser rows ONCE, and the renderer and the
  click dispatcher consume that same array. Deriving rows twice desynchronises
  the moment the filesystem changes between a render and a click.
- Anything that creates in the browser goes through `studio_ui.target_dir`, which
  is the *whole* of "where does it land" — selected directory, the directory
  holding the selected file, or the project root. Creating in a collapsed
  directory also expands it: a file that exists and is not on screen reads as the
  button having done nothing. `new_folder` deliberately does not move the
  selection, or a second New Folder would nest inside the first.
- Destructive actions arm before they fire, and the arm is keyed to the *thing*
  (a path for Delete, a document id for Close) rather than to a flag — so moving
  the selection between the two clicks re-arms on the new row instead of deleting
  it. `redraw` expires an arm that the last action did not renew
  (`studio_ui.arm_kind`), which is what stops one from outliving an unrelated
  click. Do not reintroduce a confirmation dialog: it would be an async surface
  no test can press, which is the same reason names come from a header field.
- Every outcome gets a status line via `studio_ui.action_notice`. A refusal that
  says nothing is indistinguishable from a dead button, which is how the whole
  window felt before STU-2B.
- The GtkApplication is built with `NON_UNIQUE` flags in `app/studio.bas` rather
  than via `gtk.application`, which defaults to single-instance. Reverting that
  does not just stop a second window opening — the *running* instance gets an
  extra `activate`, builds a second shell over the same globals and doubles every
  handler. `ui_gui_solo` is the regression test.
- Redraw REBUILDS the nav pane but RECONCILES the notebook by document id. A
  notebook page holds a live buffer with unsaved text; rebuilding it would
  destroy what the user is typing. `app/studio.bas`'s `G.redrawing` guard exists
  because our own `set_current_page`/`set_text` echo back as signals.

Libraries resolve through `GBASIC_PATH="lib:$GBASIC_STDLIB"`. **The entry point
lives in `app/` on purpose**: gBASIC searches the importing file's directory
*recursively* as well as `GBASIC_PATH`, so an entry beside `lib/` finds every
library twice and warns about each one.

Dependencies are declared, not assumed — a library that calls into another loads
it. Keep it that way.

## What Studio uses from gBASIC

Studio drove much of the platform work and consumes it rather than
reimplementing it: `source_outline`, `try_decode`, `process.start`/`poll`/`read`/
`stop`, `--line-buffered`, `print to error`, `atomic_replace`, and the `persist`,
`filetree`, `gtk`, `sourceeditor` and `gi` libraries. If something here wants a
capability that is not about Studio, it belongs in gBASIC's stdlib, not here.

One coupling to know: gBASIC's `tests/run_pre_registration.sh` is a tripwire on
the set of declarations its interpreter pre-registers, and it names
`lib/studio_session.bas`'s `_hoistable_kind()` as what must change with it. If
that test fails over there, the fix is probably here.

## House rules

- **Before writing gBASIC code**, read `~/development/gbasic/docs/ai/START-HERE.md`
  and follow it (`UNLEARN.md` first). gBASIC diverges from QBasic/VB intuition in
  ways that fail silently.
- **When you work around a gBASIC limitation or surprise**, append an entry to
  `~/development/gbasic/DOGFOOD.md` using its template *before continuing*.
  Studio is the main dogfooder; that log is how language defects get found.
- **Evidence standards:** tests-first where feasible; keep goldens byte-exact (a
  behavioural change that moves a golden is a deliberate, listed rebaseline);
  measure, don't assume; report what you could not verify. Never mark anything
  "verified".

## Known live issue

`if lib_fn(x) = "..."` misfires when `lib_fn` is an unqualified call to a
`load`ed library's function with an identifier argument — it parses, then fails
at run time with `compare modifier not found: x`. Call it qualified
(`lib.fn(x)`) or bind the result first. Not fixable at token delivery; see
`docs/gbasic_clause_recognition.md` §9 in the gBASIC project.
