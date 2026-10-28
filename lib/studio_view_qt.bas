' SPDX-License-Identifier: Apache-2.0
' Copyright 2026 Matthew C. Tedder. See LICENSE.

' studio_view_qt.bas — writing the model into an open Qt window.
'
' THE SPLIT FROM `studio_shell_qt` IS THE POINT, and it is enforced rather than
' intended. That library answers WHAT THE WINDOW IS, as a record, and makes no
' toolkit call at all -- which is what lets `qtshell_shape` assert the layout
' with no display and `qt_shell_pure` keep it that way. This library answers
' WHAT IS IN IT RIGHT NOW, and every line of it is a `qt.` call. Two files
' because the first has to stay reachable from a machine with no Qt.
'
' It is the Qt counterpart of `studio_shell.refresh` / `refresh_run`, and it
' holds NO DECISIONS -- every value written here comes from a `studio_ui`
' function that the headless suite already asserts. That is the interaction
' rule read from the other end: if a sentence is composed in here, it is a
' sentence no golden can see.
'
' TWO ENTRY POINTS, for the reason the GTK shell has two:
'
'   `render(win, app)`     the FULL redraw -- the browser, the tabs, git, the
'                          menu marks, the status line. Rebuilds things.
'   `render_run(win, app)` what the run poller calls, SIXTEEN TIMES A SECOND:
'                          the run strip, the output panes, the results. It
'                          must not touch the browser (that would fight the
'                          user for their own file tree) and must not touch
'                          git (detection FORKS).
'
' Both RETURN THE APP, and a caller that drops it re-parses the document on
' every render: `studio_ui.view_for` caches the section outline on `app.view`,
' and this runs at cursor-move rate. CLAUDE.md records what dropping it costs
' beyond the re-parse -- the next failed parse has no cached state to retain
' sections from, so a typed-in syntax error reaches `no-parse` instead of
' `refused`.

load studio_ui
load studio_docs
load studio_style
load studio_shell_qt
load studio_teaching

library studio_view_qt

' ---------------------------------------------------------------------------
' The window's LOOK, set once.
' ---------------------------------------------------------------------------

' Chrome that never changes, applied after the window opens.
'
' WHY IT IS NOT IN THE RECORD: a container carries a NAME OR OPTIONS AND NEVER
' BOTH (gBASIC §0.8 -- `tabs settings( movable: true )` costs four reduce/reduce
' conflicts), and the browser spends its one slot on being named `files` with a
' subject. So its ten chrome properties go through the by-name route instead,
' which is what upstream means by "the look was always one `qt.set` away".
'
' ONCE, not per render: none of it changes while Studio runs, and a property
' write that cannot change anything is work at redraw rate for nothing.
function dress(win, app)
    files = studio_shell_qt.part_browser()
    ' A file tree has no header row. `headerHidden` IS a Q_PROPERTY where
    ' `headerVisible` is not -- which corrected Studio's own ask in the helpful
    ' direction, and is why the heading is declared at all: a column still
    ' needs a caption for `qt.heading` to be an oracle over the mapping.
    z = qt.set(win, files, "headerHidden", true)
    ' NO ARROWS, because Studio owns expansion. See `studio_shell_qt._browser`:
    ' the rows handed over ARE the visible set, so a widget that could collapse
    ' one by itself would desynchronise the index the click dispatcher uses.
    z = qt.set(win, files, "itemsExpandable", false)
    z = qt.set(win, files, "rootIsDecorated", false)
    ' AND NO BRANCH LINES. Qt draws its own connector before a child row, which
    ' sat beside Studio's own glyphs and indentation as a second, half-drawn
    ' answer to "where is this" -- seen in a capture of the real window, a lone
    ' line before `sales.bas` and none before the project above it. The rule
    ' names only the branch sub-control, so it changes nothing else.
    z = qt.set(win, files, "styleSheet", "QTreeView::branch { image: none; border-image: none; background: transparent; }")
    ' The same eight pixels per level the GTK browser uses, and for the same
    ' measured reason: twelve was visibly wider than the two-spaces-in-a-
    ' proportional-font it replaced, wide enough that two names started
    ' ellipsizing which had fitted before. Qt's default is 20.
    z = qt.set(win, files, "indentation", studio_style.indent())
    ' NOT `uniformRowHeights`, though every row is one line of text: with it set,
    ' NO ROW WAS DRAWN on a real display. Measured under X11, one property at a
    ' time: the same tree draws every row without it and none with it --
    ' presumably the row height is measured from the undrawn depth column, and
    ' comes out zero. The offscreen tiers never saw it, because they read a
    ' row's TEXT back, never its size. It is a speed hint and the browser does
    ' not need one.
    ' NOT striped. A file tree with alternating bands reads as a report; the
    ' property is there and this is a choice rather than an omission.
    z = qt.set(win, files, "alternatingRowColors", false)
    ' A browser row is not sortable: the order is the filesystem's, with
    ' directories first, and sorting the view while `nav_rows` keeps its own
    ' order would make one index mean two different rows.
    z = qt.set(win, files, "sortingEnabled", false)
    return nothing
end function

' ---------------------------------------------------------------------------
' The full redraw.
' ---------------------------------------------------------------------------

' Write everything the model says into the window. `notice` replaces the status
' line for one redraw, which is how an action reports what it did (or refused
' to do) -- the same signature `studio_shell.refresh` has, so a caller moving
' between the two shells changes nothing but the name.
function render(win, app, notice)
    ' THE TOOLBAR'S BUTTON STYLE, on the full redraw rather than in `dress`,
    ' because it is the one piece of chrome that FOLLOWS THE THEME: text while
    ' dark, icons otherwise. `studio_style.qt_tool_button_style` is the
    ' decision and this is one `qt.set` -- see that function for why an icon
    ' cannot be made legible on a dark strip without a palette.
    ' THE BROWSER. `qt.refresh` re-reads the subject from THIS frame by the
    ' name the record declares, so the variable has to be called exactly that
    ' -- `studio_shell_qt.nav_subject()` is the one place that name is written,
    ' and gBASIC refuses a subject it cannot find, which makes a drift loud.
    '
    ' A table is the only widget in this vocabulary whose row COUNT can change
    ' without rebuilding the window, which is why the browser is one.
    nav = studio_ui.nav_rows(app)
    z = qt.refresh(win, studio_shell_qt.part_browser())

    ' THE TABS. A reconcile, not a rebuild: a page whose name is unchanged
    ' keeps its editor, with its text, its caret and its undo stack. Studio's
    ' captions carry the unsaved marker and so are exactly what moves, which is
    ' why a page is named after its DOCUMENT and not after what it says.
    app = studio_view_qt._tabs(win, app)

    app = studio_view_qt.render_run(win, app)

    ' GIT IS IN THE FULL REDRAW AND NEVER IN `render_run`. Reading status
    ' spawns a process, and the poller runs sixteen times a second -- forking
    ' `git status` at that rate is a worse version of the mistake the two-entry
    ' split exists to avoid.
    '
    ' QUIET OUTSIDE A REPOSITORY (§18): the pane is HIDDEN there, so someone
    ' who does not use git never sees it mentioned -- and inside one it holds
    ' the summary (branch, each change), which is what the GTK pane showed. The
    ' first Qt version wrote the one-line `git_label` into a pane that was
    ' always visible; found after the GTK window was gone, because the wiring
    ' diff that guarded the switch compares SIGNALS, and this is what a redraw
    ' writes.
    e = studio_ui.git_engaged(app)
    app = e.app
    z = qt.set(win, studio_shell_qt.part_side_dock("git"), "visible", e.engaged)
    if e.engaged then
        g = studio_ui.git_lines(app)
        app = g.app
        z = qt.set(win, "git_body", "plainText", join(g.lines, chr(10)))
    end if

    ' THE ASSISTANT'S ANSWER, which lives on the app between redraws, or the
    ' sentence saying what the button does when there is none yet.
    answer = app["agent_answer"]
    if is_unknown(answer) then
        answer = "Press Where was I? — the answer appears here. It needs a provider key: Studio looks in its secret store first, then the environment, and says which it used."
    end if
    z = qt.write(win, "agent_body", answer)

    ' A TEACHING CUE the agent left, drawn and consumed.
    app = studio_view_qt._cue(win, app)

    ' OVERLAY CONFLICTS ARE SURFACED on every full redraw and never acted on
    ' (design §9.3): a conflict that only appeared when you pressed Promote
    ' would be one you found by trying to lose work. Written only when there IS
    ' one, so a Compare's output stays until something conflicts.
    c = studio_ui.overlay_conflicts(app)
    app = c.app
    if count(c.problems) > 0 then
        lines = []
        for each pr in c.problems
            lines = append(lines, pr.name + " / " + pr.section_id + ": " + pr.detail)
        end for
        z = qt.write(win, "ov_diff", join(lines, chr(10)))
    end if

    ' THE MENU MARKS, which are the toolkit's own now. Under GTK a popover of
    ' plain buttons cannot draw a radio mark, so the glyph went in the label;
    ' a QAction is checkable and this is one `qt.set` per state item. Not in
    ' `render_run` -- none of it changes while a program runs.
    for each action in studio_ui.menu_all()
        state = studio_ui.menu_checkable(action)
        if state then
            z = qt.set(win, studio_shell_qt.part_item(action), "checked",
                       studio_ui.menu_checked(app, action))
        end if
    end for

    ' The title, which carries the unsaved marker as well as the tab does --
    ' conventional, and it costs one property write.
    z = qt.set(win, studio_shell_qt.window_name(), "windowTitle",
               studio_shell_qt.title_for(app))

    line = studio_ui.status_text(app)
    if notice != "" then
        line = notice
    end if
    z = qt.set(win, studio_shell_qt.part_status(), "text", line)
    return app
end function

' ---------------------------------------------------------------------------
' The poll redraw.
' ---------------------------------------------------------------------------

function render_run(win, app)
    v = studio_ui.view_for(app)
    app = v.app
    sess = studio_ui.exec_session(app)

    z = qt.set(win, "run_state", "text", studio_ui.run_line(sess))
    z = qt.set(win, "run_section", "text", studio_ui.section_label(app))
    z = qt.set(win, "run_standing", "text", studio_ui.standing_line(app))
    z = qt.set(win, "run_branch", "text", studio_ui.branch_label(app))

    ' HIDDEN RATHER THAN ABSENT, the rule the GTK strip already follows: Run
    ' All is meaningless outside a `.sql` document, and a control that is added
    ' and removed is one whose parent can be destroyed under a live window.
    z = qt.set(win, "run_all_btn", "visible", studio_ui.shows_run_all(app))
    z = qt.set(win, "snippet_btn", "visible", studio_ui.shows_snippets(app))
    z = qt.set(win, "schema_btn", "visible", studio_ui.shows_schema(app))

    z = qt.set(win, "prefix_body", "plainText", studio_ui.prefix_body(app))
    z = qt.set(win, "target_body", "plainText", studio_ui.target_body(app))

    errs = studio_ui.error_body(app)
    z = qt.set(win, "err_body", "plainText", errs)
    ' SAID TWICE ON PURPOSE: in the heading, where the eye lands, and in the
    ' body, where the text is. This pane is the last of three in the console
    ' scroller, so on a short window it is the one below the fold -- and a
    ' heading reading "Errors" over a pane you cannot see is indistinguishable
    ' from one reading "Errors" over "(none)".
    z = qt.set(win, "err_head", "text", studio_ui.error_heading(errs))

    z = qt.set(win, "results_body", "plainText", studio_ui.results_body(app))

    app = studio_view_qt._gutter(win, app)

    ' THE BRANCH PANE IS A TABLE, so it follows its subject the way the browser
    ' does -- read out of THIS frame by the name the record declares.
    br = studio_ui.branch_rows(app)
    app = br.app
    branches = []
    for each r in br.rows
        branches = append(branches, { line: studio_ui.branch_line(r) })
    end for
    z = qt.refresh(win, studio_shell_qt.part_branches())

    ' THE TABLES PANE IS A TABLE TOO, for the same reason: a row is clicked to
    ' open the grid. The click dispatcher re-derives `table_rows` and indexes it
    ' the way this list was built, and the "(nothing tabular...)" row sits past
    ' the end of that array, so a click on it answers `no-table` by itself.
    tr = studio_ui.table_rows(app)
    app = tr.app
    tables = studio_shell_qt.table_subject(tr.rows)
    z = qt.refresh(win, studio_shell_qt.part_tables())
    return app
end function


' THE GUTTER: a mark per line in the active editor's margin.
'
' Two categories, which are Studio's own and which gBASIC named after them:
' `section` at every runnable section's start -- the whole notebook affordance,
' since a cell boundary is otherwise invisible -- and `error` at the parse
' diagnostic's line, which is the only thing in the window that says WHERE a
' syntax error is.
'
' NO CACHE, AND THAT IS THE API SHAPE PAYING OFF. The GTK shell caches what it
' has drawn on `shell.marked` and `shell.errmarked`, gated on the outline's
' revision and on the error lines' signature, because GTK's marks are
' add/remove per line and redrawing them means widget churn at caret-move rate.
' `qt.mark` REPLACES a whole category -- which is what Studio asked for, because
' it recomputes the whole list on every redraw and a cache is a thing to get
' wrong -- so writing it unconditionally is idempotent and cheap, and there are
' two fewer caches here than there.
'
' LINES ARE 1-BASED HERE AND 0-BASED THERE. `studio_ui.section_marks` subtracts
' one because a `Gtk.TextBuffer` counts from zero; `qt.mark` refuses a 0 by
' name, line numbers starting at 1. So the +1 goes at this ONE call site rather
' than `studio_ui` growing a second answer -- the parser's own numbering is
' 1-based and this is putting it back.
function _gutter(win, app)
    doc = studio_docs.active_doc(app.dm)
    if doc = nothing then
        return app
    end if
    part = studio_shell_qt.part_editor(doc.id)
    m = studio_ui.section_marks(app)
    app = m.app
    z = qt.mark(win, part, "section", studio_view_qt._one_based(m.lines))
    e = studio_ui.error_marks(app)
    app = e.app
    z = qt.mark(win, part, "error", studio_view_qt._one_based(e.lines))
    return app
end function

function _one_based(lines)
    out = []
    for each n in lines
        out = append(out, n + 1)
    end for
    return out
end function

' ---------------------------------------------------------------------------
' The notebook.
' ---------------------------------------------------------------------------

' Reconcile the tab set, then put each document's text in its editor.
'
' THE TEXT IS WRITTEN ONLY WHERE IT DIFFERS. A `qt.write` that set the same
' string again would still reset the caret and clear the undo stack, which is
' the whole thing the reconcile exists to protect -- so this reads first. That
' is also why a new page's editor is filled here rather than at build time: the
' record carries no text, because text is state and the record is shape.
function _tabs(win, app)
    items = studio_view_qt.editor_handlers(app, studio_view_qt._tab_items(studio_shell_qt.window_for(app)))
    z = qt.refresh(win, studio_shell_qt.part_tabs(), items)
    for each r in studio_ui.tab_rows(app)
        doc = studio_docs.doc_by_id(app.dm, r.doc_id)
        if doc != nothing then
            part = studio_shell_qt.part_editor(r.doc_id)
            have = qt.read(win, part, "plainText")
            if have != doc.content then
                z = qt.write(win, part, doc.content)
            end if
            app = studio_view_qt._zoom(win, app, part)
        end if
    end for
    ' Which page is on top. A document is made active in the MODEL and the
    ' window follows, never the other way round.
    at = studio_view_qt._page_of(app)
    if at >= 0 then
        z = qt.set(win, studio_shell_qt.part_tabs(), "currentIndex", at)
    end if
    return app
end function

' The index of the active document among the VISIBLE ones, or -1.
'
' Among the visible ones, because `tab_rows` filters by project -- the notebook
' follows the browser, and a document hidden behind another project is absent
' from both. -1 when the active document is not on screen, which is a state
' `focus_visible_doc` is supposed to prevent and which must not become a wrong
' index if it ever happens.
' THE TEXT SIZE, which nothing on the Qt path applied: the menu items and
' their Ctrl++ / Ctrl+- shortcuts moved the SETTING and the status line said
' "text size 115%" about an editor that never changed -- the dead control the
' theme was before it, found the same way, by the user.
'
' THE BASE IS THE FIRST EDITOR'S OWN FONT, kept on the app like `gitstate`.
' A freshly built editor is always at the desktop's size, and nothing is
' zoomed before the base is taken, so the first one seen is the base -- and
' every editor built later (a new tab, or a theme change rebuilding them all)
' comes back at that size and is set again here. Written only where the size
' DIFFERS, the rule the text above follows: the reconcile keeps editors, and a
' font set per redraw would be work at redraw rate for nothing.
function _zoom(win, app, part)
    font = qt.read(win, part, "font")
    base = app["qt_font_base"]
    if is_unknown(base) then
        base = font
        app["qt_font_base"] = base
    end if
    want = studio_style.qt_zoomed_size(base, studio_ui.editor_zoom(app))
    if number(split(font, ",")[1]) != want then
        z = qt.set(win, part, "font", studio_style.qt_font_sized(base, want))
    end if
    return app
end function

function _page_of(app)
    i = 0
    for each r in studio_ui.tab_rows(app)
        if r.doc_id = app.dm.active then
            return i
        end if
        i = i + 1
    end for
    return 0 - 1
end function

' The `tabs` container's items, out of a freshly built record -- which is
' exactly what `qt.refresh(win, name, items)` takes. A redraw is therefore
' "build the record again and hand over the part that changed", with no second
' description of what a tab is.
' EACH EDITOR'S OWN HANDLERS, put inside its page.
'
' gBASIC connects a handler exactly when the widget it TARGETS is built --
' at `qt.open` or by the `qt.refresh` that builds it (fixed upstream at
' 3d3f7d9; before that a refreshed child's handlers were never connected, which
' is why Ctrl+wheel waited). So every page carries its editor's handlers from
' the start, and an editor KEPT by a reconcile is untouched and connected once.
'
' THE HANDLERS ARE DATA ON THE APP (`qt_editor_handlers`, a list of
' `{ signal, handler }`), set by the entry point. This file makes no decision
' about them and the shell never sees them, which is what keeps
' `studio_shell_qt` callable with no Qt -- the arrangement `qt_wire` has.
' Pages pair with `tab_rows` by position, which is how `_editors` built them;
' the welcome page has no row and no editor, and is passed through.
function editor_handlers(app, pages)
    hs = app["qt_editor_handlers"]
    if is_unknown(hs) then
        return pages
    end if
    rows = studio_ui.tab_rows(app)
    if count(rows) != count(pages) then
        return pages
    end if
    out = []
    i = 0
    for each pg in pages
        ed = studio_shell_qt.part_editor(rows[i].doc_id)
        its = pg.items
        for each h in hs
            its = append(its, { kind: "handler", target: ed,
                                signal: h.signal, handler: h.handler })
        end for
        pg.items = its
        out = append(out, pg)
        i = i + 1
    end for
    return out
end function

' The same, over a whole window record, for `qt.open` -- the editors open at
' launch are built there and not by a refresh.
function with_editor_handlers(app, node)
    if has(node, "word") then
        if node.word = "tabs" then
            node.items = studio_view_qt.editor_handlers(app, node.items)
            return node
        end if
    end if
    if has(node, "items") then
        out = []
        for each c in node.items
            out = append(out, studio_view_qt.with_editor_handlers(app, c))
        end for
        node.items = out
    end if
    return node
end function

' DRAW A TEACHING CUE (STU-10) and CONSUME it: a cue left on the app would be
' re-drawn by every later redraw, so the window would go on pointing at
' something the agent said once. The previous cue is taken off first -- two
' highlights at once would leave the first on a widget nothing will clear.
'
' A highlight or pulse is a style sheet on the part, scoped by an object name
' set here for the purpose (`studio_teaching.qss`); a PULSE also leaves its
' deadline on the app, and the entry point's poller takes it off when that
' passes, since a renderer runs only when something changes. `reveal` raises
' the dock the part is in; `focus` moves the keyboard; `annotate` puts `note`
' marks in the editor's margin over the line range.
function _cue(win, app)
    c = app["teach"]
    if is_unknown(c) then
        return app
    end if
    if c = nothing then
        return app
    end if
    app["teach"] = nothing
    if not c.ok then
        return app
    end if
    app = studio_view_qt.clear_cue(win, app)
    t = studio_shell_qt.teach_target(app, c.widget)
    if t.part = "" then
        return app
    end if
    if t.dock != "" then
        z = qt.invoke(win, t.dock, "raise")
    end if
    if c.gesture = "annotate" then
        r = studio_teaching.range_of(c.detail)
        if r.ok then
            lines = []
            n = r.first
            while n <= r.last
                lines = append(lines, n)
                n = n + 1
            end while
            z = qt.mark(win, t.part, "note", lines)
            app["qt_teach_notes"] = t.part
        end if
        return app
    end if
    if c.gesture = "focus" then
        z = qt.invoke(win, t.part, "setFocus")
        return app
    end if
    if c.gesture = "reveal" then
        if t.dock = "" then
            z = qt.invoke(win, t.part, "setFocus")
        end if
        return app
    end if
    sheet = studio_teaching.qss(c.gesture, t.part)
    if sheet = "" then
        return app
    end if
    z = qt.set(win, t.part, "objectName", t.part)
    z = qt.set(win, t.part, "styleSheet", sheet)
    app["qt_teach_on"] = t.part
    if c.gesture = "pulse" then
        app["qt_pulse_until"] = monotonic() + studio_teaching.pulse_ms() / 1000
    end if
    return app
end function

' Take the last cue off: its style sheet, its pulse deadline, and any margin
' notes an annotation left.
function clear_cue(win, app)
    ' `lit`, not `on`: ON is a reserved word.
    lit = app["qt_teach_on"]
    if not is_unknown(lit) then
        if lit != nothing then
            z = qt.set(win, lit, "styleSheet", "")
        end if
    end if
    app["qt_teach_on"] = nothing
    app["qt_pulse_until"] = nothing
    notes = app["qt_teach_notes"]
    if not is_unknown(notes) then
        if notes != nothing then
            z = qt.mark(win, notes, "note", [])
        end if
    end if
    app["qt_teach_notes"] = nothing
    return app
end function

function _tab_items(node)
    if has(node, "word") then
        if node.word = "tabs" then
            return node.items
        end if
    end if
    if has(node, "items") then
        for each c in node.items
            found = studio_view_qt._tab_items(c)
            if count(found) > 0 then
                return found
            end if
        end for
    end if
    return []
end function

end library
