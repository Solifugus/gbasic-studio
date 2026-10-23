' SPDX-License-Identifier: Apache-2.0
' Copyright 2026 Matthew C. Tedder. See LICENSE.

' Headless driver for Studio's window as DATA (studio_shell_qt).
'
' THIS IS THE TIER GTK NEVER ALLOWED. `studio_shell.build` decides what the
' window is while it constructs a hundred widgets, so the only way to assert
' the layout was to open one — which is why every `ui_gui*` tier SKIPs without
' a display, and why those tiers assert TEXT and nothing asserts STRUCTURE.
' CLAUDE.md's browser and run-strip sections are a list of what that costs.
'
' `studio_shell_qt.window_for` is a pure function to a record, so the shape is
' printable. The golden below holds the whole window — every container, every
' part, every name, in order — and a pane that moves, a name that changes or a
' tab that fails to appear moves the golden. No display, no Qt, no toolkit.
'
' args: mode home projdir

function pad(text, width)
  out = text
  while count(out) < width
    out = out + " "
  end while
  return out
end function

' One line per node: the nesting as indentation, then the word, then whatever
' the node carries in its one free slot (a name, a direction, or a caption).
function print_shape(node, depth)
  indent = ""
  i = 0
  while i < depth
    indent = indent + "  "
    i = i + 1
  end while

  word = "?"
  if has(node, "word") then
    word = node.word
  end if
  if node.kind = "window" then
    word = "window"
  end if

  slot = ""
  if has(node, "name") then
    slot = node.name
  end if
  if has(node, "label") then
    ' A DOCK CARRIES BOTH, and the name is the load-bearing half: Qt keys a
    ' saved layout by it, and a dock with none makes `saveState` warn and omit
    ' the pane. So both are printed rather than the caption winning -- a golden
    ' that showed only the caption could not see a dock losing its name.
    if slot != "" then
      slot = slot + " \"" + node.label + "\""
    else
      slot = "\"" + node.label + "\""
    end if
  end if

  line = indent + word
  if slot != "" then
    line = line + " " + slot
  end if
  ' A table says what it shows, because the subject is a NAME resolved out of
  ' the calling frame at open time and a typo in it is a run-time refusal.
  if has(node, "subject") then
    line = line + " to " + node.direction + " " + node.subject
  end if
  print line

  if has(node, "items") then
    for each child in node.items
      z = print_shape(child, depth + 1)
    end for
  end if
  return nothing
end function

' Every option every part carries, so a label, a shortcut and a checkable
' state are all in the golden. Sorted by part so the order is the record's.
function show_options(node, path)
  here = path
  if has(node, "name") then
    here = path + "/" + node.name
  end if
  if has(node, "options") then
    ks = keys(node.options)
    if count(ks) > 0 then
      shown = []
      for each k in sort(ks)
        v = node.options[k]
        shown = append(shown, k + "=" + string(v))
      end for
      print "  " + pad(here, 52) + join(shown, " ")
    end if
  end if
  if has(node, "items") then
    for each child in node.items
      z = show_options(child, here)
    end for
  end if
  return nothing
end function

' Every name the window declares, in order — which is also the set `qt.read`
' can address and so the renderer's whole vocabulary.
function names_of(node, acc)
  out = acc
  if node.kind != "window" then
    if has(node, "name") then
      ' A `split`'s slot is its DIRECTION and a `docks`' is its EDGE, so
      ' neither is a part name and neither registers as one -- the same
      ' exclusion for the same reason, found the second time by a dock area
      ' turning up in this list as though it were addressable.
      if node.word != "split" then
        if node.word != "docks" then
          out = append(out, node.name)
        end if
      end if
    end if
  end if
  if has(node, "word") then
    if node.word = "table" then
      ' A table's `items` are its COLUMNS, and a column is not a part: its
      ' name is the row FIELD each cell reads. Nothing addresses one.
      return out
    end if
  end if
  if has(node, "items") then
    for each child in node.items
      out = names_of(child, out)
    end for
  end if
  return out
end function

' The tab captions of a built window, found by walking to the `tabs`.
function tab_captions(node)
  out = []
  if has(node, "word") then
    if node.word = "tabs" then
      for each t in node.items
        out = append(out, t.label)
      end for
      return out
    end if
  end if
  if has(node, "items") then
    for each child in node.items
      found = tab_captions(child)
      if count(found) > 0 then
        return found
      end if
    end for
  end if
  return out
end function

' EVERY SUBJECT THE RECORD DECLARES has to exist in the frame that opens the
' window -- `qt.open` resolves a `table to show` by name out of that frame and
' refuses the whole window otherwise. There are two now (the browser's rows and
' the branch pane's), so this is a function rather than a line to forget.
function qt_branch_subject(app)
    out = []
    for each r in studio_ui.branch_rows(app).rows
        out = append(out, { line: studio_ui.branch_line(r) })
    end for
    return out
end function

' A pane report without its SIZES. The nesting is a fact about the record and
' is byte-stable; the pixels are not -- Qt re-proportions a splitter against
' its allocation, and upstream measured 260/540 of an 800-wide splitter coming
' back 252/522. §0.22's own rule: every check is a proportion or a difference.
' The `tabs` container's items, out of a built window -- which is exactly what
' `qt.refresh(win, name, items)` takes, so a redraw is "build the record again
' and hand over the part that changed".
function tabs_items(node)
  if has(node, "word") then
    if node.word = "tabs" then
      return node.items
    end if
  end if
  if has(node, "items") then
    for each c in node.items
      found = tabs_items(c)
      if count(found) > 0 then
        return found
      end if
    end for
  end if
  return []
end function

' Every dock the RECORD declares, with the edge of the area holding it.
function dock_areas(node, edge)
  out = []
  here = edge
  if has(node, "word") then
    if node.word = "docks" then
      here = node.name
    end if
    if node.word = "dock" then
      out = append(out, { name: node.name, edge: here })
    end if
  end if
  if has(node, "items") then
    for each c in node.items
      for each d in dock_areas(c, here)
        out = append(out, d)
      end for
    end for
  end if
  return out
end function

' A dock's EDGE and how many panes it shares it with.
'
' This replaced a `nesting` helper over `qt.pane`, because §0.30 turned the
' three splits into three dock AREAS and `qt.pane` now answers `unknown` for a
' part in no splitter -- which `nesting` met as a field access on a non-record.
' The check is the same KIND of check: ask the WINDOW where the thing ended up,
' never anything we remembered when it was built, because a pane in the wrong
' area is invisible from the language otherwise.
function docked(win, name)
  d = qt.dock(win, name)
  if is_unknown(d) then
    return "(not docked)"
  end if
  return d.area + ", tabbed with " + string(d.tabbed_with)
end function

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
  load studio_style
  load studio_shell_qt

  mode = args[0]
  home = args[1]
  projdir = args[2]

  app = studio.launch(home)
  app = studio.create_registered_workspace(app, "ws")
  ws = app.model.workspace
  ws = studio_model.add_project(ws, "Alpha", projdir)
  app = studio.set_workspace(app, ws)

  ' ---- shape: the window, with nothing open --------------------------------
  if mode = "shape" then
    print "== the window, cold =="
    win = studio_shell_qt.window_for(app)
    z = print_shape(win, 0)

    print "== and every option in it =="
    z = show_options(win, "")

    print "== every name it declares =="
    print "  " + join(names_of(win, []), " ")

    print "== the title carries the marker too, which is conventional =="
    print "  cold: " + studio_shell_qt.title_for(app)

    print "== and where the record puts each dock, before any window exists =="
    ' THE RECORD'S OWN ANSWER, which is the half a shape golden can assert:
    ' `qtshell_open` asks the WINDOW the same question through `qt.dock` and
    ' the two must agree. Either alone is weaker -- the record could declare an
    ' edge the backend ignores, and the window could report one the record
    ' never asked for.
    for each a in dock_areas(win, "")
      print "  " + pad(a.name, 16) + a.edge
    end for
  end if

  ' ---- docs: a document opens, and the record grows a tab ------------------
  if mode = "docs" then
    rows = studio_ui.nav_rows(app)
    i = 0
    at = 0 - 1
    for each r in rows
      if r.kind = "file" then
        if r.name = "main.bas" then
          at = i
        end if
      end if
      i = i + 1
    end for
    print "== with nothing open =="
    win = studio_shell_qt.window_for(app)
    print "  tabs: " + join(tab_captions(win), " | ")

    r = studio_ui.activate_row(app, rows, at)
    app = r.app
    print "== main.bas opened =="
    win = studio_shell_qt.window_for(app)
    print "  tabs:   " + join(tab_captions(win), " | ")
    print "  editor: " + studio_shell_qt.part_editor(studio_docs.active_doc(app.dm).id)
    print "  title:  " + studio_shell_qt.title_for(app)

    print "== and the same document with unsaved text =="
    doc = studio_docs.active_doc(app.dm)
    app.dm = studio_docs.edit(app.dm, doc.id, "program main(args)\n  print 2\nend program\n")
    win = studio_shell_qt.window_for(app)
    print "  tabs:   " + join(tab_captions(win), " | ")
    print "  title:  " + studio_shell_qt.title_for(app)
    print "  (the marker is in the CAPTION, which `qt.refresh` re-reads --"
    print "   so the tab is keyed on the document id, not on what it says)"
  end if

  ' ---- open: THE WINDOW, OPENED, with no display at all -------------------
  '
  ' This is what replaces the `ui_gui*` tiers, and it is strictly better than
  ' what it replaces: those need GTK 4 AND a display and skip without either,
  ' where `QT_QPA_PLATFORM=offscreen` needs no display and no compositor. So
  ' the window is really built, really read back, and really asked about its
  ' own layout -- on a machine with nothing on the screen.
  '
  ' What it asserts is what only an OPEN window can say: that the record
  ' builds, that the three splits nest the way the record nests them (asked of
  ' the LAYOUT, walking up from a part, which is the one check a remembered
  ' position would agree with while being wrong), that the browser's rows and
  ' headings arrived, that a menu's entries are what `studio_ui.menus` said,
  ' and that the editor round-trips the document's text.
  if mode = "open" then
    rows = studio_ui.nav_rows(app)
    i = 0
    at = 0 - 1
    for each r in rows
      if r.kind = "file" then
        if r.name = "main.bas" then
          at = i
        end if
      end if
      i = i + 1
    end for
    r = studio_ui.activate_row(app, rows, at)
    app = r.app

    win = studio_shell_qt.window_for(app)
    print "== it checks, and it opens =="
    print "  check: " + string(qt.check(win))
    ' THE SUBJECT IS READ FROM THIS FRAME. `qt.open` resolves the browser's
    ' rows by the NAME the record declares, so the variable has to be called
    ' exactly that -- which is why `studio_shell_qt.nav_subject()` exists
    ' rather than the string being written here and there.
    nav = studio_ui.nav_rows(app)
    branches = qt_branch_subject(app)
    tables = studio_shell_qt.table_subject(studio_ui.table_rows(app).rows)
    print "  open:  " + string(qt.open(win))

    print "== what the window says about itself =="
    print "  title:   " + qt.read(win, studio_shell_qt.window_name(), "windowTitle")
    print "  tabs:    " + string(qt.read(win, studio_shell_qt.part_tabs(), "count"))
    print "  status:  " + qt.read(win, studio_shell_qt.part_status(), "text")

    print "== the browser, which is a TREE with a depth the widget has =="
    print "  heading: " + qt.heading(win, studio_shell_qt.part_browser(), 0)
    ' THE DEPTH IS THE ORACLE. A populate that ignored it builds a flat tree
    ' whose every name, index, selection and heading reads back correctly, so
    ' nothing else here can see it -- and it is asked of the WIDGET, walked up
    ' the item's parents, rather than being the number the record carried.
    j = 0
    for each nr in nav
      print "    " + string(qt.depth(win, studio_shell_qt.part_browser(), j)) + " [" + qt.cell(win, studio_shell_qt.part_browser(), j, "text") + "]"
      j = j + 1
    end for

    print "== the menus are the toolkit's own now =="
    print "  bar:     " + string(qt.menus(win))
    k = 0
    for each m in studio_ui.menus()
      print "  " + m.label + ": " + string(qt.menus(win, k))
      k = k + 1
    end for
    print "  a separator has no caption, where an empty label would have one"

    print "== and a state item is CHECKABLE, not a glyph in its label =="
    for each a in ["theme-system", "theme-dark", "restore-session"]
      nm = studio_shell_qt.part_item(a)
      print "  " + nm + ": checkable=" + string(qt.read(win, nm, "checkable")) + " checked=" + string(qt.read(win, nm, "checked"))
    end for
    print "== the accelerators are the actions' own, not an event controller =="
    for each a in ["text-bigger", "text-smaller", "text-reset"]
      nm = studio_shell_qt.part_item(a)
      print "  " + nm + ": " + qt.read(win, nm, "shortcut")
    end for

    print "== the furniture, asked of the WINDOW rather than of the record =="
    print "  files:   " + docked(win, studio_shell_qt.part_browser_dock())
    print "  console: " + docked(win, studio_shell_qt.part_console_dock())
    for each sp in studio_shell_qt.side_panes()
      print "  " + pad(sp.id + ":", 9) + docked(win, studio_shell_qt.part_side_dock(sp.id))
    end for
    print "  and the editor is the CENTRAL widget, which is docked to nothing:"
    print "    tabs:  " + docked(win, studio_shell_qt.part_tabs())

    print "== the editor round-trips the document =="
    doc = studio_docs.active_doc(app.dm)
    ed = studio_shell_qt.part_editor(doc.id)
    z = qt.write(win, ed, doc.content)
    print "  " + ed + ": [" + replace(qt.read(win, ed, "plainText"), chr(10), " / ") + "]"
    ' The syntax definition's PATH is a fact about the machine -- a definition
    ' the user installed in their own home shadows the repository's and
    ' reports the identical name -- so only the language is asserted.
    print "  highlighted as: " + qt.highlighting(win, ed).language

    print "== and the whole arrangement saves and restores =="
    ' ONE OPAQUE BLOB, where the GTK shell stores three divider numbers: a
    ' QMainWindow saves which dock is at which edge, which are tabbed, which
    ' are closed or floating, and every size. Base64, because the blob is not
    ' valid UTF-8 and `session.json` is JSON.
    blob = qt.layout(win)
    print "  saved:    " + string(count(blob) > 0)
    print "  restored: " + string(qt.restore_layout(win, blob))
    print "  unknown:  " + string(qt.restore_layout(win, "bm90aGluZw==")) + " (reported, not raised)"

    z = qt.close(win)
    print "== closed, and every verb then refuses by name =="
    print "  is_open: " + string(qt.is_open(win))
  end if

  ' ---- reconcile: THE NOTEBOOK, which was the one blocking gap ------------
  '
  ' A container's set of children used to be fixed when the window opened, so a
  ' document opening meant a NEW WINDOW -- which cost per-document undo history
  ' and the window's position on screen. gBASIC built `qt.refresh(win, name,
  ' items)` for this (§0.27, from Studio's own measurements), and this tier is
  ' the consumer's half of it.
  '
  ' THE LOAD-BEARING CHECK IS THAT A KEPT EDITOR STILL HOLDS WHAT WAS TYPED
  ' INTO IT. Everything else here passes on a reconcile that is a rebuild
  ' dressed up: the captions would be right, the count would be right, and
  ' every unsaved buffer in the window would have been thrown away.
  if mode = "reconcile" then
    o = studio.open_from_browser(app, "proj-1", projdir + "/main.bas")
    app = o.app
    win = studio_shell_qt.window_for(app)
    nav = studio_ui.nav_rows(app)
    branches = qt_branch_subject(app)
    tables = studio_shell_qt.table_subject(studio_ui.table_rows(app).rows)
    print "== one document, and something typed into it =="
    print "  open:  " + string(qt.open(win))
    print "  tabs:  " + string(qt.tabs(win, studio_shell_qt.part_tabs()))
    d1 = studio_docs.active_doc(app.dm)
    ed1 = studio_shell_qt.part_editor(d1.id)
    z = qt.write(win, ed1, "typed by hand, never saved")
    print "  typed: [" + qt.read(win, ed1, "plainText") + "]"

    print "== a second document opens: the tab set GROWS =="
    o2 = studio.open_from_browser(app, "proj-1", projdir + "/README.md")
    app = o2.app
    print "  reconciled: " + string(qt.refresh(win, studio_shell_qt.part_tabs(), tabs_items(studio_shell_qt.window_for(app))))
    print "  tabs:  " + string(qt.tabs(win, studio_shell_qt.part_tabs()))
    print "  KEPT:  [" + qt.read(win, ed1, "plainText") + "]"

    print "== the first is edited: the CAPTION moves, the editor does not =="
    app.dm = studio_docs.edit(app.dm, d1.id, "edited in the model")
    z = qt.refresh(win, studio_shell_qt.part_tabs(), tabs_items(studio_shell_qt.window_for(app)))
    print "  tabs:  " + string(qt.tabs(win, studio_shell_qt.part_tabs()))
    print "  KEPT:  [" + qt.read(win, ed1, "plainText") + "]"
    print "  (the marker is in the caption, where the GTK notebook puts it --"
    print "   a reconcile re-reads it, and the tab is keyed on the document id)"

    print "== and the first closes: the tab set SHRINKS =="
    cl = studio_docs.close(app.dm, d1.id, "discard")
    app.dm = cl.dm
    z = qt.refresh(win, studio_shell_qt.part_tabs(), tabs_items(studio_shell_qt.window_for(app)))
    print "  tabs:  " + string(qt.tabs(win, studio_shell_qt.part_tabs()))

    print "== and reopening it mints a NEW document, so a new editor =="
    print "   (that a dropped widget is DELETED rather than hidden is gBASIC's"
    print "    own claim, held there by a source tripwire -- a widget nobody can"
    print "    name is unobservable from this side, which is why it has to be)"
    o3 = studio.open_from_browser(app, "proj-1", projdir + "/main.bas")
    app = o3.app
    z = qt.refresh(win, studio_shell_qt.part_tabs(), tabs_items(studio_shell_qt.window_for(app)))
    print "  tabs:  " + string(qt.tabs(win, studio_shell_qt.part_tabs()))
    back = studio_docs.active_doc(app.dm)
    print "  " + studio_shell_qt.part_editor(back.id) + ": [" + qt.read(win, studio_shell_qt.part_editor(back.id), "plainText") + "]"
    z = qt.close(win)
  end if

  ' ---- check: gBASIC's own validator, which needs no Qt and no display -----
  if mode = "check" then
    print "== qt.check on the cold window =="
    win = studio_shell_qt.window_for(app)
    print "  " + string(qt.check(win))

    rows = studio_ui.nav_rows(app)
    i = 0
    at = 0 - 1
    for each r in rows
      if r.kind = "file" then
        if r.name = "main.bas" then
          at = i
        end if
      end if
      i = i + 1
    end for
    r = studio_ui.activate_row(app, rows, at)
    app = r.app
    print "== and with a document open =="
    win = studio_shell_qt.window_for(app)
    print "  " + string(qt.check(win))
  end if
end program
