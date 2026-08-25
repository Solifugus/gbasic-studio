' STU-7 headless driver for the state-only branch model (studio_branches).
' Tree operations, selection, nesting, bindings, staleness, and persistence —
' all over plain data, with no GTK and no display.
'
' args: mode home

function base_src()
  return "print \"one\"\n\nfunction add(a, b)\n  return a + b\nend function\n\ntotal = add(2, 3)\nprint total\n"
end function

' The same file with the SHARED ANCESTRY changed: section 1's text differs, so
' anything branched below it was explored against source that no longer exists.
function changed_ancestry_src()
  return "print \"one, revised\"\n\nfunction add(a, b)\n  return a + b\nend function\n\ntotal = add(2, 3)\nprint total\n"
end function

' Changed BELOW the branch point instead: the ancestry is untouched.
function changed_below_src()
  return "print \"one\"\n\nfunction add(a, b)\n  return a + b\nend function\n\ntotal = add(2, 4)\nprint total\n"
end function

function sections_for(src)
  st = studio_sections.create("doc-1")
  return studio_sections.refresh(st, src)
end function

function show(tree, secs)
  print studio_branches.summary(tree, "doc-1", secs)
end function

function act(label, r)
  print "-> " + label + ": " + r.action + " " + r.detail
  return r.tree
end function

program main(args)
  load persist
  load studio_sections
  load studio_branches

  mode = args[0]
  home = args[1]
  src = base_src()
  secs = sections_for(src)
  ' sec-1 statements | sec-2 function add | sec-3 statements
  point = secs.sections[2].id

  ' ---- tree: create, select, nest, rename, delete -------------------------
  if mode = "tree" then
    tree = studio_branches.create()
    print "empty: " + studio_branches.summary(tree, "doc-1", secs)

    a = studio_branches.add(tree, "doc-1", point, "Baseline", "", secs)
    tree = a.tree
    b = studio_branches.add(tree, "doc-1", point, "Robust", "", secs)
    tree = b.tree
    banner_two = studio_branches.add(tree, "doc-1", point, "No Outliers", "", secs)
    tree = banner_two.tree
    print "== three branches at one point =="
    show(tree, secs)

    print "== exactly one is selected at a point =="
    tree = act("select Robust", studio_branches.select(tree, b.id))
    show(tree, secs)
    tree = act("select No Outliers", studio_branches.select(tree, banner_two.id))
    show(tree, secs)
    print "selected at the point: " + studio_branches.selected_at(tree, point)

    print "== nesting: a branch point inside a branch =="
    n = studio_branches.add(tree, "doc-1", secs.sections[0].id, "Inner", banner_two.id, secs)
    tree = n.tree
    tree = act("select Inner", studio_branches.select(tree, n.id))
    show(tree, secs)

    print "== rename =="
    tree = act("rename", studio_branches.rename(tree, b.id, "Robust v2"))
    tree = act("rename to nothing", studio_branches.rename(tree, b.id, "   "))
    tree = act("rename a branch that is not there", studio_branches.rename(tree, "br-99", "x"))
    show(tree, secs)

    print "== deleting a branch takes its descendants with it =="
    d = studio_branches.drop(tree, banner_two.id)
    tree = d.tree
    print "-> delete No Outliers: removed " + d.removed
    show(tree, secs)
    print "the point falls back to baseline: [" + studio_branches.selected_at(tree, point) + "]"
  end if

  ' ---- bindings: what makes a state-only branch differ --------------------
  if mode = "bindings" then
    tree = studio_branches.create()
    a = studio_branches.add(tree, "doc-1", point, "Baseline", "", secs)
    tree = a.tree
    r = studio_branches.add(tree, "doc-1", point, "Robust", "", secs)
    tree = r.tree

    tree = act("bind threshold", studio_branches.bind(tree, r.id, "threshold", "0.95"))
    tree = act("bind label", studio_branches.bind(tree, r.id, "label", "\"robust\""))
    tree = act("rebind threshold", studio_branches.bind(tree, r.id, "threshold", "0.99"))
    show(tree, secs)

    print "== the source a branch contributes =="
    print "<" + studio_branches.bindings_text(studio_branches.by_id(tree, r.id)) + ">"
    print "a branch with no bindings contributes nothing: <" + studio_branches.bindings_text(studio_branches.by_id(tree, a.id)) + ">"

    print "== what a binding may not be =="
    print "  empty name:     " + studio_branches.binding_problem("", "1")
    print "  empty value:    " + studio_branches.binding_problem("x", "  ")
    print "  not a name:     " + studio_branches.binding_problem("a-b", "1")
    print "  leading digit:  " + studio_branches.binding_problem("2x", "1")
    print "  two statements: " + studio_branches.binding_problem("x", "1\nprint 2")
    print "  fine:           [" + studio_branches.binding_problem("threshold_2", "0.95") + "]"
    tree = act("bind a bad name", studio_branches.bind(tree, r.id, "a-b", "1"))

    print "== the selected chain's bindings, outermost first =="
    tree = studio_branches.select(tree, r.id).tree
    n = studio_branches.add(tree, "doc-1", secs.sections[0].id, "Inner", r.id, secs)
    tree = n.tree
    tree = studio_branches.bind(tree, n.id, "threshold", "0.5").tree
    tree = studio_branches.select(tree, n.id).tree
    for each c in studio_branches.selected_chain(tree, "doc-1", secs)
      print "  chain: " + c.id + " " + c.name
    end for
    for each bd in studio_branches.chain_bindings(tree, "doc-1", secs)
      print "  " + bd.branch + " @" + bd.point + " " + bd.name + " = " + bd.expr
    end for
  end if

  ' ---- staleness: the honesty requirement (§9.3) --------------------------
  if mode = "stale" then
    tree = studio_branches.create()
    r = studio_branches.add(tree, "doc-1", point, "Robust", "", secs)
    tree = r.tree
    tree = studio_branches.bind(tree, r.id, "threshold", "0.95").tree
    tree = studio_branches.select(tree, r.id).tree
    print "== made against the current ancestry =="
    show(tree, secs)

    print "== a change BELOW the branch point leaves it alone =="
    below = studio_sections.refresh(secs, changed_below_src())
    show(tree, below)
    print "stale: " + count(studio_branches.stale_ids(tree, "doc-1", below))

    print "== a change ABOVE it does not =="
    above = studio_sections.refresh(secs, changed_ancestry_src())
    show(tree, above)
    print "stale: " + count(studio_branches.stale_ids(tree, "doc-1", above))
    print "and it is still SELECTED — the flag is surfaced, not acted on:"
    print "  selected=" + studio_branches.selected_at(tree, point)

    print "== re-anchoring is explicit: a person looked and accepted =="
    tree = act("reanchor", studio_branches.reanchor(tree, r.id, above))
    show(tree, above)
  end if

  ' ---- persistence --------------------------------------------------------
  if mode = "persist" then
    tree = studio_branches.create()
    a = studio_branches.add(tree, "doc-1", point, "Baseline", "", secs)
    tree = a.tree
    r = studio_branches.add(tree, "doc-1", point, "Robust", "", secs)
    tree = r.tree
    tree = studio_branches.bind(tree, r.id, "threshold", "0.95").tree
    tree = studio_branches.select(tree, r.id).tree
    n = studio_branches.add(tree, "doc-1", secs.sections[0].id, "Inner", r.id, secs)
    tree = n.tree
    tree = studio_branches.select(tree, n.id).tree
    print "== before =="
    show(tree, secs)

    raw = studio_branches.to_persist(tree)
    f{file} = home + "/branches.json"
    write(f, json_encode(raw))
    back = studio_branches.from_persist(try_decode(read(f)).value)
    print "== after a round trip through JSON =="
    show(back, secs)
    print "identical=" + (json_encode(studio_branches.to_persist(back)) = json_encode(raw))

    print "== a missing or future record degrades to an empty tree =="
    print "  from nothing:  " + count(studio_branches.from_persist(nothing).branches)
    print "  from unknown:  " + count(studio_branches.from_persist(unknown).branches)
    fut = { schema_version: 99, next_branch: 5, branches: [], selected: {} }
    print "  from a future: " + count(studio_branches.from_persist(fut).branches) + " next=" + studio_branches.from_persist(fut).next_branch
  end if
end program
