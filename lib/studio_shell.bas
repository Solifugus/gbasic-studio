' SPDX-License-Identifier: Apache-2.0
' Copyright 2026 Matthew C. Tedder. See LICENSE.

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
    load studio_templates
    load studio_schema
    load studio_model
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
                nav.append(studio_shell._nav_row(r))
            end if
            i = i + 1
        end for
        return rows
    end function

    ' One browser row.
    '
    ' Indentation is a MARGIN, not spaces inside the text. It used to be two
    ' spaces per level baked into `nav_rows`' label, which put depth into a
    ' presentation string and then rendered it in a PROPORTIONAL font, where two
    ' spaces are whatever the font happens to say. `studio_ui` hands over the
    ' parts now and this is the only place that decides how deep a level looks.
    '
    ' MIDDLE ellipsis, not END. Measured: a five-level tree in a 260px pane cut
    ' `interpolated_string_expression_parser_regression_tests.bas` off mid-word
    ' with no ellipsis and no horizontal scrollbar — nothing said the name was
    ' truncated and nothing could reach the rest of it. END ellipsis would have
    ' signalled the truncation and still eaten `.bas`, which is the part that
    ' says what the file IS. MIDDLE keeps both ends.
    '
    ' `_fill` and not `_left` on the NAME: `halign = START` hands a label its
    ' NATURAL width, and a label allowed its natural width never ellipsizes —
    ' it just runs off the edge, which is the bug. The label has to be GIVEN a
    ' width for Pango to have anything to elide against.
    function _nav_row(r)
        u = studio_style.unit()
        ' The gap between the glyph and the name is box SPACING, not a space
        ' inside either label -- so it is one number here instead of a
        ' proportional font's opinion.
        box = gtk.box("h", 4)
        box.margin_start = r.depth * studio_shell._indent()
        ' The glyph gets a column of its OWN, one character wide. Inside the
        ' name's label it was a character of a PROPORTIONAL font, so a
        ' directory's name and a file's name beside it started at different
        ' places -- `width_chars` and `max_width_chars` together pin the column
        ' at whatever one character is in the font actually in use.
        g = studio_shell._left(gtk.label(r.glyph))
        g.width_chars = 1
        g.max_width_chars = 1
        box.append(g)
        lbl = studio_shell._fill(gtk.label(r.name))
        lbl.ellipsize = gi.enum("Pango.EllipsizeMode.MIDDLE")
        ' A note INSIDE the tree -- "(empty)", "(hidden files only)" -- is a
        ' remark about the directory above it, not an entry you can act on, and
        ' it has to read that way or it is one more thing to try clicking. The
        ' workspace header is an info row too and keeps its weight, which is
        ' why this is on depth and not on kind alone.
        if r.kind = "info" then
            if r.depth > 0 then
                lbl = studio_style.apply(lbl, "dim")
            end if
        end if
        box.append(lbl)
        ' The whole path, on hover, for the row whose name had to be elided --
        ' and for every other row too, because "which of the four src/ folders
        ' is this" is the same question one level up.
        if r.path != "" then
            box.set_tooltip_text(r.path)
        end if
        return box
    end function

    ' How deep one level of the tree looks. Two spaces' worth in the old
    ' rendering, near enough, and now an exact number rather than a font's
    ' opinion of a space.
    function _indent()
        return studio_style.indent()
    end function

    ' ---- the browser's context menu (STU-13) --------------------------------
    '
    ' A `Gtk.Popover` holding a box of ordinary `Gtk.Button`s, NOT a
    ' `Gtk.PopoverMenu`. A PopoverMenu is driven by a `GMenuModel`, which is
    ' built through class statics the gi bridge cannot reach -- the same gap as
    ' `Gtk.Settings.get_default`. Plain buttons are also what makes the menu
    ' TESTABLE: a display tier can `activate()` one, which no menu-model item
    ' would let it do.
    '
    ' Built ONCE, holding every item there is, and the items a row does not
    ' offer are hidden. Rebuilding it per right-click would re-run `gi.connect`
    ' on a fresh set of buttons every time.
    function context_menu()
        pop = gi.new("Gtk.Popover")
        pop.set_has_arrow(true)
        box = gtk.box("v", 0)
        box = studio_style.apply(box, "panel")
        items = {}
        for each a in studio_ui.context_all()
            b = gtk.button(studio_ui.context_label(a))
            ' Frameless and LEFT-aligned, or a column of them reads as a stack
            ' of buttons rather than as a menu — looked at, and that is exactly
            ' what the first version was. `set_has_frame(false)` is the GTK 4
            ' way; the stylesheet's `flat` is Studio's own prefixed class and
            ' means something else (it is what stops a listbox painting a view
            ' background).
            b.set_has_frame(false)
            b.halign = gi.enum("Gtk.Align.FILL")
            inner = b.get_child()
            if inner != nothing then
                inner.xalign = 0
            end if
            box.append(b)
            items[a] = b
        end for
        pop.set_child(box)
        return { popover: pop, items: items, parented: false }
    end function

    ' Show the items this row offers and hide the rest. Returns whether there is
    ' anything to show -- an empty menu is worse than none, because a popover
    ' with nothing in it reads as a control that failed.
    function context_for(menu, actions)
        any = false
        for each a in studio_ui.context_all()
            b = menu.items[a]
            wanted = contains(actions, a)
            b.set_visible(wanted)
            if wanted then
                any = true
            end if
        end for
        return any
    end function

    ' ---- the schema browser (STU-17) ---------------------------------------

    ' What the database says about itself, for the connection this document
    ' names. A window Studio BUILDS, like the snippet and New Project windows
    ' and for the same reason: every control is an ordinary widget whose value
    ' can be set, so a display tier can drive it.
    '
    ' The columns are read ON DEMAND, one table at a time, rather than fetched
    ' for the whole database when the window opens. Two reasons, and the second
    ' is the one that decided it: a browser that pre-fetches every column of
    ' every table does work nobody asked for and returns a payload nobody
    ' bounded -- and the window can only show the EXACT question it asked about
    ' the table you are looking at if it asks one per table. A bulk fetch would
    ' have to display a query that is not about what is on screen, which is the
    ' magic this whole surface refuses.
    '
    ' The cost, stated: each pick is a blocking child (see `studio_schema`), so
    ' against a remote database there is a pause. `studio_schema.timeout_s()`
    ' bounds it.
    function schema_window(gtkapp, tables, source, conn_name, driver)
        u = studio_style.unit()
        win = gtk.application_window(gtkapp)
        win.title = "gBASIC Studio — schema"
        win.default_width = 600
        win.default_height = 520
        outer = gtk.box("v", u)
        outer.margin_start = u * 2
        outer.margin_end = u * 2
        outer.margin_top = u * 2
        outer.margin_bottom = u * 2

        head = studio_shell._left(gtk.label("What this database says about itself"))
        head = studio_style.apply(head, "head")
        outer.append(head)

        ' WHICH database, said out loud -- the same reason the snippet window
        ' says it. The connection is named in a comment three lines up in the
        ' file and nothing else on screen repeats it.
        where = studio_shell._left(gtk.label(conn_name + " — " + driver))
        where = studio_style.apply(where, "dim")
        outer.append(where)

        names = []
        for each t in tables
            names = append(names, studio_schema.table_label(t))
        end for
        model = gi.new("Gtk.StringList")
        for each n in names
            model.append(n)
        end for
        pick = gi.new("Gtk.DropDown")
        pick.set_model(model)
        if count(names) > 0 then
            pick.set_selected(0)
        end if
        pick.hexpand = false
        pick.halign = gi.enum("Gtk.Align.START")
        outer.append(pick)

        ' The columns. `_mono` because this is a list of identifiers and types
        ' in three aligned columns, and a proportional font takes the alignment
        ' away -- the same argument program output already makes.
        '
        ' And `_fill` ON TOP, which is not optional inside a `_vscroll`. Looked
        ' at without it: `_mono` composes `_wrapped`, which wraps at the
        ' label's NATURAL width, and inside a scroller whose horizontal policy
        ' is NEVER the label is handed its minimum -- so the list rendered one
        ' character wide and hyphenated, `id / IN- / TE- / GER`. The identical
        ' string passes the golden either way, which is the whole reason this
        ' section of CLAUDE.md exists and the reason I looked.
        cols = studio_shell._fill(studio_shell._mono(gtk.label("")))
        ' Pinned to the TOP of the scroller. A label given more height than it
        ' needs centres in it, so a three-column table floated in the middle of
        ' the pane with a gap above and below and nothing saying why -- looked
        ' at. A list starts where the control above it ends.
        cols.valign = gi.enum("Gtk.Align.START")
        cols_scroll = studio_shell._vscroll(cols)
        cols_scroll.vexpand = true
        outer.append(cols_scroll)

        ' THE QUESTION STUDIO ASKED, character for character. Not a nicety: it
        ' is the difference between a tool that tells you about your database
        ' and one that shows you how to ask. `pragma table_info` and
        ' `information_schema.columns` are both worth learning from the tool
        ' that used them.
        asked_head = studio_shell._left(gtk.label("Studio asked"))
        asked_head = studio_style.apply(asked_head, "head")
        outer.append(asked_head)
        asked = studio_shell._mono(gtk.label(source))
        asked = studio_shell._wrapped(asked)
        outer.append(asked)

        note = studio_shell._wrapped(gtk.label(""))
        note = studio_style.apply(note, "dim")
        outer.append(note)

        row = gtk.box("h", u)
        row.halign = gi.enum("Gtk.Align.END")
        close_btn = gtk.button("Close")
        ins_btn = gtk.button("Insert a select")
        ins_btn.set_tooltip_text("Write `select <every column> from <this table>;` into your document, at the caret. Naming the columns rather than `select *` is the habit worth keeping.")
        ins_btn.add_css_class(studio_style.css_class("suggested-action"))
        row.append(close_btn)
        row.append(ins_btn)
        outer.append(row)

        win.set_child(outer)
        return { window: win, pick: pick, tables: tables, cols: cols,
                 asked: asked, note: note, columns: [],
                 close_btn: close_btn, insert_btn: ins_btn }
    end function

    ' Which table is selected, or -1.
    function schema_index(w)
        if count(w.tables) = 0 then
            return 0 - 1
        end if
        sel = w.pick.get_selected()
        if sel < 0 then
            return 0 - 1
        end if
        if sel >= count(w.tables) then
            return 0 - 1
        end if
        return sel
    end function

    ' Render one table's columns, and the question that produced them. Takes
    ' the record `studio_ui.schema_columns` returned -- refusal included, so
    ' the window says why rather than going blank.
    function schema_set_columns(w, r)
        if not r.ok then
            w.cols.label = ""
            w.note.label = studio_ui.action_notice(r.why, r.detail)
            w.columns = []
            return w
        end if
        lines = []
        for each c in r.columns
            lines = append(lines, studio_schema.column_label(c))
        end for
        if count(lines) = 0 then
            ' A table with no columns is not a thing; an empty answer means the
            ' name did not match, which is worth saying rather than showing a
            ' blank pane that reads as still loading.
            w.cols.label = "(the database returned no columns for this table)"
        else
            w.cols.label = join(lines, "\n")
        end if
        w.asked.label = r.source
        w.note.label = ""
        w.columns = r.columns
        return w
    end function

    ' ---- the header menus (STU-16) ------------------------------------------

    ' One menu: a `Gtk.MenuButton` with a popover of ordinary buttons hanging off
    ' it. The SAME construction as the browser's right-click menu, for the same
    ' reason -- a `Gtk.PopoverMenu` is driven by a `GMenuModel` built through
    ' class statics the `gi` bridge cannot reach, and plain buttons are also what
    ' makes a menu testable, because a test can press one.
    '
    ' Measured before it was written: `Gtk.MenuButton` constructs through
    ' `gi.new`, and `set_popover`, `get_popover`, `set_always_show_arrow` and
    ' `popup`/`popdown` are all ordinary instance methods. `popup()` on a button
    ' that is not yet inside a toplevel crashes -- GTK's own rule, the same shape
    ' as the widget-before-init crash -- which is not a constraint here because
    ' the header is built into the window.
    '
    ' Returns the button, and the item widgets keyed by ACTION, so the entry
    ' program connects them by name and nothing here holds a handler.
    function menu_button(spec)
        mb = gi.new("Gtk.MenuButton")
        ' THE ARROW IS A CHARACTER IN THE LABEL, not `always-show-arrow`.
        '
        ' Looked at: with `set_always_show_arrow(true)` on GTK 4.22 the two
        ' menus rendered as plain rectangles reading "Project" and "File",
        ' indistinguishable from the Save button beside them -- which is the
        ' complaint this whole phase exists to answer, reproduced by the fix for
        ' it. The property is set and reads back true; nothing is drawn.
        '
        ' `▾` is not a new idea in this window: it is already the browser's
        ' glyph for an expanded directory, so it already means "this opens" to
        ' anyone who has clicked a folder. Geometric Shapes, which every
        ' mainstream UI font carries -- the same ground the browser glyphs stand
        ' on, and the opposite of the `dialog-error` situation where an icon
        ' THEME could simply lack the name.
        mb.label = spec.label + " ▾"
        pop = gi.new("Gtk.Popover")
        pop.set_has_arrow(true)
        box = gtk.box("v", 0)
        box = studio_style.apply(box, "panel")
        items = {}
        for each a in spec.items
            if a = "-" then
                box.append(studio_shell._rule())
            else
                b = gtk.button(studio_ui.menu_label(a))
                ' Frameless and LEFT-aligned, or the column reads as a stack of
                ' buttons rather than as a menu.
                b.set_has_frame(false)
                b.halign = gi.enum("Gtk.Align.FILL")
                inner = b.get_child()
                if inner != nothing then
                    inner.xalign = 0
                end if
                ' The sentence the toolbar button had no room for.
                b.set_tooltip_text(studio_ui.menu_hint(a))
                box.append(b)
                items[a] = b
            end if
        end for
        pop.set_child(box)
        mb.set_popover(pop)
        return { button: mb, popover: pop, items: items }
    end function

    ' Every menu the header holds, keyed by id, plus one flat map from action to
    ' item widget. The flat map is what the entry program connects and what a
    ' display tier presses; the per-menu records are what a test opens.
    function menu_bar()
        menus = {}
        items = {}
        for each spec in studio_ui.menus()
            m = studio_shell.menu_button(spec)
            menus[spec.id] = m
            for each a in spec.items
                if a != "-" then
                    items[a] = m.items[a]
                end if
            end for
        end for
        return { menus: menus, items: items }
    end function

    ' A tab's right-click menu (STU-21).
    '
    ' The SAME construction as the browser's context menu and the header menus:
    ' a `Gtk.Popover` of ordinary `Gtk.Button`s, built ONCE and reparented to
    ' whichever tab was clicked. Plain buttons because a test can press one.
    function tab_menu()
        pop = gi.new("Gtk.Popover")
        pop.set_has_arrow(true)
        box = gtk.box("v", 0)
        box = studio_style.apply(box, "panel")
        items = {}
        for each a in studio_ui.tab_menu_all()
            b = gtk.button(studio_ui.tab_menu_label(a))
            b.set_has_frame(false)
            b.halign = gi.enum("Gtk.Align.FILL")
            inner = b.get_child()
            if inner != nothing then
                inner.xalign = 0
            end if
            box.append(b)
            items[a] = b
        end for
        pop.set_child(box)
        return { popover: pop, items: items, parented: false }
    end function

    ' Put text on the system clipboard.
    '
    ' NOT `clipboard.set_text`, which HANGS -- measured, the call never
    ' returns and the process has to be killed. The working route is a scratch
    ' `Gtk.TextBuffer`: set the text, select it, and `copy_clipboard`. Only
    ' instance methods, on a type Studio already builds, and proven by a round
    ' trip (copy, then paste into a second buffer and read it back).
    '
    ' The clipboard is a place the user CANNOT SEE, so a failure here is
    ' invisible by construction -- which is why the route was round-tripped
    ' rather than assumed from the call returning.
    function copy_text(shell, text)
        cb = shell.window.get_clipboard()
        buf = gi.new("Gtk.TextBuffer")
        buf.set_text(text, 0 - 1)
        buf.select_range(buf.get_start_iter(), buf.get_end_iter())
        buf.copy_clipboard(cb)
        ' THE BUFFER IS KEPT. `copy_clipboard` does not hand the clipboard a
        ' copy of the string -- it installs a content provider that reads from
        ' this buffer when somebody pastes. A local buffer is gone by then, and
        ' the paste returns NOTHING with no error anywhere: measured, the copy
        ' reported success, the status line named the path, and pasting it back
        ' produced an empty string.
        '
        ' Fourth time in this codebase that a gobject had to be held to stay
        ' alive, after `_STUDIO_STYLE`, `G.ctx_gesture` and the editors'
        ' controllers. This one is the worst of them, because the clipboard is
        ' a place the user cannot see: the failure is silent at every layer.
        shell.clip_buf = buf
        return shell
    end function

    ' A notebook tab's label (STU-21).
    '
    ' It carries the DOCUMENT ID in its widget name. That is how the
    ' right-click handler knows which tab it is on: the gesture hands back the
    ' widget it is attached to, and reading a string property off that widget
    ' is the whole of the widget-to-value read. Comparing gobject handles for
    ' identity would be the alternative and is a thing this codebase has never
    ' needed to do.
    '
    ' `name` is the CSS node name, and nothing in Studio's stylesheet targets a
    ' document id, so this is inert as styling.
    function _tab_label(t)
        lbl = gtk.label(t.label)
        lbl.name = t.doc_id
        return lbl
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

    ' A label that takes the width it is GIVEN rather than the width it wants.
    '
    ' `_left` sets halign START, which hands a label its NATURAL width — and
    ' `_wrapped` caps that at `max_width_chars`, a number chosen for the
    ' right-hand column. In the console, which is roughly twice as wide, the
    ' result is output folded into a narrow ribbon with half the pane empty
    ' beside it. xalign keeps the text left; halign FILL is what makes it span.
    ' The same pair the status bar needed, for the same reason.
    '
    ' Safe only inside `_vscroll`, whose horizontal policy of NEVER makes the
    ' viewport impose a width; `max_width_chars` still caps the NATURAL request,
    ' so this does not widen the window's minimum.
    function _fill(lbl)
        lbl.xalign = 0
        lbl.halign = gi.enum("Gtk.Align.FILL")
        lbl.hexpand = true
        return lbl
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
        ' STU-18: the settings items carry their own state in their labels, so
        ' they are re-rendered on every full redraw. Not in `refresh_run` --
        ' that is the run poller at sixteen ticks a second and none of this
        ' changes while a program is running.
        studio_shell.refresh_menu_marks(shell, app)
        studio_shell.apply_dark(shell, app)
        studio_shell.apply_zoom(shell, app)
        line = studio_shell.status_text(app)
        if notice != "" then
            line = notice
        end if
        shell.status.label = line
        if clear_name then
            shell.name_entry.text = ""
        end if
        return { shell: shell, app: app, new_editors: rec.new_editors, new_tabs: rec.new_tabs }
    end function

    ' Apply or remove Studio's own dark sheet (STU-19).
    '
    ' DISPLAY-WIDE, which is the one thing here that is not per-widget -- and
    ' has to be, because it restyles nodes Studio never touches directly:
    ' scrollbars, paned handles, notebook tabs, popover contents. The call was
    ' believed unreachable for three phases; measured, `gi.invoke` resolves it
    ' and `widget.get_display()` supplies the display.
    '
    ' Cached on `shell.dark_on` and compared, because this runs on every full
    ' redraw and re-adding a provider stacks another one for the life of the
    ' process -- the same mistake `install_teaching_css` avoids by installing
    ' once at build time.
    function apply_dark(shell, app)
        want = studio_ui.theme_of(app) = "dark"
        if want = shell.dark_on then
            return nothing
        end if
        disp = shell.window.get_display()
        if want then
            if shell.dark_css = nothing then
                ' Built once and kept: parsing the sheet on every toggle is
                ' work for nothing, and a provider that is added and removed is
                ' the same object either way.
                prov = gi.new("Gtk.CssProvider")
                prov.load_from_string(studio_style.dark_css())
                shell.dark_css = prov
            end if
            gi.invoke("Gtk.StyleContext.add_provider_for_display", disp,
                      shell.dark_css, studio_style.dark_priority())
        else
            if shell.dark_css != nothing then
                gi.invoke("Gtk.StyleContext.remove_provider_for_display", disp,
                          shell.dark_css)
            end if
        end if
        shell.dark_on = want
        return nothing
    end function

    ' Apply the editor's text size (STU-20).
    '
    ' Display-wide and REPLACED on change, never stacked: adding a provider
    ' does not supersede an earlier one, it joins it, so eight presses of
    ' Bigger would leave eight sheets fighting over one property. Remove then
    ' add, gated on the value actually changing.
    function apply_zoom(shell, app)
        want = studio_ui.editor_zoom(app)
        if want = shell.zoom_at then
            return nothing
        end if
        disp = shell.window.get_display()
        if shell.zoom_css != nothing then
            gi.invoke("Gtk.StyleContext.remove_provider_for_display", disp, shell.zoom_css)
        end if
        prov = gi.new("Gtk.CssProvider")
        prov.load_from_string(studio_style.zoom_css(want))
        gi.invoke("Gtk.StyleContext.add_provider_for_display", disp, prov,
                  studio_style.zoom_priority())
        shell.zoom_css = prov
        shell.zoom_at = want
        return nothing
    end function

    ' Put each settings item's own state into its label (STU-18).
    '
    ' A menu of plain `Gtk.Button`s cannot draw a radio mark -- that needs a
    ' `Gtk.PopoverMenu` over a `GMenuModel`, which is built from class statics
    ' the `gi` bridge cannot reach and which no test could press either. So the
    ' mark is a character, and `studio_ui.menu_text` is the ONE place the
    ' string is assembled, because the goldens address these items by it.
    ' Returns NOTHING, deliberately. Every widget it touches is a gobject
    ' handle, so setting a label reaches the real button and there is no
    ' updated record to hand back -- and returning `shell` and discarding it
    ' earns gBASIC warning 2101 on stderr at every redraw, which several
    ' golden tiers capture. `sections_gui` caught it immediately.
    function refresh_menu_marks(shell, app)
        for each spec in studio_ui.menus()
            for each a in spec.items
                if a != "-" then
                    m = studio_ui.menu_mark(app, a)
                    if m != "" then
                        b = shell.menubar.items[a]
                        b.label = studio_ui.menu_text(app, a)
                    end if
                end if
            end for
        end for
        return nothing
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
        shell.bar.runall.set_visible(studio_ui.shows_run_all(app))
        shell.bar.snippet.set_visible(studio_ui.shows_snippets(app))
        shell.bar.schema.set_visible(studio_ui.shows_schema(app))
        shell.bar.standing.label = studio_ui.standing_line(app)
        shell.pane.prefix.label = studio_ui.prefix_body(app)
        shell.pane.target.label = studio_ui.target_body(app)
        errs = studio_ui.error_body(app)
        shell.pane.errors.label = errs
        ' Said twice on purpose: in the heading, where the eye lands, and in the
        ' body, where the text is. A heading reading "Errors" over a pane below
        ' the fold is indistinguishable from a heading reading "Errors" over
        ' "(none)".
        shell.pane.errors_head.label = studio_ui.error_heading(errs)
        if studio_ui.error_count(errs) > 0 then
            studio_style.set_state(shell.pane.errors_head, "state-error")
        else
            ' CLEARED rather than set to idle: the heading has a look of its own
            ' and should get it back, and `state-idle` is a colour, not an
            ' absence.
            studio_style.clear_state(shell.pane.errors_head)
        end if
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

        ' The parser's marks, on the same gutter. Gated on the SIGNATURE, not on
        ' the revision the section marks use: a failed parse does not advance the
        ' revision (see studio_ui.error_marks), so a revision-gated redraw would
        ' pin the error to wherever it first appeared.
        em = studio_ui.error_marks(app)
        app = em.app
        if shell.errmarked[em.doc_id] != em.signature then
            ebuf = ed.buffer
            es = sourceeditor._iter(ebuf.get_start_iter())
            ee = sourceeditor._iter(ebuf.get_end_iter())
            ebuf.remove_source_marks(es, ee, "error")
            for each ln in em.lines
                ed.mark(ln, "error")
            end for
            shell.errmarked[em.doc_id] = em.signature
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
            ' Same decision as the editor's scheme, in smaller print: a pale
            ' blue tint is a highlight on a light editor and a smear over
            ' unreadable text on a dark one.
            dset = ed.view().get_settings()
            dark = studio_style.dark_for(app.model.settings.theme,
                                         dset.gtk_theme_name,
                                         dset.gtk_application_prefer_dark_theme,
                                         env("GTK_THEME"))
            shell.hl_tag = ed.highlight(r.start0, r.end0, studio_style.section_tint(dark))
            shell.hl_doc = m.doc_id
        end if
        return { shell: shell, app: app }
    end function

    ' Highlight a buffer as whatever its file actually is.
    '
    ' Every editor was created with `set_language("gbasic")`, so a README was
    ' syntax-highlighted as a program — `#` headings as comments and the rest as
    ' undefined identifiers.
    '
    ' STUDIO decides what is gBASIC; the TOOLKIT decides everything else. A
    ' GtkSourceLanguageManager already knows markdown, json, yaml, html, css,
    ' python, sh, C, XML, TOML, SQL, Rust and Go, and `guess_language` is how
    ' you ask it — so this is not a table of extensions Studio would have to
    ' keep up to date, which is the same boundary the rest of the project draws
    ' against the stdlib.
    '
    ' Through the editor's OWN manager (`ed._lm`), never a fresh one: a
    ' GtkSourceBuffer's highlight engine calls back into the manager that
    ' produced its language, and `sourceeditor.language()` builds a transient
    ' one that finalizes on return — which sourceeditor's own header documents
    ' as a GtkSourceView critical.
    '
    ' `ed.set_language(id)` RAISES on an id the manager does not have and gBASIC
    ' cannot catch a raise, so everything but gBASIC goes through the object
    ' `guess_language` returns, and `nothing` simply means no highlighting —
    ' which is correct for a .txt, and for a Makefile, which it does not know.
    function _set_language_for(ed, path)
        if studio_ui.is_gbasic(path) then
            ' Not guessed. Studio without its own highlighting is broken in a
            ' way worth raising about, and the guess would depend on a search
            ' path rather than on the one fact Studio is sure of.
            ed.set_language("gbasic")
            return nothing
        end if
        lang = ed._lm.guess_language(path, nothing)
        if lang != nothing then
            ed.buffer.set_language(lang)
        end if
        return nothing
    end function

    ' Resolve a style scheme id to the object a buffer wants, or `nothing`.
    '
    ' `GtkSource.StyleSchemeManager.get_default` is a class static and out of
    ' reach, but a manager constructed here searches the same default path — the
    ' installed schemes came back from `get_scheme_ids` on one.
    function _scheme(id)
        mgr = gi.new("GtkSource.StyleSchemeManager")
        return mgr.get_scheme(id)
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
        new_tabs = []

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
            return { shell: shell, new_editors: new_editors, new_tabs: new_tabs }
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

        ' THE ADAPTER RULE, applied to the toolkit instead of a widget: read the
        ' plain values, let `studio_style` decide. `Gtk.Settings.get_default` is
        ' a class static the gi bridge cannot reach, but `get_settings()` is an
        ' ordinary instance method on any widget and answers the same object.
        tset = book.get_settings()
        scheme_id = studio_style.scheme_for(app.model.settings.theme,
                                            tset.gtk_theme_name,
                                            tset.gtk_application_prefer_dark_theme,
                                            env("GTK_THEME"))
        scheme = studio_shell._scheme(scheme_id)

        ' A THEME CHANGE HAS TO REACH THE PAGES THAT ALREADY EXIST (STU-18).
        '
        ' The scheme was derived on every redraw from the first day, and
        ' applied only to pages being CREATED -- which was invisible while
        ' nothing could change the setting, because the only way to change it
        ' was to hand-edit the file and restart. With a Settings menu, picking
        ' Dark would have left every open editor light until you closed and
        ' reopened its tab, one tab at a time.
        '
        ' Cached on the shell and compared, rather than re-set every redraw:
        ' this runs at cursor-move rate through `refresh`, and handing every
        ' buffer a style scheme sixteen times a second is the mistake
        ' `refresh_run` exists to avoid. The cache is primed to "-", which is
        ' not reachable as a real scheme id, for the same reason the mark
        ' caches are.
        if scheme_id != shell.scheme_id then
            if scheme != nothing then
                for each pg in shell.pages
                    pg.editor.buffer.set_style_scheme(scheme)
                end for
            end if
            shell.scheme_id = scheme_id
        end if

        ' Create a page for every document that does not have one yet.
        for each t in want
            have = studio_shell._page_index(shell.pages, t.doc_id)
            if have < 0 then
                doc = studio_docs.doc_by_id(app.dm, t.doc_id)
                ed = sourceeditor.create()
                ed.set_text(doc.content)
                studio_shell._set_language_for(ed, doc.path)
                ' A style scheme is NOT the GTK theme, and nothing was setting
                ' one — which is why the editor stayed white inside a dark
                ' window. `nothing` means the scheme is not installed on this
                ' machine, and the buffer keeps its default rather than being
                ' handed a null.
                if scheme != nothing then
                    ed.buffer.set_style_scheme(scheme)
                end if
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
                ' The parser's mark, at a HIGHER priority than the section one:
                ' a syntax error very often sits on the first line of the thing
                ' it broke, and the gutter draws one icon per line. The section
                ' start is recoverable (the strip names it); the error is the
                ' only thing that says where to look.
                '
                ' STUDIO SHIPS THIS ICON. `dialog-error` and
                ' `dialog-error-symbolic` are both standard names and NEITHER
                ' resolved here — measured, not assumed: this install's Breeze
                ' has the first and not the second, its Adwaita has the second
                ' and not the first, and what the gutter actually drew was GTK's
                ' missing-icon fallback, a grey disc wide enough to sit on top
                ' of the code. A marker that lands on the wrong icon is worse
                ' than no marker, so the name is Studio's own and the file is in
                ' share/icons/hicolor, which every theme inherits and `./studio`
                ' already puts on XDG_DATA_DIRS for the window icon.
                '
                ' `MarkAttributes.set_background` would need a `Gdk.RGBA`, and
                ' `gi.new` refuses it: "not an instantiable object type".
                bad = gi.new("GtkSource.MarkAttributes")
                bad.set_icon_name("gbasic-studio-error")
                vw.set_mark_attributes("error", bad, 2)
                sc = gtk.scrolled(ed.view())
                sc.vexpand = true
                sc.hexpand = true
                tab_lbl = studio_shell._tab_label(t)
                book.append_page(sc, tab_lbl)
                ' STU-21: handed back so the entry program can put a
                ' right-click gesture on it. Returned rather than connected
                ' here, because `gi.connect` lives only in app/studio.bas.
                new_tabs = append(new_tabs, tab_lbl)
                ' A NEW BUFFER HAS NO MARKS, and both caches are keyed by
                ' document id, which a closed-and-reopened file keeps. Left
                ' alone, the cache would say "already drawn at this revision /
                ' signature" about a buffer that was created two lines ago, and
                ' the gutter would stay empty until something else moved.
                ' Neither value is reachable as a real one — a revision counts
                ' up from 1, a signature is digits and commas — so the first
                ' decoration always draws.
                shell.marked[t.doc_id] = -1
                shell.errmarked[t.doc_id] = "-"
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
                ' REUSED, not rebuilt (STU-21). This used to hand the notebook
                ' a fresh `gtk.label` on every reconcile, which was invisible
                ' while nothing was attached to it -- and a right-click gesture
                ' is attached to it now. A label replaced on every redraw takes
                ' its controller with it, and the menu would work until the
                ' first time anything else moved.
                lbl = book.get_tab_label(pg.child)
                if lbl = nothing then
                    book.set_tab_label(pg.child, studio_shell._tab_label(t))
                else
                    if lbl.label != t.label then
                        lbl.label = t.label
                    end if
                end if
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

        return { shell: shell, new_editors: new_editors, new_tabs: new_tabs }
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
        ' TWO MENUS AND ONE BUTTON, where there were ten buttons (STU-16). The
        ' row used to mix three scopes -- the workspace, the browser selection
        ' and the active document -- with nothing saying which was which, and
        ' `studio_ui.menus` is where that is now said: a menu NAME gives its
        ' items a scope and a menu ITEM has room to name what it acts on, which
        ' a rectangle with a width budget never did.
        '
        ' Every item dispatches to the same `studio_ui` function its button
        ' called, and the shell keeps the SAME record keys, so nothing about
        ' arming, refusing or naming changed -- only where the control lives and
        ' what it is called.
        header = gtk.box("h", studio_style.unit())
        header = studio_style.apply(header, "toolbar")
        wordmark = studio_shell._left(gtk.label("gBASIC Studio"))
        wordmark = studio_style.apply(wordmark, "title")
        header.append(wordmark)
        header.append(studio_shell._bar())

        menubar = studio_shell.menu_bar()
        for each spec in studio_ui.menus()
            header.append(menubar.menus[spec.id].button)
        end for
        header.append(studio_shell._bar())

        ' STU-2D's name field. `gtk` has no entry constructor, and that library
        ' says so on purpose ("callers drop straight down to the raw gi bridge for
        ' anything not wrapped here"), so this is one gi.new rather than a change
        ' to somebody else's stdlib.
        '
        ' It is a field and not a dialog because a GtkEntry is an ordinary widget:
        ' its text can be set programmatically, which means the display tier can
        ' type into it and click Rename for real. A modal dialog could not be
        ' driven by any test we can write.
        '
        ' It expanded to fill the header and pushed every button to the right; it
        ' needs a width, not all of the width.
        name_entry = gi.new("Gtk.Entry")
        ' "name" was the whole of what this field said about itself, and Open
        ' Folder reads it as a PATH — so the one way to open a project you
        ' already have was spelled nowhere in the window. A placeholder is the
        ' cheapest label there is and it is already on screen.
        name_entry.placeholder_text = "name or path"
        name_entry.set_tooltip_text("A name for New File / New Folder / Rename, or a folder path for Open Folder (~ works). New Project asks for its own.")
        name_entry.max_width_chars = 18
        name_entry.hexpand = false
        header.append(name_entry)
        header.append(studio_shell._bar())

        ' The ONE verb that stays a button. It is pressed constantly, it is the
        ' only header control with a state of its own (the conflict arm, which is
        ' why it is two clicks over a file that changed underneath), and putting
        ' it in a menu as well would be a second widget for the teaching registry
        ' and the smoke modes to tell apart.
        save_btn = gtk.button("Save")
        save_btn.set_tooltip_text("Write the active document to disk. Over a file that changed underneath, press twice — the first press arms it.")
        header.append(save_btn)

        ' The old names, kept: the entry program connects by these and several
        ' smoke modes activate them. Delete takes the stock destructive class,
        ' which the theme colours — it is the only control in this window that
        ' removes a file from disk.
        new_btn = menubar.items["new-project"]
        open_btn = menubar.items["open-folder"]
        projfile_btn = menubar.items["project-file"]
        closeproj_btn = menubar.items["close-project"]
        file_btn = menubar.items["new-file"]
        folder_btn = menubar.items["new-folder"]
        rename_btn = menubar.items["rename"]
        delete_btn = menubar.items["delete"]
        refresh_btn = menubar.items["reload"]
        close_btn = menubar.items["close-tab"]
        ' The one item that removes a file from disk, and the ONE place in this
        ' header with a colour.
        '
        ' `studio-danger` and NOT the stock `.destructive-action` it wore as a
        ' toolbar button. Looked at, with the hover state forced on with
        ' `set_state_flags(PRELIGHT)`: that class paints a BACKGROUND, the
        ' theme's own `button:hover` background beats it, and the tint vanished
        ' -- Delete rendered identically to Close Tab. Keeping the frame did
        ' not help either; measured both ways. The warning was disappearing at
        ' the one moment it is being read, the instant before the click, and no
        ' golden can see it because the label is the same string either way.
        ' Studio's own class colours the TEXT instead, which the hover
        ' background cannot take away.
        delete_btn = studio_style.apply(delete_btn, "danger")
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
        ctx = studio_shell.context_menu()
        ' Vertical only. With names ellipsizing there is nothing to scroll to
        ' sideways, and a horizontal policy of AUTOMATIC is what lets a child
        ' take its natural width instead of the width it is given — which is
        ' the difference between a name that elides and a name that is clipped.
        nav_scroll = studio_shell._vscroll(nav)
        split.set_start_child(nav_scroll)
        ' Where the user last left it, not a number baked in here. Studio has
        ' read `session.window` since STU-0 and never once written it back, so
        ' a resized window and a dragged divider were both forgotten on exit.
        split.position = studio_model.pane_at(model.session, "browser", 260)

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
        vsplit.position = studio_model.pane_at(model.session, "console", 380)

        rsplit = gtk.paned("h")
        rsplit.set_start_child(vsplit)
        rsplit.set_end_child(beside_scroll)
        rsplit.position = studio_model.pane_at(model.session, "right", 620)
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
                 name_entry: name_entry, open_btn: open_btn,
                 projfile_btn: projfile_btn, rename_btn: rename_btn,
                 delete_btn: delete_btn, close_btn: close_btn,
                 save_btn: save_btn, refresh_btn: refresh_btn,
                 closeproj_btn: closeproj_btn,
                 ' STU-16: the header menus. `menus` is keyed by menu id and
                 ' holds the MenuButton and its popover -- a display tier opens
                 ' one with `popup()`. `items` is flat, keyed by action, and is
                 ' the same widgets the named keys above point at.
                 menubar: menubar,
                 ' The three GtkPaneds themselves, so the exit path can ask
                 ' where they ended up. Nothing else reads them.
                 split: split, vsplit: vsplit, rsplit: rsplit,
                 ' STU-13: the browser's right-click menu. The GESTURE that
                 ' raises it is made in app/studio.bas, which is the only place
                 ' allowed to call gi.connect.
                 ctx: ctx,
                 ' STU-21: a tab's own right-click menu, built once.
                 tabctx: studio_shell.tab_menu(),
                 ' STU-21: the scratch buffer behind the last clipboard copy,
                 ' kept alive because the clipboard reads from it lazily.
                 clip_buf: nothing,
                 bar: bar, pane: pane, rpane: rpane, apane: apane, bpane: bpane,
                 tpane: tpane, gpane: gpane,
                 ' STU-5 decoration state: which outline revision each document's
                 ' gutter marks were drawn for, and the one live highlight tag.
                 ' `errmarked` is the same idea for the parser's marks, keyed on
                 ' their line signature because a failed parse leaves the
                 ' revision where it was.
                 marked: {}, errmarked: {}, hl_tag: nothing, hl_doc: "",
                 ' STU-10 teaching state: what currently carries a class.
                 pulsing: nothing, pulse_class: "", highlighted: nothing, highlight_class: "",
                 teach_tag: nothing,
                 ' STU-18: the editor style scheme currently applied to every
                 ' page. Primed to "-", which is not reachable as a real
                 ' scheme id, so the first redraw always applies one.
                 scheme_id: "-",
                 ' STU-19: Studio's own dark sheet, built on first use and
                 ' added to the DISPLAY. `dark_on` is primed false because the
                 ' sheet starts unapplied, which is true of a fresh window
                 ' whatever the setting says -- the first redraw applies it.
                 dark_css: nothing, dark_on: false,
                 ' STU-20: the editor text size, and what is currently applied.
                 ' Primed to -1, which is not on the ladder, so the first
                 ' redraw always installs a sheet.
                 zoom_css: nothing, zoom_at: 0 - 1,
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

    ' TWO ROWS, and the second one exists for one reason: the state line is the
    ' only place a REFUSAL or a materialization FAILURE is ever written, and
    ' those carry a whole sentence ("that section is ambiguous after the last
    ' edit; disambiguate it first"). Sharing one horizontal row with three
    ' buttons and two more labels, an ellipsized sentence became "run: refused
    ' [sec-3] — that sec…" and the rest of it existed nowhere on screen. A
    ' horizontal row has a hard width budget; a sentence does not fit in one.
    '
    ' So the buttons and the two SHORT labels keep the top row, and the state
    ' line gets a row of its own, at the full width of the console, where it can
    ' wrap instead of being cut.
    function run_bar()
        u = studio_style.unit()
        bar = gtk.box("v", u)
        controls = gtk.box("h", u)
        run_btn = gtk.button("Run Section")
        ' The stock suggested class. Of the three buttons on this strip one is
        ' what you came here to press and two are what you press when it goes
        ' wrong, and they were indistinguishable.
        run_btn.add_css_class(studio_style.css_class("suggested-action"))
        ' Run All is for a `.sql` document and is HIDDEN for anything else --
        ' `refresh_run` sets that from `studio_ui.shows_run_all`. A gBASIC
        ' document already replays everything above the caret when you press
        ' Run Section, so the button would mean nearly the same thing there and
        ' be one more control to tell apart. Built once and shown or hidden,
        ' like the branch pane, rather than added and removed.
        all_btn = gtk.button("Run All")
        ' Same rule, same place: `.sql` only, set by `refresh_run` from
        ' `studio_ui.shows_snippets`. It sits on the run strip rather than in
        ' the header menus because this is where SQL's verbs already are, and
        ' because both of these are about the DOCUMENT's connection rather than
        ' about the workspace, the selection or the file.
        snip_btn = gtk.button("Snippet…")
        ' STU-17, and the third of the three. Same rule again.
        schema_btn = gtk.button("Schema…")
        schema_btn.set_tooltip_text("What this database says about itself: its tables and views, and the columns of one. It shows the exact question it asked.")
        snip_btn.set_tooltip_text("Write a statement into this file. It is not run -- you read it, edit it, and press Run.")
        halt_btn = gtk.button("Stop")
        force_btn = gtk.button("Force Stop")
        ' The state carried in the TEXT only — "run: running" and "run: failed" in
        ' the same grey. The text is unchanged (the goldens assert it); the class
        ' moves with the state, and `refresh_run` is what moves it.
        state = studio_shell._left(gtk.label("run: idle"))
        state = studio_style.apply(state, "state-idle")
        ' WRAPPING, now that it owns a row — and wrapping rather than ellipsizing
        ' also answers the minimum-width problem the ellipsis was there for. A
        ' label that neither wraps nor ellipsizes reports its WHOLE SENTENCE as
        ' its minimum width, which is what let a narrow window starve the console
        ' until it clipped from the left; a WRAPPING label reports its longest
        ' WORD, which is smaller than the ellipsized version ever was.
        '
        ' `max_width_chars` for the reason `_wrapped` documents at length: `wrap`
        ' alone leaves the natural width at the whole sentence on one line, and a
        ' scroller hands a child its natural width. 72 rather than `_wrapped`'s
        ' 44 because this row spans the console, which is a good deal wider than
        ' the right-hand column that number was chosen for.
        state.wrap = true
        state.wrap_mode = gi.enum("Pango.WrapMode.WORD_CHAR")
        state.max_width_chars = 72
        ' And it SPANS the row, rather than folding at its natural width with
        ' the rest of the console empty beside it.
        state = studio_shell._fill(state)
        ' STU-5A′: which section Run would run, shown BEFORE you press it rather
        ' than after. It follows the caret.
        section = studio_shell._left(gtk.label("section: (none)"))
        section = studio_style.apply(section, "dim")
        section.ellipsize = gi.enum("Pango.EllipsizeMode.END")
        ' STU-5 §10.3: whether what you are looking at is live in this session or
        ' a record from an earlier one.
        standing = studio_shell._left(gtk.label(""))
        standing = studio_style.apply(standing, "dim")
        ' These two stay on the horizontal row, so they still cannot wrap;
        ' ellipsize instead, which at least SAYS it was cut rather than stopping
        ' mid-word. Both are short by construction — an id and a word — which is
        ' why they are the two that stayed.
        standing.ellipsize = gi.enum("Pango.EllipsizeMode.END")
        branch = studio_shell._left(gtk.label("branch: baseline"))
        branch.ellipsize = gi.enum("Pango.EllipsizeMode.END")
        bar = studio_style.apply(bar, "panel")
        controls.append(run_btn)
        controls.append(all_btn)
        controls.append(snip_btn)
        controls.append(schema_btn)
        controls.append(halt_btn)
        controls.append(force_btn)
        controls.append(section)
        controls.append(standing)
        bar.append(controls)
        ' Under the buttons rather than over them: it is what pressing one of
        ' them produced, and the output headings below it read on from there.
        bar.append(state)
        ' The branch is NOT appended: the selector pane names it a few inches
        ' away, and a fifth label turned the strip into two ellipsized stubs.
        ' The widget stays so a caller can read the text without the pane.
        ' `stop` is a gBASIC keyword and cannot be a record key, hence `halt`.
        return { box: bar, controls: controls, run: run_btn, runall: all_btn,
                 snippet: snip_btn, schema: schema_btn,
                 halt: halt_btn, force: force_btn,
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
        prefix_head = studio_style.apply(studio_shell._fill(studio_shell._wrapped(gtk.label("Prefix output — sections replayed before the target"))), "head")
        prefix_body = studio_shell._fill(studio_shell._mono(gtk.label("")))
        target_head = studio_style.apply(studio_shell._fill(studio_shell._wrapped(gtk.label("Target output — the section you ran"))), "head")
        target_body = studio_shell._fill(studio_shell._mono(gtk.label("")))
        ' STU-5: a section's errors had nowhere to go. The child's stderr was
        ' captured, attributed and stored, and the window showed none of it.
        ' The heading is REFRESHED, not fixed: `refresh_run` rewrites it with a
        ' count and moves it into the error colour when there is something under
        ' it. This pane is the last of the three, so on a short window it is the
        ' one that falls below the fold of the console scroller.
        error_head = studio_style.apply(studio_shell._fill(studio_shell._wrapped(gtk.label("Errors"))), "head")
        error_body = studio_shell._fill(studio_shell._mono(gtk.label("")))
        box.append(prefix_head)
        box.append(prefix_body)
        box.append(studio_shell._rule())
        box.append(target_head)
        box.append(target_body)
        box.append(studio_shell._rule())
        box.append(error_head)
        box.append(error_body)
        return { box: box, prefix: prefix_body, target: target_body,
                 errors: error_body, errors_head: error_head }
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
        ' The MENU, not the item inside it: the item is in a popover that is
        ' shut, and a highlight on a widget nobody can see is a cue that reports
        ' success and draws nothing.
        if name = "project_menu" then
            return shell.menubar.menus["project"].button
        end if
        if name = "file_menu" then
            return shell.menubar.menus["file"].button
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
                "run_button", "save_button", "project_menu",
                "file_menu", "overlay_strip"]
    end function

    ' Install the teaching stylesheet, once, at build time.
    '
    ' PER WIDGET, not display-wide — and by CHOICE, not necessity. This comment
    ' used to say `Gtk.StyleContext.add_provider_for_display` was unreachable
    ' because gi.invoke does not resolve class statics. MEASURED, gi.invoke
    ' DOES resolve that one, with `widget.get_display()` supplying the display.
    ' Per-widget is still the better answer for TEACHING specifically: these are
    ' cues on named widgets, so no display-wide state and nothing to leak into
    ' another window, and the styles exist exactly where they are used.
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

    ' ---- STU-12: the New Project window -------------------------------------
    '
    ' A WINDOW Studio builds, not a system dialog. The same reason names come
    ' from a header field and confirmations are two clicks: a GtkFileDialog or
    ' a GtkAlertDialog is async with no signal a test can synthesise, so it
    ' would be the one surface in this application nothing could press. Every
    ' control here is an ordinary widget whose value can be SET, so the display
    ' tier fills the form and clicks Create for real.
    '
    ' It holds no decisions. It reads an options record in and hands one back
    ' out; what those options MEAN is `studio_ui.project_plan`, headless.
    function new_project_window(gtkapp, opts, license_ids)
        u = studio_style.unit()
        win = gtk.application_window(gtkapp)
        win.title = "gBASIC Studio — new project"
        win.default_width = 520
        outer = gtk.box("v", u)
        outer.margin_start = u * 2
        outer.margin_end = u * 2
        outer.margin_top = u * 2
        outer.margin_bottom = u * 2

        head = studio_shell._left(gtk.label("New project"))
        head = studio_style.apply(head, "head")
        outer.append(head)

        ' A grid, so the three fields line up on one left edge. A box of boxes
        ' gives three labels of three different widths and three entries that
        ' start in three different places.
        grid = gi.new("Gtk.Grid")
        grid.set_column_spacing(u * 2)
        grid.set_row_spacing(u)
        name_entry = studio_shell._field(opts.name)
        loc_entry = studio_shell._field(opts.location)
        author_entry = studio_shell._field(opts.author)
        name_entry.set_tooltip_text("What the project is called. The DIRECTORY is a slug of this, so \"My Thing\" lands in my-thing.")
        loc_entry.set_tooltip_text("The directory the project directory is made inside. ~/ and relative paths work.")
        author_entry.set_tooltip_text("Who a licence names as the copyright holder. Taken from git's user.name when there is one.")
        grid.attach(studio_shell._left(gtk.label("Name")), 0, 0, 1, 1)
        grid.attach(name_entry, 1, 0, 1, 1)
        grid.attach(studio_shell._left(gtk.label("Location")), 0, 1, 1, 1)
        grid.attach(loc_entry, 1, 1, 1, 1)
        grid.attach(studio_shell._left(gtk.label("Author")), 0, 2, 1, 1)
        grid.attach(author_entry, 1, 2, 1, 1)
        ' The LICENCE is a drop-down and the rest are checkboxes because it is
        ' the one option with more than two answers. `Gtk.DropDown` over a
        ' `Gtk.StringList`, both reachable through `gi.new` and both driven by
        ' ordinary instance methods (`set_selected`) — `new_from_strings` is a
        ' class static the bridge cannot call, the same gap as everywhere else.
        model = gi.new("Gtk.StringList")
        for each id in license_ids
            model.append(id)
        end for
        lic = gi.new("Gtk.DropDown")
        lic.set_model(model)
        lic.set_selected(studio_shell._index_of(license_ids, opts.license))
        lic.hexpand = false
        lic.halign = gi.enum("Gtk.Align.START")
        lic.set_tooltip_text("Studio does not write a licence of its own: it copies the text from share/licenses/ and fills in the year and the author.")
        grid.attach(studio_shell._left(gtk.label("Licence")), 0, 3, 1, 1)
        grid.attach(lic, 1, 3, 1, 1)
        outer.append(grid)

        ' The four files, in the order a project usually acquires them. Only
        ' main.bas is on: a project with nothing in it scans to zero browser
        ' rows and there is nowhere to click, which is the one default that
        ' pays for itself. A ticked `.gstudio.json` would be Studio putting its
        ' own file in your directory because you did not look — which is the
        ' behaviour that file exists to avoid.
        main_chk = studio_shell._check("main.bas — a file you can run straight away", opts.main)
        readme_chk = studio_shell._check("README.md", opts.readme)
        proj_chk = studio_shell._check(".gstudio.json — a stable id, an ignore list, an interpreter pin", opts.projfile)
        git_chk = studio_shell._check("git repository — git init, and a .gitignore", opts.git)
        outer.append(main_chk)
        outer.append(readme_chk)
        outer.append(proj_chk)
        outer.append(git_chk)

        note = studio_shell._wrapped(gtk.label(""))
        note = studio_style.apply(note, "dim")
        outer.append(note)

        row = gtk.box("h", u)
        row.halign = gi.enum("Gtk.Align.END")
        cancel_btn = gtk.button("Cancel")
        create_btn = gtk.button("Create")
        create_btn.add_css_class(studio_style.css_class("suggested-action"))
        row.append(cancel_btn)
        row.append(create_btn)
        outer.append(row)

        win.set_child(outer)
        return { window: win, name: name_entry, location: loc_entry,
                 author: author_entry, license: lic, license_ids: license_ids,
                 main: main_chk, readme: readme_chk, projfile: proj_chk,
                 git: git_chk, note: note,
                 create_btn: create_btn, cancel_btn: cancel_btn }
    end function

    ' ---- the snippet window (STU-15) ----------------------------------------
    '
    ' A drop-down of the snippets this connection's engine has, the selected
    ' one's description, and one entry per field it DECLARES. The form is built
    ' from the template's own `fields`, so adding a builder is adding a
    ' template file and no code at all -- which is the whole reason `fields`
    ' carries `label`, `required` and `default`.
    '
    ' Pressing Insert writes the statement into the document. It does not run
    ' it, and this window has no way to: there is no session here and no
    ' connection. That is the point rather than a limitation.
    '
    ' A window Studio BUILDS, like New Project and for the same reason: every
    ' control is an ordinary widget whose value can be SET, so a display tier
    ' can fill the form and press the button for real. A GtkAlertDialog is an
    ' async surface no test can press.
    function snippet_window(gtkapp, rows, engine, conn_name)
        u = studio_style.unit()
        win = gtk.application_window(gtkapp)
        win.title = "gBASIC Studio — snippet"
        win.default_width = 560
        outer = gtk.box("v", u)
        outer.margin_start = u * 2
        outer.margin_end = u * 2
        outer.margin_top = u * 2
        outer.margin_bottom = u * 2

        head = studio_shell._left(gtk.label("Write a statement into this file"))
        head = studio_style.apply(head, "head")
        outer.append(head)

        ' WHICH database this is about, said out loud. The connection is named
        ' in a comment three lines up in the file and the engine is a field in
        ' `.gstudio.json`; a form offering `create login` without saying it
        ' means SQL Server on `erp` is a form you have to already know the
        ' answer to.
        where = studio_shell._left(gtk.label(conn_name + " — " + engine))
        where = studio_style.apply(where, "dim")
        outer.append(where)

        names = []
        for each r in rows
            names = append(names, r.name)
        end for
        model = gi.new("Gtk.StringList")
        for each n in names
            model.append(n)
        end for
        pick = gi.new("Gtk.DropDown")
        pick.set_model(model)
        if count(names) > 0 then
            pick.set_selected(0)
        end if
        pick.hexpand = false
        pick.halign = gi.enum("Gtk.Align.START")
        outer.append(pick)

        ' What the statement IS and what to watch out for -- the template's own
        ' description, which is also readable in the file it came from.
        desc = studio_shell._wrapped(gtk.label(""))
        desc = studio_style.apply(desc, "dim")
        outer.append(desc)

        ' EVERY field of EVERY snippet, built once and shown or hidden, exactly
        ' like the browser's context menu. Minting widgets inside a selection
        ' handler is the doubling `ui_gui_solo` exists to catch one level up,
        ' and a grid rebuilt under a live window is a parent destroyed out from
        ' under whatever had focus.
        grid = gi.new("Gtk.Grid")
        grid.set_column_spacing(u * 2)
        grid.set_row_spacing(u)
        entries = []
        row_at = 0
        ri = 0
        while ri < count(rows)
            r = rows[ri]
            for each f in r.fields
                lab = studio_shell._left(gtk.label(studio_templates.field_label(f)))
                ent = studio_shell._field(f.default)
                if f.secret then
                    ' NOT hidden. The value is about to be written into the
                    ' user's own document in plain text, because CREATE ROLE
                    ' takes it in the statement and there is nowhere else for
                    ' it to go -- and a masked entry would say the opposite of
                    ' what is true about where it is going.
                    ent.set_tooltip_text("This is written into your document in plain text — the statement carries it, so there is nowhere else for it to go.")
                end if
                grid.attach(lab, 0, row_at, 1, 1)
                grid.attach(ent, 1, row_at, 1, 1)
                entries = append(entries, { row: ri, name: f.name, label: lab, entry: ent })
                row_at = row_at + 1
            end for
            ri = ri + 1
        end while
        outer.append(grid)

        note = studio_shell._wrapped(gtk.label(""))
        note = studio_style.apply(note, "dim")
        outer.append(note)

        row = gtk.box("h", u)
        row.halign = gi.enum("Gtk.Align.END")
        cancel_btn = gtk.button("Cancel")
        ins_btn = gtk.button("Insert")
        ins_btn.add_css_class(studio_style.css_class("suggested-action"))
        row.append(cancel_btn)
        row.append(ins_btn)
        outer.append(row)

        win.set_child(outer)
        w = { window: win, pick: pick, rows: rows, entries: entries,
              desc: desc, note: note, insert_btn: ins_btn, cancel_btn: cancel_btn }
        return studio_shell.snippet_show(w)
    end function

    ' Show the selected snippet's fields and hide the rest. Called when the
    ' window is built and again whenever the drop-down changes -- one function,
    ' so "which fields belong to this snippet" has one answer.
    function snippet_show(w)
        sel = studio_shell.snippet_index(w)
        for each e in w.entries
            e.label.set_visible(e.row = sel)
            e.entry.set_visible(e.row = sel)
        end for
        if sel >= 0 then
            if sel < count(w.rows) then
                w.desc.label = w.rows[sel].description
            end if
        end if
        return w
    end function

    function snippet_index(w)
        if count(w.rows) = 0 then
            return 0 - 1
        end if
        sel = w.pick.get_selected()
        if sel < 0 then
            return 0 - 1
        end if
        if sel >= count(w.rows) then
            return 0 - 1
        end if
        return sel
    end function

    ' Read the window back as { id, values }. The whole of the widget-to-value
    ' read for this window, in one place, so the handler stays an adapter.
    function snippet_values(w)
        sel = studio_shell.snippet_index(w)
        if sel < 0 then
            return { id: "", values: {} }
        end if
        vals = {}
        for each e in w.entries
            if e.row = sel then
                vals[e.name] = e.entry.text
            end if
        end for
        return { id: w.rows[sel].id, values: vals }
    end function

    ' Read the window back as the options record studio_ui consumes. The whole
    ' of the widget-to-value read, in one place, so the handler that calls it is
    ' still an adapter.
    function new_project_options(w)
        ids = w.license_ids
        sel = w.license.get_selected()
        chosen = "none"
        if sel >= 0 then
            if sel < count(ids) then
                chosen = ids[sel]
            end if
        end if
        return {
            name: w.name.text,
            location: w.location.text,
            author: w.author.text,
            main: w.main.get_active(),
            readme: w.readme.get_active(),
            projfile: w.projfile.get_active(),
            git: w.git.get_active(),
            license: chosen
        }
    end function

    function _field(text)
        e = gi.new("Gtk.Entry")
        e.text = text
        e.hexpand = true
        return e
    end function

    ' `ticked`, not `on`: ON is a reserved word in gBASIC, and a parameter named
    ' one is a parse error in a file the window cannot load.
    function _check(label, ticked)
        c = gi.new("Gtk.CheckButton")
        c.label = label
        c.set_active(ticked)
        return c
    end function

    function _index_of(ids, want)
        i = 0
        while i < count(ids)
            if ids[i] = want then
                return i
            end if
            i = i + 1
        end while
        return 0
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
        n = count(studio_ui.tab_rows(app))
        line = base + " — " + n + " open"
        ' Work that is open and NOT on screen has to be counted somewhere, or
        ' the unsaved-changes warning on exit is about documents the user has
        ' no memory of leaving open.
        hidden = studio_ui.hidden_docs(app)
        if hidden > 0 then
            line = line + " (" + hidden + " in other projects)"
        end if
        return line
    end function

end library
