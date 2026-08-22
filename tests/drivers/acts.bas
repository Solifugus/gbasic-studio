' STU-10 headless driver for act tools and the permission model. Tier
' assignment, scope composition, confirmation binding, the audit trail, and the
' negatives — a denied act, an unknown tool, a confirmation spent on the wrong
' thing. Offline and displayless throughout.
'
' args: mode home projdir

' The history records real paths, which are temp directories here. Print the
' tail only, or the golden would be a golden about this machine.
function scrub(text, projdir)
  return replace(text, projdir + "/", "")
end function

function show(lines)
  for each l in lines
    print l
  end for
end function

function policy_of(g, p, sn)
  return studio_permissions.effective(g, p, sn)
end function

' One tool call through THE gate, printed the way a caller sees it.
function try_call(app, log, policy, name, args, confirmed)
  r = studio_tools.invoke(app, log, policy, name, args, confirmed)
  line = "  " + name
  if r.ok then
    line = line + " -> ok"
  else
    line = line + " -> " + r.why
  end if
  print line
  return r
end function

program main(args)
  load persist
  load filetree
  load studio_model
  load studio_docs
  load studio
  load studio_ui
  load studio_history
  load studio_permissions
  load studio_tools

  mode = args[0]
  home = args[1]
  projdir = ""
  if count(args) > 2 then
    projdir = args[2]
  end if

  app = studio.launch(home)
  app = studio.create_registered_workspace(app, "ws")
  ws = app.model.workspace
  ws = studio_model.add_project(ws, "Alpha", projdir)
  app = studio.set_workspace(app, ws)
  app.clock_fixed = 1000
  log = studio_history.open(home)

  if mode = "tiers" then
    print "every tool, and the tier its REVERSIBILITY puts it in:"
    for each t in studio_tools.registry()
      print "  " + studio_tools.tier_of(t.name) + "  " + t.name
    end for
    print ""
    print "-- a name that is not a tool has no tier, and answers the strictest thing"
    print "  " + studio_tools.tier_of("rm_rf")
  end if

  if mode = "gate" then
    print "-- default policy: reads are automatic"
    pol = policy_of(nothing, nothing, nothing)
    show(studio_permissions.summary(pol))
    print ""
    r = try_call(app, log, pol, "current_project", {}, "")
    app = r.app
    log = r.log

    print ""
    print "-- a local act needs confirmation by default, and says so"
    r = try_call(app, log, pol, "create_file", { name: "made-by-agent.bas" }, "")
    app = r.app
    log = r.log
    tok = r.token
    print "  token: " + tok

    print ""
    print "-- a confirmation is bound to the ACT: this one cannot be spent elsewhere"
    r = try_call(app, log, pol, "create_file", { name: "something-else.bas" }, tok)
    app = r.app
    log = r.log

    print ""
    print "-- confirmed, it runs"
    r = try_call(app, log, pol, "create_file", { name: "made-by-agent.bas" }, tok)
    app = r.app
    log = r.log

    print ""
    print "-- with local autonomy turned up, no confirmation is asked for"
    pol2 = policy_of({ local: "auto" }, nothing, nothing)
    r = try_call(app, log, pol2, "create_file", { name: "second.bas" }, "")
    app = r.app
    log = r.log

    print ""
    print "-- but a session clamp overrides that, whatever global says"
    pol3 = policy_of({ local: "auto" }, nothing, { local: "deny" })
    r = try_call(app, log, pol3, "create_file", { name: "third.bas" }, "")
    app = r.app
    log = r.log
    print "  " + studio_permissions.why_line({ local: "auto" }, nothing, { local: "deny" }, "local")

    print ""
    print "-- an unknown tool is refused before any policy question is asked"
    r = try_call(app, log, pol2, "rm_rf", { path: "/" }, "")
    app = r.app
    log = r.log

    print ""
    print "-- a read tool cannot be reached through the write path, or vice versa"
    c = studio_tools.call(app, log, "create_file", { name: "x.bas" })
    print "  call(create_file) -> " + c.why
  end if

  if mode = "task" then
    ' The acceptance criterion: a scripted multi-step task, entirely through
    ' act tools, with local autonomy granted.
    pol = policy_of({ local: "auto" }, nothing, nothing)
    print "open a file -> edit it -> put the caret in it -> run it -> report"
    r = try_call(app, log, pol, "create_file", { name: "task.bas" }, "")
    app = r.app
    log = r.log
    r = try_call(app, log, pol, "edit_document", { content: "total = 6 * 7\nprint \"the answer is \" + total\n" }, "")
    app = r.app
    log = r.log
    r = try_call(app, log, pol, "move_cursor", { line: 0, column: 0 }, "")
    app = r.app
    log = r.log
    r = try_call(app, log, pol, "execute_section", {}, "")
    app = r.app
    log = r.log
    ' Drive the run to completion the way the window's timer does.
    n = 0
    while n < 400
      t = studio_ui.tick_run(app)
      app = t.app
      if not t.active then
        break
      end if
      n = n + 1
    end while
    r = try_call(app, log, pol, "section_output", { section_id: studio_ui.view_for(app).sid }, "")
    app = r.app
    log = r.log
    print "  target output: <" + r.value.target + ">"

    print ""
    print "-- and every step of it is in the history, refusals included"
    for each e in studio_history.recent(log, 12)
      if e.kind = "agent_action" then
        print "  " + e.kind + " " + e.target + " — " + scrub(e.detail, projdir)
      end if
    end for
  end if

  if mode = "destructive" then
    pol = policy_of({ local: "auto" }, nothing, nothing)
    r = try_call(app, log, pol, "create_file", { name: "doomed.bas" }, "")
    app = r.app
    log = r.log
    ws = app.model.workspace
    ws = studio_model.set_selected_path(ws, projdir + "/doomed.bas")
    app = studio.set_workspace(app, ws)
    probe(file) = projdir + "/doomed.bas"
    print "the file exists: " + string(exists(probe))

    print ""
    print "-- local autonomy does NOT carry over to a destructive act"
    r = try_call(app, log, pol, "delete_path", {}, "")
    app = r.app
    log = r.log
    tok = r.token
    still = exists(probe)
    print "  the file still exists: " + string(still)

    print ""
    print "-- confirmed, it goes"
    r = try_call(app, log, pol, "delete_path", {}, tok)
    app = r.app
    log = r.log
    gone = exists(probe)
    print "  the file still exists: " + string(gone)

    print ""
    print "-- a session that denies the external tier cannot be confirmed past"
    locked = policy_of({ local: "auto" }, nothing, { external: "deny" })
    r = try_call(app, log, locked, "delete_path", {}, "any-token-at-all")
    app = r.app
    log = r.log

    print ""
    print "-- every attempt is in the audit trail, including the refused ones"
    for each e in studio_history.recent(log, 12)
      if e.kind = "agent_action" then
        print "  " + e.target + " — " + scrub(e.detail, projdir)
      end if
    end for
  end if
end program
