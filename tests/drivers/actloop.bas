' STU-10 headless driver for the ACTING agent loop and provider selection.
' Offline throughout: `llm.with_transport` replaces the HTTP call with a
' function, so a scripted provider drives real tool calls against a real app and
' the tests assert what Studio actually did.
'
' args: mode home projdir

' ---- the scripted providers ------------------------------------------------

function reply_edit_then_text(m, req)
  G.round = G.round + 1
  if G.round = 1 then
    b = "{\"model\":\"c\",\"content\":[{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"edit_document\",\"input\":{\"content\":\"print \\\"written by the agent\\\"\\n\"}}],\"usage\":{\"input_tokens\":1,\"output_tokens\":1},\"stop_reason\":\"tool_use\"}"
    return { status: 200, headers: {}, body: b }
  end if
  b = "{\"model\":\"c\",\"content\":[{\"type\":\"text\",\"text\":\"I replaced the buffer. It is unsaved.\"}],\"usage\":{\"input_tokens\":1,\"output_tokens\":1},\"stop_reason\":\"end_turn\"}"
  return { status: 200, headers: {}, body: b }
end function

function reply_delete_then_text(m, req)
  G.round = G.round + 1
  if G.round = 1 then
    b = "{\"model\":\"c\",\"content\":[{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"delete_path\",\"input\":{}}],\"usage\":{\"input_tokens\":1,\"output_tokens\":1},\"stop_reason\":\"tool_use\"}"
    return { status: 200, headers: {}, body: b }
  end if
  ' What the model does with a refusal is the whole point: it must report it,
  ' not retry it and not route around it.
  b = "{\"model\":\"c\",\"content\":[{\"type\":\"text\",\"text\":\"I cannot delete that: it needs your confirmation.\"}],\"usage\":{\"input_tokens\":1,\"output_tokens\":1},\"stop_reason\":\"end_turn\"}"
  return { status: 200, headers: {}, body: b }
end function

' ---- the tool wrappers: read the global, call the ONE gate ------------------

function act_schema()
  return { type: "object", properties: { content: { type: "string" } }, required: [] }
end function

function tool_edit_document(a)
  return call_gated("edit_document", a)
end function

function tool_delete_path(a)
  return call_gated("delete_path", a)
end function

' Every tool the agent is given goes through `invoke`, with the session's policy.
' A refusal is returned to the model AS TEXT — it is information the model has to
' relay, not an exception.
'
' The state lives in FIELDS of one global record, not in separate globals. A
' gBASIC function cannot rebind a top-level scalar — the assignment silently
' creates a local — so `G.app = r.app` here looked like it worked, reported the
' act as successful, and threw the updated app away. The buffer was never
' edited and the audit trail was empty, both from the same line. Field writes on
' a global record are the shape Studio's own handlers use, for exactly this.
function call_gated(name, a)
  r = studio_tools.invoke(G.app, G.log, G.pol, name, a, "")
  G.app = r.app
  G.log = r.log
  G.calls = append(G.calls, name + " -> " + string(r.ok))
  if r.ok then
    return encode(r.value)
  end if
  return "REFUSED: " + r.why
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
  load studio_permissions
  load studio_tools
  load studio_secrets
  load studio_providers
  load studio_agent
  load llm

  mode = args[0]
  home = args[1]
  projdir = ""
  if count(args) > 2 then
    projdir = args[2]
  end if

  if mode = "providers" then
    k = studio_secrets.key_from_hex("00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff")
    persist.ensure_dir(home)
    print "-- with nothing configured"
    for each l in studio_providers.summary(home, k)
      print l
    end for
    print ""
    print "-- a provider with no key is a VALUE, not a raise: the window has to"
    print "   keep working for someone who has not configured an assistant."
    r = studio_providers.resolve(home, k, "anthropic", "")
    print "  ok=" + string(r.ok) + " — " + r.why
    print ""
    print "-- storing a key changes where it comes from, and it SAYS so"
    put_result = studio_secrets.put(home, k, "anthropic", "sk-ant-NOT-REAL-000000000000000000")
    r2 = studio_providers.resolve(home, k, "anthropic", "")
    print "  ok=" + string(r2.ok) + " source=" + r2.source
    for each l in studio_providers.summary(home, k)
      print l
    end for
    print ""
    print "-- the local provider needs no key at all. For anyone who cannot send"
    print "   their source to a third party it is not a lesser case, it is the"
    print "   only one."
    r3 = studio_providers.resolve(home, k, "local", "")
    print "  ok=" + string(r3.ok) + " source=" + r3.source
    print ""
    print "-- an unknown provider lists the real ones"
    print "  " + studio_providers.resolve(home, k, "gemini", "").why
    print ""
    print "-- and the model is overridable per resolve"
    print "  default: " + studio_providers.by_id("anthropic").model
  end if

  if mode = "acting" then
    app = studio.launch(home)
    app = studio.create_registered_workspace(app, "ws")
    ws = app.model.workspace
    ws = studio_model.add_project(ws, "Alpha", projdir)
    app = studio.set_workspace(app, ws)
    tf{file} = projdir + "/target.bas"
    write(tf, "print \"the original\"\n")
    rows = studio_ui.nav_rows(app)
    i = 0
    idx = -1
    while i < count(rows)
      if rows[i].kind = "file" then
        if find(rows[i].label, "target.bas") != nothing then
          idx = i
        end if
      end if
      i = i + 1
    end while
    r = studio_ui.activate_row(app, rows, idx)
    app = r.app
    app.clock_fixed = 1000
    log = studio_history.open(home)

    G = { app: app, log: log, calls: [], round: 0,
          pol: studio_permissions.effective({ local: "auto" }, nothing, nothing) }

    print "-- the acting system prompt states the permission model, because the"
    print "   model has to be able to explain a refusal to the user"
    sp = studio_agent.act_system_prompt()
    print "  names the tiers:        " + string(find(sp, "external") != nothing)
    print "  says stop, not retry:   " + string(find(sp, "STOP") != nothing)
    print "  forbids routing around: " + string(find(sp, "another route") != nothing)
    print ""
    print "-- a scripted provider that edits the buffer"
    m = llm.anthropic("claude-sonnet-4-6", "sk-offline")
    m = llm.with_transport(m, reply_edit_then_text)
    m = studio_agent.model(m, [ llm.tool("edit_document", "replace the buffer", act_schema(), tool_edit_document) ])
    ans = studio_agent.act(m, G.app, G.log, "replace this file with a hello world")
    print "  rounds=" + ans.rounds
    print "  text=" + ans.text
    print "  tool calls: " + join(G.calls, ", ")
    print ""
    print "-- the buffer really changed"
    print "  <" + studio_docs.active_doc(G.app.dm).content + ">"
    print "-- and it is UNSAVED, exactly as if the user had typed it"
    print "  dirty: " + string(studio_docs.is_dirty(studio_docs.active_doc(G.app.dm)))
    print "  the file on disk still says: <" + read(tf) + ">"
    print ""
    print "-- every act is in the history, with the agent named as the actor"
    for each e in studio_history.recent(G.log, 6)
      if e.kind = "agent_action" then
        print "  " + e.kind + " " + e.target + " — " + e.detail
      end if
    end for
  end if

  if mode = "gated" then
    app = studio.launch(home)
    app = studio.create_registered_workspace(app, "ws")
    ws = app.model.workspace
    ws = studio_model.add_project(ws, "Alpha", projdir)
    app = studio.set_workspace(app, ws)
    tf{file} = projdir + "/precious.bas"
    write(tf, "print \"do not delete me\"\n")
    ws = studio_model.set_selected_path(app.model.workspace, projdir + "/precious.bas")
    app = studio.set_workspace(app, ws)
    app.clock_fixed = 1000
    log = studio_history.open(home)

    ' Local autonomy granted; destructive still gated. This is the case that
    ' matters: an agent trusted to edit is NOT thereby trusted to delete.
    G = { app: app, log: log, calls: [], round: 0,
          pol: studio_permissions.effective({ local: "auto" }, nothing, nothing) }

    m = llm.anthropic("claude-sonnet-4-6", "sk-offline")
    m = llm.with_transport(m, reply_delete_then_text)
    m = studio_agent.model(m, [ llm.tool("delete_path", "delete the selected path", act_schema(), tool_delete_path) ])
    ans = studio_agent.act(m, G.app, G.log, "delete precious.bas")
    print "-- the model asked to delete a file"
    print "  tool calls: " + join(G.calls, ", ")
    print "  what it told the user: " + ans.text
    print ""
    print "-- the file is still there"
    print "  exists: " + string(exists(tf))
    print ""
    print "-- and the attempt is in the audit trail, refusal and all"
    for each e in studio_history.recent(G.log, 6)
      if e.kind = "agent_action" then
        print "  " + e.target + " — " + replace(e.detail, projdir + "/", "")
      end if
    end for
    print ""
    print "-- NOTE, and it is a real limitation: there is no in-loop confirmation"
    print "   prompt. Confirmation is granted by POLICY, not by a dialog — a"
    print "   dialog is an async surface no test can press, which is why Studio"
    print "   has none anywhere. The agent stops and tells the user instead."
  end if
end program
