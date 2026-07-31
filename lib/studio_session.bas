' studio_session — STU-4 execution sessions (headless).
'
' Runs an execution section by REPLAY: running section N means executing sections
' 1..N in a fresh child interpreter. R2 (docs/gbasic_studio_r2.md) established that
' this is the only model the runtime supports -- there is no reusable evaluation
' context, and Studio (being gBASIC) could not reach one if there were.
'
' Studio owns the session; the platform owns the child. The child is driven with
' PLAT-PROC's non-blocking primitives (process.start/poll/read/stop/release)
' directly from a GTK timeout callback -- no actor, no mailbox (R2 amendment
' 2026-07-27).
'
' A session belongs to ONE document and permits at most one active run. Sessions
' hold no shared mutable state, so different documents run concurrently for free.
'
' STATE MACHINE (every state explicit; no boolean soup):
'   idle          nothing has run yet, or the last run was cleared
'   materializing writing the prefix file
'   running       child launched, being polled
'   stopping      SIGTERM sent, waiting for the child to go
'   unresponsive  SIGTERM sent, the grace window elapsed, child still alive
'   finished      the child exited (of its own accord or after a stop)
'   failed        the run could not proceed (materialize or launch error)
'   refused       Studio declined to start (see can_run)
'
' TRANSITIONS (all named, all tested):
'   idle|finished|failed|refused -> materializing   run requested and permitted
'   idle|finished|failed|refused -> refused         run requested and refused
'   materializing -> running                        child launched
'   materializing -> failed                         write or launch error
'   running -> running                              tick with the child alive
'   running -> finished                             child exited
'   running -> stopping                             stop requested
'   stopping -> finished                            child died
'   stopping -> unresponsive                        grace elapsed, still alive
'   unresponsive -> finished                        force stop killed it
'   running|stopping|unresponsive -> ... -> materializing   restart, after the stop
'
' See docs/gbasic_studio_stu4.md.

library studio_session


    ' Dependencies, declared rather than assumed. A library that calls into
    ' another must load it: relying on the caller to have done so turns a
    ' missing load into a runtime failure deep inside a call, and it stops
    ' working entirely once these libraries live in separate projects.
    load studio_results
    load studio_sections
    load persist
    function schema_version()
        return 1
    end function

    ' ---- state helpers -----------------------------------------------------

    ' Record a transition and move. Every state change goes through here, so the
    ' transition log in the goldens is the machine's actual history, not a
    ' reconstruction.
    function _to(session, next_state)
        if session.state != next_state then
            session.transitions = append(session.transitions, session.state + ">" + next_state)
        end if
        session.state = next_state
        return session
    end function

    function is_active(session)
        if session.state = "materializing" then
            return true
        end if
        if session.state = "running" then
            return true
        end if
        if session.state = "stopping" then
            return true
        end if
        if session.state = "unresponsive" then
            return true
        end if
        return false
    end function

    ' ---- construction ------------------------------------------------------

    ' Which gBASIC to run a section with. Studio is a gBASIC program but is not
    ' the gBASIC project, so there is no interpreter beside it to assume: the
    ' path comes from the GBASIC environment variable, falling back to whatever
    ' `gbasic` resolves to on PATH (an installed one). A caller that needs a
    ' specific build sets session.interpreter directly, as the tests do.
    function default_interpreter()
        v = env("GBASIC")
        if is_string(v) then
            if v != "" then
                return v
            end if
        end if
        return "gbasic"
    end function

    function create(doc_id, scratch_dir)
        return {
            schema_version: 1,
            doc_id: doc_id,
            scratch_dir: scratch_dir,
            interpreter: studio_session.default_interpreter(),
            state: "idle",
            transitions: [],
            run_seq: 0,
            section_id: "",
            section_index: -1,
            prefix_path: "",
            prefix_bytes: 0,
            appended: "",
            handle: nothing,
            reason: "",
            message: "",
            out_raw: "",
            out_prefix: "",
            out_target: "",
            err_prefix: "",
            err_target: "",
            ' Separation is PER STREAM (STU-4B). stdout can carry the boundary
            ' marker; stderr cannot, so the two are never reported as one verdict.
            '   split_out: none | exact | pending | marked | combined
            '   split_err: none | exact | unavailable
            split_out: "none",
            split_err: "none",
            split_reason: "",
            marker: "",
            ' Test seam: a fixed nonce, so a fixture can print the marker itself.
            nonce_fixed: "",
            ' STU-5A timing. The runtime's clock is whole seconds (`epoch()`), so a
            ' run shorter than a second records a duration of 0 -- reported as it is
            ' rather than dressed up with a millisecond figure the platform cannot
            ' actually measure. `clock_fixed` is the test seam that keeps goldens
            ' byte-stable while a real run still happens.
            clock_fixed: 0,
            started_epoch: 0,
            finished_epoch: 0,
            map: nothing,
            hoisted: [],
            stderr_raw: "",
            diagnostics: [],
            attribution: [],
            exit_code: -1,
            signal: 0,
            success: false,
            pending: nothing,
            ' How many ticks a bare stop waits before the session reports the child
            ' as `unresponsive`. At the shell's 50ms cadence, 20 ticks is ~1s: long
            ' enough for a well-behaved child to run its SIGTERM handler and exit,
            ' short enough that the user learns quickly that force is needed.
            stop_ticks: 0,
            stop_grace_ticks: 20
        }
    end function

    ' Wall-clock seconds, or the pinned value when a test has fixed the clock.
    function _now(session)
        if session.clock_fixed != 0 then
            return session.clock_fixed
        end if
        return epoch()
    end function

    ' ---- refusal -----------------------------------------------------------

    ' Whether `section_id` may be run against this section state. Refusal reasons
    ' are CODES the UI can map to its own wording; `message` is the fallback text.
    '
    ' Last-known-good sections exist so the UI stays coherent while the user is
    ' mid-edit -- NOT so stale code can be executed. Running against source that no
    ' longer parses would execute a file whose bytes do not match the sections
    ' Studio is reasoning about, so it is refused outright.
    function can_run(sections, section_id)
        if not sections.valid then
            return { ok: false, reason: "source-invalid",
                     message: "the document does not parse; fix the errors first" }
        end if
        for each sid in sections.stale_ids
            if sid = section_id then
                return { ok: false, reason: "section-stale",
                         message: "that section no longer exists in the current source" }
            end if
        end for
        found = nothing
        for each s in sections.sections
            if s.id = section_id then
                found = s
            end if
        end for
        if found = nothing then
            return { ok: false, reason: "section-missing",
                     message: "no such section in the current source" }
        end if
        if found.status = "ambiguous" then
            return { ok: false, reason: "section-ambiguous",
                     message: "that section is ambiguous after the last edit; disambiguate it first" }
        end if
        if found.status = "stale" then
            return { ok: false, reason: "section-stale",
                     message: "that section no longer exists in the current source" }
        end if
        return { ok: true, reason: "", message: "" }
    end function

    ' ---- prefix materialization -------------------------------------------

    ' The largest whole-codepoint prefix of `text` that is at most `nbytes` long.
    ' Binary search over `mid` (which counts CODEPOINTS) using byte_count as the
    ' oracle: O(log n) C-level slices rather than an interpreted per-byte loop, which
    ' would be O(n^2) because `append` copies the array every call. Section offsets
    ' always land on codepoint boundaries, so the result is exact.
    function _byte_prefix(text, nbytes)
        lo = 0
        hi = len(text)
        while lo < hi
            probe = floor((lo + hi + 1) / 2)
            if byte_count(mid(text, 0, probe)) <= nbytes then
                lo = probe
            else
                hi = probe - 1
            end if
        end while
        return mid(text, 0, lo)
    end function

    ' source[start_off, end_off) as text. Two binary searches; see _byte_prefix.
    function _byte_slice(source, start_off, end_off)
        full = studio_session._byte_prefix(source, end_off)
        head = studio_session._byte_prefix(full, start_off)
        return mid(full, len(head), len(full) - len(head))
    end function

    ' Complete lines in `text` -- i.e. its newline count. `split` is a C builtin, so
    ' this is one pass rather than an interpreted per-byte loop.
    function _line_count(text)
        nl = "\n"
        return count(split(text, nl)) - 1
    end function

    ' Byte offset of the start of the line containing `off`. Nothing but whitespace
    ' can precede a section's first token on its line -- gBASIC has no statement
    ' separator (STU-4B Step 0), so no earlier statement can share it, and a comment
    ' runs to end of line -- which is what makes inserting a whole line here
    ' column-preserving.
    function _line_start(source, off)
        i = off
        while i > 0
            if byte_at(source, i - 1) = 10 then
                return i
            end if
            i = i - 1
        end while
        return 0
    end function

    ' A per-run boundary marker. NOT a fixed sentinel: a user program can print
    ' anything, and a fixed string would be forgeable by accident. Digits and
    ' hyphens only, so it is safe inside the generated string literal.
    function _nonce(session)
        if session.nonce_fixed != "" then
            return session.nonce_fixed
        end if
        a = floor(random() * 1000000000)
        b = floor(random() * 1000000000)
        return "@@gbstudio-" + epoch() + "-" + session.run_seq + "-" + a + "-" + b + "@@"
    end function

    ' Declarations whose meaning does not depend on where in the file they sit --
    ' see the hoisting rule in materialize_text.
    function _hoistable_kind(kind)
        if kind = "function" then
            return true
        end if
        if kind = "modifier" then
            return true
        end if
        if kind = "library" then
            return true
        end if
        return false
    end function

    ' The source text to execute for a run of `section`, plus the position map that
    ' translates a line of it back to a line of the document.
    '
    ' The body is the literal BYTE PREFIX of the document, source[0,
    ' section.end_offset) -- never a stitched-together subset -- so a line of the
    ' prefix keeps its document line number and --json-diagnostics positions map
    ' straight back through STU-3's ranges. Exactly three things are added, each
    ' recorded in the map:
    '
    '   1. END APPENDS (STU-4). A trailing newline, because section ranges are
    '      newline-exclusive; and `end program` when the target lives inside a
    '      `program` block, because a byte prefix cuts the block open. Neither
    '      shifts a line before it.
    '
    '   2. HOISTED DECLARATIONS (STU-4B). Top-level `function`/`modifier`/`library`
    '      declarations that sit wholly AFTER the prefix, appended at the end in
    '      source order. Appending shifts nothing before it.
    '
    '      Hoisting happens only when the prefix contains a program block that will
    '      execute, because that is the exact condition under which the interpreter
    '      itself registers top-level functions and modifiers up front regardless of
    '      file position (src/eval.c, eval_program) and resolves `library` from the
    '      whole root. Under that condition hoisting REPRODUCES the document's
    '      semantics rather than changing them -- and nothing else can be reordered,
    '      because when a program block is present it is the only thing that runs
    '      (top-level statements outside it never execute at all). Without a program
    '      block in the prefix, top-level statements run in order and a declaration
    '      below the target is invisible to it in the real document too, so hoisting
    '      it would MANUFACTURE behaviour the document does not have. Nothing is
    '      hoisted in that case.
    '
    '   3. A BOUNDARY MARKER (STU-4B), when `nonce` is non-empty: one whole line
    '      `print "<nonce>"` inserted at the start of the line beginning section N,
    '      so replayed output can be told from the target's. gBASIC has no statement
    '      separator (Step 0), so a zero-line-shift marker is impossible; this is the
    '      single-injection fallback, and the map carries its single -1 offset.
    function materialize_text(source, section, sections, nonce)
        prefix_end = section.end_offset

        ' Will the prefix execute a program block? Any section with `program:`
        ' ancestry starting before the prefix end means the block opens inside it.
        prog_in_prefix = false
        for each s in sections.sections
            if left(s.anchor.ancestry, 8) = "program:" then
                if s.start_offset < prefix_end then
                    prog_in_prefix = true
                end if
            end if
        end for

        marker_line = 0
        if nonce != "" then
            ls = studio_session._line_start(source, section.start_offset)
            head = studio_session._byte_prefix(source, ls)
            tail = studio_session._byte_slice(source, ls, prefix_end)
            marker_line = studio_session._line_count(head) + 1
            body = head + "print \"" + nonce + "\"\n" + tail
        else
            body = studio_session._byte_prefix(source, prefix_end)
        end if

        appended = ""
        n = byte_count(body)
        if n > 0 then
            if byte_at(body, n - 1) != 10 then
                body = body + "\n"
                appended = "newline"
            end if
        end if

        ' Every line of the prefix is accounted for before anything generated is
        ' appended, so the map's document segments are fixed at this point.
        prefix_lines = studio_session._line_count(body)
        segs = []
        if marker_line > 0 then
            if marker_line > 1 then
                segs = append(segs, { kind: "document", c_start: 1, c_end: marker_line - 1, delta: 0 })
            end if
            segs = append(segs, { kind: "marker", c_start: marker_line, c_end: marker_line, delta: 0 })
            if prefix_lines > marker_line then
                segs = append(segs, { kind: "document", c_start: marker_line + 1, c_end: prefix_lines, delta: -1 })
            end if
        else
            if prefix_lines > 0 then
                segs = append(segs, { kind: "document", c_start: 1, c_end: prefix_lines, delta: 0 })
            end if
        end if

        anc = section.anchor.ancestry
        if left(anc, 8) = "program:" then
            body = body + "end program\n"
            if appended = "" then
                appended = "end-program"
            else
                appended = appended + "+end-program"
            end if
        end if
        gen_lines = studio_session._line_count(body)
        if gen_lines > prefix_lines then
            segs = append(segs, { kind: "generated", c_start: prefix_lines + 1, c_end: gen_lines, delta: 0 })
        end if

        hoisted = []
        if prog_in_prefix then
            for each s in sections.sections
                keep = false
                if s.anchor.ancestry = "top" then
                    if s.start_offset >= prefix_end then
                        if studio_session._hoistable_kind(s.kind) then
                            keep = true
                        end if
                    end if
                end if
                if keep then
                    child_start = studio_session._line_count(body) + 1
                    body = body + studio_session._byte_slice(source, s.start_offset, s.end_offset)
                    if byte_at(body, byte_count(body) - 1) != 10 then
                        body = body + "\n"
                    end if
                    child_end = studio_session._line_count(body)
                    nm = ""
                    if s.name != nothing then
                        nm = s.name
                    end if
                    hoisted = append(hoisted, {
                        kind: s.kind,
                        name: nm,
                        doc_start_line: s.start_line,
                        child_start_line: child_start,
                        lines: child_end - child_start + 1
                    })
                    segs = append(segs, {
                        kind: "hoisted",
                        c_start: child_start,
                        c_end: child_end,
                        delta: s.start_line - child_start
                    })
                    if appended = "" then
                        appended = "hoist"
                    else
                        if find(appended, "hoist") = nothing then
                            appended = appended + "+hoist"
                        end if
                    end if
                end if
            end for
        end if

        return {
            text: body,
            appended: appended,
            hoisted: hoisted,
            map: { schema_version: 1, marker_line: marker_line, segments: segs }
        }
    end function

    ' Translate a 1-based line of the MATERIALIZED file to a 1-based line of the
    ' DOCUMENT. Exact, not inferential: every segment was recorded while Studio
    ' generated the very content it describes.
    '
    '   kind = "document"   a prefix line; `line` is its document line
    '   kind = "hoisted"    a hoisted declaration's line; `line` is where that
    '                       declaration really lives in the document
    '   kind = "marker"     the injected boundary line; no document counterpart
    '   kind = "generated"  an appended `end program`; no document counterpart
    '   kind = "unmapped"   past the end of what Studio generated (a diagnostic can
    '                       name a line that does not exist). No shift is known to
    '                       apply, so the line is passed through unchanged.
    function map_line(map, child_line)
        if map = nothing then
            return { kind: "unmapped", line: child_line }
        end if
        for each s in map.segments
            if child_line >= s.c_start then
                if child_line <= s.c_end then
                    if s.kind = "marker" then
                        return { kind: "marker", line: 0 }
                    end if
                    if s.kind = "generated" then
                        return { kind: "generated", line: 0 }
                    end if
                    return { kind: s.kind, line: child_line + s.delta }
                end if
            end if
        end for
        return { kind: "unmapped", line: child_line }
    end function

    function _prefix_path(session)
        return session.scratch_dir + "/run-" + session.doc_id + "-" + session.run_seq + ".bas"
    end function

    ' ---- running -----------------------------------------------------------

    ' Start a run of `section_id`. Refusal is checked FIRST, so a refused run never
    ' touches the filesystem. Returns the updated session; inspect `.state`.
    function run(session, sections, source, section_id)
        if studio_session.is_active(session) then
            session.reason = "already-running"
            session.message = "a run is already in progress for this document"
            return session
        end if

        ' Stamp the clock before the gate: a refusal is a thing that happened at a
        ' time, and STU-5A records it as one.
        now = studio_session._now(session)
        session.started_epoch = now
        session.finished_epoch = now

        gate = studio_session.can_run(sections, section_id)
        if not gate.ok then
            session = studio_session._to(session, "refused")
            session.section_id = section_id
            session.reason = gate.reason
            session.message = gate.message
            return session
        end if

        ' Reset per-run results before the new run so nothing leaks across.
        session.reason = ""
        session.message = ""
        session.out_raw = ""
        session.out_prefix = ""
        session.out_target = ""
        session.err_prefix = ""
        session.err_target = ""
        session.split_reason = ""
        session.marker = ""
        session.map = nothing
        session.hoisted = []
        session.stderr_raw = ""
        session.diagnostics = []
        session.attribution = []
        session.exit_code = -1
        session.signal = 0
        session.success = false
        session.section_id = section_id
        session.run_seq = session.run_seq + 1

        idx = -1
        i = 0
        target = nothing
        for each s in sections.sections
            if s.id = section_id then
                idx = i
                target = s
            end if
            i = i + 1
        end for
        session.section_index = idx
        ' Section 1 has no prefix, so its output is unambiguously its own and needs
        ' no marker. Any later section shares one stdout stream with the sections
        ' replayed before it, and a boundary marker is injected to tell them apart;
        ' whether that succeeded is not known until the stream has been seen, so the
        ' verdict stays `pending` until the run ends. stderr carries no marker at
        ' all, so it is `unavailable` from the start rather than optimistically
        ' claimed and later withdrawn.
        if idx = 0 then
            session.split_out = "exact"
            session.split_err = "exact"
        else
            session.split_out = "pending"
            session.split_err = "unavailable"
            session.marker = studio_session._nonce(session)
        end if

        session = studio_session._to(session, "materializing")

        m = studio_session.materialize_text(source, target, sections, session.marker)
        session.appended = m.appended
        session.map = m.map
        session.hoisted = m.hoisted
        session.prefix_bytes = byte_count(m.text)
        persist.ensure_dir(session.scratch_dir)
        path = studio_session._prefix_path(session)
        persist.write_text_atomic(path, m.text)
        session.prefix_path = path

        pf(file) = path
        if not exists(pf) then
            session = studio_session._to(session, "failed")
            session.reason = "materialize-failed"
            session.message = "could not write the execution prefix"
            session.finished_epoch = studio_session._now(session)
            return session
        end if

        ' --line-buffered (PLAT-STREAM) so a completed `print` reaches us while the
        ' child is still running: stdout is a pipe here, and stdio would otherwise
        ' block-buffer it and hand us nothing until exit -- leaving the tick loop
        ' below polling an empty pipe and losing everything still buffered if the
        ' user stops the run.
        session.handle = process.start({
            command: session.interpreter,
            args: ["--line-buffered", "--json-diagnostics", path]
        })
        session = studio_session._to(session, "running")
        return session
    end function

    ' ---- ticking -----------------------------------------------------------

    ' One non-blocking service of the child: drain whatever it has produced, learn
    ' whether it is still alive, and advance the state machine. Safe to call in any
    ' state; a no-op when no child is live. This is what the GTK timeout drives.
    function tick(session)
        if session.handle = nothing then
            return session
        end if
        if not studio_session.is_active(session) then
            return session
        end if

        c = process.read(session.handle)
        session = studio_session._absorb(session, c.stdout, c.stderr)

        s = process.poll(session.handle)
        if s.running then
            if session.state = "stopping" then
                session.stop_ticks = session.stop_ticks + 1
                if session.stop_ticks >= session.stop_grace_ticks then
                    session = studio_session._to(session, "unresponsive")
                end if
            end if
            return session
        end if

        ' The child is gone: take a final read so no tail output is lost, record the
        ' outcome, attribute the diagnostics, and release the handle.
        c = process.read(session.handle)
        session = studio_session._absorb(session, c.stdout, c.stderr)
        session.exit_code = s.exit_code
        session.signal = s.signal
        session.success = s.success
        session.finished_epoch = studio_session._now(session)
        process.release(session.handle)
        session.handle = nothing
        session = studio_session._resolve_split(session)
        session = studio_session._to(session, "finished")
        session = studio_session.cleanup_prefix(session)
        return session
    end function

    ' Accumulate freshly-read bytes verbatim. Splitting happens once, when the run
    ' ends -- a marker that has not arrived yet is not the same as one that never
    ' will, and only a complete stream can tell those apart. `out_raw` is what the UI
    ' shows live.
    function _absorb(session, out_chunk, err_chunk)
        session.out_raw = session.out_raw + out_chunk
        session.stderr_raw = session.stderr_raw + err_chunk
        return session
    end function

    ' Decide the stdout split from the finished stream.
    '
    '   exact     the target is section 1: no prefix exists, so all output is its own
    '   marked    the boundary marker appeared EXACTLY once; the stream splits there
    '   combined  it appeared zero times or more than once
    '
    ' Zero occurrences is the correct answer, not an error, when the child died
    ' inside the prefix or the marker sat where it could never execute. Two or more
    ' means a user program printed the nonce itself: there is then no way to tell
    ' which occurrence is the boundary, so the run does NOT guess -- it reports
    ' combined and says why (the STU-3 ambiguity principle). Nothing is discarded in
    ' any case, and nothing that might be the prefix's is shown as the target's.
    function _resolve_split(session)
        if session.split_out = "exact" then
            session.out_target = session.out_raw
            session.out_prefix = ""
            return session
        end if
        if session.marker = "" then
            session.split_out = "combined"
            session.split_reason = "no-marker"
            session.out_prefix = session.out_raw
            session.out_target = ""
            return session
        end if
        parts = split(session.out_raw, session.marker)
        occurrences = count(parts) - 1
        if occurrences = 1 then
            session.split_out = "marked"
            session.split_reason = ""
            session.out_prefix = parts[0]
            rest = parts[1]
            ' The marker statement printed nonce + newline; drop that newline so the
            ' target's output does not start with a blank line.
            if byte_count(rest) > 0 then
                if byte_at(rest, 0) = 10 then
                    rest = mid(rest, 1, len(rest) - 1)
                end if
            end if
            session.out_target = rest
            return session
        end if
        session.split_out = "combined"
        session.out_prefix = session.out_raw
        session.out_target = ""
        if occurrences = 0 then
            session.split_reason = "marker-absent"
        else
            ' Both occurrences stay in the displayed text: exactly one of them is
            ' ours, and stripping the wrong one would delete the user's output.
            session.split_reason = "marker-ambiguous"
        end if
        return session
    end function

    ' ---- stopping ----------------------------------------------------------

    ' Bare stop: SIGTERM and nothing else. A child that ignores it stays alive and
    ' the session moves to `unresponsive` after the grace window -- surfaced as a
    ' distinct state rather than as a hang. Escalation is a separate user action.
    '
    ' Named `request_stop` rather than `stop` because `stop` is a gBASIC keyword
    ' (the STOP statement) and cannot be a function name.
    function request_stop(session)
        if not studio_session.is_active(session) then
            return session
        end if
        if session.handle = nothing then
            return session
        end if
        session.stop_ticks = 0
        session = studio_session._to(session, "stopping")
        process.stop(session.handle)
        return studio_session.tick(session)
    end function

    ' Force stop: the explicit escalation. SIGTERM, a bounded grace, then SIGKILL.
    function force_stop(session, grace_seconds)
        if not studio_session.is_active(session) then
            return session
        end if
        if session.handle = nothing then
            return session
        end if
        ' Escalating from `unresponsive` goes straight to `finished`; re-announcing
        ' `stopping` would only add a transition the machine does not really make.
        if session.state = "running" then
            session = studio_session._to(session, "stopping")
        end if
        s = process.stop(session.handle, { force_after: grace_seconds })
        c = process.read(session.handle)
        session = studio_session._absorb(session, c.stdout, c.stderr)
        session.exit_code = s.exit_code
        session.signal = s.signal
        session.success = s.success
        session.finished_epoch = studio_session._now(session)
        process.release(session.handle)
        session.handle = nothing
        session = studio_session._resolve_split(session)
        session = studio_session._to(session, "finished")
        return studio_session.cleanup_prefix(session)
    end function

    ' ---- restart -----------------------------------------------------------

    ' Stop-then-run, with the stop completed FIRST so two runs of one session can
    ' never overlap. A restart requested mid-run records the intent, force-stops the
    ' current child (bounded, so a SIGTERM-ignoring child cannot wedge the restart),
    ' and only then starts the new run.
    function restart(session, sections, source, section_id, grace_seconds)
        if studio_session.is_active(session) then
            session.pending = { kind: "restart", section_id: section_id }
            session = studio_session.force_stop(session, grace_seconds)
        end if
        session.pending = nothing
        return studio_session.run(session, sections, source, section_id)
    end function

    ' ---- diagnostics & attribution ----------------------------------------

    ' Split the child's stderr into structured diagnostics and plain text. With
    ' --json-diagnostics each diagnostic is one JSON object per line, but the child's
    ' OWN stderr writes are interleaved there too, so every line is validated before
    ' decoding (`decode` raises, and a raise cannot be caught from a library).
    function parse_diagnostics(session)
        diags = []
        plain = []
        for each line in split(session.stderr_raw, "\n")
            if line = "" then
                continue
            end if
            ' One pass through the platform parser. This used to pre-validate
            ' with a pure-gBASIC scanner and then `decode`, because `decode`
            ' raises and gBASIC cannot catch a raise; `try_decode` reports
            ' failure as a value, so the pre-pass has no reason to exist. A
            ' child's stderr line that is not JSON at all is the normal case
            ' here, not an error, and lands in `plain` exactly as before.
            r = try_decode(line)
            handled = false
            if r.ok then
                d = r.value
                if is_record(d) then
                    if has(d, "severity") then
                        if has(d, "start") then
                            diags = append(diags, d)
                            handled = true
                        end if
                    end if
                end if
            end if
            if not handled then
                plain = append(plain, line)
            end if
        end for
        session.diagnostics = diags
        ' stderr carries no boundary marker -- the marker is a `print`, so it lands
        ' on stdout only. stderr is therefore separable ONLY when the target is
        ' section 1 and there is no prefix to separate from. Everything else goes to
        ' the prefix bucket, and split_err says "unavailable" rather than letting the
        ' UI infer that stderr was separated because stdout was.
        if session.split_err = "exact" then
            session.err_target = join(plain, "\n")
        else
            session.err_prefix = join(plain, "\n")
        end if
        return session
    end function

    ' Map each diagnostic's position back to the DOCUMENT and classify where it
    ' landed. The child reports positions in the materialized file, which is no
    ' longer line-for-line identical to the document once a marker is injected or a
    ' declaration is hoisted -- so every position goes through the position map
    ' first, and only then through STU-3's byte ranges. Columns never move: both
    ' injections are whole-line operations.
    '
    '   where = "target"     the error is in the section the user asked to run
    '   where = "prefix"     the error is in replayed context -- an earlier section,
    '                        or a hoisted declaration, which is context too
    '   where = "outside"    a real document position in no section (a gap between
    '                        sections, or past the end of the document)
    '   where = "generated"  a line Studio itself generated: the appended
    '                        `end program` or the boundary marker. It has no
    '                        document position, so none is invented -- line and
    '                        column are reported as 0.
    function attribute(session, sections, source)
        out = []
        for each d in session.diagnostics
            child_line = d.start.line
            col = d.start.column
            m = studio_session.map_line(session.map, child_line)
            if m.kind = "marker" or m.kind = "generated" then
                out = append(out, {
                    section_id: nothing,
                    where: "generated",
                    line: 0,
                    column: 0,
                    severity: d.severity,
                    message: d.message
                })
            else
                line = m.line
                off = studio_sections.offset_of(source, line, col)
                sid = studio_sections.section_at(sections, off)
                where = "outside"
                if sid != nothing then
                    if sid = session.section_id then
                        where = "target"
                    else
                        where = "prefix"
                    end if
                end if
                out = append(out, {
                    section_id: sid,
                    where: where,
                    line: line,
                    column: col,
                    severity: d.severity,
                    message: d.message
                })
            end if
        end for
        session.attribution = out
        return session
    end function

    ' Convenience: everything that must happen once a run has finished.
    function finalize(session, sections, source)
        session = studio_session.parse_diagnostics(session)
        return studio_session.attribute(session, sections, source)
    end function

    ' ---- STU-5A: emitting a durable result ---------------------------------

    ' Build the record STU-5A persists. This EMITS what the run already produced;
    ' it changes nothing about how a run happens.
    '
    ' The section FINGERPRINT is captured here, from the sections state the run was
    ' launched against -- not looked up later. Section ids are deliberately stable
    ' across edits (that is STU-3's purpose), so a result keyed by id alone would
    ' silently appear to describe code that has since changed. Recording the
    ' content hash as run is what lets studio_results say "this result predates the
    ' section's current text" instead of showing a stale result as current.
    '
    ' A refusal produces a record too: Studio declining to run is an event, and a
    ' history that quietly omitted it would misrepresent the session.
    function to_result(session, sections)
        found = nothing
        for each s in sections.sections
            if s.id = session.section_id then
                found = s
            end if
        end for
        fp = ""
        kind = ""
        nm = nothing
        if found != nothing then
            fp = studio_results.fingerprint_of(found)
            kind = found.kind
            nm = found.name
        end if

        ' The three terminal states map straight through; anything else means the
        ' caller asked before the run ended, and the state is reported as-is rather
        ' than being coerced into one of the three.
        outcome = session.state

        dur = session.finished_epoch - session.started_epoch
        if dur < 0 then
            dur = 0
        end if

        return {
            result_id: "",
            section_id: session.section_id,
            section_fingerprint: fp,
            section_kind: kind,
            section_name: nm,
            started_epoch: session.started_epoch,
            finished_epoch: session.finished_epoch,
            duration_seconds: dur,
            outcome: outcome,
            exit_code: session.exit_code,
            signal: session.signal,
            success: session.success,
            reason: session.reason,
            message: session.message,
            split_out: session.split_out,
            split_err: session.split_err,
            split_reason: session.split_reason,
            out_prefix: session.out_prefix,
            out_target: session.out_target,
            err_prefix: session.err_prefix,
            err_target: session.err_target,
            truncated: [],
            attribution: session.attribution,
            run_seq: session.run_seq
        }
    end function

    ' ---- scratch lifecycle -------------------------------------------------

    ' Delete this run's materialized prefix. Called when a run finishes; the child
    ' has long since parsed the file, so removing it cannot disturb a live run.
    function cleanup_prefix(session)
        if session.prefix_path = "" then
            return session
        end if
        f(file) = session.prefix_path
        if exists(f) then
            delete(f)
        end if
        session.prefix_path = ""
        return session
    end function

    ' Remove every materialized prefix left in the scratch directory. A Studio that
    ' crashed mid-run leaves its file behind, so this runs at startup: the scratch
    ' directory is Studio-owned and holds nothing worth keeping between launches.
    ' Returns how many files were removed.
    function sweep_scratch(scratch_dir)
        ' `exists` wants a FILE reference even when the path is a directory (same
        ' quirk persist.ensure_dir documents).
        probe(file) = scratch_dir
        if not exists(probe) then
            return 0
        end if
        d(dir) = scratch_dir
        removed = 0
        for each e in list(d)
            if e.type != "folder" then
                f(file) = scratch_dir + "/" + e.name
                if exists(f) then
                    delete(f)
                    removed = removed + 1
                end if
            end if
        end for
        return removed
    end function

    ' ---- summary (tests / minimal UI) --------------------------------------

    function summary(session)
        lines = []
        head = "state=" + session.state + " section=" + session.section_id + " run=" + session.run_seq + " split=out:" + session.split_out + " err:" + session.split_err
        lines = append(lines, head)
        if session.split_reason != "" then
            lines = append(lines, "split_reason=" + session.split_reason)
        end if
        if count(session.hoisted) > 0 then
            lines = append(lines, "hoisted=" + count(session.hoisted))
        end if
        if session.reason != "" then
            lines = append(lines, "reason=" + session.reason + " message=" + session.message)
        end if
        if session.state = "finished" then
            lines = append(lines, "exit_code=" + session.exit_code + " signal=" + session.signal + " success=" + session.success)
        end if
        lines = append(lines, "out_prefix=<" + session.out_prefix + ">")
        lines = append(lines, "out_target=<" + session.out_target + ">")
        for each a in session.attribution
            sid = "-"
            if a.section_id != nothing then
                sid = a.section_id
            end if
            lines = append(lines, "! " + a.where + " section=" + sid + " " + a.line + ":" + a.column + " " + a.message)
        end for
        return join(lines, "\n")
    end function

    function transitions(session)
        return join(session.transitions, " ")
    end function

end library
