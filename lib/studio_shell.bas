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

    ' STU-8: the tabular tier and the general virtualized grid it opens into.
    load studio_table
    load studio_teaching
    load studio_git
    load datagrid


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
    ' The window's appearance, in one place. Every class this file writes goes on
    ' through `studio_style.apply`, which attaches the shared provider at the same
    ' time — a class added without it is a name nothing renders.
    load studio_style
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
        ' With no workspace, `nav_rows` yields exactly one row — "(no workspace
        ' open)" — and it sat in the top-left corner of a pane the height of the
        ' window, indistinguishable from a file. Asked of the MODEL rather than by
        ' matching the label, because the wording belongs to studio_ui and a shell
        ' comparing strings with it is a second copy of the same decision.
        empty = false
        if app.model.workspace = nothing then
            empty = true
        end if
        if empty then
            ' Shrink the list to its one row and centre that in the pane, and
            ' stop the list painting a view background while it does — a white
            ' strip the width of the pane with one sentence in it reads as a
            ' control someone could click.
            nav.valign = gi.enum("Gtk.Align.CENTER")
            nav.add_css_class(studio_style.css_class("flat"))
        else
            nav.valign = gi.enum("Gtk.Align.FILL")
            nav.remove_css_class(studio_style.css_class("flat"))
        end if
        i = 0
        for each r in rows
            if empty then
                nav.append(studio_shell._empty(gtk.label(r.label)))
                ' GtkListBox wraps what it is given in a GtkListBoxRow of its
                ' own, and the row is what paints the view background. Flatten
                ' the row too, or the label is centred inside a white bar that
                ' still looks like something to click.
                lbrow = nav.get_row_at_index(i)
                if lbrow != nothing then
                    lbrow = studio_style.apply(lbrow, "flat")
                end if
            else
                nav.append(studio_shell._left(gtk.label(r.label)))
            end if
            i = i + 1
        end for
        return rows
    end function

    ' A LEFT-ALIGNED label. `gtk.label` centres, which is right for a title and
    ' wrong for everything this shell shows: a browser row whose indentation
    ' encodes tree depth, a line of program output, an error, a table of
    ' variables. Centred, the indentation means nothing and output reads as
    ' poetry. Nothing in a golden can see this — the text is identical either
    ' way — which is why it survived five phases.
    function _left(lbl)
        lbl.xalign = 0
        lbl.halign = gi.enum("Gtk.Align.START")
        return lbl
    end function

    ' Left-aligned AND wrapping. Wrap rather than clip: a label narrower than its
    ' text is silently truncated at the edge, and a message a user cannot finish
    ' reading is not a message.
    '
    ' Only for things that occupy a whole row. Wrapping a label that shares a
    ' horizontal strip with others makes each one a narrow column of syllables —
    ' which is what the run strip turned into the first time this was applied to
    ' everything.
    function _wrapped(lbl)
        lbl = studio_shell._left(lbl)
        lbl.wrap = true
        lbl.wrap_mode = gi.enum("Pango.WrapMode.WORD_CHAR")
        ' `wrap` alone does not make a label wrap. A wrapping label still reports
        ' its NATURAL width as the whole text on one line, so a container that
        ' asks for natural size — a GtkScrolledWindow does — hands it that width
        ' and the text runs off the edge instead of folding.
        '
        ' `max_width_chars` caps the natural width and nothing else: given more
        ' room the label still uses it. This is the difference between the right
        ' pane reading "Branches — alternate continuations below this poi" with
        ' the rest gone, and reading as a paragraph.
        '
        ' Invisible to every golden. The text a test asserts is identical whether
        ' the widget wrapped it or clipped it, which is why five phases of panes
        ' were built this way before anyone looked at the window.
        lbl.max_width_chars = 44
        return lbl
    end function

    ' Left-aligned AND selectable AND monospaced: for captured output and
    ' anything else a user will want to copy out of.
    function _mono(lbl)
        lbl = studio_shell._wrapped(lbl)
        lbl.selectable = true
        ' "monospace" is the stock class every GTK theme defines; studio_style's
        ' own rule sets the size of the scale's monospace step.
        lbl.add_css_class("monospace")
        return studio_style.apply(lbl, "mono")
    end function

    ' ---- the visual scale ----------------------------------------------------
    '
    ' Four helpers, so no call site has to remember that a CSS class and its
    ' provider are two separate things (see studio_style's header). They compose
    ' with `_left`/`_wrapped` rather than replacing them: alignment is about what
    ' a label CONTAINS, and these are about what it WEIGHS.

    ' Explanatory prose: smaller and muted, so the controls beside it outrank it.
    ' Everything in the right-hand column that is a sentence rather than a value
    ' goes through here.
    function _dim(lbl)
        return studio_style.apply(studio_shell._wrapped(lbl), "dim")
    end function

    ' A panel heading — the short word that says which pane this is. Bold, small
    ' and letter-spaced; it does not wrap because it is never long enough to, and
    ' a heading that folds is a heading that has become a sentence.
    function _head(text)
        lbl = studio_shell._left(gtk.label(text))
        return studio_style.apply(lbl, "head")
    end function

    ' The rule that introduces a heading. The right-hand column stacked five panes
    ' with nothing between them, so it read as one list; this is the line that
    ' says where one pane ends and the next begins.
    function _rule()
        sep = gi.new("Gtk.Separator", "orientation", gi.enum("Gtk.Orientation.HORIZONTAL"))
        return studio_style.apply(sep, "rule")
    end function

    ' The same idea turned on its side: the divider between two groups of
    ' toolbar buttons.
    function _bar()
        sep = gi.new("Gtk.Separator", "orientation", gi.enum("Gtk.Orientation.VERTICAL"))
        sep.margin_start = studio_style.unit()
        sep.margin_end = studio_style.unit()
        return studio_style.attach(sep)
    end function

    ' What a pane says when it holds nothing: centred in the space it is failing
    ' to fill, and muted, because it is a state rather than a message.
    function _empty(lbl)
        lbl.halign = gi.enum("Gtk.Align.CENTER")
        lbl.valign = gi.enum("Gtk.Align.CENTER")
        lbl.hexpand = true
        lbl.vexpand = true
        return studio_style.apply(lbl, "empty")
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
        ' STU-11: git goes in the FULL redraw, never in refresh_run. Reading
        ' status spawns a process, and refresh_run is what the run poller calls
        ' sixteen times a second — forking `git status` at that rate would be a
        ' worse version of the mistake refresh_run exists to avoid.
        fg = studio_shell._fill_git(shell, app)
        shell = fg.shell
        app = fg.app
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
        ' The same sentence, in the colour of what it says. Classes only — the
        ' provider went on at build time, and this runs sixteen times a second.
        studio_style.set_state(shell.bar.state, studio_style.state_class(sess))
        shell.bar.section.label = studio_ui.section_label(app)
        shell.bar.standing.label = studio_ui.standing_line(app)
        shell.pane.prefix.label = studio_ui.prefix_body(app)
        shell.pane.target.label = studio_ui.target_body(app)
        shell.pane.errors.label = studio_ui.error_body(app)
        shell.rpane.body.label = studio_ui.results_body(app)
        shell.bar.branch.label = studio_ui.branch_label(app)
        fb = studio_shell._fill_branches(shell, app)
        shell = fb.shell
        app = fb.app
        ' STU-8: the table offers belong here rather than in `refresh`, because a
        ' run is exactly what changes them — a section that has just finished is
        ' the moment its variables become openable.
        ft = studio_shell._fill_tables(shell, app)
        shell = ft.shell
        app = ft.app
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
                ' An empty state, not a stray line of text: centred in the pane it
                ' is failing to fill, and muted, because it describes a situation
                ' rather than asking for anything. The TEXT is unchanged.
                book.append_page(studio_shell._empty(gtk.label("(no document open)")), gtk.label("Welcome"))
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
                set_cursor_result = ed.set_cursor(0, 0)
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
            ' By DOCUMENT ID, not by position. These two arrays are built
            ' differently — `want` follows the document manager's order, pages
            ' follow creation order with survivors compacted and new ones
            ' appended — and pairing them by index is only correct while those
            ' happen to agree. When they did not, a tab would carry one
            ' document's label over another document's buffer: the window would
            ' say you were editing one file while showing you another.
            t = studio_shell._want_for(want, pg.doc_id)
            if t != nothing then
                book.set_tab_label(pg.child, gtk.label(t.label))
            end if
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

    ' The wanted-tab row for a document id, or nothing.
    function _want_for(want, doc_id)
        for each t in want
            if t.doc_id = doc_id then
                return t
            end if
        end for
        return nothing
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
        ' The window's icon. `set_icon_name` resolves through the icon theme, and
        ' the icon theme's search path is where a display-wide call would be
        ' needed (`Gtk.IconTheme.get_for_display` is a class static the `gi`
        ' bridge cannot reach). So the path is supplied from OUTSIDE the process
        ' instead: `./studio` puts the repository's `share/` on XDG_DATA_DIRS,
        ' where `share/icons/hicolor/...` holds the gBASIC mascot under this name.
        ' Installed normally — the .desktop file in `share/applications` — the
        ' same name resolves with nothing set at all.
        win.set_icon_name("org.gbasic.Studio")

        outer = gtk.box("v", 0)

        ' --- header / menu strip ---
        ' The buttons are returned, not connected: `gi.connect` lives only in the
        ' entry program (see this file's header).
        '
        ' GROUPED, with a rule between groups: ten buttons in an undifferentiated
        ' row is a row nobody reads, they scan it for the word they want. The
        ' groups are project, file, name, then the two that destroy something.
        header = gtk.box("h", studio_style.unit())
        header = studio_style.apply(header, "toolbar")
        wordmark = studio_shell._left(gtk.label("gBASIC Studio"))
        wordmark = studio_style.apply(wordmark, "title")
        header.append(wordmark)
        header.append(studio_shell._bar())
        ' The name field expanded to fill the header and pushed every button to
        ' the right; it needs a width, not all of the width.
        name_entry_width = 18
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
        name_entry.max_width_chars = name_entry_width
        name_entry.hexpand = false
        ' Reads the name field as a PATH. A real folder chooser is a
        ' GtkFileDialog — async, with no signal a test can synthesise — so it
        ' would be the one control in this window nothing could press. The field
        ' is the same answer STU-2D gave for names, and a "Browse..." button that
        ' merely FILLS the field can be added later without changing any of this.
        open_btn = gtk.button("Open Folder")
        rename_btn = gtk.button("Rename")
        delete_btn = gtk.button("Delete")
        close_btn = gtk.button("Close")
        save_btn = gtk.button("Save")
        refresh_btn = gtk.button("Refresh")
        ' Delete takes the stock destructive class. It is the only control in this
        ' window that removes a file from disk, and it sat in a row of identical
        ' grey buttons one pixel from Close. The class is the THEME's — red in
        ' light, red in dark, whatever the user's accent is — not a colour of ours.
        delete_btn.add_css_class(studio_style.css_class("destructive-action"))

        ' Group 1: the project. What you press when there is nothing open yet.
        header.append(new_btn)
        header.append(open_btn)
        header.append(studio_shell._bar())
        ' Group 2: the file. Make one, put it somewhere, write it, re-read it.
        header.append(file_btn)
        header.append(folder_btn)
        header.append(save_btn)
        header.append(refresh_btn)
        header.append(studio_shell._bar())
        ' Group 3: the name field and the one button that consumes it on its own.
        ' New File, New Folder and New Project read it too, which is why it sits
        ' between them and Rename rather than inside either group.
        header.append(name_entry)
        header.append(rename_btn)
        header.append(studio_shell._bar())
        ' Group 4: the two that take something away, at the far end where a
        ' mis-aimed click does not land on them.
        header.append(delete_btn)
        header.append(close_btn)
        outer.append(header)

        ' --- main split: project browser | editor tab notebook ---
        '
        ' MARGINS. There was not one `set_margin_*` call anywhere in this
        ' repository, which is why every pane was welded to the window frame. The
        ' unit is studio_style.unit() — 6px — and the split takes one of them all
        ' round, so the editor, the browser and the right column each sit on a
        ' visible gutter instead of on the glass.
        u = studio_style.unit()
        split = gtk.paned("h")
        split.vexpand = true
        split.margin_start = u
        split.margin_end = u
        split.margin_top = u
        split.margin_bottom = u

        nav = gtk.listbox()
        ' The browser's rows carry their own indentation, so the pane only needs
        ' to be held off its own frame.
        nav.margin_start = u
        nav.margin_end = u
        nav.margin_top = u
        ' The stylesheet has to be reachable from the list itself: `_fill_nav`
        ' toggles the flat class on it when the workspace is empty, and a class
        ' whose provider is not attached is a name nothing renders.
        nav = studio_style.attach(nav)
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
        apane = studio_shell.agent_pane()

        ' The design puts the console at the BOTTOM and inspection at the RIGHT
        ' (§6.2/§6.3), and looking at the window showed why: four panes stacked in
        ' one scroller meant the variables of a run sat below the fold with the
        ' editor still half empty. Output goes under the editor; results and the
        ' assistant go beside them.
        under = gtk.box("v", u)
        ' `.studio-panel` deliberately has no top padding (see studio_style), so
        ' the console gets its gap from the divider above it here.
        under.margin_top = u
        under.append(bar.box)
        under.append(pane.box)

        bpane = studio_shell.branch_pane()
        tpane = studio_shell.table_pane()
        gpane = studio_shell.git_pane()
        beside = gtk.box("v", u)
        beside.append(bpane.box)
        beside.append(rpane.box)
        beside.append(tpane.box)
        beside.append(gpane.box)
        beside.append(apane.box)

        ' FLOORS, so that "its minimum" is a size somebody can use.
        '
        ' A GtkScrolledWindow's minimum is near zero — that is what a scroller is
        ' for — so refusing to shrink below the minimum is only half an answer: a
        ' divider would still stop with the source view 38px tall, which is the
        ' measured collapse this pair of fixes exists to stop. These are the sizes
        ' below which a pane has stopped being a pane. Multiples of the spacing
        ' unit, like everything else here.
        under_scroll = studio_shell._vscroll(under)
        under_scroll.set_size_request(-1, u * 15)
        beside_scroll = studio_shell._vscroll(beside)
        beside_scroll.set_size_request(u * 44, -1)
        nav_scroll.set_size_request(u * 26, -1)
        book.set_size_request(u * 48, u * 30)

        vsplit = gtk.paned("v")
        vsplit.set_start_child(book)
        vsplit.set_end_child(under_scroll)
        vsplit.position = 380

        rsplit = gtk.paned("h")
        rsplit.set_start_child(vsplit)
        rsplit.set_end_child(beside_scroll)
        rsplit.position = 620
        split.set_end_child(rsplit)

        ' NO PANE MAY BE ALLOCATED LESS THAN IT NEEDS.
        '
        ' GTK 4's `shrink-start-child` / `shrink-end-child` default to TRUE, which
        ' lets a GtkPaned hand a child LESS than its minimum — down to nothing.
        ' Combined with `_vscroll`'s horizontal policy of NEVER, which does not
        ' scroll but does hold the child at its own minimum width, an underfed
        ' pane does not reflow its contents: it CLIPS them, and it clips them from
        ' the LEFT. Measured: `vsplit` driven to 0 left the source view 38px tall
        ' with the code gone, and `rsplit` at 330 left the console reading
        ' ": finished [sec-6] — exit 1" and "able: undefned_name" — the run strip
        ' and the error message with their left-hand halves cut off. Neither is
        ' recoverable from the keyboard: there is no scrollbar to drag, and Home
        ' moves a caret the view will not follow sideways.
        '
        ' With shrink off, a divider STOPS at the minimum instead of swallowing
        ' the pane behind it, and the window refuses to size below the sum. A pane
        ' you cannot quite close is a much smaller problem than a pane that
        ' disappears with your file inside it.
        split.set_shrink_start_child(false)
        split.set_shrink_end_child(false)
        vsplit.set_shrink_start_child(false)
        vsplit.set_shrink_end_child(false)
        rsplit.set_shrink_start_child(false)
        rsplit.set_shrink_end_child(false)

        outer.append(split)

        ' --- status bar ---
        ' Given a rule and a tint of its own, it stops reading as a line of text
        ' that fell off the bottom of the window.
        status = studio_shell._left(gtk.label(studio_shell.status_text(app)))
        ' `_left` sets halign START, which gives a label its NATURAL width — and a
        ' status bar that is only as wide as its current sentence is a floating
        ' grey tab, not a bar. xalign keeps the text left; halign FILL makes the
        ' bar the width of the window.
        status.halign = gi.enum("Gtk.Align.FILL")
        status.hexpand = true
        status = studio_style.apply(status, "statusbar")
        outer.append(status)

        win.set_child(outer)

        ' The window is built EMPTY and then filled by the ONE redraw path, so the
        ' first paint and every later one are produced by the same code. A separate
        ' initial-population path is how a view starts disagreeing with its
        ' refresh.
        '
        ' It is deliberately NOT presented here. Presenting an empty window makes
        ' GTK allocate scrolled windows that have no child yet. The caller
        ' presents after the first refresh — see `present` below.
        '
        ' The "GtkGizmo (slider) reported min width/height -2" pair that survives
        ' that is NOT ours and is not fixable here: a bare GtkWindow holding one
        ' GtkScrolledWindow around one GtkLabel prints exactly the same pair on
        ' this GTK 4, with no paned, no policy and no margin involved. Studio has
        ' four scrolled windows, which is why there are eight lines. Taking the
        ' paneds off `shrink` changed nothing, so it is not a starved allocation.
        shell = { window: win, status: status, nav: nav, notebook: book,
                 new_btn: new_btn, file_btn: file_btn, folder_btn: folder_btn,
                 name_entry: name_entry, open_btn: open_btn, rename_btn: rename_btn,
                 delete_btn: delete_btn, close_btn: close_btn,
                 save_btn: save_btn, refresh_btn: refresh_btn,
                 bar: bar, pane: pane, rpane: rpane, apane: apane, bpane: bpane,
                 tpane: tpane, gpane: gpane,
                 ' STU-5 decoration state: which outline revision each document's
                 ' gutter marks were drawn for, and the one live highlight tag.
                 marked: {}, hl_tag: nothing, hl_doc: "",
                 ' STU-10 teaching state: what currently carries a class.
                 pulsing: nothing, pulse_class: "", highlighted: nothing, highlight_class: "",
                 teach_tag: nothing,
                 rows: [], pages: [], welcome: false }
        ' STU-10: the teaching stylesheet, installed once on each widget an agent
        ' may point at. After the record exists, because it is what names them.
        shell.teach_css = studio_shell.install_teaching_css(shell)
        return shell
    end function

    ' A scroller that scrolls VERTICALLY ONLY.
    '
    ' This is not a preference. A GtkScrolledWindow with automatic horizontal
    ' policy gives its child the child's NATURAL width, and a wrapping label's
    ' natural width is its whole text on one line — so a label that was told to
    ' wrap never does, the column overflows, and every heading in the right-hand
    ' pane gets cut off mid-word at the window edge. Looking at the window is the
    ' only way anyone finds this: the text is identical either way to a golden,
    ' and every one of them passed.
    '
    ' NEVER on the horizontal policy makes the viewport impose its own width,
    ' which is what gives a wrapping label something to wrap to.
    function _vscroll(child)
        s = gtk.scrolled(child)
        never = gi.enum("Gtk.PolicyType.NEVER")
        auto = gi.enum("Gtk.PolicyType.AUTOMATIC")
        s.set_policy(never, auto)
        return s
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
        bar = gtk.box("h", studio_style.unit())
        run_btn = gtk.button("Run Section")
        ' The stock suggested class. Of the three buttons on this strip one is
        ' what you came here to press and two are what you press when it goes
        ' wrong, and they were indistinguishable.
        run_btn.add_css_class(studio_style.css_class("suggested-action"))
        halt_btn = gtk.button("Stop")
        force_btn = gtk.button("Force Stop")
        ' The state carried in the TEXT only — "run: running" and "run: failed" in
        ' the same grey. The text is unchanged (the goldens assert it); the class
        ' moves with the state, and `refresh_run` is what moves it.
        state = studio_shell._left(gtk.label("run: idle"))
        state = studio_style.apply(state, "state-idle")
        ' Ellipsized for the same reason `standing` is, and now for a second one:
        ' a label that neither wraps nor ellipsizes reports its WHOLE SENTENCE as
        ' its minimum width, so "run: finished [sec-6] — exit 1" appearing after a
        ' run raised the console's minimum width by about 200px. That is what let
        ' a narrow window starve the strip until it was clipped from the left.
        ' The label text is untouched; only how it fails is.
        state.ellipsize = gi.enum("Pango.EllipsizeMode.END")
        ' STU-5A′: which section Run would run, shown BEFORE you press it rather
        ' than after. It follows the caret.
        section = studio_shell._left(gtk.label("section: (none)"))
        section = studio_style.apply(section, "dim")
        section.ellipsize = gi.enum("Pango.EllipsizeMode.END")
        ' STU-5 §10.3: whether what you are looking at is live in this session or
        ' a record from an earlier one.
        standing = studio_shell._left(gtk.label(""))
        standing = studio_style.apply(standing, "dim")
        ' The strip is one horizontal row, so this cannot wrap; ellipsize instead,
        ' which at least SAYS it was cut rather than stopping mid-word.
        standing.ellipsize = gi.enum("Pango.EllipsizeMode.END")
        branch = studio_shell._left(gtk.label("branch: baseline"))
        branch.ellipsize = gi.enum("Pango.EllipsizeMode.END")
        bar = studio_style.apply(bar, "panel")
        bar.append(run_btn)
        bar.append(halt_btn)
        bar.append(force_btn)
        bar.append(state)
        bar.append(section)
        bar.append(standing)
        ' The branch is NOT appended: the selector pane names it a few inches
        ' away, and a fifth label turned the strip into two ellipsized stubs.
        ' The widget stays so a caller can read the text without the pane.
        ' `stop` is a gBASIC keyword and cannot be a record key, hence `halt`.
        return { box: bar, run: run_btn, halt: halt_btn, force: force_btn,
                 state: state, section: section, standing: standing, branch: branch }
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
        box = gtk.box("v", studio_style.unit())
        box = studio_style.apply(box, "panel")
        ' Three sections of output with nothing to tell them apart but a sentence
        ' each, in body weight, directly above the monospace they described. The
        ' TEXT is untouched — a golden asserts every word of it — and the headings
        ' now carry the heading class and a rule, so the eye finds the boundary
        ' before it reads the sentence.
        prefix_head = studio_style.apply(studio_shell._wrapped(gtk.label("Prefix output — sections replayed before the target")), "head")
        prefix_body = studio_shell._mono(gtk.label(""))
        target_head = studio_style.apply(studio_shell._wrapped(gtk.label("Target output — the section you ran")), "head")
        target_body = studio_shell._mono(gtk.label(""))
        ' STU-5: a section's errors had nowhere to go. The child's stderr was
        ' captured, attributed and stored, and the window showed none of it.
        error_head = studio_style.apply(studio_shell._wrapped(gtk.label("Errors")), "head")
        error_body = studio_shell._mono(gtk.label(""))
        box.append(prefix_head)
        box.append(prefix_body)
        box.append(studio_shell._rule())
        box.append(target_head)
        box.append(target_body)
        box.append(studio_shell._rule())
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
        box = gtk.box("v", studio_style.unit())
        box = studio_style.apply(box, "panel")
        ' The BODY already opens with "Results — sec-N", so a header saying
        ' "Results" too put the word on two consecutive lines. The header says
        ' what the pane is keyed to; the body says which section that is. That is
        ' why THIS line is the pane's heading rather than a sentence under one
        ' saying "Results": that title would be the word the body is about to say.
        head = studio_style.apply(studio_shell._wrapped(gtk.label("For the section at the cursor")), "head")
        body = studio_shell._mono(gtk.label(""))
        box.append(studio_shell._rule())
        box.append(head)
        box.append(body)
        return { box: box, head: head, body: body }
    end function

    ' ---- STU-7: the inline branch selector (§9.1) ---------------------------
    '
    ' Mutually-exclusive rows at the branch point. A GtkListBox rather than a row
    ' of buttons for the same reason the file browser is one: the rows are DATA
    ' that changes, and a listbox has an index a click reports, so the dispatcher
    ' can resolve it against the array that produced the widgets.
    function branch_pane()
        box = gtk.box("v", studio_style.unit())
        box = studio_style.apply(box, "panel")
        ' A heading of its own, and the sentence that explains it DEMOTED beneath.
        ' The right-hand column was five explanatory paragraphs stacked with no
        ' rule between them: it read as one list, and the controls were the least
        ' prominent thing in it. The heading is a new label; the sentence keeps
        ' every word it had.
        head = studio_shell._dim(gtk.label("Branches — alternate continuations below this point"))
        list = gtk.listbox()
        bind_btn = gtk.button("Bind name = value")
        bind_btn.halign = gi.enum("Gtk.Align.START")
        box.append(studio_shell._rule())
        box.append(studio_shell._head("Branches"))
        box.append(head)
        box.append(list)
        box.append(bind_btn)
        ' STU-9: the overlay strip. A row of buttons rather than a listbox,
        ' because unlike the branches these are FIXED acts, not data — the set
        ' never changes, only whether each one is currently allowed, and every
        ' refusal comes back as a status line saying why.
        ' TWO rows of three. Six buttons in one horizontal row is 640px of
        ' controls in a 320px column: the last two simply were not on screen, and
        ' a button nobody can see is a feature nobody has. Shorter labels too —
        ' "Overlay this section" was the widest thing in the pane.
        edit_btn = gtk.button("Overlay")
        ' NOT "Save". The toolbar already has a Save, and that one writes the
        ' FILE -- two buttons with one word doing different things to the same
        ' document is a worse defect than the crowding that tempted me to shorten
        ' it. It fits in the two-row layout, so there was never a trade to make.
        save_btn = gtk.button("Save overlay")
        cmp_btn = gtk.button("Compare")
        reb_btn = gtk.button("Rebase")
        prom_btn = gtk.button("Promote")
        disc_btn = gtk.button("Discard")
        orow1 = gtk.box("h", 4)
        orow1.append(edit_btn)
        orow1.append(save_btn)
        orow1.append(cmp_btn)
        orow2 = gtk.box("h", 4)
        orow2.append(reb_btn)
        orow2.append(prom_btn)
        orow2.append(disc_btn)
        box.append(orow1)
        box.append(orow2)
        ' The overlay BUFFER. A real editor, not a label: an overlay is code the
        ' user types, and it cannot go in the source editor because that buffer
        ' shows the canonical document — a window that displayed non-canonical text
        ' as the file would be the one thing §2.1 forbids. So the experiment gets
        ' its own editor, visibly separate from the file, which is also what
        ' "visibly marked experimental" means in practice.
        ed = sourceeditor.create()
        ed.set_language("gbasic")
        ed_scroll = gtk.scrolled(ed.view())
        ed_scroll.set_size_request(-1, 140)
        ' Hidden until there is an overlay to edit. It was permanently on screen
        ' as an empty box with a lone line-number "1" in it, taking a fifth of the
        ' right-hand column from every user who has never made an overlay.
        ed_scroll.set_visible(false)
        box.append(ed_scroll)
        ' Where compare prints and a conflict is spelled out. Monospaced because
        ' it holds source lines.
        diff = studio_shell._mono(gtk.label(""))
        box.append(diff)
        return { box: box, list: list, bind: bind_btn, rows: [],
                 edit: edit_btn, save: save_btn, cmp: cmp_btn,
                 rebase: reb_btn, promote: prom_btn, discard: disc_btn,
                 editor: ed, editor_scroll: ed_scroll, diff: diff }
    end function

    ' Rebuild the selector from the shared row model, exactly as the nav pane is
    ' rebuilt from its own — and the rows are stored so a later click resolves
    ' against what was actually drawn.
    function _fill_branches(shell, app)
        br = studio_ui.branch_rows(app)
        app = br.app
        studio_shell._clear_listbox(shell.bpane.list)
        for each r in br.rows
            mark = "   "
            if r.selected then
                mark = " * "
            end if
            text = mark + r.label + studio_ui.overlay_mark(r)
            if r.stale then
                text = text + "   [ancestry changed]"
            end if
            shell.bpane.list.append(studio_shell._left(gtk.label(text)))
        end for
        shell.bpane.rows = br.rows
        ' STU-9: conflicts are SURFACED on every redraw, never acted on (§9.3).
        ' A conflict that only appeared when you pressed Promote would be a
        ' conflict you found by trying to lose work.
        c = studio_ui.overlay_conflicts(app)
        app = c.app
        if count(c.problems) > 0 then
            lines = []
            for each p in c.problems
                lines = append(lines, p.name + " / " + p.section_id + ": " + p.detail)
            end for
            shell.bpane.diff.label = join(lines, "\n")
        end if
        return { shell: shell, app: app }
    end function

    ' ---- STU-11: the git pane, which is usually not there -------------------
    '
    ' §18 asks for git to be VISUALLY QUIET when not needed, and the honest
    ' reading of that is not "a collapsed expander" — it is that someone who does
    ' not use git should never see the word. So the pane is built once and its
    ' VISIBILITY is driven by whether the active project is a repository.
    '
    ' Built once rather than created and destroyed: a widget that comes and goes
    ' would reflow the whole right-hand column every time the project changed,
    ' and `set_visible` is what GTK provides for exactly this.
    function git_pane()
        box = gtk.box("v", studio_style.unit())
        box = studio_style.apply(box, "panel")
        head = studio_shell._head("Git")
        body = studio_shell._mono(gtk.label(""))
        box.append(studio_shell._rule())
        box.append(head)
        box.append(body)
        box.set_visible(false)
        return { box: box, head: head, body: body }
    end function

    function _fill_git(shell, app)
        e = studio_ui.git_engaged(app)
        app = e.app
        shell.gpane.box.set_visible(e.engaged)
        if not e.engaged then
            return { shell: shell, app: app }
        end if
        g = studio_ui.git_lines(app)
        app = g.app
        shell.gpane.body.label = join(g.lines, "\n")
        return { shell: shell, app: app }
    end function

    ' ---- STU-10: teaching, rendered ----------------------------------------
    '
    ' §13 requires this to be GENERALIZED — a facility over named widgets, not a
    ' special path. So it is: a lookup from the cue's widget name to a widget the
    ' shell already built, then one of four generic GTK operations. Nothing here
    ' exists only for teaching, and nothing native is involved.
    '
    '   highlight  a CSS class on the widget
    '   pulse      the same class, removed again by a gi.timeout
    '   focus      grab_focus
    '   reveal     grab_focus on a pane, which scrolls its scroller to it
    '   annotate   a temporary GtkTextTag over a line range of the editor
    '
    ' The cue was already validated by studio_teaching — a widget that cannot
    ' perform a gesture was refused before it got here — so this renders rather
    ' than decides. What it still checks is that the NAME resolves to a live
    ' widget: the registry is a list a human maintains, and a pane that got
    ' renamed in the shell without being renamed there would otherwise fail
    ' silently, which is the failure mode teaching can least afford.
    function teach_widget(shell, name)
        if name = "browser" then
            return shell.nav
        end if
        if name = "tabs" then
            return shell.notebook
        end if
        if name = "run_strip" then
            return shell.bar.box
        end if
        if name = "output" then
            return shell.pane.box
        end if
        if name = "results" then
            return shell.rpane.box
        end if
        if name = "branches" then
            return shell.bpane.box
        end if
        if name = "tables" then
            return shell.tpane.box
        end if
        if name = "assistant" then
            return shell.apane.box
        end if
        if name = "name_field" then
            return shell.name_entry
        end if
        if name = "run_button" then
            return shell.bar.run
        end if
        if name = "save_button" then
            return shell.save_btn
        end if
        if name = "new_file_button" then
            return shell.file_btn
        end if
        if name = "new_folder_button" then
            return shell.folder_btn
        end if
        if name = "overlay_strip" then
            return shell.bpane.edit
        end if
        return nothing
    end function

    ' Which widget names this shell can actually resolve. Compared against
    ' studio_teaching.registry() by a test, so a widget the agent is told it may
    ' point at and a widget the window can find are kept the same set.
    function teachable()
        return ["browser", "tabs", "editor", "gutter", "run_strip", "output",
                "results", "branches", "tables", "assistant", "name_field",
                "run_button", "save_button", "new_file_button",
                "new_folder_button", "overlay_strip"]
    end function

    ' Install the teaching stylesheet, once, at build time.
    '
    ' PER WIDGET, not display-wide. The usual way to do this is
    ' `Gtk.StyleContext.add_provider_for_display`, and the `gi` bridge cannot
    ' reach it — it is a static class function, and gi.invoke does not resolve
    ' those. A widget's own style context takes a provider, so the stylesheet goes
    ' on each teachable widget instead. That is better scoping than the
    ' conventional answer would have given: no display-wide state, nothing to
    ' leak into another window, and the styles exist exactly where they are used.
    '
    ' Once, at build time, and not per gesture: a provider added on each teaching
    ' request would stack one per request for the life of the process.
    function install_teaching_css(shell)
        prov = gi.new("Gtk.CssProvider")
        prov.load_from_string(studio_teaching.css())
        for each name in studio_shell.teachable()
            w = studio_shell.teach_widget(shell, name)
            if w != nothing then
                ' Bound rather than chained: gBASIC does not accept a method call
                ' on the result of a method call as a statement.
                ctx = w.get_style_context()
                ctx.add_provider(prov, 600)
            end if
        end for
        return prov
    end function

    ' Render a cue. Four generic operations, none of which exists only for
    ' teaching.
    '
    ' A pulse removes its own class through a gi.timeout, which is the same
    ' mechanism the run poller uses. The timeout callback cannot close over the
    ' widget — gBASIC functions do not close over state — so the shell keeps the
    ' pulsing widget on itself and the program's one-line callback clears it.
    function apply_cue(shell, app)
        c = app["teach"]
        if c = unknown then
            return { shell: shell, app: app, drawn: false }
        end if
        if c = nothing then
            return { shell: shell, app: app, drawn: false }
        end if
        if not c.ok then
            return { shell: shell, app: app, drawn: false }
        end if
        ' The cue is consumed. A cue left on the app would be re-applied by every
        ' later redraw, so the window would keep pointing at something the agent
        ' said once, forever.
        app["teach"] = nothing
        if c.widget = "editor" or c.widget = "gutter" then
            if c.gesture = "annotate" then
                return { shell: studio_shell._annotate(shell, app, c), app: app, drawn: true }
            end if
        end if
        w = studio_shell.teach_widget(shell, c.widget)
        if w = nothing then
            return { shell: shell, app: app, drawn: false }
        end if
        if c.gesture = "focus" then
            w.grab_focus()
            return { shell: shell, app: app, drawn: true }
        end if
        if c.gesture = "reveal" then
            ' A pane has no scroll-to of its own; focusing it makes its scroller
            ' bring it into view, which is what "reveal" means here.
            w.grab_focus()
            return { shell: shell, app: app, drawn: true }
        end if
        cls = studio_teaching.css_class(c.gesture)
        if cls = "" then
            return { shell: shell, app: app, drawn: false }
        end if
        clear_pulse_result = studio_shell.clear_pulse(shell)
        w.add_css_class(cls)
        if c.gesture = "pulse" then
            shell.pulsing = w
            shell.pulse_class = cls
        else
            shell.highlighted = w
            shell.highlight_class = cls
        end if
        return { shell: shell, app: app, drawn: true }
    end function

    ' End a pulse. Called by the program's timeout callback, and again before any
    ' new gesture — two pulses at once would leave the first one's class on a
    ' widget with nothing left to remove it.
    function clear_pulse(shell)
        if shell.pulsing != nothing then
            shell.pulsing.remove_css_class(shell.pulse_class)
            shell.pulsing = nothing
            shell.pulse_class = ""
        end if
        return shell
    end function

    function clear_highlight(shell)
        if shell.highlighted != nothing then
            shell.highlighted.remove_css_class(shell.highlight_class)
            shell.highlighted = nothing
            shell.highlight_class = ""
        end if
        return shell
    end function

    ' A temporary tag over a line range of the active editor. The same GtkTextTag
    ' facility STU-5's section tint uses, over a different range and with a
    ' different name.
    function _annotate(shell, app, c)
        ed = studio_shell.editor_for(shell, app.dm.active)
        if ed = nothing then
            return shell
        end if
        r = studio_teaching.range_of(c.detail)
        if not r.ok then
            return shell
        end if
        ' The editor's own highlight facility, the one STU-5's section tint uses,
        ' over a different range and in a different colour. A previous annotation
        ' is removed first: two live tags over overlapping ranges leave a colour
        ' nobody chose.
        if shell.teach_tag != nothing then
            ed.unhighlight(shell.teach_tag)
            shell.teach_tag = nothing
        end if
        shell.teach_tag = ed.highlight(r.first, r.last, studio_teaching.annotate_colour())
        return shell
    end function

    ' ---- STU-8: the table offers, and the grid window ----------------------
    '
    ' Design §7 has Studio OFFER a view rather than assume one, so this is a list
    ' of offers and not a grid: only variables that are recognizably tabular get a
    ' row at all, and a section whose variables are all scalars shows none.
    '
    ' A listbox for the same reason the file browser and the branch selector are
    ' listboxes: the rows are DATA that changes with every run, and a listbox has
    ' an index a click reports, so the dispatcher resolves it against the array
    ' that produced the widgets rather than deriving them a second time.
    function table_pane()
        box = gtk.box("v", studio_style.unit())
        box = studio_style.apply(box, "panel")
        head = studio_shell._dim(gtk.label("Tables — results the section left behind that can be opened as a table"))
        list = gtk.listbox()
        fetch_btn = gtk.button("Fetch all rows (runs the section again)")
        fetch_btn.halign = gi.enum("Gtk.Align.START")
        box.append(studio_shell._rule())
        box.append(studio_shell._head("Tables"))
        box.append(head)
        box.append(list)
        box.append(fetch_btn)
        return { box: box, list: list, fetch: fetch_btn, rows: [] }
    end function

    function _fill_tables(shell, app)
        t = studio_ui.table_rows(app)
        app = t.app
        studio_shell._clear_listbox(shell.tpane.list)
        for each r in t.rows
            shell.tpane.list.append(studio_shell._left(gtk.label("   " + r.label)))
        end for
        if count(t.rows) = 0 then
            shell.tpane.list.append(studio_shell._left(gtk.label("   (nothing tabular in the latest run)")))
        end if
        shell.tpane.rows = t.rows
        return { shell: shell, app: app }
    end function

    ' The grid window. TWO TIERS, and the fork is the design's (§7), not a
    ' convenience: a modest table is a grid of labels and needs no native
    ' component at all, while a large one goes through the DataGrid — the single
    ' justified native piece, and a general gBASIC component rather than a Studio
    ' grid.
    '
    ' The caption is not decoration. It is where a sampled source admits to being
    ' one, and it is drawn from the same `studio_table.caption` the headless
    ' goldens assert, so the window cannot quietly say something kinder than the
    ' model does.
    '
    ' A virtual grid's cell callback cannot close over this source — gBASIC
    ' functions do not close over state — so the caller supplies `count_fn` and
    ' `cell_fn`, which are the two-line adapters in app/studio.bas that read the
    ' program global. Same rule as a signal handler, for the same reason.
    function table_window(gtkapp, caption, src, count_fn, cell_fn)
        win = gtk.application_window(gtkapp)
        win.title = "gBASIC Studio — table"
        win.default_width = 900
        win.default_height = 600
        outer = gtk.box("v", 6)
        outer.append(studio_shell._wrapped(gtk.label(caption)))
        if src.kind = "none" then
            outer.append(studio_shell._left(gtk.label("(nothing to show)")))
            win.set_child(outer)
            return { window: win, grid: nothing, kind: "empty" }
        end if
        kind = "labels"
        grid = nothing
        if src.known > studio_table.modest_rows() then
            kind = "datagrid"
            grid = datagrid.create_virtual(count_fn, cell_fn)
            ordinal = 0
            for each c in src.cols
                grid = datagrid.add_column(grid, { title: c, index: ordinal })
                ordinal = ordinal + 1
            end for
            outer.append(gtk.scrolled(datagrid.widget(grid)))
        else
            outer.append(gtk.scrolled(studio_shell._label_grid(src)))
        end if
        win.set_child(outer)
        return { window: win, grid: grid, kind: kind }
    end function

    ' The modest tier: one label per cell. Bounded by construction — nothing
    ' reaches this branch with more rows than `modest_rows()`, which is what keeps
    ' "a widget per cell" from being the wrong answer.
    function _label_grid(src)
        g = gi.new("Gtk.Grid")
        g.set_column_spacing(12)
        g.set_row_spacing(2)
        ordinal = 0
        for each c in src.cols
            g.attach(studio_shell._left(gtk.label(c)), ordinal, 0, 1, 1)
            ordinal = ordinal + 1
        end for
        i = 0
        while i < src.known
            r = studio_table.row_at(src, i)
            src = r.src
            ordinal = 0
            for each c in src.cols
                text = ""
                if ordinal < count(r.row) then
                    text = string(r.row[ordinal])
                end if
                g.attach(studio_shell._mono(gtk.label(text)), ordinal, i + 1, 1, 1)
                ordinal = ordinal + 1
            end for
            i = i + 1
        end while
        return g
    end function

    ' ---- STU-6: the agent pane ---------------------------------------------
    '
    ' Read-only, and it says so. The button asks "where was I?"; the answer lands
    ' in the label. There is no input field yet because there is nothing useful to
    ' type at an assistant that can only look — orientation is one question.
    function agent_pane()
        box = gtk.box("v", studio_style.unit())
        box = studio_style.apply(box, "panel")
        head = studio_shell._dim(gtk.label("Assistant — read-only; it can see your project, not change it"))
        ask_btn = gtk.button("Where was I?")
        ask_btn.halign = gi.enum("Gtk.Align.START")
        ' The body is prose too, until it is holding an answer — and "(not
        ' configured …)" is the state most windows show it in.
        body = studio_shell._dim(gtk.label("(not configured — set ANTHROPIC_API_KEY and restart)"))
        box.append(studio_shell._rule())
        box.append(studio_shell._head("Assistant"))
        box.append(head)
        box.append(ask_btn)
        box.append(body)
        return { box: box, ask: ask_btn, body: body }
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
