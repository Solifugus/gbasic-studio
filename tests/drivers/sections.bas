' STU-3 headless driver for the execution-section engine (studio_sections).
' Dispatches on args[0] to a scenario and prints a deterministic, path-free
' transcript for golden comparison. Exercises derivation, cursor resolution,
' reattachment across edits (blank-line insert / internal edit / rename / sibling
' insert / move / duplicate ambiguity / delete), invalid-source retention +
' recovery, persistence round-trip, multi-document isolation, Unicode byte offsets,
' and repeated-refresh determinism.

' ---- source fixtures (each returns whole-file source) ----------------------

function base_src()
  return "x = 1\ny = 2\n\nfunction add(a, b)\n  return a + b\nend function\n\nprint add(x, y)\n\nfunction mul(a, b)\n  return a * b\nend function\n"
end function

function base_blank()
  ' one blank line inserted at the very top (all offsets shift down)
  return "\nx = 1\ny = 2\n\nfunction add(a, b)\n  return a + b\nend function\n\nprint add(x, y)\n\nfunction mul(a, b)\n  return a * b\nend function\n"
end function

function base_internal()
  ' body of add() changed (return a + b + 0); header (name) unchanged
  return "x = 1\ny = 2\n\nfunction add(a, b)\n  return a + b + 0\nend function\n\nprint add(x, y)\n\nfunction mul(a, b)\n  return a * b\nend function\n"
end function

function base_rename()
  ' add() renamed to plus(); body identical
  return "x = 1\ny = 2\n\nfunction plus(a, b)\n  return a + b\nend function\n\nprint add(x, y)\n\nfunction mul(a, b)\n  return a * b\nend function\n"
end function

function base_sibling()
  ' a new function sub() inserted before add()
  return "x = 1\ny = 2\n\nfunction sub(a, b)\n  return a - b\nend function\n\nfunction add(a, b)\n  return a + b\nend function\n\nprint add(x, y)\n\nfunction mul(a, b)\n  return a * b\nend function\n"
end function

function base_delete()
  ' mul() deleted
  return "x = 1\ny = 2\n\nfunction add(a, b)\n  return a + b\nend function\n\nprint add(x, y)\n"
end function

function base_dup()
  ' mul() duplicated verbatim as a second identical function
  return "x = 1\ny = 2\n\nfunction add(a, b)\n  return a + b\nend function\n\nprint add(x, y)\n\nfunction mul(a, b)\n  return a * b\nend function\n\nfunction mul(a, b)\n  return a * b\nend function\n"
end function

function broken_src()
  ' add() body incomplete -> parse fails
  return "x = 1\ny = 2\n\nfunction add(a, b)\n  return a +\n"
end function

function prog_src()
  ' a program block: sections come from its BODY (design 6.2)
  return "program main(args)\n  x = 1\n  print x\n\n  function helper(n)\n    return n\n  end function\nend program\n"
end function

function uni_src()
  return "greeting = \"héllo\"\n\nfunction shout(s)\n  return s\nend function\n"
end function

' ---- helpers ---------------------------------------------------------------

function show(label, state)
  print "-- " + label
  print studio_sections.summary(state)
end function

program main(args)
  load "studio_sections"
  load "persist"
  load "studio_model"

  mode = ""
  if count(args) > 0 then
    mode = args[0]
  end if
  ' Modes that touch the disk take a scratch directory as args[1]. Nothing about
  ' the path is ever printed, so the goldens stay path-free.
  dir = ""
  if count(args) > 1 then
    dir = args[1]
  end if

  if mode = "derive" then
    st = studio_sections.create("doc-1")
    st = studio_sections.refresh(st, base_src())
    show("base", st)
  end if

  if mode = "cursor" then
    st = studio_sections.create("doc-1")
    st = studio_sections.refresh(st, base_src())
    for each off in [0, 3, 6, 20, 40, 55, 70, 200]
      print "offset " + off + " -> " + studio_sections.section_at(st, off)
    end for
  end if

  ' The editor-facing cursor path: 1-based BYTE line/column (what studio_docs
  ' stores) -> byte offset -> section. Includes a multi-byte line so the byte-column
  ' convention is pinned, and out-of-range positions that must clamp, not raise.
  if mode = "cursor_pos" then
    st = studio_sections.create("doc-1")
    src = base_src()
    st = studio_sections.refresh(st, src)
    show("base", st)
    for each p in [[1, 1], [2, 3], [4, 1], [5, 10], [6, 12], [8, 1], [11, 5], [99, 1], [1, 500]]
      l = p[0]
      c = p[1]
      print "line " + l + " col " + c + " -> off " + studio_sections.offset_of(src, l, c) + " -> " + studio_sections.section_at_position(st, src, l, c)
    end for
    ' Multi-byte: "héllo" — the column is a BYTE column, so the closing quote of
    ' line 1 sits one column further right than a character count would suggest.
    u = uni_src()
    su = studio_sections.create("doc-2")
    su = studio_sections.refresh(su, u)
    print "unicode bytes=" + byte_count(u)
    for each p in [[1, 1], [1, 13], [1, 21], [3, 1]]
      l = p[0]
      c = p[1]
      print "u line " + l + " col " + c + " -> off " + studio_sections.offset_of(u, l, c) + " -> " + studio_sections.section_at_position(su, u, l, c)
    end for
  end if

  if mode = "prog" then
    st = studio_sections.create("doc-1")
    st = studio_sections.refresh(st, prog_src())
    show("program-scope", st)
  end if

  if mode = "insert_blank" then
    st = studio_sections.create("doc-1")
    st = studio_sections.refresh(st, base_src())
    show("v1", st)
    st = studio_sections.refresh(st, base_blank())
    show("v2 (blank inserted above)", st)
  end if

  if mode = "internal" then
    st = studio_sections.create("doc-1")
    st = studio_sections.refresh(st, base_src())
    show("v1", st)
    st = studio_sections.refresh(st, base_internal())
    show("v2 (add body edited)", st)
  end if

  if mode = "rename" then
    st = studio_sections.create("doc-1")
    st = studio_sections.refresh(st, base_src())
    show("v1", st)
    st = studio_sections.refresh(st, base_rename())
    show("v2 (add -> plus, body same)", st)
  end if

  if mode = "sibling" then
    st = studio_sections.create("doc-1")
    st = studio_sections.refresh(st, base_src())
    show("v1", st)
    st = studio_sections.refresh(st, base_sibling())
    show("v2 (sub inserted before add)", st)
  end if

  if mode = "duplicate" then
    st = studio_sections.create("doc-1")
    st = studio_sections.refresh(st, base_src())
    show("v1", st)
    st = studio_sections.refresh(st, base_dup())
    show("v2 (mul duplicated)", st)
  end if

  if mode = "delete" then
    st = studio_sections.create("doc-1")
    st = studio_sections.refresh(st, base_src())
    show("v1", st)
    st = studio_sections.refresh(st, base_delete())
    show("v2 (mul deleted)", st)
  end if

  if mode = "invalid" then
    st = studio_sections.create("doc-1")
    st = studio_sections.refresh(st, base_src())
    show("v1 valid", st)
    st = studio_sections.refresh(st, broken_src())
    show("v2 broken (last-known-good retained)", st)
    st = studio_sections.refresh(st, base_src())
    show("v3 restored (reattached)", st)
  end if

  if mode = "persist" then
    st = studio_sections.create("doc-1")
    st = studio_sections.refresh(st, base_src())
    show("v1", st)
    saved = studio_sections.to_persist(st)
    st2 = studio_sections.from_persist(saved, "doc-1")
    show("restored (anchors only)", st2)
    st2 = studio_sections.refresh(st2, base_src())
    show("restored + reparsed (ids preserved)", st2)
  end if

  if mode = "multidoc" then
    a = studio_sections.create("doc-1")
    a = studio_sections.refresh(a, base_src())
    b = studio_sections.create("doc-2")
    b = studio_sections.refresh(b, base_delete())
    show("doc-1", a)
    show("doc-2", b)
  end if

  if mode = "unicode" then
    st = studio_sections.create("doc-1")
    st = studio_sections.refresh(st, uni_src())
    show("unicode", st)
    for each off in [0, 10, 20]
      print "offset " + off + " -> " + studio_sections.section_at(st, off)
    end for
  end if

  ' Real on-disk round-trip: sections ride in the workspace record, through strict
  ' JSON + atomic_replace, and come back with ids intact and reattaching.
  if mode = "store" then
    st = studio_sections.create("doc-1")
    st = studio_sections.refresh(st, base_src())
    show("v1 (in memory)", st)

    ws = studio_model.new_workspace("ws-1", "W")
    ws.sections = studio_sections.persist_into(ws.sections, st)
    print "encodable=" + json_encodable(ws)
    path = dir + "/workspace.json"
    persist.write_atomic(path, ws)

    r = persist.read_status(path)
    print "read=" + r.status
    back = studio_model.normalize_workspace(r.value)
    st2 = studio_sections.restore_from(back.sections, "doc-1")
    show("restored from disk (anchors only)", st2)
    ' An edit happened while we were away: mul() deleted. Ids that survive must be
    ' the SAME ids, and the deleted one must go stale rather than be reused.
    st2 = studio_sections.refresh(st2, base_delete())
    show("restored + reparsed after edit", st2)
    print "stale=" + join(st2.stale_ids, ",")

    ' Forgetting a document clears only its slot.
    ws.sections = studio_sections.forget(ws.sections, "doc-1")
    print "after forget count=" + count(ws.sections)
  end if

  ' Compatibility: a workspace written BEFORE STU-3 has no `sections` key at all.
  ' It must normalize in, restore as an empty section state, and then accept
  ' sections — without any migration step.
  if mode = "compat" then
    old = {
      schema_version: 1,
      id: "ws-1",
      name: "W",
      next_seq: 1,
      active_project: "",
      projects: [],
      tabs: { order: [], active: "" },
      nav: { selected_path: "", expanded: [] },
      docs: { open: [], active: "", next_doc: 1 }
    }
    path = dir + "/old_workspace.json"
    persist.write_atomic(path, old)
    r = persist.read_status(path)
    print "read=" + r.status
    raw = r.value
    print "has sections before normalize=" + has(raw, "sections")
    ws = studio_model.normalize_workspace(raw)
    print "has sections after normalize=" + has(ws, "sections")
    print "sections count=" + count(ws.sections)

    st = studio_sections.restore_from(ws.sections, "doc-1")
    show("restored from a pre-STU-3 workspace", st)
    st = studio_sections.refresh(st, base_src())
    show("first refresh (ids minted fresh)", st)

    ' Unknown document in a populated bundle is also an empty state, not an error.
    ws.sections = studio_sections.persist_into(ws.sections, st)
    other = studio_sections.restore_from(ws.sections, "doc-999")
    show("unknown doc id", other)
  end if

  if mode = "repeated" then
    st = studio_sections.create("doc-1")
    i = 0
    while i < 25
      st = studio_sections.refresh(st, base_src())
      i = i + 1
    end while
    show("after 25 refreshes", st)
  end if
end program
