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

An empty home renders `(no workspace open)`; **New Project** opens a window that
asks for a name, a location and which of `main.bas` / `README.md` /
`.gstudio.json` / a git repository to make (only `main.bas` is ticked), and
Create builds the project directory — under `<home>/projects/` unless the
Location says otherwise. **New File** adds more. Closing the gui window runs `studio.persist`, so the home is written on
exit — unsaved *buffers* are not (there is no draft store; the exit path warns on
stderr). `./studio build <home>` still writes a canned workspace headlessly if
you want content without clicking.

## Tests

```sh
tests/run_studio.sh            # 183 cases, headless; honours GBASIC / GBASIC_STDLIB
tests/run_studio_agent.sh      # 29 cases, headless AND offline (scripted transport)
```

Golden-file based: a driver plus a `.out` of expected stdout, compared
byte-for-byte, so update the `.out` when output changes *intentionally* and say
so. The suite builds the sibling gBASIC first when `GBASIC` points into a source
tree, so an interpreter change is what gets tested rather than a stale binary.
Display tiers (`sections_gui`, `sessions_gui`, `results_gui`, `ui_gui`,
`ui_gui_cold`, `ui_gui_new`, `ui_gui_name`, `ui_gui_solo`, `ui_gui_run`,
`ui_gui_cursor`, `ui_gui_open`, `ui_gui_newproj`, `ui_gui_layout`,
`ui_gui_ctx`, `ui_gui_branch`, `ui_gui_table`, `ui_gui_overlay`, `ui_gui_teach`, `ui_gui_git`) SKIP cleanly
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
lib/studio_sections.bas execution sections with stable ids — over source_outline
                        for gBASIC, over studio_sql for a .sql document; the
                        id matching below the candidates is the same either way
lib/studio_sql.bas      STU-14 where one SQL statement ends and the next
                        begins: a SCANNER, not a parser, plus the two shallow
                        facts (verb, object name) that section identity and the
                        destructive-statement arm need
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
lib/studio_projects.bas  ONE project's state in a file of its own —
                        `<home>/state/<key>.json`: section anchors, the branch
                        tree, the overlays. Keyed by the project's IDENTITY
                        through the shared `studio_model.path_key`
lib/studio_projfile.bas  the project's OWN file, `.gstudio.json` — DECLARED,
                        small, hand-edited, committed, and IN the project
                        directory: a stable id, an ignore list, and which
                        gBASIC this project runs under. The exact opposite of
                        studio_projects, which is why they are two libraries
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
lib/studio_style.bas    the ONE stylesheet, the shared CSS provider, and the
                        spacing unit. Classes go on through `style.apply`, which
                        attaches the provider at the same time
share/                  the .desktop entry, the hicolor icons, and the licence
                        texts New Project can write (see share/README and
                        share/licenses/README)
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
- **A project's state lives in its own file**, `<home>/state/<key>.json`, not in
  the session record. One record holding every project's anchors at once grew
  with every project ever opened and never shrank, and put the state that is
  obviously about ONE project somewhere it could not be found, inspected or
  deleted on its own. It is NOT in the project directory: this is derived,
  personal and sometimes large — anchors that only mean anything beside this
  home's results, a branch tree that is an experiment in progress.
- `studio_model.path_key` is shared by `studio_projects` (keyed on a project
  path) and `studio_results` (keyed on a document path). Two copies of a hash
  are two things that can drift into producing different filenames for one
  input; `studio_results._key` now delegates, and the implementation moved
  verbatim so existing stores keep their names.
- The state is cached on `app.pstate`, flushed by `studio.persist` AND on a
  project switch — `project_state` writes the outgoing one on its way out,
  because a switch is exactly when those anchors would otherwise be dropped on
  the floor. It is deliberately NOT written per mutation: the section fold runs
  at cursor-move rate. Same in-memory-until-exit behaviour it had inside the
  workspace; only the file changed.
- `studio_projects.key_for(path, stable_id)` takes the project's IDENTITY, and
  never `proj-N`. That id is minted from a per-workspace counter, so closing a
  project and reopening it mints a different one and orphans the state — the
  same defect keying anchors by `doc-N` produced. The stable id out of
  `.gstudio.json` survives the project MOVING; the path is the fallback when
  there is no project file, and survives everything but a move. The id still
  goes through `path_key` rather than being used raw as a filename: it is
  hand-editable text, and a `/` in it would otherwise choose where the state
  lands.
- **Everything below `key_for` takes the KEY, not the path.** `studio_projects`
  does not know what a directory is; `studio_ui.project_state` is the single
  place that resolves identity, because it is the one caller holding both the
  path and the project file. The store compares keys and never interprets them.
- **Adding a project file CHANGES the key, so the anchors have to be carried.**
  `studio_ui.add_project_file` re-files the state under the new key
  (`_refile_state`) — from memory when the project is the loaded one, from the
  old file otherwise, and not at all when there is nothing to carry. Without it
  a button whose whole promise is "this changes nothing about your code" would
  silently renumber every section in the project: `ui_projfile` was written to
  fail first and did, `sec-3,sec-1,sec-2` coming back as `sec-1,sec-2,sec-3` —
  the STU-3 misattribution re-entered through a new door. The old state file is
  LEFT behind, like the workspace migration, because until the next save it is
  the only copy and there is no undo for that button.
- A document under NO project (opened by path, nothing adopted) has no key. Its
  state lives in memory and is not persisted, rather than being invented a home.
- **`.gstudio.json` — Studio never creates it except when explicitly asked.**
  Not on Open Folder, not on New Project unless the box is ticked, not on save,
  not on exit, not on first run. One button (`Project File`), one function
  (`studio_ui.add_project_file`), one writer (`studio_projfile.create`). That
  is the whole answer to "other IDEs put their own metadata in my project": a
  file that exists only because somebody pressed a button cannot arrive
  uninvited, and one that arrives any other way has broken the promise however
  small it is.
- **Open Folder never writes anything, ever.** It READS the project file —
  `spec.name` is how two checkouts both called `src` get different names in the
  browser — and that is all. The name lands when the folder is OPENED, so
  editing it in the file shows up the next time you open the project rather
  than mid-session.
- **It is the one dotfile the browser shows** (`studio_ui.hidden_entry`). Hiding
  a file you were asked to consent to is how it becomes uninvited metadata
  again, and it is meant to be hand-edited, which a browser that will not show
  it makes needlessly awkward. `.hidden` is in the `mkproj_ui` fixture so the
  assertion is about `.gstudio.json` and not about dotfiles generally.
- `create` REFUSES over an existing file rather than merging into it. Studio
  does not know what else a hand-edited file holds, and a rewrite that dropped
  somebody's key would be the same complaint arriving by the back door.
- What it writes is MINIMAL: the id, the name, an empty `ignore`. `interpreter`
  and `stdlib` are OMITTED rather than written empty — an empty string in an
  interpreter field reads as a claim ("no interpreter"), not as an absence.
- The id is `gsp-<hash of where>-<when>`, minted once and never derived again.
  Opaque on purpose: an id you can read as a path invites the reading that it
  goes stale when the project moves, which is the one thing it exists not to do.
  `mint_id` takes the stamp as a PARAMETER (the `clock_fixed` seam) so a golden
  can hold an id's shape (`studio_projfile._shape` → `gsp-#-#`) without holding
  the second it was minted in.
- **A newer `schema_version` means read NOTHING out of it**, not "read the
  fields we still recognise". Half-honouring a file that means something else
  now is worse than not honouring it; the state store takes the same line.
  `present` (the file is there) and `status` (Studio can use it) are separate
  for exactly this: a corrupt or future file is present, so "add one" still
  refuses, and unusable, so nothing is read out of it.
- Every field is guarded by type (`_string`, `_strings`). It is hand-edited, so
  `"ignore": "build"` — a string where an array belongs — will happen, and it
  must not raise inside a redraw.
- The ignore list matches a NAME, at any depth, in two forms and no more: an
  exact name, and a `*` prefix matching a suffix (`*.o`). The browser filters
  `filetree.flatten` rows by name, so a path-anchored rule would be a second
  mechanism pretending to be the same one — and a pattern language nobody can
  predict the behaviour of is worse than one that plainly does two things.
- **The project file is NOT cached.** `nav_rows` and `project_state` read it
  where they need it. `nav_rows` already calls `filetree.scan` on every redraw,
  so one small file is inside the noise, and no cache means hand-editing
  `.gstudio.json` takes effect on the next redraw with no invalidation rule to
  get wrong. Contrast `gitstate`, which is cached because detection FORKS.
- The two pin fields are named after the two things `./studio` itself sets:
  `interpreter` is the binary, `gbasic_path` is GBASIC_PATH for the child.
  Calling the second `stdlib` would have been a small lie — a project with its
  own `lib/` needs both entries on that path, and that is the more useful thing
  to be able to say.
- A pinned `gbasic_path` REPLACES `GBASIC_PATH` in the child rather than
  prepending to it. A pin the ambient environment can reach around is not a pin — and the
  child otherwise inherits Studio's own `lib:`, putting THIS repository's
  libraries on the search path of the user's program. It goes through
  `process.start`'s `env`, which MERGES over the inherited environment, so
  nothing else about the child's world changes.
- `session.env` is `nothing` and not `{}` when nothing is pinned:
  `process.start` validates the `env` option whenever the key is PRESENT, and
  `nothing` is not a record, so passing it always would raise on every run that
  pins nothing — which is nearly all of them. `_launch` builds the options
  record and adds `env` only when there is one.
- `studio_projfile.read_spec`, not `read`: gBASIC has a `read` builtin, and a
  library function shadowing one earns a note on STDERR at every load. Several
  golden tiers capture stderr, so that is eleven failing tests and not a style
  question — which is exactly how `tool_call` was found.

### The New Project window

- **New Project OPENS A WINDOW now; it no longer creates a project outright.**
  `studio_ui.new_project` (mint a name, make a directory) is still there and
  still tested, because the cold-start path is the one thing in this
  application that cannot be allowed to break. But the button goes through
  `studio_shell.new_project_window`, which is a window Studio BUILDS — not a
  `GtkAlertDialog`, for the same reason names come from a header field and
  confirmations are two clicks: an async surface is one no test can press.
  Every control in it is an ordinary widget whose value can be SET, so
  `ui_gui_newproj` fills the form and clicks Create for real.
- The window holds NO decisions. It reads an options record in
  (`studio_ui.default_options`) and hands one back out
  (`studio_shell.new_project_options`, which is the whole of the
  widget-to-value read). What those options MEAN is `studio_ui.project_plan`,
  headless, and `ui_newproj2` asserts every box with no widget in sight.
- **`project_plan` decides, `create_project` acts, and a refused plan has
  touched nothing.** The refusals are named — `no-name`, `invalid`, `no-path`,
  `exists`, `no-author`, `no-license` — and each reaches the status line by
  name, so a New Project that will not go through says which field to change.
  A refusal also keeps the WINDOW open with what was typed still in it: the
  field to fix is in that window, and closing it to put the reason in a status
  line behind it would hide both.
- **Only `main.bas` is ticked by default.** A project with nothing in it scans
  to zero browser rows and there is nowhere to click — the STU-2B dead end,
  now closed from the other end. Everything else is OFF, and `.gstudio.json`
  most deliberately: Studio ticking that box by default would be Studio putting
  its own file in your directory because you did not look, which is the exact
  behaviour that file exists to avoid. **A box you had to untick is not
  consent.**
- The checkbox goes through `studio_projfile.create`, the same single writer
  the button uses, so "Studio never creates `.gstudio.json` except when asked"
  stays true of a checkbox as well as of a button.
- `create_project` answers `project-created`, NOT the `created` that New File
  answers with. That notice reduces its detail to one token, which for a
  project is the minted id — "created proj-1", about a thing the user just
  named. This detail is the name and the list of what was actually written, and
  it is reported whole, because a project name has spaces in it.
- **git being absent is not this project's problem.** The directory and its
  files are already written when `git init` is tried; a missing git is reported
  and the project stands. Refusing to make a project over an optional tool
  would be the §18 complaint again.
- **Studio does not AUTHOR a licence.** `share/licenses/<id>.txt` holds the
  text; `studio_ui.license_text` copies it and fills the two SPDX placeholders.
  `share/licenses/README.md` records where every one of them came from, because
  "I wrote out the GPL from memory" is not a provenance. An id whose file is
  missing is REFUSED (`no-license`) rather than written empty — a LICENSE file
  that is not the licence is worse than no LICENSE file.
- A template whose holder would come out blank is refused too (`no-author`).
  A licence naming nobody grants nothing, and the window has the field right
  there. `studio_ui.default_author` fills it from `git config user.name` — the
  one place on a developer's machine holding a real name rather than a login —
  through `studio_git`, which finds git with `process.which` and never by
  running it. One spawn when the window OPENS, not on a redraw.
- `share/` is found through `GBASIC_STUDIO_SHARE`, exported by `./studio` and
  by the test runner, like `GBASIC_STUDIO_VIEWERS`. An installed copy keeps
  `share/` somewhere else and Studio's own working directory is never the
  answer. Without it the licence cases would exercise the "no text shipped"
  refusal instead of the licence.
- `Gtk.DropDown` over a `Gtk.StringList`, both reachable through `gi.new` and
  both driven by ordinary instance methods (`set_selected`, `get_selected`).
  `Gtk.DropDown.new_from_strings` is a class static the bridge cannot call —
  the same gap as `Gtk.Settings.get_default`. Measured before the window was
  written, not assumed.
- **`on` is a reserved word.** `function _check(label, on)` is a parse error,
  and a parse error in `studio_shell.bas` is a window that will not open at
  all. The parameter is `ticked`.
- The window is built ONCE and kept on `G.newproj_win`; a second click on New
  Project presents the one that is already open. Minting a second set of
  widgets over the same handlers is the doubling `ui_gui_solo` exists to catch
  one level up.
- Three display tiers got a project from one click and now need two
  (`click_create_project`). `stu2c_step` keeps its ORIGINAL phase numbering
  against a `ph = G.phase - 1`, rather than renumbering a flow whose phase
  numbers appear nowhere in its golden.

### The browser pane (STU-13)

- **A deep tree CLIPPED a file name mid-word, with no ellipsis and no
  horizontal scrollbar.** Measured: five levels in a 260px pane cut
  `interpolated_string_expression_parser_regression_tests.bas` off at
  `interpolated_string_expression_pa` — nothing said the name was truncated
  and nothing could reach the rest of it. Found by taking a screenshot, like
  every other defect in this section; no golden can see it, because the
  asserted label is the whole string either way.
- The rows ellipsize **MIDDLE**, not END. END would signal the truncation and
  still eat `.bas`, which is the part that says what the file IS.
- **`_fill`, not `_left`, on a browser row.** `halign = START` hands a label
  its NATURAL width, and a label allowed its natural width never ellipsizes —
  it runs off the edge, which is the bug. The label has to be GIVEN a width for
  Pango to have anything to elide against. The nav scroller is `_vscroll` for
  the same reason: a horizontal policy of AUTOMATIC lets a child take its
  natural width instead of the width it is given.
- **Indentation is a MARGIN now, not spaces in the label.** `studio_ui._row`
  carries `name`, `depth` and `glyph`, and `studio_ui.row_label` derives the
  flat string from them — in ONE place, because the goldens address rows by
  that string and two independent renderings of one thing is the
  `projects[].documents` mistake. Nothing moved: 172 cases passed unchanged
  across that refactor, which is the evidence that `row_label` reproduces what
  it replaced.
- `studio_style.indent()` is **8**, not `unit() * 2`. Measured: twelve pixels
  is visibly wider than the old two-spaces-in-a-proportional-font, wide enough
  that two names started ellipsizing which had fitted before. Making the
  indentation exact must not cost the names the width it was meant to save
  them.
- Every row carries its full path as a TOOLTIP, which is where an elided name
  can be read in full.
- **The layout you set is now remembered.** `session.window` had been READ at
  startup since STU-0 and never written back, and the three divider positions
  were literals in `studio_shell.build` — so a resized window and a dragged
  divider were both forgotten on every launch. `studio_model.pane_at` guards
  every stored value (missing key, not a record, not a number, absurdly small)
  because this is JSON a user can edit and a crash can truncate, and a divider
  read as 0 is a pane collapsed to its floor on startup with nothing saying why.
- **Geometry is captured on `close-request`, not after the loop returns.** The
  GTK loop returns only once the window is GONE, so the exit path cannot ask it
  how big it was — which is why that field was never written. Returning false
  from the handler lets the close proceed. `stu2c_step` now calls
  `window.close()` rather than `app_ref.quit()`, because that tier's whole
  claim is that closing the window saves the session and `quit()` skips
  `close-request` entirely.
- The exact divider numbers are NOT in a golden. A GtkPaned clamps its position
  against the allocation and under Wayland the compositor decides that —
  measured, `rsplit = 700` came back 572 on this desktop. `ui_panes` asserts the
  arithmetic headlessly where it is pure; `ui_gui_layout` asserts only what
  needs a real window: that closing it writes the layout down at all.

### The browser's right-click menu (STU-13)

- A `Gtk.Popover` holding a box of ordinary `Gtk.Button`s, **not** a
  `Gtk.PopoverMenu`. A PopoverMenu is driven by a `GMenuModel` built through
  class statics the bridge cannot reach, and plain buttons are also what makes
  the menu testable — `ui_gui_ctx` presses one. `gi.new("Gdk.Rectangle")` fails
  like `Gdk.RGBA`, so `set_pointing_to` is out and the popover parents to the
  ROW, which points at the thing it is about anyway.
- Built ONCE holding every item there is; `studio_shell.context_for` shows the
  ones `studio_ui.context_actions` names and hides the rest. An empty list means
  NO menu: a popover with nothing in it reads as a control that failed.
- **Every item dispatches to the same `studio_ui` function the toolbar calls.**
  That is what keeps Delete ARMED from the menu — a second implementation would
  quietly undo the two-click rule on the same file, from a different control.
- **Rename does not rename.** It fills the header name field and focuses it,
  because that field is where a name comes from and a second route to one is two
  places to get naming rules wrong. The item says "Rename…" for that reason.
- Right-click SELECTS (`studio_ui.select_row`) and does not activate: on a file
  `activate_row` would OPEN it, which is a menu acting before it was asked.
  Project rows are the exception and DO activate, because both of their items
  are about a project and the one just pointed at is the one meant.
- **`redraw` takes the popover down first.** It is parented to a browser row and
  a redraw rebuilds those; a popover whose parent is destroyed is a GTK critical,
  which `G_DEBUG=fatal-criticals` turns into a nonzero exit.
- `close_project` is NOT armed, unlike Delete and Close: nothing is lost. The
  directory is untouched, the state file stays on disk under its own key, and
  Open Folder puts it back with its anchors. It REFUSES while a document under
  it is dirty, naming the file — closing the project closes those tabs and
  Studio keeps no drafts. It writes the project's anchors before the project
  stops being findable, or `project_path_for` would answer "" and the cache
  would flush to nowhere. Nothing is logged: `studio_history.kinds()` is a
  closed vocabulary and this is not in it.
- **The gesture is held on `G` as well as passed to `add_controller`.** A
  controller nothing else holds is one more object that can go away under a live
  window — the same reason `_STUDIO_STYLE` is a global.
- **`row.get_allocation()` RAISES through the bridge**, so a display tier cannot
  ask a row where it is. `ui_gui_ctx` finds the y by scanning `get_row_at_y`
  until it answers the wanted index, which also exercises that lookup for real.
  Pixel arithmetic is not a substitute: `get_height()` reported 19 against an
  actual pitch of ~20, so `idx * h` opened the menu on the wrong file.
- Menu items are `set_has_frame(false)` with `xalign = 0` on their labels.
  Studio's own `flat` class is prefixed and means something else (it stops a
  listbox painting a view background); without the GTK 4 call the menu was a
  column of framed, centred buttons — looked at, and that is what it was.
- A `Gtk.Popover` autohides, so it DISMISSES when a screenshot tool takes focus,
  and on Wayland it is a separate surface that a window-only capture does not
  include at all. Both are why looking at this one needed a full-screen grab.

### What the browser LOOKS like, and which project you are in

- The glyphs are `●` active project, `○` inactive, `▾` expanded, `▸`
  collapsed, and a space for a file — `studio_ui.glyph_*`, one answer each.
  Filled and hollow for the active project rather than an asterisk and two
  blanks: "which of these am I in" is answered by a shape being solid, and a
  blank is not a shape. They are geometric shapes from the Unicode block every
  mainstream UI font carries; this is NOT the `dialog-error` situation, where an
  icon THEME can simply lack a name.
- Each glyph is ONE character and the gap after it is LAYOUT: box spacing in the
  widget, a space in `row_label`. Two characters of a proportional font is a
  column nobody measured, and it cost ~8px of name width for nothing.
- A browser row is a BOX of two labels, not one: a glyph label pinned to one
  character (`width_chars` and `max_width_chars` together) and the ellipsizing
  name. Inside one label the glyph was proportional, so a directory's name and
  a file's name beside it began at different places.
- **The notebook follows the browser.** The browser shows one project at a time
  and the tab row did not, so switching projects changed the tree and left you
  looking at the previous project's files, with nothing in the tab row saying
  which project any of them came from. `studio_ui.doc_in_view` filters
  `tab_rows`; a document under NO project is always shown, because there is no
  project it could be waiting behind.
- **Nothing is closed by that filtering.** A hidden document keeps its unsaved
  text and comes straight back when its project does — `ui_projtabs` asserts
  exactly that, because "your edits are still there" is the whole reason hiding
  is acceptable at all.
- `studio_ui.focus_visible_doc` runs at EVERY change of active project (the five
  `set_active_project` call sites). Without it the editor, the run strip and the
  results go on showing a document whose tab is not there — the same
  selected-versus-displayed mismatch the browser had.
- `studio_docs.set_active(dm, "")` CLEARS the active document. It has to be
  explicit: an unknown id is ignored on purpose (a stale id from a closed tab
  must not blank the editor), and "no document" is not an unknown id.
- The status line counts what is hidden (`studio_ui.hidden_docs`). Work that is
  open and invisible has to be counted somewhere, or the unsaved-changes warning
  on exit is about documents the user has no memory of leaving open.
- **A right-click does NOT change the active project.** Both project items name
  the row they came from — `add_project_file(app, project_id)` with "" meaning
  the active one, for the toolbar button. The first version activated the row
  first, which switched projects silently and only became visible when something
  else redrew and the tree jumped.
- `studio_projfile.create` answers `project-no-folder`, not `no-project`, for a
  project with no directory. `no-project` made the status line say "open a
  project first" about a project that was plainly open — a refusal whose
  wording contradicts what the user can see is indistinguishable from the button
  doing nothing.
- `close_project` answers `project-dirty`, not the `dirty` Delete uses. That one
  says "save main.bas first", which is true and reads as a remark about the file
  rather than as the reason a project would not close; this one names both.
- **A row added and redrawn in the SAME callback has no allocation yet**, so
  `get_row_at_y` cannot find it — the loop has to be given back for GTK to lay
  it out. Cost an hour of looking for a product bug that was a test artefact.
- **An expanded directory with nothing to show SAYS SO.** Opening an empty
  folder changed the arrow and nothing else, and the rows below it — its
  SIBLINGS, which sort after it because directories come first — stayed
  exactly where they were. Reported as a control that does not work, and it is
  indistinguishable from one. `studio_ui._empty_note` looks ahead in the
  FLATTENED list at the run of entries deeper than the directory and answers
  "(empty)", "(hidden files only)", or "" when something survives the filter.
- The two notes are different FACTS about the directory and are told apart on
  purpose: "(empty)" about a folder holding six dotfiles would be a statement
  Studio cannot support. `hidden_entry` and the project's ignore list are the
  two ways a child can exist and not show.
- The note is an `info` row — not clickable (`activate_row` answers "none"), no
  context menu (`context_actions` answers []), and `dim` in the shell so it
  reads as a remark rather than as one more thing to try clicking. That styling
  is keyed on kind AND depth, because the workspace header is an info row too
  and keeps its weight.

### SQL as a document type (STU-14, in progress)

- **`byte_slice(s, at, count)` takes a COUNT, not an end offset.** Documented,
  and `source_outline_design.md` shows the idiom
  (`byte_slice(text, a, b - a)`), but every offset in this codebase is
  half-open `[start, end)` and passing `end` straight through reads as correct
  and returns too much. It cost an hour: the statement boundaries were right
  and the extracted TEXT ran to the end of the file. A first test that sliced
  `(s, 6, 11)` from an 11-byte string could not tell the two readings apart,
  which is its own lesson about what a probe proves.
- **The SQL splitter is a scanner, not a parser**, and that is the whole
  design. It knows the places a `;` is not a terminator — inside a string, a
  line comment, a NESTED block comment (PostgreSQL nests them), a quoted
  identifier in any of the three spellings, or a dollar-quoted body — and it
  knows nothing else. A parser here would have to be three parsers, one per
  engine, and would go wrong on the first dialect feature it had not met;
  a scanner is wrong only where the QUOTING rules differ, and they barely do.
- `$1` must NOT open a dollar quote, or a single parameter placeholder swallows
  the rest of the file into one statement. The tag has to match.
- **A `.sql` document reuses the SAME id matcher a gBASIC one does.**
  `studio_sections.attach` was split out of `_apply` so candidates do not have
  to come from `source_outline`; everything downstream of them is about section
  IDENTITY and knows nothing about gBASIC. Two identical statements come back
  `ambiguous` rather than guessed at, inherited for free.
- A SQL statement has no name the way a function does, so `name_of` reads one
  off the `<verb> <noun> <name>` DDL shapes (skipping `if not exists`,
  `or replace`) purely to give tier-2 matching something to hold. That is what
  keeps a result attached to `create table customers` after its columns are
  rewritten — measured: it keeps `sec-1` while an inserted statement above it
  takes `sec-3`, so the ids are out of file order, which is the point.
- `tier_of` assigns read / write / **destructive** by REVERSIBILITY, the same
  rule the permission tiers use. `delete` and `update` with no `where` are
  destructive: those are the ones that read as ordinary and empty a table.
  `with` is reported as a write rather than guessed at — over-stating what a
  statement does costs a reader a moment, under-stating it costs them a table.
- **`studio_docs.open` CANONICALISES the path it stores.** `find_open` always
  compared canonically, so a document's identity was canonical while
  `doc.path` kept whatever the caller typed — and everything downstream reads
  `doc.path`: `studio_ui.doc_key` files section anchors under it, and
  `project_path_for` decides which project a document belongs to by matching it
  as a PREFIX. A path arriving with a `..` in it (`<project>/../loose.sql`) was
  therefore attributed to the project it had just climbed out of, because the
  string still began with that project's path. Found by a `.sql` file outside
  every project resolving to a project's database.
- **A `.sql` file NAMES its connection, in the file**: `-- @database app`, read
  through the same scanner, so a directive inside a string or a block comment
  is not one. In the file and not in a picker because opening somebody else's
  `.sql` must not silently point it at your database — a picker remembers what
  YOU chose last; a line in the file travels with it and shows in the diff.
  With no directive, ONE declared connection is an obvious answer and two is a
  question (`no-database`), because guessing is how a statement lands on the
  wrong database.
- `.gstudio.json` gains `databases`, by NAME. No passwords: that file is
  committed, and a credential that travels with the project is a credential in
  everybody's clone. Those go in `studio_secrets`, keyed by the same name.
- A SQLite `path` is resolved against the PROJECT, not the launch directory —
  `data/app.db` in a committed file has to mean the same thing in every clone.
- **Every refusal is named**: `file-no-project`, `no-databases`, `no-database`,
  `unknown-database`, `bad-database`. `file-no-project` is deliberately NOT the
  `no-project` the project-file action uses — that one means nothing is open,
  and "open a project first" about a window with three projects open sends the
  user nowhere.
- The generated program puts the statement in through `quote` and never
  hand-written quotation marks: it is the user's text going into a gBASIC
  string literal, and an apostrophe would end that literal early and leave the
  rest to be read as code. Same rule the viewer registry follows for field
  names.
- `query` for a read and `exec` otherwise, because `exec` reports
  `rows_affected` and that is the only thing an `update` has to say. A
  PostgreSQL `insert ... returning` therefore reports a count rather than its
  rows — a known gap, not a silent one.
- A pg `port` is emitted as a NUMBER. Quoting it hands `pg.connect` a string
  where it wants an integer, and the failure would be about types rather than
  about the project file that set it.
- **`to` is a reserved word** (`print to error`), so a parameter named one is a
  parse error in a library nothing can then load. `from` is fine; `lo`/`hi` is
  what `_raw_after` uses.
- **`ctx_open_on` in `ui_gui_ctx` goes by INDEX, not by scanning for a y.** The
  scan is the faithful path and is used once, where it is the thing being
  tested; everywhere else it is a race and it lost one — a phase that redraws
  rebuilds the nav rows and the next tick can arrive before GTK has allocated
  them, so no y maps to any row and the menu silently does not open. Same
  allocation-timing trap as before, found as an intermittent failure.
- **`persist.read_status` answers "loaded", not "ok".** Testing for the wrong
  one silently yields an empty store on every read — the round trip appears to
  write and then return nothing.
- A smoke mode that reaches past `studio_ui` fails in the least legible way
  there is: `stu3_smoke` mutated `ws.sections` after that field was removed, and
  because it runs inside a GTK timer callback the raise took the callback down
  and left the main loop spinning. A HANG, not a failure.
- **PERSISTED PER-DOCUMENT STATE IS KEYED BY PATH, NEVER BY `doc-N`.**
  `studio_ui.doc_key(doc)` is the one answer, used for section anchors AND
  branches. A document id is a live-session handle: closing a tab throws it
  away and reopening the same file mints the next one, so anything filed under
  it was unreachable afterwards — and worse than unreachable. Section ids are
  deliberately NOT in file order (STU-3 re-matches them across edits so an
  inserted function keeps the ids below it), while a state derived fresh
  numbers them in file order. **Measured**: a file whose sections were
  `sec-4, sec-3, sec-1, sec-2` came back from a close as
  `sec-1, sec-2, sec-3, sec-4`, so every result filed against sec-4 named a
  DIFFERENT function and the results pane showed it confidently. Silent
  misattribution is worse than loss. `ui_anchors` is the regression test and
  was written to fail first.
- `studio_sections` and `studio_branches` never interpret that key — they only
  compare it — so the whole fix is in what `studio_ui` hands them. That is also
  why it moved no goldens: `ui_branch` and `sections_gui` pass unchanged.
- **Anything that builds section or branch state outside `studio_ui` must use
  `studio_ui.doc_key` too.** Two places did — `tests/drivers/ui.bas`'s branch
  fixture and `stu3_smoke` — and both broke the moment the key changed: the
  first built a tree the window could not find, the second persisted a SECOND
  record for a document already filed under its path. The layering rule earning
  its keep: the only two places that skipped `studio_ui` are the only two that
  broke.
- **THE WORKSPACE IS NOT A FILE ANY MORE.** It rides inside `session.json` as
  `session.workspace`. There was never more than one:
  `create_registered_workspace` has two production call sites and both are
  guarded by `if ws = nothing`, so a separate `workspaces/<id>.json`, a
  `workspaces.json` registry listing it, a most-recent order and an id-minting
  counter were four mechanisms serving a set of size one. The in-memory name
  (`app.model.workspace`, `studio.set_workspace`) is KEPT — 109 call sites, and
  renaming them buys nothing a user can see. What the user had was a file, a
  registry and a concept in the summary; those are what went.
- Writing the two together also removes a way for them to disagree. A crash
  between "write session.json" and "write workspaces/ws-1.json" could leave a
  pointer to a stale set of projects; one file cannot be half-consistent with
  itself.
- **The migration reads the old file and NEVER deletes it.** `startup` takes
  `session.workspace` when it is there and otherwise calls `_migrate_workspace`,
  which follows the old `session.active_workspace` pointer into
  `paths.legacy_workspaces_dir` — the only remaining use of that directory, and
  it is read-only. Until the first clean save the old file is the ONLY copy of
  that state, and an upgrade that tidies away a user's only copy is not an
  upgrade. `stu1_migrate` builds an old-layout home and asserts both halves:
  the projects come back, and the file is still there afterwards. Verified
  against a copy of a real home — 5 projects, 10 section records.
- `projects[].documents` and `workspace.tabs` are GONE, along with
  `studio_model.open_document` that filled them. They were STU-0 schema that
  only `build_canned` ever wrote: the running app records open documents in
  `workspace.docs` (`studio_docs.to_meta`) and derives the notebook from
  `app.dm.docs`. Two lists of the same thing, one never written, is how a reader
  ends up unable to say what a project is — which is exactly what happened.
  **A project is now a name and a path.**
- **Open Folder reads the name field as a PATH, and a GtkEntry is not a shell.**
  `studio_ui.expand_path` does the two expansions everybody assumes: a leading
  `~`, and a relative path against `GBASIC_STUDIO_CWD` — the directory
  `./studio` was invoked from, which it exports for exactly this, because the
  script cds into the install tree and Studio's own working directory is the
  one referent that is never what anyone meant. Measured before it existed:
  `~/development/gdash` came back "gdash is not there", about a directory that
  was plainly there. `~user` is deliberately NOT expanded — that needs a passwd
  lookup, and a confident wrong home is worse than a path that fails visibly.
- `adopt_folder` answers `no-folder` and `no-path`, not `missing` and `none`.
  `missing` is about a browser row, where the leaf is the thing the user
  clicked; a typed path needs the WHOLE expanded string, because the part that
  is wrong is usually the part the leaf hides. `no-path` (an empty field) is a
  question rather than a failure and says what to type. The display tier
  reduces the path itself (`path_free` in `app/studio.bas`) rather than the
  window saying less than it should — a golden's need to be path-free is not a
  reason to give a user a worse sentence.
- The empty-workspace browser names BOTH ways in, because neither is guessable
  from a row of buttons and a field whose placeholder said "name". That field is
  the only route to an existing project, and nothing in the window said so —
  which is how someone with a dozen projects concluded Studio could not open
  them. The placeholder is "name or path" and both it and Open Folder carry
  tooltips. Still no GtkFileDialog: it is async with no synthesisable signal, so
  it would be the one control here no test could press.
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
- **The gutter marks the parse error, and the icon is one Studio SHIPS.** A
  `GtkSource.MarkAttributes` draws from an icon NAME, and `dialog-error` and
  `dialog-error-symbolic` are both standard freedesktop names that did not
  resolve — measured, not assumed: this machine's Breeze has the first and not
  the second, its Adwaita has the second and not the first, and what the gutter
  drew was GTK's missing-icon fallback, a grey disc wide enough to sit on top of
  the code. A marker that lands on the wrong icon is worse than no marker, so
  the name is `gbasic-studio-error` and the file is in
  `share/icons/hicolor/<size>/status/`, which every theme inherits and
  `./studio` already puts on XDG_DATA_DIRS for the window icon.
  `MarkAttributes.set_background` would have skipped icons entirely, but it
  takes a `Gdk.RGBA` and `gi.new` refuses it ("not an instantiable object
  type") — the same class of gap as the unreachable class statics.
- Error marks are gated on `studio_ui.mark_signature` (the LINES, joined), not
  on the outline's `revision` that `section_marks` uses. `studio_sections._apply`
  advances `revision` only on a SUCCESSFUL parse, so a revision-gated redraw
  would pin the marker to wherever it first appeared and leave it there however
  the error moved. A count will not do either: two different one-line errors
  share one, and the marker would sit on the line just fixed.
- Both mark caches are primed when a PAGE is created (`marked` to -1,
  `errmarked` to "-", neither reachable as a real value). They are keyed by
  document id, which a closed-and-reopened file keeps, while the buffer behind
  it is brand new and has no marks — so without this the cache says "already
  drawn" about a buffer two lines old and the gutter stays empty until something
  unrelated moves.
- **ONLY gBASIC is parsed.** A project is not only its `.bas` files — a README,
  a Makefile, a JSON fixture are part of it — but `view_for` used to hand every
  document to `source_outline`, and a markdown file does not parse to nothing,
  it parses to a FAILURE. So opening README.md answered "this file does not
  parse — error 1:1 unexpected token", counted `Errors (1)` and marked line 1 in
  the gutter. `studio_ui.is_gbasic` gates the refresh; an unrefreshed state is
  valid and empty, which is the truth. `run_section` refuses first, by NAME
  (`not-gbasic`), before deriving anything.
- `studio_ui.gbasic_suffixes` is `.bas` / `.gb` — the `globs` of `gbasic.lang`,
  which is the file the EDITOR highlights from, so "is this gBASIC" has one
  answer and not two that drift. Suffix and case-insensitive: `notes.bas.txt`
  and `dialect.basic` are the two ways a looser check goes wrong, and
  `README.BAS` is still gBASIC.
- **Studio decides what is gBASIC; the TOOLKIT decides everything else.**
  `studio_shell._set_language_for` forces `gbasic` for Studio's own suffixes and
  otherwise asks `guess_language`, which already knows markdown, json, yaml,
  html, css, python, sh, C, XML, TOML, SQL, Rust and Go. Studio does not keep a
  table of extensions; that is the stdlib's job, and a table here would be one
  more thing to go stale. Through the editor's OWN manager (`ed._lm`) — a
  buffer's highlight engine calls back into the manager that produced its
  language, and a transient one finalizing on return is a documented
  GtkSourceView critical. `ed.set_language(id)` RAISES on an unknown id and
  gBASIC cannot catch a raise, so everything but gBASIC goes through the object
  `guess_language` returns; `nothing` just means no highlighting, which is right
  for a `.txt` and for a Makefile, which it does not recognise.
- `studio_tools._is_refusal` must list every way `run_section` declines —
  `execute_section` is an agent act over the same function, and an action
  missing from that list is reported to the model as a SUCCESS. The agent would
  be told it ran a README.
- **A file that does not parse SAYS SO, and says where.**
  `studio_sections.refresh` has recorded the parser's diagnostics since STU-3
  (`state.diagnostics`, `{severity, message, start_line, start_column, ...}`)
  and nothing displayed them. A file that does not parse yields no sections, so
  the strip said `section: (none)`, Run answered "the cursor is not inside a
  runnable section" — true, and useless, because the cursor is plainly inside a
  function — and the LINE AND COLUMN of the syntax error, the one actionable
  fact the window held, was thrown away on every keystroke. `studio_ui.parses`
  / `parse_lines` / `diagnostic_line` surface it; `error_body` puts it in the
  Errors pane, and `run_section` returns the distinct action `no-parse` so the
  status line can name the file rather than the cursor.
- `studio_ui.parses(st)` asks `st.valid`; it does NOT infer from the section
  list being empty. On a failed parse `studio_sections._apply` KEEPS the
  last-known-good sections — it must, or a user mid-keystroke would have every
  result renumbered out from under them — so a document can fail to parse and
  still have a full list of sections. That is also why the same broken file
  reaches the user two ways: `no-parse` when it was broken on open (no sections
  ever existed) and `refused` when it was broken by TYPING (the old sections
  survive, so the caret resolves and `can_run` declines). Both now carry the
  same address.
- **Dropping the app `view_for` returns costs more than a re-parse.** The
  documented cost is re-parsing at cursor-move rate; the undocumented one is
  that the NEXT failed parse has no cached state to retain sections from, so
  `view_for` rebuilds from the workspace and comes back with none. That is the
  difference between a typed-in syntax error reaching `refused` (what the window
  does, because `refresh_run` threads the app back) and reaching `no-parse`.
  `tests/drivers/ui.bas`'s `badsyntax` case threads it deliberately for this
  reason.
- **The run strip is TWO ROWS, and the state line owns the second.** A refusal
  or a materialization failure carries a whole SENTENCE ("that section is
  ambiguous after the last edit; disambiguate it first"), and a horizontal row
  of three buttons plus two labels has a hard width budget — so it arrived
  ellipsized after its first few words and the rest of it was nowhere on screen.
  Buttons and the two SHORT labels (`section:`, `standing`) keep the top row;
  the state label gets the console's full width below them and WRAPS. Wrapping
  also answers the minimum-width problem the ellipsis was originally for: a
  wrapping label reports its longest WORD as its minimum, which is smaller than
  the ellipsized version ever was.
- **A refused or failed run records NO result, so the Errors pane has to be told
  by the session.** Both states return from `studio_ui.run_section` with
  `active` false, so `tick_run` is never polled and `add_result` is never
  reached — correctly, because nothing executed and there is nothing to file
  under the section's history. But that left the message one home, the strip,
  and the pane whose whole job is to say what went wrong answered "(none)" about
  a run Studio had just declined. `output_source` therefore has a fourth kind,
  `fault`, and `studio_ui.fault_text` is the closed set (refused | failed) that
  produces it. The output panes say `(the run did not start)` rather than
  showing an EARLIER run's output beside "refused:", which would read as output
  of the run that was refused.
- The Errors heading is REFRESHED, not fixed: `studio_ui.error_heading` counts
  non-empty lines and `refresh_run` moves the heading into `state-error` when
  there are any. The pane is the third of three stacked in the console scroller,
  so on a short window it is the one below the fold — and a heading reading
  "Errors" over a pane you cannot see is indistinguishable from one reading
  "Errors" over "(none)". Counted in NON-EMPTY lines because a raw stderr
  capture ends in a newline and a blank trailing line is not an error.
- `studio_style.clear_state` exists because "no state" is not `state-idle`.
  `set_state` always ADDS one, and a widget with a look of its own (a heading)
  should get its own look back rather than the idle colour.
- **`_left` + `_wrapped` fold a label at its NATURAL width, which is a number
  chosen for the right-hand column.** `halign: START` hands a label its natural
  width and `max_width_chars` caps that at 44 — right beside the results pane,
  wrong in the console, which is roughly twice as wide and ended up folding
  program output into a narrow ribbon with half the pane empty next to it.
  `studio_shell._fill` (xalign 0 + halign FILL + hexpand) is what makes a label
  span the width it is GIVEN; it is safe only inside `_vscroll`, whose
  horizontal policy of NEVER makes the viewport impose that width, and
  `max_width_chars` still caps the natural request so the window's minimum does
  not move. Same blind spot as every other entry here: a golden asserts the
  text, which is identical either way.
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
- **A STARVED PANE CLIPS FROM THE LEFT; IT DOES NOT REFLOW.** GTK 4's
  `shrink-start-child`/`shrink-end-child` default to TRUE, so a GtkPaned will hand
  a child LESS than its minimum — down to nothing — and `_vscroll`'s horizontal
  policy of NEVER does not scroll but does hold the child at its own minimum
  width. Underfed, the pane therefore clips, from the LEFT, with no scrollbar to
  drag back. Measured on master: `rsplit` at 330 left the console reading
  ": finished [sec-6] — exit 1" and "able: undefned_name" and blanked the editor
  page entirely; `vsplit` at 0 left the source view 38px tall with the code gone.
  Home does not help — the caret is off-screen in a direction the view will not
  follow. All three paneds now have `shrink` OFF, and the notebook, browser,
  console and right column carry `set_size_request` floors, because a scroller's
  own minimum is near zero and "stops at the minimum" has to stop somewhere
  usable. A run is what tips it: the run-state label's text grows, and a label
  that neither wraps nor ellipsizes reports its whole sentence as its MINIMUM
  width — so the run strip is ellipsized now, and the text it reports is
  unchanged.
- **A GtkSourceView's colours are a STYLE SCHEME, not the GTK theme, and the
  stylesheet cannot reach them.** Nothing ever set one, so the editor sat on the
  light default inside a dark window and Studio looked like two applications
  sharing a frame. A scheme is a `GtkSourceStyleScheme` object, not CSS, so
  `studio_style.css()` has nothing to say about it. `light_scheme` is `classic`
  — measured, by asking a fresh buffer for `get_style_scheme` before anything
  set one — so the light editor is exactly what it always was, and
  `classic-dark` is that scheme's own dark counterpart. Naming both is the
  point: otherwise one is a choice and the other is an accident.
- **No ONE signal says the toolkit is dark.** Measured on a plainly dark window
  on this machine: `gtk-application-prefer-dark-theme` was FALSE, `gtk-theme-name`
  said "Breeze", and only `GTK_THEME=Adwaita:dark` carried it. So
  `studio_style.toolkit_is_dark` takes all three and any one of them wins.
  `Gtk.Settings.get_default` is a class static the bridge cannot reach, but
  `widget.get_settings()` is an ordinary instance method and answers the same
  object — the same shape of workaround as the per-widget CSS providers.
- `settings.theme` had been persisted since STU-0 with NOTHING reading it.
  `studio_style.dark_for` is where it finally lands: "light"/"dark" overrule the
  toolkit, "system" defers to it. One decision, read by both the editor's scheme
  and the section tint — asking the toolkit separately would give a user who set
  `theme: "dark"` on a light desktop a dark editor with a light tint smeared
  across it.
- The section tint is a GtkTextTag background, so it cannot be an `@theme`
  reference either: `studio_style.section_tint(dark)` is two literals and a
  boolean. The hardcoded `#eaf1fb` was a highlight on a light editor and a smear
  over unreadable text on a dark one.
- `env` answers `unknown` for an unset variable and `lower` RAISES on one, so
  `_names_dark` guards with `is_string` before touching it. A theme probe that
  crashed the window of everyone who has not set GTK_THEME would be a poor trade
  for a colour.
- **A CSS class without its provider renders nothing.** `gi` cannot call class
  statics, so `Gdk.Display.get_default` and
  `Gtk.StyleContext.add_provider_for_display` are both out of reach and there is
  no display-wide stylesheet. Providers go on ONE WIDGET AT A TIME. That is why
  `studio_style.apply(widget, class)` does both halves and why nothing calls
  `add_css_class` directly for a Studio class — a call site that remembers only
  the class writes a name nothing renders. The provider is the program global
  `_STUDIO_STYLE`, assigned in `app/studio.bas` beside `_DATAGRID` for the same
  no-closures reason; reading an unassigned global RAISES, so it is assigned
  unconditionally in the display block rather than lazily.
- **`letter-spacing` breaks a wrapping label the way `wrap = true` does.** A
  label with letter-spacing reports a natural width that does NOT include the
  spacing, so a wrapping label given its own natural width wraps inside it:
  measured, "Errors" came back 38px and rendered as "Error-/s", and all three
  output-pane headings folded the moment the heading class went on. `.studio-head`
  therefore has no letter-spacing. Same blind spot as every other entry here —
  the asserted text is identical whether the widget folded it or not.
- **`_left` gives a label its NATURAL width**, because `halign: START` does. That
  is right for a row and wrong for a bar: the status bar styled as a bar was a
  grey tab the width of its current sentence. `xalign = 0` keeps the text left;
  `halign = FILL` is what makes it span.
- **An empty GtkListBox still paints a list.** The background is on the ROW, not
  on the list, so flattening the listbox alone leaves a white strip with one
  centred sentence in it — which reads as a control. `_fill_nav` flattens the row
  it just appended as well.
- The `GtkGizmo (slider) reported min width/height -2` warnings are NOT ours and
  are not fixable here. A GtkWindow holding one GtkScrolledWindow around one
  GtkLabel prints the same pair on this GTK 4 — no paned, no policy, no margin
  involved. Studio has four scrolled windows, hence eight lines. Taking the
  paneds off `shrink` changed nothing, so it is not a starved allocation either.
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
