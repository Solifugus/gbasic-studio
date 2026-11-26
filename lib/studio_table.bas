' SPDX-License-Identifier: Apache-2.0
' Copyright 2026 Matthew C. Tedder. See LICENSE.

' studio_table — STU-8 the tabular tier: which results get a table, and where
' the rows come from (headless).
'
' Design §7 draws a line Studio has to hold: it must NOT assume every large
' structure is a table, and it must not pretend a sample is a dataset. So this
' answers two questions and keeps them apart.
'
'   1. WHAT IS TABULAR, AND HOW BIG. `tier` reads a captured variable's shape and
'      says none / modest / large. The fork was a WIDGET under GTK (labels
'      below `modest_rows`, the DataGrid above); under Qt every grid is a
'      `table to ask`, so only `none` versus the rest decides anything now.
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

    ' The line between design §7's two tiers. Under GTK it decided the WIDGET --
    ' a grid of labels below it, the virtualized DataGrid above. Under Qt every
    ' grid is a `table to ask`, whose cost is the viewport, so nothing on screen
    ' forks on it any more; `tier` still reports it, and `offer_line` no longer
    ' says it, because "(DataGrid)" named a widget that does not exist.
    function modest_rows()
        return 500
    end function

    ' The export cap. Not a display limit — the grid asks for visible cells only
    ' and does not care — but a limit on how much of someone's data Studio will copy out of
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
    ' status line: the variable and how many rows the RUN saw -- the total, not
    ' what the capture kept, since that is what a reader decides to fetch on.
    function offer_line(v)
        t = studio_table.tier(v)
        if t = "none" then
            return ""
        end if
        n = studio_table.row_count(v)
        if n = 1 then
            return v.name + ": 1 row"
        end if
        return v.name + ": " + n + " rows"
    end function

    ' ---- row sources -------------------------------------------------------

    ' What an export is an export OF. Without this, an export is keyed only by
    ' document and variable name — so editing the code, re-running, and opening
    ' the table again would serve rows produced by source that no longer exists,
    ' captioned with their own row count and no hint that they describe a
    ' different program. That is the same class of dishonesty as a sampled grid
    ' captioned with a total, and this architecture makes it just as easy.
    '
    ' The section's content fingerprint and the branch, which together are what a
    ' result already records about itself (STU-3 anchors, STU-7 branches).
    function stamp_for(fingerprint, branch)
        return fingerprint + "|" + branch
    end function

    ' `order` is the row a grid position shows, or `nothing` for the order the
    ' run made them in -- see `sort_rows`.
    function _empty_source()
        return { kind: "none", cols: [], n: 0, known: 0, sampled: false,
                 rows: [], decodes: 0, reads: 0, path: "", stamp: "",
                 offsets: [], size: 0, blocks: {}, order: [] }
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

    ' How many rows one read of an export brings in, and how many such blocks a
    ' source keeps. Together they bound what a grid holds: 8 x 256 rows of
    ' text, whatever the table's size -- the user's rule (2026-11-26) that a
    ' display never pulls an enormous dataset into memory at once.
    function export_block()
        return 256
    end function

    function block_cache()
        return 8
    end function

    ' AN EXPORT ON DISK, OPENED WITHOUT READING IT. One streamed pass (`for
    ' each line in f`, which holds only the longest line) reads the header and
    ' notes the BYTE offset of every `export_block()`-th row; rows are then read
    ' a block at a time with `read_at` when a grid asks for them. The offsets are
    ' bytes, summed with `byte_count`, never `len`, which counts codepoints. The
    ' export is Studio's own file, written with "\n" line ends.
    '
    ' It used to `read` the whole file and split it: rows were decoded lazily,
    ' but every byte of a million-row export sat in memory.
    function from_export_file(path)
        src = studio_table._empty_source()
        f{file} = path
        if not exists(f) then
            return src
        end if
        k = studio_table.export_block()
        offsets = []
        pos = 0
        known = 0
        head = nothing
        for each line, at in f
            if at = 0 then
                h = try_decode(line)
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
            else
                if line != "" then
                    if known - floor(known / k) * k = 0 then
                        offsets = append(offsets, pos)
                    end if
                    known = known + 1
                end if
            end if
            pos = pos + byte_count(line) + 1
        end for
        if head = nothing then
            return src
        end if
        src.kind = "export"
        src.path = path
        if has(head, "stamp") then
            if is_string(head.stamp) then
                src.stamp = head.stamp
            end if
        end if
        src.cols = head.cols
        src.n = head.n
        src.known = known
        src.sampled = src.known < src.n
        src.offsets = offsets
        src.size = pos
        return src
    end function

    ' Block `b`'s rows as text, read from disk.
    function _read_block(src, b)
        start = src.offsets[b]
        upto = src.size
        if b + 1 < count(src.offsets) then
            upto = src.offsets[b + 1]
        end if
        f{file} = src.path
        out = []
        for each line in split(read_at(f, start, upto - start), "\n")
            if line != "" then
                out = append(out, line)
            end if
        end for
        return out
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
        k = studio_table.export_block()
        b = floor(i / k)
        bkey = string(b)
        blk = src.blocks[bkey]
        if is_unknown(blk) or blk = nothing then
            ' A block not held: read it, and let the oldest go if that makes
            ' more than `block_cache()`. Scrolling reads ahead a block at a time.
            blk = { lines: studio_table._read_block(src, b), rows: {} }
            src.reads = src.reads + 1
            src.order = append(src.order, bkey)
            if count(src.order) > studio_table.block_cache() then
                src.blocks[src.order[0]] = nothing
                keep = []
                j = 1
                while j < count(src.order)
                    keep = append(keep, src.order[j])
                    j = j + 1
                end while
                src.order = keep
            end if
        end if
        key = string(i - b * k)
        hit = blk.rows[key]
        if not is_unknown(hit) then
            return { src: src, row: hit }
        end if
        text = ""
        if i - b * k < count(blk.lines) then
            text = blk.lines[i - b * k]
        end if
        r = try_decode(text)
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
        blk.rows[key] = row
        src.blocks[bkey] = blk
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

    ' Whether text is a plain decimal number: an optional sign, digits with at
    ' most one point, and an optional exponent. CHECKED, not caught -- `number`
    ' would raise on anything else, and a probe written as a raise is a probe
    ' that hides a different raise.
    function _is_number_text(t)
        u = trim(t)
        n = len(u)
        if n = 0 then
            return false
        end if
        i = 0
        c = mid(u, 0, 1)
        if contains(["-", "+"], c) then
            i = 1
        end if
        digits = 0
        point = false
        while i < n
            c = mid(u, i, 1)
            if studio_table._is_digit(c) then
                digits = digits + 1
            else
                if c = "." then
                    if point then
                        return false
                    end if
                    point = true
                else
                    if lower(c) = "e" then
                        if digits = 0 then
                            return false
                        end if
                        return studio_table._is_exponent(u, i + 1)
                    end if
                    return false
                end if
            end if
            i = i + 1
        end while
        return digits > 0
    end function

    function _is_exponent(u, at)
        n = len(u)
        i = at
        if i < n then
            if contains(["-", "+"], mid(u, i, 1)) then
                i = i + 1
            end if
        end if
        seen = 0
        while i < n
            if not studio_table._is_digit(mid(u, i, 1)) then
                return false
            end if
            seen = seen + 1
            i = i + 1
        end while
        return seen > 0
    end function

    function _is_digit(c)
        return contains(["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"], c)
    end function

    ' WHICH COLUMNS HOLD NUMBERS, for the grid to right-align them (gBASIC
    ' §0.35's `align:`). The same rule the numeric sort uses -- every non-empty
    ' cell reads as a number -- decided over the first `align_probe()` rows
    ' rather than all of them: an export can be a million rows, and a wrong
    ' guess costs where text sits in a cell, never what it says. A column with
    ' nothing in it at all is left as text.
    function align_probe()
        return 200
    end function

    function numeric_columns(src)
        out = []
        n = src.known
        if n > studio_table.align_probe() then
            n = studio_table.align_probe()
        end if
        col = 0
        while col < count(src.cols)
            numeric = true
            seen = 0
            i = 0
            while i < n
                r = studio_table.cell(src, i, col)
                src = r.src
                if r.text != "" then
                    seen += 1
                    if not studio_table._is_number_text(r.text) then
                        numeric = false
                    end if
                end if
                i += 1
            end while
            if seen = 0 then
                numeric = false
            end if
            out = append(out, numeric)
            col += 1
        end while
        return out
    end function

    ' ---- what the window says about a source -------------------------------

    ' The second line of the grid window: what a SAMPLE means and what to do
    ' about it, or "" for a whole table. The caption states the shortfall;
    ' this says why there is one and where the rest is.
    function caption_note(src)
        if src.kind = "none" then
            return ""
        end if
        if not src.sampled then
            return ""
        end if
        return "Showing the " + string(src.known) + " rows the run kept. Fetch all rows, in the Tables pane, runs the section again to show all " + string(src.n) + "."
    end function

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
        f{file} = path
        if not exists(f) then
            return studio_table._empty_source()
        end if
        return studio_table.from_export_file(path)
    end function

    ' The export for a variable, but only if it is an export of THIS run's code on
    ' THIS branch. A stamp that does not match is not an error and not a thing to
    ' repair silently — it is an export of something else, and the answer is to
    ' fall back to the sample the current result actually carries.
    '
    ' An unstamped export (written before stamps existed) is treated as
    ' mismatched. Assuming it belongs would be assuming exactly what cannot be
    ' checked.
    function matching_export(home, doc_path, name, stamp)
        src = studio_table.read_export(home, doc_path, name)
        if src.kind = "none" then
            return src
        end if
        if src.stamp = stamp then
            return src
        end if
        return studio_table._empty_source()
    end function

end library
