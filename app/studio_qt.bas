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

' ---- the browser's right-click menu ---------------------------------------

' THE RIGHT-CLICK, which asks for the menu and does not act.
'
' `customContextMenuRequested` is the signal, and naming the handler is what
' ASKS for it: every widget starts at Qt's `DefaultContextMenu` policy, under
' which that signal is never emitted -- so gBASIC sets the policy when it sees
' the handler rather than making the request take two lines.
'
' MEASURED, A RIGHT-CLICK FIRES ONLY THIS. Not `itemClicked` and not
' `itemSelectionChanged`, so it cannot open the file it is about -- which is
' Studio's rule ("right-click SELECTS and does not activate") arriving from the
' toolkit rather than being enforced here.
'
' THE ROW IS REMEMBERED, because every item acts on the row that was clicked
' rather than on whatever is selected when the item is pressed. That is the same
' reason the GTK shell keeps `G.ctx_index`.
function on_qt_nav_context()
    idx = qt.selected(G.win, studio_shell_qt.part_browser())
    if is_unknown(idx) then
        return nothing
    end if
    G.ctx_index = idx
    rows = studio_ui.nav_rows(G.app)
    offered = studio_ui.context_actions(rows, idx)
    for each action in studio_ui.context_all()
        z = qt.set(G.win, studio_shell_qt.part_ctx(action), "visible",
                   contains(offered, action))
    end for
    ' AN EMPTY MENU IS NOT SHOWN, and Qt is what refuses: an all-hidden QMenu
    ' is `isEmpty()` and `popup()` leaves it invisible, so this answers false
    ' for a row that offers nothing -- which is an ordinary outcome and not a
    ' failure, exactly as the GTK `context_for` reports it.
    G.ctx_shown = qt.popup(G.win, studio_shell_qt.part_nav_menu())
    return nothing
end function

' The row the menu was raised on, or `nothing`.
function qt_ctx_row()
    rows = studio_ui.nav_rows(G.app)
    if G.ctx_index < 0 then
        return nothing
    end if
    if G.ctx_index >= count(rows) then
        return nothing
    end if
    return rows[G.ctx_index]
end function

function on_qt_ctx_open()
    r = qt_ctx_row()
    if r = nothing then
        return nothing
    end if
    res = studio_ui.activate_row(G.app, studio_ui.nav_rows(G.app), G.ctx_index)
    if res.action = "open" then
        qt_note("file_opened", r.path, "")
    end if
    return qt_took(res)
end function

function on_qt_ctx_new_file()
    return on_qt_new_file()
end function

function on_qt_ctx_new_folder()
    return on_qt_new_folder()
end function

' RENAME DOES NOT RENAME. It fills the header field with the current name and
' focuses it, because that field is where a name comes from and a second route
' to one is two places to get naming rules wrong. The item says "Rename…" for
' that reason.
function on_qt_ctx_rename()
    r = qt_ctx_row()
    if r = nothing then
        return nothing
    end if
    z = qt.write(G.win, studio_shell_qt.part_name_field(), r.name)
    ' FOCUS IT AND SELECT WHAT IS IN IT, so the next keystroke replaces the
    ' name rather than appending to it -- which is what the GTK handler's
    ' `grab_focus` + `select_region(0, -1)` does. `qt.select` is a TABLE's verb
    ' and raises on a field; `selectAll` is an ordinary zero-argument method,
    ' which is what `qt.invoke` passes.
    z = qt.invoke(G.win, studio_shell_qt.part_name_field(), "setFocus")
    z = qt.invoke(G.win, studio_shell_qt.part_name_field(), "selectAll")
    G.last_action = "rename-ready"
    G.last_detail = r.name
    return qt_redraw()
end function

function on_qt_ctx_delete()
    return on_qt_delete()
end function

' THE ITEM NAMES THE ROW IT CAME FROM, where the menu item in the header acts
' on the ACTIVE project -- because a right-click must not change which project
' you are in.
function on_qt_ctx_project_file()
    r = qt_ctx_row()
    if r = nothing then
        return nothing
    end if
    res = studio_ui.add_project_file(G.app, r.project_id)
    if res.action = "created" then
        qt_note("file_created", res.detail, "")
    end if
    return qt_took(res)
end function

function on_qt_ctx_close_project()
    r = qt_ctx_row()
    if r = nothing then
        return nothing
    end if
    return qt_took(studio_ui.close_project(G.app, r.project_id))
end function

' ---- the branch pane ------------------------------------------------------

' A BRANCH ROW CHOSEN. The rows are DATA that changes, which is why the pane is
' a table rather than a row of buttons -- the same argument the browser rests
' on, and `qt.selected` answers the index against the array that produced them.
function on_qt_branch_row()
    if G.redrawing then
        return nothing
    end if
    idx = qt.selected(G.win, studio_shell_qt.part_branches())
    if is_unknown(idx) then
        return nothing
    end if
    br = studio_ui.branch_rows(G.app)
    G.app = br.app
    ' The header field names a new branch the way it names a new file, which is
    ' what the `+` row reads.
    return qt_took(studio_ui.activate_branch_row(G.app, br.rows, idx, qt_typed_name()))
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
' WHERE THE CARET IS, in Studio's numbering.
'
' `qt.caret` answers `{ line, column, selecting }` and is ONE-BASED -- the same
' numbering `source_outline`, a parse diagnostic and `qt.mark` all use. Studio's
' own `run_section` and `sync_cursor` take ZERO-BASED coordinates (they add one
' internally, because the GTK editor's `cursor()` is a GtkTextBuffer position).
' So the minus one goes here, at the ONE place the two numberings meet, exactly
' as the plus one for the gutter lives at the one call site in
' `studio_view_qt._gutter`.
'
' `unknown` for a part that is not a text editor, and `nothing` when there is no
' document -- the welcome page has no editor to ask.
function qt_caret_now()
    doc = studio_docs.active_doc(G.app.dm)
    if doc = nothing then
        return nothing
    end if
    c = qt.caret(G.win, studio_shell_qt.part_editor(doc.id))
    if is_unknown(c) then
        return nothing
    end if
    return { line0: c.line - 1, column0: c.column - 1, sid: doc.id }
end function

' RUN, which is what this whole conversion was waiting for.
'
' It refused by name for four phases, and the refusal was right: the panes are
' caret-keyed (STU-5A'), so the strip names the section the caret is in and Run
' runs that one. `run_section(app, 0, 0)` would have resolved through
' `section_for`'s fall-through to the FIRST section -- a plausible wrong answer,
' which is worse than a refusal. gBASIC built `qt.caret` (its §0.32) and the
' sentence goes away.
'
' With no document there is no caret, and `run_section` is still the one that
' says so: it answers `none` for an empty document set, which reaches the status
' line by name like every other refusal here.
function on_qt_run()
    at = qt_caret_now()
    if at = nothing then
        return qt_took(studio_ui.run_section(G.app, 0, 0))
    end if
    r = studio_ui.run_section(G.app, at.line0, at.column0)
    G.polling = r.active
    return qt_took(r)
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

' NEW PROJECT OPENS A WINDOW, and the window is built ONCE and presented
' again on a second press -- minting a second set of parts over the same
' handlers is the doubling `ui_gui_solo` exists to catch one level up, and
' under Qt a second `qt.open` of the same name refuses by name anyway.
function on_qt_new_project()
    if qt_np_is_open() then
        return nothing
    end if
    ' THE SUBJECT HAS TO BE IN THIS FRAME, by the name the record declares --
    ' `qt.open` binds a `form to edit` out of the frame that calls it.
    opts = studio_ui.default_options(G.app, G.app.paths.home)
    G.npwin = qt_wire_newproj(studio_shell_qt.new_project_window(opts, studio_ui.license_ids()))
    z = qt.open(G.npwin)
    ' A `choice`'s own list, which is data rather than declaration -- the
    ' licences Studio actually SHIPS, so an id whose text is missing cannot be
    ' offered in the first place.
    z = qt.options(G.npwin, "license", studio_ui.license_ids())
    z = qt.write(G.npwin, "license", opts.license)
    return nothing
end function

' CREATE. `project_plan` decides and `create_project` acts, so a refused plan
' has touched nothing -- and the refusals are NAMED, each reaching this window's
' own note by name, so a New Project that will not go through says which field
' to change.
function on_qt_np_create()
    ' ONE VERB IS THE WHOLE WIDGET-TO-VALUE READ. The GTK shell walks eight
    ' widgets and maps a drop-down index back to a licence id; a `form to edit`
    ' binds the record and `qt.subject` hands it back.
    opts = qt.subject(G.npwin, studio_shell_qt.newproj_subject())
    r = studio_ui.create_project(G.app, opts)
    if r.action = "project-created" then
        G.app = r.app
        qt_note("project_created", r.detail, "")
        z = qt.close(G.npwin)
        G.last_action = r.action
        G.last_detail = r.detail
        return qt_redraw()
    end if
    ' REFUSED: the window stays open with what was typed still in it, and the
    ' reason goes in the note beside the fields rather than in a status line
    ' behind the window.
    z = qt.set(G.npwin, "np_note", "text", studio_ui.action_notice(r.action, r.detail))
    return nothing
end function

function on_qt_np_cancel()
    return qt.close(G.npwin)
end function

' Whether the New Project window is up.
'
' `qt.is_open` takes a window RECORD and refuses `nothing` -- correctly, there
' being no window to ask about -- so "has it ever been opened" is a separate
' question from "is it open", and conflating them raised on the FIRST press.
function qt_np_is_open()
    if G.npwin = nothing then
        return false
    end if
    return qt.is_open(G.npwin)
end function

function qt_wire_newproj(win)
    win = qt_on(win, "np_create", "clicked", on_qt_np_create)
    win = qt_on(win, "np_cancel", "clicked", on_qt_np_cancel)
    return win
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

' THE APPLICATION'S DARK SHEET. One call, and the only `qt.` verb in Studio
' that touches no part: `qt.theme` belongs to the QApplication, which is what
' makes it the counterpart of the display-wide GTK provider rather than of a
' per-widget one.
'
' "Follow the desktop" sets NO SHEET, which is the honest reading of the words
' under a toolkit that gives Studio no way to ask whether the desktop is dark
' -- see `studio_style.qt_dark_for`. Clearing is the same call with "", which
' gBASIC's own cookbook establishes.
' THE TOOLBAR'S LOOK, which is the one piece of chrome that follows the theme.
'
' NOT IN THE RENDERER, and not in `dress` either. Not `dress`, because that
' runs once and this changes when the theme does; not the renderer, because
' this is the one place in the Qt path that has to CATCH -- and a renderer that
' catches is how a window draws half of itself and says nothing, which is the
' rule CLAUDE.md states for exactly this.
'
' WHAT IT CATCHES is a build of Qt with no SVG support. Studio's dark icons are
' SVG, `qt.set` REFUSES a file Qt cannot read (measured: a malformed one comes
' back "is not an image Qt can read", with Qt's parser error on stderr), and
' `dark_icons_available` can only answer whether the FILE is there. So the
' refusal is the signal, and the fallback is the labels the toolbar wore before
' these icons existed -- five blank buttons being the one outcome worse than
' either.
function qt_apply_toolbar(app)
    theme = app.model.settings.theme
    style = studio_style.qt_tool_button_style(theme)
    ok = true
    on error goto next
    for each ti in studio_style.toolbar_icons()
        want = studio_style.toolbar_icon(ti.part, theme)
        if want != "" then
            z = qt.set(G.win, ti.part, "icon", want)
            if error then
                print to error "Studio (Qt): this Qt cannot read " + want + " — falling back to labels"
                error.clear()
                ok = false
            end if
        end if
    end for
    on error stop
    if not ok then
        style = 1
    end if
    z = qt.set(G.win, studio_shell_qt.part_toolbar(), "toolButtonStyle", style)
    return ok
end function

function qt_apply_theme(app)
    if studio_style.qt_dark_for(app.model.settings.theme) then
        return qt.theme(studio_style.dark_qss())
    end if
    return qt.theme("")
end function

' The two theme items. Each one is still an ADAPTER -- `studio_ui.set_theme`
' makes the decision and records it -- with the sheet applied after, because
' the setting is what the sheet is derived from.
'
' THE WHOLE WINDOW RE-THEMES, EDITORS INCLUDED, and the editors cost something
' to do it.
'
' `theme:` on a `source` is construction-only -- measured, `qt.set` refuses it
' by name -- so an open editor can only change colour by being REBUILT, which
' `studio_shell_qt.part_page_for` arranges by putting the theme in the page's
' name. The redraw that follows this press is what does it.
'
' WHAT THAT COSTS, said in the notice because it is the user's to notice: each
' open tab's caret and undo stack reset. Unsaved text does NOT -- Studio's
' model owns the buffer and `_tabs` writes it back wherever it differs, which
' is the same mechanism that fills a newly opened tab. The user was offered the
' alternative (chrome now, editors next launch, nothing lost) and chose this,
' because a light window around a dark editor is the STU-19 defect wearing the
' other shoe.
function qt_theme_to(name)
    r = studio_ui.set_theme(G.app, name)
    ' From `r.app` and not from `G`: the sheet is derived from the setting the
    ' decision just made, and `qt_took` below is what installs it on the global.
    themed = qt_apply_theme(r.app)
    ' The icons and the button style follow the sheet, because the stock ones
    ' are the thing the sheet cannot reach.
    barred = qt_apply_toolbar(r.app)
    if r.action = "theme-set" then
        r.detail = r.detail + " — open editors were rebuilt, so their undo history starts again"
    end if
    return qt_took(r)
end function

function on_qt_theme_system()
    return qt_theme_to("system")
end function

function on_qt_theme_dark()
    return qt_theme_to("dark")
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

' ---- closing --------------------------------------------------------------

' THE WINDOW IS CLOSING, AND THIS IS THE ONLY MOMENT ITS LAYOUT CAN BE READ.
'
' `on <win>.closed` fires BEFORE gBASIC forgets the window, which is what §0.17
' built it for: afterwards every verb refuses, correctly, because a window the
' person dismissed must not go on answering with the values it was showing.
' The GTK shell has the same problem and the same shape of answer -- it reads
' its geometry in `close-request`, because the loop returns only once the
' window is gone.
function on_qt_closed()
    if not qt.is_open(G.win) then
        return nothing
    end if
    w = qt.read(G.win, studio_shell_qt.window_name(), "width")
    h = qt.read(G.win, studio_shell_qt.window_name(), "height")
    session = G.app.model.session
    session.window.width = w
    session.window.height = h
    ' The whole arrangement, base64 -- see `studio_model.qt_layout_of` for why
    ' it is one opaque string and not a record of numbers.
    session.qt_layout = qt.layout(G.win)
    G.app.model.session = session
    return nothing
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
    win = qt_on(win, files, "customContextMenuRequested", on_qt_nav_context)
    win = qt_on(win, studio_shell_qt.part_branches(), "itemSelectionChanged", on_qt_branch_row)
    win = qt_on(win, studio_shell_qt.part_tabs(), "currentChanged", on_qt_tab_changed)
    ' SAVE IS A `QAction` ON THE TOOLBAR NOW, so its signal is `triggered`
    ' rather than `clicked` -- the part name is unchanged, which is what kept
    ' every other reference to it working.
    win = qt_on(win, studio_shell_qt.part_save(), "triggered", on_qt_save)
    win = qt_on(win, "tb_reload", "triggered", on_qt_reload)
    win = qt_on(win, "tb_open_folder", "triggered", on_qt_open_folder)
    win = qt_on(win, "tb_new_file", "triggered", on_qt_new_file)
    win = qt_on(win, "tb_new_folder", "triggered", on_qt_new_folder)
    win = qt_on(win, studio_shell_qt.window_name(), "closed", on_qt_closed)
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

    ' The browser's own menu. Every item dispatches to the SAME `studio_ui`
    ' function the header item does -- which is what keeps Delete armed from
    ' here, because a second implementation would quietly undo the two-click
    ' rule on the same file from a different control.
    win = qt_on(win, qt_ctx("open"), "triggered", on_qt_ctx_open)
    win = qt_on(win, qt_ctx("new-file-here"), "triggered", on_qt_ctx_new_file)
    win = qt_on(win, qt_ctx("new-folder-here"), "triggered", on_qt_ctx_new_folder)
    win = qt_on(win, qt_ctx("rename"), "triggered", on_qt_ctx_rename)
    win = qt_on(win, qt_ctx("delete"), "triggered", on_qt_ctx_delete)
    win = qt_on(win, qt_ctx("project-file"), "triggered", on_qt_ctx_project_file)
    win = qt_on(win, qt_ctx("close-project"), "triggered", on_qt_ctx_close_project)
    return win
end function

function qt_ctx(action)
    return studio_shell_qt.part_ctx(action)
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

    ' `launch`, NOT `startup` -- and getting this wrong meant the Qt window had
    ' never once opened on a home that had been used before. `startup` is the
    ' STU-0 model load; `launch` is that plus the live document manager, the
    ' restored drafts and the viewer registry. `app.dm` was reaching this entry
    ' point only as a SIDE EFFECT of `create_registered_workspace`, which
    ' `startup` calls only when there is no workspace yet -- so every one of the
    ' Qt tiers, each building an empty home, had a document manager by accident,
    ' and the first real home raised `unknown record field: dm` out of
    ' `studio_ui.tab_rows` before the window was built. The GTK entry has called
    ' `launch` since STU-2.
    app = studio.launch(home)

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
          ' The browser row a right-click was raised on, and whether the menu
          ' actually appeared. Every item acts on THAT row rather than on
          ' whatever is selected when the item is pressed.
          ctx_index: 0 - 1, ctx_shown: false,
          ' The New Project window, which is a SECOND ordinary window rather
          ' than a modal one -- see `studio_shell_qt.new_project_window`.
          npwin: nothing,
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
    ' THE BRANCH PANE'S SUBJECT, bound at open for the same reason `nav` is:
    ' `qt.open` reads a `table to show` out of the frame that calls it and
    ' refuses the whole window when the variable is not there.
    branches = []
    for each br in studio_ui.branch_rows(G.app).rows
        branches = append(branches, { line: studio_ui.branch_line(br) })
    end for
    ' THEMED BEFORE IT OPENS. `qt.theme` needs no display and is remembered
    ' until there is a QApplication to put it on, which is upstream's stated
    ' reason for that design: refusing until a window existed would make the
    ' first window appear unthemed and then change under the user.
    themed = qt_apply_theme(G.app)
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
    barred = qt_apply_toolbar(G.app)

    ' THE LAYOUT THE USER LAST LEFT, restored whole.
    '
    ' This replaces the three divider numbers the GTK shell stores, and it is a
    ' strictly larger thing: `QMainWindow` saves which dock is at which edge,
    ' which are tabbed together, which are closed or floating, and every size.
    ' A `Gtk.Paned` could offer one number per divider and nothing about
    ' arrangement, which is why dragging a dock somewhere useful was never
    ' something Studio could remember.
    '
    ' A BLOB IT DOES NOT RECOGNISE IS REPORTED, NOT RAISED -- `qt.restore_layout`
    ' answers false, which is exactly what a launch meets after the window's
    ' own declaration changed. Losing a saved arrangement is not worth stopping
    ' a program for, so this is noted on stderr and nothing else.
    saved_layout = studio_model.qt_layout_of(G.app.model.session)
    if saved_layout != "" then
        took = qt.restore_layout(win, saved_layout)
        if not took then
            print to error "Studio (Qt): the saved window layout was not recognised — starting from the declaration"
        end if
    end if

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
        ' THE BRANCH PANE IS A TABLE now, so there is no body to read: its
        ' rows are what it holds, and a row is `studio_ui.branch_line`.
        print "  branches: " + string(qt_branch_cells(win))
        print "  tables:   [" + studio_qt_first_line(qt.read(win, "tables_body", "plainText")) + "]"
        print "  git:      [" + qt.read(win, "git_body", "plainText") + "]"
        print "  dark is checked: " + string(qt.read(win, studio_shell_qt.part_item("theme-dark"), "checked"))

        print "-- the furniture: which EDGE did each dock land on? --"
        ' ASKED OF THE WINDOW (`dockWidgetArea`) rather than of anything we
        ' remembered when the pane was built -- which is the rule `qt.at` and
        ' `qt.pane` already follow, and it is load-bearing here: a pane in the
        ' wrong area is INVISIBLE from the language otherwise, since every part
        ' inside it reads back by name whichever edge it ended up on and
        ' `visible` is true either way.
        print "  " + padto_qt("files", 10) + qt.dock(win, studio_shell_qt.part_browser_dock()).area
        print "  " + padto_qt("console", 10) + qt.dock(win, studio_shell_qt.part_console_dock()).area
        for each sp in studio_shell_qt.side_panes()
            d = qt.dock(win, studio_shell_qt.part_side_dock(sp.id))
            print "  " + padto_qt(sp.id, 10) + d.area + ", tabbed with " + string(d.tabbed_with)
        end for
        print "  (Qt TABS the docks sharing an edge, which is what stops the"
        print "   last of five panes sitting below the fold)"
        print "-- and the toolbar's items are QActions with real icons --"
        for each ti in [studio_shell_qt.part_save(), "tb_reload", "tb_open_folder", "tb_new_file", "tb_new_folder"]
            print "  " + padto_qt(ti, 16) + "icon=" + string(qt.has_icon(win, ti))
        end for
        print "-- the layout round-trips, which is what a dragged dock needs --"
        blob = qt.layout(win)
        print "  saved:    " + string(count(blob) > 0) + " (base64, because the blob is not UTF-8)"
        print "  restored: " + string(qt.restore_layout(win, blob))
        print "  a blob it does not know is REPORTED, not raised: " + string(qt.restore_layout(win, "bm90aGluZw=="))

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
        ' THE BRANCH PANE POPULATES once there is a section to branch at --
        ' cold it is empty, because a branch point is a section and there was
        ' no document. `*` is the selected one and `+` is the row that makes a
        ' new one, which is why this pane had to be a table and not a memo.
        print "  branches:       " + string(qt_branch_cells(win))
        z = qt.select(win, studio_shell_qt.part_branches(), 0)
        print "  chose Baseline: " + G.last_action

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

    ' A SECOND LAUNCH OVER A HOME THAT HAS BEEN USED, which is the one state
    ' every other tier here skips -- and the state in which this entry point
    ' did not work at all.
    '
    ' All thirteen Qt tiers `rm -rf` their home first, so all thirteen were
    ' testing a FIRST launch. `app.dm` was reaching this program only as a side
    ' effect of `create_registered_workspace`, which `studio.startup` calls
    ' only when there is no workspace yet, so an empty home got a document
    ' manager by accident and a real one got none: `unknown record field: dm`
    ' out of `studio_ui.tab_rows`, before the window was even built. Reported
    ' by the user, who was the first person ever to open Studio twice.
    '
    ' SO THIS MODE PERSISTS ON ITS WAY OUT, and the tier runs it TWICE against
    ' one home. The second run is the assertion; the first exists to leave
    ' something behind for it to find.
    if mode = "reopen" then
        print "-- the home as it arrived --"
        print "  workspace present:  " + string(G.app.model.workspace != nothing)
        print "  documents restored: " + string(count(G.app.dm.docs))
        print "-- the window, built from that model --"
        print "  opened:   " + string(qt.is_open(win))
        print "  tabs:     " + string(qt.tabs(win, studio_shell_qt.part_tabs()))
        print "  title:    " + studio_qt_scrub(qt.read(win, studio_shell_qt.window_name(), "windowTitle"), G.app)
        print "  rows:     " + string(count(studio_ui.nav_rows(G.app)))

        ' OPEN ONE FILE, so the next launch has a document to restore and the
        ' `_reload_docs` half is exercised rather than assumed.
        rows = studio_ui.nav_rows(G.app)
        at = studio_qt_row_index(rows, "file", "main.bas")
        if at >= 0 then
            r = studio_ui.activate_row(G.app, rows, at)
            G.app = r.app
            nav = studio_ui.nav_rows(G.app)
            G.app = studio_view_qt.render(win, G.app, "")
            print "-- with main.bas open --"
            print "  action:   " + r.action
            print "  tabs:     " + string(qt.tabs(win, studio_shell_qt.part_tabs()))
            doc = studio_docs.active_doc(G.app.dm)
            ed = studio_shell_qt.part_editor(doc.id)
            print "  gutter:   " + string(qt.gutter(win, ed).line_numbers)
            print "  language: " + qt.highlighting(win, ed).language
        end if

        ' THE THEME, which is the other half of what the user reported. The
        ' sheet is the application's and needs no part to ask about.
        print "-- the application's own sheet --"
        print "  setting:      " + studio_ui.theme_of(G.app)
        print "  dark applied: " + string(len(qt.theme()) > 0)
        ' AND THE WHOLE LOOP, pressed rather than reasoned about: the menu item
        ' goes through the same `qt_theme_to` a click calls, the sheet lands on
        ' the QApplication, the setting is written, and the SECOND run of this
        ' mode starts dark -- which is what makes "the theme does nothing" a
        ' thing a tier can catch next time.
        '
        ' What is NOT asserted is how it looks. A wrong Qt selector is ignored
        ' in silence exactly as a wrong GTK node name is, so this says the
        ' sheet is set and is the one we meant, and no more than that.
        pressed = qt_theme_to("dark")
        print "  after Dark:   " + G.last_action + " — " + G.last_detail
        print "  sheet set:    " + string(len(qt.theme()) > 0)
        print "  it is OURS:   " + string(contains(qt.theme(), studio_style.dark_bg()))
        print "  editor would be built: " + studio_style.qt_source_theme(studio_ui.theme_of(G.app))
        print "  toolbar style:        " + string(qt.read(win, studio_shell_qt.part_toolbar(), "toolButtonStyle"))
        print "  every toolbar icon arrived: " + string(qt_all_icons(win))
        ' AND THE REBUILT EDITOR, which is the load-bearing half. Pressing Dark
        ' renames every page, so `qt.refresh` builds a new `source` -- and the
        ' three things that must survive that are the text (written back from
        ' the model), the margin (a construction option, so it has to be in the
        ' rebuilt record) and the highlighter. An editor that came back empty
        ' or without its gutter would be the reconcile defect this conversion
        ' already met once, arriving through the theme.
        if at >= 0 then
            doc2 = studio_docs.active_doc(G.app.dm)
            ed2 = studio_shell_qt.part_editor(doc2.id)
            print "  after the rebuild, the editor still holds its text: " + string(len(qt.read(win, ed2, "plainText")) > 0)
            print "  ... its margin:    " + string(qt.gutter(win, ed2).line_numbers)
            print "  ... its language:  " + qt.highlighting(win, ed2).language
        end if

        ' AND BOTH WAYS. A theme that only goes dark is half a control, and the
        ' toolbar's icons have to come BACK under "Follow the desktop" -- there
        ' is no sheet then, the palette is the platform's, and an icon is the
        ' better affordance when it can be seen.
        print "-- and Follow the desktop puts it all back --"
        back = qt_theme_to("system")
        print "  action:        " + G.last_action
        print "  sheet cleared: " + string(len(qt.theme()) = 0)
        print "  toolbar style: " + string(qt.read(win, studio_shell_qt.part_toolbar(), "toolButtonStyle"))
        print "  every icon arrived: " + string(qt_all_icons(win))
        print "  editor built:  " + studio_style.qt_source_theme(studio_ui.theme_of(G.app))
        ' Back to dark, so the NEXT launch of this mode starts themed -- which
        ' is what the second block of this tier's golden asserts.
        again = qt_theme_to("dark")
        print "  and back to dark for the next launch: " + G.last_action

        z = qt.close(win)
        ' PERSISTED, unlike `probe` and `press`, because the whole point of
        ' this mode is what the NEXT launch finds -- and `persist`, not
        ' `shutdown`, for the reason the exit path below now states.
        saved = studio.persist(G.app)
        print "  persisted:    " + string(count(saved) > 0)
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
        z = qt.invoke(win, studio_shell_qt.part_save(), "trigger")
        print "  action: " + G.last_action + " | " + studio_qt_scrub(qt.read(win, studio_shell_qt.part_status(), "text"), G.app)

        ' RUN, PRESSED FOR REAL, WITH THE CARET DECIDING WHICH SECTION.
        '
        ' This replaces four phases of a refusal. The claim worth asserting is
        ' not "a run happened" -- it is that the caret is what CHOSE, so the
        ' caret goes somewhere specific first and the strip is read back to see
        ' that it names the section the caret is in. `run_section(app, 0, 0)`
        ' would have answered the FIRST section whatever the caret said, which
        ' is exactly the plausible wrong answer the refusal existed to avoid.
        print "-- Run, and the CARET is what picks the section --"
        z = qt.invoke(win, studio_shell_qt.part_item("new-file"), "trigger")
        rows = studio_ui.nav_rows(G.app)
        atf = studio_qt_row_index(rows, "file", "main.bas")
        if atf >= 0 then
            ro = studio_ui.activate_row(G.app, rows, atf)
            G.app = ro.app
            nav = studio_ui.nav_rows(G.app)
            G.app = studio_view_qt.render(win, G.app, "")
        end if
        rdoc = studio_docs.active_doc(G.app.dm)
        red = studio_shell_qt.part_editor(rdoc.id)
        ' Two sections, so "which one" is a question with a wrong answer.
        G.app.dm = studio_docs.edit(G.app.dm, rdoc.id,
            "function one()" + chr(10) + "  return 1" + chr(10) + "end function" + chr(10) +
            chr(10) +
            "function two()" + chr(10) + "  return 2" + chr(10) + "end function" + chr(10))
        nav = studio_ui.nav_rows(G.app)
        G.app = studio_view_qt.render(win, G.app, "")
        z = qt.caret_to(win, red, 1, 1)
        G.app = qt_sync_caret(G.app)
        print "  caret at line 1 — strip says: " + qt.read(win, "run_section", "text")
        z = qt.caret_to(win, red, 6, 3)
        G.app = qt_sync_caret(G.app)
        print "  caret at line 6 — strip says: " + qt.read(win, "run_section", "text")
        c = qt.caret(win, red)
        print "  and the caret reads back 1-based: line=" + string(c.line) + " column=" + string(c.column) + " selecting=" + string(c.selecting)
        z = qt.invoke(win, "run_btn", "click")
        print "  Run answered: " + G.last_action + " (" + G.last_detail + ")"
        print "  status: " + studio_qt_scrub(qt.read(win, studio_shell_qt.part_status(), "text"), G.app)
        ' A LINE PAST THE END IS REFUSED, naming the real length -- which is
        ' what makes `qt.caret_to` safe to drive from a diagnostic, and why
        ' `qt_go_to_stopped` checks the length rather than catching.
        on error goto next
        z = qt.caret_to(win, red, 999, 1)
        if error then
            print "  a line past the end is refused, as it should be"
            error.clear()
        else
            print "  a line past the end was ACCEPTED, which it should not be"
        end if
        on error stop
        ' STOPPED, so the tier leaves no child behind it. A run launched and
        ' abandoned is a process outliving the test that made it, and this mode
        ' has no poller to finish it.
        z = qt.invoke(win, "stop_btn", "click")
        print "  stopped: " + G.last_action

        print "-- the browser's own right-click menu, per row --"
        ' `qt.right_click` cannot aim at a TREE row (its third argument is a
        ' table's), so the row is selected first and the click lands on the
        ' part. In a real window the press itself moves the current item, which
        ' is what §0.20 measured for a table -- so this drives the menu path
        ' faithfully and only the aiming is simulated.
        for each want in ["file", "dir", "project", "info"]
            at = qt_row_of_kind(want)
            if at < 0 then
                print "  " + padto_qt(want, 8) + "(no such row)"
            else
                z = qt.select(win, studio_shell_qt.part_browser(), at)
                z = qt.right_click(win, studio_shell_qt.part_browser())
                print "  " + padto_qt(want, 8) + "shown=" + string(G.ctx_shown) + " offers: " + join(studio_ui.context_actions(studio_ui.nav_rows(G.app), G.ctx_index), ", ")
                z = qt.invoke(win, studio_shell_qt.part_nav_menu(), "hide")
            end if
        end for
        print "  (an all-hidden menu is not shown, which is Qt refusing rather"
        print "   than us: an empty one reads as a control that failed)"

        print "-- Rename from that menu FILLS the field and does not rename --"
        ' THE ASSERTION IS A RELATIONSHIP, NOT A FILENAME, and the first
        ' version of it was neither. `qt.right_click` cannot aim at a tree row,
        ' so the click lands at a point in the widget and whatever row is under
        ' that point becomes the one the menu was raised on -- which means the
        ' row depends on ROW HEIGHT. This golden held `README.md` for one
        ' reason only: that was the row the point hit with Qt's default item
        ' metrics. Adding `QTreeView::item { padding: 2px; }` to Studio's dark
        ' sheet moved it to `b.bas`, and a tier whose expected value moves when
        ' a stylesheet changes padding is asserting the wrong thing.
        '
        ' So it reports the row the menu WAS raised on, and the field beside
        ' it. The invariant is that they are the same row -- which is the whole
        ' claim ("Rename fills the field with the row you right-clicked") and
        ' is true at any row height.
        at = qt_row_of_kind("file")
        z = qt.select(win, studio_shell_qt.part_browser(), at)
        z = qt.right_click(win, studio_shell_qt.part_browser())
        raised = qt_ctx_row()
        z = qt.invoke(win, qt_ctx("rename"), "trigger")
        filled = qt.read(win, studio_shell_qt.part_name_field(), "text")
        print "  action: " + G.last_action
        print "  raised on a " + raised.kind + ", and the field holds that row: " + string(filled = raised.name)
        print "  field is a file in the project: " + string(contains(filled, ".") and filled != "")

        print "-- New Project opens its own window, filled and pressed for real --"
        z = qt.invoke(win, qt_item("new-project"), "trigger")
        print "  open:     " + string(qt_np_is_open())
        print "  name:     [" + qt.read(G.npwin, "name", "text") + "]"
        print "  main.bas ticked by default: " + string(qt.read(G.npwin, "main", "checked"))
        print "  .gstudio.json is NOT:       " + string(qt.read(G.npwin, "projfile", "checked"))
        print "  (a box you had to untick is not consent)"
        print "  a second press presents the one that is open, not a second:"
        z = qt.invoke(win, qt_item("new-project"), "trigger")
        print "    still one window: " + string(qt_np_is_open())

        print "-- a refusal keeps the window open, with what was typed in it --"
        z = qt.write(G.npwin, "name", "")
        z = qt.invoke(G.npwin, "np_create", "click")
        print "  note:     " + qt.read(G.npwin, "np_note", "text")
        print "  open:     " + string(qt_np_is_open())

        print "-- and a licence with no author refuses by its own name --"
        ' MIT, not Apache: those two are the only ids whose LICENSE text names
        ' a copyright holder in the file itself, so they are the two that can
        ' refuse for want of one. And the id is written as a VALUE rather than
        ' an index -- `qt.write` refuses one that is not in the choice's list
        ' by name, so a licence Studio does not ship cannot be chosen at all,
        ' where the GTK window maps a drop-down index back through `_index_of`.
        z = qt.write(G.npwin, "name", "A Fine Project")
        z = qt.write(G.npwin, "author", "")
        z = qt.write(G.npwin, "license", "MIT")
        z = qt.invoke(G.npwin, "np_create", "click")
        print "  note:     " + qt.read(G.npwin, "np_note", "text")

        print "-- filled in properly, Create makes the project --"
        z = qt.write(G.npwin, "author", "A Person")
        z = qt.write(G.npwin, "license", "none")
        z = qt.invoke(G.npwin, "np_create", "click")
        print "  action:   " + G.last_action
        print "  window:   " + string(qt_np_is_open()) + " (closed on success)"
        print "  projects: " + string(count(G.app.model.workspace.projects))

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
                        ' A Run All that stopped part way: put the caret on the
                        ' line it stopped at, so the panes -- which follow the
                        ' caret -- are showing the failure by the time the
                        ' status line names it.
                        if t.action = "ran-stopped" then
                            went = qt_go_to_stopped(t.detail)
                        end if
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
                ' AND THE CARET, which the panes are keyed to. Polled for the
                ' same reason the buffer is, and cheap: a read and two integer
                ' comparisons when it has not moved.
                G.app = qt_sync_caret(G.app)
            end if
        end while
    end watch

    rc = qt.run()
    ' CANCEL THE BEAT, OR THE PROCESS NEVER EXITS. A `timer.every` is a live
    ' source in gBASIC's own event loop, and that loop outlives `program`: with
    ' the timer still registered the interpreter sat at 2% CPU forever after
    ' this block returned -- the window gone, the session already saved, and
    ' every `print` below lost in an unflushed stdout buffer, so a terminal
    ' showed NOTHING. Measured both ways: uncancelled, exit 124 with no output;
    ' cancelled, exit 0 with all of it. Found by the user leaving the window
    ' open and closing it, which no tier does -- gBASIC's own two Qt lifecycle
    ' fixtures both cancel, and I copied the timer without the cancel.
    beat_off = timer.cancel(beat)
    ' The session is written on the way out, exactly as the GTK path writes it
    ' from `close-request`. Here the window has already gone by the time
    ' `qt.run()` returns, so anything that has to be read off it is read in the
    ' `closed` handler -- which is what §0.17 built that handler for.
    ' `persist`, NOT `shutdown`, and this was the same mistake as `startup`
    ' versus `launch` one line of this program apart. `shutdown` is the STU-0
    ' writer: it copies the workspace into the session and writes two files.
    ' `persist` is what closing a window MEANS -- it folds the live document
    ' manager back into the workspace (`_sync_docs`), captures the unsaved
    ' buffers as drafts, and writes the active project's anchors, branches and
    ' overlays out of `app.pstate` -- and then calls `shutdown` itself.
    '
    ' So under Qt, closing the window was dropping the open tab set, every
    ' unsaved buffer, and every section anchor. The last of those is the worst:
    ' anchors are what keep a result attached to the section it came from
    ' across an edit, and a state rebuilt from scratch numbers sections in FILE
    ' order -- which is the STU-3 misattribution, re-entering through the exit
    ' path. `app/studio.bas` has called `persist` here since STU-2.
    saved = studio.persist(G.app)
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
' A WHOLE-FILE RUN THAT STOPPED: GO THERE, rather than ask.
'
' `ran-stopped` carries the DOCUMENT LINE, and its notice has read "stopped at
' line 7 — put the caret there to see why" since STU-14. That sentence exists
' because the panes are caret-keyed and a failed Run All moves the result out
' from under the caret, so the Errors pane says "(none)" about a run that
' plainly failed. Telling the user to go there was the best Studio could do
' with no way to move the caret; `qt.caret_to` (gBASIC §0.32) means it can
' simply go.
'
' CHECKED, NOT CAUGHT. `qt.caret_to` REFUSES a line past the end -- naming the
' document's real length, deliberately, because a program placing the caret
' where a diagnostic said is working from a model and clamping would put it on
' the wrong line and look like it worked. That refusal is right and Studio
' should never provoke it: the line comes from the child's diagnostics mapped
' back through `text_map`, and a document edited since the run started could be
' shorter. So the length is checked here against the model, and a line past the
' end leaves the caret alone and lets the status line say what it always said.
function qt_go_to_stopped(detail)
    doc = studio_docs.active_doc(G.app.dm)
    if doc = nothing then
        return false
    end if
    ln = number(detail)
    if ln < 1 then
        return false
    end if
    if ln > count(split(doc.content, chr(10))) then
        return false
    end if
    z = qt.caret_to(G.win, studio_shell_qt.part_editor(doc.id), ln, 1)
    ' The model follows the widget, or the next poll would read the new caret,
    ' decide it moved, and redraw a second time for nothing.
    r = studio_ui.sync_cursor(G.app, doc.id, ln - 1, 0)
    G.app = r.app
    return true
end function

' THE PANES FOLLOW THE CARET, which is STU-5A' and is what makes Run's answer
' predictable: the strip says which section Run will run BEFORE it is pressed.
'
' A POLL, like the buffer sync beside it and for the same reason -- a per-editor
' signal cannot be connected, because gBASIC's reconcile builds a new child's
' widget without connecting its handler records. The GTK shell gets
' `notify::cursor-position` and calls `sync_cursor`; here the caret is read on
' the tick and handed to the same function.
'
' CHEAP PATH ONLY. `sync_cursor` answers `changed` when the caret crossed INTO a
' different section, and only then is there anything to redraw -- `render_run`
' and not a full redraw, because rebuilding the browser at arrow-key rate would
' fight the user for their own file tree. That is the rule `pane_redraw`
' already follows on the GTK side.
'
' The history gets the crossing and not the keystroke, for the reason
' `on_cursor_moved` states: one event per arrow key would drown the log.
function qt_sync_caret(app)
    doc = studio_docs.active_doc(app.dm)
    if doc = nothing then
        return app
    end if
    c = qt.caret(G.win, studio_shell_qt.part_editor(doc.id))
    if is_unknown(c) then
        return app
    end if
    ' Nothing to do when it has not moved. `doc.cursor` is what `set_cursor`
    ' last stored, in Studio's 1-based document coordinates.
    if doc.cursor.line = c.line then
        if doc.cursor.column = c.column then
            return app
        end if
    end if
    r = studio_ui.sync_cursor(app, doc.id, c.line - 1, c.column - 1)
    app = r.app
    if r.changed then
        qt_note("section_selected", r.detail, "")
        app = studio_view_qt.render_run(G.win, app)
    end if
    return app
end function

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

' Every row the branch table is holding, read back off the widget.
function qt_branch_cells(win)
    out = []
    i = 0
    for each r in studio_ui.branch_rows(G.app).rows
        out = append(out, qt.cell(win, studio_shell_qt.part_branches(), i, "line"))
        i = i + 1
    end for
    return out
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
' The first row of a given KIND, whatever it is called -- so a tier can ask for
' "a directory" without knowing the fixture's names.
function qt_row_of_kind(kind)
    i = 0
    for each r in studio_ui.nav_rows(G.app)
        if r.kind = kind then
            return i
        end if
        i = i + 1
    end for
    return 0 - 1
end function

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
' Whether every toolbar item has an icon on it.
'
' `qt.has_icon` is the ONLY way to ask -- `qt.read(win, part, "icon")` refuses
' by name ("an icon has no text form"), which is right: a QIcon is an object
' and there is nothing truthful to render as a string. That refusal is also
' why this is the assertion a tier can make and "is it the RIGHT icon" is not.
' What it does catch is the failure that actually happened: a dark theme whose
' icons are drawn from a palette, present and invisible.
function qt_all_icons(win)
    for each ti in studio_style.toolbar_icons()
        if not qt.has_icon(win, ti.part) then
            return false
        end if
    end for
    return true
end function

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
