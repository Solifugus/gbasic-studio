' studio_model.bas — the gBASIC Studio domain model (headless, pure gBASIC).
'
' This is the authoritative shape of Studio's persistent state. It has NO GTK and
' NO file I/O: it constructs, mutates, and normalizes plain records. persist
' persists them; studio.bas composes them into the startup/shutdown lifecycle and
' owns the single live instance. Keeping the model pure is what makes every Studio
' data rule testable without a display.
'
' Mutation follows the copy-on-write rule (docs: array/record COW): a function
' that "changes" a record or array RETURNS the updated value; the caller
' reassigns. Nested updates (a project inside a workspace's projects array) read
' the element, mutate the copy, and write it back into the array.
'
' Stable identifiers: workspaces, projects, and documents each carry a string id
' minted from a monotonic per-container counter (ws-N / proj-N / doc-N). Nothing
' downstream (tabs, active selections, sessions) refers to a thing by array
' position — only by id.
'
' Schema versioning: every persisted record carries schema_version. On load a
' FUTURE version is rejected (the caller recovers to a default) and older/missing
' fields are normalized in, so unknown newer fields survive a round trip.
library studio_model

    ' The current on-disk schema version for all Studio stores.
    function schema_version()
        return 1
    end function

    ' ---- defaults ----------------------------------------------------------

    function default_window()
        return { width: 1200, height: 800, maximized: false }
    end function

    ' Global, user-level preferences. Typed fields with sensible defaults.
    function default_settings()
        return {
            schema_version: 1,
            theme: "system",
            restore_last_session: true,
            recent_limit: 10
        }
    end function

    ' The last-session record: which workspace was open, window geometry, recent
    ' files, and the counter used to mint the next workspace id.
    function default_session()
        return {
            schema_version: 1,
            active_workspace: "",
            next_ws: 1,
            window: studio_model.default_window(),
            recent_files: []
        }
    end function

    ' A fresh, empty workspace with the given stable id and display name.
    ' `nav` holds STU-1 navigation state (browser selection + expanded dirs); it is
    ' additive — STU-0 workspaces without it are normalized in, and it is not part of
    ' the STU-0 summary, so existing goldens are unaffected. `sections` (STU-3) is
    ' additive on exactly the same terms: a list of per-document execution-section
    ' persist records (studio_sections.to_persist tagged with its doc_id), backfilled
    ' to [] by normalize_workspace for any workspace saved before STU-3.
    function new_workspace(id, name)
        return {
            schema_version: 1,
            id: id,
            name: name,
            next_seq: 1,
            active_project: "",
            projects: [],
            tabs: { order: [], active: "" },
            nav: { selected_path: "", expanded: [] },
            docs: { open: [], active: "", next_doc: 1 },
            sections: []
        }
    end function

    ' ---- id minting --------------------------------------------------------

    ' Mint the next workspace id from the session counter. Returns the updated
    ' session and the new id together (COW: caller reassigns the session).
    function mint_workspace_id(session)
        seq = session.next_ws
        session.next_ws = seq + 1
        return { session: session, id: "ws-" + seq }
    end function

    ' ---- workspace mutation ------------------------------------------------

    ' Last path segment of a path (its display name), or the whole path if none.
    function _basename(path)
        name = path
        for each seg in split(path, "/")
            if seg != "" then
                name = seg
            end if
        end for
        return name
    end function

    ' Index of the project with `id` in the workspace, or -1.
    function _project_index(ws, id)
        i = 0
        for each p in ws.projects
            pid = p.id
            if pid = id then
                return i
            end if
            i = i + 1
        end for
        return 0 - 1
    end function

    ' Add a project (name + folder path) to a workspace. The project receives a
    ' stable id (proj-N) and becomes the active project if none is set. Returns
    ' the updated workspace; the new id is `ws-after.active_project` only if it was
    ' the first — use last_project() to read the new project regardless.
    function add_project(ws, name, path)
        seq = ws.next_seq
        pid = "proj-" + seq
        ws.next_seq = seq + 1
        proj = {
            id: pid,
            name: name,
            path: path,
            next_seq: 1,
            documents: []
        }
        ws.projects = append(ws.projects, proj)
        if ws.active_project = "" then
            ws.active_project = pid
        end if
        return ws
    end function

    ' The most recently added project (or nothing when there are none).
    function last_project(ws)
        n = count(ws.projects)
        if n = 0 then
            return nothing
        end if
        return ws.projects[n - 1]
    end function

    ' Open a document (a file path) inside a project. The document gets a stable
    ' id (doc-N), is added to the project, appended to the tab order, and made the
    ' active tab. Returns the updated workspace (nested COW write-back).
    function open_document(ws, project_id, path)
        idx = studio_model._project_index(ws, project_id)
        if idx < 0 then
            error "studio_model: unknown project: " + project_id
        end if
        proj = ws.projects[idx]
        seq = proj.next_seq
        docid = "doc-" + seq
        proj.next_seq = seq + 1
        doc = { id: docid, path: path, name: studio_model._basename(path) }
        proj.documents = append(proj.documents, doc)
        ' write the mutated project copy back into the array (COW)
        ws.projects[idx] = proj
        ' tabs reference documents by stable id, never by position
        tabs = ws.tabs
        tabs.order = append(tabs.order, docid)
        tabs.active = docid
        ws.tabs = tabs
        return ws
    end function

    ' Set the active project by id (validated). Returns the updated workspace.
    function set_active_project(ws, project_id)
        idx = studio_model._project_index(ws, project_id)
        if idx < 0 then
            error "studio_model: unknown project: " + project_id
        end if
        ws.active_project = project_id
        return ws
    end function

    ' Remove a project from the workspace (does NOT touch its files on disk). If it
    ' was the active project, activation falls back to the first remaining project
    ' (or "" when none). Returns the updated workspace. Unknown id is a no-op.
    function remove_project(ws, project_id)
        kept = []
        for each p in ws.projects
            if p.id != project_id then
                kept = append(kept, p)
            end if
        end for
        ws.projects = kept
        if ws.active_project = project_id then
            first = studio_model._first_project_id(ws)
            ws.active_project = first
        end if
        return ws
    end function

    ' Change a project's display name (id and path are unchanged). Returns the
    ' updated workspace (nested COW write-back).
    function rename_project(ws, project_id, name)
        idx = studio_model._project_index(ws, project_id)
        if idx < 0 then
            error "studio_model: unknown project: " + project_id
        end if
        proj = ws.projects[idx]
        proj.name = name
        ws.projects[idx] = proj
        return ws
    end function

    ' The id of the first project, or "" when the workspace has none.
    function _first_project_id(ws)
        n = count(ws.projects)
        if n = 0 then
            return ""
        end if
        p = ws.projects[0]
        return p.id
    end function

    ' The project record with `id`, or nothing.
    function project_by_id(ws, project_id)
        idx = studio_model._project_index(ws, project_id)
        if idx < 0 then
            return nothing
        end if
        return ws.projects[idx]
    end function

    ' ---- navigation state (STU-1 browser: selection + expansion) ------------

    ' Record the browser's selected node path. Returns the updated workspace.
    function set_selected_path(ws, path)
        nav = ws.nav
        nav.selected_path = path
        ws.nav = nav
        return ws
    end function

    ' True when a directory path is currently expanded in the browser.
    function is_expanded(ws, path)
        return contains(ws.nav.expanded, path)
    end function

    ' Toggle a directory path's expanded state. Returns the updated workspace.
    function toggle_expanded(ws, path)
        nav = ws.nav
        present = contains(nav.expanded, path)
        if present then
            nav.expanded = remove_value(nav.expanded, path)
        else
            nav.expanded = append(nav.expanded, path)
        end if
        ws.nav = nav
        return ws
    end function

    ' Mark a directory path expanded (idempotent). Returns the updated workspace.
    function expand_path(ws, path)
        nav = ws.nav
        present = contains(nav.expanded, path)
        if not present then
            nav.expanded = append(nav.expanded, path)
        end if
        ws.nav = nav
        return ws
    end function

    ' ---- session mutation --------------------------------------------------

    ' Record window geometry in the session. Returns the updated session.
    function set_window(session, w, h, maximized)
        session.window = { width: w, height: h, maximized: maximized }
        return session
    end function

    ' Point the session at a workspace id. Returns the updated session.
    function set_active_workspace(session, ws_id)
        session.active_workspace = ws_id
        return session
    end function

    ' Push a path onto the recent-files list (most-recent-first, de-duplicated,
    ' capped at `limit`). Returns the updated session.
    function touch_recent(session, path, limit)
        kept = [path]
        for each r in session.recent_files
            if r != path then
                if count(kept) < limit then
                    kept = append(kept, r)
                end if
            end if
        end for
        session.recent_files = kept
        return session
    end function

    ' ---- version / normalization (load-time compatibility) -----------------

    ' True when a decoded record declares a schema version newer than this build
    ' understands — the caller must refuse it and recover to a default.
    function is_future(raw)
        sv = raw["schema_version"]
        if sv = unknown then
            return false
        end if
        cur = studio_model.schema_version()
        return sv > cur
    end function

    ' Fill any missing field of a decoded settings record from the defaults, while
    ' PRESERVING unknown (future) keys already present. This is the forward/back
    ' compatible merge: old files gain new defaults; unrecognized keys survive.
    function normalize_settings(raw)
        result = raw
        defs = studio_model.default_settings()
        for each k in keys(defs)
            v = result[k]
            if v = unknown then
                result[k] = defs[k]
            end if
        end for
        result.schema_version = studio_model.schema_version()
        return result
    end function

    ' Same forward/back-compatible normalization for a session record.
    function normalize_session(raw)
        result = raw
        defs = studio_model.default_session()
        for each k in keys(defs)
            v = result[k]
            if v = unknown then
                result[k] = defs[k]
            end if
        end for
        result.schema_version = studio_model.schema_version()
        return result
    end function

    ' Same for a workspace record.
    function normalize_workspace(raw)
        result = raw
        defs = studio_model.new_workspace("", "")
        for each k in keys(defs)
            v = result[k]
            if v = unknown then
                result[k] = defs[k]
            end if
        end for
        result.schema_version = studio_model.schema_version()
        return result
    end function

end library
