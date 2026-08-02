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
        return out
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

    ' Dispatch. Returns { ok, value } or { ok: false, why } — never raises for a
    ' bad name or bad arguments, because those arrive from a language model and a
    ' model getting a tool name wrong is an ordinary event, not a crash.
    ' (`error` is a gBASIC keyword and cannot be a record key, hence `why`.)
    function call(app, log, name, args)
        known = studio_tools.is_tool(name)
        if not known then
            return { ok: false, why: "no such tool: " + name, value: nothing }
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
