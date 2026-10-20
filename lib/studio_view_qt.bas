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
load studio_shell_qt

library studio_view_qt

' ---------------------------------------------------------------------------
' The full redraw.
' ---------------------------------------------------------------------------

' Write everything the model says into the window. `notice` replaces the status
' line for one redraw, which is how an action reports what it did (or refused
' to do) -- the same signature `studio_shell.refresh` has, so a caller moving
' between the two shells changes nothing but the name.
function render(win, app, notice)
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
    z = qt.set(win, "git_body", "plainText", studio_ui.git_label(app))

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

    b = studio_view_qt._lines(win, "branch_body", studio_ui.branch_rows(app),
                              "(no branches)")
    app = b
    t = studio_view_qt._lines(win, "tables_body", studio_ui.table_rows(app),
                              "(nothing tabular in the latest run)")
    app = t
    return app
end function

' A pane whose model is a LIST OF ROWS, rendered as text.
'
' STATED AS A LIMIT RATHER THAN LEFT TO BE FOUND: under GTK these are listboxes
' whose rows are CLICKABLE -- a branch is selected by clicking one, a table is
' opened by clicking one -- and a memo of joined lines is not. Making them
' tables (the one clickable list this vocabulary has) is the next increment;
' the text is what keeps the pane honest in the meantime rather than empty.
function _lines(win, part, model, empty)
    out = []
    for each r in model.rows
        out = append(out, r.label)
    end for
    text = empty
    if count(out) > 0 then
        text = join(out, chr(10))
    end if
    z = qt.set(win, part, "plainText", text)
    return model.app
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
    items = studio_view_qt._tab_items(studio_shell_qt.window_for(app))
    z = qt.refresh(win, studio_shell_qt.part_tabs(), items)
    for each r in studio_ui.tab_rows(app)
        doc = studio_docs.doc_by_id(app.dm, r.doc_id)
        if doc != nothing then
            part = studio_shell_qt.part_editor(r.doc_id)
            have = qt.read(win, part, "plainText")
            if have != doc.content then
                z = qt.write(win, part, doc.content)
            end if
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
