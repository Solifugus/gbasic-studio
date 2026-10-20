' SPDX-License-Identifier: Apache-2.0
' Copyright 2026 Matthew C. Tedder. See LICENSE.

' studio_qt.bas — the Qt entry point (STU-22).
'
' A SECOND ENTRY DURING THE MIGRATION, deliberately, rather than a mode inside
' `app/studio.bas`. Three reasons, in the order they decided it:
'
'   1. `app/studio.bas` loads `gi`, `gtk`, `datagrid` and `sourceeditor` inside
'      its display block, and this process must load NONE of them. A Qt mode in
'      there would be one `load` away from pulling GTK into a window that has
'      no use for it -- and `gi.new("Gtk.<Widget>")` SEGFAULTS before GTK is
'      initialized rather than raising, which is not a failure anybody enjoys
'      diagnosing twice.
'   2. The rule that `app/studio.bas` is the only place with `gi.connect` stays
'      exactly true, because there is no `gi.connect` here at all. A Qt handler
'      is a FUNCTION REFERENCE in the record.
'   3. It is deletable. When the GTK shell goes, this file becomes
'      `app/studio.bas` and nothing else has to be untangled.
'
' WHAT HAS NOT CHANGED IS THE INTERACTION RULE. A handler here is still an
' ADAPTER: read one plain value off the window, call one `studio_ui` function,
' ask for a redraw. Every decision is in `studio_ui` over plain data, which is
' what the headless suite asserts and what made this port 1.3% of the source
' rather than a rewrite. A handler cannot close over state -- gBASIC functions
' do not -- so each reads the program global `G`, which is the same two-line
' wrapper shape the GTK handlers and the agent tool adapters already use.
'
' `qt.run()` IS CALLED FROM THE TOP LEVEL OF `program`, and that is load-bearing
' rather than tidy: from inside a function every loop-delivered source is
' silently starved -- a timer tick is appended to `timer.ticks` and never
' delivered, the schedule advances so it looks like it is working, and the
' program HANGS with no output. gBASIC's own open-ledger item, with a probe.

program main(args)
    load persist
    load filetree
    load studio_model
    load studio_docs
    load studio
    load studio_ui
    load studio_sections
    load studio_projects
    load studio_projfile
    load studio_secrets
    load studio_templates
    load studio_results
    load studio_table
    load studio_session
    load studio_sql
    load studio_schema
    load studio_branches
    load studio_overlays
    load studio_drafts
    load studio_history
    load studio_style
    load studio_shell_qt
    load studio_view_qt

    mode = "gui"
    if count(args) > 0 then
        mode = args[0]
    end if
    home = ""
    if count(args) > 1 then
        home = args[1]
    end if
    if home = "" then
        home = studio_qt_default_home()
    end if

    app = studio.startup(home)

    ' An explicit project, the way `./studio gui <home> <dir>` takes one.
    if count(args) > 2 then
        if args[2] != "" then
            a = studio_ui.adopt_folder(app, args[2])
            app = a.app
        end if
    end if

    G = { app: app, win: nothing, running: false }

    win = studio_shell_qt.window_for(G.app)
    ' REFUSED BEFORE OPENED, always. `qt.open` validates too, but a validator
    ' nobody is obliged to call is necessary and not sufficient -- and a raise
    ' out of `qt.check` names the part and the path, where a half-built window
    ' names whatever Qt tripped over first.
    ok = qt.check(win)
    ' THE BROWSER'S SUBJECT HAS TO BE IN THIS FRAME BEFORE THE OPEN, not after
    ' it: `qt.open` binds a `table to show` by reading the named variable out of
    ' the frame that calls it, and refuses the whole window when it is not
    ' there. Found by running it -- the refusal says so in as many words, which
    ' is the difference between a minute and an afternoon.
    nav = studio_ui.nav_rows(G.app)
    z = qt.open(win)
    G.win = win

    ' THE FIRST PAINT AND EVERY LATER ONE ARE THE SAME CODE. The record carries
    ' shape and no state, so the window opens empty and one render fills it --
    ' a separate initial-population path is how a view starts disagreeing with
    ' its refresh.
    G.app = studio_view_qt.render(win, G.app, "")

    ' The layout the user last left. Each split is addressed by a part that is
    ' one of ITS OWN panes, because the walk stops at the nearest region.
    for each p in studio_shell_qt.pane_sizes(G.app)
        sized = qt.resize_panes(win, p.at, p.sizes)
    end for

    if mode = "probe" then
        ' A headless tier's mode: everything above has happened for real,
        ' offscreen, so print what the window is holding and stop. No loop,
        ' because a loop needs somebody to close the window and offscreen has
        ' no window manager.
        print "-- the Qt shell, opened and rendered --"
        print "  title:    " + qt.read(win, studio_shell_qt.window_name(), "windowTitle")
        print "  status:   " + qt.read(win, studio_shell_qt.part_status(), "text")
        print "  rows:     " + string(qt.read(win, studio_shell_qt.part_browser(), "rowCount"))
        print "  tabs:     " + string(qt.tabs(win, studio_shell_qt.part_tabs()))
        print "  section:  " + qt.read(win, "run_section", "text")
        print "  state:    [" + qt.read(win, "run_state", "text") + "]"
        print "  standing: [" + qt.read(win, "run_standing", "text") + "]"
        print "  run all:  " + string(qt.read(win, "run_all_btn", "visible"))
        print "  snippets: " + string(qt.read(win, "snippet_btn", "visible"))
        print "  prefix:   [" + qt.read(win, "prefix_body", "plainText") + "]"
        print "  target:   [" + qt.read(win, "target_body", "plainText") + "]"
        print "  errors:   " + qt.read(win, "err_head", "text") + " [" + qt.read(win, "err_body", "plainText") + "]"
        print "  results:  [" + studio_qt_first_line(qt.read(win, "results_body", "plainText")) + "]"
        print "  branches: [" + studio_qt_first_line(qt.read(win, "branch_body", "plainText")) + "]"
        print "  tables:   [" + studio_qt_first_line(qt.read(win, "tables_body", "plainText")) + "]"
        print "  git:      [" + qt.read(win, "git_body", "plainText") + "]"
        print "  dark is checked: " + string(qt.read(win, studio_shell_qt.part_item("theme-dark"), "checked"))

        ' AND THEN A DOCUMENT OPENS, through the same `studio_ui.activate_row`
        ' a browser click calls -- so this half asserts the row model reaching
        ' the window as well as the render. One tier rather than two, because
        ' the cold state and the one-document state are the same code path with
        ' different data, and a tier that only ever sees an empty window is the
        ' STU-2B dead end wearing a golden.
        print "-- a browser row activated, exactly as a click would --"
        rows = studio_ui.nav_rows(G.app)
        at = studio_qt_row_index(rows, "file", "main.bas")
        r = studio_ui.activate_row(G.app, rows, at)
        G.app = r.app
        print "  action:   " + r.action
        nav = studio_ui.nav_rows(G.app)
        G.app = studio_view_qt.render(win, G.app, "")
        print "  title:    " + qt.read(win, studio_shell_qt.window_name(), "windowTitle")
        print "  status:   " + qt.read(win, studio_shell_qt.part_status(), "text")
        print "  tabs:     " + string(qt.tabs(win, studio_shell_qt.part_tabs()))
        print "  on top:   " + string(qt.read(win, studio_shell_qt.part_tabs(), "currentIndex"))
        print "  section:  " + qt.read(win, "run_section", "text")
        doc = studio_docs.active_doc(G.app.dm)
        ed = studio_shell_qt.part_editor(doc.id)
        print "  " + ed + ": [" + replace(qt.read(win, ed, "plainText"), chr(10), " / ") + "]"
        print "  highlighted as: " + qt.highlighting(win, ed).language

        ' AND EDITED IN THE MODEL, which is where the marker comes from. The
        ' caption moves and the editor is NOT rebuilt -- the one claim the
        ' reconcile exists to support, asserted here against the real shell
        ' rather than against a fixture.
        print "-- edited in the model --"
        G.app.dm = studio_docs.edit(G.app.dm, doc.id, "print \"typed\"" + chr(10))
        nav = studio_ui.nav_rows(G.app)
        G.app = studio_view_qt.render(win, G.app, "saved nothing; this is a probe")
        print "  tabs:     " + string(qt.tabs(win, studio_shell_qt.part_tabs()))
        print "  title:    " + qt.read(win, studio_shell_qt.window_name(), "windowTitle")
        print "  status:   " + qt.read(win, studio_shell_qt.part_status(), "text")
        print "  " + ed + ": [" + replace(qt.read(win, ed, "plainText"), chr(10), " / ") + "]"

        z = qt.close(win)
        return nothing
    end if

    ' THE RUN POLLER. gBASIC's own timer, which fires while `qt.run()` holds
    ' the thread -- measured, eight ticks of a 50ms timer delivered inside the
    ' loop, each one writing into the window. The GTK shell uses `gi.timeout`
    ' at the same rate and for the same reason, and only the FINAL tick of a
    ' run does a full redraw: a full redraw rebuilds the browser, and doing
    ' that sixteen times a second would fight the user for their own file tree.
    beat = timer.every(0.0625)
    watch(timer.ticks)
        while count(timer.ticks) > 0
            ev = take_first(timer.ticks)
            ' A WINDOW CAN CLOSE WITHOUT THE PROGRAM ASKING, so every verb
            ' starts refusing for a reason that is nobody's mistake. `is_open`
            ' is the question that answers where the others raise.
            if qt.is_open(G.win) then
                if studio_ui.is_running(G.app) then
                    t = studio_ui.tick_run(G.app)
                    G.app = t.app
                    if t.active then
                        G.app = studio_view_qt.render_run(G.win, G.app)
                    else
                        nav = studio_ui.nav_rows(G.app)
                        G.app = studio_view_qt.render(G.win, G.app, "")
                    end if
                end if
            end if
        end while
    end watch

    rc = qt.run()
    ' The session is written on the way out, exactly as the GTK path writes it
    ' from `close-request`. Here the window has already gone, so the geometry
    ' had to be read before it did -- which is what `on <win>.closed` is for.
    saved = studio.shutdown(G.app)
    print "saved: " + join(saved, ", ")
    return nothing
end program

' ---------------------------------------------------------------------------
' Helpers. Top level and before `program`, because a function defined inside a
' program block AFTER the call to it is not hoisted.
' ---------------------------------------------------------------------------

function studio_qt_default_home()
    h = env("HOME")
    if is_string(h) then
        return h + "/.gbasic-studio"
    end if
    return ".gbasic-studio"
end function

' Where a row of a given kind and name sits in the browser's row array.
'
' The array is the one `nav_rows` produced and nothing re-derives it, which is
' the invariant CLAUDE.md states: the renderer and the click dispatcher consume
' THE SAME array, because deriving rows twice desynchronises the moment the
' filesystem changes between a render and a click.
function studio_qt_row_index(rows, kind, name)
    i = 0
    for each r in rows
        if r.kind = kind then
            if r.name = name then
                return i
            end if
        end if
        i = i + 1
    end for
    return 0 - 1
end function

' The first line of a pane's text, for a golden that must not hold a path or a
' timestamp the body happens to carry further down.
function studio_qt_first_line(text)
    parts = split(text, chr(10))
    if count(parts) = 0 then
        return ""
    end if
    return parts[0]
end function
