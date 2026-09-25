# gBASIC Studio

An IDE for gBASIC, written in gBASIC.

Studio is a separate project from the language. It depends on gBASIC the way any
application depends on its runtime — through the interpreter and its standard
library — and nothing in gBASIC depends on Studio.

## Status

**The model and persistence layer are built and tested, and the shell now
responds to input.** Phases STU-0 through STU-11 are complete — STU-0..STU-6 are
the design's MVP, STU-7 and STU-9 are the two kinds of exploratory branch,
STU-8 added rich viewers and the tabular tier, STU-10 gave the assistant the ability to
act under a permission model, and STU-11 added optional git. **The plan's phases
are all complete.**
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
field** — the last one as a path, with `~` and relative paths expanded the way
a shell would (relative to wherever you ran `./studio`). That is how you open a
project you already have: type `~/development/gdash`, press **Open Folder**, and
it becomes a project in the workspace and stays there. The empty browser says
so, and the field and the button both carry tooltips, because a field labelled
only "name" hid the one route to an existing project. Leave it empty
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

**What went wrong is readable.** The run strip's state line gets a row of its
own under the buttons, so it wraps instead of being cut: a refusal
(`run: refused [sec-3] — that section is ambiguous after the last edit;
disambiguate it first`) used to share one horizontal row with three buttons and
two labels and arrive ellipsized after its first few words, with the rest of the
sentence nowhere on screen. The **Errors** pane carries the same sentence in
full, selectable, and its heading counts what is under it — `Errors (1)` — so
a pane below the fold of the console still says there is something to scroll to.
A run Studio *declines* records no result, correctly, since nothing executed;
the message reaches the pane from the session instead, and the output panes say
`(the run did not start)` rather than showing an earlier run's output beside it.

**The editor follows the theme.** A GtkSourceView paints from a *style scheme*,
which is its own thing and not the GTK theme — and nothing set one, so the
source area stayed white inside a dark window and Studio looked like two
applications sharing a frame. It now picks `classic` or `classic-dark` (the
light one is what a buffer chose on its own, so nothing about the light editor
moved), and the tint over the section at the caret follows the same decision.
`settings.theme` is what decides: `light` and `dark` overrule the desktop,
`system` reads it — and since no single toolkit signal is reliable, all three of
`gtk-application-prefer-dark-theme`, `gtk-theme-name` and `GTK_THEME` are
consulted. That setting has been saved in every home since the first release
with nothing reading it.

**Each project keeps its own state file.** Section anchors, the branch tree and
the overlays live in `<home>/state/<key>.json`, one per project, instead of all
together in the session record — which grew with every project you had ever
opened and never shrank. Open two projects and you get two files; delete one and
you have forgotten exactly that project and nothing else. Still nothing in your
project directory: this is derived and personal, and it only means anything
beside this home's results.

**A long file name is no longer cut off mid-word.** A deep tree in a narrow
browser clipped `interpolated_string_expression_parser_regression_tests.bas`
at `interpolated_string_expression_pa` — no ellipsis to say it had been
truncated, and no horizontal scrollbar to reach the rest. Names ellipsize in
the MIDDLE now, so the extension survives (it is the part that says what the
file is), the full path is on the tooltip, and the tree indents with a margin
instead of spaces in the text, so a level is the same width at every depth.

**The tab row follows the project you are in.** The browser has always shown
one project at a time and the tabs did not, so switching projects changed the
tree and left you looking at the previous project's files. Nothing is closed by
this — a hidden document keeps its unsaved text and comes straight back when
its project does — and the status line counts what is open elsewhere, so work
you left behind is never invisible. A file opened by path with no project
adopted is always shown.

**An empty folder now says it is empty.** Expanding one used to change the
arrow and nothing else — and because directories sort before files, the rows
that stayed put underneath were its siblings, which read as its contents. It
gets a `(empty)` note now, or `(hidden files only)` when everything inside it
is a dotfile or on the project's ignore list, because those are two different
facts about the folder.

**Nicer marks in the browser.** A filled dot for the project you are in, a
hollow one for the others, and small triangles for open and closed folders. The
glyph sits in a column of its own, so names line up whatever is beside them.

**And the layout you set stays set.** The window size had been read from the
session since the first release and never once written back, and the three
dividers were fixed numbers, so a resized window and a dragged divider were
forgotten every launch. Both are saved when the window closes.

**Right-click a row in the browser.** A file offers Open, Rename and Delete; a
directory offers New File here, New Folder here, Rename and Delete; a project
offers Add project file and Close project. Every item goes through the same
function the toolbar button does, so Delete still arms on the first click and
asks for a second — a menu that deleted outright would have undone that rule
from a different control. Rename fills the name field rather than renaming, and
Close project only takes the project out of the workspace: the folder is
untouched, and Open Folder puts it back with its run history intact.

**New Project asks.** It opens a window — a name, where it goes, and four
things a new project usually wants: `main.bas`, a `README.md`, a
`.gstudio.json`, and a git repository with a `.gitignore`. Only `main.bas` is
ticked. An empty project used to be a dead end (no files, no rows, nothing to
click), and that one default closes it; everything else is off, because a box
you had to untick is not consent. There is also a licence list, and Studio does
not write a licence of its own — it copies the text from `share/licenses/` and
fills in the year and the author, taken from `git config user.name` when there
is one. Pick one it has no text for, or leave the author blank on a licence that
names a copyright holder, and it refuses and says so rather than writing a
LICENSE file that is not the licence.

It is a window Studio builds rather than a system dialog, which is why there is
a test that fills the form in and presses Create.

**A project can carry its own file, if you ask for it.** `.gstudio.json` gives a
project a stable id, so its saved state survives the folder being moved or
renamed; a list of what the browser should not show; and a pin on which gBASIC
it runs under, so a project that needs a particular build gets it on anybody's
machine. **Studio never creates this file on its own** — not on Open Folder, not
on save, not on exit, not on first run. There is one button that writes it and
nothing else does, which is the whole point: the objection to an IDE's metadata
is that it appears uninvited and then has opinions about your directory. It is
also the one dotfile the browser shows, because hiding a file you agreed to is
how it becomes uninvited again. Adding one moves the project's saved state to
the new key rather than leaving the anchors behind.

**Closing a tab no longer scrambles a file's run history.** Section anchors and
branches were filed under the document's minted `doc-N` id, which a close throws
away — so reopening the same file derived a fresh state numbered in file order,
while the ids results were recorded against deliberately are not in file order.
A file whose sections were `sec-4, sec-3, sec-1, sec-2` came back as
`sec-1, sec-2, sec-3, sec-4`, and every result then named a *different*
function. They are keyed by path now, which a close does not change.

**One file, not four.** A home used to keep its projects in
`workspaces/<id>.json`, with `session.json` pointing at it and a
`workspaces.json` registry listing the set — a set that never had more than one
member. The projects now ride inside `session.json`, and the registry is gone.
An existing home migrates itself on the next launch and **the old file is left
exactly where it is**: until the first clean save it is the only copy of that
state. A project is a name and a path; the two document lists it used to carry
(one of which nothing ever wrote) are gone.

**A project is not only its `.bas` files.** Open a README, a Makefile, a JSON
fixture — they are part of the project, and Studio now treats them as what they
are. Each is highlighted as its own language (markdown, JSON, YAML, HTML, CSS,
Python, shell, C and the rest come from GtkSourceView, so the list is not one
Studio has to maintain), and none of them is parsed as gBASIC. That last part
was the bug: every document used to go through `source_outline`, so opening
README.md reported *"this file does not parse — error 1:1 unexpected token"* and
marked line 1 in the gutter. Now the strip says `section: (not a gBASIC file)`,
the errors pane says nothing, and Run answers `README.md is not a gBASIC file —
Run Section needs .bas or .gb`. Editing and saving work exactly as before.

**A file that does not parse says where.** It used to say nothing useful: no
sections means no section at the cursor, so the strip read `section: (none)` and
Run answered "the cursor is not inside a runnable section" — true, and useless,
with the caret sitting plainly inside a function. Studio had the parser's
diagnostic the whole time and threw it away on every keystroke. Now the strip
says `section: (this file does not parse)`, the Errors pane carries
`error 8:8  syntax error, unexpected THEN`, pressing Run puts the same line in
the status bar, and **the gutter marks the line** — the marker moves when the
error moves and goes when it is fixed, and the section arrows come back with it. Break a file that was parsing a moment ago and the run is
refused instead — the sections from before survive, so the caret still resolves
— and the pane shows both the refusal and the address it does not carry.

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

**Exploratory branching, state-only (STU-7).** At a section boundary you can keep
alternate continuations and switch between them. Everything *above* the branch
point is shared ancestry; everything below may diverge. A state-only branch runs
**identical source** — what differs is the bindings it injects at its point, so
the same file answers `score is 50` on the baseline, `25` on one branch and `90`
on another, and the file on disk never changes. Each branch keeps its own run
history rather than interleaving with its siblings.

A branch is **not a Git branch** — not stored, surfaced or created as one. If the
code above a branch point changes, the branch is flagged `[ancestry changed]` and
stays selected: Studio surfaces stale state rather than acting on it, and
re-anchoring is a separate deliberate click.

**Code-overlay branches (STU-9).** The other half of branching: experiment with
*downstream code* without touching the file. An overlay changes only what is
below the branch point, lives in Studio metadata, is visibly marked
experimental, and is never a second `.bas` and never a Git branch.

```
    Baseline
  * Robust [experimental: 1 section(s)]
    +

  the branch runs:   score is 500
  the baseline runs: score is 50
  the file on disk:  byte-identical, throughout
```

**How an overlay is represented was the open question** (design Q5), and the
answer decides everything downstream. Not a textual diff — that needs a patch
engine, and "does this hunk still apply?" is a fuzzy question whose wrong answers
are silent misapplications. Not an AST patch — the platform exposes structure,
not a rewritable tree. An overlay is a **per-section replacement text** stamped
with the fingerprint of the canonical section it was written against. So:
applying is the splice the run pipeline already does, and a **conflict is a hash
comparison** — no context matching, no fuzz, no judgement. The cost is that an
overlay replaces whole sections, which is also the unit Studio executes, anchors
and files results against.

**Rebase does not claim to be a merge.** There is nothing to merge — an overlay
*is* the whole section — so accepting it *shadows* the canonical change, and
Compare is where that stays visible. An overlay whose section was deleted cannot
be rebased onto anything: it is reported unresolved and left for you to discard,
never dropped silently. **Promote** is refused outright while anything conflicts,
and writes into the buffer as an ordinary unsaved edit — Studio's rule is that
you save your own edits.

**Rich viewers a library registers for its own types (STU-8).** Structural
dispatch sees a `stats.ols` result as a record holding six unrelated arrays, and
shows six unrelated arrays. A statistician reads it as R² and then a coefficient
table — coef, s.e., t and p *across* from each term. Only the library that
produced those four parallel arrays knows they are one table, so a library may
ship a declarative sidecar named after itself — `stats.bas` alongside
`stats.viewers` — holding JSON, never code. Studio reads it; Studio never
evaluates it. That is the whole registration protocol: no core-language change,
no import hook, nothing a library must do at run time. gBASIC still has no idea
what "display" means.

```
    m record[11]
      OLS regression
        observations  100
        R²            0.8421
        adj. R²       0.8405
        terms (3):
          term  coef       s.e.      t       p
          0     1.203104   0.114023  10.551  <0.0001
          1     0.48719    0.031089  15.671  0.0002
          2     -0.009312  0.004402  -2.115  0.0372
```

Matching is over the *descriptor*, never a value: under the replay model the
child that computed the regression exited before the pane was drawn. Extraction
therefore cannot happen in Studio either — the preview stringifies — so a
viewer's `detail` list is compiled into the run's variable epilogue and the
values are fetched in the child, where they still exist.

**Tables, and what a sample is (STU-8).** Studio does not assume every large
structure is a table: a record has fields, not rows. What is recognizably tabular
gets an offer, and opening it shows *the rows Studio has* — which after a
finished run is a bounded sample, because the child that held the array is gone.
The caption says so in the same breath as the total: `50 of 48,291 rows (sampled
— the run that made them has ended)`. A grid captioned with a number it cannot
show is a lie told by omission, and it is the exact lie this architecture makes
easy.

**Fetch all rows** re-runs the section with an export epilogue, through the same
function the Run button uses, so an export can never come from a run that differs
from the one you are reading results from. Past a few hundred rows the grid is
the general `DataGrid` (a virtualized `GtkColumnView`), and rows are decoded only
when a cell of them is bound. Both halves are measured rather than asserted: the
display tier runs the same interaction over a 1,200-row table and a 12,000-row
one and requires byte-identical output — the bind count is a function of the
window, not of the table.

**Git, when you use it and invisible when you don't (STU-11).** Status, diff,
history, branches and commit, all over `process.run` invoking `git` — no bespoke
binding. Outside a repository the pane is not collapsed, it is **not there**, and
the status bar says nothing at all: Studio mentioning git to someone who doesn't
use it, on every click, is precisely what the design asks it not to do.

Git is found by **looking for the executable** on `PATH`, never by running it —
`process.run` raises when a program is missing and gBASIC cannot catch a raise,
so asking the question by trying would crash the window of everyone without git.
That single constraint is why git can be optional at all.

A Studio exploratory branch is still **not** a Git branch. The one crossover is
that a promoted overlay becomes an ordinary working-tree edit — which Git sees
because it *is* one, not because Studio told it anything.

**An assistant that can act, under permissions you set (STU-10).** The agent
performs the *same semantic operations your buttons do* — it calls into the same
layer, so "the agent can do what you can do" is a property of the code rather
than a claim. Tools sit in three tiers, and the line between them is
**reversibility, not how dangerous the name sounds**:

| tier | examples | default |
|---|---|---|
| read | observe the project, files, state, history | automatic |
| local | navigate, edit a buffer, run a section, make a branch | ask first |
| external | save over a file, delete, rename | ask first |

Editing is *local* because a buffer edit is unsaved until you press Save.
Deleting is *external* because Studio cannot put it back.

**Scopes narrow; they never widen.** Global sets your defaults, a project may
only tighten them, and a session can clamp everything down — *"read-only this
investigation"*. If the innermost scope simply won, a project config could hand
the agent more authority than you granted, and that file is one somebody else
may have written.

**A confirmation is bound to the act.** The token hashes the tool name *and its
arguments*, so confirming `delete a.bas` can never be spent on `delete b.bas`.
Every act is recorded in the history — **including the refused ones**, because a
log of successes is a record of what worked, not of what was attempted.

There is no in-loop confirmation dialog, deliberately: confirmation is granted by
policy. A dialog is an async surface no test can press, which is the same reason
names come from a header field and Delete takes two clicks.

**Teaching, and secrets.** The agent can point at the window by name — highlight,
pulse, focus, reveal, or annotate a line range — and a bad name is refused *with
the list of real ones*, so a model can correct itself. API keys live in an
encrypted store whose key comes from your environment and is **never written to
disk**; without libcrypto the store refuses to save rather than quietly falling
back to plaintext.

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

An empty home renders `(no workspace open)`; click **New Project** and a window
asks for a name, a location and which files to make — `main.bas` is ticked, so
Create lands you on a file you can run. The directory goes under
`<home>/projects/` unless you change the Location. **New File** adds more. To work on a directory you
already have, type its path into the header's name field and press **Open
Folder**, or pass it as the third argument (above). To start from a canned
workspace instead:

```sh
./studio build /tmp/demo-home
./studio gui   /tmp/demo-home
```

## Tests

```sh
tests/run_studio.sh           # 183 cases, headless; honours GBASIC / GBASIC_STDLIB
tests/run_studio_agent.sh     # 29 cases, headless AND offline — no network, no key
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
writes), `process.which` (finding an optional tool without risking the raise
that running a missing one causes), and the `persist`, `filetree`, `gtk`,
`sourceeditor` and `gi` libraries.

**Studio requires gBASIC 0.1.0-rc3 or later.** The floor is `process.which`,
and it cannot be probed around: an older interpreter also lacks `has_builtin`,
so there is no way to ask "do I have it?" without crashing — you cannot probe
for the prober. A build that is too old fails loudly at the first git
detection rather than degrading.
