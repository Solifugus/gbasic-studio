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

function read_file_text(p)
  f(file) = p
  return read(f)
end function

' `join` requires string elements, so a list of line numbers needs converting.
function numlist(nums)
  out = []
  for each n in nums
    out = append(out, string(n))
  end for
  return join(out, ",")
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
' STU-8: a row source's shape, minus the paths, which are temp directories.
function show_source(src)
  for each l in studio_table.summary(src)
    print l
  end for
end function

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
  load studio_table
  load studio_overlays
  load studio_drafts
  load studio_branches

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
    r = studio_ui.save_active(app, "")
    app = act("save with nothing open", r)

    rows = studio_ui.nav_rows(app)
    r = studio_ui.activate_row(app, rows, row_index(rows, "file", "main.bas"))
    app = r.app
    d = studio_docs.active_doc(app.dm)
    r = studio_ui.apply_edit(app, d.id, "saved through the Save button\n")
    app = act("edit", r)
    show(app)

    r = studio_ui.save_active(app, "")
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

    ' Switching the active project does NOT clear the browser selection, so the
    ' selection can point into the tree of the project you just left. A creation
    ' must still land in the project you are IN — otherwise the file sits in one
    ' project's folder while the workspace records it as another's.
    banner("the selection is in project one; the ACTIVE project is two")
    ws2 = app.model.workspace
    ws2 = studio_model.add_project(ws2, "Beta", projdir + "/docs")
    ws2 = studio_model.set_active_project(ws2, "proj-2")
    app = studio.set_workspace(app, ws2)
    print "selection still points at " + studio_ui._leaf(app.model.workspace.nav.selected_path)
    r = studio_ui.new_file(app, "")
    app = act("New File", r)
    print "landed under " + studio_ui._leaf(studio_docs._dirname(studio_docs.active_doc(app.dm).path))

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
    sv = studio_ui.save_active(app, "")
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
    write(rf, "print \"one\"\n\nfunction add(a, b)\n  return a + b\nend function\n\nsum = add(2, 3)\nprint sum\n")

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
    print "prefix=<" + studio_ui.prefix_body(app) + ">"
    print "target=<" + studio_ui.target_body(app) + ">"
    print "errors=<" + studio_ui.error_body(app) + ">"
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

  ' ---- overlay: code-overlay branches, end to end through the run path -----
  if mode = "overlay" then
    of(file) = projdir + "/overlaid.bas"
    write(of, "threshold = 0.5\n\nfunction score(t)\n  return t * 100\nend function\n\nprint \"score is \" + score(threshold)\n")
    rows = studio_ui.nav_rows(app)
    r = studio_ui.activate_row(app, rows, row_index(rows, "file", "overlaid.bas"))
    app = r.app
    app.clock_fixed = 1000
    id = studio_docs.active_doc(app.dm).id

    ' Everything the acceptance criterion is about: the file on disk must be
    ' byte-identical after running an overlay. Recorded before anything happens.
    before_size = file_size(of)
    before_text = read(of)

    banner("the baseline is the file itself, and cannot carry an overlay")
    r = studio_ui.sync_cursor(app, id, 6, 0)
    app = r.app
    b = studio_ui.begin_overlay(app)
    app = b.app
    print "action=" + b.action + " — " + b.detail

    banner("so: a branch at the top section, then an overlay below it")
    r = studio_ui.sync_cursor(app, id, 0, 0)
    app = r.app
    brows = studio_ui.branch_rows(app)
    app = brows.app
    r = studio_ui.activate_branch_row(app, brows.rows, count(brows.rows) - 1, "Robust")
    app = r.app
    print "action=" + r.action + " " + r.detail

    r = studio_ui.sync_cursor(app, id, 2, 0)
    app = r.app
    b = studio_ui.begin_overlay(app)
    app = b.app
    print "action=" + b.action + " on " + b.detail
    print "  an overlay opens as a COPY of what is there:"
    for each l in split(b.text, "\n")
      print "    |" + l
    end for

    banner("typing into it")
    r = studio_ui.save_overlay(app, "function score(t)\n  if t < 0 then\n    return 0\n  end if\n  return t * 1000\nend function")
    app = r.app
    print "action=" + r.action + " " + r.detail
    print "branch kind: " + studio_ui.branch_kind(app, studio_ui.active_branch(app).id)

    banner("and it is VISIBLY MARKED experimental (§9.2)")
    ' The selector shows the branches AT the caret's section, so this reads the
    ' point the branch hangs off — not the section the overlay changed, which is
    ' below it.
    r = studio_ui.sync_cursor(app, id, 0, 0)
    app = r.app
    brows3 = studio_ui.branch_rows(app)
    app = brows3.app
    for each row in brows3.rows
      mk = "  "
      if row.selected then
        mk = "* "
      end if
      print "  " + mk + row.label + studio_ui.overlay_mark(row)
    end for
    print "  " + studio_ui.branch_label(app)
    r = studio_ui.sync_cursor(app, id, 2, 0)
    app = r.app

    banner("the branch sees different source; the DOCUMENT does not")
    ps = studio_ui.projected_source(app)
    app = ps.app
    print "overlaid=" + string(ps.overlaid) + " applied=" + join(ps.applied, ",")
    print "document still says:"
    for each l in split(studio_docs.active_doc(app.dm).content, "\n")
      print "    |" + l
    end for

    banner("compare")
    d = studio_ui.overlay_diff(app)
    app = d.app
    for each l in d.lines
      print l
    end for

    banner("running the branch runs the OVERLAY")
    r = studio_ui.sync_cursor(app, id, 6, 0)
    app = r.app
    r = studio_ui.run_section(app, 6, 0)
    app = drive(r.app)
    print "target=<" + studio_ui.target_body(app) + ">"

    banner("and the canonical file on disk was never touched")
    after_size = file_size(of)
    after_text = read(of)
    print "  size unchanged:  " + string(after_size = before_size)
    print "  bytes unchanged: " + string(after_text = before_text)

    banner("an overlay survives a close and a relaunch")
    studio.persist(app)
    again = studio.launch(home)
    ov2 = studio_ui.overlays(again)
    print "edits restored: " + count(ov2.edits)
    for each e in ov2.edits
      print "  " + e.branch + " / " + e.section_id
    end for
    ' The branch tree comes back too, or the overlay would be addressed to a
    ' branch that no longer exists — which is why the two live in the same record.
    print "branches restored: " + count(studio_ui.branch_tree(again).branches)

    banner("the baseline still runs the file")
    brows2 = studio_ui.branch_rows(app)
    app = brows2.app
    r = studio_ui.sync_cursor(app, id, 0, 0)
    app = r.app
    brows2 = studio_ui.branch_rows(app)
    app = brows2.app
    r = studio_ui.activate_branch_row(app, brows2.rows, 0, "")
    app = r.app
    print "action=" + r.action
    r = studio_ui.sync_cursor(app, id, 6, 0)
    app = r.app
    r = studio_ui.run_section(app, 6, 0)
    app = drive(r.app)
    print "target=<" + studio_ui.target_body(app) + ">"
  end if

  ' ---- overlay_conflict: §9.3, the part that must not guess ----------------
  if mode = "overlay_conflict" then
    cf(file) = projdir + "/conflicted.bas"
    write(cf, "threshold = 0.5\n\nfunction score(t)\n  return t * 100\nend function\n\nprint \"score is \" + score(threshold)\n")
    rows = studio_ui.nav_rows(app)
    r = studio_ui.activate_row(app, rows, row_index(rows, "file", "conflicted.bas"))
    app = r.app
    app.clock_fixed = 1000
    id = studio_docs.active_doc(app.dm).id

    r = studio_ui.sync_cursor(app, id, 0, 0)
    app = r.app
    brows = studio_ui.branch_rows(app)
    app = brows.app
    r = studio_ui.activate_branch_row(app, brows.rows, count(brows.rows) - 1, "Robust")
    app = r.app
    r = studio_ui.sync_cursor(app, id, 2, 0)
    app = r.app
    b = studio_ui.begin_overlay(app)
    app = b.app
    r = studio_ui.save_overlay(app, "function score(t)\n  if t < 0 then\n    return 0\n  end if\n  return t * 1000\nend function")
    app = r.app

    banner("now the user edits the SAME section canonically")
    app.dm = studio_docs.edit(app.dm, id, "threshold = 0.5\n\nfunction score(t)\n  return t * 7\nend function\n\nprint \"score is \" + score(threshold)\n")
    c = studio_ui.overlay_conflicts(app)
    app = c.app
    for each p in c.problems
      print "  " + p.name + " / " + p.section_id + ": " + p.why + " — " + p.detail
    end for

    banner("promote is refused while it conflicts, and says what to do")
    r = studio_ui.promote_overlay(app)
    app = r.app
    print "action=" + r.action + " — " + r.detail

    banner("compare shows exactly what the overlay is shadowing")
    d = studio_ui.overlay_diff(app)
    app = d.app
    for each l in d.lines
      print l
    end for

    banner("rebase is the explicit act, and it does not claim to merge")
    r = studio_ui.rebase_overlay(app)
    app = r.app
    print "action=" + r.action + " — " + r.detail
    c2 = studio_ui.overlay_conflicts(app)
    app = c2.app
    print "conflicts now: " + count(c2.problems)

    banner("and now promote writes it into the document — as an unsaved edit")
    r = studio_ui.promote_overlay(app)
    app = r.app
    print "action=" + r.action + " — " + r.detail
    print "the document now reads:"
    for each l in split(studio_docs.active_doc(app.dm).content, "\n")
      print "    |" + l
    end for
    print "dirty (promote is an edit, not a save): " + string(studio_docs.is_dirty(studio_docs.active_doc(app.dm)))
    print "the file on disk still says:"
    for each l in split(read(cf), "\n")
      print "    |" + l
    end for
    print "overlay after promote: " + count(studio_overlays.for_branch(studio_ui.overlays(app), studio_ui.active_branch(app).id))

    ' The acceptance criterion's second half (§9.2/§18): once promoted and SAVED,
    ' the experiment is an ordinary working-tree edit — nothing about it is
    ' special any more, which is the point of promoting it.
    banner("Save turns it into an ordinary working-tree edit")
    r = studio_ui.save_active(app, "")
    app = r.app
    print "action=" + r.action + " " + r.detail
    on_disk = read(cf)
    print "the file on disk now says:"
    for each l in split(on_disk, "\n")
      print "    |" + l
    end for
    buffered = studio_docs.active_doc(app.dm).content
    print "buffer and file agree: " + string(on_disk = buffered)
    print "dirty: " + string(studio_docs.is_dirty(studio_docs.active_doc(app.dm)))
  end if

  ' ---- table: the tabular tier, end to end through the run path ------------
  if mode = "table" then
    tf(file) = projdir + "/table.bas"
    write(tf, "rows = []\nn = 0\nwhile n < 1200\n  rows = append(rows, { id: n, name: \"row \" + n, score: n * 1.5 })\n  n = n + 1\nend while\ntotal = count(rows)\n")
    rows = studio_ui.nav_rows(app)
    r = studio_ui.activate_row(app, rows, row_index(rows, "file", "table.bas"))
    app = r.app
    app.clock_fixed = 1000
    id = studio_docs.active_doc(app.dm).id
    r = studio_ui.sync_cursor(app, id, 0, 0)
    app = r.app

    banner("nothing has run, so there is nothing to offer")
    t = studio_ui.table_rows(app)
    app = t.app
    print "offers: " + count(t.rows)

    print "-> Run"
    r = studio_ui.run_section(app, 0, 0)
    app = drive(r.app)

    banner("what the result can be opened as")
    t = studio_ui.table_rows(app)
    app = t.app
    for each row in t.rows
      print "  " + row.label
    end for

    banner("opening one WITHOUT fetching shows the capture sample, and says so")
    o = studio_ui.open_table(app, t.rows, 0)
    app = o.app
    print "caption: " + o.caption
    show_source(o.src)

    banner("fetching runs the section again and writes the whole table out")
    f = studio_ui.fetch_table(app, t.rows, 0)
    app = f.app
    print "action=" + f.action + " " + f.detail
    app = drive(app)

    banner("now the same click opens the whole table")
    t2 = studio_ui.table_rows(app)
    app = t2.app
    o2 = studio_ui.open_table(app, t2.rows, 0)
    app = o2.app
    print "caption: " + o2.caption
    show_source(o2.src)

    banner("and it is still lazy: a cell decodes its row and no others")
    c = studio_table.cell(o2.src, 1100, 1)
    print "  [1100][1] = " + c.text + "   rows decoded: " + c.src.decodes

    banner("an index nobody offered is refused, not guessed at")
    o3 = studio_ui.open_table(app, t2.rows, 9)
    print "action=" + o3.action

    ' The failure this guards against: an export is keyed by document and
    ' variable name, so editing the code and running again would otherwise serve
    ' rows produced by source that no longer exists — captioned with their own row
    ' count, and with nothing to say they describe a different program.
    banner("editing the code and running again abandons the old export")
    app = studio.edit_document(app, id, "rows = []\nn = 0\nwhile n < 1300\n  rows = append(rows, { id: n, name: \"row \" + n, score: n * 2 })\n  n = n + 1\nend while\ntotal = count(rows)\n")
    r = studio_ui.sync_cursor(app, id, 0, 0)
    app = r.app
    r = studio_ui.run_section(app, 0, 0)
    app = drive(r.app)
    t3 = studio_ui.table_rows(app)
    app = t3.app
    o4 = studio_ui.open_table(app, t3.rows, 0)
    app = o4.app
    print "caption: " + o4.caption
    print "  (the 1200-row export is still on disk; it is an export of other code)"

    banner("fetching again re-stamps it, and the whole table comes back")
    f2 = studio_ui.fetch_table(app, t3.rows, 0)
    app = drive(f2.app)
    t4 = studio_ui.table_rows(app)
    app = t4.app
    o5 = studio_ui.open_table(app, t4.rows, 0)
    print "caption: " + o5.caption
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

    ' STU-5: what the editor draws. Lines are the editor's own 0-based ones.
    banner("gutter marks, and the extent of the section at the caret")
    m = studio_ui.section_marks(app)
    app = m.app
    print "marks at lines " + numlist(m.lines) + " (revision " + m.revision + ")"
    l = 0
    while l < 7
      r = studio_ui.sync_cursor(app, id, l, 0)
      app = r.app
      cr = studio_ui.current_range(app)
      app = cr.app
      print "  caret " + l + " -> highlight " + cr.start0 + ".." + cr.end0
      l = l + 1
    end while
    ' An edit moves the revision, so the marks are redrawn — and only then.
    app = studio.edit_document(app, id, "print \"one\"\n\nfunction add(a, b)\n  return a + b\nend function\n\nnewvar = 1\nprint add(2, 3)\n")
    m2 = studio_ui.section_marks(app)
    app = m2.app
    print "after an edit: marks at " + numlist(m2.lines) + " (revision " + m2.revision + ")"
    app = studio.edit_document(app, id, "print \"one\"\n\nfunction add(a, b)\n  return a + b\nend function\n\nprint add(2, 3)\n")

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

    ' STU-5: the OUTPUT panes are per-section too. The caret is on a section that
    ' has never run, so they say so rather than showing the other section's output.
    banner("and so does the output")
    print "prefix=<" + studio_ui.prefix_body(app) + ">"
    print "target=<" + studio_ui.target_body(app) + ">"
    r = studio_ui.sync_cursor(app, id, 6, 0)
    app = r.app
    print "-- back on the section that ran --"
    print "prefix=<" + studio_ui.prefix_body(app) + ">"
    print "target=<" + studio_ui.target_body(app) + ">"
    print "errors=<" + studio_ui.error_body(app) + ">"

    ' Editing the section a result describes must show up as a mark, and that
    ' means the pane's section model has to be re-derived from the new text.
    banner("edit the run section; its id survives but its fingerprint does not")
    app = studio.edit_document(app, id, "print \"one\"\n\nfunction add(a, b)\n  return a + b\nend function\n\nprint add(2, 4)\n")
    r = studio_ui.sync_cursor(app, id, 6, 0)
    app = r.app
    print studio_ui.results_body(app)

    ' STU-5 §10.3: a result from an EARLIER session is cold — real, readable, and
    ' backed by no live state. Reopening the home is what makes it so.
    banner("standing, in the session that ran it")
    r = studio_ui.sync_cursor(app, id, 6, 0)
    app = r.app
    st = studio_ui.run_standing(app)
    app = st.app
    print "standing=" + st.standing + " | " + studio_ui.standing_line(app)
    r = studio_ui.sync_cursor(app, id, 0, 0)
    app = r.app
    st = studio_ui.run_standing(app)
    app = st.app
    print "a section that never ran: " + st.standing + " | " + studio_ui.standing_line(app)

    banner("reopened in a new session — the same result, now cold")
    ' Closing writes the home; relaunching is a genuinely new session with no
    ' live run in it, which is what makes the stored result cold rather than warm.
    r = studio_ui.sync_cursor(app, id, 6, 0)
    app = r.app
    studio.persist(app)
    again = studio.launch(home)
    ad = studio_docs.active_doc(again.dm)
    rr = studio_ui.sync_cursor(again, ad.id, 6, 0)
    again = rr.app
    st = studio_ui.run_standing(again)
    again = st.app
    print "standing=" + st.standing + " | " + studio_ui.standing_line(again)
    print "the result is still there:"
    print studio_ui.results_body(again)

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

  ' ---- runerr: a section that fails, and what the window says about it -----
  ' The failure a user actually hits: the program parses, runs, and raises. The
  ' diagnostic arrives as structured JSON on the child's stderr and is parsed OUT
  ' of it, so the raw capture is EMPTY — a pane showing only stderr reported
  ' "(none)" about a run that had just failed.
  if mode = "runerr" then
    ef(file) = projdir + "/bad.bas"
    write(ef, "print \"Hello\"\n\nx = 0\nwhile x < 3\n  print \"Counting \" + X\n  x = x + 1\nend while\n")
    rows = studio_ui.nav_rows(app)
    r = studio_ui.activate_row(app, rows, row_index(rows, "file", "bad.bas"))
    app = r.app
    app.clock_fixed = 1000
    id = studio_docs.active_doc(app.dm).id
    r = studio_ui.sync_cursor(app, id, 4, 0)
    app = r.app
    r = studio_ui.run_section(app, 4, 0)
    app = r.app
    app = drive(app)
    print "strip:   " + studio_ui.run_line(studio_ui.exec_session(app))
    print "target:  <" + studio_ui.target_body(app) + ">"
    print "errors:  <" + studio_ui.error_body(app) + ">"
    print "results:"
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

  ' ---- drafts: unsaved work survives closing the window --------------------
  ' The hazard this closes: Studio used to discard every unsaved buffer on exit
  ' and warn on stderr, which a GUI user never sees.
  if mode = "drafts" then
    rows = studio_ui.nav_rows(app)
    r = studio_ui.activate_row(app, rows, row_index(rows, "file", "main.bas"))
    app = r.app
    id = studio_docs.active_doc(app.dm).id
    app = studio.edit_document(app, id, "half-typed, never saved\n")
    print "dirty before closing: " + studio_ui.dirty_count(app)

    saved = studio.persist(app)
    print "saved=" + join(saved, ",")

    banner("reopened — the typing is back, and still unsaved")
    again = studio.launch(home)
    d = studio_docs.doc_by_id(again.dm, id)
    print "content=" + d.content
    print "still dirty=" + studio_docs.is_dirty(d)
    print "file on disk is untouched=" + (read_file_text(projdir + "/main.bas") = "print \"main\"\n")

    banner("saving it clears the draft")
    sv = studio_ui.save_active(again, "")
    again = sv.app
    studio.persist(again)
    idx = studio_drafts.open_index(home)
    print studio_drafts.summary(idx)
    third = studio.launch(home)
    d3 = studio_docs.doc_by_id(third.dm, id)
    print "after a clean save, reopened dirty=" + studio_docs.is_dirty(d3)

    banner("a file that changed underneath the draft is a CONFLICT, not a silent overwrite")
    app2 = studio.launch(home)
    app2 = studio.edit_document(app2, id, "typed again\n")
    studio.persist(app2)
    ' Someone else edits the file while Studio is closed.
    w(file) = projdir + "/main.bas"
    write(w, "changed by someone else\n")
    app3 = studio.launch(home)
    d4 = studio_docs.doc_by_id(app3.dm, id)
    print "buffer=" + d4.content
    print "external=" + d4.external
    print "on disk=" + read_file_text(projdir + "/main.bas")
    print "the tab says: " + studio_ui.tab_label(d4)

    ' Saving over a conflict OVERWRITES whoever else wrote the file, so it takes
    ' two clicks — the same shape as Delete and Close, and for a bigger reason.
    banner("Save over a conflict arms first")
    sv = studio_ui.save_active(app3, "")
    app3 = sv.app
    print "-> Save: " + sv.action + " | " + studio_ui.action_notice(sv.action, sv.detail)
    print "on disk still=" + read_file_text(projdir + "/main.bas")
    sv2 = studio_ui.save_active(app3, sv.armed)
    app3 = sv2.app
    print "-> Save again: " + sv2.action
    print "on disk now=" + read_file_text(projdir + "/main.bas")
    print "arm kinds: " + studio_ui.arm_kind("armed-save") + " (save) vs " + studio_ui.arm_kind("saved") + " (none)"
  end if

  ' ---- branch: two continuations over identical source ---------------------
  ' The whole claim of a state-only branch: the SAME code, run twice, producing
  ' different answers because the bindings injected at the branch point differ.
  if mode = "branch" then
    bf(file) = projdir + "/branchy.bas"
    write(bf, "threshold = 0.5\n\nfunction score(t)\n  return t * 100\nend function\n\nprint \"score is \" + score(threshold)\n")
    rows = studio_ui.nav_rows(app)
    r = studio_ui.activate_row(app, rows, row_index(rows, "file", "branchy.bas"))
    app = r.app
    app.clock_fixed = 1000
    id = studio_docs.active_doc(app.dm).id
    r = studio_ui.sync_cursor(app, id, 6, 0)
    app = r.app
    v = studio_ui.view_for(app)
    app = v.app
    point = v.sid
    print "the branch point is the section at the caret: " + point

    banner("baseline: no branch selected, the document as written")
    r = studio_ui.run_section(app, 6, 0)
    app = r.app
    app = drive(app)
    print "target=<" + studio_ui.target_body(app) + ">"

    banner("two branches at that point, each binding threshold differently")
    tree = studio_ui.branch_tree(app)
    a = studio_branches.add(tree, id, point, "Low", "", v.st)
    tree = studio_branches.bind(a.tree, a.id, "threshold", "0.25").tree
    b = studio_branches.add(tree, id, point, "High", "", v.st)
    tree = studio_branches.bind(b.tree, b.id, "threshold", "0.9").tree
    app = studio_ui.set_branch_tree(app, tree)

    tree = studio_branches.select(tree, a.id).tree
    app = studio_ui.set_branch_tree(app, tree)
    print "-> selected " + studio_ui.active_branch(app).name
    r = studio_ui.run_section(app, 6, 0)
    app = r.app
    app = drive(app)
    print "target=<" + studio_ui.target_body(app) + ">"

    tree = studio_branches.select(tree, b.id).tree
    app = studio_ui.set_branch_tree(app, tree)
    print "-> selected " + studio_ui.active_branch(app).name
    r = studio_ui.run_section(app, 6, 0)
    app = r.app
    app = drive(app)
    print "target=<" + studio_ui.target_body(app) + ">"

    banner("the file on disk never changed")
    print read_file_text(projdir + "/branchy.bas")

    banner("each branch keeps its OWN history; they do not interleave")
    print "-- High (selected)"
    print studio_ui.results_body(app)
    tree = studio_branches.select(tree, a.id).tree
    app = studio_ui.set_branch_tree(app, tree)
    print "-- Low"
    print studio_ui.results_body(app)
    tree = studio_branches.clear_point(tree, point)
    app = studio_ui.set_branch_tree(app, tree)
    print "-- baseline"
    print studio_ui.results_body(app)

    banner("branches survive a save and a relaunch")
    studio.persist(app)
    again = studio.launch(home)
    back = studio_ui.branch_tree(again)
    print studio_branches.summary(back, id, v.st)
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
    ' This used to pin a limitation — the tab came back and the unsaved text did
    ' not — and now pins its absence. Closing preserves both which documents were
    ' open AND what was typed into them; the buffer comes back UNSAVED, so the
    ' decision to write it to the file is still the user's.
    d = studio_docs.doc_by_id(again.dm, "doc-1")
    print "doc-1 content after restart=" + d.content
    print "still unsaved=" + studio_docs.is_dirty(d)
    print "the file itself is untouched=" + (read_file_text(projdir + "/main.bas") = "print \"main\"\n")
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
