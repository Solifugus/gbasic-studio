' ============================================================================
' studio.bas — gBASIC Studio entry point (STU-0 skeleton).
'
' STU-0 delivers the persistent BACKBONE, not an editor: launch Studio, create /
' open a workspace, close, relaunch, and find the working context restored. The
' domain model + persistence live in the stdlib studio_* libraries (headless and
' fully testable); this program is the thin entry point that runs the lifecycle
' and, in the display modes, mounts the shell view over the model.
'
' Modes (first program argument), so the backbone is headless-testable:
'   startup   <home>       — run the startup pipeline, print the model summary
'   build     <home>       — startup, build a canned workspace, shut down (persist)
'   roundtrip <home>       — build + shut down + relaunch; print restored summary
'   stress    <home>       — repeated atomic save/reload; assert every reload loads
'   cycles    <home>       — 50 startup/shutdown cycles (memory/leak probe)
'   smoke                  — build the GTK shell over a canned workspace, quit
'   (default) gui          — startup + shell + run the GTK loop (needs a display)
'
' RUN (needs GTK4 typelib + a display for gui/smoke):
'   GBASIC_PATH=stdlib ./gbasic examples/studio/studio.bas gui ~/.gbasic-studio
' ============================================================================

' Build a fixed, deterministic workspace (stable ids from the counters) so the
' save/restore and shell modes have identical, assertable state every run.
function build_canned(app)
    app = studio.create_workspace(app, "member-analytics")
    ws = app.model.workspace
    ws = studio_model.add_project(ws, "Analytics", "/home/u/analytics")
    ws = studio_model.open_document(ws, "proj-1", "/home/u/analytics/load.bas")
    ws = studio_model.open_document(ws, "proj-1", "/home/u/analytics/report.bas")
    app = studio.set_workspace(app, ws)

    session = app.model.session
    session = studio_model.set_window(session, 1024, 768, true)
    session = studio_model.touch_recent(session, "/home/u/analytics/load.bas", 10)
    m = app.model
    m.session = session
    app.model = m
    return app
end function

' Build a fixed STU-1 workspace over a real project directory (created by the test
' harness) plus a deliberately-missing second project, with a canned expansion and
' selection — so navigation save/restore and the browser are deterministic.
function build_stu1(app, projdir)
    app = studio.create_registered_workspace(app, "myws")
    ws = app.model.workspace
    ws = studio_model.add_project(ws, "Alpha", projdir)
    ws = studio_model.add_project(ws, "Beta", projdir + "/ghost")
    ws = studio_model.expand_path(ws, projdir + "/src")
    ws = studio_model.set_selected_path(ws, projdir + "/main.bas")
    app = studio.set_workspace(app, ws)
    return app
end function

' ============================================================================
' STU-2B — input handlers.
'
' Every function in this block is an ADAPTER, and the shape is always the same:
'   1. pull ONE plain value out of the widget (an index, a page number, a string)
'   2. call ONE studio_ui function with it
'   3. store the returned app and ask for a redraw
'
' There are no decisions here. What a click MEANS is decided in studio_ui, which
' is ordinary gBASIC a headless test calls directly (tests/drivers/ui.bas). That
' split is the point: what is left in a handler is too small to hide a bug in.
' If logic ever appears below, it has escaped its test coverage.
'
' Handlers mutate FIELDS of the global G rather than rebinding it, because a
' callback cannot rebind a top-level scalar.
' ============================================================================

' The single redraw path. Every handler ends here.
'
' `G.redrawing` guards re-entry, and it is not optional: refreshing the notebook
' calls set_current_page, which synchronously emits "switch-page", which would
' re-enter the tab handler and mutate the model mid-redraw. Reloading a document
' from disk likewise sets buffer text, which emits "changed". Both are OUR writes
' being echoed back, not user input, and must not be mistaken for it.
function redraw()
    if G.redrawing then
        return nothing
    end if
    G.redrawing = true
    ' STU-2D. Three decisions, all of them studio_ui's: what the status bar says
    ' about the last outcome, whether the name field has been consumed, and which
    ' pending confirmation (if any) survives. Clearing the arms HERE rather than
    ' in each handler is what stops one from outliving an unrelated click and
    ' firing later against a selection the user has long since moved.
    notice = studio_ui.action_notice(G.last_action, G.last_detail)
    clear_name = studio_ui.clears_name(G.last_action)
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
    r = studio_shell.refresh(G.shell, G.app, notice, clear_name)
    G.shell = r.shell
    ' The app comes back because rendering the panes populates a cache on it
    ' (studio_ui.view_for). Dropping it would re-parse the document every render.
    G.app = r.app
    ' A redraw can create pages, and a new page's buffer has never been wired.
    ' This is the only place editors are connected, so no page can exist unwired.
    for each ne in r.new_editors
        ed = ne.editor
        gi.connect(ed.buffer, "changed", on_buffer_changed)
        ' "notify::cursor-position" fires ONCE per caret move; "mark-set" fires
        ' twice (insert and selection_bound), which would double every refresh.
        gi.connect(ed.buffer, "notify::cursor-position", on_cursor_moved)
    end for
    G.redrawing = false
    ' STU-10: a teaching cue is drawn AFTER the redraw, and outside the
    ' re-entrancy guard. It touches widgets the redraw has just rebuilt, and
    ' drawing it inside would point at a pane the reconciler is about to replace.
    draw_cue()
    return nothing
end function

' STU-6: append one semantic event. A handler naming its own event kind is not a
' decision — it IS the handler's identity — and the vocabulary is closed, so a
' typo raises here rather than becoming a category nobody can query.
function note_event(kind, target, detail)
    G.log = studio_history.note(G.log, kind, target, detail, epoch())
    return nothing
end function

' A browser row was activated (single click — GtkListBox activates on single
' click by default). Extract the row's index; the rows the view rendered decide
' what that index means.
function on_nav_row_activated(box, row)
    idx = row.get_index()
    r = studio_ui.activate_row(G.app, G.shell.rows, idx)
    G.app = r.app
    G.last_action = r.action
    G.last_detail = r.detail
    if r.action = "open" then
        note_event("file_opened", G.shell.rows[idx].path, "")
    end if
    if r.action = "project" then
        note_event("project_opened", G.shell.rows[idx].path, G.shell.rows[idx].label)
    end if
    redraw()
    return nothing
end function

' The notebook switched page — either the user clicked a tab, or we just called
' set_current_page during a redraw. The guard tells the two apart.
function on_tab_switched(book, page, num)
    if G.redrawing then
        return nothing
    end if
    r = studio_ui.select_tab(G.app, studio_ui.tab_rows(G.app), num)
    G.app = r.app
    G.last_action = r.action
    G.last_detail = r.detail
    redraw()
    return nothing
end function

' An editor buffer changed. Hand every open page's text over; studio_ui decides
' which documents actually moved.
function on_buffer_changed(buffer)
    if G.redrawing then
        return nothing
    end if
    buffers = []
    for each pg in G.shell.pages
        ed = pg.editor
        buffers = append(buffers, { doc_id: pg.doc_id, text: ed.get_text() })
    end for
    r = studio_ui.sync_buffers(G.app, buffers)
    G.app = r.app
    G.last_action = r.action
    G.last_detail = r.detail
    ' A full redraw only when a document's DIRTY state actually moved — that is
    ' the one thing typing changes which a full redraw is needed to show (the
    ' tab's marker). Every other keystroke gets the cheap path, because rebuilding
    ' the browser pane on each one would fight the user for their own file tree.
    if r.moved then
        redraw()
    else
        pane_redraw()
    end if
    return nothing
end function

' The caret moved. The panes are keyed to the section it is in, so this is a
' pane refresh and never a full redraw: it fires on every arrow key.
function on_cursor_moved(buffer, pspec)
    if G.redrawing then
        return nothing
    end if
    ed = studio_shell.editor_for(G.shell, G.app.dm.active)
    if ed = nothing then
        return nothing
    end if
    c = ed.cursor()
    r = studio_ui.sync_cursor(G.app, G.app.dm.active, c.line, c.column)
    G.app = r.app
    ' Only when the caret crosses INTO a different section. Recording every
    ' cursor-position notify would fill the log with one event per arrow key.
    if r.changed then
        note_event("section_selected", r.detail, "")
    end if
    pane_redraw()
    return nothing
end function

' Everything a run or a caret move can change, and nothing a click can. Cheap
' enough to call at keystroke rate.
function pane_redraw()
    if G.redrawing then
        return nothing
    end if
    G.redrawing = true
    rr = studio_shell.refresh_run(G.shell, G.app)
    G.shell = rr.shell
    G.app = rr.app
    G.redrawing = false
    return nothing
end function

function on_new_project()
    r = studio_ui.new_project(G.app, G.home)
    G.app = r.app
    G.last_action = r.action
    G.last_detail = r.detail
    if r.action = "created" then
        note_event("project_created", r.detail, "")
    end if
    redraw()
    return nothing
end function

' The three below read the header's name field — one plain string off one widget,
' which is exactly the value an adapter is allowed to extract. Empty means "you
' decide", and studio_ui does.
function on_new_file()
    r = studio_ui.new_file(G.app, G.shell.name_entry.text)
    G.app = r.app
    G.last_action = r.action
    G.last_detail = r.detail
    if r.action = "created" then
        note_event("file_created", r.detail, "")
    end if
    redraw()
    return nothing
end function

function on_new_folder()
    r = studio_ui.new_folder(G.app, G.shell.name_entry.text)
    G.app = r.app
    G.last_action = r.action
    G.last_detail = r.detail
    if r.action = "created" then
        note_event("folder_created", r.detail, "")
    end if
    redraw()
    return nothing
end function

' Open the folder named in the header field as a project.
function on_open_folder()
    r = studio_ui.adopt_folder(G.app, G.shell.name_entry.text)
    G.app = r.app
    G.last_action = r.action
    G.last_detail = r.detail
    if r.action = "adopted" then
        note_event("folder_opened", G.shell.name_entry.text, r.detail)
    end if
    redraw()
    return nothing
end function

function on_rename()
    r = studio_ui.rename_selected(G.app, G.shell.name_entry.text)
    G.app = r.app
    G.last_action = r.action
    G.last_detail = r.detail
    if r.action = "renamed" then
        note_event("file_renamed", r.detail, "")
    end if
    redraw()
    return nothing
end function

' Delete and Close carry a pending confirmation between clicks. The handler only
' hands the stored arm in and stores whatever comes back; whether that arms or
' fires is studio_ui's call, and redraw is what expires it.
function on_delete()
    r = studio_ui.delete_selected(G.app, G.armed_path)
    G.app = r.app
    G.last_action = r.action
    G.last_detail = r.detail
    if r.action = "deleted" then
        note_event("file_deleted", r.detail, "")
    end if
    G.armed_path = r.armed
    redraw()
    return nothing
end function

function on_close_tab()
    r = studio_ui.close_active(G.app, G.armed_doc)
    G.app = r.app
    G.last_action = r.action
    G.last_detail = r.detail
    if r.action = "closed" then
        note_event("file_closed", r.detail, "")
    end if
    G.armed_doc = r.armed
    redraw()
    return nothing
end function

function on_save()
    r = studio_ui.save_active(G.app, G.armed_save)
    G.app = r.app
    G.last_action = r.action
    G.last_detail = r.detail
    G.armed_save = r.armed
    if r.action = "saved" then
        note_event("file_saved", r.detail, "")
    end if
    redraw()
    return nothing
end function

function on_refresh()
    r = studio_ui.refresh(G.app)
    G.app = r.app
    G.last_action = r.action
    G.last_detail = r.detail
    redraw()
    return nothing
end function

' ---- STU-2E: running a section ---------------------------------------------
'
' Run is the first interaction that does not finish when the click does, so it
' has one thing the others do not: a poll. The handler starts it, the timer
' advances it, and studio_ui decides everything either of them means.
'
' The cursor is read off the EDITOR here rather than tracked continuously,
' because "which section" is only asked once — when Run is pressed. That is the
' adapter's whole job: one value off one widget, in the widget's own units.
function on_run()
    line = 0
    col = 0
    ed = studio_shell.editor_for(G.shell, G.app.dm.active)
    if ed != nothing then
        c = ed.cursor()
        line = c.line
        col = c.column
    end if
    r = studio_ui.run_section(G.app, line, col)
    G.app = r.app
    G.last_action = r.action
    G.last_detail = r.detail
    redraw()
    if r.active then
        gi.timeout(60, on_run_poll)
    end if
    return nothing
end function

' One poll. Returning `active` is what keeps the timer alive, so the run stops
' being polled the moment it stops running — there is no idle timer left over.
'
' A tick refreshes only the run widgets. Rebuilding the browser sixteen times a
' second would fight the user for their own file tree; the FINAL tick does a full
' redraw, because that is when the status line and the results pane change.
function on_run_poll()
    r = studio_ui.tick_run(G.app)
    G.app = r.app
    if r.active then
        rr = studio_shell.refresh_run(G.shell, G.app)
        G.shell = rr.shell
        G.app = rr.app
        return true
    end if
    G.last_action = r.action
    G.last_detail = r.detail
    sess = studio_ui.exec_session(G.app)
    if sess != nothing then
        if sess.success then
            note_event("section_executed", sess.section_id, "exit " + sess.exit_code)
        else
            note_event("run_failed", sess.section_id, studio_ui.run_line(sess))
        end if
    end if
    redraw()
    return false
end function

' STU-6: ask the assistant where the user was. Read-only by construction — the
' registry it is given holds nothing that writes — and a missing key is reported
' in the pane rather than raising, because an unconfigured assistant must not
' take the window down with it.
function on_ask_agent()
    key = env("ANTHROPIC_API_KEY")
    ok = false
    if is_string(key) then
        if key != "" then
            ok = true
        end if
    end if
    if not ok then
        G.shell.apane.body.label = "(not configured — set ANTHROPIC_API_KEY and restart)"
        return nothing
    end if
    G.shell.apane.body.label = "(asking...)"
    m = studio_agent.model(llm.anthropic("claude-sonnet-4-6", key), agent_tools())
    a = studio_agent.ask(m, G.app, G.log, studio_agent.default_question())
    G.shell.apane.body.label = a.text
    return nothing
end function

' One wrapper per tool. They cannot be one shared function: `llm` calls a tool's
' callable with the ARGUMENTS only, so the callable is the only place the tool's
' own name can live. Each is two lines and does nothing but name itself and read
' the global — the same shape, and the same reason, as a signal handler.
function tool_call(name, a)
    r = studio_tools.call(G.app, G.log, name, a)
    if r.ok then
        return r.value
    end if
    ' `error` is a gBASIC keyword and cannot be a record key; the model sees a
    ' `refused` field and the reason.
    return { refused: r.why }
end function

function tool_current_project(a)
    return tool_call("current_project", a)
end function

function tool_open_files(a)
    return tool_call("open_files", a)
end function

function tool_active_file(a)
    return tool_call("active_file", a)
end function

function tool_list_sections(a)
    return tool_call("list_sections", a)
end function

function tool_section_at_cursor(a)
    return tool_call("section_at_cursor", a)
end function

function tool_run_state(a)
    return tool_call("run_state", a)
end function

function tool_section_results(a)
    return tool_call("section_results", a)
end function

function tool_section_output(a)
    return tool_call("section_output", a)
end function

function tool_section_variables(a)
    return tool_call("section_variables", a)
end function

function tool_recent_actions(a)
    return tool_call("recent_actions", a)
end function

function tool_where_was_i(a)
    return tool_call("where_was_i", a)
end function

function agent_tools()
    out = []
    for each t in studio_tools.registry()
        out = append(out, llm.tool(t.name, t.description, t.schema, tool_fn_for(t.name)))
    end for
    return out
end function

' Name to callable. A tool the registry lists but this does not map is a
' programming error and says so, rather than being silently absent from what the
' model can see.
function tool_fn_for(name)
    if name = "current_project" then
        return tool_current_project
    end if
    if name = "open_files" then
        return tool_open_files
    end if
    if name = "active_file" then
        return tool_active_file
    end if
    if name = "list_sections" then
        return tool_list_sections
    end if
    if name = "section_at_cursor" then
        return tool_section_at_cursor
    end if
    if name = "run_state" then
        return tool_run_state
    end if
    if name = "section_results" then
        return tool_section_results
    end if
    if name = "section_output" then
        return tool_section_output
    end if
    if name = "section_variables" then
        return tool_section_variables
    end if
    if name = "recent_actions" then
        return tool_recent_actions
    end if
    if name = "where_was_i" then
        return tool_where_was_i
    end if
    error "agent_tools: no callable for tool '" + name + "'"
end function

' ---- STU-8: the two callbacks a virtual DataGrid needs -----------------------
'
' Adapters, in the same sense a signal handler is one: read the global, call one
' studio_table function, hand back a plain value. The decision about what a cell
' contains is in studio_table, where a headless test calls it directly.
'
' `table_cell` WRITES the global back because decoding is what fills the cache;
' dropping the returned source would re-decode the same row on every bind, which
' is the difference between scrolling a million-row table and not.
function table_count()
    if _STUDIO_TABLE.src = nothing then
        return 0
    end if
    return _STUDIO_TABLE.src.known
end function

function table_cell(idx, col)
    if _STUDIO_TABLE.src = nothing then
        return ""
    end if
    r = studio_table.cell(_STUDIO_TABLE.src, idx, col)
    _STUDIO_TABLE.src = r.src
    return r.text
end function

' A table offer was clicked: open it.
'
' ONE TABLE WINDOW AT A TIME, and that is a constraint rather than a preference.
' A virtual grid's cell callback is handed (index, ordinal) and nothing else — it
' cannot tell which grid is asking — so every grid in the process reads the same
' `_STUDIO_TABLE.src`. Two windows open at once would therefore be two grids over
' ONE source: the second would quietly repaint the first with its own rows the
' moment anything scrolled. Replacing the window keeps the invariant the callback
' actually has, instead of leaving a second view that lies as soon as it is
' touched.
function on_table_row(box, row)
    idx = row.get_index()
    r = studio_ui.open_table(G.app, G.shell.tpane.rows, idx)
    G.app = r.app
    G.last_action = r.action
    G.last_detail = r.detail
    if r.action = "table" then
        if G.table_win != nothing then
            G.table_win.destroy()
        end if
        ' The registry holds a grid's view, selection, native model and every
        ' column's factory for as long as the grid lives — that is what lets
        ' factories stay internal. Dropping the window without this would leave
        ' all of it retained, once per table the user ever opened.
        if G.table_grid != nothing then
            datagrid.destroy(G.table_grid)
        end if
        _STUDIO_TABLE.src = r.src
        tw = studio_shell.table_window(G.app_ref, r.caption, r.src, table_count, table_cell)
        G.last_table_kind = tw.kind
        G.table_win = tw.window
        G.table_grid = tw.grid
        tw.window.present()
    end if
    redraw()
    return nothing
end function

' Fetch the whole table. This RE-RUNS the section, which is the only way to get
' data out of a run that has ended, and the status line says so rather than
' leaving the user to wonder why their program printed again.
function on_fetch_table()
    idx = G.shell.tpane.list.get_selected_row()
    n = 0
    if idx != nothing then
        n = idx.get_index()
    end if
    r = studio_ui.fetch_table(G.app, G.shell.tpane.rows, n)
    G.app = r.app
    ' Kept apart from `last_action` for the display tier's benefit: the run poller
    ' overwrites `last_action` the moment the child finishes, so for a fast table
    ' the click's own outcome is gone before anything can read it.
    G.fetch_action = r.action
    G.last_action = r.action
    G.last_detail = r.detail
    if r.active then
        gi.timeout(60, on_run_poll)
    end if
    redraw()
    return nothing
end function

' A branch row was clicked. Same adapter shape as a browser row: read the index,
' let the rows that were drawn decide what it means.
function on_branch_row(box, row)
    idx = row.get_index()
    r = studio_ui.activate_branch_row(G.app, G.shell.bpane.rows, idx, G.shell.name_entry.text)
    G.app = r.app
    G.last_action = r.action
    G.last_detail = r.detail
    redraw()
    return nothing
end function

function on_bind()
    r = studio_ui.bind_selected(G.app, G.shell.name_entry.text)
    G.app = r.app
    G.last_action = r.action
    G.last_detail = r.detail
    redraw()
    return nothing
end function

' ---- STU-10: teaching, drawn -----------------------------------------------
'
' A cue left on the app by the `point_at` tool is rendered on the next redraw and
' consumed there. This is the adapter: one call, and — for a pulse — one timeout
' whose callback clears the class again. The callback cannot close over the
' widget, so the shell holds it and this reads the global, exactly as every other
' handler does.
function draw_cue()
    r = studio_shell.apply_cue(G.shell, G.app)
    G.shell = r.shell
    G.app = r.app
    if G.shell.pulsing != nothing then
        gi.timeout(studio_teaching.pulse_ms(), end_pulse)
    end if
    return nothing
end function

function end_pulse()
    G.shell = studio_shell.clear_pulse(G.shell)
    return false
end function

' ---- STU-9: the overlay acts ------------------------------------------------
'
' Adapters, all six. The DECISIONS -- may this branch carry an overlay, does this
' section sit below the point, does anything conflict, may this be promoted --
' live in studio_ui, where the headless suite presses them directly.
'
' The editor is the NAME FIELD's bigger sibling here: an overlay's text comes out
' of the active editor buffer, so "Overlay this section" loads the section into it
' and "Save overlay" takes what is there. That keeps the overlay editable with the
' editor the user already has, and keeps this a two-line read like every other
' handler.
function on_overlay_edit()
    r = studio_ui.begin_overlay(G.app)
    G.app = r.app
    G.last_action = r.action
    G.last_detail = r.detail
    if r.action = "overlay-began" then
        G.shell.bpane.editor.set_text(r.text)
    end if
    if r.action = "overlay-open" then
        G.shell.bpane.editor.set_text(r.text)
    end if
    redraw()
    return nothing
end function

' Save what the OVERLAY EDITOR holds. Its own editor, not the source one: the
' source buffer shows the canonical document, and a window displaying
' non-canonical text as the file is the one thing §2.1 forbids.
function on_overlay_save()
    r = studio_ui.save_overlay(G.app, G.shell.bpane.editor.get_text())
    G.app = r.app
    G.last_action = r.action
    G.last_detail = r.detail
    redraw()
    return nothing
end function

function on_overlay_compare()
    d = studio_ui.overlay_diff(G.app)
    G.app = d.app
    G.shell.bpane.diff.label = join(d.lines, "\n")
    G.last_action = "overlay-compared"
    G.last_detail = count(d.lines) + " line(s)"
    redraw()
    return nothing
end function

function on_overlay_rebase()
    r = studio_ui.rebase_overlay(G.app)
    G.app = r.app
    G.last_action = r.action
    G.last_detail = r.detail
    redraw()
    return nothing
end function

function on_overlay_promote()
    r = studio_ui.promote_overlay(G.app)
    G.app = r.app
    G.last_action = r.action
    G.last_detail = r.detail
    redraw()
    return nothing
end function

function on_overlay_discard()
    r = studio_ui.discard_overlay(G.app)
    G.app = r.app
    G.last_action = r.action
    G.last_detail = r.detail
    redraw()
    return nothing
end function

function on_stop()
    r = studio_ui.stop_run(G.app)
    G.app = r.app
    G.last_action = r.action
    G.last_detail = r.detail
    redraw()
    return nothing
end function

function on_force_stop()
    r = studio_ui.force_stop_run(G.app)
    G.app = r.app
    G.last_action = r.action
    G.last_detail = r.detail
    redraw()
    return nothing
end function

' Connect every widget the shell exposed. This is the ONLY gi.connect over
' widgets in the program, so the wiring is one readable list rather than a thing
' scattered through the view.
function wire_shell()
    sh = G.shell
    gi.connect(sh.nav, "row-activated", on_nav_row_activated)
    gi.connect(sh.notebook, "switch-page", on_tab_switched)
    gi.connect(sh.new_btn, "clicked", on_new_project)
    gi.connect(sh.file_btn, "clicked", on_new_file)
    gi.connect(sh.folder_btn, "clicked", on_new_folder)
    gi.connect(sh.open_btn, "clicked", on_open_folder)
    gi.connect(sh.rename_btn, "clicked", on_rename)
    gi.connect(sh.delete_btn, "clicked", on_delete)
    gi.connect(sh.close_btn, "clicked", on_close_tab)
    gi.connect(sh.save_btn, "clicked", on_save)
    gi.connect(sh.refresh_btn, "clicked", on_refresh)
    gi.connect(sh.bar.run, "clicked", on_run)
    gi.connect(sh.bar.halt, "clicked", on_stop)
    gi.connect(sh.bar.force, "clicked", on_force_stop)
    gi.connect(sh.apane.ask, "clicked", on_ask_agent)
    gi.connect(sh.bpane.list, "row-activated", on_branch_row)
    gi.connect(sh.bpane.bind, "clicked", on_bind)
    gi.connect(sh.tpane.list, "row-activated", on_table_row)
    gi.connect(sh.tpane.fetch, "clicked", on_fetch_table)
    gi.connect(sh.bpane.edit, "clicked", on_overlay_edit)
    gi.connect(sh.bpane.save, "clicked", on_overlay_save)
    gi.connect(sh.bpane.cmp, "clicked", on_overlay_compare)
    gi.connect(sh.bpane.rebase, "clicked", on_overlay_rebase)
    gi.connect(sh.bpane.promote, "clicked", on_overlay_promote)
    gi.connect(sh.bpane.discard, "clicked", on_overlay_discard)
    return nothing
end function

' ---- STU-2B display tier ---------------------------------------------------
'
' The headless suite proves what an interaction MEANS. What it cannot reach is
' the two inches between a GTK signal and a studio_ui call: that the handler is
' connected at all, that the row index it reads is the row the user hit, and that
' rebuilding the pane from inside the pane's own handler does not blow up.
'
' So this tier synthesises REAL signals rather than calling handlers directly.
' There is no gi.emit (the bridge has no such entry point), but several
' introspected GTK methods emit the signal we want as their documented effect:
'   * GtkListBoxRow.activate()     -> "row-activated" on the parent listbox
'   * GtkNotebook.set_current_page -> "switch-page"
'   * GtkTextBuffer.set_text       -> "changed"
' all synchronous, and
'   * GtkButton.activate()         -> "clicked", ~250 ms later via GtkButton's
'                                     own activate timeout
' which is why the button half runs on a timer instead of in a straight line.
'
' Output is model state, printed path-free, so it is a golden like every other.

function find_row(kind, name)
    rows = G.shell.rows
    i = 0
    while i < count(rows)
        r = rows[i]
        if r.kind = kind then
            lab = r.label
            tail = mid(lab, len(lab) - len(name), len(name))
            if tail = name then
                return i
            end if
        end if
        i = i + 1
    end while
    return -1
end function

' Synthesise a click on browser row `idx` — the real signal, through the real
' handler, on the row the listbox actually holds at that index.
function click_row(idx)
    row = G.shell.nav.get_row_at_index(idx)
    if row = nothing then
        print "  (no widget row at " + idx + ")"
        return nothing
    end if
    row.activate()
    return nothing
end function

function state(label)
    print "-- " + label + " --"
    print studio_ui.summary(G.app)
    return nothing
end function

' Phase A: the signals that are delivered synchronously.
function run_stu2b_probe()
    state("as built")

    ' THE VERTICAL SLICE: click a browser row -> the document opens -> a tab
    ' appears -> that tab is the active document in the model.
    i = find_row("file", "main.bas")
    print "clicking browser row " + i + " (main.bas)"
    click_row(i)
    print "action=" + G.last_action
    state("after the click")

    ' The pane rebuilt itself from inside its own handler; it must still be
    ' clickable, with rows that still line up with the model.
    j = find_row("dir", "src")
    print "clicking browser row " + j + " (src)"
    click_row(j)
    print "action=" + G.last_action
    state("after expanding src")

    ' A second document, so there is something to switch between.
    k = find_row("file", "a.bas")
    print "clicking browser row " + k + " (src/a.bas)"
    click_row(k)
    print "action=" + G.last_action
    state("two tabs")

    ' Tab switching, through a real "switch-page".
    print "set_current_page(0)"
    G.shell.notebook.set_current_page(0)
    print "action=" + G.last_action
    state("after switching to page 0")

    ' Typing, through a real "changed" on the live buffer.
    pg = G.shell.pages[0]
    ed = pg.editor
    print "typing into page 0's buffer"
    ed.set_text("typed into the editor by hand\n")
    print "action=" + G.last_action
    state("after typing")
    return nothing
end function

' Phase B: the buttons, whose "clicked" arrives on GtkButton's own timer.
function stu2b_button_step()
    G.phase = G.phase + 1
    if G.phase = 1 then
        print "clicking Save"
        G.shell.save_btn.activate()
        return true
    end if
    if G.phase = 2 then
        print "action=" + G.last_action
        state("after Save")
        print "clicking Refresh"
        G.shell.refresh_btn.activate()
        return true
    end if
    if G.phase = 3 then
        print "action=" + G.last_action
        state("after Refresh")
        print "clicking New Project"
        G.shell.new_btn.activate()
        return true
    end if
    print "action=" + G.last_action
    state("after New Project")
    G.app_ref.quit()
    return false
end function

' ---- STU-2C display tier ---------------------------------------------------
'
' The whole complaint STU-2C answers, driven end to end through real signals:
' start with nothing, and build a project, a file, its contents and a folder
' using only the window. STU-2B stopped after the first of those — New Project
' made an empty directory, an empty directory has no rows, and every other
' control needs a row.
'
' It finishes by closing the window, because the GTK loop returning is what now
' persists the session, and the harness reopens the same home afterwards.
function stu2c_step()
    G.phase = G.phase + 1
    if G.phase = 1 then
        print "clicking New Project on a cold home"
        G.shell.new_btn.activate()
        return true
    end if
    if G.phase = 2 then
        print "action=" + G.last_action
        state("after New Project — an empty project, which is where STU-2B stopped")
        print "clicking New File"
        G.shell.file_btn.activate()
        return true
    end if
    if G.phase = 3 then
        print "action=" + G.last_action
        state("after New File")
        ' The new file opened into a tab, so it can be typed into immediately.
        pg = G.shell.pages[0]
        ed = pg.editor
        print "typing into it"
        ed.set_text("print \"made entirely from the window\"\n")
        print "action=" + G.last_action
        print "clicking Save"
        G.shell.save_btn.activate()
        return true
    end if
    if G.phase = 4 then
        print "action=" + G.last_action
        state("after Save")
        print "clicking New Folder"
        G.shell.folder_btn.activate()
        return true
    end if
    print "action=" + G.last_action
    state("after New Folder")
    print "closing the window"
    G.app_ref.quit()
    return false
end function

' ---- STU-2D display tier ---------------------------------------------------
'
' What the headless suite cannot reach here is the name FIELD: that Rename and
' New File read the text a user typed into a GtkEntry, and that the field empties
' once it has been consumed. GtkEntry's text is an ordinary property, so the test
' types by setting it — the same trick as the editor buffer, and the reason the
' name field is a field rather than a dialog.
'
' It also presses Delete twice for real, which is the only way to see that the
' arm survives one redraw and not two.
function stu2d_step()
    G.phase = G.phase + 1
    if G.phase = 1 then
        print "typing \"notes.bas\" into the name field, then clicking New File"
        G.shell.name_entry.text = "notes.bas"
        G.shell.file_btn.activate()
        return true
    end if
    if G.phase = 2 then
        print "action=" + G.last_action + " status=" + G.shell.status.label
        print "name field is now [" + G.shell.name_entry.text + "]"
        state("after New File")
        print "typing \"notes-2.bas\" and clicking Rename"
        G.shell.name_entry.text = "notes-2.bas"
        G.shell.rename_btn.activate()
        return true
    end if
    if G.phase = 3 then
        print "action=" + G.last_action + " status=" + G.shell.status.label
        state("after Rename")
        print "clicking Delete once"
        G.shell.delete_btn.activate()
        return true
    end if
    if G.phase = 4 then
        print "action=" + G.last_action + " status=" + G.shell.status.label
        state("armed, and still there")
        print "clicking Delete again"
        G.shell.delete_btn.activate()
        return true
    end if
    if G.phase = 5 then
        print "action=" + G.last_action + " status=" + G.shell.status.label
        state("deleted")
        print "clicking Delete with nothing selected"
        G.shell.delete_btn.activate()
        return true
    end if
    print "action=" + G.last_action + " status=" + G.shell.status.label
    G.app_ref.quit()
    return false
end function

' ---- STU-2E display tier ---------------------------------------------------
'
' Click Run and let the window drive itself: the button's handler starts a real
' child interpreter and a real GTK timer, and nothing here advances the run. What
' this proves that the headless case cannot is that the poll is actually
' installed and actually stops — that a run started from a click reaches a
' finished state and lands in the panes, without the test ticking it along.
function stu2e_step()
    G.phase = G.phase + 1
    if G.phase = 1 then
        print "clicking Run Section"
        G.shell.bar.run.activate()
        return true
    end if
    ' Wait for the run the WINDOW is driving. Bounded, so a hung child fails the
    ' case instead of hanging the suite.
    sess = studio_ui.exec_session(G.app)
    settled = false
    if sess != nothing then
        if studio_session.is_active(sess) = false then
            settled = true
        end if
    end if
    if settled = false then
        if G.phase < 40 then
            return true
        end if
        print "run did not settle"
    end if
    print "strip=" + G.shell.bar.state.label
    print "status=" + G.shell.status.label
    print "prefix=<" + G.shell.pane.prefix.label + ">"
    print "target=<" + G.shell.pane.target.label + ">"
    print G.shell.rpane.body.label
    G.app_ref.quit()
    return false
end function

' ---- STU-5A′ display tier --------------------------------------------------
'
' Moving the caret is not a click, so nothing the other tiers do would notice a
' disconnected cursor handler. `set_cursor` moves the real caret and GTK emits
' the real "notify::cursor-position", so the strip and the results pane here are
' being driven by the signal and not by the test.
function stu2f_step()
    G.phase = G.phase + 1
    if G.phase = 1 then
        print "caret at the top"
        print "  " + G.shell.bar.section.label
        print "moving the caret into the function"
        G.shell.pages[0].editor.set_cursor(3, 2)
        return true
    end if
    if G.phase = 2 then
        print "  " + G.shell.bar.section.label
        print "moving the caret to the last line"
        G.shell.pages[0].editor.set_cursor(6, 0)
        return true
    end if
    if G.phase = 3 then
        print "  " + G.shell.bar.section.label
        print "clicking Run Section there"
        G.shell.bar.run.activate()
        return true
    end if
    sess = studio_ui.exec_session(G.app)
    settled = false
    if sess != nothing then
        if studio_session.is_active(sess) = false then
            settled = true
        end if
    end if
    if settled = false then
        if G.phase < 40 then
            return true
        end if
        print "run did not settle"
    end if
    print "  " + G.shell.bar.state.label
    print "results pane, caret still on the section that ran:"
    print G.shell.rpane.body.label
    print "moving the caret back to the first section"
    G.shell.pages[0].editor.set_cursor(0, 0)
    print "  " + G.shell.bar.section.label
    print "results pane, following the caret:"
    print G.shell.rpane.body.label
    G.app_ref.quit()
    return false
end function

' ---- STU-2C' display tier -------------------------------------------------
'
' Open Folder reads the header field as a PATH. This types one in and clicks the
' button, which is the whole reason the control is a field rather than a dialog:
' a GtkFileDialog is async with no signal a test can synthesise, so it would be
' the one control in this window nothing could press.
function stu2g_step()
    G.phase = G.phase + 1
    if G.phase = 1 then
        print "typing the folder path into the name field, then clicking Open Folder"
        G.shell.name_entry.text = G.open_target
        G.shell.open_btn.activate()
        return true
    end if
    if G.phase = 2 then
        print "action=" + G.last_action + " status=" + G.shell.status.label
        print "name field is now [" + G.shell.name_entry.text + "]"
        state("after Open Folder")
        print "clicking Open Folder again on the same path"
        G.shell.name_entry.text = G.open_target
        G.shell.open_btn.activate()
        return true
    end if
    if G.phase = 3 then
        print "action=" + G.last_action + " status=" + G.shell.status.label
        state("activated, not duplicated")
        print "clicking Open Folder on a path that is not there"
        G.shell.name_entry.text = G.open_target + "/nowhere"
        G.shell.open_btn.activate()
        return true
    end if
    print "action=" + G.last_action + " status=" + G.shell.status.label
    G.app_ref.quit()
    return false
end function

' ---- STU-7 display tier ----------------------------------------------------
'
' The selector is a listbox of DATA, so its rows can be activated the same way a
' browser row is — which is the whole reason it is a listbox and not a row of
' buttons built per branch.
function stu7_step()
    G.phase = G.phase + 1
    if G.phase = 1 then
        print "rows as drawn:"
        for each r in G.shell.bpane.rows
            mark = "  "
            if r.selected then
                mark = "* "
            end if
            print "  " + mark + r.kind + " " + r.label
        end for
        print "typing a name and clicking +"
        G.shell.name_entry.text = "Low"
        studio_shell_click_branch_row(count(G.shell.bpane.rows) - 1)
        return true
    end if
    if G.phase = 2 then
        print "action=" + G.last_action + " status=" + G.shell.status.label
        print "  " + studio_ui.branch_label(G.app)
        print "binding a value onto it"
        G.shell.name_entry.text = "threshold = 0.25"
        G.shell.bpane.bind.activate()
        return true
    end if
    if G.phase = 3 then
        print "action=" + G.last_action + " status=" + G.shell.status.label
        print "rows now:"
        for each r in G.shell.bpane.rows
            mark = "  "
            if r.selected then
                mark = "* "
            end if
            print "  " + mark + r.kind + " " + r.label
        end for
        print "clicking Baseline"
        studio_shell_click_branch_row(0)
        return true
    end if
    print "action=" + G.last_action + " status=" + G.shell.status.label
    print "  " + G.shell.bar.branch.label
    G.app_ref.quit()
    return false
end function

' STU-8: the tabular tier, clicked for real.
'
' What the headless suite cannot reach is exactly what this checks: that the
' offers pane is filled by the SAME redraw the rest of the window uses, that a
' click on an offer row reaches the dispatcher with the index the user hit, and —
' the part no plain-data test can assert — that a virtual DataGrid built over a
' Studio row source actually BINDS cells, through GTK's own factory, reading
' through the two-line adapters.
'
' MEASURING BINDS. The counters are reset BEFORE the widget tree is built, never
' after: GtkColumnView realizes and binds its visible rows when the view is first
' given a size, not at present() and not when the main loop runs. Resetting after
' present zeroes work that has already happened and makes a healthy grid look
' like it never bound. That is the documented DataGrid measurement artifact, and
' repeating it here would have turned a passing grid into a failing test.
function stu8_step()
    ' NEVER advance while a run is in flight. The first version of this stepped
    ' on a fixed timer and passed twice before a bigger table made the run outlast
    ' the interval — after which every later phase read a window that was still
    ' mid-run: the offers pane was empty (a live session is not a stored result),
    ' so the click that should have opened a table opened nothing. A display tier
    ' that depends on how fast the machine is does not test what it claims to.
    sess = studio_ui.exec_session(G.app)
    if sess != nothing then
        if studio_session.is_active(sess) then
            return true
        end if
    end if
    G.phase = G.phase + 1
    if G.phase = 1 then
        print "before any run, the offers pane has nothing to offer: " + count(G.shell.tpane.rows)
        print "clicking Run"
        G.shell.bar.run.activate()
        return true
    end if
    if G.phase = 2 then
        print "offers after the run: " + count(G.shell.tpane.rows)
        for each r in G.shell.tpane.rows
            print "  tier=" + r.tier
        end for
        print "clicking the offer"
        datagrid.reset_accesses()
        studio_shell_click_table_row(0)
        return true
    end if
    if G.phase = 3 then
        print "action=" + G.last_action + " tier=" + G.last_table_kind
        print "  a sample fits in a grid of labels, so no DataGrid was built"
        print "  cells bound by GTK: " + stu8_bounded(datagrid.accesses())
        print "clicking Fetch all rows"
        G.shell.tpane.fetch.activate()
        return true
    end if
    if G.phase = 4 then
        print "fetch action=" + G.fetch_action
        print "opening it again, now that the whole table is on disk"
        datagrid.reset_accesses()
        studio_shell_click_table_row(0)
        return true
    end if
    print "action=" + G.last_action + " tier=" + G.last_table_kind
    ' THE virtualization assertion. Not "the number is small" -- small compared to
    ' what? -- but that it does not MOVE when the table grows: the suite runs this
    ' tier twice, at 1,200 rows and at 12,000, and requires these two lines to
    ' come out byte-identical. A grid that materialized its rows could not do
    ' that.
    print "  cells bound by GTK: " + stu8_bounded(datagrid.accesses())
    print "  rows decoded by Studio: " + stu8_bounded(_STUDIO_TABLE.src.decodes)
    G.app_ref.quit()
    return false
end function

' A count reported as a BAND rather than a number. How many rows GTK realizes
' depends on the window height, the theme's row padding and the GTK version, so a
' golden holding the exact figure would be a golden about this machine. What the
' test is actually asserting is that the number is bounded — some, and nowhere
' near the whole table — and that is what this prints.
function stu8_bounded(n)
    if n = 0 then
        return "none"
    end if
    if n < 2000 then
        return "bounded"
    end if
    return "MANY (" + n + ") — grew with the table"
end function

function studio_shell_click_table_row(idx)
    row = G.shell.tpane.list.get_row_at_index(idx)
    if row = nothing then
        print "  (no table row at " + idx + ")"
        return nothing
    end if
    row.activate()
    return nothing
end function

' STU-10: teaching, drawn for real.
'
' What only this tier can reach: that a cue built by studio_teaching resolves to a
' widget the shell actually holds, that the CSS class lands ON that widget, that a
' pulse takes it off again by itself, and that an annotation puts a real
' GtkTextTag over the editor. The headless tier proves what a cue MEANS; nothing
' below the widget boundary can prove it was drawn.
function stu10_step()
    ' Never advance while a pulse is still running. The first version checked
    ' that the class had been removed on a fixed interval and raced the timeout —
    ' the same mistake STU-8's tier made, and the reason that one waits on its
    ' run instead of on a clock.
    if G.shell.pulsing != nothing then
        return true
    end if
    G.phase = G.phase + 1
    if G.phase = 1 then
        print "every widget the agent may point at resolves to a real one:"
        missing = 0
        for each nm in studio_shell.teachable()
            if studio_shell.teach_widget(G.shell, nm) = nothing then
                if nm != "editor" then
                    if nm != "gutter" then
                        print "  UNRESOLVED: " + nm
                        missing = missing + 1
                    end if
                end if
            end if
        end for
        print "  unresolved: " + missing + " (editor and gutter are the source itself)"
        print "pointing at the Run button"
        stu10_point("run_button", "highlight", "")
        return true
    end if
    if G.phase = 2 then
        print "  has the class: " + string(G.shell.bar.run.has_css_class(studio_teaching.css_class("highlight")))
        print "pulsing the name field"
        stu10_point("name_field", "pulse", "")
        ' Checked in the SAME phase: the cue is drawn synchronously inside the
        ' redraw, so the class is on by the time this returns. Checking it in the
        ' next phase would be checking it after the timeout might already have
        ' fired.
        print "  has the class: " + string(G.shell.name_entry.has_css_class(studio_teaching.css_class("pulse")))
        return true
    end if
    if G.phase = 3 then
        print "  and the pulse took it off again by itself: " + string(not G.shell.name_entry.has_css_class(studio_teaching.css_class("pulse")))
        print "annotating lines 2-4 of the editor"
        stu10_point("editor", "annotate", "2-4")
        return true
    end if
    if G.phase = 4 then
        print "  a tag is on the buffer: " + string(G.shell.teach_tag != nothing)
        print "pointing at something that is not there"
        stu10_point("run_panel", "highlight", "")
        return true
    end if
    print "  action=" + G.last_action + " — " + G.last_detail
    G.app_ref.quit()
    return false
end function

' Point through the TOOL, not by calling the shell: what this tier is for is the
' whole path, from a tool call an agent could have made to a class on a widget.
function stu10_point(widget, gesture, detail)
    pol = studio_permissions.effective({ local: "auto" }, nothing, nothing)
    cue_args = { widget: widget, gesture: gesture, detail: detail }
    r = studio_tools.invoke(G.app, G.log, pol, "point_at", cue_args, "")
    G.app = r.app
    G.log = r.log
    G.last_action = "point_at"
    G.last_detail = r.why
    if r.ok then
        G.last_detail = studio_teaching.describe(r.value)
    end if
    redraw()
    return nothing
end function

' STU-9: the whole overlay cycle, clicked for real.
'
' What only this tier can reach: that the overlay editor is a REAL editable
' buffer (text typed into it comes back out through get_text), that the six
' buttons are connected, and that a promote reaches the source editor's buffer
' through the ordinary redraw rather than through a path of its own.
function stu9_step()
    sess = studio_ui.exec_session(G.app)
    if sess != nothing then
        if studio_session.is_active(sess) then
            return true
        end if
    end if
    G.phase = G.phase + 1
    if G.phase = 1 then
        print "an overlay needs a branch: the baseline is the file"
        G.shell.bpane.edit.activate()
        return true
    end if
    if G.phase = 2 then
        print "  action=" + G.last_action + " — " + G.last_detail
        print "making a branch, then overlaying the section below it"
        G.shell.name_entry.text = "Robust"
        studio_shell_click_branch_row(count(G.shell.bpane.rows) - 1)
        return true
    end if
    if G.phase = 3 then
        print "  action=" + G.last_action
        stu9_caret(2)
        G.shell.bpane.edit.activate()
        return true
    end if
    if G.phase = 4 then
        print "  action=" + G.last_action + " on " + G.last_detail
        print "the overlay editor opened with the canonical text:"
        stu9_show(G.shell.bpane.editor.get_text())
        print "typing into it, for real"
        G.shell.bpane.editor.set_text("function score(t)\n  return t * 1000\nend function")
        G.shell.bpane.save.activate()
        return true
    end if
    if G.phase = 5 then
        print "  action=" + G.last_action
        print "the selector marks it experimental:"
        stu9_caret(0)
        return true
    end if
    if G.phase = 6 then
        for each r in G.shell.bpane.rows
            mark = "  "
            if r.selected then
                mark = "* "
            end if
            print "  " + mark + r.label + studio_ui.overlay_mark(r)
        end for
        print "comparing"
        G.shell.bpane.cmp.activate()
        return true
    end if
    if G.phase = 7 then
        stu9_show(G.shell.bpane.diff.label)
        print "running the branch"
        stu9_caret(6)
        G.shell.bar.run.activate()
        return true
    end if
    if G.phase = 8 then
        print "  target=<" + studio_ui.target_body(G.app) + ">"
        print "the source editor still shows the FILE:"
        stu9_show(studio_shell.editor_for(G.shell, G.app.dm.active).get_text())
        print "promoting"
        G.shell.bpane.promote.activate()
        return true
    end if
    print "  action=" + G.last_action + " — " + G.last_detail
    print "and NOW the source editor shows it, as an unsaved edit:"
    stu9_show(studio_shell.editor_for(G.shell, G.app.dm.active).get_text())
    G.app_ref.quit()
    return false
end function

function stu9_show(text)
    for each l in split(text, "\n")
        print "    |" + l
    end for
    return nothing
end function

' Move the REAL caret, which is what the panes and the overlay acts read.
function stu9_caret(line)
    ed = studio_shell.editor_for(G.shell, G.app.dm.active)
    if ed != nothing then
        ed.set_cursor(line, 0)
    end if
    return nothing
end function

' Synthesise a real row-activated on the selector.
function studio_shell_click_branch_row(idx)
    row = G.shell.bpane.list.get_row_at_index(idx)
    if row = nothing then
        print "  (no branch row at " + idx + ")"
        return nothing
    end if
    row.activate()
    return nothing
end function

' The cold-home path: an empty home renders "(no workspace open)", and New
' Project is the only thing that can move it. If this button does not work, a
' new user has no way into Studio at all.
function stu2b_cold_step()
    G.phase = G.phase + 1
    if G.phase = 1 then
        print "clicking New Project on a cold home"
        G.shell.new_btn.activate()
        return true
    end if
    print "action=" + G.last_action
    state("after New Project")
    G.app_ref.quit()
    return false
end function

' GTK activate handler (display modes only). Reads the global G assembled in main.
function on_activate(gtkapp)
    shell = studio_shell.build(gtkapp, G.app)
    G.shell = shell
    wire_shell()
    redraw()
    studio_shell.present(shell)
    if G.stu2b then
        run_stu2b_probe()
        ' The button half cannot run inline: GtkButton turns activate() into
        ' "clicked" on a ~250 ms timer, so the loop has to be given back.
        gi.timeout(400, stu2b_button_step)
        return nothing
    end if
    if G.stu2b_cold then
        state("a cold home")
        gi.timeout(400, stu2b_cold_step)
        return nothing
    end if
    if G.stu2c then
        state("a cold home")
        gi.timeout(400, stu2c_step)
        return nothing
    end if
    if G.stu2d then
        state("as built")
        gi.timeout(400, stu2d_step)
        return nothing
    end if
    if G.stu2g then
        state("a cold home")
        gi.timeout(400, stu2g_step)
        return nothing
    end if
    if G.stu10 then
        gi.timeout(600, stu10_step)
    end if
    if G.stu9 then
        gi.timeout(500, stu9_step)
    end if
    if G.stu8 then
        gi.timeout(500, stu8_step)
    end if
    if G.stu7 then
        gi.timeout(400, stu7_step)
        return nothing
    end if
    if G.stu2e then
        print studio_ui.exec_summary(G.app)
        gi.timeout(200, stu2e_step)
        return nothing
    end if
    if G.stu2f then
        gi.timeout(200, stu2f_step)
        return nothing
    end if
    if G.smoke then
        ws = G.app.model.workspace
        print "shell-built"
        if ws = nothing then
            print "workspace=none"
        else
            print "workspace=" + ws.name
            print "projects=" + count(ws.projects)
        end if
        dm = G.app.dm
        print "open-docs=" + count(dm.docs)
        ad = studio_docs.active_doc(dm)
        if ad != nothing then
            print "active-tab=" + studio_shell.tab_label(ad)
        end if
        if G.sections then
            doc = studio_docs.doc_by_id(dm, G.doc_id)
            st = studio_sections.create(G.doc_id)
            st = studio_sections.refresh(st, doc.content)
            print studio_sections.summary(st)
            cur = doc.cursor
            print "cursor line=" + cur.line + " col=" + cur.column + " -> " + studio_sections.section_at_position(st, doc.content, cur.line, cur.column)
            ' Persisting through the workspace record works the same under the shell.
            ws = G.app.model.workspace
            ws.sections = studio_sections.persist_into(ws.sections, st)
            print "persisted docs=" + count(ws.sections)
        end if
        if G.exec then
            ' STU-4: build the execution strip + output pane, resolve the section at
            ' the document's cursor, start a run, and drive it from a GTK TIMEOUT --
            ' no actor, no mailbox (R2 amendment). The timer is the only thing that
            ' advances the session; the GTK loop stays free the whole time.
            bar = studio_shell.run_bar()
            pane = studio_shell.output_pane()
            G.bar = bar
            G.pane = pane
            doc = studio_docs.doc_by_id(dm, G.doc_id)
            st = studio_sections.create(G.doc_id)
            st = studio_sections.refresh(st, doc.content)
            G.secs = st
            G.src = doc.content
            cur = doc.cursor
            sid = studio_sections.section_at_position(st, doc.content, cur.line, cur.column)
            print "cursor-section=" + sid
            G.sid = sid
            if G.results then
                ' STU-5A: mount the results pane before the run, so "no runs yet"
                ' is a state the pane actually renders rather than a special case.
                G.store = studio_results.open(G.home, G.doc_path)
                G.rpane = studio_shell.results_pane()
                G.rpane.body.label = studio_shell.results_text(G.home, G.store, st, sid)
                print "results-pane-before=<" + G.rpane.body.label + ">"
            end if
            sess = studio_session.create(G.doc_id, G.scratch)
            ' Pin the clock so the display golden is byte-stable, exactly as the
            ' headless cases do.
            sess.clock_fixed = 1000
            sess = studio_session.run(sess, st, doc.content, sid)
            G.sess = sess
            bar.state.label = studio_shell.session_text(sess)
            print studio_shell.session_text(sess)
            gi.timeout(50, on_run_tick)
            return nothing
        end if
        gtkapp.quit()
    end if
end function

' STU-4 timer callback: one non-blocking service of the child per tick. Returns
' true to stay armed, false to disarm once the run has left an active state.
function on_run_tick()
    G.sess = studio_session.tick(G.sess)
    G.bar.state.label = studio_shell.session_text(G.sess)
    G.pane.prefix.label = studio_shell.output_prefix_text(G.sess)
    G.pane.target.label = studio_shell.output_target_text(G.sess)
    if studio_session.is_active(G.sess) then
        return true
    end if
    G.sess = studio_session.finalize(G.sess, G.secs, G.src)
    print studio_shell.session_text(G.sess)
    print "prefix-pane=<" + studio_shell.output_prefix_text(G.sess) + ">"
    print "target-pane=<" + studio_shell.output_target_text(G.sess) + ">"
    print "transitions: " + studio_session.transitions(G.sess)
    if G.results then
        ' STU-5A: the run is over, so it becomes a durable record -- written, read
        ' back, and rendered, so the pane is showing persisted state and not the
        ' live session it happens to sit next to.
        G.store = studio_results.add_result(G.home, G.store, studio_session.to_result(G.sess, G.secs))
        studio_results.save(G.home, G.store)
        reloaded = studio_results.open(G.home, G.doc_path)
        G.rpane.body.label = studio_shell.results_text(G.home, reloaded, G.secs, G.sid)
        print "results-pane-after=<" + G.rpane.body.label + ">"

        ' Now edit the section the result describes. Its id survives (STU-3), so
        ' only the fingerprint can tell the pane that the result is behind the
        ' text on screen -- which is the whole point of recording it.
        edited = "print \"first\"\n\nfunction add(a, b)\n  return a + b\nend function\n\nprint add(2, 4)\n"
        st2 = studio_sections.refresh(G.secs, edited)
        G.rpane.body.label = studio_shell.results_text(G.home, reloaded, st2, G.sid)
        print "results-pane-edited=<" + G.rpane.body.label + ">"
    end if
    G.app_ref.quit()
    return false
end function

program main(args)
    ' Core backbone libraries — always available (loads live inside the program
    ' block; a top-level load does not run when a program block is present).
    load persist
    load studio_model
    load filetree
    load studio_docs
    load studio_sections
    load studio_session
    load studio_results
    load studio_history
    load studio

    mode = "gui"
    if count(args) > 0 then
        mode = args[0]
    end if

    home = ".gbasic-studio"
    if count(args) > 1 then
        home = args[1]
    end if

    ' ---- headless lifecycle modes -----------------------------------------

    if mode = "startup" then
        app = studio.startup(home)
        print studio.summary(app)
        return
    end if

    if mode = "build" then
        app = studio.startup(home)
        app = build_canned(app)
        saved = studio.shutdown(app)
        print "saved=" + join(saved, ",")
        return
    end if

    if mode = "roundtrip" then
        app = studio.startup(home)
        app = build_canned(app)
        studio.shutdown(app)
        app2 = studio.startup(home)
        print studio.summary(app2)
        return
    end if

    if mode = "stress" then
        app = studio.startup(home)
        app = build_canned(app)
        i = 0
        ok = true
        while i < 30
            studio.shutdown(app)
            chk = studio.startup(home)
            w = chk.model.workspace
            if w = nothing then
                ok = false
            end if
            i = i + 1
        end while
        print "stress_ok=" + ok
        return
    end if

    if mode = "cycles" then
        i = 0
        while i < 50
            a = studio.startup(home)
            studio.shutdown(a)
            i = i + 1
        end while
        print "cycles_done=50"
        return
    end if

    ' ---- STU-1 headless modes (navigation) --------------------------------
    ' For browse/missing modes, `home` carries the project directory path.

    if mode = "stu1_build" then
        projdir = ".gbasic-studio-proj"
        if count(args) > 2 then
            projdir = args[2]
        end if
        app = studio.launch(home)
        app = build_stu1(app, projdir)
        saved = studio.persist(app)
        print "saved=" + join(saved, ",")
        return
    end if

    if mode = "stu1_restore" then
        app = studio.launch(home)
        print studio.nav_summary(app)
        ws = app.model.workspace
        proj = studio_model.project_by_id(ws, ws.active_project)
        nodes = filetree.scan(proj.path, ws.nav.expanded)
        print "browser:"
        print filetree.dump(nodes)
        return
    end if

    if mode = "stu1_browse" then
        nodes = filetree.scan(home, [home + "/src"])
        print filetree.dump(nodes)
        return
    end if

    if mode = "stu1_missing" then
        nodes = filetree.scan(home + "/does_not_exist", [])
        print "rows=" + filetree.visible_count(nodes)
        return
    end if

    if mode = "stu1_registry" then
        app = studio.launch(home)
        app = studio.create_registered_workspace(app, "one")
        studio.persist(app)
        app = studio.create_registered_workspace(app, "two")
        studio.persist(app)
        app = studio.create_registered_workspace(app, "three")
        studio.persist(app)
        print studio.nav_summary(app)
        return
    end if

    if mode = "stu1_cycles" then
        i = 0
        while i < 50
            a = studio.launch(home)
            studio.persist(a)
            i = i + 1
        end while
        print "cycles_done=50"
        return
    end if

    ' ---- STU-2 headless modes (documents) ---------------------------------
    ' args[2] is a project directory (created by the harness) unless noted.

    if mode = "stu2_lifecycle" then
        projdir = args[2]
        app = studio.launch(home)
        app = studio.create_registered_workspace(app, "ws")
        r = studio.open_file(app, "p", projdir + "/a.bas")
        app = r.app
        print "open a=" + r.status + " id=" + r.id
        r = studio.open_file(app, "p", projdir + "/./a.bas")
        app = r.app
        print "dup a=" + r.status + " id=" + r.id
        r = studio.open_file(app, "p", projdir + "/b.bas")
        app = r.app
        print "open b=" + r.status
        r = studio.open_file(app, "p", projdir + "/sub")
        app = r.app
        print "open dir=" + r.status
        r = studio.open_file(app, "p", projdir + "/ghost.bas")
        app = r.app
        print "open missing=" + r.status
        app = studio.edit_document(app, "doc-1", "edited content\n")
        print "-- after edit --"
        print studio.docs_summary(app)
        app = studio.edit_document(app, "doc-1", "aaa\n")
        d = studio_docs.doc_by_id(app.dm, "doc-1")
        print "revert clean=" + (not studio_docs.is_dirty(d))
        app = studio.edit_document(app, "doc-1", "saved by studio\n")
        sv = studio.save_document(app, "doc-1")
        app = sv.app
        print "save=" + sv.status
        print "-- final --"
        print studio.docs_summary(app)
        return
    end if

    if mode = "stu2_savefail" then
        app = studio.launch(home)
        app = studio.create_registered_workspace(app, "ws")
        r = studio.open_file(app, "", home + "/nodir/x.bas")
        app = r.app
        app = studio.edit_document(app, r.id, "content")
        sv = studio.save_document(app, r.id)
        app = sv.app
        d = studio_docs.doc_by_id(app.dm, r.id)
        print "savefail=" + sv.status + " dirty=" + studio_docs.is_dirty(d)
        return
    end if

    if mode = "stu2_close" then
        projdir = args[2]
        decision = "discard"
        if count(args) > 3 then
            decision = args[3]
        end if
        app = studio.launch(home)
        app = studio.create_registered_workspace(app, "ws")
        r = studio.open_file(app, "p", projdir + "/a.bas")
        app = r.app
        app = studio.edit_document(app, r.id, "dirty edit\n")
        c = studio.close_document(app, r.id, decision)
        app = c.app
        print "close(" + decision + ")=" + c.status + " open=" + count(app.dm.docs)
        return
    end if

    if mode = "stu2_restore" then
        projdir = args[2]
        app = studio.launch(home)
        app = studio.create_registered_workspace(app, "ws")
        r = studio.open_file(app, "p", projdir + "/a.bas")
        app = r.app
        app = studio.set_document_cursor(app, r.id, 2, 5)
        r = studio.open_file(app, "p", projdir + "/b.bas")
        app = r.app
        app = studio.set_document_cursor(app, r.id, 1, 3)
        app = studio.set_active_document(app, "doc-1")
        studio.persist(app)
        print "-- relaunch --"
        app2 = studio.launch(home)
        print studio.docs_summary(app2)
        return
    end if

    if mode = "stu2_missing_restore" then
        ' harness opens+persists, deletes the file, then runs this to relaunch.
        app = studio.launch(home)
        print studio.docs_summary(app)
        return
    end if

    if mode = "stu2_open_persist" then
        projdir = args[2]
        app = studio.launch(home)
        app = studio.create_registered_workspace(app, "ws")
        r = studio.open_file(app, "p", projdir + "/a.bas")
        app = r.app
        studio.persist(app)
        print "persisted id=" + r.id
        return
    end if

    if mode = "stu2_external" then
        projdir = args[2]
        app = studio.launch(home)
        app = studio.create_registered_workspace(app, "ws")
        r = studio.open_file(app, "p", projdir + "/a.bas")
        app = r.app
        r = studio.open_file(app, "p", projdir + "/b.bas")
        app = r.app
        r = studio.open_file(app, "p", projdir + "/c.bas")
        app = r.app
        ' a: clean, changed on disk; b: dirty, changed on disk; c: deleted
        ea(file) = projdir + "/a.bas"
        write(ea, "external change to a\n")
        app = studio.edit_document(app, "doc-2", "my unsaved edits\n")
        eb(file) = projdir + "/b.bas"
        write(eb, "external change to b\n")
        ec(file) = projdir + "/c.bas"
        delete(ec)
        cp = studio.checkpoint_documents(app)
        app = cp.app
        print "conflicts=" + join(cp.conflicts, ",")
        print "reloaded=" + join(cp.reloaded, ",")
        print "deleted=" + join(cp.deleted, ",")
        print studio.docs_summary(app)
        return
    end if

    if mode = "stu2_browser" then
        projdir = args[2]
        app = studio.launch(home)
        app = studio.create_registered_workspace(app, "ws")
        ws = app.model.workspace
        ws = studio_model.add_project(ws, "Alpha", projdir)
        app = studio.set_workspace(app, ws)
        ' simulate the browser selecting and opening a file
        proj = studio_model.project_by_id(ws, "proj-1")
        nodes = filetree.scan(proj.path, [])
        rows = filetree.flatten(nodes)
        picked = ""
        for each row in rows
            if row.kind = "file" then
                if picked = "" then
                    picked = row.path
                end if
            end if
        end for
        r = studio.open_from_browser(app, "proj-1", picked)
        app = r.app
        d = studio_docs.active_doc(app.dm)
        print "browser_opened=" + d.display_name + " active=" + app.dm.active
        return
    end if

    if mode = "stu2_cycles" then
        projdir = args[2]
        i = 0
        while i < 40
            a = studio.launch(home)
            a = studio.create_registered_workspace(a, "ws")
            rr = studio.open_file(a, "p", projdir + "/a.bas")
            a = rr.app
            a = studio.edit_document(a, rr.id, "cycle edit " + i + "\n")
            s2 = studio.save_document(a, rr.id)
            a = s2.app
            c2 = studio.close_document(a, rr.id, "discard")
            a = c2.app
            studio.persist(a)
            i = i + 1
        end while
        print "cycles_done=40"
        return
    end if

    ' ---- display modes (need GTK4 + a display) ----------------------------

    G = {}
    G.app = studio.launch(home)
    G.smoke = false
    G.shell = nothing
    G.sections = false
    G.doc_id = ""
    G.exec = false
    G.scratch = home + "/scratch"
    G.sess = nothing
    G.secs = nothing
    G.src = ""
    G.bar = nothing
    G.pane = nothing
    G.app_ref = nothing
    ' STU-5A: durable results for the display tier.
    G.results = false
    G.home = home
    G.doc_path = ""
    G.store = nothing
    G.rpane = nothing
    G.sid = ""
    ' STU-2B: input wiring state. `redrawing` is the re-entrancy guard that tells
    ' our own writes (set_current_page, set_text) apart from user input.
    G.redrawing = false
    G.last_action = ""
    ' STU-2D: the detail behind the last action (what the status line names), and
    ' the two pending confirmations — a path waiting on a second Delete, a
    ' document waiting on a second Close.
    G.last_detail = ""
    G.armed_path = ""
    G.armed_doc = ""
    G.armed_save = ""
    G.stu2b = false
    G.stu2b_cold = false
    G.phase = 0
    ' STU-2C: closing the window saves the session. Only the modes that mean to
    ' write a home do it — the smoke tiers assert their own output and must not
    ' grow a "saved=" line each.
    G.stu2c = false
    G.stu2d = false
    G.stu2e = false
    G.stu2f = false
    G.stu2g = false
    G.stu7 = false
    G.stu8 = false
    G.stu9 = false
    G.stu10 = false
    G.last_table_kind = ""
    G.fetch_action = ""
    G.table_win = nothing
    G.table_grid = nothing
    G.open_target = ""
    G.save_on_exit = false
    ' STU-6: the semantic action history. Loaded here, appended by the handlers,
    ' written by the exit path beside everything else.
    G.log = studio_history.open(home)
    if mode = "gui" then
        G.save_on_exit = true
    end if


    ' STU-2B display tier: a fixture workspace over a real project directory, then
    ' a sweep of synthesised clicks (see run_stu2b_probe).
    if mode = "stu2b_smoke" then
        G.stu2b = true
        projdir = args[2]
        G.app = studio.create_registered_workspace(G.app, "ws")
        ws = G.app.model.workspace
        ws = studio_model.add_project(ws, "Alpha", projdir)
        G.app = studio.set_workspace(G.app, ws)
    end if

    ' STU-2B cold home: nothing at all, and New Project as the only way in.
    if mode = "stu2b_cold" then
        G.stu2b_cold = true
    end if

    ' STU-2C: cold home to a working project using only the window, then close it
    ' and let the exit path write the home the harness reopens.
    if mode = "stu2c_smoke" then
        G.stu2c = true
        G.save_on_exit = true
    end if

    ' STU-2D: the name field, Rename, and Delete's two clicks, over a real
    ' project directory.
    if mode = "stu2d_smoke" then
        G.stu2d = true
        projdir = args[2]
        G.app = studio.create_registered_workspace(G.app, "ws")
        ws = G.app.model.workspace
        ws = studio_model.add_project(ws, "Alpha", projdir)
        G.app = studio.set_workspace(G.app, ws)
    end if

    ' STU-2C': Open Folder, typed into the name field and clicked for real.
    if mode = "stu2g_smoke" then
        G.stu2g = true
        G.open_target = args[2]
    end if

    ' STU-7: the inline branch selector, clicked for real.
    if mode = "stu10_smoke" then
        G.stu10 = true
        projdir = args[2]
        G.app = studio.create_registered_workspace(G.app, "ws")
        ws = G.app.model.workspace
        ws = studio_model.add_project(ws, "Alpha", projdir)
        G.app = studio.set_workspace(G.app, ws)
        ro = studio.open_from_browser(G.app, "proj-1", projdir + "/branchy.bas")
        G.app = ro.app
        G.app.clock_fixed = 1000
    end if

    if mode = "stu9_smoke" then
        G.stu9 = true
        projdir = args[2]
        G.app = studio.create_registered_workspace(G.app, "ws")
        ws = G.app.model.workspace
        ws = studio_model.add_project(ws, "Alpha", projdir)
        G.app = studio.set_workspace(G.app, ws)
        ro = studio.open_from_browser(G.app, "proj-1", projdir + "/branchy.bas")
        G.app = ro.app
        G.app.clock_fixed = 1000
    end if

    if mode = "stu8_smoke" then
        G.stu8 = true
        projdir = args[2]
        G.app = studio.create_registered_workspace(G.app, "ws")
        ws = G.app.model.workspace
        ws = studio_model.add_project(ws, "Alpha", projdir)
        G.app = studio.set_workspace(G.app, ws)
        ro = studio.open_from_browser(G.app, "proj-1", projdir + "/tabular.bas")
        G.app = ro.app
        G.app.clock_fixed = 1000
    end if

    if mode = "stu7_smoke" then
        G.stu7 = true
        projdir = args[2]
        G.app = studio.create_registered_workspace(G.app, "ws")
        ws = G.app.model.workspace
        ws = studio_model.add_project(ws, "Alpha", projdir)
        G.app = studio.set_workspace(G.app, ws)
        ro = studio.open_from_browser(G.app, "proj-1", projdir + "/branchy.bas")
        G.app = ro.app
        G.app.dm = studio_docs.set_cursor(G.app.dm, ro.id, 7, 1)
        G.app.clock_fixed = 1000
    end if

    ' STU-2E: Run Section, clicked for real, with a document open and its cursor
    ' in the last section so the run has a prefix to replay.
    if mode = "stu2e_smoke" then
        G.stu2e = true
        projdir = args[2]
        G.app = studio.create_registered_workspace(G.app, "ws")
        ws = G.app.model.workspace
        ws = studio_model.add_project(ws, "Alpha", projdir)
        G.app = studio.set_workspace(G.app, ws)
        ro = studio.open_from_browser(G.app, "proj-1", projdir + "/runme.bas")
        G.app = ro.app
        ' The editor's caret is where on_run reads from, and the shell puts it at
        ' the top of a freshly opened buffer, so move the DOCUMENT's cursor is not
        ' enough — stu2e_step clicks Run with the caret wherever the editor has it,
        ' which is line 0. Section 1 it is: a run with no prefix is still a run,
        ' and the prefix pane saying so is part of what this checks.
        G.app.clock_fixed = 1000
    end if

    ' STU-5A′: the caret drives the panes. Same fixture as stu2e_smoke, but
    ' nothing is clicked until the caret has been moved twice.
    if mode = "stu2f_smoke" then
        G.stu2f = true
        projdir = args[2]
        G.app = studio.create_registered_workspace(G.app, "ws")
        ws = G.app.model.workspace
        ws = studio_model.add_project(ws, "Alpha", projdir)
        G.app = studio.set_workspace(G.app, ws)
        ro = studio.open_from_browser(G.app, "proj-1", projdir + "/runme.bas")
        G.app = ro.app
        G.app.clock_fixed = 1000
    end if

    if mode = "smoke" then
        G.smoke = true
        G.app = build_canned(G.app)
    end if
    if mode = "stu2_smoke" then
        G.smoke = true
        G.app = studio.create_registered_workspace(G.app, "ws")
        docfile = ".gbasic-studio-doc.bas"
        if count(args) > 2 then
            docfile = args[2]
        end if
        r = studio.open_file(G.app, "", docfile)
        G.app = r.app
        G.app = studio.edit_document(G.app, r.id, "' edited in Studio\nprint(\"hi\")\n")
    end if
    ' STU-3 display check: the section engine driven from the REAL editor state
    ' (live document buffer + the document's line/column cursor) with the GTK shell
    ' built. STU-3 renders no widgets of its own (boundary rendering is STU-5), so
    ' what this proves is the integration: buffer -> sections, cursor -> section id,
    ' under a real display and a real editor tab.
    if mode = "stu3_smoke" then
        G.smoke = true
        G.sections = true
        G.app = studio.create_registered_workspace(G.app, "ws")
        docfile = ".gbasic-studio-doc.bas"
        if count(args) > 2 then
            docfile = args[2]
        end if
        r = studio.open_file(G.app, "", docfile)
        G.app = r.app
        G.doc_id = r.id
        G.app = studio.edit_document(G.app, r.id, "x = 1\n\nfunction add(a, b)\n  return a + b\nend function\n\nprint add(x, 2)\n")
        G.app.dm = studio_docs.set_cursor(G.app.dm, r.id, 4, 3)
    end if

    if mode = "stu4_smoke" then
        G.smoke = true
        G.exec = true
        G.app = studio.create_registered_workspace(G.app, "ws")
        docfile = ".gbasic-studio-exec.bas"
        if count(args) > 2 then
            docfile = args[2]
        end if
        r = studio.open_file(G.app, "", docfile)
        G.app = r.app
        G.doc_id = r.id
        G.app = studio.edit_document(G.app, r.id, "print \"first\"\n\nfunction add(a, b)\n  return a + b\nend function\n\nprint add(2, 3)\n")
        ' Cursor inside the LAST section, so the run replays the prefix above it.
        G.app.dm = studio_docs.set_cursor(G.app.dm, r.id, 7, 1)
        studio_session.sweep_scratch(G.scratch)
    end if

    ' STU-5A display check: the same real run as stu4_smoke, but its result is
    ' RECORDED, persisted, and rendered in the results pane -- and then the section
    ' is edited so the pane's stale-content mark is exercised through the actual UI
    ' path rather than only in the headless goldens.
    if mode = "stu5_smoke" then
        G.smoke = true
        G.exec = true
        G.results = true
        G.app = studio.create_registered_workspace(G.app, "ws")
        docfile = ".gbasic-studio-results.bas"
        if count(args) > 2 then
            docfile = args[2]
        end if
        r = studio.open_file(G.app, "", docfile)
        G.app = r.app
        G.doc_id = r.id
        G.doc_path = docfile
        G.app = studio.edit_document(G.app, r.id, "print \"first\"\n\nfunction add(a, b)\n  return a + b\nend function\n\nprint add(2, 3)\n")
        G.app.dm = studio_docs.set_cursor(G.app.dm, r.id, 7, 1)
        studio_session.sweep_scratch(G.scratch)
    end if

    load gi
    load gtk
    load sourceeditor
    load studio_ui
    load llm
    load studio_tools
    load studio_agent
    load studio_shell
    load studio_table
    load studio_teaching
    load studio_permissions
    load datagrid
    gi.require("Gtk", "4.0")

    ' STU-8: the DataGrid's per-grid state has to be reachable from a factory
    ' "bind" signal that GTK invokes with only (factory, item). gBASIC has no
    ' closures, so the component finds its grid through a program global — one
    ' line, at program scope, exactly as datagrid.bas documents. It goes AFTER the
    ' loads, not beside the other globals: `load` is not hoisted, and datagrid is
    ' loaded here rather than at the top because it pulls in gi, which the
    ' headless modes must never touch.
    _DATAGRID = datagrid.new_registry()
    ' And the same shape for the row source behind a virtual grid: the cell
    ' callback is handed (index, ordinal) and nothing else, so the source it reads
    ' — and the decode cache it fills — live here.
    _STUDIO_TABLE = { src: nothing }

    ' STU-2C: an existing directory can be opened as a project from the command
    ' line — `./studio gui <home> <folder>`. There is no button for it, because a
    ' folder chooser is an async GTK dialog with no signal a test can synthesise,
    ' and smuggling one in as a handler callback is exactly the design failure the
    ' interaction rule forbids. The DECISION is a plain function either way, so
    ' the phase that adds a dialog only has to add the adapter in front of it.
    if mode = "gui" then
        if count(args) > 2 then
            folder = args[2]
            if folder != "" then
                ad = studio_ui.adopt_folder(G.app, folder)
                G.app = ad.app
                if ad.action = "missing" then
                    print to error "no such directory: " + folder
                end if
            end if
        end if
    end if

    ' NON_UNIQUE, deliberately. `gtk.application(id)` builds a GtkApplication with
    ' default flags, which makes it SINGLE-INSTANCE: a second `./studio` does not
    ' open a second window at all — it registers as a remote, forwards "activate"
    ' to the first process and exits. That is wrong twice over. A user with two
    ' projects gets one window and no explanation, and the process that IS running
    ' receives an extra "activate", builds a SECOND shell over the same globals and
    ' ends up with two of every handler — which is how it first showed itself here,
    ' as a display tier that occasionally saw one click land twice.
    '
    ' `gtk` has no flags parameter (it wraps GTK, it does not replace it — its
    ' header says to drop to `gi` for anything unwrapped), so this is the one place
    ' the application object is built by hand.
    gi.require("Gio", "2.0")
    solo = gi.enum("Gio.ApplicationFlags.NON_UNIQUE")
    gtkapp = gi.new("Gtk.Application", "application-id", "org.gbasic.Studio", "flags", solo)
    G.app_ref = gtkapp
    gi.connect(gtkapp, "activate", on_activate)
    gi.call(gtkapp, "run", 0, nothing)

    ' STU-2C: the loop has returned, so the window is gone — save the session.
    ' STU-2B left this out and nothing a user did in the GUI survived closing it:
    ' the restore path existed and was tested, but was never called from here.
    '
    ' What is saved is the workspace, session and settings — which projects and
    ' documents were open, not what was typed into them. Studio has no draft
    ' store, so unsaved buffers are lost, and saying so is better than letting
    ' them vanish quietly.
    if G.save_on_exit then
        unsaved = studio_ui.dirty_count(G.app)
        if unsaved > 0 then
            print to error "warning: " + unsaved + " document(s) had unsaved changes; Studio does not keep drafts"
        end if
        saved = studio.persist(G.app)
        studio_history.save(home, G.log)
        print "saved=" + join(saved, ",")
    end if
    print "app-exited"
end program
