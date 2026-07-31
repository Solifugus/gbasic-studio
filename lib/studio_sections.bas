' studio_sections — STU-3 execution-section engine (headless).
'
' Studio owns execution-section identity; the platform (source_outline) owns source
' structure. This module derives execution sections from a document's outline,
' assigns Studio-owned stable section IDs, re-resolves them across edits by
' structural evidence (never raw line numbers), resolves a cursor byte-offset to its
' section, and (de)serializes anchors. It executes nothing (no replay/results/AI).
'
' Design basis: docs/gbasic_execution_boundaries.md — a boundary sits only at a
' top-level statement seam; sections are the top-level units of the executed list
' (a `program` block's body when present, else the file top level); compound
' statements are atomic; named declarations are landmarks. See docs/gbasic_studio_stu3.md.
'
' STATE (one per document):
'   { schema_version, doc_id, next_sec, valid, revision, source_hint_len,
'     sections: [ <section> ], diagnostics: [...], stale_ids: [...] }
' SECTION:
'   { id:"sec-N", kind, name(|nothing), status:"active"|"stale"|"ambiguous",
'     start_offset,end_offset,start_line,start_column,end_line,end_column,
'     member_kinds:[...], anchor:{...} }
' ANCHOR (Studio-owned; how an id re-finds its section — never line-only):
'   { kind, name, ancestry, ordinal, header_fp, body_fp, kinds_sig,
'     start_offset_hint, end_offset_hint }

library studio_sections

    function schema_version()
        return 1
    end function

    ' ---- arithmetic / fingerprint helpers ---------------------------------

    function _mod(a, b)
        return a - floor(a / b) * b
    end function

    ' Rolling hash of source[start_off, end_off) with ALL whitespace runs folded to
    ' a single space and leading/trailing whitespace trimmed, so reindentation and
    ' inserted blank lines do NOT change the fingerprint. Byte-based (matches the
    ' outline's byte offsets); pure O(n), no allocation. Collisions are gated by
    ' kind/ordinal in matching, so this need not be cryptographic.
    function _norm_hash(source, start_off, end_off)
        m = 1000000007
        h = 0
        started = false
        pending = false
        i = start_off
        while i < end_off
            b = byte_at(source, i)
            ws = false
            if b = 32 then
                ws = true
            end if
            if b = 9 then
                ws = true
            end if
            if b = 10 then
                ws = true
            end if
            if b = 13 then
                ws = true
            end if
            if ws then
                pending = true
            else
                if started then
                    if pending then
                        h = _mod(h * 131 + 33, m)
                    end if
                end if
                h = _mod(h * 131 + b + 1, m)
                started = true
                pending = false
            end if
            i = i + 1
        end while
        return h
    end function

    ' Byte offset of the first '\n' at/after start (else end).
    function _first_nl(source, start_off, end_off)
        i = start_off
        while i < end_off
            if byte_at(source, i) = 10 then
                return i
            end if
            i = i + 1
        end while
        return end_off
    end function

    ' ---- structure -> sections --------------------------------------------

    function _is_decl(kind)
        if kind = "program" then
            return true
        end if
        if kind = "library" then
            return true
        end if
        if kind = "function" then
            return true
        end if
        if kind = "modifier" then
            return true
        end if
        return false
    end function

    ' The scope-level outline nodes, in source order: the outline roots, EXCEPT that
    ' when the file has exactly one top-level `program` block its wrapper is dropped
    ' and its direct children become scope-level (design §6.2: sections come from the
    ' program body; declarations outside are hoisted before section 1 and stay their
    ' own sections). Iterating outline.nodes once preserves source order.
    function _scope_nodes(outline)
        prog_id = nothing
        prog_count = 0
        for each n in outline.nodes
            if n.parent_id = nothing then
                if n.kind = "program" then
                    prog_count = prog_count + 1
                    prog_id = n.id
                end if
            end if
        end for
        scope = []
        for each n in outline.nodes
            keep = false
            if n.parent_id = nothing then
                if prog_count = 1 then
                    if n.kind != "program" then
                        keep = true
                    end if
                else
                    keep = true
                end if
            else
                if prog_count = 1 then
                    if n.parent_id = prog_id then
                        keep = true
                    end if
                end if
            end if
            if keep then
                scope = append(scope, n)
            end if
        end for
        return { nodes: scope, prog_id: prog_id, prog_count: prog_count }
    end function

    ' Ancestry label for a scope node: the enclosing program's name, or "top".
    function _ancestry(node, scope_info, outline)
        if scope_info.prog_count = 1 then
            if node.parent_id = scope_info.prog_id then
                pname = ""
                for each n in outline.nodes
                    if n.id = scope_info.prog_id then
                        if n.name != nothing then
                            pname = n.name
                        end if
                    end if
                end for
                return "program:" + pname
            end if
        end if
        return "top"
    end function

    function _decl_section(node, source, ancestry)
        nl = studio_sections._first_nl(source, node.start_offset, node.end_offset)
        header_fp = studio_sections._norm_hash(source, node.start_offset, nl)
        body_fp = studio_sections._norm_hash(source, nl, node.end_offset)
        return {
            id: "",
            kind: node.kind,
            name: node.name,
            status: "active",
            start_offset: node.start_offset,
            end_offset: node.end_offset,
            start_line: node.start_line,
            start_column: node.start_column,
            end_line: node.end_line,
            end_column: node.end_column,
            member_kinds: [node.kind],
            anchor: {
                kind: node.kind,
                name: node.name,
                ancestry: ancestry,
                ordinal: 0,
                header_fp: header_fp,
                body_fp: body_fp,
                kinds_sig: node.kind,
                start_offset_hint: node.start_offset,
                end_offset_hint: node.end_offset
            }
        }
    end function

    function _statements_section(run, source, ancestry)
        first = run[0]
        last = run[count(run) - 1]
        kinds = []
        for each n in run
            kinds = append(kinds, n.kind)
        end for
        sig = join(kinds, ",")
        first_nl = studio_sections._first_nl(source, first.start_offset, first.end_offset)
        header_fp = studio_sections._norm_hash(source, first.start_offset, first_nl)
        body_fp = studio_sections._norm_hash(source, first.start_offset, last.end_offset)
        return {
            id: "",
            kind: "statements",
            name: nothing,
            status: "active",
            start_offset: first.start_offset,
            end_offset: last.end_offset,
            start_line: first.start_line,
            start_column: first.start_column,
            end_line: last.end_line,
            end_column: last.end_column,
            member_kinds: kinds,
            anchor: {
                kind: "statements",
                name: nothing,
                ancestry: ancestry,
                ordinal: 0,
                header_fp: header_fp,
                body_fp: body_fp,
                kinds_sig: sig,
                start_offset_hint: first.start_offset,
                end_offset_hint: last.end_offset
            }
        }
    end function

    ' Assign a per-(kind,ancestry) source-ordered ordinal to each section's anchor.
    function _assign_ordinals(sections)
        seen = {}
        out = []
        for each s in sections
            key = s.anchor.kind + "|" + s.anchor.ancestry
            n = 0
            if has(seen, key) then
                n = seen[key]
            end if
            s.anchor.ordinal = n
            seen[key] = n + 1
            out = append(out, s)
        end for
        return out
    end function

    ' Derive candidate sections (no ids/status yet) from an outline + its source.
    function derive(outline, source)
        info = studio_sections._scope_nodes(outline)
        scope = info.nodes
        sections = []
        run = []
        for each n in scope
            if studio_sections._is_decl(n.kind) then
                if count(run) > 0 then
                    anc = studio_sections._ancestry(run[0], info, outline)
                    sections = append(sections, studio_sections._statements_section(run, source, anc))
                    run = []
                end if
                anc = studio_sections._ancestry(n, info, outline)
                sections = append(sections, studio_sections._decl_section(n, source, anc))
            else
                run = append(run, n)
            end if
        end for
        if count(run) > 0 then
            anc = studio_sections._ancestry(run[0], info, outline)
            sections = append(sections, studio_sections._statements_section(run, source, anc))
        end if
        return studio_sections._assign_ordinals(sections)
    end function

    ' ---- reattachment ------------------------------------------------------

    ' Match predicates from strongest to weakest.
    function _pred(tier, c, p)
        if c.kind != p.kind then
            return false
        end if
        if tier = 1 then
            if c.anchor.header_fp != p.anchor.header_fp then
                return false
            end if
            return c.anchor.body_fp = p.anchor.body_fp
        end if
        if tier = 2 then
            if c.name = nothing then
                return false
            end if
            return c.name = p.name
        end if
        if tier = 3 then
            return c.anchor.body_fp = p.anchor.body_fp
        end if
        if tier = 4 then
            if c.anchor.kinds_sig != p.anchor.kinds_sig then
                return false
            end if
            return c.anchor.ancestry = p.anchor.ancestry
        end if
        return false
    end function

    ' Count unmatched prev p (p_used[i]=false) satisfying _pred(tier,c,p).
    function _count_prev(tier, c, prev, p_used)
        n = 0
        i = 0
        while i < count(prev)
            if not p_used[i] then
                if studio_sections._pred(tier, c, prev[i]) then
                    n = n + 1
                end if
            end if
            i = i + 1
        end while
        return n
    end function

    ' Count unmatched candidates c (c_id[j]="") satisfying _pred(tier,c,prev[pi]).
    function _count_cand(tier, prev_p, cand, c_id)
        n = 0
        j = 0
        while j < count(cand)
            if c_id[j] = "" then
                if studio_sections._pred(tier, cand[j], prev_p) then
                    n = n + 1
                end if
            end if
            j = j + 1
        end while
        return n
    end function

    ' Reattach candidates against previous sections. Returns { sections, next_sec,
    ' stale_ids }. A pair is reattached (prev id kept, status active) only when it is
    ' UNIQUE on both sides at a tier; candidates that collide with a surviving prev at
    ' a strong tier are flagged "ambiguous" (fresh id, not guessed); genuinely new
    ' candidates get a fresh id (active); unmatched prev ids become stale. O(n^2) over
    ' section count (small by construction; documented in stu3 doc).
    function _match(prev, cand, next_sec)
        ' c_id[j] = assigned id ("" = unmatched); c_status[j].
        c_id = []
        c_status = []
        j = 0
        while j < count(cand)
            c_id = append(c_id, "")
            c_status = append(c_status, "active")
            j = j + 1
        end while
        p_used = []
        i = 0
        while i < count(prev)
            p_used = append(p_used, false)
            i = i + 1
        end while

        tier = 1
        while tier <= 4
            j = 0
            while j < count(cand)
                if c_id[j] = "" then
                    if studio_sections._count_prev(tier, cand[j], prev, p_used) = 1 then
                        ' find that prev; confirm it maps uniquely back to this cand
                        pi = 0
                        found = -1
                        while pi < count(prev)
                            if not p_used[pi] then
                                if studio_sections._pred(tier, cand[j], prev[pi]) then
                                    found = pi
                                end if
                            end if
                            pi = pi + 1
                        end while
                        if found >= 0 then
                            if studio_sections._count_cand(tier, prev[found], cand, c_id) = 1 then
                                c_id[j] = prev[found].id
                                c_status[j] = "active"
                                p_used[found] = true
                            end if
                        end if
                    end if
                end if
                j = j + 1
            end while
            tier = tier + 1
        end while

        ' Remaining candidates: ambiguous if a surviving prev still looks like a
        ' rename/copy (strong-tier match), else genuinely new.
        j = 0
        while j < count(cand)
            if c_id[j] = "" then
                amb = false
                if studio_sections._count_prev(2, cand[j], prev, p_used) > 0 then
                    amb = true
                end if
                if studio_sections._count_prev(3, cand[j], prev, p_used) > 0 then
                    amb = true
                end if
                c_id[j] = "sec-" + next_sec
                next_sec = next_sec + 1
                if amb then
                    c_status[j] = "ambiguous"
                else
                    c_status[j] = "active"
                end if
            end if
            j = j + 1
        end while

        ' Assemble result sections (candidate order = source order) + stale ids.
        out = []
        j = 0
        while j < count(cand)
            s = cand[j]
            s.id = c_id[j]
            s.status = c_status[j]
            out = append(out, s)
            j = j + 1
        end while
        stale = []
        i = 0
        while i < count(prev)
            if not p_used[i] then
                stale = append(stale, prev[i].id)
            end if
            i = i + 1
        end while
        return { sections: out, next_sec: next_sec, stale_ids: stale }
    end function

    ' ---- state / refresh ---------------------------------------------------

    function create(doc_id)
        return {
            schema_version: 1,
            doc_id: doc_id,
            next_sec: 1,
            valid: true,
            revision: 0,
            source_hint_len: 0,
            sections: [],
            diagnostics: [],
            stale_ids: []
        }
    end function

    ' Refresh sections from source. Parses via source_outline. On ok=true, derives
    ' candidates and reattaches (preserving ids). On ok=false, RETAINS last-known-good
    ' sections and ids, records diagnostics, and marks valid=false (never reattaches
    ' against a failed parse, never deletes sections because parsing failed).
    function refresh(state, source)
        o = source_outline(source)
        return studio_sections._apply(state, o, source)
    end function

    ' Same as refresh but with a pre-computed outline (test seam).
    function refresh_outline(state, outline, source)
        return studio_sections._apply(state, outline, source)
    end function

    function _apply(state, o, source)
        state.diagnostics = o.diagnostics
        if not o.ok then
            state.valid = false
            return state
        end if
        cand = studio_sections.derive(o, source)
        r = studio_sections._match(state.sections, cand, state.next_sec)
        state.sections = r.sections
        state.next_sec = r.next_sec
        state.stale_ids = r.stale_ids
        state.valid = true
        state.revision = state.revision + 1
        state.source_hint_len = byte_count(source)
        return state
    end function

    ' ---- cursor resolution -------------------------------------------------

    ' The execution section containing a cursor BYTE offset, or nothing when the
    ' offset is in a gap between sections / before the first / after the last / in a
    ' stale range. Sections are non-overlapping top-level units, so at most one
    ' contains the offset; a nested block resolves to its enclosing section (its bytes
    ' lie within that section's range). end_offset is exclusive: an offset on a
    ' section's closing terminator is still inside the section.
    function section_at(state, offset)
        for each s in state.sections
            if s.status != "stale" then
                if offset >= s.start_offset then
                    if offset < s.end_offset then
                        return s.id
                    end if
                end if
            end if
        end for
        return nothing
    end function

    ' Byte offset of a 1-based BYTE line/column, the position convention the outline
    ' and the diagnostics both use (docs/source_outline_design.md §1.3). This is the
    ' seam between the EDITOR and the section engine: a document's stored cursor is
    ' line/column, every section range is a byte offset. Out-of-range positions clamp
    ' to the end of source rather than raising, so a cursor left over from a longer
    ' previous revision degrades to "past the last section" (-> nothing) instead of
    ' breaking the caller.
    function offset_of(source, line, column)
        total = byte_count(source)
        off = 0
        cur = 1
        while cur < line
            if off >= total then
                return total
            end if
            if byte_at(source, off) = 10 then
                cur = cur + 1
            end if
            off = off + 1
        end while
        off = off + (column - 1)
        if off < 0 then
            return 0
        end if
        if off > total then
            return total
        end if
        return off
    end function

    ' Cursor-to-section straight from an editor position (studio_docs stores
    ' doc.cursor as {line, column}). Returns a section id or nothing.
    function section_at_position(state, source, line, column)
        off = studio_sections.offset_of(source, line, column)
        return studio_sections.section_at(state, off)
    end function

    function section_by_id(state, id)
        for each s in state.sections
            if s.id = id then
                return s
            end if
        end for
        return nothing
    end function

    ' ---- persistence -------------------------------------------------------

    ' Compact persistable form: ids + Studio anchors + next counter. Does NOT persist
    ' parse-local outline node ids or full ranges as identity (the anchor carries only
    ' hint offsets). Regenerated structure comes from a reparse on restore.
    function to_persist(state)
        anchors = []
        for each s in state.sections
            anchors = append(anchors, {
                id: s.id,
                kind: s.kind,
                name: s.name,
                status: s.status,
                anchor: s.anchor
            })
        end for
        return {
            schema_version: 1,
            next_sec: state.next_sec,
            anchors: anchors
        }
    end function

    ' Rebuild a state from persisted anchors (ids preserved). The restored sections
    ' are anchor-only (ranges are last-session hints) until the next refresh reattaches
    ' them to the freshly parsed structure.
    function from_persist(raw, doc_id)
        st = studio_sections.create(doc_id)
        if raw = nothing then
            return st
        end if
        if has(raw, "next_sec") then
            st.next_sec = raw.next_sec
        end if
        secs = []
        if has(raw, "anchors") then
            for each a in raw.anchors
                secs = append(secs, {
                    id: a.id,
                    kind: a.kind,
                    name: a.name,
                    status: a.status,
                    start_offset: a.anchor.start_offset_hint,
                    end_offset: a.anchor.end_offset_hint,
                    start_line: 0,
                    start_column: 0,
                    end_line: 0,
                    end_column: 0,
                    member_kinds: [],
                    anchor: a.anchor
                })
            end for
        end if
        st.sections = secs
        return st
    end function

    ' ---- workspace bundle (the persisted slot studio_model carries) ---------
    '
    ' The workspace record carries ONE additive `sections` slot: a list of
    ' per-document persist records (`to_persist` output tagged with its doc_id).
    ' Additive is what makes it compatible in both directions:
    '   * an STU-2-era workspace file has no `sections` key at all — it reads back as
    '     `unknown`, studio_model.normalize_workspace backfills the [] default, and
    '     every accessor below treats absent/unknown/nothing as "no sections yet";
    '   * a future reader that does not know the slot simply ignores it.
    ' The whole bundle is json_encodable (offsets/fingerprints are numbers, an absent
    ' name is `nothing` -> JSON null -> `nothing` again on decode), so it goes through
    ' persist.write_atomic unchanged.

    function _bundle(raw)
        if raw = unknown then
            return []
        end if
        if raw = nothing then
            return []
        end if
        return raw
    end function

    ' Upsert this document's persist record into the bundle, keyed by doc_id.
    ' COW: returns the new bundle, caller reassigns.
    function persist_into(raw, state)
        bundle = studio_sections._bundle(raw)
        rec = studio_sections.to_persist(state)
        rec.doc_id = state.doc_id
        out = []
        replaced = false
        for each e in bundle
            if e.doc_id = state.doc_id then
                out = append(out, rec)
                replaced = true
            else
                out = append(out, e)
            end if
        end for
        if not replaced then
            out = append(out, rec)
        end if
        return out
    end function

    ' The state for `doc_id` rebuilt from the bundle, or a fresh empty state when
    ' this document has no persisted sections (new document, or a workspace saved
    ' before STU-3). Never raises on a missing/older slot.
    function restore_from(raw, doc_id)
        bundle = studio_sections._bundle(raw)
        for each e in bundle
            if e.doc_id = doc_id then
                return studio_sections.from_persist(e, doc_id)
            end if
        end for
        return studio_sections.create(doc_id)
    end function

    ' Drop a document's sections (document closed / removed from the workspace).
    function forget(raw, doc_id)
        bundle = studio_sections._bundle(raw)
        out = []
        for each e in bundle
            if e.doc_id != doc_id then
                out = append(out, e)
            end if
        end for
        return out
    end function

    ' ---- summary (tests / minimal UI) --------------------------------------

    function summary(state)
        lines = []
        head = "valid=" + state.valid + " revision=" + state.revision + " next_sec=" + state.next_sec + " sections=" + count(state.sections) + " stale=" + count(state.stale_ids)
        lines = append(lines, head)
        for each s in state.sections
            nm = "-"
            if s.name != nothing then
                nm = s.name
            end if
            lines = append(lines, s.id + " " + s.kind + " name=" + nm + " status=" + s.status + " [" + s.start_offset + "," + s.end_offset + ") ord=" + s.anchor.ordinal + " kinds=" + s.anchor.kinds_sig)
        end for
        for each d in state.diagnostics
            lines = append(lines, "! " + d.severity + " " + d.message)
        end for
        return join(lines, "\n")
    end function

end library
