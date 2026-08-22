' studio_table — STU-8 the tabular tier: which results get a table, and where
' the rows come from (headless).
'
' Design §7 draws a line Studio has to hold: it must NOT assume every large
' structure is a table, and it must not pretend a sample is a dataset. So this
' answers two questions and keeps them apart.
'
'   1. WHAT IS TABULAR, AND HOW BIG. `tier` reads a captured variable's shape and
'      says none / modest / large. `modest` is a grid of labels' worth of cells
'      and needs no native component; `large` is the DataGrid (NAP-12), which is
'      the one justified native piece and a general gBASIC component, not a
'      Studio grid.
'
'   2. WHERE THE ROWS ARE. This is the honest part, and it is forced by the
'      replay model. A finished run's capture holds a bounded SAMPLE — fifty rows
'      of a hundred thousand — because the child that held the array exited. A
'      grid over that sample is a grid over a sample, and it says so, every time,
'      in the row count and in a standing note. Getting the rest means going back
'      and running the section again with an EXPORT epilogue, which writes the
'      whole variable to a file one encoded row per line.
'
' LAZY IS ABOUT DECODING, NOT ABOUT WIDGETS. GTK's part of virtualization is
' already handled: GtkColumnView realizes cell widgets only for visible rows, so
' a million-row model costs a few hundred widgets. The part Studio owns is that
' an exported table arrives as a million LINES OF JSON, and decoding all of them
' to show forty would cost more than the run that produced them. A row is decoded
' when a cell of it is asked for, and not before; `decodes` counts it, so the
' claim is measured rather than asserted.
'
' A source:
'   { kind, cols, n, known, sampled, lines, rows, cache, decodes, path }
'     n        the logical row count — what the variable HAD in the child
'     known    how many rows this source can actually serve
'     sampled  known < n: the grid is showing part of a larger table
library studio_table


    load studio_results

    function schema_version()
        return 1
    end function

    ' Above this many rows, the DataGrid. Below it, a grid of labels does the job
    ' with no native component (§7's two tiers). Five columns of five hundred rows
    ' is the "few thousand cells" the design puts the fork at.
    function modest_rows()
        return 500
    end function

    ' The export cap. Not a display limit — the DataGrid is virtualized and does
    ' not care — but a limit on how much of someone's data Studio will copy out of
    ' a run and leave on their disk without being asked twice.
    function export_cap()
        return 1000000
    end function

    ' How many rows the export epilogue buffers before writing. Whole-file text
    ' I/O is all gBASIC has, so a per-row append would be one syscall per row; a
    ' chunk is the difference between an export and a fork bomb.
    function export_chunk()
        return 500
    end function

    ' ---- what gets an affordance -------------------------------------------

    ' Which tier a captured variable belongs to. Decided from the SHAPE the
    ' epilogue reported and the count it saw in the child — not from how many rows
    ' the preview happens to carry, which is a fact about the capture and not
    ' about the data.
    '
    ' A record is not a table. It has fields, not rows, and the fields viewer
    ' (STU-5) or a registered one (STU-8A) reads it properly; putting it in a grid
    ' would turn one object into a two-column list of its own field names.
    function tier(v)
        if not is_record(v) then
            return "none"
        end if
        if not has(v, "category") then
            return "none"
        end if
        if v.category != "container" then
            return "none"
        end if
        if v.kind = "record" then
            return "none"
        end if
        n = studio_table.row_count(v)
        if n <= 0 then
            return "none"
        end if
        if n > studio_table.modest_rows() then
            return "large"
        end if
        return "modest"
    end function

    function row_count(v)
        if not has(v, "count") then
            return 0
        end if
        if not is_number(v.count) then
            return 0
        end if
        return v.count
    end function

    ' The affordances design §7 shows beside a variable. `Inspect` is always
    ' offered for a container; `Table` only for something recognizably tabular,
    ' which is the whole point of the sentence "Studio must not assume every large
    ' structure is a table".
    function offers(v)
        out = []
        if not is_record(v) then
            return out
        end if
        if has(v, "category") then
            if v.category = "container" then
                out = append(out, "Inspect")
            end if
        end if
        t = studio_table.tier(v)
        if t != "none" then
            out = append(out, "Table")
        end if
        return out
    end function

    ' One line describing what a table offer would open, for the pane and the
    ' status line. Says the tier out loud: a reader deciding whether to fetch
    ' 48,000 rows should know the grid they get is the virtualized one.
    function offer_line(v)
        t = studio_table.tier(v)
        if t = "none" then
            return ""
        end if
        n = studio_table.row_count(v)
        if t = "large" then
            return v.name + ": " + n + " rows (DataGrid)"
        end if
        return v.name + ": " + n + " rows (table)"
    end function

    ' ---- row sources -------------------------------------------------------

    function _empty_source()
        return { kind: "none", cols: [], n: 0, known: 0, sampled: false,
                 lines: [], rows: [], cache: {}, decodes: 0, path: "" }
    end function

    ' The rows Studio already has, straight off the capture. No file, no re-run,
    ' and usually not the whole table: this is what a grid can show the instant
    ' someone clicks.
    function from_preview(v)
        src = studio_table._empty_source()
        if studio_table.tier(v) = "none" then
            return src
        end if
        if not has(v, "preview") then
            return src
        end if
        p = v.preview
        src.kind = "preview"
        src.cols = p.cols
        src.rows = p.rows
        src.n = studio_table.row_count(v)
        src.known = count(p.rows)
        src.sampled = src.known < src.n
        return src
    end function

    ' An export file: a header line, then one encoded row per line. Only the
    ' header is decoded here — the rows are strings until someone looks at one.
    function from_export(text, path)
        src = studio_table._empty_source()
        if text = "" then
            return src
        end if
        lines = split(text, "\n")
        if count(lines) = 0 then
            return src
        end if
        h = try_decode(lines[0])
        if not h.ok then
            return src
        end if
        head = h.value
        if not is_record(head) then
            return src
        end if
        if not has(head, "cols") then
            return src
        end if
        body = []
        i = 1
        while i < count(lines)
            if lines[i] != "" then
                body = append(body, lines[i])
            end if
            i = i + 1
        end while
        src.kind = "export"
        src.path = path
        src.cols = head.cols
        src.lines = body
        src.n = head.n
        src.known = count(body)
        src.sampled = src.known < src.n
        return src
    end function

    ' ---- lazy row access ---------------------------------------------------

    ' Row `i`, decoding it if this is the first time anyone asked. Returns the
    ' source back with the row cached, in gBASIC's usual style — a function cannot
    ' mutate its caller's record, so the caller keeps the returned one or pays the
    ' decode again.
    '
    ' A row that will not decode comes back as a row of blanks rather than
    ' raising. One corrupt line in an export is a bad cell; a raise in a cell
    ' callback is a dead grid.
    function row_at(src, i)
        if i < 0 then
            return { src: src, row: [] }
        end if
        if i >= src.known then
            return { src: src, row: [] }
        end if
        if src.kind = "preview" then
            return { src: src, row: src.rows[i] }
        end if
        key = string(i)
        hit = src.cache[key]
        if hit != unknown then
            return { src: src, row: hit }
        end if
        r = try_decode(src.lines[i])
        row = []
        if r.ok then
            if is_array(r.value) then
                row = r.value
            end if
        end if
        if count(row) = 0 then
            for each c in src.cols
                row = append(row, "")
            end for
        end if
        src.cache[key] = row
        src.decodes = src.decodes + 1
        return { src: src, row: row }
    end function

    ' One cell as display text. The column is addressed by INDEX because that is
    ' what a grid's cell callback is handed; a row too short for it answers blank,
    ' which is the same answer the preview gives for a heterogeneous array.
    function cell(src, i, col)
        r = studio_table.row_at(src, i)
        if col < 0 then
            return { src: r.src, text: "" }
        end if
        if col >= count(r.row) then
            return { src: r.src, text: "" }
        end if
        return { src: r.src, text: string(r.row[col]) }
    end function

    ' ---- what the window says about a source -------------------------------

    ' The grid's title line. A sampled source states the shortfall in the same
    ' breath as the total: a grid captioned "48,291 rows" that can only show fifty
    ' of them is a lie told by omission, and it is the exact lie the replay model
    ' makes easy.
    function caption(name, src)
        if src.kind = "none" then
            return name + ": nothing to show"
        end if
        if not src.sampled then
            return name + ": " + src.n + " rows"
        end if
        return name + ": " + src.known + " of " + src.n + " rows (sampled — the run that made them has ended)"
    end function

    function summary(src)
        out = []
        out = append(out, "source: " + src.kind)
        out = append(out, "  columns: " + join(src.cols, " | "))
        out = append(out, "  rows: " + src.known + " of " + src.n)
        out = append(out, "  sampled: " + string(src.sampled))
        out = append(out, "  decoded so far: " + src.decodes)
        return out
    end function

    ' ---- the export --------------------------------------------------------

    function tables_dir(home)
        return home + "/tables"
    end function

    ' Where a variable's exported rows live. Keyed the same way results are — a
    ' readable tail plus a hash of the whole document path — so two documents
    ' sharing a basename do not overwrite each other's exports.
    function export_path(home, doc_path, name)
        return studio_table.tables_dir(home) + "/" + studio_results._key(doc_path) + "." + studio_table._safe(name) + ".rows"
    end function

    ' A variable name is a gBASIC identifier and cannot carry a path separator,
    ' but this is a filename built from a value that came back from a child
    ' process, and that is exactly the kind of assumption that is true until it
    ' is not.
    function _safe(name)
        out = ""
        i = 0
        while i < len(name)
            c = mid(name, i, 1)
            if studio_table._safe_char(c) then
                out = out + c
            else
                out = out + "_"
            end if
            i = i + 1
        end while
        if out = "" then
            return "var"
        end if
        return out
    end function

    function _safe_char(c)
        if c >= "a" then
            if c <= "z" then
                return true
            end if
        end if
        if c >= "A" then
            if c <= "Z" then
                return true
            end if
        end if
        if c >= "0" then
            if c <= "9" then
                return true
            end if
        end if
        return c = "_"
    end function

    ' Read an export back, or an empty source when there is none. A missing export
    ' is the normal state — nobody has asked for the full table yet.
    function read_export(home, doc_path, name)
        path = studio_table.export_path(home, doc_path, name)
        f(file) = path
        if not exists(f) then
            return studio_table._empty_source()
        end if
        return studio_table.from_export(read(f), path)
    end function

end library
