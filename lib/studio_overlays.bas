' studio_overlays — STU-9 code-overlay branches (headless).
'
' STU-7 gave branches that differ only in their BINDINGS: identical source, a
' different runtime. This is the other kind (design §9.2) — experimenting with
' downstream CODE without touching the file yet:
'
'   * changes apply only BELOW the branch point,
'   * they live in Studio metadata, never in the `.bas` (§2.1),
'   * they are visibly marked experimental,
'   * they are not Git branches and not extra visible `.bas` files (§2.3),
'   * the canonical file on disk is never mutated by selecting or running one.
'
' ---------------------------------------------------------------------------
' DESIGN Q5, DECIDED: a SECTION-SCOPED FULL-TEXT REPLACEMENT.
'
' The design left the representation open between a scoped textual diff, an AST
' patch, and a shadow file. Taking them in reverse:
'
'   * An AST patch is not available. The platform exposes `source_outline`, which
'     is structure, not a tree you can rewrite and print back. Building one would
'     be building a second parser for gBASIC inside Studio.
'
'   * A textual diff needs a patch engine — hunks, context lines, fuzz — and it
'     buys a worse answer than the one below. "Did this hunk still apply?" is a
'     fuzzy question with a heuristic answer, and a heuristic that guesses wrong
'     silently misapplies an edit. §9.3 requires the opposite.
'
'   * A shadow file for the whole document loses the ONE property the design
'     insists on: that an overlay is scoped below the branch point. A whole-file
'     shadow cannot tell you whether the shared ancestry drifted, because it
'     contains its own copy of it.
'
' So: an overlay is a set of EDITS, one per section, each carrying the section's
' id, the replacement text, and `base_fp` — the fingerprint of the canonical text
' the edit was written against.
'
' That representation falls out of what STU-3 already built and it makes every
' hard question exact rather than fuzzy:
'
'   apply     splice each edit over its section's byte span. The same operation
'             the run pipeline already performs for markers and bindings.
'   conflict  `base_fp != fingerprint_of(section_now)`. Not "the context lines no
'             longer match" — a hash comparison, with no fuzz and no judgement.
'   scope     a section's offset against the branch point's. Exact.
'   promote   write the same splice into the file. No patch application, so
'             promote cannot fail in a way that apply did not already report.
'
' The cost is honest and worth naming: an overlay replaces WHOLE SECTIONS. There
' is no such thing as a three-line change to a fifty-line section that survives an
' unrelated edit elsewhere in that same section. Section granularity is the
' granularity of the conflict, and a section IS the unit Studio executes, marks,
' anchors and records results against — so it is the unit the user already thinks
' in.
'
' ---------------------------------------------------------------------------
' AN EDIT:
'   { branch, section_id, base_fp, text }
'
' A branch's overlay is every edit carrying its id. Nothing is stored per
' document beyond that: the section id already names the document, because ids are
' minted per document and the state that holds them is per document.
library studio_overlays


    ' Dependencies, declared rather than assumed.
    load studio_sections
    load studio_results

    function schema_version()
        return 1
    end function

    function create()
        return { schema_version: studio_overlays.schema_version(), edits: [] }
    end function

    ' ---- reading ------------------------------------------------------------

    function for_branch(ov, branch)
        out = []
        for each e in ov.edits
            if e.branch = branch then
                out = append(out, e)
            end if
        end for
        return out
    end function

    function edit_for(ov, branch, section_id)
        for each e in ov.edits
            if e.branch = branch then
                if e.section_id = section_id then
                    return e
                end if
            end if
        end for
        return nothing
    end function

    function has_any(ov, branch)
        return count(studio_overlays.for_branch(ov, branch)) > 0
    end function

    ' ---- writing ------------------------------------------------------------

    ' Record (or replace) one section's overlay text. `base_fp` is the fingerprint
    ' of the canonical section this was written against — the whole conflict story
    ' rests on it being captured HERE, at the moment the user started editing, and
    ' not recomputed later from whatever the file says by then.
    function put(ov, branch, section_id, base_fp, text)
        out = []
        replaced = false
        for each e in ov.edits
            if e.branch = branch then
                if e.section_id = section_id then
                    out = append(out, { branch: branch, section_id: section_id, base_fp: base_fp, text: text })
                    replaced = true
                else
                    out = append(out, e)
                end if
            else
                out = append(out, e)
            end if
        end for
        if not replaced then
            out = append(out, { branch: branch, section_id: section_id, base_fp: base_fp, text: text })
        end if
        ov.edits = out
        return ov
    end function

    ' Named `drop` rather than `remove`, which is a builtin: a library function
    ' sharing a builtin's name silently sends every unqualified call to the
    ' builtin. STU-7 learned this the same way.
    function drop(ov, branch, section_id)
        out = []
        for each e in ov.edits
            keep = true
            if e.branch = branch then
                if e.section_id = section_id then
                    keep = false
                end if
            end if
            if keep then
                out = append(out, e)
            end if
        end for
        ov.edits = out
        return ov
    end function

    function drop_branch(ov, branch)
        out = []
        for each e in ov.edits
            if e.branch != branch then
                out = append(out, e)
            end if
        end for
        ov.edits = out
        return ov
    end function

    ' ---- conflicts (§9.3) ---------------------------------------------------

    ' What is wrong with each edit against the CURRENT sections, or an empty list.
    '
    '   gone          the section the edit replaces is no longer in the outline
    '   changed       its canonical text moved after the edit was written
    '   out-of-scope  it is no longer below the branch point
    '
    ' `point_end` is the branch point section's end offset; pass -1 to skip the
    ' scope check (a caller that has no point in hand, such as a promote preview).
    function conflicts(st, edits, point_end)
        out = []
        for each e in edits
            sec = studio_sections.section_by_id(st, e.section_id)
            if sec = nothing then
                out = append(out, { section_id: e.section_id, why: "gone",
                                    detail: "the section this replaces is no longer in the file" })
            else
                if studio_results.fingerprint_of(sec) != e.base_fp then
                    out = append(out, { section_id: e.section_id, why: "changed",
                                        detail: "the canonical text moved after this overlay was written" })
                else
                    if point_end >= 0 then
                        if sec.start_offset < point_end then
                            out = append(out, { section_id: e.section_id, why: "out-of-scope",
                                                detail: "this section is not below the branch point" })
                        end if
                    end if
                end if
            end if
        end for
        return out
    end function

    function conflict_for(problems, section_id)
        for each p in problems
            if p.section_id = section_id then
                return p
            end if
        end for
        return nothing
    end function

    ' The edits that apply cleanly, in source order — which is the order the
    ' projection needs and NOT the order they were written in.
    function applicable(st, edits, point_end)
        problems = studio_overlays.conflicts(st, edits, point_end)
        keep = []
        for each e in edits
            if studio_overlays.conflict_for(problems, e.section_id) = nothing then
                keep = append(keep, e)
            end if
        end for
        return studio_overlays._by_offset(st, keep)
    end function

    function _by_offset(st, edits)
        out = []
        left = edits
        while count(left) > 0
            pick = 0
            i = 1
            while i < count(left)
                if studio_overlays._offset_of(st, left[i]) < studio_overlays._offset_of(st, left[pick]) then
                    pick = i
                end if
                i = i + 1
            end while
            out = append(out, left[pick])
            rest = []
            i = 0
            while i < count(left)
                if i != pick then
                    rest = append(rest, left[i])
                end if
                i = i + 1
            end while
            left = rest
        end while
        return out
    end function

    function _offset_of(st, e)
        sec = studio_sections.section_by_id(st, e.section_id)
        if sec = nothing then
            return 0
        end if
        return sec.start_offset
    end function

    ' ---- projection ---------------------------------------------------------

    ' The source as this branch sees it: canonical text with each applicable
    ' edit's section replaced. This is what the design calls the projection, and
    ' it is also exactly what gets materialized for the run — the canonical file is
    ' never written, read back, or touched.
    '
    ' A section's `end_offset` stops at its LAST STATEMENT, not after the newline
    ' that follows, so a replacement span excludes that newline and the text put in
    ' its place must too. An overlay ending in a newline would otherwise gain a
    ' blank line every time it was saved.
    function project(source, st, edits)
        ordered = studio_overlays._by_offset(st, edits)
        out = ""
        cursor = 0
        applied = []
        for each e in ordered
            sec = studio_sections.section_by_id(st, e.section_id)
            if sec != nothing then
                if sec.start_offset >= cursor then
                    out = out + studio_overlays._slice(source, cursor, sec.start_offset)
                    out = out + studio_overlays._body(e.text)
                    cursor = sec.end_offset
                    applied = append(applied, e.section_id)
                end if
            end if
        end for
        out = out + studio_overlays._slice(source, cursor, byte_count(source))
        return { text: out, applied: applied }
    end function

    ' Strip trailing newlines so the replacement matches the span convention above.
    function _body(text)
        n = byte_count(text)
        while n > 0
            if byte_at(text, n - 1) != 10 then
                break
            end if
            n = n - 1
        end while
        return studio_overlays._slice(text, 0, n)
    end function

    ' source[a, b) as text. Offsets from `source_outline` are BYTE offsets and
    ' `mid` counts characters, so a document with one non-ASCII character makes
    ' the two disagree — silently, and only for that document. Two binary searches
    ' on `byte_count` bridge them; the same helper studio_session uses, and for the
    ' same reason.
    function _slice(source, a, b)
        if b <= a then
            return ""
        end if
        full = studio_overlays._byte_prefix(source, b)
        head = studio_overlays._byte_prefix(full, a)
        return mid(full, len(head), len(full) - len(head))
    end function

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

    ' ---- promote / discard / compare (§9.2) ---------------------------------

    ' Promote is the same projection, written to the file. It is refused outright
    ' while ANY edit conflicts: promoting a partial overlay would write half an
    ' experiment into someone's source and leave the other half in metadata, which
    ' is a state nobody asked for and nothing later can describe.
    function promote(source, st, edits, point_end)
        problems = studio_overlays.conflicts(st, edits, point_end)
        if count(problems) > 0 then
            return { ok: false, why: "conflicts", problems: problems, text: source }
        end if
        if count(edits) = 0 then
            return { ok: false, why: "empty", problems: [], text: source }
        end if
        p = studio_overlays.project(source, st, edits)
        return { ok: true, why: "", problems: [], text: p.text }
    end function

    ' Rebase: re-stamp an edit onto the canonical text as it is NOW.
    '
    ' This is not a merge, and it must not be described as one. There is no merge
    ' to perform — an overlay is the whole section's text, so accepting it means
    ' the canonical change to that section is SHADOWED. Rebase therefore reports,
    ' per edit, exactly what it is now shadowing, and `diff_lines` shows it. An edit
    ' whose section is gone cannot be rebased onto anything and is reported for the
    ' user to discard; nothing is dropped here without being named.
    function rebase(ov, branch, st)
        edits = studio_overlays.for_branch(ov, branch)
        problems = studio_overlays.conflicts(st, edits, -1)
        rebased = []
        unresolved = []
        for each e in edits
            p = studio_overlays.conflict_for(problems, e.section_id)
            if p = nothing then
                ' nothing to do: it already sits on the current text
            else
                if p.why = "changed" then
                    sec = studio_sections.section_by_id(st, e.section_id)
                    ov = studio_overlays.put(ov, branch, e.section_id, studio_results.fingerprint_of(sec), e.text)
                    rebased = append(rebased, e.section_id)
                else
                    unresolved = append(unresolved, p)
                end if
            end if
        end for
        return { ov: ov, rebased: rebased, unresolved: unresolved }
    end function

    ' Canonical against overlay for one section, as display lines. Named
    ' `diff_lines` and not `compare`: `compare` is a builtin, and a library
    ' function sharing a builtin's name sends every unqualified call to the
    ' builtin instead. The interpreter warns about it now; it did not always. Not a minimal
    ' diff: the common head and tail are trimmed and what is left is shown as two
    ' blocks. A real LCS would mark fewer lines, and would also be a diff engine —
    ' the thing this representation exists to avoid needing. What a reader has to
    ' be able to see is WHICH LINES DIFFER, and trimming gives that exactly.
    function diff_lines(source, st, e)
        out = []
        sec = studio_sections.section_by_id(st, e.section_id)
        if sec = nothing then
            out = append(out, "  " + e.section_id + ": the canonical section is gone")
            return out
        end if
        was = split(studio_overlays._slice(source, sec.start_offset, sec.end_offset), "\n")
        now = split(studio_overlays._body(e.text), "\n")
        head = 0
        while head < count(was)
            if head >= count(now) then
                break
            end if
            if was[head] != now[head] then
                break
            end if
            head = head + 1
        end while
        tail = 0
        while head + tail < count(was)
            if head + tail >= count(now) then
                break
            end if
            if was[count(was) - 1 - tail] != now[count(now) - 1 - tail] then
                break
            end if
            tail = tail + 1
        end while
        if head = count(was) then
            if head = count(now) then
                out = append(out, "  " + e.section_id + ": identical")
                return out
            end if
        end if
        out = append(out, "  " + e.section_id + ":")
        if head > 0 then
            out = append(out, "    " + head + " line(s) unchanged above")
        end if
        i = head
        while i < count(was) - tail
            out = append(out, "    - " + was[i])
            i = i + 1
        end while
        i = head
        while i < count(now) - tail
            out = append(out, "    + " + now[i])
            i = i + 1
        end while
        if tail > 0 then
            out = append(out, "    " + tail + " line(s) unchanged below")
        end if
        return out
    end function

    ' The canonical text of a section, which is what an editor opens when someone
    ' starts an overlay: an overlay begins as a copy of what is there, not as a
    ' blank buffer.
    function canonical_text(source, st, section_id)
        sec = studio_sections.section_by_id(st, section_id)
        if sec = nothing then
            return ""
        end if
        return studio_overlays._slice(source, sec.start_offset, sec.end_offset)
    end function

    function base_fp(st, section_id)
        sec = studio_sections.section_by_id(st, section_id)
        if sec = nothing then
            return ""
        end if
        return studio_results.fingerprint_of(sec)
    end function

    ' ---- persistence --------------------------------------------------------

    function to_persist(ov)
        return { schema_version: studio_overlays.schema_version(), edits: ov.edits }
    end function

    function from_persist(raw)
        ov = studio_overlays.create()
        if raw = nothing then
            return ov
        end if
        if not is_record(raw) then
            return ov
        end if
        if not has(raw, "edits") then
            return ov
        end if
        if not is_array(raw.edits) then
            return ov
        end if
        for each e in raw.edits
            if studio_overlays._well_formed(e) then
                ov.edits = append(ov.edits, { branch: e.branch, section_id: e.section_id,
                                              base_fp: e.base_fp, text: e.text })
            end if
        end for
        return ov
    end function

    function _well_formed(e)
        if not is_record(e) then
            return false
        end if
        for each k in ["branch", "section_id", "base_fp", "text"]
            if not has(e, k) then
                return false
            end if
            if not is_string(e[k]) then
                return false
            end if
        end for
        return true
    end function

    ' ---- summaries ----------------------------------------------------------

    function summary(ov, branch, st)
        out = []
        edits = studio_overlays.for_branch(ov, branch)
        if count(edits) = 0 then
            out = append(out, "overlay: none (this branch differs only in state)")
            return out
        end if
        problems = studio_overlays.conflicts(st, edits, -1)
        out = append(out, "overlay: " + count(edits) + " section(s), " + count(problems) + " conflict(s)")
        for each e in studio_overlays._by_offset(st, edits)
            p = studio_overlays.conflict_for(problems, e.section_id)
            mark = "  ok      "
            if p != nothing then
                mark = "  " + p.why + " "
            end if
            out = append(out, mark + e.section_id)
            if p != nothing then
                out = append(out, "            " + p.detail)
            end if
        end for
        return out
    end function

end library
