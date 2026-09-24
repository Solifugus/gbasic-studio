' studio_sql.bas — where one SQL statement ends and the next begins.
'
' A `.sql` document is a notebook: each statement is a cell, runs on its own,
' and keeps its own history. Splitting the file into those cells is this
' library's whole job, and it is a SCANNER and not a parser. It knows where a
' semicolon is not a terminator — inside a string, inside a comment, inside a
' quoted identifier, inside a PostgreSQL dollar-quoted body — and it knows
' nothing else about SQL. A parser here would have to be three parsers (SQLite,
' PostgreSQL, whatever is behind ODBC) and would go wrong on the dialect
' features it had not met yet; a scanner is wrong only where the QUOTING rules
' differ, and they barely do.
'
' What it reads out beyond the boundaries is deliberately shallow: the leading
' verb, and the object name when the shape is `<verb> <noun> <name>`. Those two
' are not for executing anything. The verb decides whether a statement is
' rewindable (see `tier_of`), and the name is what lets `studio_sections` keep
' a result attached to `create table customers` after somebody edits the
' columns — a statement has no name of its own the way a gBASIC function does,
' and without one the only anchor left is the text itself.
library studio_sql

    function schema_version()
        return 1
    end function

    ' ---- the scanner --------------------------------------------------------

    ' Split `text` into statements.
    '
    ' Returns an array of records in source order:
    '   { text, start_offset, end_offset, start_line, start_column,
    '     end_line, end_column, verb, name, tier }
    '
    ' Offsets are BYTES and half-open, the same convention `studio_sections`
    ' and `source_outline` use. Lines and columns are 1-based, because that is
    ' what a diagnostic prints and what `section_at_position` is handed.
    '
    ' A run of whitespace and comments with no statement in it produces
    ' NOTHING. A file that is entirely a comment has no cells, which is the
    ' truth about it; inventing an empty one would put a row in the browser
    ' that cannot be run.
    function statements(text)
        out = []
        n = byte_count(text)
        i = 0
        line = 1
        col = 1
        ' Where the current statement began, and where its first non-blank
        ' byte was. The two differ because a statement is preceded by the
        ' whitespace and comments that follow the previous one, and those
        ' belong to nobody.
        s_off = -1
        s_line = 1
        s_col = 1
        while i < n
            b = byte_at(text, i)
            skip = studio_sql._skip(text, i, n)
            if skip > i then
                ' A comment or a quoted run. It cannot contain a terminator,
                ' and it does not start a statement either — a file that opens
                ' with a licence header starts at the first real byte after it.
                j = i
                while j < skip
                    if byte_at(text, j) = 10 then
                        line = line + 1
                        col = 1
                    else
                        col = col + 1
                    end if
                    j = j + 1
                end while
                i = skip
                continue
            end if
            if b = 59 then
                ' A terminator. The statement includes it.
                if s_off >= 0 then
                    out = append(out, studio_sql._make(text, s_off, i + 1, s_line, s_col))
                    s_off = -1
                end if
                col = col + 1
                i = i + 1
                continue
            end if
            blank = studio_sql._is_space(b)
            if not blank then
                if s_off < 0 then
                    s_off = i
                    s_line = line
                    s_col = col
                end if
            end if
            if b = 10 then
                line = line + 1
                col = 1
            else
                col = col + 1
            end if
            i = i + 1
        end while
        ' A last statement with no terminator. Real files end that way, and so
        ' does every file while it is being typed.
        if s_off >= 0 then
            out = append(out, studio_sql._make(text, s_off, n, s_line, s_col))
        end if
        return out
    end function

    ' The byte after the run starting at `i` when `i` opens a comment or a
    ' quoted region, or `i` itself when it does not. This is the entire
    ' dialect-sensitive part of the scanner.
    function _skip(text, i, n)
        b = byte_at(text, i)
        ' -- line comment
        if b = 45 then
            if i + 1 < n then
                if byte_at(text, i + 1) = 45 then
                    j = i + 2
                    while j < n
                        if byte_at(text, j) = 10 then
                            return j
                        end if
                        j = j + 1
                    end while
                    return n
                end if
            end if
            return i
        end if
        ' /* block comment */ — NESTED, because PostgreSQL nests them and
        ' treating `/* /* */ */` as closing early would swallow a terminator.
        if b = 47 then
            if i + 1 < n then
                if byte_at(text, i + 1) = 42 then
                    depth = 1
                    j = i + 2
                    while j < n
                        if j + 1 < n then
                            if byte_at(text, j) = 47 then
                                if byte_at(text, j + 1) = 42 then
                                    depth = depth + 1
                                    j = j + 2
                                    continue
                                end if
                            end if
                            if byte_at(text, j) = 42 then
                                if byte_at(text, j + 1) = 47 then
                                    depth = depth - 1
                                    j = j + 2
                                    if depth = 0 then
                                        return j
                                    end if
                                    continue
                                end if
                            end if
                        end if
                        j = j + 1
                    end while
                    return n
                end if
            end if
            return i
        end if
        ' 'string'  "identifier"  `identifier`
        '
        ' A doubled quote is an escaped one, and the naive rule gets that for
        ' free: the run closes and the next byte opens a new one, so the
        ' terminator inside stays hidden either way.
        if b = 39 then
            return studio_sql._closed(text, i, n, 39)
        end if
        if b = 34 then
            return studio_sql._closed(text, i, n, 34)
        end if
        if b = 96 then
            return studio_sql._closed(text, i, n, 96)
        end if
        ' [identifier] — SQL Server and SQLite. Not nested.
        if b = 91 then
            return studio_sql._closed(text, i, n, 93)
        end if
        ' $$ body $$ and $tag$ body $tag$ — PostgreSQL. The tag has to match,
        ' or `$1` in an ordinary parameter list would open a quote that never
        ' closes and the rest of the file would become one statement.
        if b = 36 then
            return studio_sql._dollar(text, i, n)
        end if
        return i
    end function

    ' The byte after a run opened at `i` and closed by `closer`.
    function _closed(text, i, n, closer)
        j = i + 1
        while j < n
            if byte_at(text, j) = closer then
                return j + 1
            end if
            j = j + 1
        end while
        ' Unterminated. Everything to the end is inside it, which is what the
        ' engine would say too.
        return n
    end function

    ' A PostgreSQL dollar-quoted run, or `i` when this `$` does not open one.
    function _dollar(text, i, n)
        ' The tag is [A-Za-z_][A-Za-z0-9_]* between two dollars, possibly empty.
        j = i + 1
        while j < n
            b = byte_at(text, j)
            if b = 36 then
                ' Found the closing dollar of the opening tag.
                ' `byte_slice` takes a LENGTH, not an end offset.
                tag = byte_slice(text, i, j + 1 - i)
                k = j + 1
                tn = byte_count(tag)
                while k + tn <= n
                    if byte_slice(text, k, tn) = tag then
                        return k + tn
                    end if
                    k = k + 1
                end while
                return n
            end if
            ok = studio_sql._tag_byte(b, j = i + 1)
            if not ok then
                ' `$1`, `$` on its own — not a dollar quote.
                return i
            end if
            j = j + 1
        end while
        return i
    end function

    function _tag_byte(b, first)
        if b = 95 then
            return true
        end if
        if b >= 65 then
            if b <= 90 then
                return true
            end if
        end if
        if b >= 97 then
            if b <= 122 then
                return true
            end if
        end if
        if first then
            return false
        end if
        if b >= 48 then
            if b <= 57 then
                return true
            end if
        end if
        return false
    end function

    function _is_space(b)
        if b = 32 then
            return true
        end if
        if b = 9 then
            return true
        end if
        if b = 10 then
            return true
        end if
        return b = 13
    end function

    ' One statement record, with the trailing blank bytes trimmed off the end
    ' so `end_offset` lands on the terminator rather than on the newline after
    ' it. Studio marks the gutter and resolves the caret by offset, and a
    ' section that reaches into the blank line below it claims a caret sitting
    ' in the gap between two cells.
    function _make(text, start_off, end_off, s_line, s_col)
        e = end_off
        trimming = true
        while trimming
            if e <= start_off then
                trimming = false
            else
                blank = studio_sql._is_space(byte_at(text, e - 1))
                if blank then
                    e = e - 1
                else
                    trimming = false
                end if
            end if
        end while
        ' The end position is computed from the TRIMMED end, not taken from
        ' where the scanner happened to be. Otherwise a statement's reported
        ' range runs past its own text into the blank line after it, and a
        ' record whose offsets and line numbers disagree is a trap for whoever
        ' reads it next. Like `end_offset`, it is one PAST the last byte.
        ln = s_line
        cl = s_col
        i = start_off
        while i < e
            if byte_at(text, i) = 10 then
                ln = ln + 1
                cl = 1
            else
                cl = cl + 1
            end if
            i = i + 1
        end while
        return studio_sql._record(text, start_off, e, s_line, s_col, ln, cl)
    end function

    function _record(text, start_off, end_off, s_line, s_col, e_line, e_col)
        body = byte_slice(text, start_off, end_off - start_off)
        verb = studio_sql.verb_of(body)
        return {
            text: body,
            start_offset: start_off,
            end_offset: end_off,
            start_line: s_line,
            start_column: s_col,
            end_line: e_line,
            end_column: e_col,
            verb: verb,
            name: studio_sql.name_of(verb, body),
            tier: studio_sql.tier_of(verb, body)
        }
    end function

    ' ---- what a statement IS ------------------------------------------------

    ' The leading keyword, lower-cased, with comments and blank space skipped.
    ' "" when there is no word in it at all.
    function verb_of(text)
        w = studio_sql._words(text, 1)
        if count(w) = 0 then
            return ""
        end if
        return w[0]
    end function

    ' Up to `want` leading words, lower-cased, skipping comments. Used for the
    ' verb and for the `<verb> <noun> <name>` shapes below; it stops early, so
    ' a long statement is not walked to read three words off the front.
    function _words(text, want)
        out = []
        n = byte_count(text)
        i = 0
        while i < n
            b = byte_at(text, i)
            skip = studio_sql._skip(text, i, n)
            if skip > i then
                ' A comment is skipped; a quoted identifier IS a word, and is
                ' taken whole so `create table "my table"` reads as one.
                quoted = false
                if b = 34 then
                    quoted = true
                end if
                if b = 96 then
                    quoted = true
                end if
                if b = 91 then
                    quoted = true
                end if
                if quoted then
                    out = append(out, lower(byte_slice(text, i + 1, skip - 1 - (i + 1))))
                    if count(out) >= want then
                        return out
                    end if
                end if
                i = skip
                continue
            end if
            word = studio_sql._word_byte(b)
            if word then
                j = studio_sql._word_end(text, i, n)
                out = append(out, lower(byte_slice(text, i, j - i)))
                if count(out) >= want then
                    return out
                end if
                i = j
                continue
            end if
            i = i + 1
        end while
        return out
    end function

    function _word_end(text, i, n)
        j = i
        while j < n
            if not studio_sql._word_byte(byte_at(text, j)) then
                return j
            end if
            j = j + 1
        end while
        return n
    end function

    ' A word byte: letters, digits, underscore, and `.` so a schema-qualified
    ' name reads as one word.
    function _word_byte(b)
        if b = 95 then
            return true
        end if
        if b = 46 then
            return true
        end if
        if b >= 48 then
            if b <= 57 then
                return true
            end if
        end if
        if b >= 65 then
            if b <= 90 then
                return true
            end if
        end if
        if b >= 97 then
            if b <= 122 then
                return true
            end if
        end if
        return false
    end function

    ' The object a statement is about, or `nothing`.
    '
    ' Only the `<verb> <noun> <name>` shapes, which is most of DDL, and only to
    ' give `studio_sections` something stable to re-match on. `nothing` is a
    ' perfectly good answer: a `select` is anchored by its text, like the
    ' statement runs the shell already has.
    '
    ' `if not exists` and `or replace` are skipped because they sit exactly
    ' where the name would be and are extremely common.
    function name_of(verb, text)
        if not studio_sql._names(verb) then
            return nothing
        end if
        w = studio_sql._words(text, 8)
        i = 1
        n = count(w)
        while i < n
            t = w[i]
            if studio_sql._skippable(t) then
                i = i + 1
                continue
            end if
            if studio_sql._noun(t) then
                i = i + 1
                continue
            end if
            return t
        end while
        return nothing
    end function

    ' The verbs whose second-or-third word is an object name.
    function _names(verb)
        if verb = "create" then
            return true
        end if
        if verb = "alter" then
            return true
        end if
        if verb = "drop" then
            return true
        end if
        if verb = "truncate" then
            return true
        end if
        if verb = "comment" then
            return true
        end if
        return false
    end function

    function _skippable(t)
        if t = "if" then
            return true
        end if
        if t = "not" then
            return true
        end if
        if t = "exists" then
            return true
        end if
        if t = "or" then
            return true
        end if
        if t = "replace" then
            return true
        end if
        if t = "temp" then
            return true
        end if
        if t = "temporary" then
            return true
        end if
        if t = "unique" then
            return true
        end if
        if t = "materialized" then
            return true
        end if
        return t = "on"
    end function

    function _noun(t)
        if t = "table" then
            return true
        end if
        if t = "view" then
            return true
        end if
        if t = "index" then
            return true
        end if
        if t = "trigger" then
            return true
        end if
        if t = "schema" then
            return true
        end if
        if t = "database" then
            return true
        end if
        if t = "function" then
            return true
        end if
        if t = "procedure" then
            return true
        end if
        if t = "sequence" then
            return true
        end if
        if t = "role" then
            return true
        end if
        if t = "user" then
            return true
        end if
        return t = "column"
    end function

    ' ---- how far a statement can be taken back ------------------------------

    ' "read" | "write" | "destructive", assigned by REVERSIBILITY, which is the
    ' same rule the permission tiers use: not by how alarming the word looks.
    '
    ' `destructive` is the set Studio ARMS — one click says what it is about to
    ' do, a second does it. It is deliberately small and deliberately includes
    ' `delete` with no `where`, because that is the one that reads as ordinary
    ' and empties a table.
    function tier_of(verb, text)
        if verb = "" then
            return "read"
        end if
        if verb = "select" then
            return "read"
        end if
        if verb = "with" then
            ' A CTE usually ends in a select, and in PostgreSQL it can end in a
            ' delete. Reported as a write rather than guessed at: over-stating
            ' what a statement does costs a reader a moment, and under-stating
            ' it costs them a table.
            return "write"
        end if
        if verb = "explain" then
            return "read"
        end if
        if verb = "show" then
            return "read"
        end if
        if verb = "pragma" then
            return "read"
        end if
        if verb = "describe" then
            return "read"
        end if
        if verb = "values" then
            return "read"
        end if
        if verb = "drop" then
            return "destructive"
        end if
        if verb = "truncate" then
            return "destructive"
        end if
        if verb = "delete" then
            bare = studio_sql._unfiltered(text)
            if bare then
                return "destructive"
            end if
            return "write"
        end if
        if verb = "update" then
            bare = studio_sql._unfiltered(text)
            if bare then
                return "destructive"
            end if
            return "write"
        end if
        return "write"
    end function

    ' Whether a statement has no `where` in it. Word-wise and comment-aware, so
    ' `-- where` in a comment and `wherever` in an identifier both fail to
    ' count. A subquery's `where` makes it look filtered when the outer
    ' statement is not; that errs toward NOT arming, which is why the arm is a
    ' safety net and the tier is not a permission.
    function _unfiltered(text)
        for each w in studio_sql._words(text, 4096)
            if w = "where" then
                return false
            end if
        end for
        return true
    end function

    ' ---- reporting ----------------------------------------------------------

    ' A deterministic one-line summary of a statement, for the goldens.
    function summary(st)
        nm = "-"
        if st.name != nothing then
            nm = st.name
        end if
        return st.verb + " " + nm + " [" + st.tier + "] " + st.start_line + ":" + st.start_column + "-" + st.end_line + ":" + st.end_column
    end function

end library
