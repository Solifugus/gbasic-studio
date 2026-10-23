' SPDX-License-Identifier: Apache-2.0
' Copyright 2026 Matthew C. Tedder. See LICENSE.

' ============================================================================
' studio_cli.bas — gBASIC Studio's HEADLESS modes.
'
' The lifecycle and navigation modes the backbone is tested through, with no
' window and no toolkit loaded at all. They lived in the GTK entry point until
' GTK went; they never touched it, and keeping them in an entry that loads no
' toolkit is what lets them keep running on a machine with no display.
'
' Modes (first program argument):
'   startup   <home>       — run the startup pipeline, print the model summary
'   build     <home>       — startup, build a canned workspace, shut down (persist)
'   roundtrip <home>       — build + shut down + relaunch; print restored summary
'   stress    <home>       — repeated atomic save/reload; assert every reload loads
'   cycles    <home>       — 50 startup/shutdown cycles (memory/leak probe)
'   stu1_* / stu2_*        — the navigation and document modes the suite drives
'
' The window is `app/studio.bas`; `./studio <mode>` picks between the two.
' ============================================================================

' Build a fixed, deterministic workspace (stable ids from the counters) so the
' save/restore and shell modes have identical, assertable state every run.
function build_canned(app)
    app = studio.create_workspace(app, "member-analytics")
    ws = app.model.workspace
    ws = studio_model.add_project(ws, "Analytics", "/home/u/analytics")
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
        shutdown_result = studio.shutdown(app)
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
            shutdown_result = studio.shutdown(app)
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
            shutdown_result = studio.shutdown(a)
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

    ' A home written BEFORE the workspace was demoted: its projects live in
    ' workspaces/<id>.json and session.json only points at it. Launching must
    ' find them, and the old file must still be there afterwards — it is the
    ' only copy of that state until the first clean save, and an upgrade that
    ' tidies away a user's only copy is not an upgrade.
    if mode = "stu1_migrate" then
        persist.ensure_dir(home)
        persist.ensure_dir(home + "/workspaces")
        legacy_ws = studio_model.new_workspace("ws-1", "old-home")
        legacy_ws = studio_model.add_project(legacy_ws, "Alpha", "/home/u/alpha")
        legacy_ws = studio_model.add_project(legacy_ws, "Beta", "/home/u/beta")
        legacy_ws = studio_model.set_active_project(legacy_ws, "proj-2")
        persist.write_atomic(home + "/workspaces/ws-1.json", legacy_ws)
        legacy_session = studio_model.default_session()
        legacy_session.active_workspace = "ws-1"
        persist.write_atomic(home + "/session.json", legacy_session)

        print "-- launching the old home --"
        app = studio.launch(home)
        print studio.summary(app)

        print "-- saving it forward --"
        saved = studio.persist(app)
        print "saved=" + join(saved, ",")
        legacy_probe{file} = home + "/workspaces/ws-1.json"
        print "old file still there=" + exists(legacy_probe)

        print "-- and the next launch reads the session, not the old file --"
        again = studio.launch(home)
        print studio.summary(again)
        return
    end if

    if mode = "stu1_cycles" then
        i = 0
        while i < 50
            a = studio.launch(home)
            persist_result = studio.persist(a)
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
        persist_result = studio.persist(app)
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
        persist_result = studio.persist(app)
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
        ea{file} = projdir + "/a.bas"
        write(ea, "external change to a\n")
        app = studio.edit_document(app, "doc-2", "my unsaved edits\n")
        eb{file} = projdir + "/b.bas"
        write(eb, "external change to b\n")
        ec{file} = projdir + "/c.bas"
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
            persist_result = studio.persist(a)
            i = i + 1
        end while
        print "cycles_done=40"
        return
    end if

    print to error "studio_cli: no headless mode named " + quote(mode)
end program
