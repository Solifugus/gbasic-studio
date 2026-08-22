' studio_viewers — STU-8 library-registered rich viewers (headless).
'
' Design Q11, and the §6.2 boundary it exists to respect: Studio must be able to
' render a `stats.bas` regression the way a statistician reads one — R², then a
' coefficient table with standard errors, t and p across from each term — WITHOUT
' teaching the core gBASIC language what "display" means. Structural dispatch
' (STU-5) cannot do it: to that layer a model is a record holding six unrelated
' arrays, and it shows six unrelated arrays.
'
' The convention. A library that defines a type ships a DECLARATIVE sidecar named
' after it — `stats.bas` is accompanied by `stats.viewers` — holding JSON, never
' code. Studio reads it; Studio never evaluates it. That is the whole registration
' protocol: no core change, no import hook, no callback into a library, and
' nothing a library must do at run time.
'
'   { "schema": 1, "library": "stats", "viewers": [ ... ] }
'
' One viewer:
'   { "name":   "regression",
'     "title":  "OLS regression",
'     "match":  { "kind": "record", "fields": ["coefficients", "r_squared"] },
'     "detail": ["coefficients", "std_errors", "r_squared", "n"],
'     "layout": [ { "block": "fields",   "items":   [...] },
'                 { "block": "parallel", "columns": [...] } ] }
'
' WHY `match` IS OVER A DESCRIPTOR AND NOT A VALUE. Studio holds no values. The
' replay model (STU-4) means the child that computed the regression exited before
' the pane was ever drawn; all that survives is what the variable epilogue
' captured. So a match tests the SHAPE the epilogue reported — kind, type, and
' the field names a record preview carries — and never the data.
'
' WHY `detail` EXISTS. Recognition can happen here, but EXTRACTION cannot: the
' preview stringifies, so `coefficients` arrives as the text "[1.2, 0.48]" and a
' parallel-array table built from it would be built from parsing display text.
' `detail` names the fields a viewer needs as real values, and `studio_session`
' compiles the registry's match rules into the epilogue so the capture is taken
' where the value still is. It is bounded like every other capture: a viewer that
' asks for a million-element array gets `detail_rows()` of it and a count.
'
' MATCH SPECIFICITY. Two viewers may both match; the more specific one wins, where
' specific means "requires more fields". A tie is broken by discovery order, which
' is stable because the search path is ordered and each directory is sorted.
library studio_viewers




    function schema_version()
        return 1
    end function

    ' The extension a sidecar carries. Deliberately not `.json`: a directory of
    ' libraries may hold unrelated JSON, and a registry that swept all of it would
    ' report parse failures for files that were never addressed to it.
    function suffix()
        return ".viewers"
    end function

    ' How many elements of a detail array the capture may carry. A viewer is a
    ' READING of a result, not a copy of it: a coefficient table with two hundred
    ' terms is already past what anyone reads down, and the DataGrid tier
    ' (studio_table) is the honest answer for more.
    function detail_rows()
        return 200
    end function

    ' ---- the registry ------------------------------------------------------

    function create()
        return { schema_version: studio_viewers.schema_version(), viewers: [], sources: [], problems: [] }
    end function

    ' Search directories, in precedence order. A library's own sidecar beside the
    ' library wins over Studio's bundled copy — the library is the authority on
    ' its own types, and Studio's copy exists only so a stock install has one
    ' before any library ships theirs.
    function search_path(studio_dir)
        dirs = []
        v = env("GBASIC_STDLIB")
        if is_string(v) then
            if v != "" then
                dirs = append(dirs, v)
            end if
        end if
        if studio_dir != "" then
            dirs = append(dirs, studio_dir)
        end if
        return dirs
    end function

    ' The path a running Studio uses. `GBASIC_STUDIO_VIEWERS` names the bundled
    ' directory (the launcher exports it); the relative fallback is what a test or
    ' a direct interpreter invocation from the checkout gets.
    function default_path()
        own = "viewers"
        v = env("GBASIC_STUDIO_VIEWERS")
        if is_string(v) then
            if v != "" then
                own = v
            end if
        end if
        return studio_viewers.search_path(own)
    end function

    ' Read every sidecar on the path into one registry. Missing directories,
    ' unreadable files and malformed JSON are all recorded as PROBLEMS rather than
    ' raised: one library shipping a broken sidecar must not stop the pane from
    ' drawing, and a viewer that silently did not load is the kind of failure that
    ' gets diagnosed as "the pane is wrong" for a week.
    function load_path(dirs)
        reg = studio_viewers.create()
        for each dir in dirs
            reg = studio_viewers.load_dir(reg, dir)
        end for
        return reg
    end function

    function load_dir(reg, dir)
        names = []
        d(dir) = dir
        for each e in list(d)
            if e.type = "file" then
                if studio_viewers._is_sidecar(e.name) then
                    names = append(names, e.name)
                end if
            end if
        end for
        names = sort(names)
        for each n in names
            reg = studio_viewers.load_file(reg, dir + "/" + n)
        end for
        return reg
    end function

    function _is_sidecar(name)
        s = studio_viewers.suffix()
        if len(name) <= len(s) then
            return false
        end if
        return right(name, len(s)) = s
    end function

    ' One sidecar. Every viewer is validated before it enters the registry, and a
    ' rejected one names itself and the reason: an invalid entry that loaded
    ' anyway would fail later, in the renderer, where the message would be about
    ' a missing field rather than about a malformed declaration.
    function load_file(reg, path)
        f(file) = path
        if not exists(f) then
            reg.problems = append(reg.problems, path + ": missing")
            return reg
        end if
        r = try_decode(read(f))
        if not r.ok then
            reg.problems = append(reg.problems, path + ": not valid JSON")
            return reg
        end if
        doc = r.value
        if not is_record(doc) then
            reg.problems = append(reg.problems, path + ": not an object")
            return reg
        end if
        if not has(doc, "viewers") then
            reg.problems = append(reg.problems, path + ": no viewers")
            return reg
        end if
        if not is_array(doc.viewers) then
            reg.problems = append(reg.problems, path + ": viewers is not a list")
            return reg
        end if
        lib = ""
        if has(doc, "library") then
            if is_string(doc["library"]) then
                lib = doc["library"]
            end if
        end if
        added = 0
        for each v in doc.viewers
            problem = studio_viewers.viewer_problem(v)
            if problem != "" then
                reg.problems = append(reg.problems, path + ": " + problem)
            else
                reg.viewers = append(reg.viewers, studio_viewers._normalize(v, lib))
                added = added + 1
            end if
        end for
        reg.sources = append(reg.sources, { path: path, owner: lib, viewers: added })
        return reg
    end function

    ' What is wrong with a viewer declaration, or "" if nothing is. Written as one
    ' function so the validator and the error message cannot drift apart.
    function viewer_problem(v)
        if not is_record(v) then
            return "a viewer is not an object"
        end if
        if not has(v, "name") then
            return "a viewer has no name"
        end if
        if not is_string(v.name) then
            return "a viewer name is not a string"
        end if
        if v.name = "" then
            return "a viewer name is empty"
        end if
        if not has(v, "match") then
            return v.name + ": no match"
        end if
        if not is_record(v.match) then
            return v.name + ": match is not an object"
        end if
        if not has(v.match, "fields") then
            return v.name + ": match has no fields"
        end if
        if not is_array(v.match.fields) then
            return v.name + ": match fields is not a list"
        end if
        if count(v.match.fields) = 0 then
            return v.name + ": match fields is empty"
        end if
        for each fn in v.match.fields
            if not is_string(fn) then
                return v.name + ": a match field is not a string"
            end if
        end for
        if has(v, "detail") then
            if not is_array(v.detail) then
                return v.name + ": detail is not a list"
            end if
        end if
        if has(v, "layout") then
            if not is_array(v.layout) then
                return v.name + ": layout is not a list"
            end if
            for each b in v.layout
                bp = studio_viewers._block_problem(b)
                if bp != "" then
                    return v.name + ": " + bp
                end if
            end for
        end if
        return ""
    end function

    ' A layout block. Two kinds, and the second is the one that earns the whole
    ' mechanism:
    '
    '   fields    label/value pairs read straight off the detail capture.
    '   parallel  N arrays of equal length read ACROSS as one table. This is what
    '             structural dispatch cannot see: `coefficients`, `std_errors`,
    '             `t_values` and `p_values` are four lists to a shape-matcher and
    '             one table to a reader, and only the library that produced them
    '             knows which.
    function _block_problem(b)
        if not is_record(b) then
            return "a layout block is not an object"
        end if
        if not has(b, "block") then
            return "a layout block has no block kind"
        end if
        if b.block = "fields" then
            if not has(b, "items") then
                return "a fields block has no items"
            end if
            if not is_array(b.items) then
                return "a fields block's items is not a list"
            end if
            for each it in b.items
                if not is_record(it) then
                    return "a fields item is not an object"
                end if
                if not has(it, "field") then
                    return "a fields item has no field"
                end if
            end for
            return ""
        end if
        if b.block = "parallel" then
            if not has(b, "columns") then
                return "a parallel block has no columns"
            end if
            if not is_array(b.columns) then
                return "a parallel block's columns is not a list"
            end if
            if count(b.columns) = 0 then
                return "a parallel block has no columns"
            end if
            for each c in b.columns
                if not is_record(c) then
                    return "a parallel column is not an object"
                end if
                if not has(c, "title") then
                    return "a parallel column has no title"
                end if
                if not has(c, "field") then
                    if not has(c, "index") then
                        return "a parallel column has neither field nor index"
                    end if
                end if
            end for
            return ""
        end if
        return "unknown layout block \"" + b.block + "\""
    end function

    ' Fill in what a declaration left out, so every consumer reads the same shape
    ' and no renderer has to ask `has` about an optional key.
    function _normalize(v, lib)
        title = v.name
        if has(v, "title") then
            if is_string(v.title) then
                title = v.title
            end if
        end if
        kind = "record"
        if has(v.match, "kind") then
            if is_string(v.match.kind) then
                kind = v.match.kind
            end if
        end if
        vtype = ""
        if has(v.match, "type") then
            if is_string(v.match.type) then
                vtype = v.match.type
            end if
        end if
        detail = []
        if has(v, "detail") then
            for each d in v.detail
                if is_string(d) then
                    detail = append(detail, d)
                end if
            end for
        end if
        layout = []
        if has(v, "layout") then
            layout = v.layout
        end if
        ' A viewer that declares no detail still needs the fields its layout reads,
        ' or it would match and then render nothing. Deriving them is not a
        ' convenience: a hand-written detail list that drifts from the layout fails
        ' silently, as a blank row.
        detail = studio_viewers._with_layout_fields(detail, layout)
        return {
            name: v.name,
            owner: lib,
            title: title,
            kind: kind,
            type: vtype,
            fields: v.match.fields,
            detail: detail,
            layout: layout
        }
    end function

    function _with_layout_fields(detail, layout)
        seen = {}
        for each d in detail
            seen[d] = true
        end for
        for each b in layout
            if b.block = "fields" then
                for each it in b.items
                    if seen[it.field] = unknown then
                        seen[it.field] = true
                        detail = append(detail, it.field)
                    end if
                end for
            end if
            if b.block = "parallel" then
                for each c in b.columns
                    if has(c, "field") then
                        if seen[c.field] = unknown then
                            seen[c.field] = true
                            detail = append(detail, c.field)
                        end if
                    end if
                end for
            end if
        end for
        return detail
    end function

    ' ---- matching ----------------------------------------------------------

    ' The field names a captured variable is known to carry. For a record, the
    ' preview holds them as the first cell of each row — which also fixes the
    ' limit: a record with more fields than `studio_session.preview_rows()` has a
    ' truncated preview, so a viewer keyed on a field past that bound cannot match.
    ' That is a real edge and it is better surfaced than papered over; no stats
    ' object comes close to fifty fields.
    function descriptor_fields(v)
        out = []
        if not is_record(v) then
            return out
        end if
        if not has(v, "preview") then
            return out
        end if
        p = v.preview
        if not is_record(p) then
            return out
        end if
        if not has(p, "cols") then
            return out
        end if
        if count(p.cols) != 2 then
            return out
        end if
        if p.cols[0] != "field" then
            return out
        end if
        for each row in p.rows
            if count(row) > 0 then
                out = append(out, row[0])
            end if
        end for
        return out
    end function

    ' Does this viewer claim this variable? Kind first (cheapest and most
    ' discriminating), then the declared type when one was given, then every
    ' required field.
    function matches(spec, v)
        if not is_record(v) then
            return false
        end if
        if spec.kind != "" then
            if v.kind != spec.kind then
                return false
            end if
        end if
        if spec.type != "" then
            if not has(v, "type") then
                return false
            end if
            if v.type != spec.type then
                return false
            end if
        end if
        present = {}
        for each fn in studio_viewers.descriptor_fields(v)
            present[fn] = true
        end for
        for each want in spec.fields
            if present[want] = unknown then
                return false
            end if
        end for
        return true
    end function

    ' The registered viewer for a variable, or `nothing`. More required fields
    ' wins: a viewer for `{coefficients, r_squared, alpha}` is a statement about a
    ' narrower type than one for `{coefficients, r_squared}`, and the narrower
    ' reading is the one its author meant to be used.
    function best_for(reg, v)
        best = nothing
        score = -1
        for each spec in reg.viewers
            if studio_viewers.matches(spec, v) then
                if count(spec.fields) > score then
                    score = count(spec.fields)
                    best = spec
                end if
            end if
        end for
        return best
    end function

    ' ---- what the capture must fetch ---------------------------------------

    ' The recognition table the variable epilogue is compiled against: one entry
    ' per viewer, carrying only what the child needs — which fields prove a match
    ' and which fields to bring back. Ordered most-specific first so the generated
    ' code can take the first match and stop, giving the same winner as
    ' `best_for` without sorting inside generated gBASIC.
    function capture_rules(reg)
        rules = []
        for each spec in reg.viewers
            if spec.kind = "record" then
                if count(spec.detail) > 0 then
                    rules = append(rules, { name: spec.name, fields: spec.fields, detail: spec.detail })
                end if
            end if
        end for
        return studio_viewers._by_specificity(rules)
    end function

    function _by_specificity(rules)
        out = []
        left = rules
        while count(left) > 0
            pick = 0
            i = 1
            while i < count(left)
                if count(left[i].fields) > count(left[pick].fields) then
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

    ' ---- rendering ---------------------------------------------------------

    ' A registered viewer's display lines for one captured variable, at `indent`.
    ' Returns an EMPTY array when the capture carries no detail — a viewer that
    ' matched on shape but has no values to show must fall back to the structural
    ' preview rather than print a table of blanks. That happens for every result
    ' recorded before the viewer was registered, which is a normal state, not a
    ' fault.
    function render(spec, v, indent)
        out = []
        if not is_record(v) then
            return out
        end if
        if not has(v, "detail") then
            return out
        end if
        d = v.detail
        if not is_record(d) then
            return out
        end if
        if count(keys(d)) = 0 then
            return out
        end if
        out = append(out, indent + spec.title)
        for each b in spec.layout
            if b.block = "fields" then
                out = studio_viewers._render_fields(out, b, d, indent)
            end if
            if b.block = "parallel" then
                out = studio_viewers._render_parallel(out, b, d, indent)
            end if
        end for
        return out
    end function

    function _render_fields(out, b, d, indent)
        pairs = []
        wide = 0
        for each it in b.items
            if has(d, it.field) then
                label = it.field
                if has(it, "label") then
                    label = it.label
                end if
                pairs = append(pairs, { label: label, text: studio_viewers._cell(d[it.field], it) })
                if len(label) > wide then
                    wide = len(label)
                end if
            end if
        end for
        for each p in pairs
            out = append(out, indent + "  " + p.label + repeat(" ", wide - len(p.label)) + "  " + p.text)
        end for
        return out
    end function

    ' The parallel-array table. Its length is the SHORTEST column present, and it
    ' says so when the columns disagree: two arrays of different length are not a
    ' table, and padding one to the other's length would invent rows.
    function _render_parallel(out, b, d, indent)
        label = ""
        if has(b, "label") then
            label = b.label
        end if
        cols = []
        n = -1
        ragged = false
        for each c in b.columns
            if has(c, "field") then
                if not has(d, c.field) then
                    return out
                end if
                vals = d[c.field]
                if not is_array(vals) then
                    return out
                end if
                if n < 0 then
                    n = count(vals)
                else
                    if count(vals) != n then
                        ragged = true
                        if count(vals) < n then
                            n = count(vals)
                        end if
                    end if
                end if
            end if
            cols = append(cols, c)
        end for
        if n <= 0 then
            return out
        end if
        head = []
        for each c in cols
            head = append(head, c.title)
        end for
        rows = []
        i = 0
        while i < n
            row = []
            for each c in cols
                if has(c, "field") then
                    row = append(row, studio_viewers._cell(d[c.field][i], c))
                else
                    row = append(row, studio_viewers._index_cell(c, i))
                end if
            end for
            rows = append(rows, row)
            i = i + 1
        end while
        if label != "" then
            out = append(out, indent + "  " + label + " (" + n + "):")
        end if
        for each line in studio_viewers._table_lines(head, rows)
            out = append(out, indent + "    " + line)
        end for
        if ragged then
            out = append(out, indent + "    (columns of unequal length; shown to the shortest)")
        end if
        return out
    end function

    ' An index column names the row rather than reading a field: `term` numbers
    ' the coefficients, and a declaration may supply its own names.
    function _index_cell(c, i)
        if has(c, "names") then
            if is_array(c.names) then
                if i < count(c.names) then
                    return string(c.names[i])
                end if
            end if
        end if
        return string(i)
    end function

    ' Column-aligned plain text. The pane is monospaced (`studio_shell._mono`), so
    ' padding is alignment here and not decoration.
    function _table_lines(head, rows)
        wide = []
        for each h in head
            wide = append(wide, len(h))
        end for
        for each row in rows
            i = 0
            while i < count(row)
                if len(row[i]) > wide[i] then
                    wide[i] = len(row[i])
                end if
                i = i + 1
            end while
        end for
        out = [studio_viewers._pad_row(head, wide)]
        for each row in rows
            out = append(out, studio_viewers._pad_row(row, wide))
        end for
        return out
    end function

    ' The LAST cell is not padded. gBASIC has no right-trim, but more to the
    ' point a line of trailing spaces is invisible in the pane and loud in a
    ' golden — the diff would be about whitespace nobody can see.
    function _pad_row(row, wide)
        cells = []
        i = 0
        while i < count(row)
            cell = row[i]
            if i < count(row) - 1 then
                cell = cell + repeat(" ", wide[i] - len(cell))
            end if
            cells = append(cells, cell)
            i = i + 1
        end while
        return join(cells, "  ")
    end function

    ' One value as text, honouring a declared decimal `places`. A number shown to
    ' its full float expansion is unreadable in a coefficient table, and rounding
    ' it in the CAPTURE would destroy the value; rounding belongs here, in the
    ' viewer, where it is a presentation choice a declaration made.
    '
    ' Precision note, settled 2026-08-22: `string(number)` renders the shortest
    ' decimal that reads back as the same double, on every gBASIC from 0.1.0-rc3
    ' on. (Earlier releases emitted 6 significant digits; that skew once made a
    ' viewer golden interpreter-dependent, which is why this comment exists.)
    ' `places` is therefore purely a DISPLAY choice now — the bundled sidecar
    ' keeps `places: 4` because a coefficient table is read by eye, not because
    ' any interpreter would truncate it.
    ' `min` is the other half of the same idea, and it is not decoration: a
    ' p-value of 1e-7 rounded to four places prints as `0`, which reads as
    ' "exactly zero" — a claim the number does not make. Below the declared
    ' magnitude a value is shown as a BOUND instead.
    function _cell(value, spec)
        if is_number(value) then
            if has(spec, "min") then
                if is_number(spec["min"]) then
                    if value != 0 then
                        if abs(value) < spec["min"] then
                            lead = "<"
                            if value < 0 then
                                lead = ">-"
                            end if
                            return lead + string(spec["min"])
                        end if
                    end if
                end if
            end if
            if has(spec, "places") then
                if is_number(spec.places) then
                    return string(round(value, spec.places))
                end if
            end if
        end if
        if is_string(value) then
            return value
        end if
        return string(value)
    end function

    ' ---- summaries for tests and the status line ---------------------------

    function summary(reg)
        out = []
        out = append(out, "registry: " + count(reg.viewers) + " viewer(s) from " + count(reg.sources) + " source(s)")
        for each s in reg.sources
            out = append(out, "  " + s.owner + " <- " + s.viewers + " viewer(s)")
        end for
        for each spec in reg.viewers
            out = append(out, "  " + spec.name + " matches " + spec.kind + " with " + join(spec.fields, ", "))
        end for
        for each p in reg.problems
            out = append(out, "  problem: " + p)
        end for
        return out
    end function

end library
