' studio_results — STU-5A persistent, section-linked execution results (headless).
'
' A run produces one durable RECORD. This library owns where those records live,
' how many are kept, what happens to output too large to keep, and — the part that
' matters most — how a stored result is compared against the section as it stands
' NOW, so a result is never shown as if it described code that has since changed.
'
' WHY A SEPARATE STORE (not the workspace record)
'   STU-3's anchors live in the workspace record because they are small and
'   bounded. Results are neither: one STU-4 case moves ~155 KB of output in a
'   single run, and history accumulates. Putting them in the workspace record
'   would mean every settings or navigation write rewrote megabytes.
'
' GRANULARITY: one file per DOCUMENT.
'   * Per document rather than per workspace, because a document is the unit of
'     concurrency: STU-4 permits one session per document and several at once.
'     Distinct documents therefore write distinct files, and non-clobbering is
'     structural rather than hoped for — gBASIC has no lock primitive that could
'     make a shared file safe.
'   * Per document rather than per section, because a section's results are only
'     ever wanted in the context of its document; per-section files would multiply
'     small-file overhead and turn "this document's history" into a directory scan.
'
' KEYED BY PATH, not by doc_id.
'   `doc-N` is minted per launch from an open-order counter (studio_docs.open), so
'   it is NOT stable across restarts. STU-3 can key its anchors by doc_id because
'   they are a cache that re-derives correctly on open; a result history is not
'   self-healing, and attaching one document's runs to another would be exactly the
'   silent wrongness this project refuses at every other layer.
'
' FORMAT: a small strict-JSON INDEX plus sidecar capture files.
'
'   <home>/results/<key>.json    the index -- metadata for every result
'   <home>/results/<key>.d/      the captures -- raw bytes, one file per stream
'                                  res-1.out_target, res-1.err_prefix, ...
'
'   MEASURED, and the reason for the split: persist's read path must
'   use `try_decode`, because `decode` raises and gBASIC cannot
'   catch a raise (docs/ai/UNLEARN.md). That validator is pure gBASIC walking one
'   character at a time -- about 2 KB/s. On a store holding two 64 KB captures it
'   took 53 s to validate what the C `decode` builtin then parsed in under a
'   second. Captured output is opaque bytes that JSON gains nothing from holding,
'   so it lives beside the index instead: the index stays a few hundred bytes per
'   result and loads instantly however much output was captured, and a capture is
'   read with a plain `read()` that validates nothing.
'
'   UPDATE (PLAT-JSON, 2026-07-28): the parse-speed half of that argument is gone.
'   persist now reads through the `try_decode` builtin, and a 4.6 MB index
'   with 9 600 records loads in under a second. The sidecar layout is KEPT, on the
'   two grounds that remain and are unaffected: the index is rewritten whole on
'   every save (atomic_replace), so inlining megabytes of capture text would be
'   write amplification on every single run; and captures are read only when
'   displayed, so history browsing touches none of them.
'
'   Crash-safety survives the split by ORDERING: capture files are written first,
'   then the index is swapped in with atomic_replace. A crash in between leaves
'   unreferenced capture files, which the next save sweeps -- never an index
'   pointing at a capture that is not there.
'
' STORE (the index):
'   { schema_version, doc_path, next_result, results: [ <result> ] }  newest FIRST
'   (`status` is added by `open` and is live-only -- never written back)
'
' RESULT (in the index; the four capture TEXTS are not here):
'   { result_id, section_id, section_fingerprint, section_kind, section_name,
'     started_epoch, finished_epoch, duration_seconds,
'     outcome, exit_code, signal, success, reason, message,
'     split_out, split_err, split_reason,
'     captures: { out_prefix, out_target, err_prefix, err_target },  byte counts
'     truncated: [ <capture name> ], attribution: [...], run_seq }
'
' A pre-STU-5A home has no results directory at all, so it loads as an empty store
' with no migration step -- the same additive-by-construction property STU-3's
' `sections` slot has.
'
' Requires persist loaded by the program (JSON is read through the
' persist reads through the try_decode builtin).
library studio_results

    ' Dependencies are declared, not assumed.
    load studio_viewers


    ' Dependencies, declared rather than assumed. A library that calls into
    ' another must load it: relying on the caller to have done so turns a
    ' missing load into a runtime failure deep inside a call, and it stops
    ' working entirely once these libraries live in separate projects.
    load persist
    ' 3 (STU-5): a sixth capture, `vars_before` — the scope as it stood before the
    ' target section ran, so the pane can show what the section CHANGED.
    ' 2 (STU-4C): results carry a fifth capture, `vars` — the variable scope the
    ' target section left behind. A version-1 store still loads: its results
    ' simply have no `vars` capture, and every reader treats an absent capture as
    ' zero bytes rather than as a missing field.
    function schema_version()
        return 3
    end function

    ' ---- policy ------------------------------------------------------------

    ' RETENTION. Per section, not per document: a user churning one section must
    ' not evict the history of another they have not touched. 20 is deep enough to
    ' cover an editing session's worth of attempts and shallow enough that the
    ' worst case stays bounded without a background collector.
    function retain_per_section()
        return 20
    end function

    ' SIZE CAP, per capture (the four output streams plus `vars`/`vars_before`).
    ' 64 KB is one pipe buffer's worth — comfortably more than any output a human
    ' reads in a results pane, and small enough that the hard ceiling
    ' (20 results x 6 captures x 64 KB) stays under 8 MB per document. A variable
    ' capture is one bounded descriptor per variable, so 64 KB is a lot of them —
    ' and the sampling in studio_session's epilogue is what keeps a single huge
    ' value from filling it.
    function capture_cap()
        return 65536
    end function

    ' Appended to any capture that was cut. The record also carries the capture's
    ' name in `truncated`, but the notice goes in the TEXT as well: a reader that
    ' ignored the field must still be unable to mistake a truncated capture for a
    ' complete one. A truncated capture presented as whole is the same class of
    ' error as a fabricated boundary.
    function truncation_notice()
        return "[studio: output truncated at " + studio_results.capture_cap() + " bytes]"
    end function

    ' ---- paths -------------------------------------------------------------

    function results_dir(home)
        return home + "/results"
    end function

    ' A filesystem-safe, deterministic, collision-resistant key for a document
    ' path: a readable tail (so a directory listing is meaningful to a human) plus
    ' a rolling hash of the WHOLE path (so two files sharing a basename in
    ' different directories never collide). Pure gBASIC on purpose — `sha256` is
    ' behind HAVE_LIBCRYPTO, and results must not stop working where crypto is
    ' compiled out.
    function _key(doc_path)
        m = 1000000007
        h = 0
        i = 0
        n = byte_count(doc_path)
        while i < n
            h = h - floor(h / m) * m
            h = h * 131 + byte_at(doc_path, i) + 1
            i = i + 1
        end while
        h = h - floor(h / m) * m

        safe = ""
        i = 0
        while i < n
            b = byte_at(doc_path, i)
            ok = false
            if b >= 48 and b <= 57 then
                ok = true
            end if
            if b >= 65 and b <= 90 then
                ok = true
            end if
            if b >= 97 and b <= 122 then
                ok = true
            end if
            if ok then
                safe = safe + chr(b)
            else
                safe = safe + "-"
            end if
            i = i + 1
        end while
        ' Keep the tail: the distinguishing part of a path is its end, not its root.
        if len(safe) > 40 then
            safe = right(safe, 40)
        end if
        return safe + "-" + h
    end function

    function store_path(home, doc_path)
        return studio_results.results_dir(home) + "/" + studio_results._key(doc_path) + ".json"
    end function

    ' Where this document's capture files live, beside its index.
    function capture_dir(home, doc_path)
        return studio_results.results_dir(home) + "/" + studio_results._key(doc_path) + ".d"
    end function

    function capture_path(home, doc_path, result_id, name)
        return studio_results.capture_dir(home, doc_path) + "/" + result_id + "." + name
    end function

    ' The four streams a result captures, in display order.
    function capture_names()
        return ["out_prefix", "out_target", "err_prefix", "err_target", "vars", "vars_before"]
    end function

    ' ---- load / save -------------------------------------------------------

    function _empty(doc_path, status)
        return {
            schema_version: studio_results.schema_version(),
            doc_path: doc_path,
            next_result: 1,
            results: [],
            status: status
        }
    end function

    ' Read this document's store. Never raises, and never pretends: a corrupt or
    ' future-schema file yields an EMPTY store whose `status` says which, so the UI
    ' can tell "no runs yet" from "runs exist but cannot be read" instead of
    ' quietly showing an empty history for both.
    '
    '   empty   nothing on disk (a pre-STU-5A home reaches here)
    '   loaded  read and understood
    '   corrupt present but not valid JSON
    '   future  written by a newer schema; refused rather than misread
    function open(home, doc_path)
        st = persist.read_status(studio_results.store_path(home, doc_path))
        if st.status = "missing" then
            return studio_results._empty(doc_path, "empty")
        end if
        if st.status = "corrupt" then
            return studio_results._empty(doc_path, "corrupt")
        end if
        raw = st.value
        v = 0
        if has(raw, "schema_version") then
            v = raw.schema_version
        end if
        if v > studio_results.schema_version() then
            return studio_results._empty(doc_path, "future")
        end if
        store = studio_results._empty(doc_path, "loaded")
        if has(raw, "next_result") then
            store.next_result = raw.next_result
        end if
        if has(raw, "results") then
            store.results = raw.results
        end if
        return store
    end function

    ' Persist atomically. `status` is live-only and is dropped on the way out, so a
    ' reload cannot mistake a past read's status for stored truth.
    function save(home, store)
        persist.ensure_dir(studio_results.results_dir(home))
        persist.write_atomic(studio_results.store_path(home, store.doc_path), {
            schema_version: studio_results.schema_version(),
            doc_path: store.doc_path,
            next_result: store.next_result,
            results: store.results
        })
        ' The index is now authoritative, so anything it does not reference is
        ' leftover from an interrupted write and can go.
        studio_results.sweep_captures(home, store)
        return store
    end function

    ' ---- truncation --------------------------------------------------------

    ' The largest whole-codepoint prefix of `text` at most `nbytes` long. Binary
    ' search over `mid` (which counts CODEPOINTS) with byte_count as the oracle, so
    ' a cap never lands mid-codepoint and turns a capture into invalid UTF-8.
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

    ' Cut `text` to the cap if it is over, keeping the HEAD. The head is where a
    ' program says what it is doing and where the first error appears; the tail of
    ' a runaway loop is the least informative part of it.
    function _truncate(text)
        cap = studio_results.capture_cap()
        if byte_count(text) <= cap then
            return { text: text, cut: false }
        end if
        head = studio_results._byte_prefix(text, cap)
        return { text: head + "\n" + studio_results.truncation_notice() + "\n", cut: true }
    end function

    ' ---- recording ---------------------------------------------------------

    ' One capture text from a session result: truncate it, write it beside the
    ' index if non-empty, and hand back its stored byte count. An empty capture
    ' writes no file at all, so a clean run leaves one or two small files rather
    ' than four -- and a missing file reads back as "" either way.
    function _write_capture(home, doc_path, result_id, name, text)
        t = studio_results._truncate(text)
        if t.text = "" then
            return { bytes: 0, cut: false }
        end if
        f(file) = studio_results.capture_path(home, doc_path, result_id, name)
        write(f, t.text)
        return { bytes: byte_count(t.text), cut: t.cut }
    end function

    ' Add `result` as the newest entry: mint its id, write its captures beside the
    ' index (truncating any that are over the cap), replace the texts with byte
    ' counts, and evict past the retention limit.
    '
    ' Captures are written BEFORE the index is saved, and eviction deletes the
    ' evicted results' capture files, so the two never disagree about what exists.
    ' Eviction happens on WRITE rather than in a sweep, so the store is never over
    ' the bound even momentarily at rest.
    function add_result(home, store, result)
        result.result_id = "res-" + store.next_result
        store.next_result = store.next_result + 1

        ' A result arrives with its capture TEXTS (from studio_session.to_result)
        ' and leaves with byte counts. Say so plainly if one is missing rather than
        ' letting an index-into-unknown raise report it as something else -- the
        ' likely cause is a result being added twice.
        for each name in studio_results.capture_names()
            if not has(result, name) then
                error "studio_results.add_result: result has no " + name + " capture (already recorded?)"
            end if
        end for

        persist.ensure_dir(studio_results.capture_dir(home, store.doc_path))
        cut = []
        sizes = { out_prefix: 0, out_target: 0, err_prefix: 0, err_target: 0, vars: 0, vars_before: 0 }
        for each name in studio_results.capture_names()
            w = studio_results._write_capture(home, store.doc_path, result.result_id, name, result[name])
            sizes[name] = w.bytes
            if w.cut then
                cut = append(cut, name)
            end if
            ' The text does not go in the index: it is opaque bytes, and validating
            ' it as JSON on every read is what made the first layout unusable.
            result = remove_key(result, name)
        end for
        result.captures = sizes
        result.truncated = cut

        store.results = prepend(store.results, result)
        return studio_results._evict(home, store)
    end function

    ' Keep at most retain_per_section() results per section, newest first, deleting
    ' the capture files of anything dropped. Parallel arrays rather than a record
    ' because a section id ("sec-1") is not a legal record key.
    function _evict(home, store)
        keep = studio_results.retain_per_section()
        ids = []
        counts = []
        out = []
        for each r in store.results
            slot = -1
            i = 0
            for each sid in ids
                if sid = r.section_id then
                    slot = i
                end if
                i = i + 1
            end for
            drop = false
            if slot < 0 then
                ids = append(ids, r.section_id)
                counts = append(counts, 1)
            else
                if counts[slot] < keep then
                    counts[slot] = counts[slot] + 1
                else
                    drop = true
                end if
            end if
            if drop then
                studio_results._delete_captures(home, store.doc_path, r.result_id)
            else
                out = append(out, r)
            end if
        end for
        store.results = out
        return store
    end function

    function _delete_captures(home, doc_path, result_id)
        for each name in studio_results.capture_names()
            f(file) = studio_results.capture_path(home, doc_path, result_id, name)
            if exists(f) then
                delete(f)
            end if
        end for
        return nothing
    end function

    ' Remove capture files no result in the index refers to. This is what makes the
    ' write ordering safe: a crash between writing captures and swapping the index
    ' leaves files nothing points at, and the next save clears them.
    function sweep_captures(home, store)
        dir = studio_results.capture_dir(home, store.doc_path)
        probe(file) = dir
        if not exists(probe) then
            return 0
        end if
        live = []
        for each r in store.results
            live = append(live, r.result_id)
        end for
        d(dir) = dir
        removed = 0
        for each e in list(d)
            if e.type != "folder" then
                rid = first(split(e.name, "."))
                keep = false
                for each id in live
                    if id = rid then
                        keep = true
                    end if
                end for
                if not keep then
                    f(file) = dir + "/" + e.name
                    if exists(f) then
                        delete(f)
                        removed = removed + 1
                    end if
                end if
            end if
        end for
        return removed
    end function

    ' ---- reading -----------------------------------------------------------

    ' One capture's text, read on demand. Absent file -> "": a result whose stream
    ' was empty wrote nothing, and one whose captures were evicted is gone. No JSON
    ' validation happens here, which is the whole point of the sidecar layout.
    function capture(home, store, result_id, name)
        f(file) = studio_results.capture_path(home, store.doc_path, result_id, name)
        if not exists(f) then
            return ""
        end if
        return read(f)
    end function

    ' The stored byte count of a capture, straight from the index -- so a UI can
    ' show how much output there is without reading any of it.
    ' A capture a stored result does not have is zero bytes, not `unknown`. A
    ' version-1 result has no `vars`, and every comparison a caller makes against
    ' this ("> 0") raises on unknown rather than reading as absent.
    function capture_bytes(result, name)
        if not has(result, "captures") then
            return 0
        end if
        n = result.captures[name]
        if n = unknown then
            return 0
        end if
        return n
    end function

    ' This section's results, newest first.
    ' The branch a stored result belongs to. A result written before STU-7 has no
    ' branch field at all, and that is the baseline — which is what it was.
    function branch_of(result)
        b = result["branch"]
        if b = unknown then
            return ""
        end if
        if b = nothing then
            return ""
        end if
        return b
    end function

    ' History for one section IN ONE BRANCH. Sibling branches explore the same
    ' section with different state; showing their runs interleaved would put two
    ' answers to different questions in one list.
    function history_in(store, section_id, branch)
        out = []
        for each r in studio_results.history_for(store, section_id)
            if studio_results.branch_of(r) = branch then
                out = append(out, r)
            end if
        end for
        return out
    end function

    function latest_in(store, section_id, branch)
        h = studio_results.history_in(store, section_id, branch)
        if count(h) = 0 then
            return nothing
        end if
        return h[0]
    end function

    function history_for(store, section_id)
        out = []
        for each r in store.results
            if r.section_id = section_id then
                out = append(out, r)
            end if
        end for
        return out
    end function

    function latest_for(store, section_id)
        for each r in store.results
            if r.section_id = section_id then
                return r
            end if
        end for
        return nothing
    end function

    ' ---- standing (the staleness comparison) -------------------------------

    ' How a stored result relates to the section AS IT STANDS NOW. Computed on
    ' every read, never stored: it is a function of the current sections, and
    ' persisting it would recreate precisely the stale-result bug it exists to
    ' prevent.
    '
    '   current            the section is active and its content is unchanged
    '   stale-content      the section still exists, but its text has changed since
    '                      the run -- the result describes code that is no longer
    '                      there
    '   section-ambiguous  STU-3 could not decide which section this id names
    '   section-gone       the section was removed, or went stale
    '   source-invalid     the document does not parse, so the sections on hand are
    '                      last-known-good and nothing can honestly be compared
    '                      against the current text
    function standing_of(result, sections)
        if not sections.valid then
            return "source-invalid"
        end if
        found = nothing
        for each s in sections.sections
            if s.id = result.section_id then
                found = s
            end if
        end for
        if found = nothing then
            return "section-gone"
        end if
        if found.status = "ambiguous" then
            return "section-ambiguous"
        end if
        if found.status = "stale" then
            return "section-gone"
        end if
        if studio_results.fingerprint_of(found) = result.section_fingerprint then
            return "current"
        end if
        return "stale-content"
    end function

    ' The fingerprint of a section's content: STU-3's header and body hashes, which
    ' fold whitespace runs, so reindenting or inserting a blank line does NOT read
    ' as a content change while any real edit does.
    function fingerprint_of(section)
        return section.anchor.header_fp + ":" + section.anchor.body_fp
    end function

    ' Every stored result with its standing, newest first.
    function classify(store, sections)
        out = []
        for each r in store.results
            out = append(out, { result: r, standing: studio_results.standing_of(r, sections) })
        end for
        return out
    end function

    ' ---- the minimal view --------------------------------------------------

    function _standing_note(standing)
        if standing = "current" then
            return ""
        end if
        if standing = "stale-content" then
            return "  [section edited since this run]"
        end if
        if standing = "section-ambiguous" then
            return "  [section ambiguous]"
        end if
        if standing = "section-gone" then
            return "  [section no longer exists]"
        end if
        return "  [document does not parse]"
    end function

    ' A readable time. A raw epoch in a results pane is a number nobody can read
    ' — "at 1785692683" tells a user nothing about whether that run was five
    ' minutes or five weeks ago, which is the only question they are asking.
    ' A pinned test clock produces a fixed date, so goldens stay byte-stable.
    function _when(epoch_seconds)
        return string(from_epoch(epoch_seconds))
    end function

    function _one_line(r, standing)
        line = r.result_id + "  " + r.outcome
        if r.outcome = "refused" then
            line = line + " (" + r.reason + ")"
        else
            line = line + " exit " + r.exit_code
            if r.signal != 0 then
                line = line + " signal " + r.signal
            end if
        end if
        line = line + "  at " + studio_results._when(r.started_epoch) + "  " + r.duration_seconds + "s"
        return line + studio_results._standing_note(standing)
    end function

    ' The variables a result recorded, as display lines (empty when it has none).
    '
    ' Read from the capture on demand, never from the index: the descriptors are
    ' opaque bytes like every other capture, so browsing history does not pull
    ' them off disk. A version-1 result has no `vars` capture at all and produces
    ' nothing here, which is what an older result should look like.
    '
    ' `absent` is worth a line of its own. A section that raised left no variables
    ' *because it raised*, and that is different information from a section that
    ' ran and genuinely defined nothing.
    ' The MARKED variables of a result — the same array the pane's lines are built
    ' from, handed back as data. STU-8's table offers need the shapes, not the
    ' rendering, and deriving them twice would let the two readings drift.
    ' Answers an empty array for every state `vars_lines` reports in words:
    ' a caller asking "what can I open" has nothing to open in any of them.
    function vars_of(home, store, result)
        status = result["vars_status"]
        if status = unknown then
            return []
        end if
        if status != "captured" then
            return []
        end if
        if studio_results.capture_bytes(result, "vars") = 0 then
            return []
        end if
        r = try_decode(studio_results.capture(home, store, result.result_id, "vars"))
        if not r.ok then
            return []
        end if
        if not is_array(r.value) then
            return []
        end if
        before = studio_results._before_vars(home, store, result)
        return studio_results.mark_changes(before, r.value)
    end function

    function vars_lines(home, store, result)
        return studio_results.vars_lines_with(home, store, result, studio_viewers.create())
    end function

    ' STU-8: the same lines, with a chance for a LIBRARY-REGISTERED viewer to
    ' replace the structural preview of a variable it recognizes. The registry is
    ' a parameter rather than a global because the pane, the tools surface and the
    ' tests all read results and only one of them has an app to hold it.
    function vars_lines_with(home, store, result, reg)
        out = []
        status = result["vars_status"]
        if status = unknown then
            return out
        end if
        if status = "absent" then
            out = append(out, "  variables: none — the section did not finish")
            return out
        end if
        if status = "ambiguous" then
            out = append(out, "  variables: not separable (the program printed the marker)")
            return out
        end if
        if status = "unreadable" then
            out = append(out, "  variables: unreadable")
            return out
        end if
        if studio_results.capture_bytes(result, "vars") = 0 then
            return out
        end if
        r = try_decode(studio_results.capture(home, store, result.result_id, "vars"))
        if not r.ok then
            out = append(out, "  variables: unreadable")
            return out
        end if
        if not is_array(r.value) then
            out = append(out, "  variables: unreadable")
            return out
        end if
        if count(r.value) = 0 then
            out = append(out, "  variables: none")
            return out
        end if
        marked = studio_results.vars_of(home, store, result)
        changed = 0
        for each v in marked
            if v.change != "same" then
                changed = changed + 1
            end if
        end for
        head = "  variables (" + count(marked) + "):"
        if changed > 0 then
            head = "  variables (" + count(marked) + ", " + changed + " changed):"
        end if
        out = append(out, head)
        for each v in marked
            out = append(out, "    " + studio_results.var_line(v))
            ' A registered viewer REPLACES the structural preview; it does not add
            ' to it. Showing both would print the same numbers twice, once read
            ' correctly and once read as unrelated lists.
            rich = []
            spec = studio_viewers.best_for(reg, v)
            if spec != nothing then
                rich = studio_viewers.render(spec, v, "      ")
            end if
            if count(rich) > 0 then
                for each rl in rich
                    out = append(out, rl)
                end for
            else
                for each pl in studio_results.preview_lines(v)
                    out = append(out, pl)
                end for
            end if
        end for
        return out
    end function

    ' How many preview rows the PANE shows. The capture holds up to
    ' `studio_session.preview_rows()`; this is the smaller number a reader can
    ' take in without scrolling past everything else in the result.
    function view_rows()
        return 8
    end function

    ' Which viewer a captured variable calls for (STU-5 §6.2 dispatch), decided
    ' from its shape rather than from its declared type:
    '   scalar  a single value — shown inline on its own line
    '   list    a flat array — one column
    '   table   an array of records — the columns are the first element's fields
    '   record  a single record — field/value pairs
    '   opaque  no preview was captured (an older result, or a live handle)
    function viewer_for(v)
        if not has(v, "preview") then
            return "opaque"
        end if
        p = v.preview
        if count(p.cols) = 0 then
            return "scalar"
        end if
        if v.kind = "record" then
            return "record"
        end if
        if count(p.cols) = 1 then
            if p.cols[0] = "value" then
                return "list"
            end if
        end if
        return "table"
    end function

    ' The preview rows for a container, as display lines. Bounded twice over: the
    ' capture already sampled, and this shows fewer still, saying how many it did
    ' not show. A truncation that does not announce itself is the same error as a
    ' truncated capture presented as whole.
    function preview_lines(v)
        out = []
        kindv = studio_results.viewer_for(v)
        if kindv = "scalar" then
            return out
        end if
        if kindv = "opaque" then
            return out
        end if
        p = v.preview
        if kindv != "list" then
            out = append(out, "        " + join(p.cols, " | "))
        end if
        shown = 0
        for each row in p.rows
            if shown < studio_results.view_rows() then
                out = append(out, "        " + join(row, " | "))
                shown = shown + 1
            end if
        end for
        hidden = count(p.rows) - shown + p.more
        if hidden > 0 then
            out = append(out, "        ... " + hidden + " more")
        end if
        return out
    end function

    ' One variable's display line. The change marker leads, because "what did this
    ' section do" is the question a result is being read to answer:
    '   +  the section created it
    '   ~  it existed before and does not look the same now
    '      (blank) it was there and is unchanged
    function var_line(v)
        mark = "  "
        if v.change = "new" then
            mark = "+ "
        end if
        if v.change = "changed" then
            mark = "~ "
        end if
        line = mark + v.name + " " + v.kind
        if v.category = "container" then
            line = line + "[" + v.count + "]"
        end if
        if v.serializable = false then
            line = line + " (live)"
        end if
        ' A scalar's value belongs on its own line; a container's goes in the rows
        ' below it.
        if studio_results.viewer_for(v) = "scalar" then
            if v.preview.text != "" then
                line = line + " = " + v.preview.text
            end if
        end if
        return line
    end function

    ' Tag each of `after` against `before`: new, changed, or same — changed ones
    ' first, then new, then the rest, each group in the order the child reported
    ' (which reflection sorts by name).
    '
    ' "Changed" is judged on the SHALLOW descriptor: kind, type and count. Two
    ' different values of the same kind and size are indistinguishable here, and
    ' saying so is better than claiming a comparison that was never made — a
    ' deeper answer needs the values, which a finished run no longer has.
    function mark_changes(before, after)
        seen = {}
        for each b in before
            seen[b.name] = b
        end for
        changed = []
        added = []
        same = []
        for each a in after
            prev = seen[a.name]
            if prev = unknown then
                a.change = "new"
                added = append(added, a)
            else
                differs = false
                if prev.kind != a.kind then
                    differs = true
                end if
                if prev.type != a.type then
                    differs = true
                end if
                if prev.count != a.count then
                    differs = true
                end if
                if differs then
                    a.change = "changed"
                    changed = append(changed, a)
                else
                    a.change = "same"
                    same = append(same, a)
                end if
            end if
        end for
        out = []
        for each v in changed
            out = append(out, v)
        end for
        for each v in added
            out = append(out, v)
        end for
        for each v in same
            out = append(out, v)
        end for
        return out
    end function

    function _before_vars(home, store, result)
        if studio_results.capture_bytes(result, "vars_before") = 0 then
            return []
        end if
        r = try_decode(studio_results.capture(home, store, result.result_id, "vars_before"))
        if not r.ok then
            return []
        end if
        if not is_array(r.value) then
            return []
        end if
        return r.value
    end function

    ' The results view for one section: the latest result, then the history behind
    ' it, with any result whose fingerprint no longer matches the section's current
    ' content marked as such on its own line.
    function view_text(home, store, sections, section_id)
        return studio_results.view_in(home, store, sections, section_id, "")
    end function

    function view_in(home, store, sections, section_id, branch)
        return studio_results.view_with(home, store, sections, section_id, branch, studio_viewers.create())
    end function

    ' STU-8: the same view, with the library-registered viewers in hand.
    function view_with(home, store, sections, section_id, branch, reg)
        hist = studio_results.history_in(store, section_id, branch)
        if count(hist) = 0 then
            if store.status = "corrupt" then
                return "Results — " + section_id + "\n(results file unreadable)"
            end if
            if store.status = "future" then
                return "Results — " + section_id + "\n(results written by a newer Studio)"
            end if
            return "Results — " + section_id + "\n(no runs yet)"
        end if
        lines = []
        lines = append(lines, "Results — " + section_id + "  (" + count(hist) + " run(s))")
        latest = hist[0]
        st = studio_results.standing_of(latest, sections)
        lines = append(lines, "latest: " + studio_results._one_line(latest, st))
        ' Only the latest result's output is read: history rows show their sizes
        ' from the index, so browsing does not pull megabytes off disk.
        if studio_results.capture_bytes(latest, "out_target") > 0 then
            lines = append(lines, "  output: <" + studio_results.capture(home, store, latest.result_id, "out_target") + ">")
        end if
        if count(latest.truncated) > 0 then
            lines = append(lines, "  truncated: " + join(latest.truncated, ","))
        end if
        for each vl in studio_results.vars_lines_with(home, store, latest, reg)
            lines = append(lines, vl)
        end for
        for each a in latest.attribution
            lines = append(lines, "  ! " + a.where + " " + a.line + ":" + a.column + " " + a.message)
        end for
        if count(hist) > 1 then
            lines = append(lines, "history:")
            i = 1
            while i < count(hist)
                h = hist[i]
                lines = append(lines, "  " + studio_results._one_line(h, studio_results.standing_of(h, sections)))
                i = i + 1
            end while
        end if
        return join(lines, "\n")
    end function

end library
