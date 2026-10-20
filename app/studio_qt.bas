' SPDX-License-Identifier: Apache-2.0
' Copyright 2026 Matthew C. Tedder. See LICENSE.

' studio_qt.bas — the Qt entry point (STU-22).
'
' A SECOND ENTRY DURING THE MIGRATION, deliberately, rather than a mode inside
' `app/studio.bas`. Three reasons, in the order they decided it:
'
'   1. `app/studio.bas` loads `gi`, `gtk`, `datagrid` and `sourceeditor` inside
'      its display block, and this process must load NONE of them. A Qt mode in
'      there would be one `load` away from pulling GTK into a window that has
'      no use for it -- and `gi.new("Gtk.<Widget>")` SEGFAULTS before GTK is
'      initialized rather than raising, which is not a failure anybody enjoys
'      diagnosing twice.
'   2. The rule that `app/studio.bas` is the only place with `gi.connect` stays
'      exactly true, because there is no `gi.connect` here at all. A Qt handler
'      is a FUNCTION REFERENCE in the record.
'   3. It is deletable. When the GTK shell goes, this file becomes
'      `app/studio.bas` and nothing else has to be untangled.
'
' WHAT HAS NOT CHANGED IS THE INTERACTION RULE. A handler here is still an
' ADAPTER: read one plain value off the window, call one `studio_ui` function,
' ask for a redraw. Every decision is in `studio_ui` over plain data, which is
' what the headless suite asserts and what made this port 1.3% of the source
' rather than a rewrite. A handler cannot close over state -- gBASIC functions
' do not -- so each reads the program global `G`, which is the same two-line
' wrapper shape the GTK handlers and the agent tool adapters already use.
'
' `qt.run()` IS CALLED FROM THE TOP LEVEL OF `program`, and that is load-bearing
' rather than tidy: from inside a function every loop-delivered source is
' silently starved -- a timer tick is appended to `timer.ticks` and never
' delivered, the schedule advances so it looks like it is working, and the
' program HANGS with no output. gBASIC's own open-ledger item, with a probe.

' ---------------------------------------------------------------------------
' THE HANDLERS.
'
' Every one is an ADAPTER and nothing else: read one plain value off the window,
' call one `studio_ui` function, record the outcome, ask for a redraw. That is
' STU-2B's rule unchanged, and it is the whole reason this port is small -- the
' decisions are all in `studio_ui` over plain data, where the headless suite
' asserts them, so moving toolkits moves only the reading.
'
' A HANDLER TAKES NO ARGUMENTS. `qt.invoke` passes none and a connected handler
' is called with none, so anything a handler needs it ASKS the window for by
' name -- `qt.selected`, `qt.read`. Nor can it close over state (gBASIC
' functions do not), so each reads the program global `G`, which is the same
' shape the GTK handlers and the agent tool adapters already use.
'
' WIRING IS A RECORD, NOT A CALL. A handler is `{ kind: "handler", target,
' signal, handler }` carried in the window's own `items`, which is why there is
' no `gi.connect` equivalent here and why `app/studio.bas` keeps its claim to
' being the only file with one.
' ---------------------------------------------------------------------------

' The full redraw, and the three decisions it makes are all `studio_ui`'s: what
' the status bar says about the last outcome, whether the name field has been
' consumed, and which pending confirmation survives. Clearing the arms HERE
' rather than in each handler is what stops one outliving an unrelated click.
function qt_redraw()
    notice = studio_ui.action_notice(G.last_action, G.last_detail)
    return qt_redraw_saying(notice)
end function

' The same, with a sentence `studio_ui` has no vocabulary for. ONE caller: the
' Run button, until a `source`'s caret is readable. See `on_qt_run`.
function qt_redraw_saying(notice)
    if not qt.is_open(G.win) then
        return nothing
    end if
    ' THE RE-ENTRANCY GUARD, and leaving it out SEGFAULTED.
    '
    ' Our own writes echo back as signals: a redraw rewrites the tree, which
    ' changes its selection, which fires `itemSelectionChanged`, whose handler
    ' redraws -- unbounded, inside Qt's own event dispatch, so it took the
    ' process down with exit 139 and NO OUTPUT AT ALL, stdout being block
    ' buffered. Fourth time that signature has appeared in this project, and
    ' the rule was already written down: `app/studio.bas` carries `G.redrawing`
    ' for exactly this, "because our own `set_current_page`/`set_text` echo back
    ' as signals". Located with `print to error`, which is unbuffered and so
    ' survives the crash -- the trick CLAUDE.md also already records.
    if G.redrawing then
        return nothing
    end if
    G.redrawing = true
    kind = studio_ui.arm_kind(G.last_action)
    if kind != "path" then
        G.armed_path = ""
    end if
    if kind != "doc" then
        G.armed_doc = ""
    end if
    if kind != "save" then
        G.armed_save = ""
    end if
    nav = studio_ui.nav_rows(G.app)
    G.app = studio_view_qt.render(G.win, G.app, notice)
    if studio_ui.clears_name(G.last_action) then
        z = qt.write(G.win, studio_shell_qt.part_name_field(), "")
    end if
    G.redrawing = false
    return nothing
end function

' A REDRAW THAT DOES NOT TOUCH THE BROWSER.
'
' For a SELECTION change, which cannot alter the row set -- so refreshing the
' tree would be work for nothing, and under GTK it is work the full redraw does
' anyway because a GtkListBox has to be rebuilt to be re-rendered. A tree does
' not.
'
' IT ALSO AVOIDS A LIVE gBASIC CRASH, and that is worth saying because the
' design reason came first and the bug confirmed it. Refreshing the tree from
' inside its own selection handler frees every QTreeWidgetItem while the
' `qt.select` that provoked the handler is still finishing, and
' `gb_qt_table_select` then calls `setSelected` on freed memory --
' `QTreeWidgetItem::treeModel`, invalid read of size 8, named by valgrind at
' qt_backend.cpp:3550 against the free at qt_backend.cpp:4611. It segfaults
' about three runs in five and, when it does not, answers `unknown` for a row
' that was just selected. Reported upstream with a thirty-line reproduction.
function qt_redraw_selection()
    if not qt.is_open(G.win) then
        return nothing
    end if
    if G.redrawing then
        return nothing
    end if
    G.redrawing = true
    notice = studio_ui.action_notice(G.last_action, G.last_detail)
    kind = studio_ui.arm_kind(G.last_action)
    if kind != "path" then
        G.armed_path = ""
    end if
    if kind != "doc" then
        G.armed_doc = ""
    end if
    if kind != "save" then
        G.armed_save = ""
    end if
    G.app = studio_view_qt.render_run(G.win, G.app)
    ' The NOTICE when the last outcome has one, and otherwise what the model
    ' says about itself -- the same fallback `studio_shell.refresh` has, and
    ' leaving it out blanked the status bar on every selection.
    line = notice
    if line = "" then
        line = studio_ui.status_text(G.app)
    end if
    z = qt.set(G.win, studio_shell_qt.part_status(), "text", line)
    G.redrawing = false
    return nothing
end function

' What the header's name field currently holds. The whole of the
' widget-to-value read for every naming action.
function qt_typed_name()
    return qt.read(G.win, studio_shell_qt.part_name_field(), "text")
end function

function qt_note(kind, target, detail)
    G.log = studio_history.note(G.log, kind, target, detail, epoch())
    return nothing
end function

' Record an outcome and redraw. Every handler below ends in this.
function qt_took(r)
    G.app = r.app
    G.last_action = r.action
    G.last_detail = r.detail
    return qt_redraw()
end function

' ---- the browser ----------------------------------------------------------

' SELECTION FOLLOWS, AND DOES NOT ACTIVATE. `itemSelectionChanged` fires for a
' click and for an arrow key alike, and activating on an arrow key would open
' every file you passed on the way down the tree. Studio already separates the
' two -- the browser's right-click menu selects without activating for exactly
' this reason -- so this is `select_row` and the click below is `activate_row`.
function on_qt_nav_selected()
    ' Our own redraw provokes this signal, so it must not act on one.
    if G.redrawing then
        return nothing
    end if
    idx = qt.selected(G.win, studio_shell_qt.part_browser())
    if is_unknown(idx) then
        return nothing
    end if
    r = studio_ui.select_row(G.app, studio_ui.nav_rows(G.app), idx)
    G.app = r.app
    G.last_action = r.action
    G.last_detail = r.detail
    ' NOT `qt_redraw`. A selection cannot change the row set, and refreshing
    ' the tree from inside its own selection handler is a live crash -- see
    ' `qt_redraw_selection`.
    return qt_redraw_selection()
end function

' A SINGLE CLICK ACTIVATES, which is what the GTK browser does.
'
' AND THIS ONE HAS NO TIER, which is stated rather than hidden. `qt.select`
' fires `itemSelectionChanged` and nothing can synthesise `itemClicked` --
' measured, all three tree signals connect and only the selection one is
' drivable. gBASIC added `qt.right_click` for precisely this argument (§0.20),
' so a left-click helper is asked for upstream. Meanwhile what keeps this
' honest is that it is an adapter over `activate_row`, which `ui_open`,
' `ui_expand`, `ui_project` and `qtview_probe` all cover -- the same sanctioned
' exception Ctrl+wheel already carries: the logic is tested and only the wiring
' is not.
function on_qt_nav_clicked()
    idx = qt.selected(G.win, studio_shell_qt.part_browser())
    if is_unknown(idx) then
        return nothing
    end if
    rows = studio_ui.nav_rows(G.app)
    r = studio_ui.activate_row(G.app, rows, idx)
    if r.action = "open" then
        qt_note("file_opened", rows[idx].path, "")
    end if
    if r.action = "project" then
        qt_note("project_opened", rows[idx].path, rows[idx].label)
    end if
    return qt_took(r)
end function

' ---- the notebook ---------------------------------------------------------

function on_qt_tab_changed()
    ' Our own redraw provokes this signal, so it must not act on one.
    if G.redrawing then
        return nothing
    end if
    at = qt.read(G.win, studio_shell_qt.part_tabs(), "currentIndex")
    return qt_took(studio_ui.select_tab(G.app, studio_ui.tab_rows(G.app), at))
end function

' ---- the header -----------------------------------------------------------

function on_qt_save()
    r = studio_ui.save_active(G.app, G.armed_save)
    G.armed_save = r.armed
    if r.action = "saved" then
        qt_note("file_saved", r.detail, "")
    end if
    return qt_took(r)
end function

' ---- the run strip --------------------------------------------------------

' RUN REFUSES, AND SAYS WHY, UNTIL A `source`'S CARET CAN BE READ.
'
' Studio's panes are caret-keyed (STU-5A'): the strip answers which section the
' caret is in, Run runs that one, and the results, variables, errors and branch
' panes all follow it. `run_section(app, 0, 0)` would resolve through
' `section_for`'s fall-through to the FIRST section -- a plausible wrong answer,
' which is this project's named failure class, and far worse than a refusal.
'
' Measured: none of `cursorPosition`, `textCursor`, `currentLine` or
' `caretPosition` is a Q_PROPERTY of a QPlainTextEdit, which is right -- a
' QTextCursor is an object, the same shape as §0.14's highlighter. Asked
' upstream as request 1. THIS IS THE ONE SENTENCE IN THE QT SHELL THAT
' `studio_ui` DOES NOT COMPOSE, deliberately: "no caret under Qt" is a fact
' about a toolkit mid-migration and not a thing Studio's model knows, so it
' does not earn a place in that vocabulary. It goes when the caret arrives.
function on_qt_run()
    print to error "Studio (Qt): Run is not wired yet -- a source's caret cannot be read"
    G.last_action = ""
    G.last_detail = ""
    return qt_redraw_saying("Run needs the caret, which this toolkit cannot yet report — use ./studio for now")
end function

function on_qt_run_all()
    r = studio_ui.run_all(G.app)
    G.polling = r.active
    return qt_took(r)
end function

function on_qt_stop()
    return qt_took(studio_ui.stop_run(G.app))
end function

' ---- the menus ------------------------------------------------------------
'
' ONE FUNCTION PER ITEM, because a handler takes no arguments and so cannot be
' told which item fired. The GTK shell has the same list for the same reason.

function on_qt_new_project()
    print to error "Studio (Qt): New Project opens a window, which is not built yet"
    G.last_action = ""
    G.last_detail = ""
    return qt_redraw_saying("New Project needs its own window, which the Qt shell does not have yet")
end function

function on_qt_open_folder()
    r = studio_ui.adopt_folder(G.app, qt_typed_name())
    if r.action = "adopted" then
        qt_note("folder_opened", qt_typed_name(), r.detail)
    end if
    return qt_took(r)
end function

function on_qt_project_file()
    r = studio_ui.add_project_file(G.app, "")
    if r.action = "created" then
        qt_note("file_created", r.detail, "")
    end if
    return qt_took(r)
end function

function on_qt_close_project()
    ws = G.app.model.workspace
    pid = ""
    if ws != nothing then
        pid = ws.active_project
    end if
    return qt_took(studio_ui.close_project(G.app, pid))
end function

function on_qt_new_file()
    r = studio_ui.new_file(G.app, qt_typed_name())
    if r.action = "created" then
        qt_note("file_created", r.detail, "")
    end if
    return qt_took(r)
end function

function on_qt_new_folder()
    r = studio_ui.new_folder(G.app, qt_typed_name())
    if r.action = "created" then
        qt_note("folder_created", r.detail, "")
    end if
    return qt_took(r)
end function

function on_qt_rename()
    r = studio_ui.rename_selected(G.app, qt_typed_name())
    if r.action = "renamed" then
        qt_note("file_renamed", r.detail, "")
    end if
    return qt_took(r)
end function

function on_qt_delete()
    r = studio_ui.delete_selected(G.app, G.armed_path)
    G.armed_path = r.armed
    if r.action = "deleted" then
        qt_note("file_deleted", r.detail, "")
    end if
    return qt_took(r)
end function

function on_qt_reload()
    return qt_took(studio_ui.refresh(G.app))
end function

function on_qt_close_tab()
    r = studio_ui.close_active(G.app, G.armed_doc)
    G.armed_doc = r.armed
    if r.action = "closed" then
        qt_note("file_closed", r.detail, "")
    end if
    return qt_took(r)
end function

function on_qt_theme_system()
    return qt_took(studio_ui.set_theme(G.app, "system"))
end function

function on_qt_theme_dark()
    return qt_took(studio_ui.set_theme(G.app, "dark"))
end function

function on_qt_text_bigger()
    return qt_took(studio_ui.zoom_by(G.app, 1))
end function

function on_qt_text_smaller()
    return qt_took(studio_ui.zoom_by(G.app, 0 - 1))
end function

function on_qt_text_reset()
    return qt_took(studio_ui.zoom_reset(G.app))
end function

function on_qt_restore_session()
    return qt_took(studio_ui.toggle_restore(G.app))
end function

' ---- the wiring -----------------------------------------------------------

' Append a handler record to a window record.
'
' THE ENTRY WIRES AND THE SHELL DOES NOT, which is the layering rather than an
' accident: a handler record carries a FUNCTION VALUE, and these functions live
' here. `studio_shell_qt.window_for` stays a pure function over the model that
' a machine with no Qt can call, and the wiring is one readable list -- the same
' arrangement `app/studio.bas`'s single `connect_signals` has, for the same
' reason.
function qt_on(win, target, signal, fn)
    win.items = append(win.items, { kind: "handler", target: target,
                                    signal: signal, handler: fn })
    return win
end function

function qt_wire(win)
    files = studio_shell_qt.part_browser()
    win = qt_on(win, files, "itemSelectionChanged", on_qt_nav_selected)
    win = qt_on(win, files, "itemClicked", on_qt_nav_clicked)
    win = qt_on(win, studio_shell_qt.part_tabs(), "currentChanged", on_qt_tab_changed)
    win = qt_on(win, studio_shell_qt.part_save(), "clicked", on_qt_save)
    win = qt_on(win, "run_btn", "clicked", on_qt_run)
    win = qt_on(win, "run_all_btn", "clicked", on_qt_run_all)
    win = qt_on(win, "stop_btn", "clicked", on_qt_stop)

    ' A QAction's signal is `triggered`, and `qt.invoke(win, item, "trigger")`
    ' is a REAL PRESS -- where an unmapped `Gtk.Button` inside a popover
    ' silently ignores `activate()`, which cost STU-16 two rounds.
    win = qt_on(win, qt_item("new-project"), "triggered", on_qt_new_project)
    win = qt_on(win, qt_item("open-folder"), "triggered", on_qt_open_folder)
    win = qt_on(win, qt_item("project-file"), "triggered", on_qt_project_file)
    win = qt_on(win, qt_item("close-project"), "triggered", on_qt_close_project)
    win = qt_on(win, qt_item("new-file"), "triggered", on_qt_new_file)
    win = qt_on(win, qt_item("new-folder"), "triggered", on_qt_new_folder)
    win = qt_on(win, qt_item("rename"), "triggered", on_qt_rename)
    win = qt_on(win, qt_item("delete"), "triggered", on_qt_delete)
    win = qt_on(win, qt_item("reload"), "triggered", on_qt_reload)
    win = qt_on(win, qt_item("close-tab"), "triggered", on_qt_close_tab)
    win = qt_on(win, qt_item("theme-system"), "triggered", on_qt_theme_system)
    win = qt_on(win, qt_item("theme-dark"), "triggered", on_qt_theme_dark)
    win = qt_on(win, qt_item("text-bigger"), "triggered", on_qt_text_bigger)
    win = qt_on(win, qt_item("text-smaller"), "triggered", on_qt_text_smaller)
    win = qt_on(win, qt_item("text-reset"), "triggered", on_qt_text_reset)
    win = qt_on(win, qt_item("restore-session"), "triggered", on_qt_restore_session)
    return win
end function

function qt_item(action)
    return studio_shell_qt.part_item(action)
end function

program main(args)
    load persist
    load filetree
    load studio_model
    load studio_docs
    load studio
    load studio_ui
    load studio_sections
    load studio_projects
    load studio_projfile
    load studio_secrets
    load studio_templates
    load studio_results
    load studio_table
    load studio_session
    load studio_sql
    load studio_schema
    load studio_branches
    load studio_overlays
    load studio_drafts
    load studio_history
    load studio_style
    load studio_shell_qt
    load studio_view_qt

    mode = "gui"
    if count(args) > 0 then
        mode = args[0]
    end if
    home = ""
    if count(args) > 1 then
        home = args[1]
    end if
    if home = "" then
        home = studio_qt_default_home()
    end if

    app = studio.startup(home)

    ' An explicit project, the way `./studio gui <home> <dir>` takes one.
    if count(args) > 2 then
        if args[2] != "" then
            a = studio_ui.adopt_folder(app, args[2])
            app = a.app
        end if
    end if

    ' The callback-scope global. Assigned INSIDE the block, because a top-level
    ' assignment never runs -- the top level is read only for declarations --
    ' and read by every handler, which cannot close over state.
    G = { app: app, win: nothing, log: studio_history.open(home),
          last_action: "", last_detail: "",
          ' The three pending confirmations, keyed to the THING rather than to a
          ' flag: moving the selection between two clicks re-arms on the new row
          ' instead of deleting it.
          armed_path: "", armed_doc: "", armed_save: "",
          ' Set across every render, because our own writes echo back as
          ' signals -- see `qt_redraw_saying`.
          redrawing: false,
          ' Whether a run is in flight. The GTK shell lets its timer remove
          ' itself by returning `active`; a `timer.every` keeps ticking, so the
          ' flag is what stops the poller doing work between runs.
          polling: false }

    win = qt_wire(studio_shell_qt.window_for(G.app))
    ' REFUSED BEFORE OPENED, always. `qt.open` validates too, but a validator
    ' nobody is obliged to call is necessary and not sufficient -- and a raise
    ' out of `qt.check` names the part and the path, where a half-built window
    ' names whatever Qt tripped over first.
    ' A WINDOW THAT WILL NOT VALIDATE SAYS WHY AND EXITS CLEANLY.
    '
    ' `qt.check` RAISES rather than answering, which made it a test gate --
    ' and a raise IS catchable (`on error goto next`, frame-scoped; CLAUDE.md
    ' used to say otherwise in five places and it is measured false). Caught, it
    ' is a runtime guard as well: a malformed record names the part and the path
    ' it is at, which is worth printing at a user where a runtime error dump is
    ' not. `qt.open` validates too, so this is the message and not the
    ' protection.
    '
    ' NOTHING ELSE ON THIS PATH CATCHES. A `qt.read` of a part that is not there
    ' is a bug in the record, and catching one is how a window renders half of
    ' itself and says nothing.
    on error goto next
    ok = qt.check(win)
    if error then
        print to error "gBASIC Studio: this window will not build — " + error.message
        return nothing
    end if
    on error stop
    ' THE BROWSER'S SUBJECT HAS TO BE IN THIS FRAME BEFORE THE OPEN, not after
    ' it: `qt.open` binds a `table to show` by reading the named variable out of
    ' the frame that calls it, and refuses the whole window when it is not
    ' there. Found by running it -- the refusal says so in as many words, which
    ' is the difference between a minute and an afternoon.
    nav = studio_ui.nav_rows(G.app)
    z = qt.open(win)
    G.win = win

    ' THE FIRST PAINT AND EVERY LATER ONE ARE THE SAME CODE. The record carries
    ' shape and no state, so the window opens empty and one render fills it --
    ' a separate initial-population path is how a view starts disagreeing with
    ' its refresh.
    G.app = studio_view_qt.render(win, G.app, "")
    ' The chrome, once. Not in the record because the browser spends its one
    ' slot on being named with a subject, and not per render because none of it
    ' changes while Studio runs.
    dressed = studio_view_qt.dress(win, G.app)

    ' The layout the user last left. Each split is addressed by a part that is
    ' one of ITS OWN panes, because the walk stops at the nearest region.
    for each p in studio_shell_qt.pane_sizes(G.app)
        sized = qt.resize_panes(win, p.at, p.sizes)
    end for

    if mode = "probe" then
        ' A headless tier's mode: everything above has happened for real,
        ' offscreen, so print what the window is holding and stop. No loop,
        ' because a loop needs somebody to close the window and offscreen has
        ' no window manager.
        print "-- the Qt shell, opened and rendered --"
        print "  title:    " + qt.read(win, studio_shell_qt.window_name(), "windowTitle")
        print "  status:   " + qt.read(win, studio_shell_qt.part_status(), "text")
        ' A TREE, not a table, so there is no `rowCount` to read -- and asking
        ' it for the DEPTH of a row is the better assertion anyway: a populate
        ' that ignored the depth builds a flat tree whose every name, index,
        ' selection and heading reads back correctly, so the depth is the one
        ' thing nothing else in this probe can see.
        print "  rows:     " + string(count(studio_ui.nav_rows(G.app)))
        print "  heading:  " + qt.heading(win, studio_shell_qt.part_browser(), 0)
        i = 0
        for each nr in studio_ui.nav_rows(G.app)
            cell = qt.cell(win, studio_shell_qt.part_browser(), i, "text")
            print "    " + string(qt.depth(win, studio_shell_qt.part_browser(), i)) + " [" + studio_qt_scrub(cell, G.app) + "]"
            i = i + 1
        end for
        print "  tabs:     " + string(qt.tabs(win, studio_shell_qt.part_tabs()))
        print "  section:  " + qt.read(win, "run_section", "text")
        print "  state:    [" + qt.read(win, "run_state", "text") + "]"
        print "  standing: [" + qt.read(win, "run_standing", "text") + "]"
        print "  run all:  " + string(qt.read(win, "run_all_btn", "visible"))
        print "  snippets: " + string(qt.read(win, "snippet_btn", "visible"))
        print "  prefix:   [" + qt.read(win, "prefix_body", "plainText") + "]"
        print "  target:   [" + qt.read(win, "target_body", "plainText") + "]"
        print "  errors:   " + qt.read(win, "err_head", "text") + " [" + qt.read(win, "err_body", "plainText") + "]"
        print "  results:  [" + studio_qt_first_line(qt.read(win, "results_body", "plainText")) + "]"
        print "  branches: [" + studio_qt_first_line(qt.read(win, "branch_body", "plainText")) + "]"
        print "  tables:   [" + studio_qt_first_line(qt.read(win, "tables_body", "plainText")) + "]"
        print "  git:      [" + qt.read(win, "git_body", "plainText") + "]"
        print "  dark is checked: " + string(qt.read(win, studio_shell_qt.part_item("theme-dark"), "checked"))

        ' AND THEN A DOCUMENT OPENS, through the same `studio_ui.activate_row`
        ' a browser click calls -- so this half asserts the row model reaching
        ' the window as well as the render. One tier rather than two, because
        ' the cold state and the one-document state are the same code path with
        ' different data, and a tier that only ever sees an empty window is the
        ' STU-2B dead end wearing a golden.
        print "-- a browser row activated, exactly as a click would --"
        rows = studio_ui.nav_rows(G.app)
        at = studio_qt_row_index(rows, "file", "main.bas")
        r = studio_ui.activate_row(G.app, rows, at)
        G.app = r.app
        print "  action:   " + r.action
        nav = studio_ui.nav_rows(G.app)
        G.app = studio_view_qt.render(win, G.app, "")
        print "  title:    " + qt.read(win, studio_shell_qt.window_name(), "windowTitle")
        print "  status:   " + qt.read(win, studio_shell_qt.part_status(), "text")
        print "  tabs:     " + string(qt.tabs(win, studio_shell_qt.part_tabs()))
        print "  on top:   " + string(qt.read(win, studio_shell_qt.part_tabs(), "currentIndex"))
        print "  section:  " + qt.read(win, "run_section", "text")
        doc = studio_docs.active_doc(G.app.dm)
        ed = studio_shell_qt.part_editor(doc.id)
        print "  " + ed + ": [" + replace(qt.read(win, ed, "plainText"), chr(10), " / ") + "]"
        print "  highlighted as: " + qt.highlighting(win, ed).language
        ' `line_numbers` is a CONSTRUCTION option and not a Q_PROPERTY, so it
        ' has its own reader -- which also answers the margin's width, and
        ' `unknown` for a part that has no margin at all.
        print "  margin:         " + string(qt.gutter(win, ed).line_numbers) + " numbers, " + string(qt.gutter(win, ed).marks) + " marks"
        ' THE GUTTER, which is the second thing gBASIC built for this consumer
        ' by name. `section` is the whole notebook affordance -- a cell
        ' boundary is otherwise invisible -- and the lines are 1-based here
        ' where `studio_ui` keeps them 0-based for a Gtk.TextBuffer.
        print "  section marks:  " + string(qt.marks(win, ed, "section"))
        print "  error marks:    " + string(qt.marks(win, ed, "error"))

        ' AND EDITED IN THE MODEL, which is where the marker comes from. The
        ' caption moves and the editor is NOT rebuilt -- the one claim the
        ' reconcile exists to support, asserted here against the real shell
        ' rather than against a fixture.
        print "-- edited in the model --"
        G.app.dm = studio_docs.edit(G.app.dm, doc.id, "print \"typed\"" + chr(10))
        nav = studio_ui.nav_rows(G.app)
        G.app = studio_view_qt.render(win, G.app, "saved nothing; this is a probe")
        print "  tabs:     " + string(qt.tabs(win, studio_shell_qt.part_tabs()))
        print "  title:    " + qt.read(win, studio_shell_qt.window_name(), "windowTitle")
        print "  status:   " + qt.read(win, studio_shell_qt.part_status(), "text")
        print "  " + ed + ": [" + replace(qt.read(win, ed, "plainText"), chr(10), " / ") + "]"

        ' AND A FILE THAT DOES NOT PARSE, which is the half of the gutter that
        ' matters: the run strip says only that a file is broken, and the
        ' margin says WHICH LINE. Edited in the model so the parse fails and
        ' the sections survive -- `studio_sections._apply` keeps the
        ' last-known-good set, which is why a document can fail to parse and
        ' still have a full list of sections.
        print "-- and with a syntax error in it --"
        G.app.dm = studio_docs.edit(G.app.dm, doc.id, "program main(args)" + chr(10) + "  print (((" + chr(10) + "end program" + chr(10))
        nav = studio_ui.nav_rows(G.app)
        G.app = studio_view_qt.render(win, G.app, "")
        print "  parses:        " + string(studio_ui.parses(studio_ui.view_for(G.app).st))
        print "  error marks:   " + string(qt.marks(win, ed, "error"))
        print "  section marks: " + string(qt.marks(win, ed, "section"))
        print "  errors pane:   " + studio_qt_first_line(qt.read(win, "err_body", "plainText"))

        z = qt.close(win)
        return nothing
    end if

    if mode = "press" then
        ' PRESSING EVERY CONTROL, FOR REAL, WITH NO DISPLAY.
        '
        ' This is what replaces `ui_gui_menus` and `ui_gui_name`, and it is
        ' better than what it replaces in one specific way: `qt.invoke(win,
        ' item, "trigger")` fires a QAction the way a person does, where a
        ' `Gtk.Button` inside a popover that has never been shown silently
        ' ignores `activate()` -- which cost STU-16 two rounds and is why the
        ' GTK tier has to pop each menu up first.
        print "-- the name field is where every naming action reads from --"
        z = qt.write(win, studio_shell_qt.part_name_field(), "from_the_menu.bas")
        print "  typed: " + qt.read(win, studio_shell_qt.part_name_field(), "text")

        print "-- a browser row SELECTED, which does not activate --"
        picked = qt_pick("dir", "src")
        print "  action: " + G.last_action + " | " + studio_qt_scrub(qt.read(win, studio_shell_qt.part_status(), "text"), G.app)

        print "-- New File, from the menu --"
        z = qt.invoke(win, qt_item("new-file"), "trigger")
        print "  action: " + G.last_action + " | " + studio_qt_scrub(qt.read(win, studio_shell_qt.part_status(), "text"), G.app)
        print "  the field was consumed: [" + qt.read(win, studio_shell_qt.part_name_field(), "text") + "]"

        print "-- Delete Selected still arms, and the arm is keyed to the file --"
        picked = qt_pick("file", "from_the_menu.bas")
        z = qt.invoke(win, qt_item("delete"), "trigger")
        print "  first:  " + G.last_action + " | " + studio_qt_scrub(qt.read(win, studio_shell_qt.part_status(), "text"), G.app)
        z = qt.invoke(win, qt_item("delete"), "trigger")
        print "  second: " + G.last_action + " | " + studio_qt_scrub(qt.read(win, studio_shell_qt.part_status(), "text"), G.app)

        print "-- the theme, which is a CHECKABLE action and not a glyph --"
        z = qt.invoke(win, qt_item("theme-dark"), "trigger")
        print "  action: " + G.last_action
        print "  dark checked:   " + string(qt.read(win, qt_item("theme-dark"), "checked"))
        print "  system checked: " + string(qt.read(win, qt_item("theme-system"), "checked"))
        print "  pressing it again is not a change:"
        z = qt.invoke(win, qt_item("theme-dark"), "trigger")
        print "    " + G.last_action

        print "-- the editor's text size, on the ladder --"
        for each a in ["text-bigger", "text-bigger", "text-smaller", "text-reset"]
            z = qt.invoke(win, qt_item(a), "trigger")
            print "  " + padto_qt(a, 14) + G.last_action + " " + G.last_detail
        end for

        print "-- Reload, which is about the FILES and not the window --"
        z = qt.invoke(win, qt_item("reload"), "trigger")
        print "  action: " + G.last_action

        print "-- Save with nothing open refuses by name --"
        z = qt.invoke(win, studio_shell_qt.part_save(), "click")
        print "  action: " + G.last_action + " | " + studio_qt_scrub(qt.read(win, studio_shell_qt.part_status(), "text"), G.app)

        print "-- Run says why it cannot, rather than running the wrong cell --"
        z = qt.invoke(win, "run_btn", "click")
        print "  " + qt.read(win, studio_shell_qt.part_status(), "text")

        print "-- Close Project, which had no toolbar button at all --"
        z = qt.invoke(win, qt_item("close-project"), "trigger")
        ' The project is CLOSED by now, so its name is out of the workspace and
        ' `studio_qt_scrub` can no longer find it -- the notice is taken while
        ' the name is still known instead.
        print "  action: " + G.last_action + " | " + replace(qt.read(win, studio_shell_qt.part_status(), "text"), G.last_detail, "(project)")
        print "  projects: " + string(count(G.app.model.workspace.projects))

        z = qt.close(win)
        return nothing
    end if

    ' THE RUN POLLER. gBASIC's own timer, which fires while `qt.run()` holds
    ' the thread -- measured, eight ticks of a 50ms timer delivered inside the
    ' loop, each one writing into the window. The GTK shell uses `gi.timeout`
    ' at the same rate and for the same reason, and only the FINAL tick of a
    ' run does a full redraw: a full redraw rebuilds the browser, and doing
    ' that sixteen times a second would fight the user for their own file tree.
    beat = timer.every(0.0625)
    watch(timer.ticks)
        while count(timer.ticks) > 0
            ev = take_first(timer.ticks)
            ' A WINDOW CAN CLOSE WITHOUT THE PROGRAM ASKING, so every verb
            ' starts refusing for a reason that is nobody's mistake. `is_open`
            ' is the question that answers where the others raise.
            if qt.is_open(G.win) then
                ' A FLAG AND NOT A QUERY. There is no `studio_ui.is_running` --
                ' I wrote one into this loop before checking, and it would have
                ' raised the first time a run started. The GTK shell has no such
                ' function either: its timer returns `active` and removes
                ' itself. A `timer.every` keeps ticking, so the flag is what
                ' stops the poller doing work between runs.
                if G.polling then
                    t = studio_ui.tick_run(G.app)
                    G.app = t.app
                    G.polling = t.active
                    if t.active then
                        ' Only the run widgets. A full redraw rebuilds the
                        ' browser, and doing that sixteen times a second would
                        ' fight the user for their own file tree.
                        G.app = studio_view_qt.render_run(G.win, G.app)
                    else
                        ' The FINAL tick does a full redraw, because that is
                        ' when the status line and the results pane change.
                        G.last_action = t.action
                        G.last_detail = t.detail
                        z = qt_redraw()
                    end if
                end if
                ' THE BUFFER SYNC, and it is a poll because a per-editor
                ' `textChanged` handler cannot be connected: gBASIC's reconcile
                ' builds a new child's widget through the same door `qt.open`
                ' uses and does NOT connect its handlers -- measured, and
                ' reported upstream. So the active editor's text is read and
                ' folded back through the one function the GTK buffer handler
                ' calls. The cost is a sync lag of one tick, not correctness.
                G.app = qt_sync_buffer(G.app)
            end if
        end while
    end watch

    rc = qt.run()
    ' The session is written on the way out, exactly as the GTK path writes it
    ' from `close-request`. Here the window has already gone, so the geometry
    ' had to be read before it did -- which is what `on <win>.closed` is for.
    saved = studio.shutdown(G.app)
    logged = studio_history.save(home, G.log)
    print "saved: " + join(saved, ", ")
    return nothing
end program

' ---------------------------------------------------------------------------
' Helpers. Top level and before `program`, because a function defined inside a
' program block AFTER the call to it is not hoisted.
' ---------------------------------------------------------------------------

function studio_qt_default_home()
    h = env("HOME")
    if is_string(h) then
        return h + "/.gbasic-studio"
    end if
    return ".gbasic-studio"
end function

' A project's own NAME out of a line, because this probe reaches its project
' through the real `studio.startup` + `adopt_folder` path -- which is what a
' user does -- and that names a project after the DIRECTORY it is in. The
' runner's fixture is a temp directory, so the name is a different string on
' every machine and in every tier.
'
' The tier reduces it rather than the probe printing less than it should, which
' is the rule `ui.bas`'s `safe_detail` and `app/studio.bas`'s `path_free`
' already follow: a golden's need to be path-free is not a reason to assert
' something weaker than what the window holds.
function studio_qt_scrub(line, app)
    ws = app.model.workspace
    if ws = nothing then
        return line
    end if
    out = line
    for each p in ws.projects
        if p.name != "" then
            out = replace(out, p.name, "(project)")
        end if
    end for
    return out
end function

' THE BUFFER SYNC. Read the active editor and fold what is there back into the
' model, through `studio_ui.sync_buffers` -- the same function the GTK buffer
' handler calls, so what an edit MEANS is one implementation.
'
' A POLL AND NOT A SIGNAL, because a per-editor `textChanged` cannot be
' connected: gBASIC's reconcile builds a new child's widget through the same
' door `qt.open` uses and does NOT connect its handler records -- measured, and
' reported upstream with the check that catches it. The cost is a sync lag of
' one tick.
'
' ONLY THE ACTIVE EDITOR, because that is the only one anybody can be typing
' into, and reading every open document's text sixteen times a second is a
' string copy per document per tick for nothing.
function qt_sync_buffer(app)
    doc = studio_docs.active_doc(app.dm)
    if doc = nothing then
        return app
    end if
    part = studio_shell_qt.part_editor(doc.id)
    have = qt.read(G.win, part, "plainText")
    if have = doc.content then
        return app
    end if
    r = studio_ui.sync_buffers(app, [ { doc_id: doc.id, text: have } ])
    app = r.app
    ' A FULL REDRAW ONLY WHEN THE DIRTY STATE MOVED, which is the one thing
    ' typing changes that the tab caption shows. `moved` is true only then --
    ' redrawing on every keystroke would rebuild the browser at typing rate.
    if r.moved then
        G.last_action = ""
        G.last_detail = ""
        z = qt_redraw()
    end if
    return app
end function

function padto_qt(text, width)
    out = text
    while count(out) < width
        out = out + " "
    end while
    return out
end function

' The browser row index of a kind and a name, read off the model's own rows --
' which is the array the dispatcher indexes, so a tier addressing a row this
' way addresses the same thing a click does.
function qt_row_of(kind, name)
    return studio_qt_row_index(studio_ui.nav_rows(G.app), kind, name)
end function

' Select a row by kind and name, and SAY SO when there is none.
'
' `qt.select` raises on an index of -1, correctly -- but a tier that dies there
' says nothing about the twelve presses after it, and "no such row" is itself a
' fact worth printing: it is what a fixture left dirty by an earlier run looks
' like. The GTK menu tier prints the same thing for the same reason.
function qt_pick(kind, name)
    at = qt_row_of(kind, name)
    if at < 0 then
        print "  (no browser row for " + kind + " " + name + ")"
        return false
    end if
    z = qt.select(G.win, studio_shell_qt.part_browser(), at)
    return true
end function

' Where a row of a given kind and name sits in the browser's row array.
'
' The array is the one `nav_rows` produced and nothing re-derives it, which is
' the invariant CLAUDE.md states: the renderer and the click dispatcher consume
' THE SAME array, because deriving rows twice desynchronises the moment the
' filesystem changes between a render and a click.
function studio_qt_row_index(rows, kind, name)
    i = 0
    for each r in rows
        if r.kind = kind then
            if r.name = name then
                return i
            end if
        end if
        i = i + 1
    end for
    return 0 - 1
end function

' The first line of a pane's text, for a golden that must not hold a path or a
' timestamp the body happens to carry further down.
function studio_qt_first_line(text)
    parts = split(text, chr(10))
    if count(parts) = 0 then
        return ""
    end if
    return parts[0]
end function
