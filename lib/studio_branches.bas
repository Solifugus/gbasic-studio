' studio_branches — STU-7 exploratory branching, state-only (headless).
'
' At a section boundary the user may keep several alternate continuations and
' switch between them. The mental model the design fixes (§9.1) is one sentence:
'
'   Everything ABOVE the branch point is shared ancestry.
'   Everything BELOW it may diverge.
'
' A STATE-ONLY branch is the cheap kind: the source is identical in every branch,
' and what differs is the runtime — inputs, parameters, assumptions. Under the
' replay model (STU-4) that has an exact meaning: each branch is the same code
' replayed with a different set of BINDINGS injected at its branch point. There
' is no other difference, which is why this kind needs no overlay, no temp file,
' and no change to the document on disk.
'
' A branch:
'   { id, doc_id, name, point, parent, bindings: [ { name, expr } ], anchor }
'     point   the section id the branch hangs off
'     parent  the branch it nests under; "" at the top level
'     anchor  a fingerprint of the SHARED ANCESTRY when the branch was made
'
' `anchor` is the honesty mechanism (§9.3). If the code above a branch point
' changes, everything below it was explored against source that no longer exists,
' and Studio must say so rather than let a stale continuation pass as current.
'
' NOT GIT. A Studio branch is not a Git branch, is not stored as one, and creates
' no ref (§2.3). It lives in the workspace record beside the section anchors.
library studio_branches


    ' Dependencies, declared rather than assumed.
    load studio_sections

    function schema_version()
        return 1
    end function

    function create()
        return {
            schema_version: studio_branches.schema_version(),
            next_branch: 1,
            branches: [],
            ' point -> branch id. Exactly one branch is selected at a branch
            ' point at a time (§9.1); a point with no entry shows its baseline,
            ' which is the document itself with no bindings at all.
            selected: {}
        }
    end function

    ' ---- the fingerprint of what is ABOVE a point --------------------------

    ' A hash over every section that precedes `point`, in order. Sections carry
    ' their own content fingerprints already (STU-3), so this composes them
    ' rather than re-hashing source — which means it moves when the shared
    ' ancestry's CONTENT moves, and not when something below the point does.
    function ancestry_anchor(sections, point)
        m = 1000000007
        h = 0
        for each s in sections.sections
            if s.id = point then
                return h - floor(h / m) * m
            end if
            if s.status != "stale" then
                fp = studio_branches._fp(s)
                i = 0
                n = byte_count(fp)
                while i < n
                    h = h - floor(h / m) * m
                    h = h * 131 + byte_at(fp, i) + 1
                    i = i + 1
                end while
            end if
        end for
        ' A point that is not in this document's sections has no ancestry to
        ' speak of; -1 can never equal a real hash, so such a branch reads stale.
        return 0 - 1
    end function

    function _fp(s)
        a = s.anchor
        return a.header_fp + ":" + a.body_fp
    end function

    ' ---- operations --------------------------------------------------------

    ' Create a branch at `point`. `parent` nests it under another branch ("" for
    ' the top level). Returns { tree, id }.
    function add(tree, doc_id, point, name, parent, sections)
        id = "br-" + tree.next_branch
        tree.next_branch = tree.next_branch + 1
        tree.branches = append(tree.branches, {
            id: id,
            doc_id: doc_id,
            name: name,
            point: point,
            parent: parent,
            bindings: [],
            anchor: studio_branches.ancestry_anchor(sections, point)
        })
        return { tree: tree, id: id }
    end function

    function by_id(tree, id)
        for each b in tree.branches
            if b.id = id then
                return b
            end if
        end for
        return nothing
    end function

    ' Every branch hanging off `point` for a document, in creation order.
    function at_point(tree, doc_id, point)
        out = []
        for each b in tree.branches
            if b.doc_id = doc_id then
                if b.point = point then
                    out = append(out, b)
                end if
            end if
        end for
        return out
    end function

    ' Select a branch at its own point. Selecting is per POINT, not global: two
    ' branch points each have their own selection, and the rendered continuation
    ' is the root-to-leaf path of those choices.
    function select(tree, id)
        b = studio_branches.by_id(tree, id)
        if b = nothing then
            return { tree: tree, action: "unknown", detail: id }
        end if
        sel = tree.selected
        sel[b.point] = id
        tree.selected = sel
        return { tree: tree, action: "selected", detail: id }
    end function

    ' Deselect a point — back to the baseline, which is the document with no
    ' bindings. There is always something to fall back to, so a delete can never
    ' leave a point with nothing rendered.
    function clear_point(tree, point)
        sel = tree.selected
        if has(sel, point) then
            sel = remove_key(sel, point)
        end if
        tree.selected = sel
        return tree
    end function

    function selected_at(tree, point)
        sel = tree.selected
        if not has(sel, point) then
            return ""
        end if
        return sel[point]
    end function

    function rename(tree, id, name)
        if trim(name) = "" then
            return { tree: tree, action: "invalid", detail: "empty" }
        end if
        out = []
        found = false
        for each b in tree.branches
            if b.id = id then
                b.name = trim(name)
                found = true
            end if
            out = append(out, b)
        end for
        tree.branches = out
        if not found then
            return { tree: tree, action: "unknown", detail: id }
        end if
        return { tree: tree, action: "renamed", detail: id }
    end function

    ' Delete a branch AND everything nested under it.
    '
    ' Named `drop` rather than `remove`: `remove` is a gBASIC builtin, and a
    ' library function sharing a builtin's name silently sends every unqualified
    ' call to the builtin instead. A child of a deleted branch
    ' describes a continuation whose own ancestry is gone, so leaving it would
    ' leave a branch nobody can reach and nothing can render.
    function drop(tree, id)
        doomed = studio_branches._descendants(tree, id)
        doomed = append(doomed, id)
        kept = []
        for each b in tree.branches
            if not contains(doomed, b.id) then
                kept = append(kept, b)
            end if
        end for
        tree.branches = kept
        ' Any point whose selection just vanished falls back to baseline.
        sel = tree.selected
        for each p in keys(sel)
            if contains(doomed, sel[p]) then
                sel = remove_key(sel, p)
            end if
        end for
        tree.selected = sel
        return { tree: tree, action: "deleted", detail: id, removed: count(doomed) }
    end function

    function _descendants(tree, id)
        out = []
        frontier = [id]
        guard = 0
        while count(frontier) > 0
            guard = guard + 1
            if guard > 1000 then
                return out
            end if
            nxt = []
            for each b in tree.branches
                if contains(frontier, b.parent) then
                    if not contains(out, b.id) then
                        out = append(out, b.id)
                        nxt = append(nxt, b.id)
                    end if
                end if
            end for
            frontier = nxt
        end while
        return out
    end function

    ' ---- bindings ----------------------------------------------------------

    ' Set one binding on a branch. `expr` is gBASIC source for a VALUE — this is
    ' what makes a state-only branch differ from its siblings, and it is the only
    ' place a branch contributes code.
    function bind(tree, id, name, expr)
        problem = studio_branches.binding_problem(name, expr)
        if problem != "" then
            return { tree: tree, action: "invalid", detail: problem }
        end if
        out = []
        found = false
        for each b in tree.branches
            if b.id = id then
                found = true
                kept = []
                replaced = false
                for each bd in b.bindings
                    if bd.name = name then
                        kept = append(kept, { name: name, expr: expr })
                        replaced = true
                    else
                        kept = append(kept, bd)
                    end if
                end for
                if not replaced then
                    kept = append(kept, { name: name, expr: expr })
                end if
                b.bindings = kept
            end if
            out = append(out, b)
        end for
        tree.branches = out
        if not found then
            return { tree: tree, action: "unknown", detail: id }
        end if
        return { tree: tree, action: "bound", detail: name }
    end function

    ' A binding's name must be an identifier and its expression must not be
    ' empty. This is the only guard between what a user typed and source that
    ' gets materialized into a run, so it refuses anything it cannot vouch for
    ' rather than hoping the interpreter will.
    function binding_problem(name, expr)
        if trim(name) = "" then
            return "the name is empty"
        end if
        if trim(expr) = "" then
            return "the value is empty"
        end if
        i = 0
        n = len(name)
        while i < n
            ch = lower(mid(name, i, 1))
            ok = false
            if ch >= "a" then
                if ch <= "z" then
                    ok = true
                end if
            end if
            if ch >= "0" then
                if ch <= "9" then
                    ok = true
                end if
            end if
            if ch = "_" then
                ok = true
            end if
            if i = 0 then
                if ch >= "0" then
                    if ch <= "9" then
                        ok = false
                    end if
                end if
            end if
            if not ok then
                return "'" + name + "' is not a variable name"
            end if
            i = i + 1
        end while
        ' A newline would let one binding become several statements, which is a
        ' different thing from a value and not what this promises to inject.
        if find(expr, "\n") != nothing then
            return "the value must be a single expression"
        end if
        return ""
    end function

    ' The gBASIC source a branch contributes, as assignment lines. Empty when the
    ' branch has no bindings — a branch with none is a legitimate placeholder for
    ' "the same thing, so I can compare later".
    function bindings_text(b)
        if b = nothing then
            return ""
        end if
        lines = []
        for each bd in b.bindings
            lines = append(lines, bd.name + " = " + bd.expr)
        end for
        if count(lines) = 0 then
            return ""
        end if
        return join(lines, "\n") + "\n"
    end function

    ' ---- staleness (§9.3) --------------------------------------------------

    ' Which branches were made against shared ancestry that has since changed.
    ' Studio never silently attaches stale execution state to changed source, so
    ' the answer is surfaced rather than acted on here.
    function stale_ids(tree, doc_id, sections)
        out = []
        for each b in tree.branches
            if b.doc_id = doc_id then
                now = studio_branches.ancestry_anchor(sections, b.point)
                if now != b.anchor then
                    out = append(out, b.id)
                end if
            end if
        end for
        return out
    end function

    function is_stale(tree, b, sections)
        now = studio_branches.ancestry_anchor(sections, b.point)
        return now != b.anchor
    end function

    ' Re-anchor a branch to the ancestry as it stands now: the user has looked at
    ' the change and accepted it. Explicit, never automatic — the whole point of
    ' the flag is that a person decides.
    function reanchor(tree, id, sections)
        out = []
        found = false
        for each b in tree.branches
            if b.id = id then
                b.anchor = studio_branches.ancestry_anchor(sections, b.point)
                found = true
            end if
            out = append(out, b)
        end for
        tree.branches = out
        if not found then
            return { tree: tree, action: "unknown", detail: id }
        end if
        return { tree: tree, action: "reanchored", detail: id }
    end function

    ' ---- the rendered path -------------------------------------------------

    ' The selected root-to-leaf chain for a document: the branch chosen at the
    ' outermost point, then the one chosen inside it, and so on. This is what
    ' §9.1 means by rendering one path at a time.
    function selected_chain(tree, doc_id, sections)
        chain = []
        parent = ""
        guard = 0
        while guard < 100
            guard = guard + 1
            pick = nothing
            for each s in sections.sections
                id = studio_branches.selected_at(tree, s.id)
                if id != "" then
                    b = studio_branches.by_id(tree, id)
                    if b != nothing then
                        if b.doc_id = doc_id then
                            if b.parent = parent then
                                if pick = nothing then
                                    pick = b
                                end if
                            end if
                        end if
                    end if
                end if
            end for
            if pick = nothing then
                return chain
            end if
            chain = append(chain, pick)
            parent = pick.id
        end while
        return chain
    end function

    ' Every binding the selected chain contributes, in chain order — outermost
    ' first, so a nested branch overrides the one it hangs under.
    function chain_bindings(tree, doc_id, sections)
        out = []
        for each b in studio_branches.selected_chain(tree, doc_id, sections)
            for each bd in b.bindings
                out = append(out, { point: b.point, name: bd.name, expr: bd.expr, branch: b.id })
            end for
        end for
        return out
    end function

    ' ---- persistence -------------------------------------------------------

    ' Folded into the workspace record beside the section anchors, because a
    ' branch means nothing without the sections it points at and the two must be
    ' restored together or not at all.
    function to_persist(tree)
        return {
            schema_version: studio_branches.schema_version(),
            next_branch: tree.next_branch,
            branches: tree.branches,
            selected: tree.selected
        }
    end function

    function from_persist(raw)
        tree = studio_branches.create()
        if raw = unknown then
            return tree
        end if
        if raw = nothing then
            return tree
        end if
        if not is_record(raw) then
            return tree
        end if
        v = 0
        if has(raw, "schema_version") then
            v = raw.schema_version
        end if
        if v > studio_branches.schema_version() then
            return tree
        end if
        if has(raw, "next_branch") then
            tree.next_branch = raw.next_branch
        end if
        if has(raw, "branches") then
            tree.branches = raw.branches
        end if
        if has(raw, "selected") then
            tree.selected = raw.selected
        end if
        return tree
    end function

    ' A deterministic rendering for the goldens: the tree, one line per branch,
    ' nesting shown by indentation, with the selection and staleness marked.
    function summary(tree, doc_id, sections)
        lines = []
        lines = append(lines, "branches: " + count(tree.branches) + " next=" + tree.next_branch)
        for each b in tree.branches
            if b.doc_id = doc_id then
                depth = studio_branches._depth(tree, b)
                indent = ""
                i = 0
                while i < depth
                    indent = indent + "  "
                    i = i + 1
                end while
                mark = "  "
                if studio_branches.selected_at(tree, b.point) = b.id then
                    mark = "* "
                end if
                line = "  " + indent + mark + b.id + " " + b.name + " @" + b.point
                if b.parent != "" then
                    line = line + " under " + b.parent
                end if
                if studio_branches.is_stale(tree, b, sections) then
                    line = line + "  [ancestry changed]"
                end if
                if count(b.bindings) > 0 then
                    line = line + "  {" + studio_branches._binding_names(b) + "}"
                end if
                lines = append(lines, line)
            end if
        end for
        return join(lines, "\n")
    end function

    function _binding_names(b)
        out = []
        for each bd in b.bindings
            out = append(out, bd.name + "=" + bd.expr)
        end for
        return join(out, ", ")
    end function

    function _depth(tree, b)
        d = 0
        cur = b
        guard = 0
        while cur.parent != ""
            guard = guard + 1
            if guard > 100 then
                return d
            end if
            cur = studio_branches.by_id(tree, cur.parent)
            if cur = nothing then
                return d
            end if
            d = d + 1
        end while
        return d
    end function

end library
