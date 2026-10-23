' SPDX-License-Identifier: Apache-2.0
' Copyright 2026 Matthew C. Tedder. See LICENSE.

' studio_shell_qt.bas — Studio's window, as DATA.
'
' This is the Qt replacement for `studio_shell.build`, and the one structural
' difference is the whole reason it is a separate library: gBASIC's Qt surface
' IS a record (gbasic docs/qt_gui_design.md §0.9), so the window does not have
' to be CONSTRUCTED to be described. `window_for(app)` is an ordinary pure
' function from Studio's model to a record, and `qt.check` validates that
' record with NO Qt and NO display -- which puts the whole of the window's
' shape inside the headless suite for the first time.
'
' Under GTK that was impossible. `studio_shell.build` makes 100-odd widgets as
' it decides what the window is, so the only way to assert the layout was to
' open a window, and the `ui_gui*` tiers therefore SKIP on a machine with no
' display. Those tiers asserted text. Nothing asserted structure, which is
' exactly the class of defect CLAUDE.md's own browser and run-strip sections
' are a list of.
'
' NOTHING IN HERE TOUCHES A TOOLKIT. No `qt.`, no `gi.`, no `gtk.`. That is
' checked by a tripwire (`qt_shell_pure`) rather than left as an intention,
' because a single `qt.read` in here would take the headless tier down with it
' on a machine without Qt -- and the tier is the whole point.
'
' --- WHAT A RECORD CANNOT DO, MEASURED -------------------------------------
'
' A window's SET of parts is fixed when `qt.open` reads the record. Measured on
' Qt 6.10.2 through this backend:
'
'   * `qt.read(win, "book", "count")` answers 2 for a two-tab `tabs` -- so the
'     set is observable;
'   * `qt.refresh` is `table`s and form subjects only. Asked of a `tabs` it
'     refuses by name: "declares no table named `book`";
'   * `qt.invoke` passes NO ARGUMENTS (src/modules/qt.c, `argc != 3`), so
'     `removeTab(int)` and `setTabText(int, QString)` -- the two Qt calls that
'     would change a tab set or a caption in place -- are out of reach by
'     construction, not by omission.
'
' So a document opening or closing is a NEW WINDOW, and that is why
' `window_for` is a function of the model rather than a one-time builder: it is
' called once per GENERATION. Measured end to end: close the window, build a
' record with one more tab, open it, write the buffers back, restore
' `currentIndex`, the window geometry and the pane sizes -- all four carried,
' and `qt.run()` entered and returned twice in one process (§0.17 records that
' closing the last window returns from the loop, and that reopening is bounded
' at a 1.01 memory ratio over 2000 cycles).
'
' AND THEN gBASIC BUILT THE VERB (§0.27, 2026-10-19), so the paragraph that
' used to be here is history worth keeping: the tab set is NOT frozen any more.
'
' `qt.refresh(win, name, items)` reconciles a named container's children by
' NAME AND WORD -- a child whose name is unchanged is KEPT with its widget, its
' text, its caret and its undo stack; a new one is built through the same door
' `qt.open` uses; an absent one is deleted and its name purged. So opening a
' document is `qt.refresh(win, part_tabs(), <the new items>)` and nothing is
' rebuilt but the tab that arrived.
'
' TWO THINGS FOLLOW, and both were measured rather than read:
'
'   * A TAB MUST CARRY A NAME. §0.8's one-slot rule means a DECLARED `tab`
'     spends its slot on the caption, but that is a fact about the grammar and
'     not about the record -- gBASIC added `name` on a built `tab` for exactly
'     this consumer. Without one the reconcile falls back to the caption, and
'     measured, the editor came back EMPTY: Studio's captions are the thing that
'     moves, so a tab keyed on its caption is rebuilt the moment the marker
'     appears. Keyed on the document id it is kept.
'   * SO THE MARKER STAYS IN THE CAPTION, where the GTK notebook has always put
'     it. A reconcile re-reads a tab's caption because it is data in the record,
'     so `studio_ui.tab_label` is reached here exactly as it is there and
'     nothing about what a marker MEANS moved toolkits.
'
' The window title carries it too, which is conventional and costs nothing.
'
' --- NAMES ------------------------------------------------------------------
'
' Every part a renderer, a handler or a test addresses is named here and
' NOWHERE ELSE, through the `part_*` functions below. A name written out at a
' call site is a name that can drift from the record, which is the
' `projects[].documents` mistake in a new costume -- and under Qt it fails
' loudly rather than silently (`qt.read` refuses an unknown part by name), so
' the cost is a broken renderer rather than a wrong answer. Document editors
' are keyed off the DOCUMENT ID, so a renderer holding a doc id can find its
' editor without a second lookup table.

load studio_ui
load studio_docs
load studio_model
load studio_style
load studio_templates

library studio_shell_qt

' ---------------------------------------------------------------------------
' The record constructors.
'
' Five shapes, because that is how many the vocabulary has: a leaf, a
' container with options, a container with a name, a container with a caption,
' and a table (a named container carrying a subject and a direction).
' §0.8 measured that a container carries a NAME OR OPTIONS AND NEVER BOTH --
' `tabs settings( movable: true )` costs four reduce/reduce conflicts -- so
' these are separate functions rather than one with optional arguments.
' ---------------------------------------------------------------------------

function part(word, name, options)
    return { kind: "part", word: word, name: name, options: options }
end function

' A leaf with no name. `stretch` and `separator` are the two: a stretch takes
' no name at all, and a separator in a layout may take one but Studio's rules
' are styled by class rather than addressed.
function bare(word)
    return { kind: "part", word: word, options: {} }
end function

function box(word, options, items)
    return { kind: "container", word: word, options: options, items: items }
end function

function named(word, name, items)
    return { kind: "container", word: word, name: name, items: items }
end function

' A container whose slot carries a CAPTION rather than a name: `tab "General"`,
' `group "Credit"`, `menu "File"`. It is the top-level `label` field and not an
' option, which cost gBASIC four increments to find out (§0.8) -- a leaf's
' `label:` lives in `options` and a labelled container's does not.
function captioned(word, caption, items)
    return { kind: "container", word: word, label: caption, items: items }
end function

' A caption AND a name, which only the RECORD can carry: §0.8's one-slot rule
' is a fact about the grammar, so a DECLARED `tab` spends its slot on the
' caption and cannot be named, while a built one may be both (gBASIC §0.27,
' added for exactly this consumer).
'
' THE NAME IS WHAT MAKES A RECONCILE WORK, and measured without it the editor
' came back EMPTY: `qt.refresh` keys on name and word, falling back to the
' caption where there is no name -- and Studio's captions are the thing that
' moves, so a tab keyed on its caption is rebuilt whenever the file is renamed.
' Keyed on the document id it is kept, with its text, its caret and its undo
' stack.
function captioned_named(word, caption, name, items)
    return { kind: "container", word: word, label: caption, name: name,
             items: items }
end function

' A split's slot is its DIRECTION, so a split cannot be named -- which is why
' pane sizes are addressed by walking up from a part inside one (§0.22) and why
' this takes no name to give.
'
' `splitter` and not `split`, which is the obvious name: `split` is a gBASIC
' BUILTIN, and while a library function is namespaced and so raises no
' shadowing note, an unqualified `split(...)` INSIDE this file would reach the
' local one and the builtin would be unreachable here. Nothing in this library
' needs to split a string today, which is exactly the state in which that trap
' gets laid.
function splitter(direction, panes)
    return { kind: "container", word: "split", name: direction, items: panes }
end function

' A table that SHOWS a list. The subject is the name of a variable in the frame
' that calls `qt.open` -- not a value, because `qt.refresh` re-reads it at the
' moment asked (§0.11), which is what lets the browser's row count grow and
' shrink without rebuilding anything.
function show_table(name, subject, columns)
    return { kind: "container", word: "table", name: name,
             direction: "show", subject: subject, items: columns }
end function

' A TREE that shows a list, which is the same production with a different word
' (gBASIC §0.28, built for this browser by name). The shape comes from a DEPTH
' COLUMN that is not drawn -- `field depth( depth: true )` -- over a FLAT list,
' which is exactly what a program owning its own expansion hands over.
'
' `to show` and nothing else: `to edit` would have to write a value back from a
' row that may be a PARENT, and `to ask` is a table's third direction for rows
' a program cannot hold, where a tree's shape comes from depths it has in hand.
function show_tree(name, subject, columns)
    return { kind: "container", word: "tree", name: name,
             direction: "show", subject: subject, items: columns }
end function

' A DOCK AREA. Its slot carries the EDGE -- `left`, `right`, `top`, `bottom` --
' the way a split's carries its direction, and for the same reason: an area with
' no edge is not an area.
function docks(edge, panes)
    return { kind: "container", word: "docks", name: edge, items: panes }
end function

' A DOCK PANE, and the ONLY shape in this vocabulary carrying a NAME AND a
' CAPTION both. §0.8's one-slot rule looks as though it forbids that, and
' gBASIC measured why it does not: the wall stands between two heads that both
' end in NEWLINE, and this head has a STRING where the choice would be, so one
' token of lookahead settles it.
'
' IT NEEDS BOTH FOR DIFFERENT REASONS. The caption is what a person reads on the
' pane's title bar. The NAME is what `qt.set` and `qt.dock` address -- and what
' Qt keys a saved layout by: a dock with no `objectName` makes `saveState` WARN
' and omit it, so "restore my layout" would come back silently partial, and
' every tier here captures stderr.
function dock(name, caption, items)
    return { kind: "container", word: "dock", name: name, label: caption,
             items: items }
end function

function toolbar(name, items)
    return named("toolbar", name, items)
end function

' The status bar. A bare container, and it holds named `text` parts rather than
' carrying a message itself: a `QStatusBar` has NO property for its text
' (`message` and `currentMessage` are both absent, and `showMessage` takes an
' argument `qt.invoke` cannot pass), while a `QLabel` inside one carries `text`
' as an ordinary Q_PROPERTY. So the by-name route reaches it and no verb was
' needed.
function status_bar(items)
    return { kind: "container", word: "status", options: {}, items: items }
end function

' The column that carries the depth and is never drawn.
function depth_column(name)
    return part("field", name, { depth: true })
end function

function column_of(name, caption)
    return part("field", name, { label: caption })
end function

' ---------------------------------------------------------------------------
' The names. One function per addressable part, because a string written twice
' is two things that can disagree.
' ---------------------------------------------------------------------------

function window_name()
    return "studio"
end function

function part_nav_menu()
    return "nav_menu"
end function

' A TAB'S OWN MENU (STU-21) and its items, named after the actions
' `studio_ui.tab_menu_all` lists -- the same rule the browser's items follow.
function part_tab_menu()
    return "tab_menu"
end function

function part_tab_item(action)
    return "tabm_" + studio_shell_qt._ident(action)
end function

' A browser context item, named after the action it performs -- the same rule
' the header items follow, so `studio_ui.context_all` stays the only list.
function part_ctx(action)
    return "ctx_" + studio_shell_qt._ident(action)
end function

' The browser's subject: the variable `app/studio.bas` must be holding when it
' calls `qt.open` and `qt.refresh`. Named here so the record and the renderer
' cannot drift about it -- gBASIC refuses a subject it cannot find in the
' calling frame, which makes a drift loud, but loud at run time is still later
' than here.
function nav_subject()
    return "nav"
end function

function part_browser()
    return "files"
end function

' The branch pane's subject -- the same arrangement the browser has, and the
' same reason the name is written once: `qt.open` and `qt.refresh` both resolve
' it out of the frame that calls them.
function branch_subject()
    return "branches"
end function

function part_branches()
    return "branch_list"
end function

' THE TABLES PANE (STU-8), the same arrangement the branch pane has: a table
' that shows a subject read out of the frame that calls `qt.open`/`qt.refresh`.
function tables_subject()
    return "tables"
end function

' What the Tables pane's table shows: one row per offer, or one row saying
' there are none -- a blank table reads as a pane that failed to fill.
function table_subject(rows)
    out = []
    for each r in rows
        out = append(out, { label: r.label })
    end for
    if count(out) = 0 then
        out = append(out, { label: "(nothing tabular in the latest run)" })
    end if
    return out
end function

function part_tables()
    return "table_list"
end function

function part_fetch()
    return "fetch_btn"
end function

' THE GRID WINDOW, and the name of the FUNCTION its table asks for cells.
' Written once here because `qt.open` resolves it by NAME, per cell, out of
' the program -- so it lives in `app/studio.bas`, which is where a function
' reading Studio's global can be.
function table_window_name()
    return "tablewin"
end function

function part_grid()
    return "grid"
end function

function grid_cell_fn()
    return "qt_table_cell"
end function

' A DOCK'S NAME IS WHAT QT KEYS A SAVED LAYOUT BY, so every one is written here
' and nowhere else -- measured upstream, a dock with no `objectName` makes
' `saveState` WARN and omit it, so "restore my layout" would come back silently
' partial, and every tier here captures stderr.
function part_browser_dock()
    return "dock_files"
end function

function part_console_dock()
    return "dock_console"
end function

function part_side_dock(id)
    return "dock_" + id
end function

function part_toolbar()
    return "toolbar"
end function

function part_tabs()
    return "book"
end function

function part_name_field()
    return "name_field"
end function

function part_save()
    return "save"
end function

function part_status()
    return "status"
end function

function part_console()
    return "console"
end function

function part_beside()
    return "beside"
end function

' A document's editor. Keyed off the document id so a renderer holding one can
' address its editor directly: `doc-3` becomes `ed_doc_3`, because a part name
' goes into `on <name>.<signal>` and a hyphen does not read as one identifier.
function part_editor(doc_id)
    return "ed_" + studio_shell_qt._ident(doc_id)
end function

' A document's TAB, named for the same reason its editor is: `qt.refresh` keys
' on the name, so the page that holds a document's editor has to be identified
' by the document rather than by the caption the marker moves.
function part_page(doc_id)
    return "page_" + studio_shell_qt._ident(doc_id)
end function

' THE SAME PAGE, PER THEME -- which is how an editor gets rebuilt when the
' theme changes.
'
' A `source`'s `theme:` is construction-only (measured: `qt.set` refuses it by
' name), so changing it means building a new widget, and `qt.refresh` rebuilds
' a child only when its NAME moves -- it does not recurse into one it keeps. So
' the theme goes in the PAGE's name: switch theme and every page is a new name,
' every editor is rebuilt with the new colours, and the editor's own part name
' is unchanged so nothing that addresses it has to know.
'
' Measured that this is safe rather than assumed: a refresh that renames the
' page while a child keeps its name does NOT clash -- the old page's names are
' purged before the new one is built -- and the rebuilt editor comes back with
' its language resolving and its margin intact (`line_numbers=true marks=true`).
' It comes back EMPTY, which is correct: the widget is new, and the renderer
' writes the text back from the model on the same redraw, because `_tabs`
' already writes wherever the text differs.
'
' WHAT IS LOST IS THE CARET AND THE UNDO STACK, for open tabs, on a deliberate
' theme change only. The user chose that over a window that stays
' half-themed until the next launch. Unsaved text is NOT at risk: Studio's
' model owns it, which is the whole reason this is affordable.
function part_page_for(doc_id, theme)
    return studio_shell_qt.part_page(doc_id) + "_" + theme
end function

' A menu item, named after the action it performs -- so the action vocabulary
' in `studio_ui.menus` is the only list of them, exactly as it is under GTK
' where `menubar.items` is keyed the same way.
function part_item(action)
    return "mi_" + studio_shell_qt._ident(action)
end function

' One `replace`, not a character walk: `split(text, "")` is refused by gBASIC
' ("split separator cannot be empty"), and one pass is also the right
' semantics -- a second would reach into the first pass's output.
function _ident(text)
    return replace(text, "-", "_")
end function

' ---------------------------------------------------------------------------
' The window.
' ---------------------------------------------------------------------------

' Studio's whole window, as a record. Pure: it reads the model and returns
' data, so the headless tier can assert the structure and `qt.check` can
' refuse a malformed one with no display anywhere.
function window_for(app)
    model = app.model

    items = []
    ' THE MENU BAR BELONGS TO THE WINDOW and not to a layout (§0.7): Qt would
    ' put a QMenuBar wherever the layout said, so a `menu` inside a `row`
    ' renders as a bar in the middle of the screen, and gBASIC refuses it at
    ' load time for that reason. A main window additionally has to PLACE it
    ' with `setMenuBar` -- added to the central widget's layout it renders
    ' inside the window, under the toolbar and above the content, which is the
    ' one existing path §0.30 had to change.
    for each spec in studio_ui.menus()
        items = append(items, studio_shell_qt._menu_for(app, spec))
    end for
    ' THE BROWSER'S CONTEXT MENU, which belongs to the WINDOW too. A `QMenu` is
    ' placed by nothing, so a `popup` written inside a `row` is a declaration
    ' the layout silently ignores -- gBASIC refuses it there.
    items = append(items, studio_shell_qt._nav_menu(app))
    ' And a tab's, for the same reason.
    items = append(items, studio_shell_qt._tab_menu(app))

    ' --- THE FURNITURE, which is what makes this a QMainWindow -------------
    '
    ' A window asks for one by HOLDING a `docks`, a `toolbar` or a `status`,
    ' decided from the declaration rather than offered as an option -- so a
    ' window with none is untouched. THREE SPLITS BECAME THREE DOCK AREAS, and
    ' that is not a cosmetic swap:
    '
    '   * a dock has a TITLE BAR saying what it is, where Studio's right-hand
    '     column was five headings in a scroller and CLAUDE.md's own verdict on
    '     it was "an undifferentiated list of sentences";
    '   * Qt TABS docks that share an area, measured -- which closes the
    '     complaint that the last of five stacked panes sits below the fold, a
    '     heading reading "Errors" over a pane you cannot see being
    '     indistinguishable from one reading "Errors" over "(none)";
    '   * and a dock can be closed, floated and dragged to another edge, which
    '     `qt.layout` then SAVES whole -- where GTK could store three divider
    '     numbers and nothing about arrangement.
    items = append(items, studio_shell_qt._toolbar(app))
    items = append(items, docks("left", [
        dock(studio_shell_qt.part_browser_dock(), "Files",
             [ studio_shell_qt._browser(app) ]) ]))
    items = append(items, docks("bottom", [
        dock(studio_shell_qt.part_console_dock(), "Console",
             [ studio_shell_qt._console(app) ]) ]))
    items = append(items, docks("right", studio_shell_qt._side_docks(app)))
    items = append(items, status_bar([
        part("text", studio_shell_qt.part_status(),
             { label: studio_ui.status_text(app) }) ]))

    ' --- and the CENTRAL widget, which is the editor -----------------------
    items = append(items, studio_shell_qt._central(app))

    return { kind: "window", name: studio_shell_qt.window_name(),
             options: { title: studio_shell_qt.title_for(app),
                        width: model.session.window.width,
                        height: model.session.window.height },
             items: items }
end function

' The window title, which is where the unsaved marker went.
'
' Under GTK the title is the workspace name and the marker rides the tab label.
' A Qt tab caption is fixed at construction (see this file's header), so the
' marker has to live somewhere a `qt.set` can reach -- and the title bar is
' where every other editor puts it anyway.
function title_for(app)
    base = "gBASIC Studio"
    ws = app.model.workspace
    if ws != nothing then
        base = "gBASIC Studio — " + ws.name
    end if
    doc = studio_docs.active_doc(app.dm)
    if doc = nothing then
        return base
    end if
    marker = studio_ui.tab_label(doc)
    plain = doc.display_name
    if marker = plain then
        return plain + " — " + base
    end if
    return marker + " — " + base
end function

' The browser's right-click menu: every item there is, BUILT ONCE, shown or
' hidden per row.
'
' That is the GTK shell's arrangement kept deliberately, and the reason is the
' same: minting widgets inside a selection handler is the doubling `ui_gui_solo`
' exists to catch one level up, and under Qt it would additionally need a
' reconcile where `qt.set(... "visible" ...)` does. `studio_ui.context_actions`
' decides which a row offers and `studio_ui.context_all` is the closed list, so
' nothing here knows what a row is.
'
' AN EMPTY MENU IS WORSE THAN NONE, and Qt agrees: an all-hidden `QMenu` is
' `isEmpty()` and `popup()` leaves it invisible, so `qt.popup` answers false and
' Studio's own comment -- "a popover with nothing in it reads as a control that
' failed" -- is enforced by the toolkit rather than by us.
function _nav_menu(app)
    entries = []
    for each action in studio_ui.context_all()
        entries = append(entries, part("item", studio_shell_qt.part_ctx(action),
                                       { label: studio_ui.context_label(action) }))
    end for
    return named("popup", studio_shell_qt.part_nav_menu(), entries)
end function

' ---------------------------------------------------------------------------
' The New Project window.
' ---------------------------------------------------------------------------

' THE GRID WINDOW: one table, built from the columns the source HAS.
'
' ONE TIER, where GTK had two. The GTK window drew a modest table as a grid of
' labels and a large one through `datagrid`, because a GtkColumnView cost
' something to stand up; a Qt `table to ask` costs the VIEWPORT -- measured
' upstream, about 27 cells whether the table has a hundred rows or a million
' -- so there is nothing to fork on. The columns are DATA here and not a
' declaration, which is why this is a function of the source.
'
' A field is named `c0`, `c1`... rather than after its column: a column is
' somebody's key, which can be any string, and a part name cannot.
'
' The caption is `studio_table.caption`, the same sentence the headless goldens
' assert, so the window cannot quietly say something kinder than the model --
' it is where a sample admits to being one.
function table_window(caption, note, cols, numeric)
    u = studio_style.unit()
    fields = []
    i = 0
    for each c in cols
        ' NUMBERS SIT RIGHT (gBASIC §0.35), so a column of them lines up on
        ' the units; `numeric` is `studio_table.numeric_columns`, decided from
        ' the data because a column's name says nothing about what is in it.
        opts = { label: string(c) }
        if i < count(numeric) then
            if numeric[i] then
                opts.align = "right"
            end if
        end if
        fields = append(fields, part("field", "c" + string(i), opts))
        i = i + 1
    end for
    body = []
    ' THE CAPTION READS AS A TITLE: bold, and a style sheet on a label has no
    ' children for it to cascade into.
    body = append(body, part("text", "grid_caption",
                             { label: caption, styleSheet: "font-weight: bold;" }))
    ' What a SAMPLE means and where the rest is -- empty for a whole table.
    body = append(body, part("text", "grid_note", { label: note, wordWrap: true }))
    if count(fields) > 0 then
        ' SORTING IS STUDIO'S (see `studio_table.sort_rows`): gBASIC turns
        ' header-click sorting off on an asking table, so the order is chosen
        ' here and the grid is told the data changed.
        body = append(body, box("row", { margin: 0, spacing: u }, [
            part("text", "grid_sort_label", { label: "Sort by" }),
            part("choice", "grid_sort", {}),
            part("check", "grid_desc", { label: "Descending" }),
            bare("stretch") ]))
        body = append(body, { kind: "container", word: "table",
                              name: studio_shell_qt.part_grid(),
                              direction: "ask",
                              subject: studio_shell_qt.grid_cell_fn(),
                              items: fields })
    else
        body = append(body, part("text", "grid_empty", { label: "(nothing to show)" }))
    end if
    return { kind: "window", name: studio_shell_qt.table_window_name(),
             options: { title: "gBASIC Studio — table", width: 900, height: 600 },
             items: [ box("column", { margin: u, spacing: u }, body) ] }
end function

' What the Sort by choice offers: the run's own order first, then every column.
function sort_choices(cols)
    out = [ "(the order the run made them)" ]
    for each c in cols
        out = append(out, string(c))
    end for
    return out
end function

' ---- STU-15: the snippet window ---------------------------------------------
'
' Insert SQL…: a builder that WRITES a statement into the file and never runs
' it. Another ordinary window, New Project's shape. Every field of EVERY
' snippet is built once and shown or hidden by which snippet is picked --
' the GTK window's arrangement and the browser menu's, for the same reason: a
' window whose parts change under a selection handler is a parent rebuilt out
' from under whatever had focus.

function snippet_window_name()
    return "snipwin"
end function

' Where each template field lives in the window, ONE mapping read by the record
' and by the handlers: `row` is the snippet's index, `name` the template's
' field, `part` the text field and `line` the row holding it with its label.
' Named by position because a field name is the template author's string.
function snippet_fields(rows)
    out = []
    ri = 0
    for each r in rows
        fi = 0
        for each f in r.fields
            out = append(out, { row: ri, name: f.name, default: f.default,
                                secret: f.secret,
                                label: studio_templates.field_label(f),
                                part: "sf_" + string(ri) + "_" + string(fi),
                                line: "sl_" + string(ri) + "_" + string(fi) })
            fi = fi + 1
        end for
        ri = ri + 1
    end for
    return out
end function

function snippet_window(rows, engine, conn_name)
    u = studio_style.unit()
    lines = []
    for each f in studio_shell_qt.snippet_fields(rows)
        opts = {}
        if f.secret then
            ' NOT masked: the value is about to be written into the document in
            ' plain text, and a masked field would say the opposite.
            opts = { toolTip: "This is written into your document in plain text — the statement carries it, so there is nowhere else for it to go." }
        end if
        lines = append(lines, named("row", f.line, [
            part("text", f.part + "_label", { label: f.label }),
            part("field", f.part, opts) ]))
    end for
    body = [
        part("text", "sn_head", { label: "Write a statement into this file" }),
        ' WHICH database, said out loud: a form offering `create login` without
        ' saying it means SQL Server on `erp` is one you must already understand.
        part("text", "sn_where", { label: conn_name + " — " + engine }),
        part("choice", "sn_pick", {}),
        part("text", "sn_desc", { label: "" }) ]
    for each l in lines
        body = append(body, l)
    end for
    body = append(body, part("text", "sn_note", { label: "" }))
    body = append(body, box("row", { margin: 0, spacing: u }, [
        bare("stretch"),
        part("button", "sn_cancel", { label: "Cancel" }),
        part("button", "sn_insert", { label: "Insert" }) ]))
    return { kind: "window", name: studio_shell_qt.snippet_window_name(),
             options: { title: "gBASIC Studio — snippet", width: 560, height: 420 },
             items: [ box("column", { margin: u * 2, spacing: u }, body) ] }
end function

' ---- STU-17: the schema window ----------------------------------------------
'
' What the database says about itself: pick a table, see its columns AND the
' exact question Studio asked to get them -- `pragma table_info`,
' `information_schema.columns` -- because the window is a tool that shows you
' how to ask, not only one that tells you. The columns are a read-only memo of
' aligned lines, the GTK window's monospace label.

function schema_window_name()
    return "schemawin"
end function

function schema_window(conn_name, driver)
    u = studio_style.unit()
    return { kind: "window", name: studio_shell_qt.schema_window_name(),
             options: { title: "gBASIC Studio — schema", width: 600, height: 520 },
             items: [ box("column", { margin: u * 2, spacing: u }, [
                 part("text", "sc_head", { label: "What this database says about itself" }),
                 part("text", "sc_where", { label: conn_name + " — " + driver }),
                 part("choice", "sc_pick", {}),
                 part("memo", "sc_cols", { readOnly: true }),
                 part("text", "sc_asked_head", { label: "Studio asked" }),
                 part("text", "sc_asked", { label: "" }),
                 part("text", "sc_note", { label: "" }),
                 box("row", { margin: 0, spacing: u }, [
                     bare("stretch"),
                     part("button", "sc_close", { label: "Close" }),
                     part("button", "sc_insert",
                          { label: "Insert a select",
                            toolTip: "Write `select <every column> from <this table>;` into your document, at the caret. Naming the columns rather than `select *` is the habit worth keeping." }) ]) ]) ] }
end function

function new_project_name()
    return "newproj"
end function

' The subject the form edits. `qt.subject(win, "opts")` IS the whole of the
' widget-to-value read, which is what makes this window so much smaller than
' the GTK one.
function newproj_subject()
    return "opts"
end function

function part_np(name)
    return name
end function

' A SECOND ORDINARY WINDOW, NOT A MODAL ONE, and that is deliberate twice over.
'
' CLAUDE.md's standing rule is that an async surface is one no test can press,
' which is why New Project is a window Studio builds rather than a
' `GtkAlertDialog`. gBASIC's §0.18 shows a modal window CAN be driven -- a timer
' keeps running while `qt.open_modal` blocks, so a program can answer its own
' window -- but §0.15's stated limit is the other case, a dialog raised from a
' HANDLER, and this one is raised from a menu item. §0.17 measured two ordinary
' windows open at once with parts scoped per window, so the shape that matches
' today's behaviour is also the shape with no limit in it.
'
' A `form to edit` DOES THE WHOLE JOB, which the GTK version could not.
' Measured: it binds fields AND checks AND a choice from one record, and
' `qt.subject` reads the lot back -- so `studio_shell.new_project_options`,
' which walks eight widgets and maps a drop-down index back to a licence id
' through `_index_of`, becomes one verb. The options record was always the
' thing being edited; now it is also the thing the window is bound to.
function new_project_window(opts, license_ids)
    u = studio_style.unit()
    return { kind: "window", name: studio_shell_qt.new_project_name(),
             options: { title: "gBASIC Studio — new project",
                        width: 560, height: 420 },
             items: [ box("column", { margin: u * 2, spacing: u }, [
                 part("text", "np_head", { label: "New project" }),
                 { kind: "container", word: "form", direction: "edit",
                   subject: studio_shell_qt.newproj_subject(), items: [
                     part("field", "name",
                          { label: "Name",
                            toolTip: "What the project is called. The DIRECTORY is a slug of this, so \"My Thing\" lands in my-thing." }),
                     part("field", "location",
                          { label: "Location",
                            toolTip: "The directory the project directory is made inside. ~/ and relative paths work." }),
                     part("field", "author",
                          { label: "Author",
                            toolTip: "Who a licence names as the copyright holder. Taken from git's user.name when there is one." }),
                     part("choice", "license",
                          { label: "Licence",
                            toolTip: "Studio does not write a licence of its own: it copies the text from share/licenses/ and fills in the year and the author." }),
                     ' THE FOUR FILES, in the order a project usually acquires
                     ' them. ONLY main.bas IS ON: a project with nothing in it
                     ' scans to zero browser rows and there is nowhere to
                     ' click. `.gstudio.json` is off most deliberately --
                     ' ticking it by default would be Studio putting its own
                     ' file in your directory because you did not look, which
                     ' is the behaviour that file exists to avoid. A box you
                     ' had to untick is not consent.
                     part("check", "main",
                          { label: "main.bas — a file you can run straight away" }),
                     part("check", "readme", { label: "README.md" }),
                     part("check", "projfile",
                          { label: ".gstudio.json — a stable id, an ignore list, an interpreter pin" }),
                     part("check", "git",
                          { label: "git repository — git init, and a .gitignore" }) ] },
                 ' The refusal goes HERE and the window STAYS OPEN with what was
                 ' typed still in it: the field to fix is in this window, and
                 ' closing it to put the reason in a status line behind it would
                 ' hide both.
                 part("text", "np_note", { label: "" }),
                 bare("stretch"),
                 box("row", { margin: 0, spacing: u }, [
                     bare("stretch"),
                     part("button", "np_cancel", { label: "Cancel" }),
                     part("button", "np_create", { label: "Create" }) ]) ]) ] }
end function

' A menu and its items. A `menu`'s slot carries a CAPTION and not a name
' (§0.7, asserted both ways upstream so a menu and a table cannot drift
' together), and an ITEM is a QAction addressed by name -- which is what makes
' `qt.invoke(win, name, "trigger")` a real press rather than a call to the
' handler, and so what finally gives the menu items a display tier that
' presses what a person presses.
function _menu_for(app, spec)
    entries = []
    for each action in spec.items
        if action = "-" then
            entries = append(entries, bare("separator"))
        else
            entries = append(entries, studio_shell_qt._item_for(app, action))
        end if
    end for
    return captioned("menu", spec.label, entries)
end function

' One item.
'
' THE ●/○ MARKS RETIRE HERE. Under GTK a popover of plain `Gtk.Button`s cannot
' draw a radio mark, so `studio_ui.menu_text` prefixes a glyph -- a trade, not
' a limitation, taken to keep every item pressable by a test. A QAction is
' `checkable:` and `qt.set(win, item, "checked", true)` moves it, so the mark
' becomes the toolkit's own and the label becomes just the label. `menu_mark`
' is still the one place that decides WHICH item is the current one; only its
' rendering changed.
function _item_for(app, action)
    opts = { label: studio_ui.menu_label(action) }
    hint = studio_ui.menu_hint(action)
    if hint != "" then
        ' A QAction's tooltip is where the sentence a toolbar button had no
        ' room for goes -- the whole argument of STU-16, kept.
        opts.toolTip = hint
    end if
    state = studio_ui.menu_checkable(action)
    if state then
        opts.checkable = true
        opts.checked = studio_ui.menu_checked(app, action)
    end if
    shortcut = studio_shell_qt.shortcut_for(action)
    ' A LIST is several alternatives, a text one shortcut (gBASIC §0.34).
    if is_array(shortcut) then
        opts.shortcut = shortcut
    else
        if shortcut != "" then
            opts.shortcut = shortcut
        end if
    end if
    return part("item", studio_shell_qt.part_item(action), opts)
end function

' The accelerators.
'
' Under GTK these were a `Gtk.EventControllerKey` on the editor, which is the
' ONE control in Studio with no display-tier test at all -- there is no way to
' synthesise a key press through the bridge, so STU-20 shipped it as a
' sanctioned exception. A QAction carries its own shortcut, declared here, and
' gBASIC measured the controller unnecessary for exactly this reason (§0.21).
' So the exception closes: the accelerator is part of the record, which the
' headless tier reads.
function shortcut_for(action)
    ' TWO KEYS, because they are two keys. "+" is SHIFTED on most layouts, so
    ' a person pressing Ctrl and the "=/+" key delivers Key_Equal, which
    ' `Ctrl++` does not match: measured by the user on a US layout, Ctrl+Shift+=
    ' zoomed and plain Ctrl+= did nothing. Kate binds both, and gBASIC's §0.34
    ' made a list of alternatives possible (QAction::setShortcuts).
    if action = "text-bigger" then
        return ["Ctrl++", "Ctrl+="]
    end if
    if action = "text-smaller" then
        return "Ctrl+-"
    end if
    if action = "text-reset" then
        return "Ctrl+0"
    end if
    if action = "new-file" then
        return "Ctrl+N"
    end if
    if action = "close-tab" then
        return "Ctrl+W"
    end if
    return ""
end function

' THE TOOLBAR, which is what the header row used to be and is now the
' toolkit's own.
'
' Its entries are `QAction`s -- the SAME objects a menu's items are, so `icon:`
' and `checkable:` work on one here exactly as there, and an `item` means the
' same thing in both places by construction rather than by agreement.
'
' THE ICONS ARE `SP_` STANDARD PIXMAPS, which is the one source that always
' resolves. Measured on this machine, which has NO ICON THEME AT ALL: all five
' answer `qt.has_icon` true, where a freedesktop name would warn and draw
' nothing. That is §0.23's own reason for preferring them.
'
' SAVE IS STILL NOT IN A MENU. It is pressed constantly, it is the only control
' with a state of its own (the conflict arm), and a second route would be a
' second widget for the teaching registry and the smoke modes to tell apart. It
' keeps the part name it had as a button, so nothing addressing it moved.
'
' AND RUN IS NOT HERE, which is STU-16's own lesson applied rather than a
' slip. That phase existed because ten toolbar buttons mixed three SCOPES with
' nothing saying which: the workspace, the browser selection, and the active
' document. This toolbar is document-and-workspace scope -- Save, Reload, Open
' Folder, New File, New Folder. Run is SECTION scope and belongs beside the
' thing that names the section, which is the run strip in the console dock: a
' Run button next to "section: sec-1 statements" says what it will run, and one
' on a global toolbar does not. Two routes to one verb is also the thing Save
' is deliberately spared.
function _toolbar(app)
    return toolbar(studio_shell_qt.part_toolbar(), [
        part("item", studio_shell_qt.part_save(),
             { label: "Save", icon: "SP_DialogSaveButton",
               toolTip: "Write the active document to disk. Over a file that changed underneath, press twice — the first press arms it." }),
        part("item", "tb_reload",
             { label: "Reload", icon: "SP_BrowserReload",
               toolTip: studio_ui.menu_hint("reload") }),
        bare("separator"),
        part("item", "tb_open_folder",
             { label: "Open Folder", icon: "SP_DialogOpenButton",
               toolTip: studio_ui.menu_hint("open-folder") }),
        part("item", "tb_new_file",
             { label: "New File", icon: "SP_FileIcon",
               toolTip: studio_ui.menu_hint("new-file") }),
        part("item", "tb_new_folder",
             { label: "New Folder", icon: "SP_FileDialogNewFolder",
               toolTip: studio_ui.menu_hint("new-folder") }) ])
end function

' The five panes that were a scrolled column on the right, each now a dock with
' a title bar of its own. Qt TABS the ones sharing an edge -- measured, two in
' the same area come back `tabbed_with: 1` -- which is what closes the
' complaint that the last of five stacked panes sits below the fold, a heading
' reading "Errors" over a pane you cannot see being indistinguishable from one
' reading "Errors" over "(none)".
' THE BRANCH PANE (STU-7, STU-9): the selector, Bind, and the overlay strip.
'
' The overlay buttons are FIXED acts, not data -- the set never changes, only
' whether each is allowed, and every refusal reaches the status bar by name --
' so they are buttons in two rows of three, the GTK layout and its reason: six
' in one row would not fit a side pane. "Save overlay", not "Save": the
' toolbar's Save writes the FILE, and one word doing two things to one document
' is worse than a longer label.
'
' THE OVERLAY HAS ITS OWN EDITOR, because the source editor shows the canonical
' document and a window displaying non-canonical text as the file is the one
' thing design §2.1 forbids. Hidden until there is an overlay to edit -- under
' GTK it was an empty box with a lone "1" in it for every user who had never
' made one. Its theme is fixed when the window is built (`theme` is
' construction-only), so a theme change reaches it at the next launch.
function _branch_body(app)
    u = studio_style.unit()
    return box("column", { margin: 0, spacing: u }, [
        show_table(studio_shell_qt.part_branches(),
                   studio_shell_qt.branch_subject(),
                   [ column_of("line", "Branch") ]),
        part("button", "bind_btn",
             { label: "Bind name = value",
               toolTip: "Give the selected branch a value: type name = value in the name field first. The source is the same in every branch; only its bindings differ." }),
        box("row", { margin: 0, spacing: u }, [
            part("button", "ov_edit", { label: "Overlay" }),
            part("button", "ov_save", { label: "Save overlay" }),
            part("button", "ov_compare", { label: "Compare" }) ]),
        box("row", { margin: 0, spacing: u }, [
            part("button", "ov_rebase", { label: "Rebase" }),
            part("button", "ov_promote", { label: "Promote" }),
            part("button", "ov_discard", { label: "Discard" }) ]),
        part("source", "ov_editor",
             { language: "gBASIC", line_numbers: true, visible: false,
               theme: studio_style.qt_source_theme(app.model.settings.theme) }),
        ' Where Compare prints and a conflict is spelled out.
        part("memo", "ov_diff", { readOnly: true }) ])
end function

' THE ASSISTANT PANE (STU-6): read-only, and it says so. One question --
' "where was I?" -- because an assistant that can only look has one useful
' thing to be asked; the answer lands in the box below.
function _agent_body()
    u = studio_style.unit()
    return box("column", { margin: 0, spacing: u }, [
        part("text", "agent_head",
             { label: "Read-only: it can see your project, not change it." }),
        part("button", "ask_btn", { label: "Where was I?" }),
        part("memo", "agent_body", { readOnly: true }) ])
end function

function _side_docks(app)
    out = []
    for each p in studio_shell_qt.side_panes()
        if p.id = "branch" then
            body = studio_shell_qt._branch_body(app)
        else
            if p.id = "tables" then
                ' THE TABLE OFFERS, CLICKABLE: a row opens the grid window.
                ' Fetch re-runs the section, and its label says so -- a button
                ' that silently re-executed somebody's code would be a worse
                ' surprise than a slow one.
                body = box("column", { margin: 0, spacing: studio_style.unit() }, [
                    show_table(studio_shell_qt.part_tables(),
                               studio_shell_qt.tables_subject(),
                               [ column_of("label", "Table") ]),
                    part("button", studio_shell_qt.part_fetch(),
                         { label: "Fetch all rows (runs the section again)" }) ])
            else
                if p.id = "agent" then
                    body = studio_shell_qt._agent_body()
                else
                    ' `results` and `git` are prose and were never lists.
                    body = part("memo", p.id + "_body", {})
                end if
            end if
        end if
        out = append(out, dock(studio_shell_qt.part_side_dock(p.id), p.label,
                               [ body ]))
    end for
    return out
end function

' THE CENTRAL WIDGET IS THE EDITOR, which is what a main window is for: the
' thing the application is about sits in the middle and everything else docks
' around it.
'
' The name field rides above it, and that is the whole of what is left of the
' header row -- the wordmark went (the title bar says it), Save went to the
' toolbar, and the menus belong to the window. A `toolbar` admits `item` and
' `separator` only, so a field cannot live in one.
function _central(app)
    u = studio_style.unit()
    return box("column", { margin: 0, spacing: 0 }, [
        box("row", { margin: u, spacing: u }, [
            part("field", studio_shell_qt.part_name_field(),
                 { placeholderText: "name or path",
                   toolTip: "A name for New File / New Folder / Rename, or a folder path for Open Folder (~ works). New Project asks for its own." }),
            bare("stretch") ]),
        studio_shell_qt._editors(app) ])
end function


' THE BROWSER IS A TREE (gBASIC §0.28, built for it by name).
'
' It was a `table` for one increment, and only because a table was the only
' widget in this vocabulary whose row COUNT could change without rebuilding the
' window -- expanding a directory being exactly that. It worked and it looked
' like a spreadsheet pretending to be a file tree: a header row that could not
' be hidden through the by-name route, grid lines, flat rows with two spaces
' per level inside the string, and no indentation of its own. The ask went
' upstream with those measurements and came back built.
'
' TWO COLUMNS, ONE OF THEM INVISIBLE. `text` is the row without its
' indentation -- the tree does that -- and `depth` is declared `depth: true`,
' which makes it the shape rather than a cell. At most one such column, because
' two would be a declaration with two answers.
'
' STUDIO OWNS EXPANSION AND THE WIDGET DOES NOT, which is not a preference. The
' rows `nav_rows` answers are the VISIBLE ones and the click dispatcher indexes
' that same array -- deriving rows twice desynchronises the moment the
' filesystem changes between a render and a click. gBASIC measured the half that
' makes this load-bearing: after a collapse Qt's own NotHidden iterator still
' counts every row, so there is no free "visible index" and an index can only
' mean the rows the program handed over. Studio hands over the visible ones, so
' the two numbers coincide by construction. `itemsExpandable` is therefore OFF
' and the `▾` / `▸` glyphs stay Studio's own, exactly as they are under GTK,
' where they are characters in the row and clicking the ROW toggles.
'
' AND NO `scroll` AROUND IT. A tree scrolls itself, like a table and a memo, so
' a scroller would be a second region for the pane walk to stop at -- which is
' what `qt.resize_panes` and `qt.pane` walk up through. Dropping it makes the
' tree the split's own pane and so the thing that addresses it.
function _browser(app)
    return show_tree(studio_shell_qt.part_browser(),
                     studio_shell_qt.nav_subject(),
                     [ column_of("text", "File"),
                       depth_column("depth") ])
end function

' A tab's right-click menu (STU-21): Close and Copy file path. Both items are
' always offered -- `tab_path` refuses BY NAME for a document with no file
' behind it, which says more than a hidden item would.
function _tab_menu(app)
    entries = []
    for each action in studio_ui.tab_menu_all()
        entries = append(entries, part("item", studio_shell_qt.part_tab_item(action),
                                       { label: studio_ui.tab_menu_label(action) }))
    end for
    return named("popup", studio_shell_qt.part_tab_menu(), entries)
end function

' One tab per visible document, each holding one `source`.
'
' The captions are PLAIN names -- see this file's header for why the marker is
' not here. `tab_rows` is the same filter the GTK notebook reconciles against,
' so a document hidden behind another project is absent from both.
'
' An empty document set gets ONE tab with a welcome note in it, because `tabs`
' with no `tab` is a book with no pages and Studio's cold start is the one path
' that must not break.
' One editor's construction options.
'
' THE LANGUAGE IS THE FILE'S (`studio_ui.highlight_language`): gBASIC for
' Studio's own suffixes, a named definition for the files Studio knows, and
' NONE for the rest -- a plain editor. Every editor used to be declared
' gBASIC, so a README was highlighted as code.
'
' THE MARGIN (gBASIC §0.29): `marks` is the gutter -- a `section` glyph at
' every runnable section's start, which is the whole notebook affordance, and
' an `error` glyph at a parse diagnostic's line. `line_numbers` because
' gBASIC's diagnostics are `line:column` and a reader needs something to count
' against.
'
' THE COLOURS are DECLARED from the setting, because `theme` is construction-
' only and a stylesheet does not move Qt's palette: a dark Studio would
' otherwise wrap a light editor. gBASIC refuses a `theme` with no `language`
' (the theme is applied WITH the definition), so a plain editor has neither --
' and in Dark it is light. Stated rather than hidden; asked of gBASIC.
function _editor_options(app, doc_id)
    opts = { line_numbers: true, marks: true }
    doc = studio_docs.doc_by_id(app.dm, doc_id)
    lang = ""
    if doc != nothing then
        lang = studio_ui.highlight_language(doc.path)
    end if
    if lang != "" then
        opts.language = lang
        opts.theme = studio_style.qt_source_theme(app.model.settings.theme)
    end if
    return opts
end function

function _editors(app)
    rows = studio_ui.tab_rows(app)
    pages = []
    for each r in rows
        ' `r.label` is `studio_ui.tab_label` -- the name with its marker, `* `
        ' unsaved / `~ ` changed underneath / `! ` gone. IT GOES IN THE CAPTION,
        ' the same place the GTK notebook puts it, because `qt.refresh` RE-READS
        ' a tab's caption and the tab is keyed on the document id rather than on
        ' what it says. Measured: the caption moves and the editor keeps its
        ' text, its caret and its undo stack.
        pages = append(pages, captioned_named("tab", r.label,
            studio_shell_qt.part_page_for(r.doc_id,
                studio_style.qt_source_theme(app.model.settings.theme)), [
            box("column", { margin: 0, spacing: 0 }, [
                part("source", studio_shell_qt.part_editor(r.doc_id),
                     studio_shell_qt._editor_options(app, r.doc_id)) ]) ]))
    end for
    if count(pages) = 0 then
        pages = append(pages, captioned_named("tab", "(no document)", "page_welcome", [
            box("column", { margin: 12, spacing: 6 }, [
                part("text", "welcome",
                     { label: "Open a file from the browser, or File ▸ New File." }),
                bare("stretch") ]) ]))
    end if
    return named("tabs", studio_shell_qt.part_tabs(), pages)
end function

' The console: the run strip above the three output panes.
'
' Every one of these is a `text` part whose label the renderer sets, which is
' what the GTK shell's labels are too -- so `studio_ui.run_line`,
' `output_source`, `error_body` and the rest are reached identically and no
' decision moved. The two-row run strip (STU-4: a refusal carries a whole
' SENTENCE and a horizontal row has a hard width budget) stays two rows.
function _console(app)
    u = studio_style.unit()
    ' TWO ROWS, and the state line owns the second. A refusal carries a whole
    ' SENTENCE ("that section is ambiguous after the last edit; disambiguate it
    ' first") and a horizontal row of buttons plus two labels has a hard width
    ' budget, so under GTK the sentence arrived ellipsized after its first few
    ' words. Nothing about that changed with the toolkit.
    '
    ' Three of the five buttons are HIDDEN rather than absent, which is the
    ' rule the GTK strip already follows: a control that is added and removed
    ' is a control whose parent can be destroyed under a live window, and under
    ' Qt it would additionally need a reconcile where `qt.set(… "visible" …)`
    ' does.
    ' NAMED, so the assistant can point at it (`teach_target`); a named row
    ' carries no options, so it takes the default spacing.
    strip = named("row", "run_strip", [
        part("button", "run_btn", { label: "Run Section" }),
        part("button", "run_all_btn", { label: "Run All" }),
        part("button", "stop_btn", { label: "Stop" }),
        ' FORCE STOP is SIGKILL after a grace period, for a child that ignores a
        ' polite stop -- `studio_ui.force_stop_run`, the GTK button's function.
        part("button", "force_btn", { label: "Force Stop" }),
        part("button", "snippet_btn", { label: "Insert SQL…" }),
        part("button", "schema_btn", { label: "Schema…" }),
        part("text", "run_section", { label: "section: (none)" }),
        part("text", "run_standing", { label: "" }),
        bare("stretch") ])
    panes = [ strip,
              part("text", "run_state", { label: "" }),
              part("text", "run_branch", { label: "" }),
              bare("separator"),
              part("text", "prefix_head",
                   { label: "Prefix output — sections replayed before the target" }),
              part("memo", "prefix_body", {}),
              bare("separator"),
              part("text", "target_head",
                   { label: "Target output — the section you ran" }),
              part("memo", "target_body", {}),
              bare("separator"),
              part("text", "err_head", { label: "Errors" }),
              part("memo", "err_body", {}) ]
    return named("scroll", studio_shell_qt.part_console(),
                 [ box("column", { margin: u, spacing: u }, panes) ])
end function

' The right column's vocabulary, in the order STU-8/9/11/10 put them. A closed
' list, so a pane cannot be added by a renderer that happens to know a name.
' ---- STU-10: what each teachable name IS in this window ----------------------
'
' `studio_teaching` decides whether a name and a gesture are allowed; this
' answers WHERE: the part to mark, and the dock to raise first, since a cue on
' a pane hidden behind another tab is a cue nobody sees.
'
' THREE NAMES POINT AT THE TOOLBAR, and that is a stated limit. `save_button`
' is a QAction (a toolbar entry is not a widget), and `project_menu` and
' `file_menu` are menu-bar menus, which gBASIC does not name at all -- and a
' cue on an item inside a shut menu draws nothing and reports success, the
' exact failure `agent_widgets` exists to stop. The toolbar holds Save, New
' File, New Folder, Open Folder and Reload, so it is the honest nearest thing.
function teach_target(app, name)
    if name = "browser" then
        return { part: studio_shell_qt.part_browser(), dock: studio_shell_qt.part_browser_dock() }
    end if
    if name = "tabs" then
        return { part: studio_shell_qt.part_tabs(), dock: "" }
    end if
    if contains(["editor", "gutter"], name) then
        doc = studio_docs.active_doc(app.dm)
        if doc = nothing then
            return { part: "", dock: "" }
        end if
        return { part: studio_shell_qt.part_editor(doc.id), dock: "" }
    end if
    if name = "run_strip" then
        return { part: "run_strip", dock: studio_shell_qt.part_console_dock() }
    end if
    if name = "output" then
        return { part: studio_shell_qt.part_console(), dock: studio_shell_qt.part_console_dock() }
    end if
    if name = "results" then
        return { part: "results_body", dock: studio_shell_qt.part_side_dock("results") }
    end if
    if name = "branches" then
        return { part: studio_shell_qt.part_branches(), dock: studio_shell_qt.part_side_dock("branch") }
    end if
    if name = "tables" then
        return { part: studio_shell_qt.part_tables(), dock: studio_shell_qt.part_side_dock("tables") }
    end if
    if name = "assistant" then
        return { part: "agent_body", dock: studio_shell_qt.part_side_dock("agent") }
    end if
    if name = "name_field" then
        return { part: studio_shell_qt.part_name_field(), dock: "" }
    end if
    if name = "run_button" then
        return { part: "run_btn", dock: studio_shell_qt.part_console_dock() }
    end if
    if name = "overlay_strip" then
        return { part: "ov_edit", dock: studio_shell_qt.part_side_dock("branch") }
    end if
    if contains(["save_button", "project_menu", "file_menu"], name) then
        return { part: studio_shell_qt.part_toolbar(), dock: "" }
    end if
    return { part: "", dock: "" }
end function

' Every name this window can resolve -- compared with `studio_teaching`'s
' registry by `agent_widgets`, so a name the agent is told it may point at and
' a name the window can find are the same set.
function teachable()
    return ["browser", "tabs", "editor", "gutter", "run_strip", "output",
            "results", "branches", "tables", "assistant", "name_field",
            "run_button", "save_button", "project_menu",
            "file_menu", "overlay_strip"]
end function

function side_panes()
    out = []
    out = append(out, { id: "branch", label: "Branches" })
    ' The results heading says what the pane is KEYED TO, not what it is: the
    ' body already opens with "Results — sec-N", so a heading reading "Results"
    ' put the word on two consecutive lines. Same wording as the GTK pane.
    out = append(out, { id: "results", label: "For the section at the cursor" })
    out = append(out, { id: "tables", label: "Tables" })
    out = append(out, { id: "git", label: "Git" })
    out = append(out, { id: "agent", label: "Assistant" })
    return out
end function

end library
