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
    ws = model.workspace

    items = []
    ' THE MENU BAR BELONGS TO THE WINDOW and not to a layout (§0.7): Qt would
    ' put a QMenuBar wherever the layout said, so a `menu` inside a `row`
    ' renders as a bar in the middle of the screen, and gBASIC refuses it at
    ' load time for that reason. So the menus go at the top level, before the
    ' body, and the header row below holds only what is genuinely a toolbar.
    for each spec in studio_ui.menus()
        items = append(items, studio_shell_qt._menu_for(app, spec))
    end for
    items = append(items, studio_shell_qt._body(app))

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
    if shortcut != "" then
        opts.shortcut = shortcut
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
    if action = "text-bigger" then
        return "Ctrl++"
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

' ---------------------------------------------------------------------------
' The body: header, the three splits, status bar.
' ---------------------------------------------------------------------------

function _body(app)
    rows = []
    rows = append(rows, studio_shell_qt._header(app))
    rows = append(rows, studio_shell_qt._main(app))
    rows = append(rows, part("text", studio_shell_qt.part_status(),
                             { label: studio_ui.status_text(app) }))
    return box("column", { margin: 0, spacing: 0 }, rows)
end function

' The header. Two menus and a button became three menus and a button at
' STU-16/STU-18, and the menus have left the row entirely now -- they belong to
' the window. What is left is the wordmark, the name field and Save, which is
' what a toolbar is for: the one verb pressed constantly, and the one field
' every naming action reads.
function _header(app)
    u = studio_style.unit()
    items = []
    items = append(items, part("text", "wordmark", { label: "gBASIC Studio" }))
    items = append(items, bare("separator"))
    ' STU-2D's name field, and the placeholder is still the only thing in the
    ' window that says Open Folder reads this as a PATH.
    items = append(items, part("field", studio_shell_qt.part_name_field(),
        { placeholderText: "name or path",
          toolTip: "A name for New File / New Folder / Rename, or a folder path for Open Folder (~ works). New Project asks for its own." }))
    items = append(items, part("button", studio_shell_qt.part_save(),
        { label: "Save",
          toolTip: "Write the active document to disk. Over a file that changed underneath, press twice — the first press arms it." }))
    ' The stretch is what keeps the three of them at the left instead of spread
    ' across the window. It takes no name, which gBASIC refuses rather than
    ' ignores.
    items = append(items, bare("stretch"))
    return box("row", { margin: u, spacing: u }, items)
end function

' browser | ( ( editors / console ) | right column )
'
' The same three nested splits the GTK shell has, in the same order, so a
' divider the user dragged under GTK means the same thing here. Under GTK they
' are `gtk.paned` and each holds exactly two children; a QSplitter holds any
' number, which is why pane sizes are a LIST upstream (§0.22) and why
' `pane_sizes` below answers one per split.
function _main(app)
    inner = splitter("down", [ studio_shell_qt._editors(app),
                            studio_shell_qt._console(app) ])
    right = splitter("across", [ inner, studio_shell_qt._beside(app) ])
    return splitter("across", [ studio_shell_qt._browser(app), right ])
end function

' The browser, which is a TABLE and not a column of labels.
'
' Three reasons, and the first is the one that decided it: a table is the only
' widget in this vocabulary whose row COUNT can change without rebuilding the
' window (`qt.refresh`, §0.11 -- written for this shape, the design doc says
' so by name). Expanding a directory is exactly that. Second, a table answers
' `qt.selected` and takes `qt.select`, which is the whole of the browser's
' selection model. Third, the right-click lands on a row rather than on a
' widget we had to find by scanning for a y -- `row.get_allocation()` RAISES
' through the GTK bridge, which is why `ui_gui_ctx` scans `get_row_at_y` at
' all.
'
' ONE COLUMN, carrying `studio_ui`'s own flat `label`. The indentation is two
' spaces per level inside that string, which is what `row_label` has always
' produced and what every golden addresses a row by. Under GTK the indent is a
' MARGIN and the glyph is a second label pinned to one character; a table cell
' has neither, so the flat rendering is the one that survives -- and it is the
' rendering the tests already hold.
function _browser(app)
    return named("scroll", studio_shell_qt.part_browser() + "_scroll", [
        show_table(studio_shell_qt.part_browser(), studio_shell_qt.nav_subject(),
                   [ column_of("label", "Files") ]) ])
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
            studio_shell_qt.part_page(r.doc_id), [
            box("column", { margin: 0, spacing: 0 }, [
                part("source", studio_shell_qt.part_editor(r.doc_id),
                     { language: "gBASIC" }) ]) ]))
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
    strip = box("row", { margin: 0, spacing: u }, [
        part("button", "run_btn", { label: "Run Section" }),
        part("button", "run_all_btn", { label: "Run All" }),
        part("button", "stop_btn", { label: "Stop" }),
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

' The right-hand column: branches, results, tables, git, the assistant.
'
' Each is a heading and a body, built once and shown or hidden -- the rule the
' GTK shell already follows, and it survives the move because `qt.set(win,
' name, "visible", false)` is the ordinary by-name route. A pane that is added
' and removed is a pane whose parent can be destroyed under a live window.
function _beside(app)
    u = studio_style.unit()
    panes = []
    for each p in studio_shell_qt.side_panes()
        panes = append(panes, part("text", p.id + "_head", { label: p.label }))
        panes = append(panes, part("memo", p.id + "_body", {}))
    end for
    panes = append(panes, bare("stretch"))
    return named("scroll", studio_shell_qt.part_beside(),
                 [ box("column", { margin: u, spacing: u }, panes) ])
end function

' The right column's vocabulary, in the order STU-8/9/11/10 put them. A closed
' list, so a pane cannot be added by a renderer that happens to know a name.
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

' ---------------------------------------------------------------------------
' Pane sizes.
'
' GTK's `position` is ONE number because a Gtk.Paned has exactly two children.
' A QSplitter holds any number, so `qt.resize_panes` takes a LIST (§0.22) -- and
' what is stored is a ratio in effect: measured upstream, asking 260/540 of an
' 800-wide splitter gives back 252/522, and a window resize re-proportions.
' A count mismatch is REFUSED rather than clamped, so these lists must be
' exactly two long, which is what keeps them honest about the three splits
' being two-pane each.
' ---------------------------------------------------------------------------

' What to hand `qt.resize_panes` for each split, keyed by a part INSIDE that
' split -- which is how a split is addressed at all, there being no name to
' look up. Read out of the session, guarded by `studio_model.pane_at` exactly
' as the GTK shell reads it, because this is JSON a user can hand-edit.
function pane_sizes(app)
    session = app.model.session
    w = session.window.width
    h = session.window.height
    browser = studio_model.pane_at(session, "browser", 260)
    right = studio_model.pane_at(session, "right", 620)
    console = studio_model.pane_at(session, "console", 380)

    ' EACH SPLIT IS ADDRESSED BY A PART THAT IS ONE OF ITS OWN PANES, because
    ' `splitter_of` stops at the NEAREST region (§0.22) -- so asking with the
    ' browser TABLE would find the scroll it sits in and resize nothing, and
    ' asking with a part in the console would find the vertical split rather
    ' than the horizontal one. Measured upstream both ways, with the control
    ' that a direct pane is still found.
    out = []
    ' The outer split: the browser against everything else. The scroll IS the
    ' pane, so it is what addresses this one.
    out = append(out, { at: studio_shell_qt.part_browser() + "_scroll",
                        sizes: [ browser, w - browser ] })
    ' The right split, whose own width is what the outer split left it -- not
    ' the window's. GTK's `rsplit.position` is measured from the rsplit's own
    ' left edge, so the number means the same thing in both toolkits.
    out = append(out, { at: studio_shell_qt.part_beside(),
                        sizes: [ right, (w - browser) - right ] })
    ' The vertical split, inside that. `book` is the tabs container, which is
    ' its first pane.
    out = append(out, { at: studio_shell_qt.part_tabs(),
                        sizes: [ console, h - console ] })
    return out
end function

end library
