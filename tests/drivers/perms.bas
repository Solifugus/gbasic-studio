' STU-10 headless driver for the permission model alone: tiers, policies, scope
' composition, the narrowing rule, confirmation tokens, and the malformed-config
' negatives. No app, no agent, no display.
'
' args: mode

function show(lines)
  for each l in lines
    print l
  end for
end function

function line(label, g, p, s)
  print label
  show(studio_permissions.summary(studio_permissions.effective(g, p, s)))
end function

program main(args)
  load studio_permissions
  mode = args[0]

  if mode = "scopes" then
    line("-- shipped defaults: read is automatic, everything else asks", nothing, nothing, nothing)
    print ""
    line("-- global turns local autonomy up", { local: "auto" }, nothing, nothing)
    print ""
    line("-- an unset project has NO opinion; it does not vote the default", { local: "auto" }, {}, nothing)
    print ""
    line("-- the project narrows it back", { local: "auto" }, { local: "confirm" }, nothing)
    print ""
    line("-- a project may not WIDEN what global denied", { external: "deny" }, { external: "auto" }, nothing)
    print ""
    line("-- \"read-only this investigation\" clamps everything", { local: "auto", external: "auto" }, nothing, { local: "deny", external: "deny" })
    print ""
    print "-- and each answer says where it came from"
    print "  " + studio_permissions.why_line(nothing, nothing, nothing, "read")
    print "  " + studio_permissions.why_line({ local: "auto" }, nothing, nothing, "local")
    print "  " + studio_permissions.why_line({ local: "auto" }, { local: "confirm" }, nothing, "local")
    print "  " + studio_permissions.why_line({ local: "auto" }, nothing, { local: "deny" }, "local")
  end if

  if mode = "malformed" then
    print "a config file with a typo in it must not be a config that grants MORE."
    print ""
    line("-- an unknown policy name is ignored, leaving the default", { local: "yolo" }, nothing, nothing)
    print ""
    line("-- a non-record scope is no scope at all", "read-only please", nothing, nothing)
    print ""
    line("-- an unknown TIER key is ignored rather than invented", { launch_missiles: "auto" }, nothing, nothing)
    print ""
    print "-- and an unreadable policy ranks as the strictest thing there is"
    eff = { read: "auto", local: "sideways", external: "confirm" }
    print "  stored as: " + studio_permissions.policy_for(eff, "local")
    d = studio_permissions.decide(eff, "local", "edit_document", {}, "")
    print "  decide -> " + d.verdict + " (" + d.why + ")"
    print "  " + studio_permissions.policy_for(eff, "not_a_tier") + " (a tier that does not exist)"
  end if

  if mode = "tokens" then
    print "a confirmation names ONE act. It cannot be spent on another."
    a = studio_permissions.token("delete_path", { path: "a.bas" })
    b = studio_permissions.token("delete_path", { path: "b.bas" })
    c = studio_permissions.token("rename_path", { path: "a.bas" })
    print "  delete a.bas: " + a
    print "  delete b.bas: " + b
    print "  rename a.bas: " + c
    print "  a = b: " + string(a = b)
    print "  a = c: " + string(a = c)
    print ""
    print "-- the same act always hashes the same way"
    print "  stable: " + string(a = studio_permissions.token("delete_path", { path: "a.bas" }))
    print ""
    print "-- confirming with the wrong token is the same as not confirming"
    pol = studio_permissions.effective(nothing, nothing, nothing)
    print "  right: " + studio_permissions.decide(pol, "external", "delete_path", { path: "a.bas" }, a).verdict
    print "  wrong: " + studio_permissions.decide(pol, "external", "delete_path", { path: "a.bas" }, b).verdict
    print "  empty: " + studio_permissions.decide(pol, "external", "delete_path", { path: "a.bas" }, "").verdict
    print ""
    print "-- and a denied tier cannot be confirmed past at all"
    denied = studio_permissions.effective({ external: "deny" }, nothing, nothing)
    print "  " + studio_permissions.decide(denied, "external", "delete_path", { path: "a.bas" }, a).verdict
  end if
end program
