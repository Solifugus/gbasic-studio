# CLAUDE.md

Guidance for Claude Code working in this repository.

## What this is

gBASIC Studio — an IDE for gBASIC, written in gBASIC. It is a separate project
from the language, which lives at `~/development/gbasic`. Studio depends on
gBASIC the way any application depends on its runtime; nothing in gBASIC depends
on Studio.

**Read `README.md` first for status — it is not what it looks like.** The model
and persistence layers are built and tested (90 headless cases, phases STU-0
through STU-5A). The interactive shell is not: what renders is a *view* over
model state with **no signal handlers at all**, so buttons and tree rows do not
respond to clicks. That is the next work and the largest untested surface in the
project.

## Build & run

There is nothing to compile — Studio is gBASIC source. It needs an interpreter
and gBASIC's standard library, both overridable and both defaulting to a sibling
checkout:

```sh
./studio                       # gui mode, home at ~/.gbasic-studio
./studio gui /tmp/demo-home    # explicit mode + home
./studio startup /tmp/probe    # a headless mode; prints the model summary
GBASIC=/usr/local/bin/gbasic GBASIC_STDLIB=/usr/local/share/gbasic/stdlib ./studio
```

An empty home renders `(no workspace open)`, and "New Project" is not wired, so
there is no way to create one from the UI. `./studio build <home>` writes a
canned workspace headlessly; open that home with `gui` to see the shell with
content in it.

## Tests

```sh
tests/run_studio.sh            # 90 cases, headless; honours GBASIC / GBASIC_STDLIB
```

Golden-file based: a driver plus a `.out` of expected stdout, compared
byte-for-byte, so update the `.out` when output changes *intentionally* and say
so. The suite builds the sibling gBASIC first when `GBASIC` points into a source
tree, so an interpreter change is what gets tested rather than a stale binary.
Display tiers (`sections_gui`, `sessions_gui`, `results_gui`) SKIP cleanly
without GTK 4 or a display. Valgrind tiers SKIP if valgrind is absent.

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
lib/studio_shell.bas    the GTK view — a pure renderer of model state
```

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
