' STU-5A headless driver for the persistent results store (studio_results).
' Dispatches on args[0] to a scenario and prints a deterministic, PATH-FREE
' transcript for golden comparison. args[1] is a scratch directory for materialized
' prefixes, args[2] a throwaway Studio home holding the results store; neither path
' is ever printed.
'
' Timestamps are pinned through the session's `clock_fixed` seam, so every golden is
' byte-stable while the real clock still drives a real run.

' ---- source fixtures -------------------------------------------------------

function base_src()
  return "print \"one\"\n\nfunction add(a, b)\n  return a + b\nend function\n\nprint add(2, 3)\n"
end function

' The middle declaration's BODY differs from base_src, so its fingerprint moves
' while its id survives reattachment -- the exact situation a result must notice.
function edited_src()
  return "print \"one\"\n\nfunction add(a, b)\n  return a + b + 0\nend function\n\nprint add(2, 3)\n"
end function

' add() removed entirely: its id goes to stale_ids, so a result naming it is orphaned.
function removed_src()
  return "print \"one\"\n\nprint 42\n"
end function

' add() duplicated verbatim -> both candidates go `ambiguous` (STU-3).
function ambiguous_src()
  return "print \"one\"\n\nfunction add(a, b)\n  return a + b\nend function\n\nfunction add(a, b)\n  return a + b\nend function\n"
end function

function broken_src()
  return "print \"one\"\n\nfunction add(a, b)\n  return a +\n"
end function

function signal_src()
  return "print \"before\"\n\nprocess.run({ command: \"sh\", args: [\"-c\", \"kill -TERM $PPID\"] })\n"
end function

' ~85 KB on stdout -- decisively past the 64 KB per-capture cap, which is the whole
' claim, and sized to that claim rather than larger: a bigger fixture would prove
' nothing more while making every tier (and especially the valgrind one, where the
' driver's own string handling is instrumented) pay for it.
function big_src()
  return "i = 0\n\nwhile i < 2500\n  print \"line-\" + i + \"-padding-padding-padding\"\n  i = i + 1\nend while\n"
end function

function other_src()
  return "print \"other-one\"\n\nfunction mul(a, b)\n  return a * b\nend function\n\nprint mul(2, 3)\n"
end function

' ---- helpers ---------------------------------------------------------------

function sections_for(src)
  st = studio_sections.create("doc-1")
  return studio_sections.refresh(st, src)
end function

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

' A session with its clock pinned, so started/finished/duration are golden-stable.
function pinned_session(doc_id, scratch, at)
  sess = studio_session.create(doc_id, scratch)
  sess.clock_fixed = at
  return sess
end function

' Run one section to completion and hand back the finished session.
function do_run(sess, secs, src, sid)
  sess = studio_session.run(sess, secs, src, sid)
  sess = drain(sess)
  return studio_session.finalize(sess, secs, src)
end function

' Run a section and record its result, returning the updated store.
function run_and_record(home, store, sess, secs, src, sid)
  sess = do_run(sess, secs, src, sid)
  r = studio_session.to_result(sess, secs)
  return studio_results.add_result(home, store, r)
end function

' The index record plus the captures it points at -- read on demand, exactly as the
' UI reads them, so the transcript reflects the real two-part layout.
function show_result(home, store, r)
  if r = nothing then
    print "  (none)"
    return nothing
  end if
  line = "  " + r.result_id + " section=" + r.section_id + " outcome=" + r.outcome
  line = line + " exit=" + r.exit_code + " signal=" + r.signal
  print line
  print "    fp=" + r.section_fingerprint + " kind=" + r.section_kind + " name=" + string(r.section_name)
  print "    at=" + r.started_epoch + ".." + r.finished_epoch + " duration=" + r.duration_seconds + "s"
  print "    split=out:" + r.split_out + " err:" + r.split_err + " reason=<" + r.split_reason + ">"
  if r.reason != "" then
    print "    reason=" + r.reason + " message=" + r.message
  end if
  print "    out_prefix=<" + studio_results.capture(home, store, r.result_id, "out_prefix") + ">"
  print "    out_target=<" + studio_results.capture(home, store, r.result_id, "out_target") + ">"
  print "    capture_bytes out_prefix=" + studio_results.capture_bytes(r, "out_prefix") + " out_target=" + studio_results.capture_bytes(r, "out_target")
  if count(r.truncated) > 0 then
    print "    truncated=" + join(r.truncated, ",")
  end if
  for each a in r.attribution
    sid = "-"
    if a.section_id != nothing then
      sid = a.section_id
    end if
    print "    ! " + a.where + " section=" + sid + " " + a.line + ":" + a.column + " " + a.message
  end for
  return nothing
end function

' The classification of every stored result against the CURRENT sections.
function show_classified(store, secs, label)
  print "-- " + label
  for each c in studio_results.classify(store, secs)
    nm = "-"
    if c.result.section_name != nothing then
      nm = c.result.section_name
    end if
    print "  " + c.result.result_id + " section=" + c.result.section_id + " name=" + nm + " -> " + c.standing
  end for
  return nothing
end function

' ---- STU-5: values worth previewing ---------------------------------------
function preview_src()
  ' One of each shape the viewer dispatches on: a scalar, a flat list, an array
  ' of records (tabular), a record, and an array long enough to be sampled.
  return "n = 42\nname = \"studio\"\n\nfunction f(q)\n  return q\nend function\n\nnums = [10, 20, 30]\nrows = [{ id: 1, who: \"ada\" }, { id: 2, who: \"bob\" }]\nrec = { a: 1, b: \"two\" }\nbig = []\ni = 0\nwhile i < 500\n  big = append(big, i)\n  i = i + 1\nend while\n"
end function

program main(args)
  load persist
  load studio_sections
  load studio_session
  load studio_results

  mode = ""
  if count(args) > 0 then
    mode = args[0]
  end if
  scratch = "/tmp/gbasic_stu5a_scratch"
  if count(args) > 1 then
    scratch = args[1]
  end if
  home = "/tmp/gbasic_stu5a_home"
  if count(args) > 2 then
    home = args[2]
  end if

  ' ---- previews: what a variable's value looks like in a result ----------
  if mode = "preview" then
    src = preview_src()
    secs = sections_for(src)
    last = secs.sections[count(secs.sections) - 1]
    store = studio_results.open(home, "/proj/p.bas")
    store = run_and_record(home, store, pinned_session("doc-1", scratch, 1000), secs, src, last.id)
    studio_results.save(home, store)

    r = studio_results.latest_for(store, last.id)
    print "-- viewer dispatch"
    vs = studio_results._before_vars(home, store, r)
    print "before_count=" + count(vs)
    after = try_decode(studio_results.capture(home, store, r.result_id, "vars"))
    for each v in after.value
      print "  " + v.name + " -> " + studio_results.viewer_for(v)
    end for

    print "-- the pane"
    print studio_results.view_text(home, store, secs, last.id)

    ' The bound is the point: a 500-element array is SAMPLED, never copied.
    print "-- bounds"
    for each v in after.value
      if v.name = "big" then
        print "  captured rows=" + count(v.preview.rows) + " more=" + v.preview.more + " count=" + v.count
      end if
    end for
    print "  capture bytes=" + (studio_results.capture_bytes(r, "vars") < 8000)
  end if

  ' ---- a result persisted and restored across a simulated restart --------
  if mode = "persist" then
    src = base_src()
    secs = sections_for(src)
    store = studio_results.open(home, "/proj/a.bas")
    print "loaded_empty=" + (count(store.results) = 0)

    sess = pinned_session("doc-1", scratch, 1000)
    last = secs.sections[count(secs.sections) - 1]
    store = run_and_record(home, store, sess, secs, src, last.id)
    studio_results.save(home, store)
    print "recorded=" + count(store.results)

    ' Simulated restart: nothing carried over but the home directory.
    print "-- after restart"
    restored = studio_results.open(home, "/proj/a.bas")
    print "restored=" + count(restored.results)
    show_result(home, restored, studio_results.latest_for(restored, last.id))
    print "identical_to_live=" + (json_encode(restored.results) = json_encode(store.results))
  end if

  ' ---- history: most recent first, restored across a restart -------------
  if mode = "history" then
    src = base_src()
    secs = sections_for(src)
    last = secs.sections[count(secs.sections) - 1]
    first = secs.sections[0]
    store = studio_results.open(home, "/proj/a.bas")

    ' Three runs of the target, one of another section interleaved, at rising
    ' clock values so ordering is checkable rather than incidental.
    store = run_and_record(home, store, pinned_session("doc-1", scratch, 1000), secs, src, last.id)
    store = run_and_record(home, store, pinned_session("doc-1", scratch, 1100), secs, src, first.id)
    store = run_and_record(home, store, pinned_session("doc-1", scratch, 1200), secs, src, last.id)
    store = run_and_record(home, store, pinned_session("doc-1", scratch, 1300), secs, src, last.id)
    studio_results.save(home, store)

    print "total=" + count(store.results)
    print "-- all results, newest first"
    for each r in store.results
      print "  " + r.result_id + " section=" + r.section_id + " at=" + r.started_epoch
    end for
    print "-- history for the target section"
    for each r in studio_results.history_for(store, last.id)
      print "  " + r.result_id + " at=" + r.started_epoch
    end for
    print "latest=" + studio_results.latest_for(store, last.id).result_id

    print "-- after restart"
    restored = studio_results.open(home, "/proj/a.bas")
    for each r in restored.results
      print "  " + r.result_id + " section=" + r.section_id + " at=" + r.started_epoch
    end for
  end if

  ' ---- the section is edited after the run: fingerprint mismatch --------
  if mode = "fingerprint" then
    src = base_src()
    secs = sections_for(src)
    mid_sec = secs.sections[1]
    store = studio_results.open(home, "/proj/a.bas")
    store = run_and_record(home, store, pinned_session("doc-1", scratch, 1000), secs, src, mid_sec.id)
    print "ran section=" + mid_sec.id + " kind=" + mid_sec.kind
    show_classified(store, secs, "against the source it ran")

    ' Edit the middle declaration's body. STU-3 keeps its id (that is the whole
    ' point of stable ids), so id alone could not tell these apart.
    st2 = studio_sections.refresh(secs, edited_src())
    same_id = false
    for each s in st2.sections
      if s.id = mid_sec.id then
        same_id = true
      end if
    end for
    print "id_survived_edit=" + same_id
    show_classified(store, st2, "against the edited source")

    ' Reindentation must NOT count as a change: the fingerprint folds whitespace.
    st3 = studio_sections.refresh(secs, base_src())
    show_classified(store, st3, "against the original source again")
  end if

  ' ---- orphaned results across each STU-3 state -------------------------
  if mode = "orphan" then
    src = base_src()
    secs = sections_for(src)
    mid_sec = secs.sections[1]
    store = studio_results.open(home, "/proj/a.bas")
    store = run_and_record(home, store, pinned_session("doc-1", scratch, 1000), secs, src, mid_sec.id)
    studio_results.save(home, store)
    print "recorded=" + count(store.results)

    ' 1. REMOVED: the declaration is deleted, so its id goes stale.
    gone = studio_sections.refresh(secs, removed_src())
    print "stale_ids=" + join(gone.stale_ids, ",")
    show_classified(store, gone, "section removed")

    ' 2. AMBIGUOUS: duplicated verbatim, so STU-3 refuses to guess WHICH copy is
    ' the original -- it mints FRESH ids for both candidates and sends the old id
    ' to stale_ids. The section state is printed here rather than described,
    ' because it is the reason the result below reads `section-gone` and not
    ' `section-ambiguous`: the id it names no longer denotes anything, and
    ' attaching it to either copy would be a guess. Silence about which is the
    ' honest answer.
    amb = studio_sections.refresh(secs, ambiguous_src())
    print studio_sections.summary(amb)
    print "stale_ids=" + join(amb.stale_ids, ",")
    show_classified(store, amb, "section ambiguous")

    ' A result CAN name an ambiguous section, by the one path that produces one:
    ' asking to run it. Studio refuses (STU-4), the refusal is recorded (STU-5A),
    ' and that record classifies as `section-ambiguous` -- distinct from gone.
    dup = amb.sections[1]
    sess = pinned_session("doc-1", scratch, 1100)
    sess = studio_session.run(sess, amb, ambiguous_src(), dup.id)
    print "run_ambiguous state=" + sess.state + " reason=" + sess.reason
    store = studio_results.add_result(home, store, studio_session.to_result(sess, amb))
    show_classified(store, amb, "with a refusal against the ambiguous section")

    ' 3. SOURCE INVALID: the document no longer parses, so the sections on hand are
    ' last-known-good and nothing can honestly be compared against the live text.
    bad = studio_sections.refresh(secs, broken_src())
    print "valid=" + bad.valid
    show_classified(store, bad, "source invalid")

    ' Through all of it the results themselves are untouched -- never deleted,
    ' never reattached to a different section.
    restored = studio_results.open(home, "/proj/a.bas")
    print "-- survived every state"
    print "still_stored=" + count(restored.results)
    print "still_section=" + restored.results[0].section_id
  end if

  ' ---- a refused run is a thing that happened ---------------------------
  if mode = "refused" then
    src = broken_src()
    secs = sections_for(src)
    print "valid=" + secs.valid
    store = studio_results.open(home, "/proj/a.bas")
    ' Refused because the document does not parse.
    sess = pinned_session("doc-1", scratch, 1000)
    sess = studio_session.run(sess, secs, src, "sec-1")
    print "state=" + sess.state + " reason=" + sess.reason
    store = studio_results.add_result(home, store, studio_session.to_result(sess, secs))

    ' Refused because there is no such section.
    good = sections_for(base_src())
    sess2 = pinned_session("doc-1", scratch, 1100)
    sess2 = studio_session.run(sess2, good, base_src(), "sec-999")
    print "state=" + sess2.state + " reason=" + sess2.reason
    store = studio_results.add_result(home, store, studio_session.to_result(sess2, good))
    studio_results.save(home, store)

    print "-- stored refusals"
    for each r in store.results
      show_result(home, store, r)
    end for
    restored = studio_results.open(home, "/proj/a.bas")
    print "restored=" + count(restored.results)
  end if

  ' ---- a run killed by a signal -----------------------------------------
  if mode = "signal" then
    src = signal_src()
    secs = sections_for(src)
    store = studio_results.open(home, "/proj/a.bas")
    last = secs.sections[count(secs.sections) - 1]
    store = run_and_record(home, store, pinned_session("doc-1", scratch, 1000), secs, src, last.id)
    studio_results.save(home, store)
    r = store.results[0]
    print "outcome=" + r.outcome + " exit=" + r.exit_code + " signal=" + r.signal + " success=" + r.success
    restored = studio_results.open(home, "/proj/a.bas")
    print "restored_signal=" + restored.results[0].signal
  end if

  ' ---- output past the size cap, truncation recorded honestly -----------
  if mode = "truncate" then
    src = big_src()
    secs = sections_for(src)
    store = studio_results.open(home, "/proj/a.bas")
    last = secs.sections[count(secs.sections) - 1]
    sess = do_run(pinned_session("doc-1", scratch, 1000), secs, src, last.id)
    print "live_bytes=" + byte_count(sess.out_target)
    print "cap=" + studio_results.capture_cap()
    r = studio_session.to_result(sess, secs)
    store = studio_results.add_result(home, store, r)
    studio_results.save(home, store)

    stored = store.results[0]
    text = studio_results.capture(home, store, stored.result_id, "out_target")
    print "stored_bytes=" + byte_count(text)
    print "index_bytes=" + studio_results.capture_bytes(stored, "out_target")
    print "truncated=" + join(stored.truncated, ",")
    print "over_cap=" + (byte_count(sess.out_target) > studio_results.capture_cap())
    ' The stored text SAYS it was cut, so a reader that ignored the field still
    ' cannot mistake it for the whole capture.
    print "notice_present=" + (find(text, studio_results.truncation_notice()) != nothing)
    print "starts_with_head=" + (left(text, 7) = "line-0-")
    restored = studio_results.open(home, "/proj/a.bas")
    rtext = studio_results.capture(home, restored, restored.results[0].result_id, "out_target")
    print "restored_bytes=" + byte_count(rtext)
    print "restored_truncated=" + join(restored.results[0].truncated, ",")
  end if

  ' ---- eviction at the retention limit ----------------------------------
  if mode = "evict" then
    src = base_src()
    secs = sections_for(src)
    last = secs.sections[count(secs.sections) - 1]
    other = secs.sections[0]
    store = studio_results.open(home, "/proj/a.bas")
    keep = studio_results.retain_per_section()
    print "retain_per_section=" + keep

    ' One more run than the limit, plus one run of a DIFFERENT section, which must
    ' not be evicted by the first section's churn.
    store = run_and_record(home, store, pinned_session("doc-1", scratch, 900), secs, src, other.id)
    i = 0
    while i < keep + 3
      store = run_and_record(home, store, pinned_session("doc-1", scratch, 1000 + i), secs, src, last.id)
      i = i + 1
    end while
    studio_results.save(home, store)

    print "target_kept=" + count(studio_results.history_for(store, last.id))
    print "other_kept=" + count(studio_results.history_for(store, other.id))
    print "total=" + count(store.results)
    h = studio_results.history_for(store, last.id)
    print "newest=" + h[0].started_epoch
    print "oldest=" + h[count(h) - 1].started_epoch
    restored = studio_results.open(home, "/proj/a.bas")
    print "restored_total=" + count(restored.results)

    ' Eviction must take the capture FILES with it, or the index shrinks while the
    ' disk does not -- the retention bound would be fiction.
    cd(dir) = studio_results.capture_dir(home, "/proj/a.bas")
    live_ids = []
    for each r in restored.results
      live_ids = append(live_ids, r.result_id)
    end for
    orphans = 0
    files = 0
    for each e in list(cd)
      if e.type != "folder" then
        files = files + 1
        rid = first(split(e.name, "."))
        known = false
        for each id in live_ids
          if id = rid then
            known = true
          end if
        end for
        if not known then
          orphans = orphans + 1
        end if
      end if
    end for
    print "capture_files=" + files
    print "orphan_capture_files=" + orphans

    ' And a file left behind by an interrupted write is swept on the next save.
    stray(file) = studio_results.capture_path(home, "/proj/a.bas", "res-9999", "out_target")
    write(stray, "left over from a crash")
    print "stray_written=" + exists(stray)
    swept = studio_results.save(home, restored)
    print "stray_swept=" + (not exists(stray))
  end if

  ' ---- two documents running concurrently, no clobbering ----------------
  if mode = "concurrent" then
    src_a = base_src()
    src_b = other_src()
    secs_a = sections_for(src_a)
    secs_b = sections_for(src_b)
    last_a = secs_a.sections[count(secs_a.sections) - 1]
    last_b = secs_b.sections[count(secs_b.sections) - 1]

    ' Two sessions, two documents, INTERLEAVED tick-by-tick -- both children alive
    ' at the same moment, which is what STU-4 permits and what a per-document store
    ' has to survive.
    sa = pinned_session("doc-1", scratch, 1000)
    sb = pinned_session("doc-2", scratch, 1000)
    sa = studio_session.run(sa, secs_a, src_a, last_a.id)
    sb = studio_session.run(sb, secs_b, src_b, last_b.id)
    print "both_active=" + (studio_session.is_active(sa) and studio_session.is_active(sb))
    guard = 0
    while guard < 4000
      if not studio_session.is_active(sa) then
        if not studio_session.is_active(sb) then
          break
        end if
      end if
      sa = studio_session.tick(sa)
      sb = studio_session.tick(sb)
      guard = guard + 1
      sleep(0.01)
    end while
    sa = studio_session.finalize(sa, secs_a, src_a)
    sb = studio_session.finalize(sb, secs_b, src_b)

    ' Both stores are written while the other is also being written. Distinct
    ' documents mean distinct files, so neither can clobber the other.
    store_a = studio_results.open(home, "/proj/a.bas")
    store_b = studio_results.open(home, "/proj/b.bas")
    store_a = studio_results.add_result(home, store_a, studio_session.to_result(sa, secs_a))
    store_b = studio_results.add_result(home, store_b, studio_session.to_result(sb, secs_b))
    studio_results.save(home, store_a)
    studio_results.save(home, store_b)
    pa = studio_results.store_path(home, "/proj/a.bas")
    pb = studio_results.store_path(home, "/proj/b.bas")
    print "distinct_files=" + (pa != pb)
    ' The atomic-write temp sibling is named from the store path, so two documents
    ' cannot collide on the scratch file either -- the failure mode a shared
    ' `.tmp` name would introduce.
    ' Bound out rather than compared inline: a `)` followed by `(` trips the
    ' modifier-clause lexer (the collision persist._last documents).
    ta = pa + ".tmp"
    tb = pb + ".tmp"
    print "distinct_tmp=" + (ta != tb)

    ' Non-clobbering, tested rather than inferred: snapshot B's file, write A
    ' again, and require B's bytes to be untouched.
    fb(file) = pb
    before_b = read(fb)
    store_a = studio_results.add_result(home, store_a, studio_session.to_result(sa, secs_a))
    studio_results.save(home, store_a)
    after_b = read(fb)
    print "b_untouched_by_a_write=" + (before_b = after_b)
    print "a_grew=" + (count(studio_results.open(home, "/proj/a.bas").results) = 2)

    ra = studio_results.open(home, "/proj/a.bas")
    rb = studio_results.open(home, "/proj/b.bas")
    print "a_results=" + count(ra.results) + " a_out=<" + studio_results.capture(home, ra, ra.results[0].result_id, "out_target") + ">"
    print "b_results=" + count(rb.results) + " b_out=<" + studio_results.capture(home, rb, rb.results[0].result_id, "out_target") + ">"
    print "a_doc_path_kept=" + (ra.doc_path = "/proj/a.bas")
    print "b_doc_path_kept=" + (rb.doc_path = "/proj/b.bas")
  end if

  ' ---- a pre-STU-5A home loads unchanged --------------------------------
  if mode = "compat" then
    ' A home with no results directory at all is exactly a pre-STU-5A home.
    print "-- pre-STU-5A home (no results directory)"
    store = studio_results.open(home, "/proj/a.bas")
    print "status=" + store.status
    print "results=" + count(store.results)
    print "doc_path_kept=" + (store.doc_path = "/proj/a.bas")

    ' Writing then reading is additive: nothing else in the home is touched.
    src = base_src()
    secs = sections_for(src)
    last = secs.sections[count(secs.sections) - 1]
    store = run_and_record(home, store, pinned_session("doc-1", scratch, 1000), secs, src, last.id)
    studio_results.save(home, store)
    print "after_write=" + count(studio_results.open(home, "/proj/a.bas").results)

    ' A corrupt store must not raise, and must not pretend to hold results.
    print "-- corrupt store"
    p = studio_results.store_path(home, "/proj/c.bas")
    f(file) = p
    write(f, "{ this is not json")
    bad = studio_results.open(home, "/proj/c.bas")
    print "status=" + bad.status
    print "results=" + count(bad.results)

    ' A store written by a FUTURE schema is refused rather than misread.
    print "-- future schema"
    p2 = studio_results.store_path(home, "/proj/d.bas")
    persist.write_atomic(p2, { schema_version: 999, doc_path: "/proj/d.bas", next_result: 1, results: [] })
    fut = studio_results.open(home, "/proj/d.bas")
    print "status=" + fut.status
    print "results=" + count(fut.results)
  end if

  ' ---- the truncation path on its own, without a child run --------------
  '
  ' `truncate` above proves truncation end-to-end from a real child, which is the
  ' claim that matters -- but it costs ~20s uninstrumented and ~9.5 min under
  ' valgrind, almost all of it in the SESSION absorbing 84 KB through repeated
  ' string concatenation (STU-4 code, unchanged here). This mode drives the same
  ' store paths -- _truncate, _byte_prefix, add_result, save, open -- on a string
  ' built in memory, in under a second, so the valgrind tier can cover them
  ' without paying for a replay it is not testing.
  if mode = "truncate_unit" then
    over = repeat("padding-line-of-known-width\n", 4000)
    print "input_bytes=" + byte_count(over)
    print "over_cap=" + (byte_count(over) > studio_results.capture_cap())

    r = {
      result_id: "", section_id: "sec-1", section_fingerprint: "1:2",
      section_kind: "statements", section_name: nothing,
      started_epoch: 1000, finished_epoch: 1000, duration_seconds: 0,
      outcome: "finished", exit_code: 0, signal: 0, success: true,
      reason: "", message: "",
      split_out: "exact", split_err: "exact", split_reason: "",
      out_prefix: "", out_target: over, err_prefix: "", err_target: over,
      vars: "", vars_status: "none", vars_before: "", vars_before_status: "none", branch: "",
      truncated: [], attribution: [], run_seq: 1
    }
    store = studio_results.open(home, "/proj/u.bas")
    store = studio_results.add_result(home, store, r)
    studio_results.save(home, store)

    s = store.results[0]
    ot = studio_results.capture(home, store, s.result_id, "out_target")
    et = studio_results.capture(home, store, s.result_id, "err_target")
    op = studio_results.capture(home, store, s.result_id, "out_prefix")
    print "truncated=" + join(s.truncated, ",")
    print "out_target_bytes=" + byte_count(ot)
    print "err_target_bytes=" + byte_count(et)
    print "out_prefix_untouched=" + (op = "")
    print "notice_present=" + (find(ot, studio_results.truncation_notice()) != nothing)
    ' The cut lands on a codepoint boundary, so a truncated capture is still valid
    ' text -- checked by round-tripping it through strict JSON, which a broken
    ' encoding would not survive.
    print "json_encodable=" + json_encodable(store.results)
    back = studio_results.open(home, "/proj/u.bas")
    print "restored_bytes=" + byte_count(studio_results.capture(home, back, back.results[0].result_id, "out_target"))
    print "restored_truncated=" + join(back.results[0].truncated, ",")

    ' A multi-byte codepoint straddling the cap must not be split in half.
    wide = repeat("é", 40000)
    print "wide_bytes=" + byte_count(wide)
    cut = studio_results._truncate(wide)
    print "wide_cut=" + cut.cut
    body = left(cut.text, len(cut.text) - len(studio_results.truncation_notice()) - 2)
    print "wide_codepoints_whole=" + (byte_count(body) = len(body) * 2)
  end if

  ' ---- the on-disk shape ------------------------------------------------
  if mode = "store" then
    src = base_src()
    secs = sections_for(src)
    last = secs.sections[count(secs.sections) - 1]
    store = studio_results.open(home, "/proj/a.bas")
    store = run_and_record(home, store, pinned_session("doc-1", scratch, 1000), secs, src, last.id)
    studio_results.save(home, store)

    raw = persist.read_status(studio_results.store_path(home, "/proj/a.bas"))
    print "status=" + raw.status
    print "schema_version=" + raw.value.schema_version
    print "doc_path=" + raw.value.doc_path
    print "next_result=" + raw.value.next_result
    print "results=" + count(raw.value.results)
    print "-- record keys"
    for each k in sort(keys(raw.value.results[0]))
      print "  " + k
    end for
    print "-- store keys"
    for each k in sort(keys(raw.value))
      print "  " + k
    end for
    ' Results live OUTSIDE the workspace record, so the workspace is unaffected.
    print "separate_from_workspace=" + (find(studio_results.store_path(home, "/proj/a.bas"), "/results/") != nothing)

    ' The two-part layout on disk: a small index, and the captures beside it.
    ' The split predates `try_decode` -- it was forced by a quadratic pure-gBASIC
    ' validator -- and is kept for write amplification (the index is rewritten
    ' whole on every save) and lazy reads (captures load only when displayed).
    print "-- on disk"
    idx(file) = studio_results.store_path(home, "/proj/a.bas")
    print "index_bytes_under_1k=" + (file_size(idx) < 1024)
    cd(dir) = studio_results.capture_dir(home, "/proj/a.bas")
    names = []
    for each e in list(cd)
      if e.type != "folder" then
        names = append(names, e.name)
      end if
    end for
    print "capture_files=" + join(sort(names), ",")
    ' An empty capture writes no file at all, so a clean run leaves the two streams
    ' that actually carried bytes and nothing else.
    print "index_holds_no_text=" + (not has(raw.value.results[0], "out_target"))
  end if

  ' ---- the minimal view (headless text) ---------------------------------
  if mode = "view" then
    src = base_src()
    secs = sections_for(src)
    mid_sec = secs.sections[1]
    store = studio_results.open(home, "/proj/a.bas")
    print "-- no results yet"
    print studio_results.view_text(home, store, secs, mid_sec.id)

    store = run_and_record(home, store, pinned_session("doc-1", scratch, 1000), secs, src, mid_sec.id)
    store = run_and_record(home, store, pinned_session("doc-1", scratch, 1100), secs, src, mid_sec.id)
    print "-- current"
    print studio_results.view_text(home, store, secs, mid_sec.id)

    edited = studio_sections.refresh(secs, edited_src())
    print "-- after editing the section"
    print studio_results.view_text(home, store, edited, mid_sec.id)

    gone = studio_sections.refresh(secs, removed_src())
    print "-- after removing the section"
    print studio_results.view_text(home, store, gone, mid_sec.id)
  end if
end program
