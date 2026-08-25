' STU-9 headless driver for code-overlay branches (studio_overlays). Projection,
' scope, conflicts, rebase, promote, discard and compare — over plain data, with
' no GTK, no display and no child process.
'
' args: mode home

function base_src()
  return "threshold = 0.5\n\nfunction score(t)\n  return t * 100\nend function\n\nprint \"score is \" + score(threshold)\n"
end function

' The SHARED ANCESTRY changed: section 1's text differs. Anything below is
' unaffected as text, which is the distinction the scope check exists to make.
function ancestry_changed_src()
  return "threshold = 0.9\n\nfunction score(t)\n  return t * 100\nend function\n\nprint \"score is \" + score(threshold)\n"
end function

' The OVERLAID section changed canonically. This is the conflict.
function overlaid_changed_src()
  return "threshold = 0.5\n\nfunction score(t)\n  return t * 1000\nend function\n\nprint \"score is \" + score(threshold)\n"
end function

function secs_for(src)
  st = studio_sections.create("doc-1")
  return studio_sections.refresh(st, src)
end function

function show(lines)
  for each l in lines
    print l
  end for
end function

function dump(label, text)
  print "-- " + label
  for each l in split(text, "\n")
    print "   |" + l
  end for
end function

function sec_at(st, i)
  return st.sections[i].id
end function

' The overlay text used throughout: the same function, made robust.
function robust_score()
  return "function score(t)\n  if t < 0 then\n    return 0\n  end if\n  return t * 100\nend function"
end function

program main(args)
  load persist
  load studio_sections
  load studio_results
  load studio_overlays

  mode = args[0]
  home = args[1]

  src = base_src()
  st = secs_for(src)

  if mode = "project" then
    print "sections:"
    for each s in st.sections
      print "  " + s.id + " " + s.kind + " [" + s.start_offset + "," + s.end_offset + ")"
    end for
    target = sec_at(st, 1)
    print ""
    print "an overlay begins as a COPY of what is there, not a blank buffer:"
    dump("canonical " + target, studio_overlays.canonical_text(src, st, target))

    ov = studio_overlays.create()
    ov = studio_overlays.put(ov, "br-1", target, studio_overlays.base_fp(st, target), robust_score())
    print ""
    show(studio_overlays.summary(ov, "br-1", st))
    print ""
    p = studio_overlays.project(src, st, studio_overlays.for_branch(ov, "br-1"))
    dump("the branch's projection", p.text)
    print ""
    print "and the canonical text is untouched by projecting it:"
    print "  same object: " + string(src = base_src())
    print ""
    print "-- the projection is REAL source: it re-derives into sections"
    pst = secs_for(p.text)
    for each s in pst.sections
      print "   " + s.id + " " + s.kind
    end for
  end if

  if mode = "scope" then
    ' Two overlays: one below the branch point, one above it.
    below = sec_at(st, 1)
    above = sec_at(st, 0)
    point_end = st.sections[0].end_offset
    ov = studio_overlays.create()
    ov = studio_overlays.put(ov, "br-1", below, studio_overlays.base_fp(st, below), robust_score())
    ov = studio_overlays.put(ov, "br-1", above, studio_overlays.base_fp(st, above), "threshold = 0.25")
    print "an overlay may only touch what is BELOW its branch point (§9.2)"
    for each p in studio_overlays.conflicts(st, studio_overlays.for_branch(ov, "br-1"), point_end)
      print "  " + p.section_id + ": " + p.why + " — " + p.detail
    end for
    print ""
    print "so only the one below it applies:"
    for each e in studio_overlays.applicable(st, studio_overlays.for_branch(ov, "br-1"), point_end)
      print "  " + e.section_id
    end for
  end if

  if mode = "conflict" then
    target = sec_at(st, 1)
    ov = studio_overlays.create()
    ov = studio_overlays.put(ov, "br-1", target, studio_overlays.base_fp(st, target), robust_score())

    print "-- upstream changed, the overlaid section did not: still applies"
    st2 = secs_for(ancestry_changed_src())
    show(studio_overlays.summary(ov, "br-1", st2))

    print ""
    print "-- the OVERLAID section changed canonically: a conflict, not a guess"
    st3 = secs_for(overlaid_changed_src())
    show(studio_overlays.summary(ov, "br-1", st3))
    print ""
    print "   what it is now shadowing:"
    show(studio_overlays.diff_lines(overlaid_changed_src(), st3, studio_overlays.edit_for(ov, "br-1", target)))

    print ""
    print "-- promote is refused outright while anything conflicts"
    r = studio_overlays.promote(overlaid_changed_src(), st3, studio_overlays.for_branch(ov, "br-1"), -1)
    print "   ok=" + string(r.ok) + " why=" + r.why
    print "   file text unchanged by the refusal: " + string(r.text = overlaid_changed_src())

    print ""
    print "-- rebase re-stamps it onto the current text, and SAYS it shadows one"
    rb = studio_overlays.rebase(ov, "br-1", st3)
    print "   rebased: " + join(rb.rebased, ", ")
    print "   unresolved: " + count(rb.unresolved)
    show(studio_overlays.summary(rb.ov, "br-1", st3))

    print ""
    print "-- and now promote is allowed"
    r2 = studio_overlays.promote(overlaid_changed_src(), st3, studio_overlays.for_branch(rb.ov, "br-1"), -1)
    print "   ok=" + string(r2.ok)
    dump("promoted source", r2.text)
  end if

  if mode = "gone" then
    target = sec_at(st, 1)
    ov = studio_overlays.create()
    ov = studio_overlays.put(ov, "br-1", target, studio_overlays.base_fp(st, target), robust_score())
    print "the section an overlay replaces can be deleted outright:"
    st4 = secs_for("threshold = 0.5\n\nprint \"no function any more\"\n")
    show(studio_overlays.summary(ov, "br-1", st4))
    print ""
    print "-- rebase cannot invent a section to sit on, and refuses to drop it silently"
    rb = studio_overlays.rebase(ov, "br-1", st4)
    print "   rebased: " + count(rb.rebased)
    for each p in rb.unresolved
      print "   unresolved: " + p.section_id + " — " + p.detail
    end for
    print "   the edit is still there for the user to look at: " + count(studio_overlays.for_branch(rb.ov, "br-1"))
    print ""
    print "-- discarding is the explicit act (§9.2)"
    ov2 = studio_overlays.drop(rb.ov, "br-1", target)
    print "   edits now: " + count(studio_overlays.for_branch(ov2, "br-1"))
  end if

  if mode = "persist" then
    target = sec_at(st, 1)
    ov = studio_overlays.create()
    ov = studio_overlays.put(ov, "br-1", target, studio_overlays.base_fp(st, target), robust_score())
    ov = studio_overlays.put(ov, "br-2", target, studio_overlays.base_fp(st, target), "function score(t)\n  return t * 2")
    persist.ensure_dir(home)
    f{file} = home + "/overlays.json"
    write(f, encode(studio_overlays.to_persist(ov)))
    back = studio_overlays.from_persist(try_decode(read(f)).value)
    print "round trip: " + count(back.edits) + " edit(s)"
    print "  br-1: " + count(studio_overlays.for_branch(back, "br-1"))
    print "  br-2: " + count(studio_overlays.for_branch(back, "br-2"))
    print "  text survives: " + string(studio_overlays.edit_for(back, "br-1", target).text = robust_score())
    print ""
    print "-- a malformed store yields an empty overlay, not a raise"
    print "  nothing: " + count(studio_overlays.from_persist(nothing).edits)
    print "  wrong shape: " + count(studio_overlays.from_persist({ edits: "no" }).edits)
    print "  half-formed edits are dropped one by one:"
    mixed = { edits: [ { branch: "b", section_id: "sec-1", base_fp: "x", text: "ok" }, { branch: "b" }, "not a record" ] }
    print "  kept: " + count(studio_overlays.from_persist(mixed).edits)
    print ""
    print "-- dropping a whole branch takes its overlay with it"
    print "  after drop_branch(br-1): " + count(studio_overlays.drop_branch(back, "br-1").edits)
  end if
end program
