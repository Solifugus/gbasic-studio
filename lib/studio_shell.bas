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
    function refresh(shell, app)
        shell.rows = studio_shell._fill_nav(shell.nav, app)
        rec = studio_shell._reconcile_tabs(shell, app)
        shell = rec.shell
        shell.status.label = studio_shell.status_text(app)
        return { shell: shell, new_editors: rec.new_editors }
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
        save_btn = gtk.button("Save")
        refresh_btn = gtk.button("Refresh")
        header.append(new_btn)
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
        split.set_end_child(book)

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
                 new_btn: new_btn, save_btn: save_btn, refresh_btn: refresh_btn,
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
        bar.append(run_btn)
        bar.append(halt_btn)
        bar.append(force_btn)
        bar.append(state)
        ' `stop` is a gBASIC keyword and cannot be a record key, hence `halt`.
        return { box: bar, run: run_btn, halt: halt_btn, force: force_btn, state: state }
    end function

    ' One line of session state for the strip: what is happening, to which section,
    ' and -- when Studio refused or the child is gone -- why.
    function session_text(session)
        if session = nothing then
            return "run: (no session)"
        end if
        line = "run: " + session.state
        if session.section_id != "" then
            line = line + " [" + session.section_id + "]"
        end if
        if session.state = "refused" then
            return line + " — " + session.message
        end if
        if session.state = "failed" then
            return line + " — " + session.message
        end if
        if session.state = "finished" then
            if session.signal != 0 then
                return line + " — killed by signal " + session.signal
            end if
            return line + " — exit " + session.exit_code
        end if
        return line
    end function

    function output_pane()
        box = gtk.box("v", 4)
        prefix_head = gtk.label("Prefix output — sections replayed before the target")
        prefix_body = gtk.label("")
        target_head = gtk.label("Target output — the section you ran")
        target_body = gtk.label("")
        box.append(prefix_head)
        box.append(prefix_body)
        box.append(target_head)
        box.append(target_body)
        return { box: box, prefix: prefix_body, target: target_body }
    end function

    ' The two panes' text. Prefix output is ALWAYS shown, never folded away: it is
    ' the only way a user can see that the replay re-issued the prefix's side
    ' effects.
    '
    ' While a run is in flight the split is not yet decided, so BOTH panes show the
    ' raw stream under the prefix heading rather than guessing at a boundary that
    ' may not have been printed yet. Once the run ends the panes show whichever
    ' answer the marker actually supports (STU-4B), and when it supports none they
    ' say so instead of pretending a boundary exists.
    function output_prefix_text(session)
        if session = nothing then
            return "(none)"
        end if
        if session.split_out = "pending" then
            if session.out_raw = "" then
                return "(running — no output yet)"
            end if
            return session.out_raw
        end if
        if session.split_out = "combined" then
            if session.out_prefix = "" then
                return "(none — sections 1..N combined)"
            end if
            return session.out_prefix
        end if
        if session.out_prefix = "" then
            return "(none)"
        end if
        return session.out_prefix
    end function

    function output_target_text(session)
        if session = nothing then
            return "(none)"
        end if
        if session.split_out = "pending" then
            return "(running — not separated yet)"
        end if
        if session.split_out = "combined" then
            return "(not separable from the prefix in this run)"
        end if
        if session.out_target = "" then
            return "(none)"
        end if
        return session.out_target
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
