' studio.bas — the gBASIC Studio application object and lifecycle (headless).
'
' This is the backbone STU-0 delivers: a deterministic STARTUP pipeline that
' assembles the authoritative Studio model from disk, and a SHUTDOWN pipeline that
' persists it atomically. It is intentionally free of GTK — the shell (studio_shell
' / examples/studio/studio.bas) is a VIEW bound to the model this layer owns, never
' a second copy of the state.
'
' Layering:   studio (lifecycle)  ->  studio_model (rules)  ->  persist (I/O)
'                                                          ->  try_decode (safe parse)
' Every store is versioned and read defensively: missing / corrupt / future-version
' inputs recover to defaults with a recorded diagnostic, never a crash.
'
' Requires persist and studio_model to be loaded by the program
' (loads live inside the `program` block).
library studio


    ' Dependencies, declared rather than assumed. A library that calls into
    ' another must load it: relying on the caller to have done so turns a
    ' missing load into a runtime failure deep inside a call, and it stops
    ' working entirely once these libraries live in separate projects.
    load studio_docs
    load studio_drafts
    load studio_viewers
    load studio_model
    load persist
    ' ---- paths -------------------------------------------------------------

    ' Resolve every store path under a single config `home` directory. Tests point
    ' `home` at a throwaway directory; a real launch would use a per-user location.
    function paths(home)
        return {
            home: home,
            settings_file: home + "/settings.json",
            session_file: home + "/session.json",
            workspaces_dir: home + "/workspaces",
            registry_file: home + "/workspaces.json"
        }
    end function

    function workspace_path(app, id)
        return app.paths.workspaces_dir + "/" + id + ".json"
    end function

    ' ---- future hooks (empty placeholders for later phases) ----------------

    ' Later Studio phases attach real behavior to these managers (editor: STU-2;
    ' section engine: STU-3; replay: STU-4; agent: STU-6). STU-0 only reserves the
    ' extension points so the app object has a stable place to grow, and marks them
    ' not-ready. They are LIVE hooks, never persisted with the model.
    function managers()
        return {
            editor: { kind: "editor", ready: false },
            section: { kind: "section", ready: false },
            replay: { kind: "replay", ready: false },
            agent: { kind: "agent", ready: false }
        }
    end function

    ' ---- load policy -------------------------------------------------------

    ' Turn a persist.read_status result into a value + a policy code:
    '   missing -> default (code "default")
    '   corrupt -> default (code "corrupt-recovered")
    '   loaded but future schema_version -> default (code "future-version-rejected")
    '   loaded and understood -> the value (code "loaded"; caller normalizes)
    function _policy(st, default_value)
        if st.status = "missing" then
            return { value: default_value, code: "default" }
        end if
        if st.status = "corrupt" then
            return { value: default_value, code: "corrupt-recovered" }
        end if
        future = studio_model.is_future(st.value)
        if future then
            return { value: default_value, code: "future-version-rejected" }
        end if
        return { value: st.value, code: "loaded" }
    end function

    ' ---- startup pipeline --------------------------------------------------

    ' main -> load global settings -> load previous session -> load its workspace
    '      -> construct the Studio model -> return the application object.
    ' Never raises on bad stored state: each store recovers to a default and
    ' appends a diagnostic. The result is the authoritative app object; the UI is
    ' built from it afterwards (studio_shell), keeping persistence and widgets apart.
    function startup(home)
        p = studio.paths(home)
        persist.ensure_dir(p.home)
        persist.ensure_dir(p.workspaces_dir)

        diagnostics = []

        ' settings
        ss = persist.read_status(p.settings_file)
        sp = studio._policy(ss, studio_model.default_settings())
        settings = sp.value
        if sp.code = "loaded" then
            settings = studio_model.normalize_settings(settings)
        end if
        diagnostics = append(diagnostics, "settings:" + sp.code)

        ' session
        es = persist.read_status(p.session_file)
        ep = studio._policy(es, studio_model.default_session())
        session = ep.value
        if ep.code = "loaded" then
            session = studio_model.normalize_session(session)
        end if
        diagnostics = append(diagnostics, "session:" + ep.code)

        ' workspace (only if the session names one and restoring is enabled)
        workspace = nothing
        want_ws = session.active_workspace
        if want_ws != "" then
            if settings.restore_last_session then
                wpath = p.workspaces_dir + "/" + want_ws + ".json"
                ws_status = persist.read_status(wpath)
                wp = studio._policy(ws_status, nothing)
                if wp.code = "loaded" then
                    workspace = studio_model.normalize_workspace(wp.value)
                    diagnostics = append(diagnostics, "workspace:loaded")
                else
                    ' missing/corrupt/future workspace: degrade to no workspace
                    ' (files+layout still restored), flag it, keep the session.
                    diagnostics = append(diagnostics, "workspace:" + wp.code)
                end if
            else
                diagnostics = append(diagnostics, "workspace:restore-disabled")
            end if
        else
            diagnostics = append(diagnostics, "workspace:none")
        end if

        model = {
            schema_version: studio_model.schema_version(),
            settings: settings,
            session: session,
            workspace: workspace
        }

        return {
            home: home,
            paths: p,
            model: model,
            managers: studio.managers(),
            diagnostics: diagnostics
        }
    end function

    ' ---- workspace lifecycle on the app object -----------------------------

    ' Create a new, empty workspace, make it the session's active workspace, and
    ' install it as the app's open workspace. Returns the updated app object.
    function create_workspace(app, name)
        model = app.model
        session = model.session
        minted = studio_model.mint_workspace_id(session)
        session = minted.session
        ws = studio_model.new_workspace(minted.id, name)
        session = studio_model.set_active_workspace(session, minted.id)
        model.session = session
        model.workspace = ws
        app.model = model
        return app
    end function

    ' Replace the app's open workspace with an updated one (after model mutations).
    function set_workspace(app, ws)
        model = app.model
        model.workspace = ws
        app.model = model
        return app
    end function

    ' ---- shutdown pipeline -------------------------------------------------

    ' collect current state -> serialize settings/session/workspace -> atomic
    ' replace each -> clean. Writes are atomic (persist), so a crash mid-save
    ' never leaves a truncated store. Returns a diagnostics array of what was saved.
    function shutdown(app)
        p = app.paths
        model = app.model
        persist.ensure_dir(p.home)
        persist.ensure_dir(p.workspaces_dir)

        saved = []
        persist.write_atomic(p.settings_file, model.settings)
        saved = append(saved, "settings")
        persist.write_atomic(p.session_file, model.session)
        saved = append(saved, "session")

        ws = model.workspace
        if ws != nothing then
            wpath = p.workspaces_dir + "/" + ws.id + ".json"
            persist.write_atomic(wpath, ws)
            saved = append(saved, "workspace:" + ws.id)
        end if
        return saved
    end function

    ' ---- deterministic summary (for headless tests / diagnostics) ----------

    ' A stable, path-free textual snapshot of the model — used by the headless test
    ' modes so save/restore can be asserted byte-exact without leaking temp paths.
    function summary(app)
        model = app.model
        s = model.settings
        se = model.session
        lines = []
        lines = append(lines, "settings.theme=" + s.theme)
        lines = append(lines, "settings.restore_last_session=" + s.restore_last_session)
        lines = append(lines, "settings.recent_limit=" + s.recent_limit)
        lines = append(lines, "session.active_workspace=" + se.active_workspace)
        win = se.window
        lines = append(lines, "session.window=" + win.width + "x" + win.height + " max=" + win.maximized)
        lines = append(lines, "session.recent=" + join(se.recent_files, ","))
        ws = model.workspace
        if ws = nothing then
            lines = append(lines, "workspace=none")
        else
            lines = append(lines, "workspace=" + ws.id + ":" + ws.name)
            lines = append(lines, "workspace.active_project=" + ws.active_project)
            lines = append(lines, "projects=" + count(ws.projects))
            for each pr in ws.projects
                lines = append(lines, "  " + pr.id + " " + pr.name + " docs=" + count(pr.documents))
            end for
            lines = append(lines, "tabs.order=" + join(ws.tabs.order, ","))
            lines = append(lines, "tabs.active=" + ws.tabs.active)
        end if
        lines = append(lines, "diagnostics=" + join(app.diagnostics, ";"))
        return join(lines, "\n")
    end function

    ' ======================================================================
    ' STU-1 — workspace registry, navigation lifecycle, and workspace ops.
    ' All additive: the STU-0 startup/shutdown/summary above are unchanged, so
    ' STU-0 stores and goldens are untouched. The registry is a SEPARATE store
    ' (workspaces.json) persisted via save_registry, not by shutdown.
    ' ======================================================================

    ' The set of known workspaces (for "open an existing workspace") plus the
    ' most-recently-opened order (for "recent workspaces").
    function default_registry()
        return { schema_version: 1, entries: [], recent: [] }
    end function

    ' Load the workspace registry into app.registry, recovering to an empty
    ' registry on a missing/corrupt/future-version file (diagnostic recorded).
    function load_registry(app)
        p = app.paths
        st = persist.read_status(p.registry_file)
        pol = studio._policy(st, studio.default_registry())
        reg = pol.value
        if pol.code = "loaded" then
            defs = studio.default_registry()
            for each k in keys(defs)
                v = reg[k]
                if v = unknown then
                    reg[k] = defs[k]
                end if
            end for
            reg.schema_version = 1
        end if
        app.registry = reg
        app.diagnostics = append(app.diagnostics, "registry:" + pol.code)
        return app
    end function

    function save_registry(app)
        p = app.paths
        persist.ensure_dir(p.home)
        persist.write_atomic(p.registry_file, app.registry)
    end function

    ' STU-1/STU-2 launch = STU-0 startup + the workspace registry + the live document
    ' manager reconstructed from the active workspace's persisted open-document
    ' metadata (studio_docs re-reads each file from disk; buffers are not persisted).
    function launch(home)
        app = studio.startup(home)
        app = studio.load_registry(app)
        app.dm = studio._reload_docs(app)
        ' Put back any unsaved buffers the last session was holding. They come
        ' back UNSAVED — a draft is the user's typing, not a decision to write it
        ' to their file.
        r = studio_drafts.restore(app.paths.home, app.dm)
        app.dm = r.dm
        app.diagnostics = append(app.diagnostics, "drafts:" + count(r.restored) + " conflicts:" + count(r.conflicts))
        ' STU-8: the library-registered viewers, read once per process. A sidecar
        ' is a library's declaration about its own types, so it changes when the
        ' library is installed, not while Studio runs.
        app.viewers = studio_viewers.load_path(studio_viewers.default_path())
        app.diagnostics = append(app.diagnostics, "viewers:" + count(app.viewers.viewers) + " problems:" + count(app.viewers.problems))
        return app
    end function

    ' Build the live document manager for the app's active workspace (empty when no
    ' workspace is open).
    function _reload_docs(app)
        ws = app.model.workspace
        if ws = nothing then
            return studio_docs.create()
        end if
        return studio_docs.from_meta(ws.docs)
    end function

    ' Fold the live document manager's metadata back into the active workspace so it
    ' is persisted (content is stripped; only open set/order/active/cursor/scroll/
    ' file-state are stored).
    function _sync_docs(app)
        ws = app.model.workspace
        if ws = nothing then
            return app
        end if
        ws.docs = studio_docs.to_meta(app.dm)
        model = app.model
        model.workspace = ws
        app.model = model
        return app
    end function

    ' STU-1/STU-2 persist = sync open documents into the workspace, then STU-0
    ' shutdown (settings/session/workspace) + the registry.
    function persist(app)
        app = studio._sync_docs(app)
        ' Drafts BEFORE the workspace: a crash between the two leaves a draft the
        ' next launch has no document to attach to, which is harmless. The other
        ' order would leave a workspace naming documents whose unsaved text was
        ' never written.
        studio_drafts.capture(app.paths.home, app.dm)
        saved = studio.shutdown(app)
        studio.save_registry(app)
        saved = append(saved, "registry")
        saved = append(saved, "drafts")
        return saved
    end function

    ' ---- recent list helper (most-recent-first, de-duplicated) -------------

    function _push_recent(recent, id)
        kept = [id]
        for each r in recent
            if r != id then
                if count(kept) < 20 then
                    kept = append(kept, r)
                end if
            end if
        end for
        return kept
    end function

    ' ---- workspace registry operations -------------------------------------

    ' Record (or update) a workspace in the registry and mark it most-recent.
    function register_workspace(app, id, name)
        reg = app.registry
        entries = []
        found = false
        for each e in reg.entries
            if e.id = id then
                entries = append(entries, { id: id, name: name })
                found = true
            else
                entries = append(entries, e)
            end if
        end for
        if not found then
            entries = append(entries, { id: id, name: name })
        end if
        reg.entries = entries
        reg.recent = studio._push_recent(reg.recent, id)
        app.registry = reg
        return app
    end function

    ' Create a new workspace, install it as active, and register it. Returns the
    ' updated app (its new workspace is app.model.workspace).
    function create_registered_workspace(app, name)
        app = studio.create_workspace(app, name)
        ws = app.model.workspace
        app = studio.register_workspace(app, ws.id, name)
        app.dm = studio_docs.create()
        return app
    end function

    ' Open an existing workspace by id: load its file, install it as active, and
    ' mark it most-recent. Missing/corrupt/future file degrades gracefully (the
    ' workspace is left closed and a diagnostic is recorded) — never a crash.
    function open_workspace(app, id)
        p = app.paths
        wpath = p.workspaces_dir + "/" + id + ".json"
        st = persist.read_status(wpath)
        pol = studio._policy(st, nothing)
        if pol.code = "loaded" then
            ws = studio_model.normalize_workspace(pol.value)
            model = app.model
            model.workspace = ws
            model.session = studio_model.set_active_workspace(model.session, id)
            app.model = model
            app.dm = studio_docs.from_meta(ws.docs)
            app = studio.register_workspace(app, id, ws.name)
            app.diagnostics = append(app.diagnostics, "open:" + id + ":loaded")
        else
            app.diagnostics = append(app.diagnostics, "open:" + id + ":" + pol.code)
        end if
        return app
    end function

    ' Rename the active workspace and update its registry entry.
    function rename_workspace(app, name)
        model = app.model
        ws = model.workspace
        if ws = nothing then
            return app
        end if
        ws.name = name
        model.workspace = ws
        app.model = model
        app = studio.register_workspace(app, ws.id, name)
        return app
    end function

    ' Close the active workspace: clear it from the model and the session (the
    ' caller persists). The registry entry is kept so it can be reopened.
    function close_workspace(app)
        app = studio._sync_docs(app)
        model = app.model
        model.workspace = nothing
        model.session = studio_model.set_active_workspace(model.session, "")
        app.model = model
        app.dm = studio_docs.create()
        return app
    end function

    ' ---- STU-1 navigation summary (deterministic, path-free) ---------------

    function nav_summary(app)
        model = app.model
        ws = model.workspace
        reg = app.registry
        lines = []
        if ws = nothing then
            lines = append(lines, "workspace=none")
        else
            lines = append(lines, "workspace=" + ws.id + ":" + ws.name)
            lines = append(lines, "active_project=" + ws.active_project)
            lines = append(lines, "projects=" + count(ws.projects))
            for each pr in ws.projects
                lines = append(lines, "  " + pr.id + " " + pr.name)
            end for
            sel = ws.nav.selected_path
            selname = ""
            if sel != "" then
                selname = studio_model._basename(sel)
            end if
            lines = append(lines, "selected=" + selname)
            lines = append(lines, "expanded=" + count(ws.nav.expanded))
        end if
        names = []
        for each e in reg.entries
            names = append(names, e.name)
        end for
        lines = append(lines, "registry=" + join(names, ","))
        lines = append(lines, "recent=" + join(reg.recent, ","))
        return join(lines, "\n")
    end function

    ' ======================================================================
    ' STU-2 — document/editor lifecycle on the app object. Thin wrappers over the
    ' headless studio_docs manager (app.dm); the shell binds editor views to it.
    ' ======================================================================

    ' Open a file into a document tab (reusing an already-open document by canonical
    ' path). `project_id` may be "" for a loose file. Returns { app, id, status }.
    function open_file(app, project_id, path)
        r = studio_docs.open(app.dm, project_id, path)
        app.dm = r.dm
        return { app: app, id: r.id, status: r.status }
    end function

    ' Open the file a browser row points at, under a given project, and activate it.
    function open_from_browser(app, project_id, path)
        return studio.open_file(app, project_id, path)
    end function

    function set_active_document(app, id)
        app.dm = studio_docs.set_active(app.dm, id)
        return app
    end function

    ' Apply an edit (the editor view calls this with the buffer text). Returns app.
    function edit_document(app, id, content)
        app.dm = studio_docs.edit(app.dm, id, content)
        return app
    end function

    function set_document_cursor(app, id, line, column)
        app.dm = studio_docs.set_cursor(app.dm, id, line, column)
        return app
    end function

    function set_document_scroll(app, id, line)
        app.dm = studio_docs.set_scroll(app.dm, id, line)
        return app
    end function

    ' Save one document. Returns { app, status }.
    function save_document(app, id)
        sv = studio_docs.save(app.dm, id)
        app.dm = sv.dm
        return { app: app, status: sv.status }
    end function

    ' Save every dirty document. Returns { app, saved, failed }.
    function save_all_documents(app)
        r = studio_docs.save_all(app.dm)
        app.dm = r.dm
        return { app: app, saved: r.saved, failed: r.failed }
    end function

    ' Close a document under an explicit decision ("save"|"discard"|"cancel").
    ' Returns { app, status }.
    function close_document(app, id, decision)
        c = studio_docs.close(app.dm, id, decision)
        app.dm = c.dm
        return { app: app, status: c.status }
    end function

    ' Detect external filesystem changes across all open documents and apply the safe
    ' policy (clean->reload, dirty->conflict, deleted->missing). Returns
    ' { app, conflicts, reloaded, deleted }.
    function checkpoint_documents(app)
        cp = studio_docs.checkpoint(app.dm)
        app.dm = cp.dm
        return { app: app, conflicts: cp.conflicts, reloaded: cp.reloaded, deleted: cp.deleted }
    end function

    ' Deterministic path-free document summary (delegates to studio_docs).
    function docs_summary(app)
        return studio_docs.summary(app.dm)
    end function

end library
