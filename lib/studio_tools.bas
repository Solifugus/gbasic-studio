' studio_tools — STU-6 the read-only semantic tool surface (headless).
'
' The Agent observes Studio through the SAME operations the window uses. There is
' no second automation path: every tool here is a thin projection of a studio_ui
' or studio_* read, so "the Agent can see what the user can see" is true by
' construction rather than by two implementations agreeing for a while.
'
' READ ONLY, and structurally so — not by policy. There is no write tool in this
' file to disable, no permission flag to get wrong, and `call` dispatches through
' a fixed table: a name that is not in `registry()` is refused before anything is
' evaluated. Model-provided text is never source; the only thing a model can
' influence is which of these named functions runs and with what arguments.
'
' HOW A TOOL REACHES THE APP. gBASIC functions do not close over state, and a
' library cannot hold any, so a tool function cannot capture the app record. The
' split is therefore: this library decides everything given `(app, name, args)`,
' and the PROGRAM supplies one trivial wrapper per tool that reads its own global
' and calls `call`. That is the same adapter rule the signal handlers follow, for
' the same reason — the untestable part shrinks to a variable read.
library studio_tools


    ' Dependencies, declared rather than assumed.
    load studio_docs
    load studio_model
    load studio_sections
    load studio_results
    load studio_history
    load studio_ui
    load studio_permissions
    load studio_teaching
    load studio_git

    function schema_version()
        return 1
    end function

    function _obj()
        return { type: "object", properties: {}, required: [] }
    end function

    function _section_arg()
        return { type: "object",
                 properties: { section_id: { type: "string" } },
                 required: ["section_id"] }
    end function

    ' The whole surface. Each entry is { name, description, schema } — the
    ' callable is the caller's to supply, because only the caller has the app.
    function registry()
        out = []
        out = append(out, { name: "current_project",
            description: "The workspace and active project: names, root path, and how many projects are open.",
            schema: studio_tools._obj() })
        out = append(out, { name: "open_files",
            description: "Every document currently open, with its display name, whether it has unsaved changes, and which one is active.",
            schema: studio_tools._obj() })
        out = append(out, { name: "active_file",
            description: "The document in front of the user: its name, its cursor position, and whether it is modified.",
            schema: studio_tools._obj() })
        out = append(out, { name: "list_sections",
            description: "The execution sections of the active document, in order, with their ids, kinds and names.",
            schema: studio_tools._obj() })
        out = append(out, { name: "section_at_cursor",
            description: "Which section the caret is in — the one Run would run.",
            schema: studio_tools._obj() })
        out = append(out, { name: "run_state",
            description: "The state of the current or most recent run, and whether the section at the cursor is warm, cold or has never run.",
            schema: studio_tools._obj() })
        out = append(out, { name: "section_results",
            description: "The recorded results for one section, newest first: outcome, exit code, and whether the section has been edited since.",
            schema: studio_tools._section_arg() })
        out = append(out, { name: "section_output",
            description: "The captured output of a section's most recent run, prefix and target kept apart.",
            schema: studio_tools._section_arg() })
        out = append(out, { name: "section_variables",
            description: "The variables a section's most recent run left behind, with a bounded preview of each value.",
            schema: studio_tools._section_arg() })
        out = append(out, { name: "recent_actions",
            description: "What the user has been doing, newest first, in Studio's own vocabulary.",
            schema: studio_tools._obj() })
        out = append(out, { name: "where_was_i",
            description: "A reconstruction of the user's working context: last file, last section, last run, last error.",
            schema: studio_tools._obj() })
        ' A READ, and it lives with the reads: asking what an agent may point at
        ' changes nothing. Putting it in act_registry would have made `is_act`
        ' true for it, routing it to a dispatcher with no branch for it.
        out = append(out, { name: "git_status",
            description: "The working-tree status of the active project's repository, if it is one: which files are modified, added, deleted or untracked.",
            schema: studio_tools._obj() })
        out = append(out, { name: "git_history",
            description: "Recent commits in the active project's repository: author, when, and subject.",
            schema: { type: "object", properties: { limit: { type: "number" } }, required: [] } })
        out = append(out, { name: "list_widgets",
            description: "The parts of the window an agent may point at, and which gestures each can perform.",
            schema: studio_tools._obj() })
        for each a in studio_tools.act_registry()
            out = append(out, a)
        end for
        return out
    end function

    ' ---- STU-10: the act tools ---------------------------------------------
    '
    ' PARITY BY CONSTRUCTION (§12). Every one of these calls the SAME studio_ui
    ' function the toolbar calls. There is no second automation path and there is
    ' nothing here that a user cannot do — which is the design's requirement, and
    ' it is enforced by a grep rather than by intention: `agent_parity` fails if an
    ' act tool reaches past studio_ui into the model directly.
    '
    ' TIERS are assigned by REVERSIBILITY, not by how dangerous the name sounds
    ' (§17). Editing code is `local` because a buffer edit is unsaved until Save
    ' and Studio can put it back. Deleting a file is `external` because it is in
    ' the §8.3 non-rewindable set — Studio cannot.
    function act_registry()
        out = []
        out = append(out, { name: "open_document", tier: "local",
            description: "Open a file from the project browser into a tab, and make it active.",
            schema: { type: "object", properties: { path: { type: "string" } }, required: ["path"] } })
        out = append(out, { name: "select_document", tier: "local",
            description: "Make an already-open document the active tab.",
            schema: { type: "object", properties: { doc_id: { type: "string" } }, required: ["doc_id"] } })
        out = append(out, { name: "move_cursor", tier: "local",
            description: "Put the caret at a line and column of the active document. Lines and columns are 0-based, as the editor counts them.",
            schema: { type: "object", properties: { line: { type: "number" }, column: { type: "number" } }, required: ["line"] } })
        out = append(out, { name: "edit_document", tier: "local",
            description: "Replace the active document's whole text. The change is UNSAVED, exactly as if the user had typed it.",
            schema: { type: "object", properties: { content: { type: "string" } }, required: ["content"] } })
        out = append(out, { name: "execute_section", tier: "local",
            description: "Run the section at the caret, in the selected branch, exactly as the Run button does.",
            schema: studio_tools._obj() })
        out = append(out, { name: "stop_execution", tier: "local",
            description: "Ask the running section to stop.",
            schema: studio_tools._obj() })
        out = append(out, { name: "create_branch", tier: "local",
            description: "Create an exploratory branch at the section under the caret and select it.",
            schema: { type: "object", properties: { name: { type: "string" } }, required: ["name"] } })
        out = append(out, { name: "bind_value", tier: "local",
            description: "Add a binding to the selected branch, written as 'name = value'.",
            schema: { type: "object", properties: { binding: { type: "string" } }, required: ["binding"] } })
        out = append(out, { name: "create_file", tier: "local",
            description: "Create a new file in the browser's target directory.",
            schema: { type: "object", properties: { name: { type: "string" } }, required: [] } })
        out = append(out, { name: "create_folder", tier: "local",
            description: "Create a new folder in the browser's target directory.",
            schema: { type: "object", properties: { name: { type: "string" } }, required: [] } })
        ' --- external: the things Studio cannot undo -------------------------
        out = append(out, { name: "save_document", tier: "external",
            description: "Write the active document's buffer to its file. External because it overwrites what is on disk.",
            schema: studio_tools._obj() })
        out = append(out, { name: "delete_path", tier: "external",
            description: "Delete the file or folder selected in the browser. Not undoable by Studio.",
            schema: studio_tools._obj() })
        ' Teaching (§13). `local` rather than `read`: it changes what the user
        ' sees and can take the keyboard, which is not an observation — but it is
        ' entirely reversible, so it does not belong beside deleting a file.
        out = append(out, { name: "point_at", tier: "local",
            description: "Draw the user's attention to a part of the window: highlight, pulse, focus, reveal, or annotate a line range of the editor. Names a widget, not a position.",
            schema: { type: "object",
                      properties: { widget: { type: "string" },
                                    gesture: { type: "string" },
                                    detail: { type: "string" } },
                      required: ["widget", "gesture"] } })
        ' STU-11: git, at the tier its reversibility earns. `git_commit` is
        ' `local` -- a commit stays in this repository and someone who knows git
        ' can undo it. Pushing is not here at all: the agent has no tool that
        ' reaches a remote, which is a stronger statement than gating one.
        out = append(out, { name: "git_commit", tier: "local",
            description: "Stage the named paths and commit them with a message. Only affects this repository; nothing is pushed.",
            schema: { type: "object",
                      properties: { message: { type: "string" },
                                    paths: { type: "array", items: { type: "string" } } },
                      required: ["message"] } })
        out = append(out, { name: "rename_path", tier: "external",
            description: "Rename the file or folder selected in the browser.",
            schema: { type: "object", properties: { name: { type: "string" } }, required: ["name"] } })
        return out
    end function

    ' Perform one act.
    '
    ' Every branch is the same shape: call ONE studio_ui function — the same one
    ' the corresponding button calls — and turn its result into a tool result. No
    ' branch reaches into studio_docs, studio_model or the filesystem directly;
    ' that is what makes "the Agent invokes the same operations the toolbar does"
    ' a property of the code rather than a claim in a document, and `agent_parity`
    ' greps for it.
    '
    ' EVERY ACT IS AUDITED (§14/§17), including the ones that fail. An agent that
    ' tried to delete a file and was refused is exactly the thing someone reading
    ' the history later needs to see; recording only successes would make the log
    ' a record of what worked rather than of what was attempted.
    function _act(app, log, name, args)
        r = studio_tools._perform(app, name, args)
        log = studio_history.note(log, "agent_action", name, r.action + " " + r.detail, nothing)
        return { app: r.app, log: log, ok: r.ok, why: r.why, value: r.value, token: "" }
    end function

    function _done(app, r, value)
        ' studio_ui reports a refusal as an ACTION, not as a raise, and the
        ' vocabulary is shared with the status line. A tool result has to say
        ' whether it worked, so the refusals are translated here in one place.
        ok = true
        why = ""
        if studio_tools._is_refusal(r.action) then
            ok = false
            why = r.action + ": " + r.detail
        end if
        return { app: r.app, ok: ok, why: why, value: value,
                 action: r.action, detail: r.detail }
    end function

    function _is_refusal(action)
        return contains(["refused", "no-doc", "no-section", "no-table", "out-of-range", "armed", "armed-save", "none", "missing", "invalid", "exists", "error", "unknown"], action)
    end function

    function _fail(app, name, why)
        return { app: app, ok: false, why: why, value: nothing,
                 action: "refused", detail: why }
    end function

    function _perform(app, name, args)
        if name = "open_document" then
            path = args["path"]
            if not is_string(path) then
                return studio_tools._fail(app, name, "open_document needs a path")
            end if
            rows = studio_ui.nav_rows(app)
            app = rows.app
            i = 0
            for each row in rows.rows
                if row.path = path then
                    r = studio_ui.activate_row(app, rows.rows, i)
                    return studio_tools._done(app, r, { doc: r.detail })
                end if
                i = i + 1
            end for
            return studio_tools._fail(app, name, "nothing in the browser is at " + path)
        end if
        if name = "select_document" then
            doc_id = args["doc_id"]
            if not is_string(doc_id) then
                return studio_tools._fail(app, name, "select_document needs a doc_id")
            end if
            tabs = studio_ui.tab_rows(app)
            i = 0
            for each t in tabs
                if t.doc_id = doc_id then
                    r = studio_ui.select_tab(app, tabs, i)
                    return studio_tools._done(app, r, { doc_id: doc_id })
                end if
                i = i + 1
            end for
            return studio_tools._fail(app, name, "no open document has id " + doc_id)
        end if
        if name = "move_cursor" then
            doc = studio_docs.active_doc(app.dm)
            if doc = nothing then
                return studio_tools._fail(app, name, "no document is open")
            end if
            line = args["line"]
            if not is_number(line) then
                return studio_tools._fail(app, name, "move_cursor needs a line")
            end if
            col = args["column"]
            if not is_number(col) then
                col = 0
            end if
            r = studio_ui.sync_cursor(app, doc.id, line, col)
            return studio_tools._done(app, r, { line: line, column: col })
        end if
        if name = "edit_document" then
            doc = studio_docs.active_doc(app.dm)
            if doc = nothing then
                return studio_tools._fail(app, name, "no document is open")
            end if
            content = args["content"]
            if not is_string(content) then
                return studio_tools._fail(app, name, "edit_document needs content")
            end if
            ' The same call the editor's own "changed" handler makes, with the
            ' same argument shape: a list of buffers. One entry here, because an
            ' agent edits the document it is looking at.
            r = studio_ui.sync_buffers(app, [{ doc_id: doc.id, text: content }])
            return studio_tools._done(app, r, { bytes: byte_count(content) })
        end if
        if name = "execute_section" then
            doc = studio_docs.active_doc(app.dm)
            if doc = nothing then
                return studio_tools._fail(app, name, "no document is open")
            end if
            r = studio_ui.run_section(app, doc.cursor.line, doc.cursor.column)
            return studio_tools._done(app, r, { section: r.detail, active: r.active })
        end if
        if name = "stop_execution" then
            r = studio_ui.stop_run(app)
            return studio_tools._done(app, r, { state: r.action })
        end if
        if name = "create_branch" then
            nm = args["name"]
            if not is_string(nm) then
                return studio_tools._fail(app, name, "create_branch needs a name")
            end if
            br = studio_ui.branch_rows(app)
            app = br.app
            if count(br.rows) = 0 then
                return studio_tools._fail(app, name, "there is no section at the caret to branch at")
            end if
            r = studio_ui.activate_branch_row(app, br.rows, count(br.rows) - 1, nm)
            return studio_tools._done(app, r, { branch: r.detail })
        end if
        if name = "bind_value" then
            b = args["binding"]
            if not is_string(b) then
                return studio_tools._fail(app, name, "bind_value needs a binding, written 'name = value'")
            end if
            r = studio_ui.bind_selected(app, b)
            return studio_tools._done(app, r, { binding: r.detail })
        end if
        if name = "create_file" then
            r = studio_ui.new_file(app, studio_tools._name_arg(args))
            return studio_tools._done(app, r, { created: r.detail })
        end if
        if name = "create_folder" then
            r = studio_ui.new_folder(app, studio_tools._name_arg(args))
            return studio_tools._done(app, r, { created: r.detail })
        end if
        if name = "save_document" then
            ' `armed` is Studio's own two-step for saving over a file that changed
            ' underneath. The agent passes it armed because the PERMISSION gate is
            ' the confirmation here — asking twice, once through each mechanism,
            ' would be one refusal the caller can never satisfy.
            doc = studio_docs.active_doc(app.dm)
            if doc = nothing then
                return studio_tools._fail(app, name, "no document is open")
            end if
            r = studio_ui.save_active(app, doc.id)
            return studio_tools._done(app, r, { saved: r.detail })
        end if
        if name = "delete_path" then
            ws = app.model.workspace
            if ws = nothing then
                return studio_tools._fail(app, name, "no workspace is open")
            end if
            if ws.nav.selected_path = "" then
                return studio_tools._fail(app, name, "nothing is selected in the browser")
            end if
            ' Armed with the path itself: studio_ui keys its two-step to the THING,
            ' so passing the selection here confirms that path and no other — the
            ' same guarantee the permission token gives, enforced twice by two
            ' mechanisms that were designed for it independently.
            r = studio_ui.delete_selected(app, ws.nav.selected_path)
            return studio_tools._done(app, r, { deleted: r.detail })
        end if
        if name = "point_at" then
            w = args["widget"]
            if not is_string(w) then
                return studio_tools._fail(app, name, "point_at needs a widget")
            end if
            g = args["gesture"]
            if not is_string(g) then
                return studio_tools._fail(app, name, "point_at needs a gesture")
            end if
            d = args["detail"]
            if not is_string(d) then
                d = ""
            end if
            c = studio_teaching.cue(w, g, d)
            if not c.ok then
                return studio_tools._fail(app, name, c.why)
            end if
            ' The cue is left ON THE APP for the shell to render on its next
            ' redraw. The library cannot touch a widget and must not try: a
            ' teaching gesture is a decision here and a rendering there, which is
            ' the same split every interaction in Studio already has.
            app["teach"] = c
            return { app: app, ok: true, why: "", value: c,
                     action: "pointed", detail: studio_teaching.describe(c) }
        end if
        if name = "git_commit" then
            g = studio_ui.git_state(app)
            app = g.app
            if g.state != "repo" then
                return studio_tools._fail(app, name, "this project is not a git repository")
            end if
            msg = args["message"]
            if not is_string(msg) then
                return studio_tools._fail(app, name, "git_commit needs a message")
            end if
            paths = args["paths"]
            if not is_array(paths) then
                paths = []
            end if
            r = studio_git.commit(g.root, msg, paths)
            if not r.ok then
                return studio_tools._fail(app, name, r.why)
            end if
            return { app: app, ok: true, why: "", value: { committed: count(paths) },
                     action: "committed", detail: msg }
        end if
        if name = "rename_path" then
            nm = args["name"]
            if not is_string(nm) then
                return studio_tools._fail(app, name, "rename_path needs a name")
            end if
            r = studio_ui.rename_selected(app, nm)
            return studio_tools._done(app, r, { renamed: r.detail })
        end if
        return studio_tools._fail(app, name, "no such act: " + name)
    end function

    ' An absent name is not an error for the two creators: the window mints
    ' untitled-N when its field is empty, and the agent gets the same behaviour
    ' rather than a different one.
    function _name_arg(args)
        v = args["name"]
        if is_string(v) then
            return v
        end if
        return ""
    end function

    ' A tool's tier. Everything without one declared is `read` — the STU-6 surface
    ' predates tiers, and every one of those tools observes and changes nothing.
    function tier_of(name)
        for each t in studio_tools.registry()
            if t.name = name then
                if has(t, "tier") then
                    return t.tier
                end if
                return "read"
            end if
        end for
        ' A name that is not a tool has no tier. Callers check `is_tool` first;
        ' this answers the strictest thing rather than a comfortable default.
        return "external"
    end function

    function act_names()
        out = []
        for each t in studio_tools.act_registry()
            out = append(out, t.name)
        end for
        return out
    end function

    function is_act(name)
        return contains(studio_tools.act_names(), name)
    end function

    function names()
        out = []
        for each t in studio_tools.registry()
            out = append(out, t.name)
        end for
        return out
    end function

    function is_tool(name)
        return contains(studio_tools.names(), name)
    end function

    ' THE GATE. Every tool call, read or act, comes through here — one dispatch
    ' authority, so "only registered tools run" and "no act runs without a policy
    ' decision" are one check each rather than one per caller.
    '
    ' Returns { app, log, ok, why, value, token }. The app and log come back
    ' because an act changes them; a read hands back what it was given.
    '
    ' ORDER MATTERS AND IS DELIBERATE: the name is checked against the registry
    ' BEFORE the permission decision, and the permission decision before anything
    ' runs. Deciding permission first would mean asking a policy question about a
    ' tool that does not exist — and answering it, for an unknown name, out of
    ' whatever `tier_of` guessed.
    function invoke(app, log, policy, name, args, confirmed)
        if not studio_tools.is_tool(name) then
            return { app: app, log: log, ok: false, why: "no such tool: " + name,
                     value: nothing, token: "" }
        end if
        tier = studio_tools.tier_of(name)
        d = studio_permissions.decide(policy, tier, name, args, confirmed)
        ' A REFUSED act is audited too, and this is not a nicety. "The agent tried
        ' to delete a file and was stopped" is precisely what someone reading the
        ' history later needs to see; a log of successes only is a record of what
        ' worked, not of what was attempted, and it would make an agent probing at
        ' a denied tier invisible.
        '
        ' A read is not logged either way. Reads are automatic, constant, and
        ' would bury the acts — the log is for what CHANGED and for what tried to.
        if d.verdict != "allowed" then
            if studio_tools.is_act(name) then
                log = studio_history.note(log, "agent_action", name, d.verdict + ": " + d.why, nothing)
            end if
            return { app: app, log: log, ok: false, why: d.why, value: nothing, token: d.token }
        end if
        if studio_tools.is_act(name) then
            return studio_tools._act(app, log, name, args)
        end if
        r = studio_tools.call(app, log, name, args)
        return { app: app, log: log, ok: r.ok, why: r.why, value: r.value, token: "" }
    end function

    ' The read surface, unchanged from STU-6 and still callable directly by
    ' anything that only reads. It is not a second gate: `invoke` is the only
    ' thing an agent reaches, and every act goes through `_act`.
    '
    ' Returns { ok, value } or { ok: false, why } — never raises for a bad name or
    ' bad arguments, because those arrive from a language model and a model
    ' getting a tool name wrong is an ordinary event, not a crash.
    ' (`error` is a gBASIC keyword and cannot be a record key, hence `why`.)
    function call(app, log, name, args)
        known = studio_tools.is_tool(name)
        if not known then
            return { ok: false, why: "no such tool: " + name, value: nothing }
        end if
        if studio_tools.is_act(name) then
            return { ok: false, why: name + " changes things; call it through invoke", value: nothing }
        end if
        if name = "current_project" then
            return studio_tools._ok(studio_tools._project(app))
        end if
        if name = "open_files" then
            return studio_tools._ok(studio_tools._open_files(app))
        end if
        if name = "active_file" then
            return studio_tools._ok(studio_tools._active(app))
        end if
        if name = "list_sections" then
            return studio_tools._ok(studio_tools._sections(app))
        end if
        if name = "section_at_cursor" then
            v = studio_ui.view_for(app)
            return studio_tools._ok({ section_id: v.sid, label: studio_ui.section_label(v.app) })
        end if
        if name = "run_state" then
            return studio_tools._ok(studio_tools._run_state(app))
        end if
        if name = "recent_actions" then
            return studio_tools._ok(studio_tools._recent(log))
        end if
        if name = "where_was_i" then
            return studio_tools._ok(studio_history.orientation(log))
        end if
        if name = "list_widgets" then
            return studio_tools._ok(studio_teaching.registry())
        end if
        if name = "git_status" then
            g = studio_ui.git_state(app)
            if g.state != "repo" then
                return { ok: false, why: "this project is not a git repository", value: nothing }
            end if
            return studio_tools._ok(studio_git.status(g.root))
        end if
        if name = "git_history" then
            g = studio_ui.git_state(app)
            if g.state != "repo" then
                return { ok: false, why: "this project is not a git repository", value: nothing }
            end if
            lim = args["limit"]
            if not is_number(lim) then
                lim = 10
            end if
            return studio_tools._ok(studio_git.history(g.root, lim))
        end if

        ' The three that take a section id. A missing or unknown id is reported,
        ' not guessed at.
        sid = args["section_id"]
        if sid = unknown then
            return { ok: false, why: "tool " + name + " needs a section_id", value: nothing }
        end if
        if name = "section_results" then
            return studio_tools._ok(studio_tools._results(app, sid))
        end if
        if name = "section_output" then
            return studio_tools._ok(studio_tools._output(app, sid))
        end if
        return studio_tools._ok(studio_tools._variables(app, sid))
    end function

    function _ok(v)
        return { ok: true, why: "", value: v }
    end function

    ' ---- the projections ---------------------------------------------------

    function _project(app)
        ws = app.model.workspace
        if ws = nothing then
            return { workspace: "", projects: 0, active: "", root: "" }
        end if
        proj = studio_model.project_by_id(ws, ws.active_project)
        nm = ""
        root = ""
        if proj != nothing then
            nm = proj.name
            root = proj.path
        end if
        return { workspace: ws.name, projects: count(ws.projects), active: nm, root: root }
    end function

    function _open_files(app)
        out = []
        for each d in app.dm.docs
            out = append(out, {
                name: d.display_name,
                modified: studio_docs.is_dirty(d),
                missing: d.missing,
                active: d.id = app.dm.active
            })
        end for
        return { count: count(out), files: out }
    end function

    function _active(app)
        d = studio_docs.active_doc(app.dm)
        if d = nothing then
            return { open: false, name: "", modified: false, line: 0, column: 0 }
        end if
        return { open: true, name: d.display_name, modified: studio_docs.is_dirty(d),
                 line: d.cursor.line, column: d.cursor.column, lines: count(split(d.content, "\n")) - 1 }
    end function

    function _sections(app)
        v = studio_ui.view_for(app)
        out = []
        if v.st != nothing then
            for each s in v.st.sections
                nm = ""
                if s.name != nothing then
                    nm = s.name
                end if
                out = append(out, { id: s.id, kind: s.kind, name: nm,
                                    status: s.status, first_line: s.start_line })
            end for
        end if
        return { count: count(out), sections: out }
    end function

    function _run_state(app)
        st = studio_ui.run_standing(app)
        sess = studio_ui.exec_session(st.app)
        state = "idle"
        section = ""
        if sess != nothing then
            state = sess.state
            section = sess.section_id
        end if
        return { state: state, section: section, standing: st.standing,
                 note: studio_ui.standing_line(st.app) }
    end function

    function _store_for(app)
        v = studio_ui.view_for(app)
        return v
    end function

    function _results(app, sid)
        v = studio_tools._store_for(app)
        if v.store = nothing then
            return { section_id: sid, count: 0, results: [] }
        end if
        out = []
        for each r in studio_results.history_for(v.store, sid)
            out = append(out, {
                result_id: r.result_id,
                outcome: r.outcome,
                exit_code: r.exit_code,
                at: r.started_epoch,
                seconds: r.duration_seconds,
                standing: studio_results.standing_of(r, v.st)
            })
        end for
        return { section_id: sid, count: count(out), results: out }
    end function

    function _output(app, sid)
        v = studio_tools._store_for(app)
        if v.store = nothing then
            return { section_id: sid, ran: false, prefix: "", target: "", errors: "" }
        end if
        latest = studio_results.latest_for(v.store, sid)
        if latest = nothing then
            return { section_id: sid, ran: false, prefix: "", target: "", errors: "" }
        end if
        home = app.paths.home
        return {
            section_id: sid,
            ran: true,
            prefix: studio_results.capture(home, v.store, latest.result_id, "out_prefix"),
            target: studio_results.capture(home, v.store, latest.result_id, "out_target"),
            errors: studio_results.capture(home, v.store, latest.result_id, "err_target")
        }
    end function

    function _variables(app, sid)
        v = studio_tools._store_for(app)
        if v.store = nothing then
            return { section_id: sid, ran: false, status: "none", variables: [] }
        end if
        latest = studio_results.latest_for(v.store, sid)
        if latest = nothing then
            return { section_id: sid, ran: false, status: "none", variables: [] }
        end if
        status = latest["vars_status"]
        if status = unknown then
            status = "none"
        end if
        vars = []
        if studio_results.capture_bytes(latest, "vars") > 0 then
            r = try_decode(studio_results.capture(app.paths.home, v.store, latest.result_id, "vars"))
            if r.ok then
                if is_array(r.value) then
                    before = studio_results._before_vars(app.paths.home, v.store, latest)
                    vars = studio_results.mark_changes(before, r.value)
                end if
            end if
        end if
        return { section_id: sid, ran: true, status: status, variables: vars }
    end function

    function _recent(log)
        out = []
        for each e in studio_history.recent(log, 25)
            out = append(out, { at: e.at, kind: e.kind,
                                target: studio_history._leaf(e.target), detail: e.detail })
        end for
        return { count: count(out), actions: out }
    end function

end library
