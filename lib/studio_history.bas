' studio_history — STU-6 semantic action history (headless).
'
' An append-only log of what the user DID, in Studio's own vocabulary: a file was
' opened, a section ran, an error was raised. Not keystrokes and not widget
' events — the point is to answer "where was I?" after a week away, and a
' keystroke log answers nothing.
'
' An event:
'   { seq, at, kind, target, detail }
'     kind    one of `kinds()` — a closed vocabulary, so a reader never has to
'             parse free text to know what happened
'     target  what it happened TO (a path, a section id, a document id)
'     detail  a short string; never a payload, never output
'
' WHY JSON AND NOT SQLITE. The plan allows either, with a capped JSON log as the
' documented fallback. gBASIC cannot probe for an optional module: `load sqlite`
' raises when the interpreter was built without it, and a raise is not catchable
' (docs/ai/UNLEARN.md), so "use SQLite when available" cannot be written without
' the availability check being itself fatal on the machines it is meant to
' protect. A bounded JSON log meets the requirement the store actually has — stay
' bounded — so that is what this is, and the choice is a limitation of the
' language rather than a preference.
'
' BOUNDEDNESS is the part that is not optional. A log that grows forever would
' make every save slower until Studio became unusable, and it would do so
' silently. Detail is kept for the newest `window()` events; everything older is
' COMPACTED into one rollup per kind — count, first and last time — which is
' still a true statement about what happened, just a coarser one.
library studio_history


    ' Dependencies, declared rather than assumed.
    load persist

    function schema_version()
        return 1
    end function

    ' How many events keep their full detail. 300 is several sessions' worth of
    ' real activity and a few tens of KB — small enough to rewrite on every save
    ' without anyone noticing.
    function window()
        return 300
    end function

    ' The closed vocabulary. A kind outside this list is a programming error, not
    ' a user event, and `record` says so rather than writing it and leaving a
    ' reader to discover it later.
    function kinds()
        return ["project_opened", "project_created", "folder_opened",
                "file_opened", "file_closed", "file_created", "file_saved",
                "file_renamed", "file_deleted", "folder_created",
                "section_selected", "section_executed", "run_stopped",
                "run_failed", "error_raised",
                ' STU-10: what the AGENT did, kept in the same log and the same
                ' closed vocabulary as what the user did. One log, because "who
                ' changed this" is a question about a single sequence of events,
                ' and two logs interleaved after the fact is a reconstruction
                ' rather than a record.
                "agent_action"]
    end function

    function is_kind(kind)
        return contains(studio_history.kinds(), kind)
    end function

    function path(home)
        return home + "/history.json"
    end function

    function _empty(status)
        return {
            schema_version: studio_history.schema_version(),
            next_seq: 1,
            events: [],
            rollups: [],
            status: status
        }
    end function

    ' Load the log. Missing is empty, corrupt is empty-and-flagged, a future
    ' version is empty-and-flagged — the same three-way policy every other store
    ' in Studio uses, because a history that refuses to open would take the whole
    ' window down with it for something that is only ever advisory.
    function open(home)
        st = persist.read_status(studio_history.path(home))
        if st.status = "missing" then
            return studio_history._empty("empty")
        end if
        if st.status = "corrupt" then
            return studio_history._empty("corrupt")
        end if
        raw = st.value
        v = 0
        if has(raw, "schema_version") then
            v = raw.schema_version
        end if
        if v > studio_history.schema_version() then
            return studio_history._empty("future")
        end if
        log = studio_history._empty("loaded")
        if has(raw, "next_seq") then
            log.next_seq = raw.next_seq
        end if
        if has(raw, "events") then
            log.events = raw.events
        end if
        if has(raw, "rollups") then
            log.rollups = raw.rollups
        end if
        return log
    end function

    function save(home, log)
        persist.ensure_dir(home)
        out = {
            schema_version: studio_history.schema_version(),
            next_seq: log.next_seq,
            events: log.events,
            rollups: log.rollups
        }
        persist.write_atomic(studio_history.path(home), out)
        return log
    end function

    ' Append one event, newest LAST, then compact if the window has been exceeded.
    ' `at` is passed in rather than read from the clock so a test can pin it, the
    ' same seam every other timestamped thing in Studio uses.
    ' Named `note` rather than `record`: `record` is a gBASIC builtin, and a
    ' library function sharing a builtin's name makes every unqualified call
    ' resolve to the builtin instead — with a warning, but silently wrong if the
    ' warning is missed.
    function note(log, kind, target, detail, at)
        known = studio_history.is_kind(kind)
        if not known then
            error "studio_history.note: unknown event kind '" + kind + "'"
        end if
        log.events = append(log.events, {
            seq: log.next_seq,
            at: at,
            kind: kind,
            target: target,
            detail: detail
        })
        log.next_seq = log.next_seq + 1
        return studio_history.compact(log)
    end function

    ' Fold everything past the window into per-kind rollups. Rollups accumulate
    ' rather than being recomputed, so compaction is O(what it removes) and the
    ' log never has to hold the detail it just discarded.
    function compact(log)
        n = count(log.events)
        w = studio_history.window()
        if n <= w then
            return log
        end if
        drop = n - w
        kept = []
        i = 0
        for each e in log.events
            if i < drop then
                log.rollups = studio_history._roll(log.rollups, e)
            else
                kept = append(kept, e)
            end if
            i = i + 1
        end for
        log.events = kept
        return log
    end function

    function _roll(rollups, e)
        out = []
        found = false
        for each r in rollups
            if r.kind = e.kind then
                r.count = r.count + 1
                if e.at < r.first_at then
                    r.first_at = e.at
                end if
                if e.at > r.last_at then
                    r.last_at = e.at
                end if
                found = true
            end if
            out = append(out, r)
        end for
        if not found then
            out = append(out, { kind: e.kind, count: 1, first_at: e.at, last_at: e.at })
        end if
        return out
    end function

    ' ---- reading -----------------------------------------------------------

    ' The newest `n` events, newest FIRST — the order a reader wants and the
    ' opposite of the order they are stored in.
    function recent(log, n)
        out = []
        i = count(log.events) - 1
        while i >= 0
            if count(out) >= n then
                return out
            end if
            out = append(out, log.events[i])
            i = i - 1
        end while
        return out
    end function

    ' The newest event of a given kind, or nothing.
    function last_of(log, kind)
        i = count(log.events) - 1
        while i >= 0
            e = log.events[i]
            if e.kind = kind then
                return e
            end if
            i = i - 1
        end while
        return nothing
    end function

    ' The reconstruction "where was I?" is built from: the last file opened, the
    ' last section selected, the last section run, the last error, and the last
    ' save. Returned as data so the agent's prompt and the headless goldens are
    ' the same thing rendered twice.
    function orientation(log)
        return {
            last_file: studio_history.last_of(log, "file_opened"),
            last_section: studio_history.last_of(log, "section_selected"),
            last_run: studio_history.last_of(log, "section_executed"),
            last_error: studio_history.last_of(log, "error_raised"),
            last_save: studio_history.last_of(log, "file_saved"),
            events: count(log.events),
            compacted: studio_history.rolled_total(log)
        }
    end function

    function rolled_total(log)
        n = 0
        for each r in log.rollups
            n = n + r.count
        end for
        return n
    end function

    ' A deterministic, path-free rendering for the goldens and for the agent's
    ' context. Targets are reduced to their last path segment.
    function summary(log)
        lines = []
        lines = append(lines, "history: " + count(log.events) + " kept, " + studio_history.rolled_total(log) + " compacted, next_seq=" + log.next_seq)
        for each r in log.rollups
            lines = append(lines, "  rollup " + r.kind + " x" + r.count + " " + r.first_at + ".." + r.last_at)
        end for
        for each e in log.events
            lines = append(lines, "  " + e.seq + " " + e.at + " " + e.kind + " " + studio_history._leaf(e.target) + " " + e.detail)
        end for
        return join(lines, "\n")
    end function

    function _leaf(target)
        if target = "" then
            return "-"
        end if
        parts = split(target, "/")
        return parts[count(parts) - 1]
    end function

end library
