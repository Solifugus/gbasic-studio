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

' GTK activate handler (display modes only). Reads the global G assembled in main.
function on_activate(gtkapp)
    shell = studio_shell.build(gtkapp, G.app)
    G.shell = shell
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
    load studio_shell
    gi.require("Gtk", "4.0")

    gtkapp = gtk.application("org.gbasic.Studio")
    G.app_ref = gtkapp
    gi.connect(gtkapp, "activate", on_activate)
    gi.call(gtkapp, "run", 0, nothing)
    print "app-exited"
end program
