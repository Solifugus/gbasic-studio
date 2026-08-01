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

    ' The first "untitled-N.bas" that does not already exist in `dir`. Minting a
    ' name that is free rather than one that is next means a New File can never
    ' silently truncate a file the user made outside Studio.
    function next_untitled(dir)
        return studio_ui._free_name(dir, "untitled-", ".bas")
    end function

    function next_folder_name(dir)
        return studio_ui._free_name(dir, "new-folder-", "")
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
    ' select it, and open it into a tab so the user can type immediately. Returns
    ' { app, action, detail } with action "created" | "none" (nothing open) and
    ' detail "<path> <doc-id>".
    function new_file(app)
        ws = app.model.workspace
        if ws = nothing then
            return { app: app, action: "none", detail: "" }
        end if
        proj = studio_model.project_by_id(ws, ws.active_project)
        if proj = nothing then
            return { app: app, action: "none", detail: "" }
        end if
        dir = studio_ui.target_dir(app)
        path = dir + "/" + studio_ui.next_untitled(dir)
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
    function new_folder(app)
        ws = app.model.workspace
        if ws = nothing then
            return { app: app, action: "none", detail: "" }
        end if
        proj = studio_model.project_by_id(ws, ws.active_project)
        if proj = nothing then
            return { app: app, action: "none", detail: "" }
        end if
        dir = studio_ui.target_dir(app)
        path = dir + "/" + studio_ui.next_folder_name(dir)
        persist.ensure_dir(path)
        if dir != proj.path then
            ws = studio_model.expand_path(ws, dir)
        end if
        app = studio.set_workspace(app, ws)
        return { app: app, action: "created", detail: path }
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
