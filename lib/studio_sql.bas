' SPDX-License-Identifier: Apache-2.0
' Copyright 2026 Matthew C. Tedder. See LICENSE.

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

    ' ---- what the file says about itself ------------------------------------

    ' The value of a `-- @key value` directive, or "".
    '
    ' A `.sql` file names the connection it is meant to run against:
    '
    '     -- @database app
    '
    ' IN THE FILE, not in a picker, because opening somebody else's .sql should
    ' not silently point it at your database. A picker remembers what YOU chose
    ' last; a line in the file travels with the file and is visible in the diff.
    '
    ' Only `--` line comments are read, and only the first match. A directive
    ' inside a string or a block comment is not one: this goes through the same
    ' scanner as everything else rather than matching text, so `'-- @database'`
    ' in an insert is a value and not an instruction.
    function directive(text, key)
        want = "@" + key
        n = byte_count(text)
        i = 0
        while i < n
            skip = studio_sql._skip(text, i, n)
            if skip > i then
                two = false
                if byte_at(text, i) = 45 then
                    if i + 1 < n then
                        if byte_at(text, i + 1) = 45 then
                            two = true
                        end if
                    end if
                end if
                if two then
                    w = studio_sql._words(byte_slice(text, i + 2, skip - (i + 2)), 2)
                    ' `_words` drops the `@`, so the comment `-- @database app`
                    ' reads as ["database", "app"]. Compare on the key itself.
                    if count(w) >= 2 then
                        if w[0] = key then
                            return studio_sql._raw_after(text, i + 2, skip, key)
                        end if
                    end if
                end if
                i = skip
                continue
            end if
            i = i + 1
        end while
        return ""
    end function

    ' The rest of a `-- @key ...` comment after the key, trimmed. Taken from the
    ' RAW bytes rather than from `_words`, because a value can be a path with
    ' characters no word rule would keep.
    ' `lo`/`hi` and not `from`/`to`: TO is a reserved word in gBASIC (`print to
    ' error`), and a parameter named one is a parse error in a library nothing
    ' can then load.
    function _raw_after(text, lo, hi, key)
        body = byte_slice(text, lo, hi - lo)
        at = find(body, "@" + key)
        if at = nothing then
            return ""
        end if
        rest = byte_slice(body, at + byte_count(key) + 1, byte_count(body))
        return trim(rest)
    end function

    ' ---- the program a cell becomes -----------------------------------------

    ' The gBASIC program that runs a RUN of cells against ONE connection.
    '
    ' One function and not two, because "run this cell" is the one-cell case and
    ' nothing else about it differs: the same connect, the same per-statement
    ' line, the same close. Two generators would be two places for the quoting
    ' rule and the `query`/`exec` choice to drift apart, and the difference
    ' between them would be an argument count.
    '
    ' A run happens in a CHILD, like every other execution in Studio, and for
    ' the same reasons: a thirty-second query would otherwise freeze the window
    ' with no Stop button, and the child is where the poll loop, the timeout and
    ' Force Stop already live.
    '
    ' ONE connection for the whole run, which is the entire point of running
    ' more than one cell at a time -- a schema rebuild and a transaction are
    ' both statements that only mean anything to the session that ran the ones
    ' before them. Running each cell in its own child would connect N times and
    ' a `begin` in the first would be rolled back before the second arrived.
    '
    ' `quote` and never hand-written quotation marks. The statement is the
    ' user's text going into a gBASIC string literal, so an apostrophe in it
    ' would end the literal early and the rest would be read as code. Same rule
    ' the viewer registry follows for field names, and the same reason.
    '
    ' `query` for a read and `exec` otherwise: `exec` reports rows_affected,
    ' which is the only thing an `update` has to say. (A PostgreSQL
    ' `insert ... returning` therefore reports a count rather than its rows;
    ' that is a known gap, not a silent one.)
    '
    ' It comes back OPEN, without its `end program`, because
    ' `studio_session.run_program` closes it -- after appending the same
    ' variable epilogue every gBASIC run already gets. That sharing is the
    ' whole reason a query's rows reach the existing grid with no second
    ' mechanism: `rows` is an ordinary captured variable, and the results pane,
    ' the table offer and the DataGrid have never heard of SQL. An epilogue
    ' after `end program` would report nothing, silently, which is why the
    ' closing line is not written here.
    '
    ' Nothing catches. gBASIC cannot catch a raise, and a database error IS a
    ' raise, so a failing statement ends the run where it failed and the ones
    ' after it do not execute. That is the right behaviour to have fallen into:
    ' a schema rebuild whose third statement fails should not go on to the
    ' fourth, and the diagnostic names the line it stopped at.
    '
    '   cells   [{ sql, tier, line, column }] in FILE ORDER -- `line`/`column`
    '           being where the statement lives in the user's document, which
    '           is the only thing this needs them for
    '   pw      the gBASIC EXPRESSION that reads the credential, from
    '           `password_expr` -- `env("GBSTUDIO_DB_PASSWORD")`, or "" when
    '           there is no password. An expression and never a value: see
    '           `password_var` for why a generated program must not contain a
    '           credential.
    '   hidden  the name prefix the epilogue leaves OUT of what it reports. The
    '           connection handle takes it, or a user who wrote one statement
    '           gets three variables back, two of them Studio's own plumbing --
    '           and a `sqlite_connection` rendered as "(live)" is a thing they
    '           can neither use nor dismiss. PASSED rather than written out
    '           here: it belongs to `studio_session`, and a copy of it in this
    '           file is a copy that can drift into hiding nothing.
    '
    ' Returns { text, marks, names }:
    '   marks   [{ child, line, column }] -- which 1-based line of `text` each
    '           statement landed on, counted WHILE the program is built. A
    '           literal beside this shape would drift from it the first time a
    '           line is added, and it would then point every engine diagnostic
    '           at the wrong row of the user's file -- silently, which is the
    '           failure this codebase keeps meeting.
    '   names   what each statement's result is bound to. Two names and not
    '           one: `rows` for a query and `result` for an exec, because a
    '           DELETE returns no rows and a variables pane calling its
    '           `{command, rows_affected}` record "rows" would be saying it did.
    '           Reused across the run rather than numbered, so what the capture
    '           reports is the LAST query's rows and the LAST exec's count --
    '           a file of forty statements would otherwise hand the inspector
    '           forty variables, thirty-nine of which nobody asked about.
    function file_program(conn, cells, hidden, prelude, pw)
        drv = conn.driver
        db = hidden + "_db"
        lines = []
        lines = append(lines, "load " + drv)
        ' Between the `load` and the `program` line, because a function defined
        ' inside a program block AFTER the call to it is not hoisted -- and
        ' every statement below calls the reporter. studio_session writes that
        ' code; this only decides where it goes.
        if prelude != "" then
            for each pl in split(prelude, "\n")
                if pl != "" then
                    lines = append(lines, pl)
                end if
            end for
        end if
        lines = append(lines, "program main(args)")
        lines = append(lines, "  " + db + " = " + drv + ".connect(" + studio_sql._target(conn, pw) + ")")
        marks = []
        names = []
        i = 0
        for each c in cells
            name = studio_sql.result_name(c.tier)
            call = "exec"
            if c.tier = "read" then
                call = "query"
            end if
            marks = append(marks, { child: count(lines) + 1, line: c.line, column: c.column })
            names = append(names, name)
            lines = append(lines, "  " + name + " = " + drv + "." + call + "(" + db + ", " + quote(c.sql) + ", [])")
            ' Each cell reports itself, here, rather than the run reporting
            ' everything at the end: a statement that fails takes the program
            ' down, and a capture held to the end would lose every cell that
            ' had already succeeded.
            lines = append(lines, "  " + hidden + "_cell(" + i + ", " + quote(name) + ", " + name + ")")
            i = i + 1
        end for
        lines = append(lines, "  " + drv + ".close(" + db + ")")
        return { text: join(lines, "\n") + "\n", marks: marks, names: names }
    end function

    ' What a statement's result is bound to. Two names and not one: `rows` for
    ' a query and `result` for an exec, because a DELETE returns no rows and a
    ' variables pane calling its `{command, rows_affected}` record "rows" would
    ' be saying it did.
    '
    ' Reused across a run rather than numbered. Each cell REPORTS itself as it
    ' goes, so nothing is lost by the next statement rebinding the name -- and
    ' forty numbered variables would all still be live in the scope at the end
    ' for no one's benefit.
    function result_name(tier)
        if tier = "read" then
            return "rows"
        end if
        return "result"
    end function

    ' ---- credentials --------------------------------------------------------
    '
    ' A PASSWORD NEVER APPEARS IN A GENERATED PROGRAM. It travels in the child's
    ' ENVIRONMENT and the program reads it back with `env`.
    '
    ' That is not a preference about tidiness. The program Studio generates is
    ' WRITTEN TO A FILE in the scratch directory and is handed to a child whose
    ' command line and source anyone on the machine can read; it is the text a
    ' diagnostic quotes; and it is what the goldens in `tests/studio/` print,
    ' which is how a credential ends up committed to a git repository. A child's
    ' environment is none of those places -- `/proc/<pid>/environ` is readable
    ' only by its owner, and it is gone when the child is.
    '
    ' The program still SAYS where the password comes from: `env("...")` is
    ' right there in the text. Studio does not hide what it runs; it declines to
    ' write the secret down.
    '
    ' `process.start`'s `env` MERGES over the inherited environment, so carrying
    ' one more variable changes nothing else about the child's world -- which is
    ' also why the pinned `gbasic_path` and this have to be built into ONE
    ' record rather than each assigning `session.env`.
    function password_var()
        return "GBSTUDIO_DB_PASSWORD"
    end function

    ' Does this driver take a password at all?
    '
    ' SQLite is a FILE. There is nobody to authenticate to, and offering a
    ' credential slot for one would invite somebody to fill it in and then
    ' wonder why it changed nothing.
    function wants_password(driver)
        if driver = "sqlite" then
            return false
        end if
        return true
    end function

    ' The gBASIC expression that reads the credential, shaped for the driver.
    '
    ' It is handed the VALUE and does not keep it. `pg` takes a record, so the
    ' expression goes in as a field and no quoting arises; an ODBC connection
    ' string is semicolon-delimited, so a password containing `;` or `=` ends
    ' its option early and the rest is read as more options. Deciding that needs
    ' to look at the value. Embedding it does not, and this does not.
    function password_expr(driver, value)
        if value = "" then
            return ""
        end if
        e = "env(" + quote(studio_sql.password_var()) + ")"
        if driver != "odbc" then
            return e
        end if
        if studio_sql._needs_brace(value) then
            ' The ODBC convention for a value carrying delimiters. Applied only
            ' where it is NEEDED: braces are parsed by the driver manager, but a
            ' driver that took them literally would turn every correct password
            ' into a wrong one, and most passwords need nothing.
            return quote("{") + " + " + e + " + " + quote("}")
        end if
        return e
    end function

    function _needs_brace(value)
        for each ch in [";", "=", "{", "}"]
            if find(value, ch) != nothing then
                return true
            end if
        end for
        return trim(value) != value
    end function

    ' An ODBC password Studio can carry at all.
    '
    ' `}` is the one character a braced value cannot contain: ODBC's connection
    ' string grammar has no escape for it, so the value would be truncated and
    ' the remainder read as options. Refused by NAME rather than mangled --
    ' a wrong password reported as a wrong password is recoverable, and a
    ' connection string silently cut in half is not.
    function odbc_password_ok(value)
        if value = "" then
            return true
        end if
        return find(value, "}") = nothing
    end function

    ' ---- what `connect` is handed -------------------------------------------

    ' One line per driver, and the only place the three differ at all.
    '
    '   pw  the credential EXPRESSION from `password_expr`, or "" for none.
    '       "" is an ordinary case and not a failure: a unix-socket PostgreSQL
    '       with peer auth, a DSN whose credentials live in odbc.ini, and a
    '       ~/.pgpass all connect with no password at all, and the field is
    '       omitted entirely rather than sent empty.
    function _target(conn, pw)
        if conn.driver = "sqlite" then
            return quote(conn.path)
        end if
        if conn.driver = "odbc" then
            return studio_sql._odbc_target(conn, pw)
        end if
        ' pg takes a RECORD. Built as one rather than pasted into a connection
        ' string, so a password with a space or a quote in it is not a parsing
        ' problem -- and the credential is an expression, so it is not in the
        ' text to be parsed in the first place.
        parts = []
        for each k in ["host", "port", "database", "user"]
            if has(conn, k) then
                v = conn[k]
                if v != "" then
                    if is_string(v) then
                        parts = append(parts, k + ": " + quote(v))
                    else
                        ' A port is a NUMBER. Quoting it hands `pg.connect` a
                        ' string where it expects an integer, and the failure
                        ' would be about types rather than about the project
                        ' file that set it.
                        parts = append(parts, k + ": " + string(v))
                    end if
                end if
            end if
        end for
        if pw != "" then
            parts = append(parts, "password: " + pw)
        end if
        return "{ " + join(parts, ", ") + " }"
    end function

    ' The connection string ODBC takes, built from DECLARED FIELDS rather than
    ' pasted together by hand.
    '
    ' `odbc.connect` takes ONE string -- `DSN=warehouse;UID=app;PWD=secret`, or
    ' a driver with its own options. gBASIC's module says outright that it
    ' "deliberately knows nothing about DSN profiles or credential storage:
    ' where connection details come from is an application's policy, not the
    ' language's". This is that policy. The project file names the parts, Studio
    ' joins them, and the password is the one part that is in neither.
    '
    ' Built from fields and not typed as a string because a string is where the
    ' password would have to go: `"Driver=FreeTDS;...;PWD=hunter2"` in a
    ' committed file is exactly what `databases` exists to prevent, and there is
    ' no way to keep one field of a string out of it.
    '
    ' `options` is passed through VERBATIM, key by key. The option matrix is
    ' per-driver and per-version and a table of it here would be a table that
    ' goes stale -- `TDS_Version`, `ClientCharset`, `BoolsAsChar`, `Encrypt`,
    ' `TrustServerCertificate` are five of dozens. Studio adds NONE of them on
    ' your behalf, including the two that produce a plausible wrong answer
    ' rather than an error (FreeTDS without `ClientCharset=UTF-8` stores
    ' non-ASCII one byte per character; psqlODBC without `BoolsAsChar=0`
    ' misreports booleans). gBASIC's odbc module already warns about both AT
    ' CONNECT TIME, on stderr, which is where the Errors pane reads from -- so
    ' the warning reaches the user from the code that owns the knowledge, and a
    ' connection string carrying options nobody wrote stays the kind of magic
    ' this project keeps refusing to build.
    function _odbc_target(conn, pw)
        head = studio_sql.odbc_string(conn)
        if pw = "" then
            return quote(head)
        end if
        sep = ";"
        if head = "" then
            sep = ""
        end if
        return quote(head + sep + "PWD=") + " + " + pw
    end function

    ' The credential-free part of it, which is also what a window can SHOW: this
    ' is the whole of what a run will connect to, minus the one field that must
    ' not be displayed.
    '
    ' PWD goes LAST, appended by `_odbc_target`, so the generated line reads as
    ' a string with one expression on the end of it rather than a value spliced
    ' into the middle.
    function odbc_string(conn)
        parts = []
        raw = studio_sql._sfield(conn, "connection_string")
        if raw != "" then
            ' The escape hatch, for what the field set below cannot say. Used
            ' VERBATIM with only the credential appended -- a string that
            ' already carries its own UID or PWD is the user's business, and
            ' Studio second-guessing it would make the hatch useless.
            parts = append(parts, raw)
        else
            dsn = studio_sql._sfield(conn, "dsn")
            if dsn != "" then
                parts = append(parts, "DSN=" + dsn)
            end if
            drv = studio_sql._sfield(conn, "odbc_driver")
            if drv != "" then
                ' `odbc_driver` and not `driver`: `driver` already names which
                ' gBASIC module runs the statement, and one key meaning both
                ' "odbc" and "FreeTDS" is a key nobody can read.
                parts = append(parts, "Driver=" + drv)
            end if
            for each pair in [["server", "Server"], ["port", "Port"], ["database", "Database"]]
                v = studio_sql._vfield(conn, pair[0])
                if v != "" then
                    parts = append(parts, pair[1] + "=" + v)
                end if
            end for
            if has(conn, "options") then
                if is_record(conn.options) then
                    for each k in keys(conn.options)
                        parts = append(parts, k + "=" + studio_sql._vfield(conn.options, k))
                    end for
                end if
            end if
        end if
        u = studio_sql._sfield(conn, "user")
        if u != "" then
            parts = append(parts, "UID=" + u)
        end if
        return join(parts, ";")
    end function

    ' A field that has to be a STRING, or is treated as absent. `.gstudio.json`
    ' is hand-edited, so a number where a name belongs is a thing that happens,
    ' and it must not raise inside a redraw.
    function _sfield(conn, k)
        if not has(conn, k) then
            return ""
        end if
        v = conn[k]
        if is_string(v) then
            return v
        end if
        return ""
    end function

    ' The same, for a field that may legitimately be a number -- `port` is
    ' written as one, and an ODBC connection string is text either way.
    function _vfield(conn, k)
        if not has(conn, k) then
            return ""
        end if
        v = conn[k]
        if is_string(v) then
            return v
        end if
        if is_number(v) then
            return string(v)
        end if
        return ""
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
