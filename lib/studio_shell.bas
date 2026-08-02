' studio_shell.bas — the gBASIC Studio application shell (GTK 4, over gtk.bas).
'
' STU-1/STU-2 scope: a usable NAVIGATION + EDITING shell — a filesystem project
' browser tree (left) and a notebook of source-editor tabs for the open documents
' (right), plus a status bar. It is a pure VIEW over the app model studio.bas owns
' (the workspace navigation model and the document manager app.dm): it reads the
' model (and scans the filesystem via filetree) to populate itself and holds
' no document state of its own. Interactive wiring (browser row -> open, editor edit
' -> document manager) is owned by the entry program's handlers over a global app
' record, so the callback-scope rules are respected.
'
' Requires gi + gtk + filetree + studio_docs + sourceeditor loaded and GTK
' initialized, so it is only used in the display modes; the headless lifecycle and
' tests never touch it.
library studio_shell


    ' Dependencies, declared rather than assumed. A library that calls into
    ' another must load it: relying on the caller to have done so turns a
    ' missing load into a runtime failure deep inside a call, and it stops
    ' working entirely once these libraries live in separate projects.
    ' `gi` is back (STU-2B dropped it as dead) for the one widget `gtk` does not
    ' wrap — a GtkEntry. Note that gi.connect still lives ONLY in app/studio.bas.
    load gi
    load gtk
    load sourceeditor
    load studio_docs
    load studio_results
    load studio_ui
    ' ---- STU-2B: redraw ------------------------------------------------------
    '
    ' A mutation redraws by calling `refresh` — there is one such function, and it
    ' brings every region of the window back into agreement with the model. Making
    ' it one function rather than a per-region set is deliberate: an interaction
    ' that forgot to redraw region X would be a bug that only shows on screen, and
    ' the headless suite could never catch it.
    '
    ' The navigation pane REBUILDS and the notebook RECONCILES, and the asymmetry
    ' is forced rather than chosen. A nav row is a label with no state a user can
    ' lose, and rebuilding it keeps the widget list and the row model identical by
    ' construction — the property `activate_row` depends on. A notebook page holds
    ' a live GtkSourceBuffer containing UNSAVED TEXT and a cursor; rebuilding one
    ' would destroy exactly the thing the user is in the middle of. So pages are
    ' matched by document id and created once.
    '
    ' Returns { shell, new_editors: [ { doc_id, editor } ] }. The editors are
    ' handed back rather than connected here because `gi.connect` lives only in the
    ' entry program (see this file's header) — a page created during a redraw still
    ' needs its buffer wired, and this is how the caller learns it exists.

    ' Rebuild the navigation listbox from the shared row model. The rows used are
    ' stored on the shell, so a later click resolves its index against the array
    ' that produced the widgets rather than a freshly-scanned one.
    function _fill_nav(nav, app)
        rows = studio_ui.nav_rows(app)
        studio_shell._clear_listbox(nav)
        for each r in rows
            nav.append(gtk.label(r.label))
        end for
        return rows
    end function

    ' Empty a GtkListBox by repeatedly removing row 0. `remove_all` would be one
    ' call but is GTK 4.12+; this form has no version floor.
    function _clear_listbox(lb)
        row = lb.get_row_at_index(0)
        while row != nothing
            lb.remove(row)
            row = lb.get_row_at_index(0)
        end while
        return nothing
    end function

    ' Bring the whole window back into agreement with the model.
    ' `notice` is what the last interaction had to say (STU-2D). It replaces the
    ' standing status line when it is non-empty, so a refusal — a name already
    ' taken, a directory that is not empty, a delete waiting for its second click
    ' — is visible instead of looking like a dead button. `clear_name` empties the
    ' header's name field once a creation or rename has consumed it.
    function refresh(shell, app, notice, clear_name)
        shell.rows = studio_shell._fill_nav(shell.nav, app)
        rec = studio_shell._reconcile_tabs(shell, app)
        shell = rec.shell
        rr = studio_shell.refresh_run(shell, app)
        shell = rr.shell
        app = rr.app
        line = studio_shell.status_text(app)
        if notice != "" then
            line = notice
        end if
        shell.status.label = line
        if clear_name then
            shell.name_entry.text = ""
        end if
        return { shell: shell, app: app, new_editors: rec.new_editors }
    end function

    ' The run strip and its two output panes and the results pane — everything a
    ' run moves, and nothing else.
    '
    ' This is separate from `refresh` on purpose. A run is polled about sixteen
    ' times a second, and a full redraw rebuilds the whole browser pane; doing that
    ' on every tick would fight the user for their own file tree while a program
    ' ran. `refresh` calls it too, so an ordinary redraw never leaves the strip
    ' behind.
    ' Returns { shell, app }, and the app matters: what the panes show is derived
    ' through `studio_ui.view_for`, which CACHES the section outline on the app
    ' record. Dropping the returned app would re-parse the document on every
    ' render — and this renders on every cursor move.
    function refresh_run(shell, app)
        v = studio_ui.view_for(app)
        app = v.app
        sess = studio_ui.exec_session(app)
        shell.bar.state.label = studio_ui.run_line(sess)
        shell.bar.section.label = studio_ui.section_label(app)
        shell.bar.standing.label = studio_ui.standing_line(app)
        shell.pane.prefix.label = studio_ui.prefix_body(app)
        shell.pane.target.label = studio_ui.target_body(app)
        shell.pane.errors.label = studio_ui.error_body(app)
        shell.rpane.body.label = studio_ui.results_body(app)
        d = studio_shell._decorate(shell, app)
        return { shell: d.shell, app: d.app }
    end function

    ' STU-5: draw the sections into the source itself — a gutter mark where each
    ' one starts, and a tint over the one the caret is in.
    '
    ' The marks are redrawn only when the outline's REVISION changes. That number
    ' moves on an edit and not on a caret move, and this runs on every caret move.
    function _decorate(shell, app)
        ed = studio_shell.editor_for(shell, app.dm.active)
        if ed = nothing then
            return { shell: shell, app: app }
        end if
        m = studio_ui.section_marks(app)
        app = m.app
        if shell.marked[m.doc_id] != m.revision then
            buf = ed.buffer
            ' `_iter` unwraps GTK's out-parameter record; the bridge hands the
            ' iterator back inside one, and remove_source_marks wants the value.
            s = sourceeditor._iter(buf.get_start_iter())
            e = sourceeditor._iter(buf.get_end_iter())
            buf.remove_source_marks(s, e, "section")
            for each ln in m.lines
                ed.mark(ln, "section")
            end for
            shell.marked[m.doc_id] = m.revision
        end if

        ' One tag at a time, removed from the editor that owns it — a tag belongs
        ' to its buffer, and switching tabs would otherwise leave the old document
        ' permanently tinted.
        if shell.hl_tag != nothing then
            owner = studio_shell.editor_for(shell, shell.hl_doc)
            if owner != nothing then
                owner.unhighlight(shell.hl_tag)
            end if
            shell.hl_tag = nothing
        end if
        r = studio_ui.current_range(app)
        app = r.app
        if r.ok then
            shell.hl_tag = ed.highlight(r.start0, r.end0, "#eaf1fb")
            shell.hl_doc = m.doc_id
        end if
        return { shell: shell, app: app }
    end function

    ' The live editor behind a document id, or nothing. The handler that starts a
    ' run needs it to read where the caret actually is.
    function editor_for(shell, doc_id)
        for each pg in shell.pages
            if pg.doc_id = doc_id then
                return pg.editor
            end if
        end for
        return nothing
    end function

    ' Match notebook pages to open documents by document id: drop pages whose
    ' document is gone, create pages for documents that have none, refresh every
    ' label, and select the active document's page.
    function _reconcile_tabs(shell, app)
        book = shell.notebook
        want = studio_ui.tab_rows(app)
        new_editors = []

        ' Drop the welcome placeholder as soon as there is a real document, and
        ' put it back when the last one closes, so the notebook is never empty.
        if count(want) = 0 then
            if count(shell.pages) > 0 or shell.welcome = false then
                studio_shell._clear_pages(shell)
                shell.pages = []
            end if
            if shell.welcome = false then
                book.append_page(gtk.label("(no document open)"), gtk.label("Welcome"))
                shell.welcome = true
            end if
            return { shell: shell, new_editors: new_editors }
        end if
        if shell.welcome then
            studio_shell._clear_pages(shell)
            shell.welcome = false
        end if

        ' Remove pages whose document has closed (back to front, so the indexes
        ' ahead of the one being removed stay valid).
        kept = []
        i = count(shell.pages) - 1
        while i >= 0
            pg = shell.pages[i]
            if studio_shell._wanted(want, pg.doc_id) then
                kept = append(kept, pg)
            else
                book.remove_page(i)
            end if
            i = i - 1
        end while
        shell.pages = studio_shell._reverse(kept)

        ' Create a page for every document that does not have one yet.
        for each t in want
            have = studio_shell._page_index(shell.pages, t.doc_id)
            if have < 0 then
                doc = studio_docs.doc_by_id(app.dm, t.doc_id)
                ed = sourceeditor.create()
                ed.set_text(doc.content)
                ed.set_language("gbasic")
                ' Setting a buffer's text leaves the caret at the END of it, so a
                ' just-opened file starts scrolled to the bottom with the cursor
                ' past the last line. Every editor puts it at the top instead —
                ' and STU-2E made it matter, because Run reads the caret to decide
                ' which section to run.
                ed.set_cursor(0, 0)
                ' STU-5: line marks are invisible until the view is told to show
                ' them and the category has attributes to draw with.
                vw = ed.view()
                vw.set_show_line_marks(true)
                at = gi.new("GtkSource.MarkAttributes")
                at.set_icon_name("media-playback-start-symbolic")
                vw.set_mark_attributes("section", at, 1)
                sc = gtk.scrolled(ed.view())
                sc.vexpand = true
                sc.hexpand = true
                book.append_page(sc, gtk.label(t.label))
                shell.pages = append(shell.pages, { doc_id: t.doc_id, editor: ed, child: sc })
                new_editors = append(new_editors, { doc_id: t.doc_id, editor: ed })
            end if
        end for

        ' Labels change without the page doing so (a dirty marker appearing), and
        ' a document's CONTENT can change underneath a live buffer when Refresh
        ' reloads a file from disk. Push text only when it actually differs: an
        ' unconditional set_text would fire "changed" on every redraw and re-dirty
        ' every tab in the window.
        idx = 0
        active_page = 0
        while idx < count(shell.pages)
            pg = shell.pages[idx]
            t = want[idx]
            book.set_tab_label(pg.child, gtk.label(t.label))
            doc = studio_docs.doc_by_id(app.dm, pg.doc_id)
            ed = pg.editor
            shown = ed.get_text()
            if shown != doc.content then
                ed.set_text(doc.content)
            end if
            if pg.doc_id = app.dm.active then
                active_page = idx
            end if
            idx = idx + 1
        end while
        book.set_current_page(active_page)

        return { shell: shell, new_editors: new_editors }
    end function

    function _wanted(want, doc_id)
        for each t in want
            if t.doc_id = doc_id then
                return true
            end if
        end for
        return false
    end function

    function _page_index(pages, doc_id)
        i = 0
        while i < count(pages)
            pg = pages[i]
            if pg.doc_id = doc_id then
                return i
            end if
            i = i + 1
        end while
        return -1
    end function

    function _reverse(arr)
        out = []
        i = count(arr) - 1
        while i >= 0
            out = append(out, arr[i])
            i = i - 1
        end while
        return out
    end function

    ' Remove every page from the notebook (used only when swapping the welcome
    ' placeholder in or out; live document pages are never cleared wholesale).
    function _clear_pages(shell)
        book = shell.notebook
        n = book.get_n_pages()
        i = n - 1
        while i >= 0
            book.remove_page(i)
            i = i - 1
        end while
        return nothing
    end function

    ' Build the main window from the app model and present it. Returns a record of
    ' widget references so the caller (and later phases) can bind to them.
    function build(gtkapp, app)
        model = app.model
        ws = model.workspace

        win = gtk.application_window(gtkapp)
        title = "gBASIC Studio"
        if ws != nothing then
            title = "gBASIC Studio — " + ws.name
        end if
        win.title = title
        win.default_width = model.session.window.width
        win.default_height = model.session.window.height

        outer = gtk.box("v", 0)

        ' --- header / menu strip ---
        ' The buttons are returned, not connected: `gi.connect` lives only in the
        ' entry program (see this file's header).
        header = gtk.box("h", 6)
        header.append(gtk.label("gBASIC Studio"))
        new_btn = gtk.button("New Project")
        file_btn = gtk.button("New File")
        folder_btn = gtk.button("New Folder")
        ' STU-2D's name field. `gtk` has no entry constructor, and that library
        ' says so on purpose ("callers drop straight down to the raw gi bridge for
        ' anything not wrapped here"), so this is one gi.new rather than a change
        ' to somebody else's stdlib.
        '
        ' It is a field and not a dialog because a GtkEntry is an ordinary widget:
        ' its text can be set programmatically, which means the display tier can
        ' type into it and click Rename for real. A modal dialog could not be
        ' driven by any test we can write.
        name_entry = gi.new("Gtk.Entry")
        name_entry.placeholder_text = "name"
        rename_btn = gtk.button("Rename")
        delete_btn = gtk.button("Delete")
        close_btn = gtk.button("Close")
        save_btn = gtk.button("Save")
        refresh_btn = gtk.button("Refresh")
        header.append(new_btn)
        header.append(file_btn)
        header.append(folder_btn)
        header.append(name_entry)
        header.append(rename_btn)
        header.append(delete_btn)
        header.append(close_btn)
        header.append(save_btn)
        header.append(refresh_btn)
        outer.append(header)

        ' --- main split: project browser | editor tab notebook ---
        split = gtk.paned("h")
        split.vexpand = true

        nav = gtk.listbox()
        nav_scroll = gtk.scrolled(nav)
        split.set_start_child(nav_scroll)
        split.position = 260

        book = gtk.notebook()

        ' STU-2E mounts what STU-4 and STU-5A built. Both were only ever
        ' constructed by the smoke modes: `run_bar` and `output_pane` and
        ' `results_pane` existed as builders that nothing in the real window
        ' called, which is why the run strip has been listed as "built but does not
        ' respond" since STU-4.
        '
        ' Editor on top, run below, split so the user decides how much of each they
        ' want. The panes go in a scrolled window because a section's output is
        ' unbounded and a label that grows without one drags the whole window wider.
        bar = studio_shell.run_bar()
        pane = studio_shell.output_pane()
        rpane = studio_shell.results_pane()
        under = gtk.box("v", 4)
        under.append(bar.box)
        under.append(pane.box)
        under.append(rpane.box)

        vsplit = gtk.paned("v")
        vsplit.set_start_child(book)
        vsplit.set_end_child(gtk.scrolled(under))
        vsplit.position = 420
        split.set_end_child(vsplit)

        outer.append(split)

        ' --- status bar ---
        status = gtk.label(studio_shell.status_text(app))
        outer.append(status)

        win.set_child(outer)

        ' The window is built EMPTY and then filled by the ONE redraw path, so the
        ' first paint and every later one are produced by the same code. A separate
        ' initial-population path is how a view starts disagreeing with its
        ' refresh.
        '
        ' It is deliberately NOT presented here. Presenting an empty window makes
        ' GTK allocate scrolled windows that have no child yet, and it complains
        ' ("GtkGizmo (slider) reported min width -2"). The caller presents after
        ' the first refresh — see `present` below.
        return { window: win, status: status, nav: nav, notebook: book,
                 new_btn: new_btn, file_btn: file_btn, folder_btn: folder_btn,
                 name_entry: name_entry, rename_btn: rename_btn,
                 delete_btn: delete_btn, close_btn: close_btn,
                 save_btn: save_btn, refresh_btn: refresh_btn,
                 bar: bar, pane: pane, rpane: rpane,
                 ' STU-5 decoration state: which outline revision each document's
                 ' gutter marks were drawn for, and the one live highlight tag.
                 marked: {}, hl_tag: nothing, hl_doc: "",
                 rows: [], pages: [], welcome: false }
    end function

    ' Show the window. Call it after the first refresh, never before.
    function present(shell)
        shell.window.present()
        return nothing
    end function

    ' A tab label with markers: "! " missing, "* " dirty (unsaved), then the name.
    ' Defined in studio_ui so the headless goldens and the notebook cannot render a
    ' tab differently; kept here under its established name for existing callers.
    function tab_label(doc)
        return studio_ui.tab_label(doc)
    end function

    ' ---- STU-4: execution strip + output pane ------------------------------
    '
    ' Deliberately minimal (STU-4 scope): run / stop / force-stop, the session state,
    ' and an output pane that keeps PREFIX output visually separate from TARGET
    ' output. No results history, no inspector, no gutter work -- those are STU-5.
    '
    ' The widgets are returned rather than wired: like the rest of this shell, the
    ' entry program owns the handlers over its global app record, because a callback
    ' cannot rebind a top-level scalar.

    function run_bar()
        bar = gtk.box("h", 6)
        run_btn = gtk.button("Run Section")
        halt_btn = gtk.button("Stop")
        force_btn = gtk.button("Force Stop")
        state = gtk.label("run: idle")
        ' STU-5A′: which section Run would run, shown BEFORE you press it rather
        ' than after. It follows the caret.
        section = gtk.label("section: (none)")
        ' STU-5 §10.3: whether what you are looking at is live in this session or
        ' a record from an earlier one.
        standing = gtk.label("")
        bar.append(run_btn)
        bar.append(halt_btn)
        bar.append(force_btn)
        bar.append(state)
        bar.append(section)
        bar.append(standing)
        ' `stop` is a gBASIC keyword and cannot be a record key, hence `halt`.
        return { box: bar, run: run_btn, halt: halt_btn, force: force_btn,
                 state: state, section: section, standing: standing }
    end function

    ' These three moved to studio_ui in STU-2E and stayed here as delegates. They
    ' were always pure functions over a session record, but they lived in a file
    ' that loads GTK, so the headless suite could not call them — and the run
    ' strip's text is the only feedback a run gives. The names are kept because the
    ' STU-4/5A display goldens print through them.
    function session_text(session)
        return studio_ui.run_line(session)
    end function

    function output_pane()
        box = gtk.box("v", 4)
        prefix_head = gtk.label("Prefix output — sections replayed before the target")
        prefix_body = gtk.label("")
        target_head = gtk.label("Target output — the section you ran")
        target_body = gtk.label("")
        ' STU-5: a section's errors had nowhere to go. The child's stderr was
        ' captured, attributed and stored, and the window showed none of it.
        error_head = gtk.label("Errors")
        error_body = gtk.label("")
        box.append(prefix_head)
        box.append(prefix_body)
        box.append(target_head)
        box.append(target_body)
        box.append(error_head)
        box.append(error_body)
        return { box: box, prefix: prefix_body, target: target_body, errors: error_body }
    end function

    function output_prefix_text(session)
        return studio_ui.prefix_text(session)
    end function

    function output_target_text(session)
        return studio_ui.target_text(session)
    end function

    ' ---- STU-5A: the results pane ------------------------------------------
    '
    ' Deliberately minimal (STU-5A scope): the latest result for the section at the
    ' cursor, the history behind it, and -- the part that is not optional -- a
    ' visible mark whenever a result's fingerprint no longer matches the section's
    ' current content. No inspector, no diffing, no charts.
    '
    ' Section ids are stable across edits by design, so a results pane keyed by id
    ' alone would show a run of code the user has since replaced as though it
    ' described what is on screen. The mark is what stops that.

    function results_pane()
        box = gtk.box("v", 4)
        head = gtk.label("Results — the section at the cursor")
        body = gtk.label("")
        box.append(head)
        box.append(body)
        return { box: box, head: head, body: body }
    end function

    ' The pane's text for `section_id` against the CURRENT sections. Delegates the
    ' wording to studio_results so the headless goldens and the display tier can
    ' never drift apart -- the view is one function, rendered in two places.
    function results_text(home, store, sections, section_id)
        if store = nothing then
            return "Results\n(no results store)"
        end if
        if section_id = "" then
            return "Results\n(no section at the cursor)"
        end if
        return studio_results.view_text(home, store, sections, section_id)
    end function

    function status_text(app)
        ws = app.model.workspace
        base = "ready"
        if ws != nothing then
            base = "ready — " + ws.name + " — " + count(ws.projects) + " project(s)"
        end if
        n = count(app.dm.docs)
        return base + " — " + n + " open"
    end function

end library
