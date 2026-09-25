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
  f{file} = p
  return read(f)
end function

' The section ids of a state, in order — what a result is filed against.
function secids(st)
  out = []
  for each s in st.sections
    out = append(out, s.id)
  end for
  return join(out, ",")
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

' The plan's file list, which is the whole of what a set of options MEANS.
function planfiles(plan)
  out = []
  for each f in plan.files
    out = append(out, f.name)
  end for
  if count(out) = 0 then
    return "(none)"
  end if
  return join(out, ",")
end function

function leafof(p)
  parts = split(p, "/")
  return parts[count(parts) - 1]
end function

' What is actually in a directory, sorted, so the golden does not depend on
' the order the filesystem hands entries back.
function dirlist(d)
  h{dir} = d
  names = []
  for each e in list(h)
    names = append(names, e.name)
  end for
  return sort(names)
end function

function head3(text)
  lines = split(text, "\n")
  out = []
  i = 0
  while i < 3
    if i < count(lines) then
      out = append(out, lines[i])
    end if
    i = i + 1
  end while
  return join(out, "\n")
end function

' The menu a row offers, as a flat string.
function acts(rows, i)
  a = studio_ui.context_actions(rows, i)
  if count(a) = 0 then
    return "(no menu)"
  end if
  return join(a, ",")
end function

' The tab row, by basename, which is what a user reads off it.
function tabnames(app)
  out = []
  for each t in studio_ui.tab_rows(app)
    d = studio_docs.doc_by_id(app.dm, t.doc_id)
    out = append(out, leafof(d.path))
  end for
  if count(out) = 0 then
    return "(none)"
  end if
  return join(out, ",")
end function

' The connection a .sql document resolves to, path-free: what matters is which
' name won and whether the path landed under the project, not where the test
' directory happens to be.
function conn(app)
  doc = studio_docs.active_doc(app.dm)
  r = studio_ui.sql_connection(app, doc)
  line = "  " + leafof(doc.path) + ": ok=" + r.ok
  if r.ok then
    line = line + " name=" + r.name + " driver=" + r.conn.driver
    line = line + " path=" + leafof(r.conn.path) + " under-project=" + (find(r.conn.path, "_proj/data/") != nothing)
  else
    line = line + " refused=" + r.why
    if r.name != "" then
      line = line + " (" + r.name + ")"
    end if
    line = line + "  status=" + studio_ui.action_notice(r.why, r.name)
  end if
  print line
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
  load studio_sections
  load studio_projects
  load studio_projfile

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
  ' `layout` reads a home the GUI just wrote, so it must not build one.
  if mode = "layout" then
    fixture = false
  end if
  if mode = "panes" then
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

    ' Made HERE and not in mkproj_ui: a new entry in the shared fixture puts a
    ' new row in every other ui_* golden.
    '
    ' An expanded directory with nothing to show used to change the arrow and
    ' nothing else, and the rows below it -- its SIBLINGS, which sort after it
    ' because directories come first -- stayed exactly where they were. That
    ' reads as a control that does not work, and was reported as one.
    banner("a directory with nothing in it says so")
    persist.ensure_dir(projdir + "/hollow")
    persist.ensure_dir(projdir + "/dots")
    df{file} = projdir + "/dots/.secret"
    write(df, "shh\n")
    rows = studio_ui.nav_rows(app)
    r = studio_ui.activate_row(app, rows, row_index(rows, "dir", "hollow"))
    app = act("expand hollow", r)
    rows = studio_ui.nav_rows(app)
    r = studio_ui.activate_row(app, rows, row_index(rows, "dir", "dots"))
    app = act("expand dots", r)
    show(app)

    banner("the notes are not rows you can act on")
    rows = studio_ui.nav_rows(app)
    i = row_index(rows, "info", "(empty)")
    print "the (empty) note is row " + i
    print "its menu: " + acts(rows, i)
    r = studio_ui.activate_row(app, rows, i)
    app = act("click it", r)
    print "selection unchanged=[" + leafof(app.model.workspace.nav.selected_path) + "]"

    banner("and a directory that HAS something gets no note at all")
    rows = studio_ui.nav_rows(app)
    r = studio_ui.activate_row(app, rows, row_index(rows, "dir", "src"))
    app = r.app
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

    f{file} = projdir + "/main.bas"
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
    pd{file} = p1.path
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

    banner("and what those two SAY, which is the whole point of them")
    ' The full path, not its last segment: "gdash is not there" about
    ' `~/development/gdash` blames the folder for a `~` nobody expanded. Literal
    ' arguments, so the golden holds the sentence rather than this machine.
    print "no folder: " + studio_ui.action_notice("no-folder", "/srv/projects/ghost")
    print "no path:   " + studio_ui.action_notice("no-path", "")

    banner("a path as a PERSON types it")
    ' Pure over three strings, so this asserts the expansion and not whatever
    ' HOME this machine happens to have. A GtkEntry is not a shell; before this,
    ' the first thing anyone types was the one thing that did not work.
    print "~             -> " + studio_ui.expand_path("~", "/home/u", "/w")
    print "~/dev/gdash   -> " + studio_ui.expand_path("~/dev/gdash", "/home/u", "/w")
    print "/abs/path     -> " + studio_ui.expand_path("/abs/path", "/home/u", "/w")
    print "dev/gdash     -> " + studio_ui.expand_path("dev/gdash", "/home/u", "/w")
    ' NOT expanded: another user's home needs a passwd lookup, and a wrong guess
    ' is worse than a path that fails honestly.
    print "~someone/x    -> " + studio_ui.expand_path("~someone/x", "/home/u", "/w")
    print "(empty)       -> [" + studio_ui.expand_path("", "/home/u", "/w") + "]"
    ' Neither is guaranteed to be set, and building a confident path out of an
    ' empty string is how "/x" becomes a plausible answer for "~/x".
    print "~/x, no HOME  -> " + studio_ui.expand_path("~/x", "", "/w")
    print "rel, no cwd   -> " + studio_ui.expand_path("rel", "/home/u", "")
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
    e{file} = projdir + "/docs/guide.md"
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
    rf{file} = projdir + "/runme.bas"
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
    of{file} = projdir + "/overlaid.bas"
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
    persist_result = studio.persist(app)
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
    cf{file} = projdir + "/conflicted.bas"
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
    tf{file} = projdir + "/table.bas"
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
    cf{file} = projdir + "/three.bas"
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
    persist_result = studio.persist(app)
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
    ef{file} = projdir + "/empty.bas"
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
    ef{file} = projdir + "/bad.bas"
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

  ' ---- anchors: section identity must survive closing a tab ----------------
  ' STU-3 exists so that a result recorded against sec-4 still means sec-4 after
  ' the source is edited. It does that by RE-MATCHING sections across edits, so
  ' the ids stop being in file order — which is the whole point.
  '
  ' But the persisted anchors were keyed by the document's minted id (doc-N),
  ' and closing a tab throws that id away: reopening the same file mints doc-N+1,
  ' finds no anchors under it, and derives a fresh state numbered in file order.
  ' The ids then land on DIFFERENT sections than the ones the results were filed
  ' against, so the results pane confidently shows you another function's
  ' history. That is worse than losing them.
  '
  ' Anchors are keyed by PATH now, which a close does not change.
  if mode = "anchors" then
    af{file} = projdir + "/anchors.bas"
    write(af, "function one()\n  return 1\nend function\n\nfunction two()\n  return 2\nend function\n")
    rows = studio_ui.nav_rows(app)
    r = studio_ui.activate_row(app, rows, row_index(rows, "file", "anchors.bas"))
    app = r.app
    id = studio_docs.active_doc(app.dm).id
    vw = studio_ui.view_for(app)
    app = vw.app
    print "opened     : " + secids(vw.st)

    banner("two edits, each inserting a function above the others")
    ' Ids advance as sections are re-matched; after this they are deliberately
    ' NOT in file order, which is what makes the bug visible.
    app = studio.edit_document(app, id, "function zero()\n  return 0\nend function\n\nfunction one()\n  return 1\nend function\n\nfunction two()\n  return 2\nend function\n")
    vw = studio_ui.view_for(app)
    app = vw.app
    print "after edit : " + secids(vw.st)
    app = studio.edit_document(app, id, "function minus()\n  return -1\nend function\n\nfunction zero()\n  return 0\nend function\n\nfunction one()\n  return 1\nend function\n\nfunction two()\n  return 2\nend function\n")
    vw = studio_ui.view_for(app)
    app = vw.app
    print "after edit : " + secids(vw.st)
    before = secids(vw.st)
    sv = studio_ui.save_active(app, "")
    app = sv.app

    banner("close the tab and open the same file again")
    cl = studio_ui.close_active(app, true)
    app = cl.app
    rows = studio_ui.nav_rows(app)
    r = studio_ui.activate_row(app, rows, row_index(rows, "file", "anchors.bas"))
    app = r.app
    vw = studio_ui.view_for(app)
    app = vw.app
    print "reopened   : " + secids(vw.st)
    print "identical to before the close=" + (secids(vw.st) = before)
  end if

  ' ---- projfile: the project's own file, which Studio never writes uninvited -
  '
  ' `.gstudio.json` is the opposite of the per-project state store: declared,
  ' small, hand-edited, committed, and IN the project directory. The asserted
  ' properties are the ones that make it acceptable to put a file there at all:
  '   - nothing creates it but the one action that says it will
  '   - the browser SHOWS it afterwards, alone among dotfiles
  '   - it gives the project a stable id, and the anchors filed under the old
  '     path key come with it rather than being silently renumbered
  '   - the ignore list takes effect, by name, at any depth
  if mode = "projfile" then
    ' The clock seam, so a minted id has a shape a golden can hold.
    app["clock_fixed"] = 1758600000

    banner("nothing there, and nothing put it there")
    print "spec: " + studio_projfile.summary(studio_projfile.read_spec(projdir))
    rows = studio_ui.nav_rows(app)
    print "browser sees it=" + (row_index(rows, "file", ".gstudio.json") >= 0)

    banner("open a file and give it sections, filed under the PATH key")
    pf{file} = projdir + "/work.bas"
    write(pf, "function one()\n  return 1\nend function\n\nfunction two()\n  return 2\nend function\n")
    rows = studio_ui.nav_rows(app)
    r = studio_ui.activate_row(app, rows, row_index(rows, "file", "work.bas"))
    app = r.app
    id = studio_docs.active_doc(app.dm).id
    vw = studio_ui.view_for(app)
    app = vw.app
    ' Re-match the ids out of file order, which is what makes a renumbering
    ' visible rather than harmless.
    app = studio.edit_document(app, id, "function zero()\n  return 0\nend function\n\nfunction one()\n  return 1\nend function\n\nfunction two()\n  return 2\nend function\n")
    vw = studio_ui.view_for(app)
    app = vw.app
    print "sections   : " + secids(vw.st)
    before = secids(vw.st)
    sv = studio_ui.save_active(app, "")
    app = sv.app
    ps = studio_ui.project_state(app)
    app = ps.app
    pst = ps.state
    pst.sections = studio_sections.persist_into(pst.sections, vw.st)
    app = studio_ui.set_project_state(app, pst)
    print "state docs=" + count(pst.sections)

    banner("Project File")
    r = studio_ui.add_project_file(app, "")
    app = act("Project File", r)
    print "   " + studio_ui.action_notice(r.action, safe_detail(r.detail))
    spec = studio_projfile.read_spec(projdir)
    print "spec: " + studio_projfile.summary(spec)

    banner("the one dotfile the browser shows")
    rows = studio_ui.nav_rows(app)
    print "browser sees it=" + (row_index(rows, "file", ".gstudio.json") >= 0)
    print "browser sees .hidden=" + (row_index(rows, "file", ".hidden") >= 0)

    banner("the key moved, and the anchors moved with it")
    oldk = studio_projects.key_for(projdir, "")
    newk = studio_projects.key_for(projdir, spec.id)
    print "key changed=" + (oldk != newk)
    ' A fresh app, reading from disk: the in-memory cache cannot be what is
    ' answering here.
    app2 = studio.launch(home)
    ws2 = app2.model.workspace
    carried = studio_projects.open(home, newk)
    print "carried: " + studio_projects.summary(carried)
    ' By PATH, which is what studio_ui.doc_key answers and what the anchors
    ' were filed under — the key INSIDE the state, unchanged by any of this.
    ' Only the file the state lives in moved.
    st2 = studio_sections.restore_from(carried.sections, projdir + "/work.bas")
    st2 = studio_sections.refresh(st2, read_file_text(projdir + "/work.bas"))
    print "restored   : " + secids(st2)
    print "identical to before the file=" + (secids(st2) = before)

    banner("asking twice does not rewrite it")
    r = studio_ui.add_project_file(app, "")
    app = act("Project File again", r)
    print "   " + studio_ui.action_notice(r.action, r.detail)

    banner("the ignore list, by name, at any depth")
    ig{file} = projdir + "/.gstudio.json"
    write(ig, "{\"schema_version\":1,\"id\":\"" + spec.id + "\",\"name\":\"Alpha\",\"ignore\":[\"docs\",\"*.md\"]}")
    rows = studio_ui.nav_rows(app)
    print "docs hidden=" + (row_index(rows, "dir", "docs") < 0)
    print "README.md hidden=" + (row_index(rows, "file", "README.md") < 0)
    print "main.bas still shown=" + (row_index(rows, "file", "main.bas") >= 0)

    banner("a file that is not JSON at all")
    write(ig, "this is not json")
    print "spec: " + studio_projfile.summary(studio_projfile.read_spec(projdir))
    rows = studio_ui.nav_rows(app)
    print "browser recovers, rows=" + (count(rows) > 3)
    r = studio_ui.add_project_file(app, "")
    app = act("Project File over the broken one", r)
  end if

  ' ---- projpin: the one thing in .gstudio.json that changes what a run DOES -
  '
  ' A pinned interpreter is the reason the project file travels: a project that
  ' needs a particular gBASIC gets it on whoever's machine, rather than
  ' whatever their shell exported. The assertion has to be that the pin CHOSE
  ' what ran, not merely that something ran, so the pin points at a stand-in
  ' that records itself and then hands over to the real interpreter.
  if mode = "projpin" then
    real = env("GBASIC")
    stub = home + "/pinned.sh"
    marker = home + "/pin-marker"
    sf{file} = stub
    write(sf, "#!/bin/sh\nprintf 'ran\\n' >> " + quote(marker) + "\nexec " + quote(real) + " \"$@\"\n")
    ch = process.run({ command: "chmod", args: ["+x", stub] })

    ' It LOADS something. A program that needs no library would run identically
    ' whatever GBASIC_PATH said, so the library-path half of the pin would have
    ' nothing to prove.
    rf{file} = projdir + "/pinned.bas"
    write(rf, "load dates\n\nprint \"one\"\n\nfunction add(a, b)\n  return a + b\nend function\n\nsum = add(2, 3)\nprint sum\n")
    rows = studio_ui.nav_rows(app)
    r = studio_ui.activate_row(app, rows, row_index(rows, "file", "pinned.bas"))
    app = r.app
    app.clock_fixed = 1000
    id = studio_docs.active_doc(app.dm).id

    banner("no pin: the ambient interpreter, and nothing recorded")
    r = studio_ui.sync_cursor(app, id, 8, 0)
    app = r.app
    r = studio_ui.run_section(app, 8, 0)
    app = r.app
    app = drive(app)
    mk{file} = marker
    print "the stand-in ran=" + exists(mk)

    banner("pinned: the same run, through the stand-in")
    gf{file} = projdir + "/.gstudio.json"
    write(gf, "{\"schema_version\":1,\"id\":\"gsp-1-1\",\"interpreter\":" + quote(stub) + "}")
    print "spec: " + studio_projfile.summary(studio_projfile.read_spec(projdir))
    r = studio_ui.run_section(app, 8, 0)
    app = r.app
    app = drive(app)
    print "the stand-in ran=" + exists(mk)

    banner("a pinned library path is the path the child actually sees")
    ' Proof that `gbasic_path` REACHES the child and REPLACES what Studio's own
    ' launcher exported, by asking the child: the section prints its own
    ' GBASIC_PATH. Asserting a FAILED load instead would have proved nothing —
    ' measured, gBASIC finds its stdlib with GBASIC_PATH pointed at an empty
    ' directory, so a program that merely loads something runs either way.
    ef{file} = projdir + "/envy.bas"
    write(ef, "print \"one\"\n\nfunction f()\n  return 1\nend function\n\nprint env(\"GBASIC_PATH\")\n")
    write(gf, "{\"schema_version\":1,\"id\":\"gsp-1-1\",\"gbasic_path\":\"/pinned/libs\"}")
    print "spec: " + studio_projfile.summary(studio_projfile.read_spec(projdir))
    rows = studio_ui.nav_rows(app)
    r = studio_ui.activate_row(app, rows, row_index(rows, "file", "envy.bas"))
    app = r.app
    id2 = studio_docs.active_doc(app.dm).id
    r = studio_ui.sync_cursor(app, id2, 6, 0)
    app = r.app
    r = studio_ui.run_section(app, 6, 0)
    app = r.app
    app = drive(app)
    print "the child saw=<" + studio_ui.target_body(app) + ">"
  end if

  ' ---- newproj2: New Project with the questions asked ----------------------
  '
  ' The window collects an options record; `project_plan` says what that record
  ' MEANS, as the exact list of files; `create_project` carries it out. The
  ' whole of "what does ticking that box do" is therefore assertable with no
  ' widget in sight, which is the point of the split.
  '
  ' Every default is the minimal one. main.bas is on because an empty project
  ' dead-ends — no rows to click. The project file is OFF: Studio writing
  ' `.gstudio.json` by default would be the exact behaviour that file exists to
  ' avoid, and a box you had to untick is not consent.
  if mode = "newproj2" then
    app["clock_fixed"] = 1758600000
    where = projdir + "/made"

    banner("the defaults")
    o = studio_ui.default_options(app, home)
    o.location = where
    o.author = "A. Author"
    print "main=" + o.main + " projfile=" + o.projfile + " readme=" + o.readme + " git=" + o.git + " license=" + o.license
    plan = studio_ui.project_plan(o, 1758600000)
    print "plan: " + plan.reason + " files=" + planfiles(plan)

    banner("a name, and the directory is its slug")
    o.name = "My Thing"
    plan = studio_ui.project_plan(o, 1758600000)
    print "dir=" + leafof(plan.path) + " name=" + plan.name

    banner("everything on")
    o.projfile = true
    o.readme = true
    o.git = true
    o.license = "MIT"
    plan = studio_ui.project_plan(o, 1758600000)
    print "plan: " + plan.reason + " files=" + planfiles(plan) + " git=" + plan.git + " projfile=" + plan.projfile

    banner("refusals, none of which create anything")
    bad = studio_ui.default_options(app, home)
    bad.location = where
    bad.name = ""
    print "-> " + studio_ui.project_plan(bad, 1758600000).reason + ": " + studio_ui.action_notice("no-name", "")
    bad.name = "a/b"
    print "-> " + studio_ui.project_plan(bad, 1758600000).reason
    bad.name = "ok"
    bad.location = ""
    print "-> " + studio_ui.project_plan(bad, 1758600000).reason
    bad.location = where
    bad.license = "MIT"
    bad.author = ""
    r2 = studio_ui.project_plan(bad, 1758600000)
    print "-> " + r2.reason + ": " + studio_ui.action_notice(r2.reason, r2.detail)
    bad.license = "Nonesuch"
    bad.author = "A. Author"
    r2 = studio_ui.project_plan(bad, 1758600000)
    print "-> " + r2.reason + ": " + studio_ui.action_notice(r2.reason, r2.detail)
    mk{file} = where
    print "nothing was created=" + (not exists(mk))

    banner("create it for real")
    r = studio_ui.create_project(app, o)
    app = act("Create", r)
    show(app)
    print "on disk: " + join(dirlist(where + "/my-thing"), " ")
    print "-- main.bas --"
    print read_file_text(where + "/my-thing/main.bas")
    print "-- README.md --"
    print read_file_text(where + "/my-thing/README.md")
    print "-- LICENSE, first three lines --"
    print head3(read_file_text(where + "/my-thing/LICENSE"))

    banner("the same name again lands on a directory that is there")
    r = studio_ui.create_project(app, o)
    app = act("Create again", r)

    banner("a licence copied verbatim carries no placeholder")
    o2 = studio_ui.default_options(app, home)
    o2.location = where
    o2.name = "Second"
    o2.author = ""
    o2.license = "Apache-2.0"
    r = studio_ui.create_project(app, o2)
    app = act("Create Apache", r)
    txt = read_file_text(where + "/second/LICENSE")
    print "has a placeholder=" + (find(txt, "[fullname]") != nothing)
    print "is the Apache licence=" + (find(txt, "Apache License") != nothing)
  end if

  ' ---- layout: what a reopened home remembers about the window -------------
  if mode = "layout" then
    app = studio.launch(home)
    sess = app.model.session
    ' Booleans, not the numbers: see stu13_step. What is asserted is that all
    ' three came back and that none of them is the built-in default any more.
    print "browser remembered=" + (studio_model.pane_at(sess, "browser", -1) > 0)
    print "console remembered=" + (studio_model.pane_at(sess, "console", -1) > 0)
    print "right remembered=" + (studio_model.pane_at(sess, "right", -1) > 0)
    print "not the built-in browser default=" + (studio_model.pane_at(sess, "browser", -1) != 260)
    ' The SIZE is recorded as a boolean. Under Wayland the compositor decides
    ' how big a window actually is, so the number that comes back is the
    ' desktop's and not something a golden can hold; that it was written at all
    ' is the assertable part.
    print "window recorded=" + (sess.window.width > 0 and sess.window.height > 0)
  end if

  ' ---- panes: the divider arithmetic, and what a bad stored value does -----
  if mode = "panes" then
    sess = studio_model.default_session()
    print "defaults: " + studio_model.pane_at(sess, "browser", -1) + " " + studio_model.pane_at(sess, "console", -1) + " " + studio_model.pane_at(sess, "right", -1)
    sess = studio_model.set_panes(sess, 340, 300, 700)
    print "set:      " + studio_model.pane_at(sess, "browser", -1) + " " + studio_model.pane_at(sess, "console", -1) + " " + studio_model.pane_at(sess, "right", -1)

    banner("a session written before panes existed")
    old = { schema_version: 1, window: { width: 10, height: 10, maximized: false } }
    print "browser falls back=" + studio_model.pane_at(old, "browser", 260)

    banner("and a file somebody edited")
    ' This is JSON in a user's home: a string where a number belongs, a key
    ' missing, a zero left behind by a truncated write. A divider read as any
    ' of those is a pane collapsed to its floor on startup with nothing saying
    ' why, so each one falls back to the built-in instead.
    bad = { schema_version: 1, panes: { browser: "wide", console: 0, right: 700 } }
    print "a string:  " + studio_model.pane_at(bad, "browser", 260)
    print "a zero:    " + studio_model.pane_at(bad, "console", 380)
    print "a number:  " + studio_model.pane_at(bad, "right", 620)
    print "missing:   " + studio_model.pane_at(bad, "nothere", 99)
    notrec = { schema_version: 1, panes: "no" }
    print "not even a record: " + studio_model.pane_at(notrec, "browser", 260)
  end if

  ' ---- context: what a right-click offers, and closing a project -----------
  '
  ' The menu's CONTENT is a function over the row model, so it is asserted here
  ' with no popover in sight. Every item maps onto a function the toolbar
  ' already calls — the menu is an adapter, not a second implementation — which
  ' matters most for Delete, where a second implementation would quietly undo
  ' the two-click rule on the same file.
  if mode = "context" then
    rows = studio_ui.nav_rows(app)
    banner("what each kind of row offers")
    print "info:    " + acts(rows, row_index(rows, "info", "ws"))
    print "project: " + acts(rows, row_index(rows, "project", "Alpha"))
    print "dir:     " + acts(rows, row_index(rows, "dir", "src"))
    print "file:    " + acts(rows, row_index(rows, "file", "main.bas"))
    print "off the end: " + acts(rows, 999)
    print "before the start: " + acts(rows, -1)

    banner("the labels")
    for each a in studio_ui.context_all()
      print "  " + a + " -> " + studio_ui.context_label(a)
    end for

    banner("right-click selects, it does not open")
    i = row_index(rows, "file", "main.bas")
    r = studio_ui.select_row(app, rows, i)
    app = act("select main.bas", r)
    print "tabs=" + count(app.dm.docs)

    banner("Close project refuses while something under it is unsaved")
    r = studio_ui.activate_row(app, rows, i)
    app = r.app
    id = studio_docs.active_doc(app.dm).id
    app = studio.edit_document(app, id, "print \"typed, never saved\"\n")
    r = studio_ui.close_project(app, "proj-1")
    app = act("Close project", r)
    print "   " + studio_ui.action_notice(r.action, r.detail)
    print "still open=" + count(app.model.workspace.projects)

    banner("saved, and then it closes")
    sv = studio_ui.save_active(app, "")
    app = sv.app
    r = studio_ui.close_project(app, "proj-1")
    app = act("Close project", r)
    print "   " + studio_ui.action_notice(r.action, r.detail)
    print "projects=" + count(app.model.workspace.projects)
    print "tabs=" + count(app.dm.docs)
    print "selection=[" + app.model.workspace.nav.selected_path + "]"
    r = studio_ui.close_project(app, "proj-1")
    app = act("Close it again", r)
  end if

  ' ---- projtabs: the notebook follows the browser --------------------------
  '
  ' The browser shows ONE project at a time and the tab row did not, so
  ' switching projects changed the tree and left you looking at the previous
  ' project's files with nothing in the tab row saying which project any of
  ' them came from. Nothing is CLOSED by the filtering -- a hidden document
  ' keeps its unsaved text and comes straight back.
  if mode = "projtabs" then
    other = projdir + "/../ui_projtabs_beta"
    persist.ensure_dir(other)
    bf{file} = other + "/beta.bas"
    write(bf, "print \"beta\"\n")

    banner("two projects, a file open in each")
    rows = studio_ui.nav_rows(app)
    r = studio_ui.activate_row(app, rows, row_index(rows, "file", "main.bas"))
    app = r.app
    r = studio_ui.adopt_folder(app, other)
    app = act("open the second folder", r)
    rows = studio_ui.nav_rows(app)
    r = studio_ui.activate_row(app, rows, row_index(rows, "file", "beta.bas"))
    app = r.app
    print "documents open: " + count(app.dm.docs)
    print "tabs shown:     " + tabnames(app)
    print "active:         " + leafof(studio_docs.active_doc(app.dm).path)
    print "hidden:         " + studio_ui.hidden_docs(app)

    banner("back to the first project")
    rows = studio_ui.nav_rows(app)
    r = studio_ui.activate_row(app, rows, row_index(rows, "project", "Alpha"))
    app = act("click Alpha", r)
    print "documents open: " + count(app.dm.docs)
    print "tabs shown:     " + tabnames(app)
    print "active:         " + leafof(studio_docs.active_doc(app.dm).path)
    print "hidden:         " + studio_ui.hidden_docs(app)

    banner("a hidden document keeps its unsaved text")
    id = studio_docs.active_doc(app.dm).id
    app = studio.edit_document(app, id, "print \"edited in Alpha\"\n")
    print "Alpha's file is dirty=" + studio_docs.is_dirty(studio_docs.active_doc(app.dm))
    rows = studio_ui.nav_rows(app)
    r = studio_ui.activate_row(app, rows, row_index(rows, "project", "ui_projtabs_beta"))
    app = r.app
    print "away: tabs shown=" + tabnames(app) + " hidden=" + studio_ui.hidden_docs(app)
    rows = studio_ui.nav_rows(app)
    r = studio_ui.activate_row(app, rows, row_index(rows, "project", "Alpha"))
    app = r.app
    back = studio_docs.active_doc(app.dm)
    print "back: tabs shown=" + tabnames(app) + " still dirty=" + studio_docs.is_dirty(back)
    print "text=" + back.content

    banner("a file opened under NO project is always shown")
    loose = projdir + "/../ui_projtabs_loose.bas"
    lf{file} = loose
    write(lf, "print \"loose\"\n")
    ' project_id "" -- a loose file, belonging to no project.
    o = studio.open_from_browser(app, "", loose)
    app = o.app
    print "tabs shown: " + tabnames(app)
  end if

  ' ---- sqlconn: which database a .sql cell runs against ---------------------
  '
  ' The file NAMES its connection and the project says what that name means.
  ' In the file rather than in a picker, because opening somebody else's .sql
  ' must not silently point it at your database -- a picker remembers what YOU
  ' chose last; a line in the file travels with it and shows up in the diff.
  '
  ' Every refusal is named, so the status line can say which of the four things
  ' is wrong instead of "cannot run".
  if mode = "sqlconn" then
    pf{file} = projdir + "/.gstudio.json"
    sf{file} = projdir + "/notes.sql"

    banner("a project that declares nothing")
    write(pf, "{\"schema_version\":1,\"id\":\"gsp-1-1\",\"name\":\"Alpha\"}")
    write(sf, "select 1;\n")
    o = studio.open_from_browser(app, "proj-1", projdir + "/notes.sql")
    app = o.app
    conn(app)

    banner("one connection, and a file that names none")
    write(pf, "{\"schema_version\":1,\"id\":\"gsp-1-1\",\"databases\":{\"app\":{\"driver\":\"sqlite\",\"path\":\"data/app.db\"}}}")
    conn(app)

    banner("two connections, and a file that names none — a question, not a guess")
    write(pf, "{\"schema_version\":1,\"id\":\"gsp-1-1\",\"databases\":{\"app\":{\"driver\":\"sqlite\",\"path\":\"data/app.db\"},\"reporting\":{\"driver\":\"sqlite\",\"path\":\"data/rep.db\"}}}")
    conn(app)

    banner("and the same two with the file naming one")
    id = studio_docs.active_doc(app.dm).id
    app = studio.edit_document(app, id, "-- @database reporting\n\nselect 1;\n")
    conn(app)

    banner("naming one the project does not declare")
    app = studio.edit_document(app, id, "-- @database nosuch\n\nselect 1;\n")
    conn(app)

    banner("a driver Studio has no module for")
    write(pf, "{\"schema_version\":1,\"id\":\"gsp-1-1\",\"databases\":{\"app\":{\"driver\":\"oracle\",\"path\":\"x\"}}}")
    app = studio.edit_document(app, id, "select 1;\n")
    conn(app)

    banner("and an entry with no driver at all")
    write(pf, "{\"schema_version\":1,\"id\":\"gsp-1-1\",\"databases\":{\"app\":{\"path\":\"x\"}}}")
    conn(app)

    banner("a .sql file under NO project")
    write(pf, "{\"schema_version\":1,\"id\":\"gsp-1-1\",\"databases\":{\"app\":{\"driver\":\"sqlite\",\"path\":\"data/app.db\"}}}")
    loose = projdir + "/../ui_sqlconn_loose.sql"
    lf{file} = loose
    write(lf, "select 1;\n")
    o = studio.open_from_browser(app, "", loose)
    app = o.app
    conn(app)

    banner("what counts as a .sql document")
    for each p in ["notes.sql", "NOTES.SQL", "notes.sql.txt", "notes.bas", "sql"]
      print "  " + p + " -> " + studio_ui.is_sql(p)
    end for
  end if

  ' ---- filetypes: a project is not only its .bas files ---------------------
  ' Studio opens a README, a Makefile, a JSON fixture — they are part of the
  ' project. But every document was handed to `source_outline` regardless, so
  ' opening README.md answered "this file does not parse — error 1:1 unexpected
  ' token" and marked line 1 in the gutter. A pane asserting that a markdown
  ' document is broken gBASIC is worse than a pane saying nothing.
  if mode = "filetypes" then
    print "-- what counts as gBASIC --"
    ' The suffixes are gbasic.lang's own globs, so the thing Studio runs and the
    ' thing the editor highlights cannot drift apart.
    print "  main.bas        -> " + studio_ui.is_gbasic("main.bas")
    print "  lib/thing.gb    -> " + studio_ui.is_gbasic("lib/thing.gb")
    ' Case-insensitive: the only thing a case-sensitive check would decide is
    ' whether Studio can run README.BAS, and it can.
    print "  SHOUT.BAS       -> " + studio_ui.is_gbasic("SHOUT.BAS")
    print "  README.md       -> " + studio_ui.is_gbasic("README.md")
    print "  Makefile        -> " + studio_ui.is_gbasic("Makefile")
    ' Suffix, not substring: these two were the ways a looser check went wrong.
    print "  notes.bas.txt   -> " + studio_ui.is_gbasic("notes.bas.txt")
    print "  dialect.basic   -> " + studio_ui.is_gbasic("dialect.basic")

    mf{file} = projdir + "/NOTES.md"
    write(mf, "# Notes\n\nThis is *markdown*, and it is not a program.\n")
    rows = studio_ui.nav_rows(app)
    r = studio_ui.activate_row(app, rows, row_index(rows, "file", "NOTES.md"))
    app = r.app

    banner("a markdown file: open, editable, and NOT a broken program")
    print "strip:   " + studio_ui.section_label(app)
    print "heading: " + studio_ui.error_heading(studio_ui.error_body(app))
    print "errors:  <" + studio_ui.error_body(app) + ">"
    em = studio_ui.error_marks(app)
    app = em.app
    print "gutter:  error marks=" + numlist(em.lines) + " section marks=" + numlist(studio_ui.section_marks(app).lines)
    r = studio_ui.run_section(app, 0, 0)
    app = r.app
    print "-> Run: " + r.action
    print "   status: " + studio_ui.action_notice(r.action, r.detail)

    banner("editing and saving one works exactly as before")
    id = studio_docs.active_doc(app.dm).id
    app = studio.edit_document(app, id, "# Notes\n\nEdited.\n")
    print "dirty=" + studio_ui.dirty_count(app)
    sv = studio_ui.save_active(app, "")
    app = sv.app
    print "save: " + sv.action + " dirty=" + studio_ui.dirty_count(app)
    print "on disk=<" + read_file_text(projdir + "/NOTES.md") + ">"

    banner("and the .bas beside it is untouched by all of this")
    rows = studio_ui.nav_rows(app)
    r = studio_ui.activate_row(app, rows, row_index(rows, "file", "main.bas"))
    app = r.app
    print "strip:   " + studio_ui.section_label(app)
    print "heading: " + studio_ui.error_heading(studio_ui.error_body(app))
    print "section marks=" + numlist(studio_ui.section_marks(app).lines)
  end if

  ' ---- badsyntax: a file that does not parse, which says so ----------------
  ' `studio_sections.refresh` has recorded the parser's diagnostics since STU-3
  ' and nothing displayed them. A file that does not parse yields no sections,
  ' so the strip said "section: (none)", Run answered "the cursor is not inside
  ' a runnable section" — true, and useless, because the cursor is plainly
  ' inside a function — and the LINE AND COLUMN of the syntax error, the one
  ' actionable fact in the window, was thrown away on every keystroke.
  if mode = "badsyntax" then
    bf{file} = projdir + "/bad_syntax.bas"
    write(bf, "print \"one\"\n\nfunction add(a, b)\n  return a + b\nend function\n\nprint add(2, 3)\nif x = then\n")
    rows = studio_ui.nav_rows(app)
    r = studio_ui.activate_row(app, rows, row_index(rows, "file", "bad_syntax.bas"))
    app = r.app
    app.clock_fixed = 1000

    banner("opened from cold: there are no sections because there is no parse")
    print "strip:   " + studio_ui.section_label(app)
    print "heading: " + studio_ui.error_heading(studio_ui.error_body(app))
    print "errors:  <" + studio_ui.error_body(app) + ">"
    ' The gutter. 0-based, because a text buffer counts lines from 0 and the
    ' parser counts them from 1 — an off-by-one here puts the marker on the line
    ' above the mistake, which is worse than no marker.
    em = studio_ui.error_marks(app)
    app = em.app
    print "marks:   lines=" + numlist(em.lines) + " signature=" + em.signature
    sm = studio_ui.section_marks(app)
    app = sm.app
    print "         section marks=" + numlist(sm.lines) + " (none: there are no sections)"
    ' The caret is INSIDE add(). Blaming the cursor would send the user to move
    ' it, which cannot help.
    r = studio_ui.run_section(app, 3, 2)
    app = r.app
    print "-> Run with the caret inside add(): " + r.action
    print "   status: " + studio_ui.action_notice(r.action, r.detail)

    banner("the marks MOVE with the error and go when it is fixed")
    ' The signature is what the shell gates its redraw on, so these three values
    ' are the whole of "the gutter keeps up". A count would not do it: the first
    ' two errors are both one error, on different lines.
    id = studio_docs.active_doc(app.dm).id
    app = studio.edit_document(app, id, "print \"one\"\n\nif q = then\n  return a + b\nend function\n")
    em = studio_ui.error_marks(app)
    app = em.app
    print "moved:   lines=" + numlist(em.lines) + " signature=" + em.signature
    app = studio.edit_document(app, id, "print \"one\"\n\nfunction add(a, b)\n  return a + b\nend function\n")
    em = studio_ui.error_marks(app)
    app = em.app
    print "fixed:   lines=" + numlist(em.lines) + " signature=<" + em.signature + ">"
    print "         section marks back=" + numlist(studio_ui.section_marks(app).lines)

    banner("a file that DOES parse is unaffected — no parse line, no heading count")
    rows = studio_ui.nav_rows(app)
    r = studio_ui.activate_row(app, rows, row_index(rows, "file", "main.bas"))
    app = r.app
    ' Thread the view back, exactly as `studio_shell.refresh_run` does. A caller
    ' that drops it does not merely re-parse: on the NEXT failed parse there is
    ' no cached state to retain last-known-good sections from, so the state is
    ' rebuilt from the workspace and comes back empty. That is the difference
    ' between this case reaching `refused` (what the window does) and reaching
    ' `no-parse`.
    vw = studio_ui.view_for(app)
    app = vw.app
    print "strip:   " + studio_ui.section_label(app)
    print "heading: " + studio_ui.error_heading(studio_ui.error_body(app))
    print "errors:  <" + studio_ui.error_body(app) + ">"

    banner("broken by TYPING into a file that parsed a moment ago")
    ' On a failed parse the state keeps its last-known-good sections — it must,
    ' or a user mid-keystroke would have every result renumbered out from under
    ' them — but they describe the OLD text, so the caret's new byte offset need
    ' not land in one. Either way the answer is the same sentence with the same
    ' address, which is the point: one fact, one message, however you got here.
    id = studio_docs.active_doc(app.dm).id
    app = studio.edit_document(app, id, "print \"main\"\nif y = then\n")
    r = studio_ui.sync_cursor(app, id, 0, 0)
    app = r.app
    vw = studio_ui.view_for(app)
    app = vw.app
    print "sections retained=" + count(vw.st.sections) + " valid=" + vw.st.valid
    r = studio_ui.run_section(app, 0, 0)
    app = r.app
    print "-> Run: " + r.action
    print "   status: " + studio_ui.action_notice(r.action, r.detail)
    print "heading: " + studio_ui.error_heading(studio_ui.error_body(app))
    print "errors:  <" + studio_ui.error_body(app) + ">"
  end if

  ' ---- runrefuse: a run Studio DECLINES, and where its sentence goes -------
  ' `refused` and `failed` both return from `run_section` with `active` false,
  ' so `tick_run` is never polled and `add_result` is never reached. Nothing
  ' executed, so there is correctly no result -- but that left the message with
  ' exactly one home, the run strip, which is a single row beside three buttons
  ' and ellipsizes. A user saw "run: refused [sec-3] — that sec…" and the rest
  ' of the sentence existed nowhere on screen, while the pane whose whole job is
  ' to say what went wrong answered "(none)".
  if mode = "runrefuse" then
    df{file} = projdir + "/dup.bas"
    write(df, "function mul(a, b)\n  return a * b\nend function\n\nprint mul(2, 3)\n")
    rows = studio_ui.nav_rows(app)
    r = studio_ui.activate_row(app, rows, row_index(rows, "file", "dup.bas"))
    app = r.app
    app.clock_fixed = 1000
    id = studio_docs.active_doc(app.dm).id
    r = studio_ui.sync_cursor(app, id, 1, 0)
    app = r.app
    print "at the caret: " + studio_ui.section_label(app)

    banner("mul() duplicated verbatim — neither copy is `the` mul() any more")
    app = studio.edit_document(app, id, "function mul(a, b)\n  return a * b\nend function\n\nfunction mul(a, b)\n  return a * b\nend function\n\nprint mul(2, 3)\n")
    r = studio_ui.sync_cursor(app, id, 1, 0)
    app = r.app
    r = studio_ui.run_section(app, 1, 0)
    app = r.app
    print "-> Run: action=" + r.action + " active=" + r.active

    banner("the strip says it in one line; the pane says it in full")
    print "strip:   " + studio_ui.run_line(studio_ui.exec_session(app))
    print "heading: " + studio_ui.error_heading(studio_ui.error_body(app))
    print "errors:  <" + studio_ui.error_body(app) + ">"
    ' NOT the previous run's output. A refusal produced none, and output from an
    ' earlier run shown beside "refused:" reads as output of the run that was
    ' refused.
    print "prefix:  <" + studio_ui.prefix_body(app) + ">"
    print "target:  <" + studio_ui.target_body(app) + ">"

    banner("the heading counts, so a pane below the fold still says there is one")
    print "nothing:  " + studio_ui.error_heading("(none)")
    print "in flight: " + studio_ui.error_heading("(running)")
    print "one:      " + studio_ui.error_heading("target [sec-3] 8:1  undefined variable: x")
    ' A raw stderr capture ends in a newline; the blank line it leaves behind is
    ' not a third error.
    print "two:      " + studio_ui.error_heading("first\nsecond\n")
  end if

  ' ---- runstop: refusal, stopping, and the states around a run -------------
  if mode = "runstop" then
    print "-> Run with nothing open: " + studio_ui.run_section(app, 0, 0).action
    print "-> Stop with nothing running: " + studio_ui.stop_run(app).action
    print "-> Force Stop with nothing running: " + studio_ui.force_stop_run(app).action
    print "-> a tick with nothing running: " + studio_ui.tick_run(app).action

    ' Never ends on its own, so only a stop can finish it.
    lf{file} = projdir + "/loop.bas"
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
    persist_result = studio.persist(again)
    idx = studio_drafts.open_index(home)
    print studio_drafts.summary(idx)
    third = studio.launch(home)
    d3 = studio_docs.doc_by_id(third.dm, id)
    print "after a clean save, reopened dirty=" + studio_docs.is_dirty(d3)

    banner("a file that changed underneath the draft is a CONFLICT, not a silent overwrite")
    app2 = studio.launch(home)
    app2 = studio.edit_document(app2, id, "typed again\n")
    persist_result = studio.persist(app2)
    ' Someone else edits the file while Studio is closed.
    w{file} = projdir + "/main.bas"
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
    bf{file} = projdir + "/branchy.bas"
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
    ' Keyed the way studio_ui keys them — by the document's PATH, not its minted
    ' id. This driver reaches past studio_ui into studio_branches to build the
    ' fixture, so it has to use the same key the window does or it builds a tree
    ' the window cannot find. (That is the layering rule earning its keep: the
    ' one place that skipped studio_ui is the one place this broke.)
    dockey = studio_ui.doc_key(studio_docs.active_doc(app.dm))
    tree = studio_ui.branch_tree(app)
    a = studio_branches.add(tree, dockey, point, "Low", "", v.st)
    tree = studio_branches.bind(a.tree, a.id, "threshold", "0.25").tree
    b = studio_branches.add(tree, dockey, point, "High", "", v.st)
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
    ' And they survive it keyed by PATH, so the doc id the relaunch mints for
    ' this file — which is a different one — no longer decides whether the
    ' branches can be found.
    persist_result = studio.persist(app)
    again = studio.launch(home)
    back = studio_ui.branch_tree(again)
    print studio_branches.summary(back, dockey, v.st)
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
    a{file} = projdir + "/main.bas"
    write(a, "changed on disk while Studio was clean\n")
    b{file} = projdir + "/README.md"
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
