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
two-click confirmation — plus a status line that reports every outcome. STU-2E
mounted the run strip and the results pane that STU-4/STU-5A had built but
nothing displayed: Run / Stop / Force Stop drive a real child interpreter and
every finished run becomes a durable result. STU-5A′ pointed the run strip and
the results pane at the CARET rather than at the last run. STU-5's gutter and
variable inspector still do not exist; see README.

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
tests/run_studio.sh            # 163 cases, headless; honours GBASIC / GBASIC_STDLIB
tests/run_studio_agent.sh      # 29 cases, headless AND offline (scripted transport)
```

Golden-file based: a driver plus a `.out` of expected stdout, compared
byte-for-byte, so update the `.out` when output changes *intentionally* and say
so. The suite builds the sibling gBASIC first when `GBASIC` points into a source
tree, so an interpreter change is what gets tested rather than a stale binary.
Display tiers (`sections_gui`, `sessions_gui`, `results_gui`, `ui_gui`,
`ui_gui_cold`, `ui_gui_new`, `ui_gui_name`, `ui_gui_solo`, `ui_gui_run`,
`ui_gui_cursor`, `ui_gui_open`, `ui_gui_branch`, `ui_gui_table`, `ui_gui_overlay`, `ui_gui_teach`, `ui_gui_git`) SKIP cleanly
without GTK 4 or a display.
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
lib/studio_branches.bas STU-7 state-only branches: a tree of alternate
                        continuations, each a set of BINDINGS replayed over
                        identical source; anchored to its shared ancestry
lib/studio_viewers.bas  STU-8 library-registered rich viewers: declarative
                        `.viewers` sidecars, read and never evaluated
lib/studio_table.bas    STU-8 the tabular tier: what is a table, and where its
                        rows come from (a capture sample, or a fetched export)
lib/studio_overlays.bas STU-9 code-overlay branches: per-section replacement
                        text, stamped with the canonical fingerprint it was
                        written against; projected, never written to the .bas
lib/studio_git.bas      STU-11 optional git over `process.run` — found by
                        `process.which` (never by running it), because
                        process.run raises on a missing executable and gBASIC
                        cannot catch a raise
lib/studio_drafts.bas   unsaved buffers across a close; conflict-aware, keyed by
                        a hash of the text the buffer was based on
lib/studio_history.bas  the semantic action log — a closed vocabulary, bounded
                        by compaction into per-kind rollups
lib/studio_tools.bas    the semantic tool surface: STU-6 reads plus STU-10 acts,
                        every one of them a call into studio_ui — one gate
                        (`invoke`), which decides permission before dispatching
lib/studio_permissions.bas STU-10 tiers (read/local/external), policies
                        (auto/confirm/deny), and scope composition. Scopes
                        NARROW; they never widen
lib/studio_teaching.bas STU-10 pointing at the window by stable widget name —
                        cues over plain data, rendered with generic GTK
lib/studio_secrets.bas  STU-10 credential storage: AES-GCM, key from the
                        environment and NEVER written to disk
lib/studio_providers.bas STU-10 selectable providers; credential from the secret
                        store first, environment second, and it says which
lib/studio_agent.bas    the agent over llm.bas — orientation (STU-6) and acting
                        (STU-10); transport injectable, so the whole path is
                        testable with no network
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
- Three things arm before they fire: Delete, Close, and Save over a CONFLICT —
  saving a document whose file changed underneath overwrites whoever made that
  change, which is the same class of loss as deleting. An ordinary save is one
  click; nothing is at stake in it. Each arm is keyed to the *thing* (a path for
  Delete, a document id for the other two) rather than to a flag, so moving the
  selection between the two clicks re-arms on the new row instead of deleting
  it.
  `redraw` expires an arm the last action did not renew (`studio_ui.arm_kind`),
  which stops one outliving an unrelated click. Do not reintroduce a confirmation
  dialog: it would be an async surface no test can press, which is the same
  reason names come from a header field.
- `doc.external` has exactly three values: none | changed | deleted. Do not add a
  fourth for a case that is one of those; the tab markers and the checkpoint
  policy both read it.
- Every outcome gets a status line via `studio_ui.action_notice`. A refusal that
  says nothing is indistinguishable from a dead button, which is how the whole
  window felt before STU-2B.
- A run's materialized prefix ends with a VARIABLE EPILOGUE (STU-4C) that reports
  what the target section left behind, via `reflect`. It must be injected before
  any appended `end program`: code after `end program` does not execute, so an
  epilogue at the end of the file would report nothing, silently, and only for
  program-body sections. `reflect.inspect` is shallow, so a section that built a
  huge array reports its count and a BOUNDED sample of it — the row loop stops at
  the limit rather than walking the container, which is what keeps a preview from
  becoming a copy. The capture is persisted as a
  fifth `studio_results` capture (schema 2); a version-1 store still loads, and
  `capture_bytes` answers 0 for a capture a stored result does not have, because
  a caller comparing `unknown > 0` raises.
  A capture is `encode`d by the child and read back with `try_decode`, so it
  carries whatever the user's program computed — including a non-finite number,
  which `number("1e308") * 10` produces with no diagnostic. **Below gBASIC
  0.1.0-rc7 `decode` refused the `inf`/`nan` that its own `encode` wrote**, so
  such a capture came back `ok: false` and the inspector blamed the file rather
  than the value. Fixed in the language (gBASIC DOGFOOD item 2), not here;
  nothing in Studio changed, and the floor is still rc3 — a capture holding an
  overflowed number is simply unreadable on rc3 through rc6.
- A run lives in `app.exec` — beside `app.dm`, live state the shutdown pipeline
  does not write, because a half-finished child process is not something to
  restore into. The section and the SOURCE are fixed when Run is pressed and kept
  for the whole run: a result is a statement about the text that ran, not about
  what has been typed since.
- Polling calls `studio_shell.refresh_run`, not `refresh`. A full redraw rebuilds
  the browser pane, and doing that sixteen times a second would fight the user
  for their own file tree; only the FINAL tick does a full redraw, because that
  is when the status line and the results pane change. `on_run_poll` returns the
  `active` flag, so the timer removes itself the moment the run ends.
- `view_for` RESTORES a document's section state from the workspace
  (`studio_sections.restore_from`) rather than creating one, and folds it back on
  every change. Section ids are minted from a per-document counter that advances
  as sections are re-matched across edits, so a state built from scratch on the
  next launch renumbers everything — and every result recorded under the old ids
  belongs to no section that exists. STU-3 built the anchors for exactly this and
  nothing was calling them.
- The panes read through `studio_ui.view_for`, which CACHES the section outline on
  `app.view` — so `refresh_run` and `refresh` return the app, and a caller that
  drops it re-parses the document on every render, at cursor-move rate. Cache
  invalidation is on document id AND content, checked separately: blanking the
  cached source to mark it stale silently fails for an empty document.
- Typing and caret moves take `pane_redraw`, not `redraw`. `sync_buffers` returns
  `moved`, which is true only when a document's dirty state actually changed —
  the one thing typing alters that needs a full redraw (the tab marker).
- `studio_ui.run_line` / `prefix_text` / `target_text` live in studio_ui, not the
  shell, so the headless suite can assert what a run reports. `studio_shell`
  keeps the old names as delegates only because the STU-4/5A display goldens
  print through them.
- `materialize_text` splices a LIST of insertions in offset order — the boundary
  marker, the before-scope dump, and any branch bindings — and the line map falls
  out of the same pass. A section's `end_offset` stops at its last statement, not
  after the newline, so the final chunk must be newline-closed BEFORE it is
  measured or the target's own last line gets no map segment and its diagnostics
  come back unmapped.
- A viewer sidecar is DECLARATIVE. `studio_viewers` reads JSON and never runs
  anything; `viewers_declarative` greps for that. If the registry ever grew a way
  to execute what a library ships, a viewer file would be arbitrary code with
  Studio's privileges and the core language would have acquired display semantics
  by the back door (§6.2).
- Viewer matching is over the DESCRIPTOR, never a value — Studio holds no values,
  because the child exited. Extraction happens in the child instead:
  `studio_viewers.capture_rules` is compiled into the variable epilogue by
  `studio_session._detail_fn`, which writes gBASIC that calls `has` and
  `reflect.field`. Field names go in through `quote`, not hand-written quotation
  marks, or a name carrying a quote would end the literal early and turn
  declarative metadata into generated code.
- A registered viewer that matches on shape but finds no `detail` renders NOTHING
  and falls back to the structural preview. Every result recorded before the
  viewer existed is in that state; it is normal, not a fault.
- A table opened without a fetch is a SAMPLE, and `studio_table.caption` is where
  it admits that. Do not caption a grid with a total it cannot show.
- Fetch goes through `studio_ui.run_section`, the same function the Run button
  uses, with one extra insertion. Do not add a second run path: an export taken
  by a differently-bound run would be a table of numbers that never coexisted.
- The DataGrid virtualization test runs the SAME interaction at two table sizes
  and requires byte-identical output. "Few cells bound" is not a claim; "the
  number does not move when the table grows tenfold" is. Reset
  `datagrid.accesses()` BEFORE building the widget tree — GtkColumnView binds
  when the view is first given a size, not at `present()`.
- `_DATAGRID` and `_STUDIO_TABLE` are program globals assigned AFTER the display
  loads in `app/studio.bas`. `load` is not hoisted, and `datagrid` pulls in `gi`,
  which the headless modes must never touch.
- An overlay is a SECTION-SCOPED FULL-TEXT REPLACEMENT (design Q5, decided in
  STU-9), not a textual diff and not an AST patch. That choice is what makes
  conflict a hash comparison (`base_fp` vs the section's fingerprint now) instead
  of a context-matching heuristic — and a heuristic that guesses wrong silently
  misapplies an edit, which §9.3 exists to forbid. The cost: an overlay replaces
  WHOLE sections, so section granularity is conflict granularity.
- `base_fp` is stamped when the overlay is BEGUN and never re-stamped on save.
  Moving it on save would silently resolve a conflict the user was never told
  about. Only `rebase` moves it, deliberately, and reports how many it moved.
- Rebase is NOT a merge and must not be described as one. An overlay is a whole
  section, so accepting it SHADOWS the canonical change; `overlay_diff` is where
  the shadowed text stays visible.
- Promote is refused while ANY edit conflicts. A partial promote writes half an
  experiment into the file and leaves the other half in metadata — a state
  nothing later can describe. Promote marks the document dirty rather than
  writing to disk: it is an edit, and the user saves edits.
- An overlay branch's results are judged against `studio_ui.branch_sections` —
  the projection's outline — not the canonical one. Judging them against
  canonical marks every result stale the moment an overlay exists, which is noise
  dressed as honesty.
- The overlay has its OWN editor in the branch pane. It cannot share the source
  editor: that buffer shows the canonical document, and a window displaying
  non-canonical text as the file is the one thing §2.1 forbids.
- If an overlay changes a section so its id no longer re-matches (renaming the
  function it replaces), the run REFUSES. Running the nearest thing would run
  different code under the id the results are filed against.
- STU-6's `agent_readonly` is GONE, replaced deliberately by three properties
  (`agent_tiered`, `agent_parity`, `agent_one_gate`). Do not re-add a write tool
  outside `act_registry`, and do not let `_perform` reach past `studio_ui`: parity
  with the window is what makes "the agent can do what the user can do"
  structural rather than aspirational.
- Tiers are assigned by REVERSIBILITY, not by how dangerous a name sounds.
  Editing code is `local` (unsaved until Save); deleting is `external` (the §8.3
  non-rewindable set).
- Permission scopes NARROW and never widen. If the innermost scope simply won, a
  project config could grant the agent more authority than the user set globally
  — and that file is one somebody else may have written. An unset scope has NO
  opinion; it does not vote the default.
- A confirmation token hashes the tool name AND its arguments. Confirming
  "delete a.bas" must never authorize "delete b.bas".
- REFUSED acts are audited too. A log of successes is a record of what worked,
  not of what was attempted, and it would make an agent probing at a denied tier
  invisible. Reads are not logged, or they would bury the acts.
- There is NO in-loop confirmation dialog, deliberately: confirmation is granted
  by policy. A dialog is an async surface no test can press — the same reason
  names come from a header field.
- The secret store's key comes from the environment and is NEVER written to disk;
  `secrets_no_key_file` greps for that. Without libcrypto the store REFUSES
  rather than falling back to plaintext.
- `agent_widgets` keeps `studio_teaching.registry()` and `studio_shell.teachable()`
  the same set. A registry entry the shell cannot resolve is a teaching request
  that reports success and draws nothing.
- Git is found by `process.which`, NEVER by running it. `process.run` raises on
  a missing executable and gBASIC cannot catch a raise, so "is git installed?"
  asked by trying would crash the window of everyone who does not have it. This
  is why git can be optional at all — and why **Studio requires gBASIC
  0.1.0-rc3**: `which` cannot be probed around on older builds (they lack
  `has_builtin` too; you cannot probe for the prober), so the floor is stated
  rather than worked around.
- Git reads happen on the FULL redraw, never in `refresh_run`. That is the run
  poller at sixteen ticks a second, and forking `git status` at that rate is a
  worse version of the mistake refresh_run exists to avoid. Detection is cached
  on the app (`gitstate`), keyed on the project path: whether a directory is a
  repository does not change while someone types.
- Outside a repository `git_label` is the EMPTY STRING, not "git: none".
  Mentioning git to someone who does not use it, on every click, is what §18
  asks Studio not to do.
- `git_not_branches` asserts that `studio_branches` and `studio_overlays` never
  spawn a process. Stated that way on purpose: the first version grepped for the
  word "branch" beside a comma and fired on the overlay's own list of record
  keys. A tripwire that trips on its own vocabulary is one someone deletes.
- The agent has NO tool that reaches a remote. Not a gated one — none. That is a
  stronger statement than gating it, and `git_commit` is `local` because a commit
  stays in this repository and someone who knows git can undo it.
- A Studio branch is NOT a Git branch — not stored, surfaced or created as one
  (design §2.3), and `branches_not_git` greps the source to keep it that way.
  A state-only branch differs from its siblings ONLY by the bindings it injects;
  the source is identical in every branch, which is what makes it cheap enough to
  be served by the replay model with no overlay and no temp file.
- Staleness is SURFACED, never acted on: a branch whose shared ancestry changed
  is flagged and stays selected, and re-anchoring is a separate explicit act.
  Studio never silently attaches stale execution state to changed source (§9.3).
- The agent surface WAS read-only structurally (STU-6). STU-10 ended that on
  purpose, so the claim is now narrower and still enforced: `studio_tools.invoke`
  is the sole dispatch authority — it refuses a name that is not in the registry,
  decides permission BEFORE dispatching, and nothing evaluates model text. The
  read path (`call`) refuses an act outright. `run_studio_agent.sh` greps for all
  of it.
- A tool's callable cannot close over the app (gBASIC functions do not close over
  state), so `app/studio.bas` carries one two-line wrapper per tool that reads
  the global and calls the dispatcher — the same adapter rule as a signal
  handler, for the same reason.
- **`wrap = true` DOES NOT MAKE A LABEL WRAP.** A wrapping label still reports
  its natural width as the whole text on one line, and a GtkScrolledWindow asks
  for natural size — so it hands the label that width and the text runs off the
  edge. `_wrapped` therefore also sets `max_width_chars`, which caps the NATURAL
  width and nothing else (given more room the label still uses it). Every heading
  in the right-hand pane was cut off mid-word for three phases because of this,
  and no golden could see it: the asserted text is identical whether the widget
  wrapped it or clipped it.
- The right-hand and output scrollers are `studio_shell._vscroll` — vertical
  policy only. A horizontal policy of AUTOMATIC is what lets a child take its
  natural width and overflow.
- A horizontal row of buttons has a hard width budget: the right column is about
  320px. Six buttons do not fit; the overlay strip is two rows of three. And a
  button label must not collide with an existing one — shortening "Save overlay"
  to "Save" gave the window two Saves doing different things to the same
  document.
- The browser hides dotfiles (`studio_ui.hidden_entry`). `.git` is not merely
  noise: it is expandable, and `filetree` scans an expanded directory eagerly, so
  one click would walk every loose object in a real repository.
- **LOOK AT THE WINDOW.** Every defect in this section was found by taking a
  screenshot and reading it, in about a minute, with 163 tests passing. Display
  goldens assert TEXT; they cannot see alignment, wrapping, clipping, visibility,
  or a control that is off-screen.
- Labels: `studio_shell._left` aligns, `_wrapped` also wraps, `_mono` also
  selects and monospaces. `gtk.label` CENTRES, which is right for a title and
  wrong for a browser row whose indentation encodes depth, for program output,
  and for a table. Wrapping belongs only on labels that own a whole row — the run
  strip is a horizontal box, and wrapping its labels turned each into a narrow
  column of syllables. NONE of this is visible to a golden: the text is identical
  either way, which is how it survived five phases.
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
