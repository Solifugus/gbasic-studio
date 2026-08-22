' STU-4 headless driver for the execution-session engine (studio_session).
' Dispatches on args[0] to a scenario and prints a deterministic, path-free
' transcript for golden comparison. args[1] is a scratch directory (never printed).
'
' Every case drives the session exactly as the shell does -- run, then tick until
' the machine leaves an active state -- so the transitions in the goldens are the
' real ones, not a narration.

' ---- source fixtures -------------------------------------------------------

function base_src()
  return "print \"one\"\n\nfunction add(a, b)\n  return a + b\nend function\n\nprint add(2, 3)\n\nprint \"last\"\n"
end function

function err_target_src()
  ' The LAST section divides by zero: the error lands in the target.
  return "print \"one\"\n\nfunction add(a, b)\n  return a + b\nend function\n\nprint 1 / 0\n"
end function

function err_prefix_src()
  ' The FIRST section divides by zero, so running the LAST section fails inside the
  ' replayed prefix and never reaches the target at all. The function declaration in
  ' the middle is load-bearing: STU-3 collapses consecutive plain statements into a
  ' single section, so without a declaration between them the "prefix" and the
  ' "target" would be the same section.
  return "print \"before\"\nprint 1 / 0\n\nfunction f(x)\n  return x\nend function\n\nprint \"target-section\"\n"
end function

function broken_src()
  return "print \"one\"\n\nfunction add(a, b)\n  return a +\n"
end function

function dup_src()
  ' mul() duplicated verbatim -> both candidates go `ambiguous` (STU-3).
  return "print \"one\"\n\nfunction mul(a, b)\n  return a * b\nend function\n\nfunction mul(a, b)\n  return a * b\nend function\n"
end function

function slow_src()
  ' Never finishes on its own: only a stop ends it.
  return "print \"started\"\n\nwhile true\n  sleep(0.05)\nend while\n"
end function

function signal_src()
  ' Kills its own interpreter from a grandchild, so the child dies BY SIGNAL with
  ' no diagnostic of any kind -- the case a status-only path must still handle.
  return "print \"before\"\n\nprocess.run({ command: \"sh\", args: [\"-c\", \"kill -TERM $PPID\"] })\n"
end function

function big_src()
  ' ~90 KB on stdout, past a 64 KB pipe buffer, so a driver that failed to drain
  ' while polling would deadlock instead of finishing.
  return "i = 0\n\nwhile i < 6000\n  print \"line-\" + i + \"-padding-padding\"\n  i = i + 1\nend while\n"
end function

function prog_src()
  ' Sections come from the program BODY, so a byte prefix cuts the block open and
  ' materialization must append `end program`. The inner declaration splits the body
  ' into three sections, so running the FIRST one truncates the block mid-way and the
  ' append is what makes the result parse at all.
  return "program main(args)\n  print \"in-program\"\n\n  function helper(n)\n    return n\n  end function\n\n  print \"second\"\nend program\n"
end function

' ---- STU-4B fixtures -------------------------------------------------------

' Helpers-after-main: the program body calls `add`, which is declared AFTER
' `end program`. A byte prefix stops before `add` is ever seen, so running a body
' section fails outright unless the declaration is hoisted. `inner` splits the body
' into separate sections so a run has a real prefix; `unused` proves source order
' is preserved among several hoisted declarations.
function hoist_after_src()
  return "program main(args)\n  print add(2, 3)\n\n  function inner(n)\n    return n\n  end function\n\n  print \"second\"\nend program\n\nfunction add(a, b)\n  return a + b\nend function\n\nfunction unused()\n  return 0\nend function\n"
end function

' The same program with the helper declared BEFORE the block: already inside every
' prefix, so nothing is hoisted and behaviour is exactly STU-4's.
function hoist_before_src()
  return "function add(a, b)\n  return a + b\nend function\n\nprogram main(args)\n  print add(2, 3)\n\n  function inner(n)\n    return n\n  end function\n\n  print \"second\"\nend program\n"
end function

' A hoisted declaration whose BODY raises when called. The diagnostic's position is
' inside the hoisted text, which the map must translate back to the declaration's
' real line in the document.
function hoist_err_src()
  return "program main(args)\n  print bad(1)\n\n  function inner(n)\n    return n\n  end function\n\n  print \"second\"\nend program\n\nfunction bad(x)\n  return x / 0\nend function\n"
end function

' A top-level `print` after `end program` never executes (only the program block
' does), so hoisting declarations past it cannot reorder an observable effect.
function hoist_inert_src()
  return "program main(args)\n  print add(1, 1)\n\n  function inner(n)\n    return n\n  end function\n\n  print \"body\"\nend program\n\nprint \"TOP-LEVEL-NEVER-RUNS\"\n\nfunction add(a, b)\n  return a + b\nend function\n"
end function

' Output on BOTH sides of the N-1/N boundary, so a successful separation has
' something to separate.
function split_src()
  return "print \"PREFIX-OUT\"\n\nfunction f(x)\n  return x\nend function\n\nprint \"TARGET-OUT\"\n"
end function

' Dies inside the replayed prefix, before the boundary marker is ever reached.
function split_die_src()
  return "print \"PREFIX-OUT\"\nprint 1 / 0\n\nfunction f(x)\n  return x\nend function\n\nprint \"TARGET-OUT\"\n"
end function

' ---- helpers ---------------------------------------------------------------

function sections_for(src)
  st = studio_sections.create("doc-1")
  return studio_sections.refresh(st, src)
end function

' Drive the session to completion exactly as the shell's timer does.
function drain(sess)
  guard = 0
  while studio_session.is_active(sess)
    sess = studio_session.tick(sess)
    guard = guard + 1
    if guard > 4000 then
      print "!! drain guard tripped"
      return sess
    end if
    sleep(0.01)
  end while
  return sess
end function

function show(label, sess)
  print "-- " + label
  print studio_session.summary(sess)
  print "transitions: " + studio_session.transitions(sess)
end function

' ---- STU-4C fixtures -------------------------------------------------------

function vars_src()
  ' A scalar, a string, an array and a record, spread across three sections so
  ' the capture reports the whole scope and not just the target's own names.
  return "x = 41 + 1\nname = \"studio\"\n\nfunction add(a, b)\n  return a + b\nend function\n\nitems = [1, 2, 3]\nrec = { a: 1, b: \"two\" }\nprint add(2, 3)\n"
end function

function vars_prog_src()
  return "program main(args)\n  inside = 7\n  print \"in-program\"\n\n  function helper(n)\n    return n\n  end function\n\n  tail = \"last\"\n  print helper(3)\nend program\n"
end function

function show_vars(sess)
  print "vars_before_status=" + sess.vars_before_status
  for each v in sess.vars_before
    print "  (before) " + v.name + " " + v.kind
  end for
  print "vars_status=" + sess.vars_status
  for each v in sess.vars
    line = "  " + v.name + " " + v.kind + "/" + v.category
    if v.category = "container" then
      line = line + " count=" + v.count
    end if
    if v.serializable = false then
      line = line + " (not serializable)"
    end if
    print line
  end for
end function

function run_and_show(label, sess, secs, src, sid)
  sess = studio_session.run(sess, secs, src, sid)
  sess = drain(sess)
  sess = studio_session.finalize(sess, secs, src)
  show(label, sess)
  return sess
end function

program main(args)
  load persist
  load studio_sections
  load studio_session

  mode = ""
  if count(args) > 0 then
    mode = args[0]
  end if
  scratch = "/tmp/gbasic_stu4_scratch"
  if count(args) > 1 then
    scratch = args[1]
  end if

  if mode = "clean" then
    src = base_src()
    secs = sections_for(src)
    print "sections=" + count(secs.sections)
    sess = studio_session.create("doc-1", scratch)
    show("initial", sess)
    ' Section 1 has no prefix: its output is exactly its own.
    first = secs.sections[0]
    sess = run_and_show("run section 1", sess, secs, src, first.id)
    ' A later section replays everything above it.
    last = secs.sections[count(secs.sections) - 1]
    sess = run_and_show("run last section", sess, secs, src, last.id)
  end if

  if mode = "err_target" then
    src = err_target_src()
    secs = sections_for(src)
    sess = studio_session.create("doc-1", scratch)
    last = secs.sections[count(secs.sections) - 1]
    sess = run_and_show("error in the target section", sess, secs, src, last.id)
  end if

  if mode = "err_prefix" then
    src = err_prefix_src()
    secs = sections_for(src)
    sess = studio_session.create("doc-1", scratch)
    last = secs.sections[count(secs.sections) - 1]
    sess = run_and_show("error in the replayed prefix", sess, secs, src, last.id)
  end if

  if mode = "outside" then
    ' A diagnostic whose position falls in NO section: the appended `end program`
    ' line sits past every section's range, and an error reported there must
    ' attribute as "outside" rather than being forced into the nearest section.
    src = prog_src()
    secs = sections_for(src)
    sess = studio_session.create("doc-1", scratch)
    last = secs.sections[count(secs.sections) - 1]
    sess = studio_session.run(sess, secs, src, last.id)
    sess = drain(sess)
    ' Synthesize a diagnostic beyond the end of the document and attribute it.
    sess.stderr_raw = "{\"severity\":\"error\",\"code\":\"GB_DIAG_RUNTIME_ERROR\",\"subcode\":1002,\"path\":\"x\",\"start\":{\"line\":999,\"column\":1},\"end\":{\"line\":999,\"column\":1},\"message\":\"synthetic out-of-range\"}"
    sess = studio_session.finalize(sess, secs, src)
    show("diagnostic outside every section", sess)
  end if

  if mode = "prog" then
    src = prog_src()
    secs = sections_for(src)
    first = secs.sections[0]
    m = studio_session.materialize_text(src, first, secs, "", "", "", [], [], { name: "", path: "", cap: 0, chunk: 500, stamp: "" })
    print "appended=" + m.appended
    print "materialized=<" + m.text + ">"
    sess = studio_session.create("doc-1", scratch)
    sess = run_and_show("run inside a program block", sess, secs, src, first.id)
  end if

  if mode = "stop" then
    src = slow_src()
    secs = sections_for(src)
    sess = studio_session.create("doc-1", scratch)
    last = secs.sections[count(secs.sections) - 1]
    sess = studio_session.run(sess, secs, src, last.id)
    ' Tick until the child has actually produced something, so the stop lands on a
    ' running child rather than racing its startup.
    ' Settle: the child is already exec'd (process.start verified that), so a few
    ' ticks simply let the state machine observe it running. We deliberately do NOT
    ' wait for output -- a gBASIC child's stdout is BLOCK-buffered on a pipe, so a
    ' program that never exits may never flush a short line at all.
    i = 0
    while i < 5
      sess = studio_session.tick(sess)
      i = i + 1
      sleep(0.01)
    end while
    print "running-before-stop=" + (sess.state = "running")
    sess = studio_session.request_stop(sess)
    sess = drain(sess)
    sess = studio_session.finalize(sess, secs, src)
    show("stopped politely", sess)
  end if

  if mode = "force" then
    src = slow_src()
    secs = sections_for(src)
    sess = studio_session.create("doc-1", scratch)
    last = secs.sections[count(secs.sections) - 1]
    sess = studio_session.run(sess, secs, src, last.id)
    ' Settle: the child is already exec'd (process.start verified that), so a few
    ' ticks simply let the state machine observe it running. We deliberately do NOT
    ' wait for output -- a gBASIC child's stdout is BLOCK-buffered on a pipe, so a
    ' program that never exits may never flush a short line at all.
    i = 0
    while i < 5
      sess = studio_session.tick(sess)
      i = i + 1
      sleep(0.01)
    end while
    sess = studio_session.force_stop(sess, 1)
    sess = studio_session.finalize(sess, secs, src)
    show("force-stopped", sess)
  end if

  if mode = "unresponsive" then
    ' A child that IGNORES SIGTERM must surface as a distinct state, never as a
    ' hang. A gBASIC child always dies on SIGTERM (it installs no handler unless
    ' `with lock` is used, and that one _exits), so the session is pointed at a
    ' helper that really does trap and ignore it. `interpreter` is a session field
    ' precisely so the runner is substitutable; the state machine under test is
    ' identical either way.
    src = slow_src()
    secs = sections_for(src)
    sess = studio_session.create("doc-1", scratch)
    sess.interpreter = "tests/helpers/proc_ignore_term.sh"
    sess.stop_grace_ticks = 3
    last = secs.sections[count(secs.sections) - 1]
    sess = studio_session.run(sess, secs, src, last.id)

    ' Settle: the child is already exec'd (process.start verified that), so a few
    ' ticks simply let the state machine observe it running. We deliberately do NOT
    ' wait for output -- a gBASIC child's stdout is BLOCK-buffered on a pipe, so a
    ' program that never exits may never flush a short line at all.
    i = 0
    while i < 5
      sess = studio_session.tick(sess)
      i = i + 1
      sleep(0.01)
    end while

    ' A bare stop cannot end this child.
    sess = studio_session.request_stop(sess)
    print "state-after-polite-stop=" + sess.state
    guard = 0
    while sess.state = "stopping"
      sess = studio_session.tick(sess)
      guard = guard + 1
      if guard > 4000 then
        print "!! never became unresponsive"
        return
      end if
      sleep(0.01)
    end while
    print "state-after-grace=" + sess.state

    ' Escalation is a separate, explicit action.
    sess = studio_session.force_stop(sess, 1)
    sess = studio_session.finalize(sess, secs, src)
    print "state=" + sess.state + " signal=" + sess.signal
    print "transitions: " + studio_session.transitions(sess)
  end if

  if mode = "restart" then
    ' A restart requested MID-RUN must wait for the stop before starting again, so
    ' two runs of one session never overlap.
    src = slow_src()
    secs = sections_for(src)
    sess = studio_session.create("doc-1", scratch)
    last = secs.sections[count(secs.sections) - 1]
    sess = studio_session.run(sess, secs, src, last.id)
    ' Settle: the child is already exec'd (process.start verified that), so a few
    ' ticks simply let the state machine observe it running. We deliberately do NOT
    ' wait for output -- a gBASIC child's stdout is BLOCK-buffered on a pipe, so a
    ' program that never exits may never flush a short line at all.
    i = 0
    while i < 5
      sess = studio_session.tick(sess)
      i = i + 1
      sleep(0.01)
    end while
    print "active-before-restart=" + studio_session.is_active(sess)
    ' Restart onto a different, terminating document so the case ends.
    src2 = base_src()
    secs2 = sections_for(src2)
    first2 = secs2.sections[0]
    sess = studio_session.restart(sess, secs2, src2, first2.id, 1)
    print "run_seq-after-restart=" + sess.run_seq
    sess = drain(sess)
    sess = studio_session.finalize(sess, secs2, src2)
    show("restarted mid-run", sess)
  end if

  if mode = "refuse" then
    sess = studio_session.create("doc-1", scratch)

    ' (1) source does not parse -- last-known-good must not be executed
    good = base_src()
    secs = sections_for(good)
    target = secs.sections[0].id
    secs = studio_sections.refresh(secs, broken_src())
    sess = studio_session.run(sess, secs, broken_src(), target)
    show("refuse: source does not parse", sess)

    ' (2) ambiguous section
    dsrc = dup_src()
    dsecs = sections_for(dsrc)
    dsecs = studio_sections.refresh(dsecs, dsrc)
    amb = ""
    for each s in dsecs.sections
      if s.status = "ambiguous" then
        amb = s.id
      end if
    end for
    print "found-ambiguous=" + (amb != "")
    sess2 = studio_session.create("doc-2", scratch)
    sess2 = studio_session.run(sess2, dsecs, dsrc, amb)
    show("refuse: ambiguous section", sess2)

    ' (3) stale / removed section
    ssrc = base_src()
    ssecs = sections_for(ssrc)
    doomed = ssecs.sections[count(ssecs.sections) - 1].id
    shorter = "print \"one\"\n"
    ssecs = studio_sections.refresh(ssecs, shorter)
    sess3 = studio_session.create("doc-3", scratch)
    sess3 = studio_session.run(sess3, ssecs, shorter, doomed)
    show("refuse: stale section", sess3)
  end if

  if mode = "signal" then
    src = signal_src()
    secs = sections_for(src)
    sess = studio_session.create("doc-1", scratch)
    last = secs.sections[count(secs.sections) - 1]
    sess = run_and_show("child killed by signal", sess, secs, src, last.id)
    print "diagnostics=" + count(sess.diagnostics)
  end if

  if mode = "big" then
    src = big_src()
    secs = sections_for(src)
    sess = studio_session.create("doc-1", scratch)
    last = secs.sections[count(secs.sections) - 1]
    sess = studio_session.run(sess, secs, src, last.id)
    sess = drain(sess)
    sess = studio_session.finalize(sess, secs, src)
    total = byte_count(sess.out_prefix) + byte_count(sess.out_target)
    print "state=" + sess.state
    print "exit_code=" + sess.exit_code
    print "output_bytes=" + total
    print "exceeded_pipe_buffer=" + (total > 65536)
  end if

  if mode = "edited" then
    ' The document is edited between two runs, so the materialized prefix differs.
    src1 = base_src()
    secs1 = sections_for(src1)
    sess = studio_session.create("doc-1", scratch)
    last1 = secs1.sections[count(secs1.sections) - 1]
    m1 = studio_session.materialize_text(src1, last1, secs1, "", "", "", [], [], { name: "", path: "", cap: 0, chunk: 500, stamp: "" })
    print "run1_prefix_bytes=" + byte_count(m1.text)
    sess = run_and_show("run 1", sess, secs1, src1, last1.id)

    src2 = "print \"one\"\n\nfunction add(a, b)\n  return a + b\nend function\n\nprint add(2, 3)\n\nprint \"CHANGED\"\n"
    secs2 = studio_sections.refresh(secs1, src2)
    last2 = secs2.sections[count(secs2.sections) - 1]
    m2 = studio_session.materialize_text(src2, last2, secs2, "", "", "", [], [], { name: "", path: "", cap: 0, chunk: 500, stamp: "" })
    print "run2_prefix_bytes=" + byte_count(m2.text)
    print "same_section_id=" + (last1.id = last2.id)
    sess = run_and_show("run 2 after edit", sess, secs2, src2, last2.id)
  end if

  if mode = "scratch" then
    ' Scratch lifecycle: a finished run leaves nothing behind, and a sweep clears
    ' whatever a crashed Studio did leave.
    persist.ensure_dir(scratch)
    d(dir) = scratch
    src = base_src()
    secs = sections_for(src)
    sess = studio_session.create("doc-1", scratch)
    first = secs.sections[0]
    sess = studio_session.run(sess, secs, src, first.id)
    print "file_exists_during_run=" + (sess.prefix_path != "")
    sess = drain(sess)
    print "prefix_path_after_finish=<" + sess.prefix_path + ">"
    print "files_left_after_run=" + count(list(d))

    ' Simulate a crashed Studio: two orphaned prefixes.
    a(file) = scratch + "/run-doc-9-1.bas"
    b(file) = scratch + "/run-doc-9-2.bas"
    write(a, "print 1\n")
    write(b, "print 2\n")
    print "orphans_before_sweep=" + count(list(d))
    n = studio_session.sweep_scratch(scratch)
    print "swept=" + n
    print "files_after_sweep=" + count(list(d))
  end if

  ' ---- STU-4B: declaration hoisting --------------------------------------

  if mode = "hoist" then
    ' The gap STU-4 named: a program body calling a helper declared after
    ' `end program`. The byte prefix cannot reach the helper, so the run only
    ' succeeds if the declaration is hoisted after the appended `end program`.
    src = hoist_after_src()
    secs = sections_for(src)
    print "sections=" + count(secs.sections)
    sess = studio_session.create("doc-1", scratch)
    first = secs.sections[0]
    print "target_kind=" + first.kind + " ancestry=" + first.anchor.ancestry
    sess = run_and_show("run body section calling a helper declared below", sess, secs, src, first.id)
    print "hoisted=" + count(sess.hoisted)
  end if

  if mode = "hoist_before" then
    ' The same program with the helper declared ABOVE: it is already inside every
    ' prefix, so nothing is hoisted and the result is exactly STU-4's.
    src = hoist_before_src()
    secs = sections_for(src)
    sess = studio_session.create("doc-1", scratch)
    ' Section 0 is the top-level `add` declaration; section 1 is the body statement.
    target = secs.sections[1]
    print "target_kind=" + target.kind + " ancestry=" + target.anchor.ancestry
    sess = run_and_show("helper declared above the block", sess, secs, src, target.id)
    print "hoisted=" + count(sess.hoisted)
  end if

  if mode = "hoist_order" then
    ' Several post-target declarations: source order preserved, each landing after
    ' the appended `end program` where a top-level declaration is legal.
    src = hoist_after_src()
    secs = sections_for(src)
    first = secs.sections[0]
    m = studio_session.materialize_text(src, first, secs, "", "", "", [], [], { name: "", path: "", cap: 0, chunk: 500, stamp: "" })
    print "appended=" + m.appended
    print "hoisted=" + count(m.hoisted)
    for each h in m.hoisted
      print "hoist " + h.kind + " " + h.name + " doc_line=" + h.doc_start_line + " child_line=" + h.child_start_line + " lines=" + h.lines
    end for
    print "materialized=<" + m.text + ">"
  end if

  if mode = "hoist_err" then
    ' A raise inside a hoisted declaration's body. Its reported position is in the
    ' hoisted text, and the map must translate it back to the declaration's real
    ' line in the document.
    src = hoist_err_src()
    secs = sections_for(src)
    sess = studio_session.create("doc-1", scratch)
    first = secs.sections[0]
    sess = run_and_show("error inside a hoisted declaration", sess, secs, src, first.id)
    for each d in sess.diagnostics
      print "raw_child_line=" + d.start.line
    end for
  end if

  if mode = "hoist_target" then
    ' The target IS a declaration (the in-body `inner`). It is the prefix's last
    ' section, so it is never hoisted into itself; the declarations below it still
    ' are.
    src = hoist_after_src()
    secs = sections_for(src)
    sess = studio_session.create("doc-1", scratch)
    target = secs.sections[1]
    print "target_kind=" + target.kind + " name=" + target.name
    sess = run_and_show("target is itself a declaration", sess, secs, src, target.id)
    print "hoisted=" + count(sess.hoisted)
    for each h in sess.hoisted
      print "hoist " + h.kind + " " + h.name
    end for
  end if

  if mode = "hoist_inert" then
    ' Proof that hoisting reorders no observable effect: a top-level `print` sits
    ' between the block and the hoisted declaration, and it never runs -- because
    ' when a program block is present it is the ONLY thing that executes.
    src = hoist_inert_src()
    secs = sections_for(src)
    sess = studio_session.create("doc-1", scratch)
    first = secs.sections[0]
    sess = run_and_show("top-level statement below the block stays inert", sess, secs, src, first.id)
    print "top_level_ran=" + (find(sess.out_target + sess.out_prefix, "TOP-LEVEL-NEVER-RUNS") != nothing)
  end if

  ' ---- STU-4B: output separation -----------------------------------------

  if mode = "split" then
    ' Output on both sides of the boundary: the injected marker separates them.
    src = split_src()
    secs = sections_for(src)
    sess = studio_session.create("doc-1", scratch)
    last = secs.sections[count(secs.sections) - 1]
    sess = run_and_show("separated stdout", sess, secs, src, last.id)
    print "split_out=" + sess.split_out + " split_err=" + sess.split_err
    print "split_reason=<" + sess.split_reason + ">"
    print "marker_in_display=" + (find(sess.out_prefix + sess.out_target, sess.marker) != nothing)
  end if

  if mode = "split_nonce" then
    ' A user program that prints the nonce itself. Two occurrences, no way to tell
    ' which is the boundary -- so the run falls back to combined and says why,
    ' rather than guessing (the STU-3 ambiguity principle).
    fixed = "@@studio-boundary-TESTNONCE@@"
    src = "print \"PREFIX-OUT\"\nprint \"" + fixed + "\"\n\nfunction f(x)\n  return x\nend function\n\nprint \"TARGET-OUT\"\n"
    secs = sections_for(src)
    sess = studio_session.create("doc-1", scratch)
    sess.nonce_fixed = fixed
    last = secs.sections[count(secs.sections) - 1]
    sess = run_and_show("user program prints the nonce", sess, secs, src, last.id)
    print "split_out=" + sess.split_out + " split_err=" + sess.split_err
    print "split_reason=<" + sess.split_reason + ">"
  end if

  if mode = "split_die" then
    ' The child dies inside the prefix, before the marker is reached. No marker is
    ' the CORRECT answer here, not an error: nothing of the target ever ran.
    src = split_die_src()
    secs = sections_for(src)
    sess = studio_session.create("doc-1", scratch)
    last = secs.sections[count(secs.sections) - 1]
    sess = run_and_show("child dies before the boundary", sess, secs, src, last.id)
    print "split_out=" + sess.split_out + " split_err=" + sess.split_err
    print "split_reason=<" + sess.split_reason + ">"
  end if

  if mode = "split_stderr" then
    ' stdout separates; stderr cannot. The marker is a `print`, so it appears on
    ' stdout only -- there is no boundary in the diagnostic stream and the session
    ' says so instead of implying stderr was separated too.
    src = "print \"PREFIX-OUT\"\n\nfunction f(x)\n  return x\nend function\n\nprint \"TARGET-OUT\"\nprint 1 / 0\n"
    secs = sections_for(src)
    sess = studio_session.create("doc-1", scratch)
    last = secs.sections[count(secs.sections) - 1]
    sess = run_and_show("stdout separated, stderr not", sess, secs, src, last.id)
    print "split_out=" + sess.split_out + " split_err=" + sess.split_err
    print "err_prefix=<" + sess.err_prefix + ">"
    print "err_target=<" + sess.err_target + ">"
  end if

  ' ---- STU-4B: the position map, exercised directly ----------------------

  if mode = "map" then
    ' The map is built from content Studio generated, so it is exact rather than
    ' inferred. Probe it directly at every boundary instead of only through error
    ' attribution.
    ' The last section of the program BODY: a prefix exists (so a marker is
    ' injected), the block is cut open (so `end program` is generated), and two
    ' top-level declarations sit below it (so both are hoisted). One materialization
    ' exercising every segment kind at once.
    src = hoist_after_src()
    secs = sections_for(src)
    target = secs.sections[2]
    m = studio_session.materialize_text(src, target, secs, "@@nonce@@", "", "", [], [], { name: "", path: "", cap: 0, chunk: 500, stamp: "" })
    print "-- marker + generated + hoist map"
    print "marker_line=" + m.map.marker_line
    print "segments=" + count(m.map.segments)
    for each s in m.map.segments
      print "seg " + s.kind + " child=" + s.c_start + ".." + s.c_end + " delta=" + s.delta
    end for
    probe = 1
    total = count(split(m.text, "\n")) - 1
    while probe <= total
      r = studio_session.map_line(m.map, probe)
      print "child " + probe + " -> " + r.kind + " " + r.line
      probe = probe + 1
    end while

    print "-- no marker (section 1), no hoist"
    src2 = split_src()
    secs2 = sections_for(src2)
    m2 = studio_session.materialize_text(src2, secs2.sections[0], secs2, "", "", "", [], [], { name: "", path: "", cap: 0, chunk: 500, stamp: "" })
    print "marker_line=" + m2.map.marker_line
    print "segments=" + count(m2.map.segments)
    r = studio_session.map_line(m2.map, 1)
    print "child 1 -> " + r.kind + " " + r.line
  end if

  ' ---- STU-4B: live output (--line-buffered) -----------------------------

  if mode = "stream" then
    ' PLAT-STREAM: sessions launch the child with --line-buffered, so a completed
    ' print arrives WHILE the child runs. Without it this loop would spin to its
    ' guard, because a block-buffered child shows nothing until it exits.
    src = "print \"EARLY-LINE\"\n\nwhile true\n  sleep(0.05)\nend while\n"
    secs = sections_for(src)
    sess = studio_session.create("doc-1", scratch)
    last = secs.sections[count(secs.sections) - 1]
    sess = studio_session.run(sess, secs, src, last.id)
    guard = 0
    seen_while_running = false
    while guard < 2000
      sess = studio_session.tick(sess)
      if find(sess.out_raw, "EARLY-LINE") != nothing then
        seen_while_running = (sess.state = "running")
        break
      end if
      guard = guard + 1
      sleep(0.01)
    end while
    print "saw_output_before_exit=" + seen_while_running
    print "state_at_observation=" + sess.state
    sess = studio_session.force_stop(sess, 2)
    sess = studio_session.finalize(sess, secs, src)
    print "final_state=" + sess.state
  end if

  ' ---- STU-4C: what the target section left behind -------------------------
  if mode = "vars" then
    src = vars_src()
    secs = sections_for(src)
    sess = studio_session.create("doc-1", scratch)
    last = secs.sections[count(secs.sections) - 1]
    sess = run_and_show("the last section, with a prefix above it", sess, secs, src, last.id)
    show_vars(sess)

    ' Section 1 has no prefix and no boundary marker, but it still has variables.
    sess2 = studio_session.create("doc-1", scratch)
    sess2 = run_and_show("section 1 — no prefix, no marker", sess2, secs, src, secs.sections[0].id)
    show_vars(sess2)

    ' A program BODY. The epilogue has to go INSIDE the block: nothing after
    ' `end program` executes, so an epilogue appended at the end of the file
    ' would report nothing at all, silently, and only for these documents.
    psrc = vars_prog_src()
    psecs = sections_for(psrc)
    sess3 = studio_session.create("doc-2", scratch)
    plast = psecs.sections[count(psecs.sections) - 1]
    sess3 = run_and_show("inside a program block", sess3, psecs, psrc, plast.id)
    show_vars(sess3)

    ' A section that RAISES never reaches the epilogue. "absent" is the ordinary
    ' answer, not an error.
    esrc = "x = 1\n\nfunction f(n)\n  return n\nend function\n\nprint 1 / 0\n"
    esecs = sections_for(esrc)
    sess4 = studio_session.create("doc-3", scratch)
    elast = esecs.sections[count(esecs.sections) - 1]
    sess4 = run_and_show("a section that raises", sess4, esecs, esrc, elast.id)
    show_vars(sess4)

    ' A program that prints the marker itself: the run declines to guess which
    ' occurrence is ours, exactly as the boundary marker does.
    sess5 = studio_session.create("doc-4", scratch)
    sess5.vars_fixed = "@@vars@@"
    msrc = "print \"@@vars@@\"\n\nfunction g(n)\n  return n\nend function\n\nk = 5\n"
    msecs = sections_for(msrc)
    mlast = msecs.sections[count(msecs.sections) - 1]
    sess5 = run_and_show("a program that prints the marker itself", sess5, msecs, msrc, mlast.id)
    show_vars(sess5)
  end if
end program
