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
function show_tree(node, depth)
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
    slot = "\"" + node.label + "\""
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
      z = show_tree(child, depth + 1)
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
      print "  " + pad(here, 44) + join(shown, " ")
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
      if node.word != "split" then
        out = append(out, node.name)
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

' A pane report without its SIZES. The nesting is a fact about the record and
' is byte-stable; the pixels are not -- Qt re-proportions a splitter against
' its allocation, and upstream measured 260/540 of an 800-wide splitter coming
' back 252/522. §0.22's own rule: every check is a proportion or a difference.
function nesting(p)
  return p.kind + " " + p.direction + " pane " + string(p.index) + " of " + string(p.panes)
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
    z = show_tree(win, 0)

    print "== and every option in it =="
    z = show_options(win, "")

    print "== every name it declares =="
    print "  " + join(names_of(win, []), " ")

    print "== the title carries the marker, because a tab caption cannot =="
    print "  cold: " + studio_shell_qt.title_for(app)

    print "== pane sizes, one list per split, addressed by a part inside it =="
    for each p in studio_shell_qt.pane_sizes(app)
      print "  at " + pad(p.at, 14) + string(p.sizes)
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
    print "  (the caption is unchanged, which is the point: a Qt tab caption is"
    print "   fixed at construction, so the marker lives in the title)"
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
    print "  open:  " + string(qt.open(win))

    print "== what the window says about itself =="
    print "  title:   " + qt.read(win, studio_shell_qt.window_name(), "windowTitle")
    print "  tabs:    " + string(qt.read(win, studio_shell_qt.part_tabs(), "count"))
    print "  status:  " + qt.read(win, studio_shell_qt.part_status(), "text")

    print "== the browser, which is a table so its row count is free =="
    print "  heading: " + qt.heading(win, studio_shell_qt.part_browser(), 0)
    print "  rows:    " + string(qt.read(win, studio_shell_qt.part_browser(), "rowCount"))
    n = qt.read(win, studio_shell_qt.part_browser(), "rowCount")
    j = 0
    while j < n
      print "    [" + qt.cell(win, studio_shell_qt.part_browser(), j, "label") + "]"
      j = j + 1
    end while

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

    print "== the nesting, asked of the LAYOUT rather than of the record =="
    print "  browser: " + nesting(qt.pane(win, studio_shell_qt.part_browser() + "_scroll"))
    print "  editors: " + nesting(qt.pane(win, studio_shell_qt.part_tabs()))
    print "  console: " + nesting(qt.pane(win, studio_shell_qt.part_console()))
    print "  beside:  " + nesting(qt.pane(win, studio_shell_qt.part_beside()))

    print "== the editor round-trips the document =="
    doc = studio_docs.active_doc(app.dm)
    ed = studio_shell_qt.part_editor(doc.id)
    z = qt.write(win, ed, doc.content)
    print "  " + ed + ": [" + replace(qt.read(win, ed, "plainText"), chr(10), " / ") + "]"
    ' The syntax definition's PATH is a fact about the machine -- a definition
    ' the user installed in their own home shadows the repository's and
    ' reports the identical name -- so only the language is asserted.
    print "  highlighted as: " + qt.highlighting(win, ed).language

    print "== and every split takes the sizes the session asked for =="
    for each p in studio_shell_qt.pane_sizes(app)
      print "  " + pad(p.at, 14) + string(qt.resize_panes(win, p.at, p.sizes))
    end for

    z = qt.close(win)
    print "== closed, and every verb then refuses by name =="
    print "  is_open: " + string(qt.is_open(win))
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
