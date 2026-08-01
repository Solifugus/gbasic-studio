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
    r = studio_shell.refresh(G.shell, G.app)
    G.shell = r.shell
    ' A redraw can create pages, and a new page's buffer has never been wired.
    ' This is the only place editors are connected, so no page can exist unwired.
    for each ne in r.new_editors
        ed = ne.editor
        gi.connect(ed.buffer, "changed", on_buffer_changed)
    end for
    G.redrawing = false
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
    redraw()
    return nothing
end function

function on_new_project()
    r = studio_ui.new_project(G.app, G.home)
    G.app = r.app
    G.last_action = r.action
    redraw()
    return nothing
end function

function on_new_file()
    r = studio_ui.new_file(G.app)
    G.app = r.app
    G.last_action = r.action
    redraw()
    return nothing
end function

function on_new_folder()
    r = studio_ui.new_folder(G.app)
    G.app = r.app
    G.last_action = r.action
    redraw()
    return nothing
end function

function on_save()
    r = studio_ui.save_active(G.app)
    G.app = r.app
    G.last_action = r.action
    redraw()
    return nothing
end function

function on_refresh()
    r = studio_ui.refresh(G.app)
    G.app = r.app
    G.last_action = r.action
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
    gi.connect(sh.save_btn, "clicked", on_save)
    gi.connect(sh.refresh_btn, "clicked", on_refresh)
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
    G.stu2b = false
    G.stu2b_cold = false
    G.phase = 0
    ' STU-2C: closing the window saves the session. Only the modes that mean to
    ' write a home do it — the smoke tiers assert their own output and must not
    ' grow a "saved=" line each.
    G.stu2c = false
    G.save_on_exit = false
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
    load studio_shell
    gi.require("Gtk", "4.0")

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

    gtkapp = gtk.application("org.gbasic.Studio")
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
        print "saved=" + join(saved, ",")
    end if
    print "app-exited"
end program
