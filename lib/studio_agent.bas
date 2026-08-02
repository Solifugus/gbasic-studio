' studio_agent — STU-6 the read-only orientation agent (headless).
'
' One question, answered well: "where was I?" — after a week away, after a
' restart, after being interrupted. It answers from Studio's own state and its
' action history, through the read-only tool surface, and it cannot do anything
' else because there is nothing else in the registry.
'
' TOOL SAFETY, stated once and enforced structurally:
'   * The registry is the only dispatch authority. `studio_tools.call` refuses a
'     name it does not hold, and `llm.with_tools` refuses to send one that is not
'     defined, so a model naming an unregistered tool gets a refusal rather than
'     an evaluation.
'   * No tool writes anything. There is no write tool to permit or forbid.
'   * Model-provided text is NEVER source. Nothing here evaluates, loads or
'     interprets a model's output — it is rendered as text and nothing more.
'
' The transport is injectable (`llm.with_transport`), so the whole path is
' testable with no network and no key: the tests script the provider's replies
' and assert what Studio did with them.
library studio_agent


    ' Dependencies, declared rather than assumed.
    load llm
    load studio_tools
    load studio_history

    function schema_version()
        return 1
    end function

    ' Rounds of tool calls before the loop is stopped. Orientation needs a
    ' handful; a provider that keeps asking is looping, and a cap turns that into
    ' an error rather than a bill.
    function max_rounds()
        return 6
    end function

    function system_prompt()
        lines = []
        lines = append(lines, "You are the orientation assistant inside gBASIC Studio, an IDE for the gBASIC language.")
        lines = append(lines, "The user has come back to a project and wants to know where they were.")
        lines = append(lines, "")
        lines = append(lines, "Answer from the tools. They are the only source of truth about this workspace,")
        lines = append(lines, "and every one of them is READ ONLY: you can observe the user's project, but you")
        lines = append(lines, "cannot change anything, run anything, or write anything. Do not offer to.")
        lines = append(lines, "")
        lines = append(lines, "Be concrete and brief. Name the file, the section, and what happened last.")
        lines = append(lines, "If a section's last run failed, say so and quote the error.")
        lines = append(lines, "If the tools do not tell you something, say you do not know rather than guessing.")
        return join(lines, "\n")
    end function

    ' The context Studio volunteers before the model asks for anything. It is the
    ' same orientation record the headless goldens print, so what the model was
    ' told and what the test asserts cannot drift apart.
    function context_text(app, log)
        o = studio_history.orientation(log)
        lines = []
        lines = append(lines, "Workspace state:")
        p = studio_tools.call(app, log, "current_project", {})
        lines = append(lines, "  project: " + p.value.active + " (" + p.value.projects + " open)")
        a = studio_tools.call(app, log, "active_file", {})
        if a.value.open then
            mod = ""
            if a.value.modified then
                mod = " (unsaved changes)"
            end if
            lines = append(lines, "  active file: " + a.value.name + mod)
        else
            lines = append(lines, "  active file: none")
        end if
        s = studio_tools.call(app, log, "section_at_cursor", {})
        lines = append(lines, "  " + s.value.label)
        r = studio_tools.call(app, log, "run_state", {})
        lines = append(lines, "  run: " + r.value.state + " / " + r.value.standing)
        lines = append(lines, "")
        lines = append(lines, "Recent history:")
        lines = append(lines, "  " + o.events + " events kept, " + o.compacted + " compacted")
        lines = append(lines, studio_agent._evline("  last file opened: ", o.last_file))
        lines = append(lines, studio_agent._evline("  last section selected: ", o.last_section))
        lines = append(lines, studio_agent._evline("  last run: ", o.last_run))
        lines = append(lines, studio_agent._evline("  last error: ", o.last_error))
        lines = append(lines, studio_agent._evline("  last save: ", o.last_save))
        return join(lines, "\n")
    end function

    function _evline(label, e)
        if e = nothing then
            return label + "(none)"
        end if
        line = label + studio_history._leaf(e.target)
        if e.detail != "" then
            line = line + " — " + e.detail
        end if
        return line
    end function

    ' Build the model handle. `tools` is the array of `llm.tool` definitions the
    ' CALLER assembled (it owns the callables, because only it has the app).
    function model(provider_handle, tools)
        m = llm.with_tools(provider_handle, tools)
        return llm.with_max_tool_rounds(m, studio_agent.max_rounds())
    end function

    ' Ask. Returns { ok, text, rounds, why } — a provider failure is a value,
    ' not a raise, because the window has to keep working when the network does
    ' not.
    function ask(m, app, log, question)
        msgs = []
        msgs = append(msgs, { role: "user", content: studio_agent.context_text(app, log) + "\n\nQuestion: " + question })
        r = llm.run_tools(m, studio_agent.system_prompt(), msgs)
        rounds = 0
        if has(r, "rounds") then
            rounds = r.rounds
        end if
        return { ok: true, text: r.text, rounds: rounds, why: "" }
    end function

    ' The default question, so the button has something to press.
    function default_question()
        return "Where was I?"
    end function

end library
