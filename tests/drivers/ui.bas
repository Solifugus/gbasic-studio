' STU-2B headless driver for the interaction INTENT layer (studio_ui).
'
' Every interaction the shell wires is decided by a function in studio_ui, so this
' driver drives the interactions themselves — not a widget, and not a mock of one.
' A handler adds only "read the row index off the GtkListBoxRow", which the display
' tier covers with a real synthesised signal; everything a click MEANS is asserted
' here, headlessly, with no GTK and no display.
'
' args: mode home projdir. Output is path-free (only basenames are ever printed),
' so the goldens are byte-stable against a throwaway home.

function banner(title)
  print "== " + title + " =="
end function

function show(app)
  print studio_ui.summary(app)
end function

' Report an intent result compactly, then the state it produced. A detail may
' carry a filesystem path (the directory a dir-row toggled), and the goldens must
' stay path-free, so every "/"-bearing token is reduced to its last segment.
function safe_detail(detail)
  out = []
  for each tok in split(detail, " ")
    ' `contains` is array-only in gBASIC; substring search is `find`, which
    ' returns `nothing` (not -1) for a string miss — so the natural
    ' `find(s, x) >= 0` raises and the test must be against `nothing`.
    hit = find(tok, "/")
    seg = tok
    if hit != nothing then
      parts = split(tok, "/")
      seg = parts[count(parts) - 1]
    end if
    out = append(out, seg)
  end for
  return join(out, " ")
end function

function act(label, r)
  line = "-> " + label + ": " + r.action
  d = safe_detail(r.detail)
  if d != "" then
    line = line + " " + d
  end if
  print line
  return r.app
end function

' Poll an in-flight run to completion, exactly as the GTK timer does — the only
' difference is that nothing here waits between ticks.
function drive(app)
  r = studio_ui.tick_run(app)
  app = r.app
  while r.active
    r = studio_ui.tick_run(app)
    app = r.app
  end while
  print "   " + studio_ui.exec_summary(app)
  return app
end function

' Index of the first nav row whose kind matches and whose label ends with `suffix`.
' Tests address rows the way a user does — by what they see — so an index shift
' shows up as a changed action rather than a silently different row.
function row_index(rows, kind, suffix)
  i = 0
  while i < count(rows)
    r = rows[i]
    if r.kind = kind then
      lab = r.label
      tail = mid(lab, len(lab) - len(suffix), len(suffix))
      if tail = suffix then
        return i
      end if
    end if
    i = i + 1
  end while
  return -1
end function

program main(args)
  load persist
  load filetree
  load studio_model
  load studio_docs
  load studio
  load studio_ui

  mode = args[0]
  home = args[1]
  projdir = ""
  if count(args) > 2 then
    projdir = args[2]
  end if

  ' ---- the standard fixture: one workspace, one project over projdir --------
  ' The cold-start modes build their own state, because what they are testing IS
  ' what happens with no workspace open.
  fixture = true
  if mode = "newproj" then
    fixture = false
  end if
  if mode = "adopt" then
    fixture = false
  end if
  if mode = "show" then
    fixture = false
  end if
  if fixture then
    app = studio.launch(home)
    app = studio.create_registered_workspace(app, "ws")
    ws = app.model.workspace
    ws = studio_model.add_project(ws, "Alpha", projdir)
    app = studio.set_workspace(app, ws)
  end if

  ' ---- rows: the browser row model the renderer and dispatcher share --------
  if mode = "rows" then
    banner("initial rows")
    show(app)

    banner("a second project, and it becomes active")
    ws = app.model.workspace
    ws = studio_model.add_project(ws, "Beta", projdir + "/ghost")
    ws = studio_model.set_active_project(ws, "proj-2")
    app = studio.set_workspace(app, ws)
    show(app)
  end if

  ' ---- open: THE vertical slice, headless half -----------------------------
  ' click a browser row -> the document opens -> a tab appears -> that tab is
  ' the active document in the model.
  if mode = "open" then
    banner("before: no tabs")
    show(app)

    rows = studio_ui.nav_rows(app)
    i = row_index(rows, "file", "main.bas")
    print "main.bas is row " + i
    r = studio_ui.activate_row(app, rows, i)
    app = act("activate main.bas", r)
    banner("after: one tab, active")
    show(app)

    banner("a second file opens a second tab and takes activation")
    rows = studio_ui.nav_rows(app)
    i = row_index(rows, "file", "README.md")
    r = studio_ui.activate_row(app, rows, i)
    app = act("activate README.md", r)
    show(app)

    banner("re-activating an open file reuses its tab rather than duplicating it")
    rows = studio_ui.nav_rows(app)
    i = row_index(rows, "file", "main.bas")
    r = studio_ui.activate_row(app, rows, i)
    app = act("activate main.bas again", r)
    show(app)
  end if

  ' ---- expand: a directory row toggles, and the rows around it move ---------
  if mode = "expand" then
    rows = studio_ui.nav_rows(app)
    i = row_index(rows, "dir", "src")
    print "src is row " + i
    r = studio_ui.activate_row(app, rows, i)
    app = act("activate src", r)
    banner("expanded")
    show(app)

    banner("collapse it again")
    rows = studio_ui.nav_rows(app)
    i = row_index(rows, "dir", "src")
    r = studio_ui.activate_row(app, rows, i)
    app = act("activate src again", r)
    show(app)
  end if

  ' ---- project: activating a project row reroots the tree ------------------
  if mode = "project" then
    ws = app.model.workspace
    ' Beta is rooted at Alpha's src/, so activating it visibly reroots the tree.
    ws = studio_model.add_project(ws, "Beta", projdir + "/src")
    app = studio.set_workspace(app, ws)
    banner("Alpha active")
    show(app)

    rows = studio_ui.nav_rows(app)
    i = row_index(rows, "project", "Beta")
    print "Beta is row " + i
    r = studio_ui.activate_row(app, rows, i)
    app = act("activate Beta", r)
    banner("Beta active — the tree below is Beta's")
    show(app)
  end if

  ' ---- bounds: rows that must do nothing, and indexes that do not exist ----
  if mode = "bounds" then
    rows = studio_ui.nav_rows(app)
    r = studio_ui.activate_row(app, rows, 0)
    app = act("row 0 (the workspace header)", r)
    r = studio_ui.activate_row(app, rows, -1)
    app = act("row -1", r)
    r = studio_ui.activate_row(app, rows, 9999)
    app = act("row 9999", r)
    r = studio_ui.activate_row(app, rows, count(rows))
    app = act("row count(rows)", r)
    banner("model untouched by every one of them")
    show(app)

    ' The same for tabs, with no document open at all.
    tabs = studio_ui.tab_rows(app)
    print "tab rows=" + count(tabs)
    r = studio_ui.select_tab(app, tabs, 0)
    app = act("select tab 0 with nothing open", r)
    r = studio_ui.select_tab(app, tabs, -1)
    app = act("select tab -1", r)
  end if

  ' ---- tabs: switching the active document ---------------------------------
  if mode = "tabs" then
    rows = studio_ui.nav_rows(app)
    r = studio_ui.activate_row(app, rows, row_index(rows, "file", "main.bas"))
    app = r.app
    rows = studio_ui.nav_rows(app)
    r = studio_ui.activate_row(app, rows, row_index(rows, "file", "README.md"))
    app = r.app
    banner("two tabs, the second active")
    show(app)

    tabs = studio_ui.tab_rows(app)
    r = studio_ui.select_tab(app, tabs, 0)
    app = act("select page 0", r)
    show(app)

    r = studio_ui.select_tab(app, tabs, 1)
    app = act("select page 1", r)
    show(app)
  end if

  ' ---- edit: buffer text -> document dirty --------------------------------
  if mode = "edit" then
    rows = studio_ui.nav_rows(app)
    r = studio_ui.activate_row(app, rows, row_index(rows, "file", "main.bas"))
    app = r.app
    d = studio_docs.active_doc(app.dm)
    id = d.id
    original = d.content
    banner("opened clean")
    show(app)

    r = studio_ui.apply_edit(app, id, "edited by the user\n")
    app = act("apply_edit (new text)", r)
    show(app)

    r = studio_ui.apply_edit(app, id, "edited by the user\n")
    app = act("apply_edit (identical text, a redundant signal)", r)
    show(app)

    r = studio_ui.apply_edit(app, id, original)
    app = act("apply_edit (typed back to the saved text)", r)
    show(app)

    ' GtkTextBuffer emits "changed" twice for a programmatic set_text (delete then
    ' insert), and the first fire sees an EMPTY buffer. The empty state must be an
    ' ordinary edit, not a crash and not a lost document.
    r = studio_ui.apply_edit(app, id, "")
    app = act("apply_edit (empty — the mid-set_text fire)", r)
    r = studio_ui.apply_edit(app, id, original)
    app = act("apply_edit (the settled text)", r)
    show(app)

    r = studio_ui.apply_edit(app, "doc-999", "text for a document that is gone")
    app = act("apply_edit on a closed document", r)
  end if

  ' ---- save ----------------------------------------------------------------
  if mode = "save" then
    r = studio_ui.save_active(app)
    app = act("save with nothing open", r)

    rows = studio_ui.nav_rows(app)
    r = studio_ui.activate_row(app, rows, row_index(rows, "file", "main.bas"))
    app = r.app
    d = studio_docs.active_doc(app.dm)
    r = studio_ui.apply_edit(app, d.id, "saved through the Save button\n")
    app = act("edit", r)
    show(app)

    r = studio_ui.save_active(app)
    app = act("save", r)
    banner("clean again, and the tab marker is gone")
    show(app)

    f(file) = projdir + "/main.bas"
    print "on disk: " + read(f)
  end if

  ' ---- newproj: the cold-home path -----------------------------------------
  if mode = "newproj" then
    app = studio.launch(home)
    banner("a cold home — this is what a user actually starts with")
    show(app)

    r = studio_ui.new_project(app, home)
    app = act("New Project", r)
    banner("a workspace and a project now exist, and the browser is live")
    show(app)
    ' The directory must be real: a project whose path does not exist scans to an
    ' empty browser and is indistinguishable from a broken one.
    ws = app.model.workspace
    p1 = studio_model.project_by_id(ws, ws.active_project)
    pd(file) = p1.path
    print "project dir created=" + exists(pd)
    print "project dir leaf=" + studio_ui._leaf(p1.path)

    r = studio_ui.new_project(app, home)
    app = act("New Project again", r)
    show(app)
  end if

  ' ---- show: open a home and print what is in it ---------------------------
  ' Used by the display tier to reopen the home the GUI just closed, which is the
  ' only way to prove from outside the process that closing the window saved it.
  if mode = "show" then
    app = studio.launch(home)
    show(app)
  end if

  ' ---- newfile: STU-2C's reason for existing -------------------------------
  ' New Project made an empty directory and there was no way to put anything in
  ' it, so a cold start dead-ended after one click. This is the way out.
  if mode = "newfile" then
    banner("before")
    show(app)

    r = studio_ui.new_file(app, "")
    app = act("New File", r)
    banner("created at the project root, selected, and already open to type in")
    show(app)

    r = studio_ui.new_file(app, "")
    app = act("New File again — the name does not collide", r)
    show(app)

    ' The target follows the browser selection, so clicking a directory first is
    ' how you choose where the file goes.
    rows = studio_ui.nav_rows(app)
    r = studio_ui.activate_row(app, rows, row_index(rows, "dir", "src"))
    app = act("activate src", r)
    r = studio_ui.new_file(app, "")
    app = act("New File", r)
    banner("inside src, which the creation expanded so the row is visible")
    show(app)

    ' A FILE selection targets the directory holding it, not the file.
    rows = studio_ui.nav_rows(app)
    r = studio_ui.activate_row(app, rows, row_index(rows, "file", "a.bas"))
    app = act("activate src/a.bas", r)
    r = studio_ui.new_file(app, "")
    app = act("New File with a file selected", r)
    show(app)

    ' With nothing open there is nowhere to create, and saying so beats writing
    ' a file into whatever directory happened to be current.
    cold = studio.launch(home + "/cold")
    rc = studio_ui.new_file(cold, "")
    print "-> New File with no workspace: " + rc.action
  end if

  ' ---- newfolder -----------------------------------------------------------
  if mode = "newfolder" then
    r = studio_ui.new_folder(app, "")
    app = act("New Folder", r)
    banner("a sibling of the project's own files, and the selection has not moved")
    show(app)

    ' Because the selection did not move, a second click makes a SIBLING. A new
    ' folder that stole the selection would nest each click inside the last.
    r = studio_ui.new_folder(app, "")
    app = act("New Folder again", r)
    show(app)

    rows = studio_ui.nav_rows(app)
    r = studio_ui.activate_row(app, rows, row_index(rows, "dir", "new-folder-1"))
    app = act("activate new-folder-1", r)
    r = studio_ui.new_file(app, "")
    app = act("New File", r)
    banner("clicking the folder first is what puts the file inside it")
    show(app)
  end if

  ' ---- adopt: an existing directory becomes a project ----------------------
  if mode = "adopt" then
    app = studio.launch(home)
    banner("a cold home")
    show(app)

    r = studio_ui.adopt_folder(app, projdir)
    app = act("Open Folder", r)
    banner("the folder is a project now, named after itself, and browsable")
    show(app)

    r = studio_ui.adopt_folder(app, projdir)
    app = act("Open Folder on the folder already open", r)
    banner("activated rather than duplicated")
    show(app)

    ' The path arrives however it was typed at a shell, and two spellings of one
    ' directory must not become two projects.
    r = studio_ui.adopt_folder(app, projdir + "/")
    app = act("Open Folder, trailing slash", r)
    r = studio_ui.adopt_folder(app, projdir + "/src/..")
    app = act("Open Folder, by way of a subdirectory", r)
    print "projects=" + count(app.model.workspace.projects)

    r = studio_ui.adopt_folder(app, projdir + "/nowhere")
    app = act("Open Folder on a path that is not there", r)
    r = studio_ui.adopt_folder(app, projdir + "/main.bas")
    app = act("Open Folder on a file", r)
    r = studio_ui.adopt_folder(app, "")
    app = act("Open Folder on an empty path", r)
    banner("untouched by all three")
    show(app)
  end if

  ' ---- names: the header's name field feeding creation ---------------------
  if mode = "names" then
    print "empty     -> " + studio_ui.name_problem("")
    print "hello.bas -> [" + studio_ui.name_problem("hello.bas") + "]"
    print "a/b.bas   -> " + studio_ui.name_problem("a/b.bas")
    print "..        -> " + studio_ui.name_problem("..")
    print ".         -> " + studio_ui.name_problem(".")
    print "  spaces  -> " + studio_ui.name_problem("  ")

    r = studio_ui.new_file(app, "notes.bas")
    app = act("New File named notes.bas", r)
    show(app)

    ' A name already on disk is refused rather than truncating what is there.
    r = studio_ui.new_file(app, "notes.bas")
    app = act("New File named notes.bas again", r)
    r = studio_ui.new_file(app, "a/b.bas")
    app = act("New File named a/b.bas", r)
    r = studio_ui.new_folder(app, "vendor")
    app = act("New Folder named vendor", r)
    show(app)
  end if

  ' ---- rename --------------------------------------------------------------
  if mode = "rename" then
    rows = studio_ui.nav_rows(app)
    r = studio_ui.activate_row(app, rows, row_index(rows, "file", "main.bas"))
    app = act("activate main.bas", r)

    r = studio_ui.rename_selected(app, "")
    app = act("Rename to nothing", r)
    r = studio_ui.rename_selected(app, "sub/dir.bas")
    app = act("Rename with a separator in it", r)
    r = studio_ui.rename_selected(app, "README.md")
    app = act("Rename onto a name already taken", r)
    r = studio_ui.rename_selected(app, "main.bas")
    app = act("Rename to what it is already called", r)
    banner("nothing moved")
    show(app)

    r = studio_ui.rename_selected(app, "entry.bas")
    app = act("Rename to entry.bas", r)
    banner("the row, the selection AND the open tab follow it")
    show(app)

    ' An unsaved buffer is refused: renaming means closing and reopening the
    ' document, and that would throw the edits away.
    d = studio_docs.active_doc(app.dm)
    app = studio.edit_document(app, d.id, "half-typed\n")
    r = studio_ui.rename_selected(app, "renamed-while-dirty.bas")
    app = act("Rename an unsaved document", r)
    show(app)

    ' A directory renames too, and the expansion state comes with it.
    sv = studio_ui.save_active(app)
    app = sv.app
    rows = studio_ui.nav_rows(app)
    r = studio_ui.activate_row(app, rows, row_index(rows, "dir", "src"))
    app = act("activate src (expanding it)", r)
    r = studio_ui.rename_selected(app, "source")
    app = act("Rename src to source", r)
    banner("still expanded, under its new name")
    show(app)

    ' ...unless something inside it is open, which a rename would strand.
    rows = studio_ui.nav_rows(app)
    r = studio_ui.activate_row(app, rows, row_index(rows, "file", "a.bas"))
    app = r.app
    rows = studio_ui.nav_rows(app)
    r = studio_ui.activate_row(app, rows, row_index(rows, "dir", "source"))
    app = r.app
    r = studio_ui.rename_selected(app, "src")
    app = act("Rename a directory with an open document inside it", r)

    r = studio_ui.rename_selected(app, "docs")
    app = act("Rename onto a directory that exists", r)
  end if

  ' ---- delete: two clicks, never one --------------------------------------
  if mode = "delete" then
    rows = studio_ui.nav_rows(app)
    r = studio_ui.activate_row(app, rows, row_index(rows, "file", "README.md"))
    app = r.app

    armed = ""
    r = studio_ui.delete_selected(app, armed)
    app = act("Delete (first click)", r)
    armed = r.armed
    print "armed=" + studio_ui._leaf(armed)
    banner("nothing is gone yet")
    show(app)

    r = studio_ui.delete_selected(app, armed)
    app = act("Delete (second click)", r)
    armed = r.armed
    print "armed=[" + studio_ui._leaf(armed) + "]"
    banner("gone, and its tab with it")
    show(app)

    ' Arming is keyed to the path, so moving the selection between the two
    ' clicks re-arms on the new row instead of deleting it.
    rows = studio_ui.nav_rows(app)
    r = studio_ui.activate_row(app, rows, row_index(rows, "file", "main.bas"))
    app = r.app
    r = studio_ui.delete_selected(app, armed)
    app = act("Delete main.bas (first click)", r)
    armed = r.armed
    rows = studio_ui.nav_rows(app)
    r = studio_ui.activate_row(app, rows, row_index(rows, "dir", "docs"))
    app = r.app
    r = studio_ui.delete_selected(app, armed)
    app = act("Delete after clicking a different row", r)
    armed = r.armed
    banner("main.bas is still here")
    show(app)

    ' A directory with anything in it is refused: recursive deletion needs a real
    ' confirmation, not a second click on the same button.
    r = studio_ui.delete_selected(app, armed)
    app = act("Delete docs (confirmed)", r)
    armed = r.armed

    rows = studio_ui.nav_rows(app)
    r = studio_ui.activate_row(app, rows, row_index(rows, "dir", "docs"))
    app = r.app
    e(file) = projdir + "/docs/guide.md"
    delete(e)
    r = studio_ui.delete_selected(app, "")
    app = act("Delete the now-empty docs (first click)", r)
    r = studio_ui.delete_selected(app, r.armed)
    app = act("Delete the now-empty docs (second click)", r)
    show(app)
  end if

  ' ---- closetab ------------------------------------------------------------
  if mode = "closetab" then
    r = studio_ui.close_active(app, "")
    app = act("Close with nothing open", r)

    rows = studio_ui.nav_rows(app)
    r = studio_ui.activate_row(app, rows, row_index(rows, "file", "main.bas"))
    app = r.app
    rows = studio_ui.nav_rows(app)
    r = studio_ui.activate_row(app, rows, row_index(rows, "file", "README.md"))
    app = r.app
    banner("two tabs")
    show(app)

    r = studio_ui.close_active(app, "")
    app = act("Close a clean tab", r)
    banner("closed on the first click, because nothing was at stake")
    show(app)

    d = studio_docs.active_doc(app.dm)
    app = studio.edit_document(app, d.id, "typed and not saved\n")
    r = studio_ui.close_active(app, "")
    app = act("Close an unsaved tab (first click)", r)
    armed = r.armed
    banner("still open")
    show(app)

    r = studio_ui.close_active(app, armed)
    app = act("Close an unsaved tab (second click)", r)
    banner("discarded")
    show(app)
  end if

  ' ---- run: the execution strip, driven exactly as the shell drives it ------
  ' Run, then poll until the machine leaves an active state — the same loop the
  ' GTK timer runs, minus the timer. A real child interpreter really runs.
  if mode = "run" then
    ' Written here rather than added to the shared fixture: a new file in
    ' mkproj_ui would put a new row in every other ui_* golden.
    ' Three sections, so a run of the last one replays the two before it.
    rf(file) = projdir + "/runme.bas"
    write(rf, "print \"one\"\n\nfunction add(a, b)\n  return a + b\nend function\n\nprint add(2, 3)\n")

    rows = studio_ui.nav_rows(app)
    r = studio_ui.activate_row(app, rows, row_index(rows, "file", "runme.bas"))
    app = r.app
    ' Pinning the clock is what lets a result's timestamps sit in a golden.
    app.clock_fixed = 1000

    ' The caret is synced first because that is what the window does: Run READS
    ' the caret, and the panes are keyed to it. A run without a caret there would
    ' assert a state a user can never be in.
    id = studio_docs.active_doc(app.dm).id
    print "-> Run with the cursor at the top (line 0)"
    r = studio_ui.sync_cursor(app, id, 0, 0)
    app = r.app
    r = studio_ui.run_section(app, 0, 0)
    app = r.app
    print "   action=" + r.action + " active=" + r.active
    app = drive(app)

    print "-> Run with the cursor in the last section"
    r = studio_ui.sync_cursor(app, id, 6, 0)
    app = r.app
    r = studio_ui.run_section(app, 6, 0)
    app = r.app
    print "   action=" + r.action + " active=" + r.active
    app = drive(app)

    banner("prefix and target output are kept apart")
    sess = studio_ui.exec_session(app)
    print "prefix=<" + studio_ui.prefix_text(sess) + ">"
    print "target=<" + studio_ui.target_text(sess) + ">"
    banner("and the run is now a durable result")
    print studio_ui.results_body(app)

    ' A second run of the same section adds to the history rather than replacing it.
    r = studio_ui.sync_cursor(app, id, 6, 0)
    app = r.app
    r = studio_ui.run_section(app, 6, 0)
    app = r.app
    app = drive(app)
    print studio_ui.results_body(app)
  end if

  ' ---- cursor: the panes follow the caret, not the last run ----------------
  if mode = "cursor" then
    cf(file) = projdir + "/three.bas"
    write(cf, "print \"one\"\n\nfunction add(a, b)\n  return a + b\nend function\n\nprint add(2, 3)\n")
    rows = studio_ui.nav_rows(app)
    r = studio_ui.activate_row(app, rows, row_index(rows, "file", "three.bas"))
    app = r.app
    app.clock_fixed = 1000
    id = studio_docs.active_doc(app.dm).id

    banner("which section each caret position is in (editor 0-based lines)")
    l = 0
    while l < 8
      r = studio_ui.sync_cursor(app, id, l, 0)
      app = r.app
      print "  line " + l + " -> " + r.detail + "   | " + studio_ui.section_label(app)
      l = l + 1
    end while

    banner("nothing has run, so every section says so")
    r = studio_ui.sync_cursor(app, id, 0, 0)
    app = r.app
    print studio_ui.results_body(app)

    ' Put the caret where the run is going to happen, which is what pressing Run
    ' in the window means — Run reads the caret and does not move it.
    banner("run the LAST section, with the caret in it")
    r = studio_ui.sync_cursor(app, id, 6, 0)
    app = r.app
    r = studio_ui.run_section(app, 6, 0)
    app = r.app
    app = drive(app)

    banner("the caret has not moved, so the pane shows that section's result")
    print studio_ui.results_body(app)

    banner("move the caret up to the first section — the pane follows")
    r = studio_ui.sync_cursor(app, id, 0, 0)
    app = r.app
    print studio_ui.results_body(app)

    ' Editing the section a result describes must show up as a mark, and that
    ' means the pane's section model has to be re-derived from the new text.
    banner("edit the run section; its id survives but its fingerprint does not")
    app = studio.edit_document(app, id, "print \"one\"\n\nfunction add(a, b)\n  return a + b\nend function\n\nprint add(2, 4)\n")
    r = studio_ui.sync_cursor(app, id, 6, 0)
    app = r.app
    print studio_ui.results_body(app)

    ' A caret in a document with nothing runnable in it at all.
    banner("an empty document")
    ef(file) = projdir + "/empty.bas"
    write(ef, "")
    rows = studio_ui.nav_rows(app)
    r = studio_ui.activate_row(app, rows, row_index(rows, "file", "empty.bas"))
    app = r.app
    print studio_ui.section_label(app)
    print studio_ui.results_body(app)
  end if

  ' ---- runstop: refusal, stopping, and the states around a run -------------
  if mode = "runstop" then
    print "-> Run with nothing open: " + studio_ui.run_section(app, 0, 0).action
    print "-> Stop with nothing running: " + studio_ui.stop_run(app).action
    print "-> Force Stop with nothing running: " + studio_ui.force_stop_run(app).action
    print "-> a tick with nothing running: " + studio_ui.tick_run(app).action

    ' Never ends on its own, so only a stop can finish it.
    lf(file) = projdir + "/loop.bas"
    write(lf, "print \"started\"\n\nwhile true\n  sleep(0.05)\nend while\n")

    rows = studio_ui.nav_rows(app)
    r = studio_ui.activate_row(app, rows, row_index(rows, "file", "loop.bas"))
    app = r.app
    app.clock_fixed = 1000

    ' loop.bas never ends on its own, so only a stop can finish it.
    r = studio_ui.run_section(app, 0, 0)
    app = r.app
    print "-> Run: action=" + r.action + " active=" + r.active

    ' A second Run while one is in flight is refused rather than queued or
    ' silently dropped — two children writing the same scratch prefix is not a
    ' thing to find out about later.
    r2 = studio_ui.run_section(app, 0, 0)
    print "-> Run again while it is running: " + r2.action + " (" + r2.detail + ")"

    r = studio_ui.stop_run(app)
    app = r.app
    print "-> Stop: action=" + r.action
    app = drive(app)
    sess = studio_ui.exec_session(app)
    print "state=" + sess.state + " signalled=" + (sess.signal != 0)
    print studio_ui.exec_summary(app)
  end if

  ' ---- notice: what the status bar says about each outcome -----------------
  ' Every action the shell can produce has to say something, or a refusal looks
  ' exactly like a button that is not wired.
  if mode = "notice" then
    ' An array literal may span lines; `+` on two arrays raises, so this is one
    ' literal rather than a few concatenated groups.
    actions = ["open", "expand", "collapse", "project", "none", "out-of-range",
               "created", "renamed", "deleted", "closed", "saved", "error",
               "armed", "armed-close", "invalid", "exists", "unchanged",
               "missing", "not-empty", "dirty", "in-use", "adopted",
               "activated", "refreshed", "select", "synced", "unknown"]
    for each a in actions
      print a + " | " + studio_ui.action_notice(a, "thing.bas")
    end for
    print "arm kinds: " + studio_ui.arm_kind("armed") + " " + studio_ui.arm_kind("armed-close") + " [" + studio_ui.arm_kind("open") + "]"
    print "clears the name field: " + studio_ui.clears_name("created") + " " + studio_ui.clears_name("renamed") + " " + studio_ui.clears_name("open")
  end if

  ' ---- exit: what gui mode now does when the window closes -----------------
  ' The GTK loop returning is not a test hook, but everything it triggers is an
  ' ordinary function call, so the sequence is asserted here and the display tier
  ' only has to prove the loop actually reaches it.
  if mode = "exit" then
    rows = studio_ui.nav_rows(app)
    r = studio_ui.activate_row(app, rows, row_index(rows, "file", "main.bas"))
    app = r.app
    print "dirty documents: " + studio_ui.dirty_count(app)
    app = studio.edit_document(app, "doc-1", "unsaved when the window closed\n")
    print "dirty documents after typing: " + studio_ui.dirty_count(app)

    saved = studio.persist(app)
    print "saved=" + join(saved, ",")

    banner("relaunching the same home")
    again = studio.launch(home)
    show(again)
    ' The KNOWN limitation, pinned rather than hidden: the tab comes back, the
    ' unsaved text does not. Studio has no draft store, so what closing preserves
    ' is which documents were open, not what was typed into them.
    d = studio_docs.doc_by_id(again.dm, "doc-1")
    print "doc-1 content after restart=" + d.content
  end if

  ' ---- refresh -------------------------------------------------------------
  if mode = "refresh" then
    rows = studio_ui.nav_rows(app)
    r = studio_ui.activate_row(app, rows, row_index(rows, "file", "main.bas"))
    app = r.app
    rows = studio_ui.nav_rows(app)
    r = studio_ui.activate_row(app, rows, row_index(rows, "file", "README.md"))
    app = r.app
    banner("two tabs open")
    show(app)

    ' main.bas: clean here, changed on disk -> reloads.
    ' README.md: dirty here, changed on disk -> a conflict, buffer preserved.
    a(file) = projdir + "/main.bas"
    write(a, "changed on disk while Studio was clean\n")
    b(file) = projdir + "/README.md"
    write(b, "changed on disk while Studio was dirty\n")
    app = studio.edit_document(app, "doc-2", "my unsaved edits\n")

    r = studio_ui.refresh(app)
    app = act("Refresh", r)
    show(app)
    d1 = studio_docs.doc_by_id(app.dm, "doc-1")
    print "doc-1 content=" + d1.content
    d2 = studio_docs.doc_by_id(app.dm, "doc-2")
    print "doc-2 content=" + d2.content
    print "doc-2 external=" + d2.external
  end if
end program
