' STU-6 headless driver: semantic history, the read-only tool surface, and the
' orientation agent. FULLY OFFLINE — the provider is a scripted transport, so no
' network is touched and no key is needed; what the goldens assert is what Studio
' sent, what it did with the tool calls, and what it refused.
'
' args: mode home projdir

' ---- the scripted provider -------------------------------------------------
'
' `llm.with_transport` replaces the HTTP call with a function, so these are
' complete provider replies in the anthropic wire format. Each returns the same
' answer every time, which is what makes an agent test a golden test at all.

function reply_text(m, req)
  b = "{\"model\":\"c\",\"content\":[{\"type\":\"text\",\"text\":\"You were in three.bas, in the last section, which ran clean.\"}],\"usage\":{\"input_tokens\":1,\"output_tokens\":1},\"stop_reason\":\"end_turn\"}"
  return { status: 200, headers: {}, body: b }
end function

' Asks for a real tool once, then answers. The counter lives in a record FIELD:
' a function cannot rebind a top-level scalar (it creates a local instead), which
' is the same callback-scope rule the GTK handlers follow — and here it showed up
' as a transport that requested the tool forever until the round cap stopped it.
function reply_tool_then_text(m, req)
  G_st.round = G_st.round + 1
  if G_st.round = 1 then
    b = "{\"model\":\"c\",\"content\":[{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"active_file\",\"input\":{}}],\"usage\":{\"input_tokens\":1,\"output_tokens\":1},\"stop_reason\":\"tool_use\"}"
    return { status: 200, headers: {}, body: b }
  end if
  b = "{\"model\":\"c\",\"content\":[{\"type\":\"text\",\"text\":\"You were editing three.bas.\"}],\"usage\":{\"input_tokens\":1,\"output_tokens\":1},\"stop_reason\":\"end_turn\"}"
  return { status: 200, headers: {}, body: b }
end function

program main(args)
  load persist
  load filetree
  load studio_model
  load studio_docs
  load studio
  load studio_sections
  load studio_session
  load studio_results
  load studio_ui
  load studio_history
  load studio_tools
  load studio_agent
  load llm

  mode = args[0]
  home = args[1]
  projdir = ""
  if count(args) > 2 then
    projdir = args[2]
  end if

  ' ---- history: recording, bounding, and reading back ---------------------
  if mode = "history" then
    log = studio_history.open(home)
    print "fresh: " + studio_history.summary(log)

    log = studio_history.note(log, "project_opened", "/p/demo", "demo", 1000)
    log = studio_history.note(log, "file_opened", "/p/demo/three.bas", "", 1001)
    log = studio_history.note(log, "section_selected", "sec-3", "statements", 1002)
    log = studio_history.note(log, "section_executed", "sec-3", "exit 0", 1003)
    log = studio_history.note(log, "file_saved", "/p/demo/three.bas", "", 1004)
    print "-- after five events"
    print studio_history.summary(log)

    print "-- persisted and reopened"
    studio_history.save(home, log)
    back = studio_history.open(home)
    print studio_history.summary(back)
    print "identical=" + (json_encode(back.events) = json_encode(log.events))

    print "-- an unknown kind is a programming error, not an event"
    print "is_kind(nonsense)=" + studio_history.is_kind("nonsense")
    print "is_kind(file_saved)=" + studio_history.is_kind("file_saved")

    print "-- orientation"
    o = studio_history.orientation(back)
    print "  last_file=" + studio_history._leaf(o.last_file.target)
    print "  last_run=" + o.last_run.target + " " + o.last_run.detail
    print "  last_error=" + string(o.last_error)
  end if

  ' ---- bound: the window holds, and nothing is lost silently --------------
  if mode = "bound" then
    log = studio_history.open(home)
    i = 0
    while i < 420
      log = studio_history.note(log, "section_executed", "sec-1", "exit 0", 2000 + i)
      i = i + 1
    end while
    log = studio_history.note(log, "error_raised", "sec-1", "division by zero", 9000)
    print "kept=" + count(log.events) + " window=" + studio_history.window()
    print "compacted=" + studio_history.rolled_total(log)
    print "total accounted=" + (count(log.events) + studio_history.rolled_total(log))
    for each r in log.rollups
      print "  rollup " + r.kind + " x" + r.count + " " + r.first_at + ".." + r.last_at
    end for
    print "the newest event survives: " + studio_history.last_of(log, "error_raised").detail
    print "the oldest kept is seq " + log.events[0].seq
    ' Bounded on disk as well as in memory.
    studio_history.save(home, log)
    f(file) = studio_history.path(home)
    print "store under 200k=" + (file_size(f) < 200000)
  end if

  ' ---- tools: the surface, and what it refuses ----------------------------
  if mode = "tools" then
    app = studio.launch(home)
    app = studio.create_registered_workspace(app, "ws")
    ws = app.model.workspace
    ws = studio_model.add_project(ws, "Alpha", projdir)
    app = studio.set_workspace(app, ws)
    tf(file) = projdir + "/three.bas"
    write(tf, "print \"one\"\n\nfunction add(a, b)\n  return a + b\nend function\n\nsum = add(2, 3)\nprint sum\n")
    rows = studio_ui.nav_rows(app)
    i = 0
    idx = -1
    while i < count(rows)
      if rows[i].kind = "file" then
        if find(rows[i].label, "three.bas") != nothing then
          idx = i
        end if
      end if
      i = i + 1
    end while
    r = studio_ui.activate_row(app, rows, idx)
    app = r.app
    app.clock_fixed = 1000
    d = studio_docs.active_doc(app.dm)
    rc = studio_ui.sync_cursor(app, d.id, 6, 0)
    app = rc.app
    log = studio_history.open(home)
    log = studio_history.note(log, "file_opened", projdir + "/three.bas", "", 1001)

    print "-- the whole surface, by the tier each tool's REVERSIBILITY puts it in"
    for each t in studio_tools.registry()
      print "  " + studio_tools.tier_of(t.name) + "  " + t.name
    end for
    print "count=" + count(studio_tools.registry())

    ' STU-6 asserted here that every tool was a read. STU-10 ended that
    ' deliberately, so what is asserted instead is the property that replaced it:
    ' the READ path still refuses to perform an act. `invoke` is the only way
    ' through, and it decides permission first.
    print "-- the read path still refuses an act outright"
    print "  " + studio_tools.call(app, log, "delete_path", {}).why

    print "-- current_project"
    cp = studio_tools.call(app, log, "current_project", {}).value
    ' The root is a throwaway temp path; goldens stay path-free.
    print "workspace=" + cp.workspace + " projects=" + cp.projects + " active=" + cp.active + " root=" + studio_history._leaf(cp.root)
    print "-- active_file"
    a = studio_tools.call(app, log, "active_file", {}).value
    print "name=" + a.name + " line=" + a.line + " modified=" + a.modified
    print "-- section_at_cursor"
    print json_encode(studio_tools.call(app, log, "section_at_cursor", {}).value)
    print "-- list_sections"
    for each s in studio_tools.call(app, log, "list_sections", {}).value.sections
      print "  " + s.id + " " + s.kind + " " + s.name + " line " + s.first_line
    end for
    print "-- run_state (nothing has run)"
    print json_encode(studio_tools.call(app, log, "run_state", {}).value)

    print "-- after a real run"
    rr = studio_ui.run_section(app, 6, 0)
    app = rr.app
    tk = studio_ui.tick_run(app)
    app = tk.app
    while tk.active
      tk = studio_ui.tick_run(app)
      app = tk.app
    end while
    print json_encode(studio_tools.call(app, log, "run_state", {}).value)
    print "-- section_output"
    o = studio_tools.call(app, log, "section_output", { section_id: "sec-3" }).value
    print "ran=" + o.ran + " target=<" + o.target + ">"
    print "-- section_variables"
    v = studio_tools.call(app, log, "section_variables", { section_id: "sec-3" }).value
    for each vv in v.variables
      print "  " + vv.name + " " + vv.kind + " " + vv.change
    end for
    print "-- section_results"
    print json_encode(studio_tools.call(app, log, "section_results", { section_id: "sec-3" }).value)

    print "-- REFUSALS"
    print json_encode(studio_tools.call(app, log, "write_file", {}))
    print json_encode(studio_tools.call(app, log, "run_section", {}))
    print json_encode(studio_tools.call(app, log, "delete_everything", {}))
    print json_encode(studio_tools.call(app, log, "section_output", {}))
    print "is_tool(active_file)=" + studio_tools.is_tool("active_file")
    print "is_tool(save_file)=" + studio_tools.is_tool("save_file")
  end if

  ' ---- agent: the whole path, offline ------------------------------------
  if mode = "agent" then
    app = studio.launch(home)
    app = studio.create_registered_workspace(app, "ws")
    ws = app.model.workspace
    ws = studio_model.add_project(ws, "Alpha", projdir)
    app = studio.set_workspace(app, ws)
    tf(file) = projdir + "/three.bas"
    write(tf, "print \"one\"\n\nfunction add(a, b)\n  return a + b\nend function\n\nsum = add(2, 3)\nprint sum\n")
    rows = studio_ui.nav_rows(app)
    i = 0
    idx = -1
    while i < count(rows)
      if rows[i].kind = "file" then
        if find(rows[i].label, "three.bas") != nothing then
          idx = i
        end if
      end if
      i = i + 1
    end while
    r = studio_ui.activate_row(app, rows, idx)
    app = r.app
    app.clock_fixed = 1000
    d = studio_docs.active_doc(app.dm)
    rc = studio_ui.sync_cursor(app, d.id, 6, 0)
    app = rc.app

    log = studio_history.open(home)
    log = studio_history.note(log, "project_opened", projdir, "Alpha", 1000)
    log = studio_history.note(log, "file_opened", projdir + "/three.bas", "", 1001)
    log = studio_history.note(log, "section_selected", "sec-3", "statements", 1002)
    log = studio_history.note(log, "section_executed", "sec-3", "exit 0", 1003)

    print "-- what Studio tells the model before it asks anything"
    print studio_agent.context_text(app, log)

    print "-- the system prompt says read-only in so many words"
    sp = studio_agent.system_prompt()
    print "mentions READ ONLY=" + (find(sp, "READ ONLY") != nothing)
    print "tells it not to guess=" + (find(sp, "rather than guessing") != nothing)

    print "-- a scripted provider that just answers"
    m = llm.anthropic("claude-sonnet-4-6", "sk-offline")
    m = llm.with_transport(m, reply_text)
    m = studio_agent.model(m, [])
    ans = studio_agent.ask(m, app, log, studio_agent.default_question())
    print "ok=" + ans.ok + " rounds=" + ans.rounds
    print "text=" + ans.text

    print "-- a scripted provider that calls a real tool first"
    ' The wrapper reads these. They must be assigned INSIDE the program block: a
    ' top-level statement does not run when a program block is present, so the
    ' assignments at the foot of this file never would have.
    G_app = app
    G_log = log
    G_st = { round: 0 }
    schema = { type: "object", properties: {}, required: [] }
    m2 = llm.anthropic("claude-sonnet-4-6", "sk-offline")
    m2 = llm.with_transport(m2, reply_tool_then_text)
    m2 = studio_agent.model(m2, [ llm.tool("active_file", "the open file", schema, tool_active_file) ])
    ans2 = studio_agent.ask(m2, app, log, "which file?")
    print "ok=" + ans2.ok + " rounds=" + ans2.rounds
    print "text=" + ans2.text
  end if
end program

'  The wrapper shape the program supplies: read the global, call the dispatcher.
' A tool function cannot close over the app, so this is how one reaches it — the
' same adapter rule the signal handlers follow. G_app/G_log are assigned inside
' the program block.
function tool_active_file(a)
  return studio_tools.call(G_app, G_log, "active_file", a).value
end function
