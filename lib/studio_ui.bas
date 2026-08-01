' studio_ui.bas — the INTENT layer between the GTK shell and the app model.
'
' STU-2B exists because the shell rendered but could not be driven: there were no
' signal handlers at all. Wiring them raises a testing problem, because a handler
' runs inside GTK's dispatch and the headless suite has no GTK. The answer this
' phase settles on is a split:
'
'   * A HANDLER is an ADAPTER. It extracts one plain value from the widget (a row
'     index, a page number, a buffer's text), calls exactly one function here, and
'     asks for a redraw. It contains no decisions and touches no model state.
'   * EVERY decision lives in this library, as an ordinary function over plain
'     data that a headless test calls directly.
'
' The point is not that handlers are tidy. It is that what a handler still does
' after the split is too small to hide a bug in, so the untestable surface shrinks
' to the widget-to-value extraction itself — which the display tier then covers by
' synthesising real GTK signals (see tests/run_studio.sh, ui_gui).
'
' Every function here takes the app record and plain values, returns a record
' whose `app` field is the updated app, and NEVER touches gi/GTK. This file must
' stay loadable with no display and no typelib.
'
' The row model is the load-bearing part. `nav_rows` produces the browser's rows
' ONCE, and both the renderer and `activate_row` consume that same array — the
' renderer to build one widget per row, the dispatcher to decide what row N means.
' A second, independently-derived row list would drift the moment the filesystem
' changed between a render and a click, and the user would activate a row they
' never saw. Rendering and dispatch read the same array or this is not safe.
library studio_ui


    ' Dependencies, declared rather than assumed. A library that calls into
    ' another must load it: relying on the caller to have done so turns a
    ' missing load into a runtime failure deep inside a call, and it stops
    ' working entirely once these libraries live in separate projects.
    load filetree
    load persist
    load studio_model
    load studio_docs
    load studio
    load studio_sections
    load studio_session
    load studio_results

    ' ---- the browser row model ---------------------------------------------

    ' The visible browser rows, in display order. Each row:
    '   { kind, label, path, project_id }
    ' kind is "info" (not actionable), "project", "dir" or "file" — the last two
    ' carried straight through from filetree so the tree and the dispatcher agree
    ' on what a row is by construction rather than by a parallel convention.
    '
    ' `label` is the exact text the renderer draws, so the label and the action can
    ' never describe different things.
    function nav_rows(app)
        rows = []
        ws = app.model.workspace
        if ws = nothing then
            rows = append(rows, { kind: "info", label: "(no workspace open)", path: "", project_id: "" })
            return rows
        end if
        rows = append(rows, { kind: "info", label: "Workspace: " + ws.name, path: "", project_id: "" })
        for each pr in ws.projects
            marker = "  "
            if pr.id = ws.active_project then
                marker = "* "
            end if
            rows = append(rows, { kind: "project", label: marker + pr.name, path: pr.path, project_id: pr.id })
        end for
        proj = studio_model.project_by_id(ws, ws.active_project)
        if proj = nothing then
            return rows
        end if
        nodes = filetree.scan(proj.path, ws.nav.expanded)
        for each r in filetree.flatten(nodes)
            indent = "  "
            i = 0
            while i < r.depth
                indent = indent + "  "
                i = i + 1
            end while
            glyph = "  "
            if r.kind = "dir" then
                if r.expanded then
                    glyph = "v "
                else
                    glyph = "> "
                end if
            end if
            rows = append(rows, { kind: r.kind, label: indent + glyph + r.name, path: r.path, project_id: proj.id })
        end for
        return rows
    end function

    ' Activate the row at `index` of the row array the view actually rendered.
    ' Returns { app, action, detail }, where action is one of:
    '   "out-of-range" — no such row (a stale index; the model is untouched)
    '   "none"         — an informational row; nothing to do
    '   "project"      — the project became active
    '   "expand"       — a directory was opened
    '   "collapse"     — a directory was closed
    '   "open"         — a file was opened into a document tab; detail is
    '                    "<status> <doc-id>" from the document manager
    '
    ' `rows` is passed in rather than recomputed so the action is decided against
    ' what the user saw, not against a filesystem that may have moved underneath.
    function activate_row(app, rows, index)
        if index < 0 then
            return { app: app, action: "out-of-range", detail: "" }
        end if
        n = count(rows)
        if index >= n then
            return { app: app, action: "out-of-range", detail: "" }
        end if
        row = rows[index]
        kind = row.kind

        if kind = "info" then
            return { app: app, action: "none", detail: "" }
        end if

        if kind = "project" then
            ws = app.model.workspace
            ws = studio_model.set_active_project(ws, row.project_id)
            app = studio.set_workspace(app, ws)
            return { app: app, action: "project", detail: row.project_id }
        end if

        if kind = "dir" then
            ws = app.model.workspace
            was_open = studio_model.is_expanded(ws, row.path)
            ws = studio_model.toggle_expanded(ws, row.path)
            ws = studio_model.set_selected_path(ws, row.path)
            app = studio.set_workspace(app, ws)
            act = "expand"
            if was_open then
                act = "collapse"
            end if
            return { app: app, action: act, detail: row.path }
        end if

        ' A file: select it in the browser, then open it into a tab. Opening is
        ' the document manager's business — reuse of an already-open path, the
        ' missing-file case and the directory case are all decided there.
        ws = app.model.workspace
        ws = studio_model.set_selected_path(ws, row.path)
        app = studio.set_workspace(app, ws)
        opened = studio.open_from_browser(app, row.project_id, row.path)
        return { app: opened.app, action: "open", detail: opened.status + " " + opened.id }
    end function

    ' ---- the tab row model --------------------------------------------------

    ' The notebook's pages, in tab order: { doc_id, label }. The welcome page that
    ' stands in for an empty document set is NOT a row here — it carries no
    ' document, so it can never be selected into one.
    function tab_rows(app)
        rows = []
        for each d in app.dm.docs
            rows = append(rows, { doc_id: d.id, label: studio_ui.tab_label(d) })
        end for
        return rows
    end function

    ' A tab label with markers: "! " missing, "* " dirty (unsaved), then the name.
    function tab_label(doc)
        marker = ""
        if doc.missing then
            marker = "! "
        else
            dirty = studio_docs.is_dirty(doc)
            if dirty then
                marker = "* "
            end if
        end if
        return marker + doc.display_name
    end function

    ' Make the document behind page `index` the active one. Returns
    ' { app, action, detail } with action "select" or "out-of-range".
    function select_tab(app, rows, index)
        if index < 0 then
            return { app: app, action: "out-of-range", detail: "" }
        end if
        n = count(rows)
        if index >= n then
            return { app: app, action: "out-of-range", detail: "" }
        end if
        row = rows[index]
        app = studio.set_active_document(app, row.doc_id)
        return { app: app, action: "select", detail: row.doc_id }
    end function

    ' ---- editing ------------------------------------------------------------

    ' Push an editor buffer's text into its document. Dirty is DERIVED by the
    ' document manager from content-vs-saved, so re-applying identical text is a
    ' no-op and typing back to the saved text un-dirties the tab on its own.
    '
    ' An unknown id is ignored rather than raised: a buffer can outlive its
    ' document (a tab closed while its "changed" signal was in flight), and a
    ' crash is a worse answer than a dropped keystroke on a document that is gone.
    function apply_edit(app, doc_id, text)
        doc = studio_docs.doc_by_id(app.dm, doc_id)
        if doc = nothing then
            return { app: app, action: "unknown", detail: doc_id }
        end if
        app = studio.edit_document(app, doc_id, text)
        after = studio_docs.doc_by_id(app.dm, doc_id)
        dirty = studio_docs.is_dirty(after)
        act = "clean"
        if dirty then
            act = "dirty"
        end if
        return { app: app, action: act, detail: doc_id }
    end function

    ' Push every visible editor buffer into its document.
    '
    ' GtkTextBuffer's "changed" carries no indication of WHICH document is being
    ' typed into, and comparing GObject references for identity from gBASIC is not
    ' something this codebase relies on anywhere else. So the adapter hands over
    ' every open page's (doc_id, text) pair and this decides — which is correct no
    ' matter which buffer fired, and costs one string comparison per open tab
    ' because an unchanged document is a no-op inside the document manager.
    '
    ' `buffers` is [ { doc_id, text } ]. Returns { app, action, detail } where
    ' detail names the documents whose dirty state actually moved.
    function sync_buffers(app, buffers)
        moved = []
        for each b in buffers
            doc = studio_docs.doc_by_id(app.dm, b.doc_id)
            if doc != nothing then
                before = studio_docs.is_dirty(doc)
                if doc.content != b.text then
                    app = studio.edit_document(app, b.doc_id, b.text)
                    after_doc = studio_docs.doc_by_id(app.dm, b.doc_id)
                    after = studio_docs.is_dirty(after_doc)
                    if before != after then
                        state = "clean"
                        if after then
                            state = "dirty"
                        end if
                        moved = append(moved, b.doc_id + "->" + state)
                    end if
                end if
            end if
        end for
        return { app: app, action: "synced", detail: join(moved, ",") }
    end function

    ' Save the active document. Returns { app, action, detail } with action
    ' "saved" | "error" | "unknown" | "none" (nothing open).
    function save_active(app)
        doc = studio_docs.active_doc(app.dm)
        if doc = nothing then
            return { app: app, action: "none", detail: "" }
        end if
        sv = studio.save_document(app, doc.id)
        return { app: sv.app, action: sv.status, detail: doc.id }
    end function

    ' ---- workspace / project creation --------------------------------------

    ' The next project name and directory for a "New Project" with no dialog
    ' behind it: "Project N" under <home>/projects/, N being one past the count
    ' already in the workspace. Deterministic, so a test can assert it.
    function next_project_name(app)
        ws = app.model.workspace
        n = 1
        if ws != nothing then
            n = count(ws.projects) + 1
        end if
        return "Project " + n
    end function

    function project_dir(home, name)
        return home + "/projects/" + studio_ui._slug(name)
    end function

    ' Lower-case, spaces to hyphens, and drop anything that is not alphanumeric or
    ' a hyphen — so a display name becomes a directory name that cannot escape its
    ' parent or need quoting.
    function _slug(name)
        out = []
        lowered = lower(name)
        i = 0
        while i < len(lowered)
            ch = mid(lowered, i, 1)
            keep = ""
            if ch >= "a" then
                if ch <= "z" then
                    keep = ch
                end if
            end if
            if ch >= "0" then
                if ch <= "9" then
                    keep = ch
                end if
            end if
            if ch = "-" then
                keep = ch
            end if
            if ch = " " then
                keep = "-"
            end if
            if keep != "" then
                out = append(out, keep)
            end if
            i = i + 1
        end while
        joined = join(out, "")
        if joined = "" then
            return "project"
        end if
        return joined
    end function

    ' "New Project". This is the one action that has to work on a COLD home: with
    ' no workspace open the shell renders "(no workspace open)" and every other
    ' action is a no-op, so if this needed a workspace to already exist there
    ' would still be no way in. It therefore creates one when none is open.
    '
    ' The project directory is created on disk, because a project whose path does
    ' not exist scans to an empty browser and looks identical to a broken one.
    ' Returns { app, action, detail } with action "created" and detail
    ' "<project-id> <name>".
    function new_project(app, home)
        ws = app.model.workspace
        if ws = nothing then
            app = studio.create_registered_workspace(app, "workspace")
            ws = app.model.workspace
        end if
        name = studio_ui.next_project_name(app)
        dir = studio_ui.project_dir(home, name)
        persist.ensure_dir(dir)
        ws = studio_model.add_project(ws, name, dir)
        proj = studio_model.last_project(ws)
        ws = studio_model.set_active_project(ws, proj.id)
        app = studio.set_workspace(app, ws)
        return { app: app, action: "created", detail: proj.id + " " + name }
    end function

    ' ---- file and folder creation (STU-2C) ---------------------------------
    '
    ' STU-2B left New Project creating an EMPTY directory and no way to put
    ' anything into it, so a cold start dead-ended after one click: an empty
    ' project scans to zero browser rows, and opening, expanding, editing and
    ' saving are all reachable only through a file row. These two functions are
    ' the way out.
    '
    ' Neither asks for a name, for the same reason New Project does not: a modal
    ' text dialog is an async GTK surface with no synthesisable signal behind it,
    ' and the phase that adds one should be the phase that designs how such a
    ' dialog is covered. A deterministic minted name is renameable later and is
    ' assertable now.

    ' Where a creation lands: the selected directory, the directory holding the
    ' selected file, or the active project's root when nothing is selected. This
    ' is the whole of "where does it go", so a test can pin it without creating
    ' anything. Returns "" when no project is open.
    function target_dir(app)
        ws = app.model.workspace
        if ws = nothing then
            return ""
        end if
        proj = studio_model.project_by_id(ws, ws.active_project)
        if proj = nothing then
            return ""
        end if
        sel = ws.nav.selected_path
        if sel = "" then
            return proj.path
        end if
        ' `studio_docs._is_dir` rather than a second copy of the rule: there is no
        ' is_dir builtin, `read`/`file_size` RAISE on a directory (uncatchable in
        ' gBASIC), and `list` returns empty for a plain file AND for an empty
        ' directory — so the answer has to come from the PARENT's entry type, and
        ' that subtlety should exist in exactly one place.
        isdir = studio_docs._is_dir(sel)
        if isdir then
            return sel
        end if
        parent = studio_docs._dirname(sel)
        if parent = "" then
            return proj.path
        end if
        return parent
    end function

    ' Why a name is unusable, or "" when it is fine. Names arrive from the
    ' header's name field, so this is the only guard between a user's typing and
    ' `move`/`write` — "a/b" would relocate rather than rename, and ".."/"."
    ' would target the parent or the directory itself.
    function name_problem(name)
        if trim(name) = "" then
            return "empty"
        end if
        hit = find(name, "/")
        if hit != nothing then
            return "separator"
        end if
        if name = "." then
            return "dots"
        end if
        if name = ".." then
            return "dots"
        end if
        return ""
    end function

    ' The first "untitled-N.bas" that does not already exist in `dir`. Minting a
    ' name that is free rather than one that is next means a New File can never
    ' silently truncate a file the user made outside Studio.
    function next_untitled(dir)
        return studio_ui._free_name(dir, "untitled-", ".bas")
    end function

    function next_folder_name(dir)
        return studio_ui._free_name(dir, "new-folder-", "")
    end function

    ' Resolve "what should this be called" once for both creators: a typed name
    ' is validated and must not already exist; an empty one is minted, and a
    ' minted name is free by construction. Returns { name, action, detail } where
    ' a non-empty `action` means refuse and report it.
    function _chosen_name(dir, name, kind)
        if trim(name) = "" then
            if kind = "folder" then
                return { name: studio_ui.next_folder_name(dir), action: "", detail: "" }
            end if
            return { name: studio_ui.next_untitled(dir), action: "", detail: "" }
        end if
        wanted = trim(name)
        problem = studio_ui.name_problem(wanted)
        if problem != "" then
            return { name: "", action: "invalid", detail: problem }
        end if
        probe(file) = dir + "/" + wanted
        taken = exists(probe)
        if taken then
            return { name: "", action: "exists", detail: dir + "/" + wanted }
        end if
        return { name: wanted, action: "", detail: "" }
    end function

    function _free_name(dir, prefix, suffix)
        n = 1
        while n < 1000
            cand = prefix + n + suffix
            probe(file) = dir + "/" + cand
            taken = exists(probe)
            if taken then
                n = n + 1
            else
                return cand
            end if
        end while
        return prefix + "x" + suffix
    end function

    ' "New File": create an empty file in the target directory, make it visible,
    ' select it, and open it into a tab so the user can type immediately.
    '
    ' `name` is whatever the header's name field held. Empty means "mint one", so
    ' the button still works with the field untouched — which is how STU-2C left
    ' it and what a first-time click does. Returns { app, action, detail } with
    ' action "created" | "none" (nothing open) | "invalid" | "exists".
    function new_file(app, name)
        ws = app.model.workspace
        if ws = nothing then
            return { app: app, action: "none", detail: "" }
        end if
        proj = studio_model.project_by_id(ws, ws.active_project)
        if proj = nothing then
            return { app: app, action: "none", detail: "" }
        end if
        dir = studio_ui.target_dir(app)
        chosen = studio_ui._chosen_name(dir, name, "file")
        if chosen.action != "" then
            return { app: app, action: chosen.action, detail: chosen.detail }
        end if
        path = dir + "/" + chosen.name
        persist.write_text_atomic(path, "")
        ' A file created inside a collapsed directory would exist and not be on
        ' screen, which reads as the button having done nothing.
        if dir != proj.path then
            ws = studio_model.expand_path(ws, dir)
        end if
        ws = studio_model.set_selected_path(ws, path)
        app = studio.set_workspace(app, ws)
        opened = studio.open_from_browser(app, proj.id, path)
        return { app: opened.app, action: "created", detail: path + " " + opened.id }
    end function

    ' "New Folder": create a directory in the target directory and expand the
    ' target so the new row is visible.
    '
    ' The selection deliberately does NOT move into it. If it did, a second click
    ' would create a folder inside the first and a third inside the second, which
    ' is not what "New Folder" twice means anywhere else. Clicking the folder is
    ' how you go into it — the same gesture as every other file browser.
    function new_folder(app, name)
        ws = app.model.workspace
        if ws = nothing then
            return { app: app, action: "none", detail: "" }
        end if
        proj = studio_model.project_by_id(ws, ws.active_project)
        if proj = nothing then
            return { app: app, action: "none", detail: "" }
        end if
        dir = studio_ui.target_dir(app)
        chosen = studio_ui._chosen_name(dir, name, "folder")
        if chosen.action != "" then
            return { app: app, action: chosen.action, detail: chosen.detail }
        end if
        path = dir + "/" + chosen.name
        persist.ensure_dir(path)
        if dir != proj.path then
            ws = studio_model.expand_path(ws, dir)
        end if
        app = studio.set_workspace(app, ws)
        return { app: app, action: "created", detail: path }
    end function

    ' ---- rename (STU-2D) -----------------------------------------------------

    ' Rename whatever the browser has selected to `name` (a bare name, not a
    ' path). Returns { app, action, detail }, action one of:
    '   "renamed"   — moved; the selection, the expansion set and any open tab
    '                 followed it
    '   "none"      — nothing selected
    '   "invalid"   — the name is empty, has a separator, or is "."/".."
    '   "missing"   — the selected path is no longer there
    '   "exists"    — something already has that name here
    '   "unchanged" — it is already called that
    '   "dirty"     — the file is open with unsaved text (see below)
    '   "in-use"    — a directory with an open document somewhere inside it
    '
    ' The two refusals are about documents, not files. A document is bound to its
    ' path, so renaming one means closing and reopening it, and doing that to a
    ' buffer with unsaved text would throw the text away — a rename must not be a
    ' way to lose work. The directory case is the same hazard one level up.
    function rename_selected(app, name)
        ws = app.model.workspace
        if ws = nothing then
            return { app: app, action: "none", detail: "" }
        end if
        sel = ws.nav.selected_path
        if sel = "" then
            return { app: app, action: "none", detail: "" }
        end if
        problem = studio_ui.name_problem(name)
        if problem != "" then
            return { app: app, action: "invalid", detail: problem }
        end if
        wanted = trim(name)
        src(file) = sel
        there = exists(src)
        if there = false then
            return { app: app, action: "missing", detail: sel }
        end if
        parent = studio_docs._dirname(sel)
        dest = parent + "/" + wanted
        if dest = sel then
            return { app: app, action: "unchanged", detail: sel }
        end if
        dst(file) = dest
        taken = exists(dst)
        if taken then
            return { app: app, action: "exists", detail: dest }
        end if

        isdir = studio_docs._is_dir(sel)
        if isdir then
            for each d in app.dm.docs
                inside = studio_ui._under(d.path, sel)
                if inside then
                    return { app: app, action: "in-use", detail: d.id }
                end if
            end for
        end if
        doc = studio_ui._doc_by_path(app.dm, sel)
        if doc != nothing then
            dirty = studio_docs.is_dirty(doc)
            if dirty then
                return { app: app, action: "dirty", detail: doc.id }
            end if
        end if

        move(src, dest)

        ' The expansion set holds absolute paths, so a renamed directory takes
        ' its whole subtree's expansion state with it or the tree silently
        ' collapses under the new name.
        ws = studio_ui._remap_expanded(ws, sel, dest)
        ws = studio_model.set_selected_path(ws, dest)
        app = studio.set_workspace(app, ws)

        if doc != nothing then
            was_active = doc.id = app.dm.active
            c = studio.close_document(app, doc.id, "discard")
            app = c.app
            proj = studio_model.project_by_id(ws, ws.active_project)
            pid = ""
            if proj != nothing then
                pid = proj.id
            end if
            opened = studio.open_from_browser(app, pid, dest)
            app = opened.app
            if was_active then
                app = studio.set_active_document(app, opened.id)
            end if
        end if
        return { app: app, action: "renamed", detail: sel + " " + dest }
    end function

    ' Every expanded path at or under `old_path`, rewritten to sit under
    ' `new_path` — or dropped entirely when `new_path` is "" (a deletion).
    ' (`to` and `from` are reserved words in gBASIC, hence the longer names.)
    function _remap_expanded(ws, old_path, new_path)
        nav = ws.nav
        moved = []
        for each p in nav.expanded
            keep = p
            if p = old_path then
                keep = new_path
            else
                under = studio_ui._under(p, old_path)
                if under then
                    if new_path = "" then
                        keep = ""
                    else
                        keep = new_path + mid(p, len(old_path), len(p) - len(old_path))
                    end if
                end if
            end if
            if keep != "" then
                moved = append(moved, keep)
            end if
        end for
        nav.expanded = moved
        ws.nav = nav
        return ws
    end function

    ' Is `path` inside directory `dir`? A prefix match alone would call
    ' "/a/srcery" a child of "/a/src", so the separator has to be part of it.
    function _under(path, dir)
        pre = dir + "/"
        if len(path) <= len(pre) then
            return false
        end if
        return mid(path, 0, len(pre)) = pre
    end function

    function _doc_by_path(dm, path)
        for each d in dm.docs
            if d.path = path then
                return d
            end if
        end for
        return nothing
    end function

    ' ---- delete (STU-2D) -----------------------------------------------------

    ' Delete the selected file or empty directory — but only on the SECOND click.
    ' `armed` is the path a previous click armed; the caller stores whatever comes
    ' back in `armed` and hands it in next time.
    '
    ' Arming is keyed to the path rather than to a flag, so clicking a different
    ' row between the two presses re-arms on the new row instead of deleting it.
    ' There is no confirmation dialog for the same reason there is no name dialog:
    ' it would be an async surface no test can drive. Two clicks is a
    ' confirmation the whole suite can press.
    '
    ' Returns { app, action, detail, armed }, action one of "armed" | "deleted" |
    ' "none" | "missing" | "not-empty".
    function delete_selected(app, armed)
        ws = app.model.workspace
        if ws = nothing then
            return { app: app, action: "none", detail: "", armed: "" }
        end if
        sel = ws.nav.selected_path
        if sel = "" then
            return { app: app, action: "none", detail: "", armed: "" }
        end if
        if armed != sel then
            return { app: app, action: "armed", detail: sel, armed: sel }
        end if

        ref(file) = sel
        there = exists(ref)
        if there = false then
            ws = studio_model.set_selected_path(ws, "")
            app = studio.set_workspace(app, ws)
            return { app: app, action: "missing", detail: sel, armed: "" }
        end if

        isdir = studio_docs._is_dir(sel)
        if isdir then
            d(dir) = sel
            if count(list(d)) > 0 then
                ' Recursive deletion is a different promise from "delete this",
                ' and it deserves a confirmation that names what goes with it.
                return { app: app, action: "not-empty", detail: sel, armed: "" }
            end if
            remove_dir(sel)
        else
            doc = studio_ui._doc_by_path(app.dm, sel)
            if doc != nothing then
                ' The user confirmed the file; the buffer goes with it.
                c = studio.close_document(app, doc.id, "discard")
                app = c.app
            end if
            delete(ref)
        end if

        ws = app.model.workspace
        ws = studio_ui._remap_expanded(ws, sel, "")
        ws = studio_model.set_selected_path(ws, "")
        app = studio.set_workspace(app, ws)
        return { app: app, action: "deleted", detail: sel, armed: "" }
    end function

    ' ---- closing a tab (STU-2D) ---------------------------------------------

    ' Close the active document. A clean one closes on the first click; an unsaved
    ' one arms exactly like Delete, so discarding work always takes two presses.
    ' Returns { app, action, detail, armed }, action "closed" | "armed-close" |
    ' "none".
    function close_active(app, armed)
        doc = studio_docs.active_doc(app.dm)
        if doc = nothing then
            return { app: app, action: "none", detail: "", armed: "" }
        end if
        dirty = studio_docs.is_dirty(doc)
        if dirty then
            if armed != doc.id then
                return { app: app, action: "armed-close", detail: doc.id, armed: doc.id }
            end if
        end if
        c = studio.close_document(app, doc.id, "discard")
        return { app: c.app, action: "closed", detail: doc.id, armed: "" }
    end function

    ' ---- what the window says back (STU-2D) ---------------------------------

    ' The status-bar line for an outcome. Every action gets one: a refusal that
    ' says nothing is indistinguishable from a button that is not wired, which is
    ' precisely how STU-2B's window felt before it had any handlers at all.
    ' Returns "" for the outcomes that are their own feedback — a row opening, a
    ' tab switching, a keystroke landing — where a status line would just be
    ' noise over something the user can already see.
    function action_notice(action, detail)
        leaf = studio_ui._leaf(detail)
        if action = "created" then
            ' "<path> <doc-id>" — the status line wants the file, not the id.
            return "created " + studio_ui._token_leaf(detail, 0)
        end if
        if action = "renamed" then
            ' "<from> <to>" — and what the user wants confirmed is the `to`.
            return "renamed to " + studio_ui._token_leaf(detail, 1)
        end if
        if action = "deleted" then
            return "deleted " + leaf
        end if
        if action = "closed" then
            return "closed " + leaf
        end if
        if action = "saved" then
            return "saved " + leaf
        end if
        if action = "error" then
            return "could not save " + leaf
        end if
        if action = "armed" then
            return "delete " + leaf + "? — click Delete again to confirm"
        end if
        if action = "armed-close" then
            return leaf + " has unsaved changes — click Close again to discard them"
        end if
        if action = "invalid" then
            return "that name will not do (" + detail + ")"
        end if
        if action = "exists" then
            return leaf + " already exists"
        end if
        if action = "unchanged" then
            return "already called " + leaf
        end if
        if action = "missing" then
            return leaf + " is not there"
        end if
        if action = "not-empty" then
            return leaf + " is not empty — empty it first"
        end if
        if action = "dirty" then
            return "save " + leaf + " first"
        end if
        if action = "in-use" then
            return "something inside it is open (" + leaf + ")"
        end if
        if action = "adopted" then
            return "opened " + leaf
        end if
        if action = "activated" then
            return "switched to " + leaf
        end if
        if action = "refreshed" then
            return "refreshed"
        end if
        if action = "running" then
            return "running " + detail
        end if
        if action = "materializing" then
            return "preparing " + detail
        end if
        if action = "ran" then
            ' "<section-id> <final-state>" — the strip already shows the state.
            return "finished " + studio_ui._token_leaf(detail, 0)
        end if
        if action = "refused" then
            return "will not run it — " + detail
        end if
        if action = "failed" then
            return "the run failed — " + detail
        end if
        if action = "busy" then
            return "a run is already going (" + detail + ") — stop it first"
        end if
        if action = "no-section" then
            return "the cursor is not inside a runnable section"
        end if
        if action = "stopping" then
            return "stopping " + detail
        end if
        if action = "forced" then
            return "forced " + detail + " to stop"
        end if
        if action = "idle" then
            return "nothing is running"
        end if
        if action = "none" then
            return "nothing selected"
        end if
        if action = "unknown" then
            return ""
        end if
        return ""
    end function

    ' The last path segment of whitespace-token `i` of a detail, for the details
    ' that carry two things.
    function _token_leaf(detail, i)
        parts = split(detail, " ")
        if i >= count(parts) then
            return studio_ui._leaf(detail)
        end if
        return studio_ui._leaf(parts[i])
    end function

    ' Which arm, if any, an outcome keeps alive. Anything else clears BOTH, so an
    ' arm cannot survive an unrelated click and fire much later against a
    ' selection the user has long since moved.
    function arm_kind(action)
        if action = "armed" then
            return "path"
        end if
        if action = "armed-close" then
            return "doc"
        end if
        return ""
    end function

    ' After these, the header's name field has been consumed and should empty —
    ' otherwise the next click reuses the same name and is refused as "exists",
    ' which reads as the button having broken.
    function clears_name(action)
        if action = "created" then
            return true
        end if
        if action = "renamed" then
            return true
        end if
        return false
    end function

    ' ---- opening an existing directory --------------------------------------

    ' Adopt `path` as a project, creating a workspace if none is open — so this,
    ' like New Project, works from a cold start. Studio is otherwise only usable
    ' on directories it made itself, which is the wrong way round for an IDE.
    '
    ' Returns { app, action, detail }, action one of:
    '   "adopted"   — a new project over that directory, named after its last
    '                 segment, and active
    '   "activated" — the directory was already a project here; it was made
    '                 active rather than added twice
    '   "missing"   — no such directory (a plain file counts as missing: a
    '                 project root has to be somewhere files can live)
    '   "none"      — an empty path
    function adopt_folder(app, raw)
        if raw = "" then
            return { app: app, action: "none", detail: "" }
        end if
        ' The path comes off a command line, so it arrives however it was typed:
        ' a trailing slash from tab-completion, a "." or a "..". Canonicalise
        ' first or the same directory adopts twice under two spellings.
        path = studio_docs._canonical(raw)
        if path = "" then
            return { app: app, action: "none", detail: "" }
        end if
        probe(file) = path
        there = exists(probe)
        isdir = false
        if there then
            isdir = studio_docs._is_dir(path)
        end if
        if isdir = false then
            return { app: app, action: "missing", detail: path }
        end if
        ws = app.model.workspace
        if ws = nothing then
            app = studio.create_registered_workspace(app, "workspace")
            ws = app.model.workspace
        end if
        for each pr in ws.projects
            if pr.path = path then
                ws = studio_model.set_active_project(ws, pr.id)
                app = studio.set_workspace(app, ws)
                return { app: app, action: "activated", detail: pr.id + " " + pr.name }
            end if
        end for
        name = studio_ui._leaf(path)
        ws = studio_model.add_project(ws, name, path)
        proj = studio_model.last_project(ws)
        ws = studio_model.set_active_project(ws, proj.id)
        app = studio.set_workspace(app, ws)
        return { app: app, action: "adopted", detail: proj.id + " " + name }
    end function

    ' ---- closing ------------------------------------------------------------

    ' How many open documents hold unsaved text. Closing the window persists the
    ' workspace (which documents were open) but NOT their buffers, so the caller
    ' can say so instead of letting the edits disappear quietly.
    function dirty_count(app)
        n = 0
        for each d in app.dm.docs
            dirty = studio_docs.is_dirty(d)
            if dirty then
                n = n + 1
            end if
        end for
        return n
    end function

    ' ---- refresh ------------------------------------------------------------

    ' "Refresh" = re-read the world. The browser rescans on every render already
    ' (nav_rows calls filetree.scan), so what this adds is the document side:
    ' every open buffer is re-checked against disk under the safe policy — clean
    ' documents reload, dirty ones are flagged as conflicts rather than
    ' overwritten, deleted ones are marked missing.
    '
    ' Returns { app, action, detail }; detail summarises what moved, in a fixed
    ' order so it is assertable.
    function refresh(app)
        cp = studio.checkpoint_documents(app)
        detail = "reloaded=" + join(cp.reloaded, ",") + " conflicts=" + join(cp.conflicts, ",") + " deleted=" + join(cp.deleted, ",")
        return { app: cp.app, action: "refreshed", detail: detail }
    end function

    ' ---- running a section (STU-2E) -----------------------------------------
    '
    ' STU-4 built the execution engine and STU-5A the durable results, and both
    ' have been driven only by smoke modes since: the Run strip existed as a
    ' builder nothing mounted. This is the wiring, and it is the first interaction
    ' that is not instantaneous — a run starts, then continues across GTK timer
    ' ticks — so it needs one thing the others did not: somewhere to keep the
    ' in-flight run.
    '
    ' That is `app.exec`, alongside `app.dm`: live state the app carries and the
    ' shutdown pipeline does not write, because a half-finished child process is
    ' not something to restore into.
    '
    '   app.exec = { doc_id, doc_path, sid, secs, src, session, store }
    '
    ' The section is decided ONCE, when Run is pressed, from the cursor as it was
    ' at that moment — together with the source as it was at that moment. Both are
    ' kept for the rest of the run, because a result is a statement about the text
    ' that ran, not about whatever the user has typed since.

    ' How long a Force Stop gives the child between SIGTERM and giving up on a
    ' polite exit.
    function force_grace()
        return 2
    end function

    ' Which section a 1-based position means, with the gaps filled in.
    '
    ' Section ranges cover the statements, not the whitespace between and after
    ' them, so `section_at` returns nothing for a caret on a file's trailing blank
    ' line — which is exactly where a caret sits after opening a file, and a very
    ' common place for a user to leave it. Refusing there would make Run look
    ' broken for the most ordinary click there is.
    '
    ' So a position outside every section resolves to the NEAREST one: the first
    ' if it is above them all, the last if below. Only a document with no sections
    ' at all has no answer.
    function section_for(st, source, line1, column1)
        off = studio_sections.offset_of(source, line1, column1)
        hit = studio_sections.section_at(st, off)
        if hit != nothing then
            if hit != "" then
                return hit
            end if
        end if
        n = count(st.sections)
        if n = 0 then
            return ""
        end if
        first = st.sections[0]
        if off < first.start_offset then
            return first.id
        end if
        return st.sections[n - 1].id
    end function

    ' Start a run for the active document's section at (line0, column0).
    '
    ' The position arrives in the EDITOR's units — GtkSourceView counts lines and
    ' columns from 0, the section engine counts from 1 — and the conversion lives
    ' here rather than in the handler, so it is a tested line rather than a thing
    ' someone has to remember at the widget boundary.
    '
    ' Returns { app, action, detail, active }, action one of:
    '   "running"    — the child is up; the caller should start polling
    '   "refused"    — Studio declined (an ambiguous or unparseable section)
    '   "failed"     — materialize or launch failed
    '   "busy"       — a run is already in flight; stop it first
    '   "none"       — no document open
    '   "no-section" — the cursor is not inside anything runnable
    function run_section(app, line0, column0)
        doc = studio_docs.active_doc(app.dm)
        if doc = nothing then
            return { app: app, action: "none", detail: "", active: false }
        end if
        ex = app["exec"]
        if ex != unknown then
            if ex != nothing then
                busy = studio_session.is_active(ex.session)
                if busy then
                    return { app: app, action: "busy", detail: ex.session.state, active: false }
                end if
            end if
        end if

        st = studio_sections.create(doc.id)
        st = studio_sections.refresh(st, doc.content)
        sid = studio_ui.section_for(st, doc.content, line0 + 1, column0 + 1)
        if sid = "" then
            return { app: app, action: "no-section", detail: "", active: false }
        end if

        sess = studio_session.create(doc.id, app.paths.home + "/scratch")
        ' The same test seam the headless session cases use: with the clock pinned,
        ' a result's timestamps are reproducible and a golden can hold them.
        fixed = app["clock_fixed"]
        if fixed != unknown then
            sess.clock_fixed = fixed
        end if
        sess = studio_session.run(sess, st, doc.content, sid)

        app.exec = { doc_id: doc.id, doc_path: doc.path, sid: sid, secs: st,
                     src: doc.content, session: sess,
                     store: studio_results.open(app.paths.home, doc.path) }
        act = sess.state
        detail = sid
        if sess.state = "refused" then
            detail = sess.message
        end if
        if sess.state = "failed" then
            detail = sess.message
        end if
        active = studio_session.is_active(sess)
        return { app: app, action: act, detail: detail, active: active }
    end function

    ' Advance an in-flight run one step. The caller polls this on a timer and stops
    ' when `active` comes back false.
    '
    ' The run becoming a durable RESULT happens here, on the one tick that sees it
    ' end — not in the handler, and not on a later redraw, because "the run
    ' finished" happens exactly once and recording it twice would be two rows in
    ' the history for one execution.
    function tick_run(app)
        ex = app["exec"]
        if ex = unknown then
            return { app: app, action: "idle", detail: "", active: false }
        end if
        if ex = nothing then
            return { app: app, action: "idle", detail: "", active: false }
        end if
        ex.session = studio_session.tick(ex.session)
        still = studio_session.is_active(ex.session)
        if still then
            app.exec = ex
            return { app: app, action: "running", detail: ex.sid, active: true }
        end if
        ex.session = studio_session.finalize(ex.session, ex.secs, ex.src)
        home = app.paths.home
        ex.store = studio_results.add_result(home, ex.store, studio_session.to_result(ex.session, ex.secs))
        studio_results.save(home, ex.store)
        app.exec = ex
        return { app: app, action: "ran", detail: ex.sid + " " + ex.session.state, active: false }
    end function

    ' Ask the child to stop (SIGTERM). It may not go; polling continues either way
    ' and `unresponsive` is a state the strip shows rather than hides.
    function stop_run(app)
        ex = app["exec"]
        if ex = unknown then
            return { app: app, action: "idle", detail: "", active: false }
        end if
        if ex = nothing then
            return { app: app, action: "idle", detail: "", active: false }
        end if
        running = studio_session.is_active(ex.session)
        if running = false then
            return { app: app, action: "idle", detail: "", active: false }
        end if
        ex.session = studio_session.request_stop(ex.session)
        app.exec = ex
        return { app: app, action: "stopping", detail: ex.sid, active: studio_session.is_active(ex.session) }
    end function

    ' Stop it and do not take no for an answer.
    function force_stop_run(app)
        ex = app["exec"]
        if ex = unknown then
            return { app: app, action: "idle", detail: "", active: false }
        end if
        if ex = nothing then
            return { app: app, action: "idle", detail: "", active: false }
        end if
        running = studio_session.is_active(ex.session)
        if running = false then
            return { app: app, action: "idle", detail: "", active: false }
        end if
        ex.session = studio_session.force_stop(ex.session, studio_ui.force_grace())
        app.exec = ex
        return { app: app, action: "forced", detail: ex.sid, active: studio_session.is_active(ex.session) }
    end function

    ' ---- what the run strip and its panes show ------------------------------
    '
    ' These moved out of studio_shell, where they were pure functions the headless
    ' suite could not reach because the file loads GTK. They are the only feedback
    ' a run gives, so they belong where they can be asserted; studio_shell keeps
    ' the old names as one-line delegates, and the STU-4/5A display goldens do not
    ' move.

    ' One line of session state for the strip: what is happening, to which section,
    ' and — when Studio refused or the child is gone — why.
    function run_line(session)
        if session = nothing then
            return "run: (no session)"
        end if
        line = "run: " + session.state
        if session.section_id != "" then
            line = line + " [" + session.section_id + "]"
        end if
        if session.state = "refused" then
            return line + " — " + session.message
        end if
        if session.state = "failed" then
            return line + " — " + session.message
        end if
        if session.state = "finished" then
            if session.signal != 0 then
                return line + " — killed by signal " + session.signal
            end if
            return line + " — exit " + session.exit_code
        end if
        return line
    end function

    ' Prefix output is ALWAYS shown, never folded away: it is the only way a user
    ' can see that the replay re-issued the prefix's side effects.
    '
    ' While a run is in flight the split is not yet decided, so BOTH panes show the
    ' raw stream under the prefix heading rather than guessing at a boundary that
    ' may not have been printed yet.
    function prefix_text(session)
        if session = nothing then
            return "(none)"
        end if
        if session.split_out = "pending" then
            if session.out_raw = "" then
                return "(running — no output yet)"
            end if
            return session.out_raw
        end if
        if session.split_out = "combined" then
            if session.out_prefix = "" then
                return "(none — sections 1..N combined)"
            end if
            return session.out_prefix
        end if
        if session.out_prefix = "" then
            return "(none)"
        end if
        return session.out_prefix
    end function

    function target_text(session)
        if session = nothing then
            return "(none)"
        end if
        if session.split_out = "pending" then
            return "(running — not separated yet)"
        end if
        if session.split_out = "combined" then
            return "(not separable from the prefix in this run)"
        end if
        if session.out_target = "" then
            return "(none)"
        end if
        return session.out_target
    end function

    ' The session behind the strip, or nothing when nothing has run.
    function exec_session(app)
        ex = app["exec"]
        if ex = unknown then
            return nothing
        end if
        if ex = nothing then
            return nothing
        end if
        return ex.session
    end function

    ' The results pane's body: the history for the section that last ran, judged
    ' against the sections as they were when it ran. Before anything has run there
    ' is nothing to key it on, and saying so beats an empty box.
    function results_body(app)
        ex = app["exec"]
        if ex = unknown then
            return "Results\n(nothing has run yet)"
        end if
        if ex = nothing then
            return "Results\n(nothing has run yet)"
        end if
        if ex.store = nothing then
            return "Results\n(no results store)"
        end if
        return studio_results.view_text(app.paths.home, ex.store, ex.secs, ex.sid)
    end function

    ' A path-free, clock-free line for the headless goldens.
    function exec_summary(app)
        sess = studio_ui.exec_session(app)
        if sess = nothing then
            return "exec: (none)"
        end if
        return "exec: " + studio_ui.run_line(sess)
    end function

    ' ---- deterministic summary (headless tests / diagnostics) --------------

    ' A path-free snapshot of everything an interaction can move: the browser rows
    ' (by kind and label, never by path), the tabs, and which of each is current.
    function summary(app)
        lines = []
        rows = studio_ui.nav_rows(app)
        lines = append(lines, "nav rows=" + count(rows))
        for each r in rows
            lines = append(lines, "  [" + r.kind + "] " + r.label)
        end for
        ws = app.model.workspace
        sel = ""
        if ws != nothing then
            sel = studio_ui._leaf(ws.nav.selected_path)
        end if
        lines = append(lines, "selected=" + sel)
        tabs = studio_ui.tab_rows(app)
        lines = append(lines, "tabs=" + count(tabs))
        for each t in tabs
            active = " "
            if t.doc_id = app.dm.active then
                active = "*"
            end if
            lines = append(lines, "  " + active + " " + t.doc_id + " " + t.label)
        end for
        return join(lines, "\n")
    end function

    ' Last path segment only — the goldens must not carry a temp directory.
    function _leaf(path)
        if path = "" then
            return ""
        end if
        parts = split(path, "/")
        return parts[count(parts) - 1]
    end function

end library
