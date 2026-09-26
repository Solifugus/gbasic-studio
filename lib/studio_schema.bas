' SPDX-License-Identifier: Apache-2.0
' Copyright 2026 Matthew C. Tedder. See LICENSE.

' studio_schema — STU-17: what the database says about itself.
'
' Three engines, three implementations, and that is not an accident of
' scheduling: `information_schema` is a dialect matrix that PostgreSQL and SQL
' Server each spell differently and SQLite does not have at all. gBASIC's odbc
' module normalises four CATALOG calls across every database with a driver
' (`odbc.tables`, `odbc.columns`, `odbc.primary_keys`, `odbc.foreign_keys`) and
' says outright that "friendly names belong to the library above this". This is
' that library.
'
' ---------------------------------------------------------------------------
' A SCHEMA READ IS A BLOCKING CHILD, NOT A RUN.
'
' Everything else that touches a database in Studio goes through
' `studio_session` -- a child, a poll loop, a durable result filed against a
' cell. A schema read has no cell to file against and nothing to keep, and
' threading it through the run machinery would mean a second meaning for
' `app.exec`, for Stop, and for every branch in `tick_run`.
'
' So it is `process.run` with a TIMEOUT, which is the shape `studio_git`
' already uses for exactly the same reason: a bounded, user-initiated question
' whose answer is wanted now. That makes the whole path synchronous and
' testable headlessly, against a real SQLite file, with no window and no timer.
'
' The cost is stated rather than hidden: a database that does not answer blocks
' the window until `timeout_s()` is up. That is why there IS a timeout and why
' it is short enough to wait out -- `timed_out` comes back as a named refusal
' naming the connection, not as a hang with nothing on screen.
'
' ---------------------------------------------------------------------------
' NOTHING HERE RUNS A STATEMENT THE USER CANNOT SEE.
'
' `tables_ask` and `columns_ask` return the exact text Studio is about to
' execute -- the SQL for sqlite and pg, the catalog CALL for odbc -- and the
' window shows it. Same rule the SQL builders follow one phase down: a window
' that told you about your database without saying what it asked would be the
' magic this project keeps refusing, and the question is worth reading anyway
' (`pragma table_info` and `information_schema.columns` are both things worth
' learning from the tool that used them).

library studio_schema

    load studio_sql

    ' How long a catalog read may take before it is a refusal instead of a wait.
    ' Longer than git's, because this one may cross a network and a first
    ' connection to a remote PostgreSQL is not instant; short enough that a
    ' wrong host does not look like a frozen window.
    function timeout_s()
        return 20
    end function

    ' The three drivers that reach a database at all. Not a list of engines:
    ' `odbc` is one entry here and many engines, because the CATALOG calls are
    ' the same whatever is behind the driver -- which is the whole reason they
    ' exist. `engine` matters to the SQL builders and not to this.
    function drivers()
        return ["sqlite", "pg", "odbc"]
    end function

    ' ---- what Studio is about to ask --------------------------------------

    ' The tables and views. Returns { ok, kind, text, why } where `kind` is
    ' "sql" or "catalog" and `text` is what the window shows and what the
    ' generated program contains, character for character.
    function tables_ask(conn)
        d = conn.driver
        if d = "sqlite" then
            ' `sqlite_%` is SQLite's own reserved prefix -- sqlite_sequence
            ' exists in any database with an AUTOINCREMENT column and is not
            ' something the user made.
            return studio_schema._ask("sql",
                "select name, type from sqlite_master" +
                " where type in ('table', 'view') and name not like 'sqlite_%'" +
                " order by type, name")
        end if
        if d = "pg" then
            ' The two catalogs PostgreSQL ships are excluded by name rather
            ' than by a `pg_%` pattern: a user's schema may legitimately start
            ' with those letters.
            return studio_schema._ask("sql",
                "select table_schema, table_name, table_type from information_schema.tables" +
                " where table_schema not in ('pg_catalog', 'information_schema')" +
                " order by table_schema, table_name")
        end if
        if d = "odbc" then
            ' `table: "%"` and not an omitted pattern. ODBC specifies that an
            ' absent argument matches anything, and SQLite, MariaDB and
            ' PostgreSQL all honour that -- but FreeTDS against SQL Server
            ' refuses `odbc.columns` with no table ("sp_columns expects
            ' parameter '@table_name'"). `%` says the same thing and is
            ' accepted everywhere, so it is what both calls use.
            return studio_schema._ask("catalog", "odbc.tables(db, { table: \"%\" })")
        end if
        return { ok: false, kind: "", text: "",
                 why: "Studio cannot read a schema through the " + d + " driver" }
    end function

    ' The columns of one table. `t` is a normalised table record from
    ' `normalise_tables`, so its qualifier came from the database itself.
    function columns_ask(conn, t)
        d = conn.driver
        if d = "sqlite" then
            ' A pragma takes no parameter, so the name is INLINED -- as a
            ' quoted identifier, with any embedded quote doubled. It came out
            ' of `sqlite_master` a moment ago rather than from a text field,
            ' which is what makes this defensible; the quoting is there because
            ' "defensible" is not the same as "safe", and a table really can be
            ' called `we"ird`.
            return studio_schema._ask("sql",
                "pragma table_info(" + studio_schema._ident(t.name) + ")")
        end if
        if d = "pg" then
            ' Parameters, because these two CAN be bound. `$1`/`$2` is
            ' PostgreSQL's placeholder; sqlite's is `?` and odbc's is `?`, and
            ' none of the three is reachable from a pragma.
            return studio_schema._ask("sql",
                "select column_name, data_type, is_nullable, ordinal_position" +
                " from information_schema.columns" +
                " where table_schema = $1 and table_name = $2" +
                " order by ordinal_position")
        end if
        if d = "odbc" then
            return studio_schema._ask("catalog",
                "odbc.columns(db, " + studio_schema._odbc_opts(t) + ")")
        end if
        return { ok: false, kind: "", text: "",
                 why: "Studio cannot read a schema through the " + d + " driver" }
    end function

    ' The parameters `columns_ask` needs bound, in order. Empty for the two
    ' that inline or call.
    function columns_params(conn, t)
        if conn.driver = "pg" then
            return [t.schema, t.name]
        end if
        return []
    end function

    ' Which columns are the primary key -- a SECOND question, because only one
    ' of the three answers it with the first.
    '
    ' This exists because the alternative is the plausible wrong answer this
    ' codebase keeps meeting. SQLite's `pragma table_info` reports `pk` for
    ' free, so without this a sqlite table showed `PK` and a PostgreSQL or ODBC
    ' one showed nothing -- which does not read as "Studio did not ask", it
    ' reads as "this table has no primary key". Costing a second round trip to
    ' avoid saying something false about somebody's schema is the right trade.
    '
    ' `ok: false` for sqlite, with a reason, because there is nothing to ask.
    function pk_ask(conn, t)
        d = conn.driver
        if d = "sqlite" then
            return { ok: false, kind: "", text: "",
                     why: "pragma table_info already reported it" }
        end if
        if d = "pg" then
            return studio_schema._ask("sql",
                "select kcu.column_name from information_schema.table_constraints tc" +
                " join information_schema.key_column_usage kcu" +
                " on kcu.constraint_name = tc.constraint_name" +
                " and kcu.table_schema = tc.table_schema" +
                " where tc.constraint_type = 'PRIMARY KEY'" +
                " and tc.table_schema = $1 and tc.table_name = $2" +
                " order by kcu.ordinal_position")
        end if
        if d = "odbc" then
            ' `table` is REQUIRED here -- upstream refuses the call without it
            ' rather than guessing, which is why the same options builder is
            ' reused: it always emits `table` and emits a qualifier only when
            ' the database gave one.
            return studio_schema._ask("catalog",
                "odbc.primary_keys(db, " + studio_schema._odbc_opts(t) + ")")
        end if
        return { ok: false, kind: "", text: "", why: "" }
    end function

    function pk_params(conn, t)
        if conn.driver = "pg" then
            return [t.schema, t.name]
        end if
        return []
    end function

    ' The key's column names, from whatever the driver called the column.
    function pk_names(rows, driver)
        out = []
        if not is_array(rows) then
            return out
        end if
        for each r in rows
            n = studio_schema._f(r, "column_name")
            if n = "" then
                n = studio_schema._f(r, "COLUMN_NAME")
            end if
            if n != "" then
                out = append(out, n)
            end if
        end for
        return out
    end function

    ' Mark the columns a key names. Separate from `normalise_columns` because
    ' it is a separate READ, and folding it in would mean that function had to
    ' know whether the second one happened.
    function mark_pk(columns, names)
        out = []
        for each c in columns
            c.pk = contains(names, c.name)
            out = append(out, c)
        end for
        return out
    end function

    ' The options record for an odbc catalog call, as source text.
    '
    ' A qualifier is included ONLY when it is a non-empty string, and that is
    ' the whole subtlety of this function. ODBC distinguishes a NULL pattern
    ' (match anything) from `""` (match only objects that HAVE no catalog or
    ' schema), and gBASIC's module passes an absent field as NULL and an empty
    ' string through as written. Normalising a missing qualifier to `""` would
    ' therefore ask the opposite question and return nothing at all on any
    ' database that qualifies its objects.
    '
    ' Which of the two carries the qualifier is not the same on every database
    ' either -- measured upstream across four drivers, SQLite has neither,
    ' MariaDB puts the database in TABLE_CAT, PostgreSQL and SQL Server use
    ' both -- so whatever came back from `odbc.tables` is what goes back in.
    function _odbc_opts(t)
        parts = []
        if studio_schema._nonempty(t, "catalog") then
            parts = append(parts, "catalog: " + quote(t.catalog))
        end if
        if studio_schema._nonempty(t, "schema") then
            parts = append(parts, "schema: " + quote(t.schema))
        end if
        parts = append(parts, "table: " + quote(t.name))
        return "{ " + join(parts, ", ") + " }"
    end function

    function _nonempty(rec, key)
        if not has(rec, key) then
            return false
        end if
        v = rec[key]
        if not is_string(v) then
            return false
        end if
        return v != ""
    end function

    function _ask(kind, text)
        return { ok: true, kind: kind, text: text, why: "" }
    end function

    ' A SQL quoted identifier: double quotes, any interior quote doubled.
    '
    ' ONE `replace` call, not a character walk: `split(text, "")` is refused by
    ' gBASIC ("split separator cannot be empty"), and one pass is also the
    ' correct semantics here -- a second pass would reach into the first
    ' pass's output and double the quotes it had just written, which is the
    ' same trap `studio_templates` avoids by substituting in one pass.
    function _ident(name)
        return "\"" + replace(name, "\"", "\"\"") + "\""
    end function

    ' ---- the program that asks it -----------------------------------------

    ' The whole program, ready to hand to an interpreter.
    '
    ' Built the same way `studio_sql.file_program` is and for the same reasons:
    ' the target goes through `studio_sql._target` so an ODBC connection is
    ' joined from its parts, and the password is an `env(...)` EXPRESSION that
    ' the text names and never contains. What is different is the end -- one
    ' `print encode(rows)` rather than a per-cell reporter, because there are
    ' no cells and the caller is waiting on the whole answer.
    ' `ask_program` and not `program`: `program` is a RESERVED WORD, which
    ' CLAUDE.md already records (it is why studio_sql's is `cell_program`) and
    ' which I walked into anyway. The failure is a parse error in a library, so
    ' nothing that loads it can run.
    function ask_program(conn, ask, params, pw)
        drv = conn.driver
        db = "db"
        lines = []
        lines = append(lines, "load " + drv)
        lines = append(lines, "program main(args)")
        lines = append(lines, "  " + db + " = " + drv + ".connect(" + studio_sql._target(conn, pw) + ")")
        if ask.kind = "catalog" then
            lines = append(lines, "  rows = " + ask.text)
        else
            lines = append(lines, "  rows = " + drv + ".query(" + db + ", " + quote(ask.text) + ", " +
                                  studio_schema._params_text(params) + ")")
        end if
        lines = append(lines, "  " + drv + ".close(" + db + ")")
        ' ONE line of output, and `encode` rather than printing the rows:
        ' whatever a driver put in a column -- a NUL, a newline, a name with a
        ' comma in it -- survives a round trip that a printed table would not.
        lines = append(lines, "  print encode(rows)")
        return join(lines, "\n") + "\nend program\n"
    end function

    function _params_text(params)
        if count(params) = 0 then
            return "[]"
        end if
        out = []
        for each p in params
            out = append(out, quote(p))
        end for
        return "[" + join(out, ", ") + "]"
    end function

    ' ---- what came back ----------------------------------------------------

    ' A table list, in Studio's own shape, from whatever the driver called it.
    '
    ' `{ catalog, schema, name, kind }` -- catalog and schema EMPTY where the
    ' database has no such thing, which is a statement about the database and
    ' not a missing value.
    function normalise_tables(rows, driver)
        out = []
        if not is_array(rows) then
            return out
        end if
        for each r in rows
            if driver = "sqlite" then
                out = append(out, studio_schema._table("", "",
                    studio_schema._f(r, "name"), studio_schema._f(r, "type")))
            end if
            if driver = "pg" then
                out = append(out, studio_schema._table("",
                    studio_schema._f(r, "table_schema"),
                    studio_schema._f(r, "table_name"),
                    studio_schema._kind(studio_schema._f(r, "table_type"))))
            end if
            if driver = "odbc" then
                ' The column names are the DRIVER'S, and upstream is explicit
                ' that this is deliberate: ODBC specifies them, so the raw
                ' names ARE the portable interface. Note `TABLE_SCHEM`, with no
                ' A -- that is ODBC's spelling and not a typo here.
                out = append(out, studio_schema._table(
                    studio_schema._f(r, "TABLE_CAT"),
                    studio_schema._f(r, "TABLE_SCHEM"),
                    studio_schema._f(r, "TABLE_NAME"),
                    studio_schema._kind(studio_schema._f(r, "TABLE_TYPE"))))
            end if
        end for
        return out
    end function

    function _table(cat, schema, name, kind)
        return { catalog: cat, schema: schema, name: name, kind: kind }
    end function

    ' "BASE TABLE" and "TABLE" both mean table; a view says so. Lower-cased and
    ' collapsed, because three spellings of one fact in a list the user reads is
    ' three things to tell apart for no gain.
    function _kind(raw)
        k = lower(raw)
        if k = "base table" then
            return "table"
        end if
        if k = "" then
            return "table"
        end if
        return k
    end function

    ' The columns of one table.
    '
    ' `nullable` is a STRING and not a boolean -- "yes", "no", or "" for
    ' "this driver will not say". The third case is real and is why the field
    ' cannot be a boolean: SQLite reports a primary key as nullable through
    ' ODBC, which is simply wrong, so Studio declines to state it there rather
    ' than passing on an answer it knows to be false. Through the NATIVE sqlite
    ' driver `pragma table_info` answers `notnull` correctly, so that path does
    ' say.
    function normalise_columns(rows, driver, engine)
        out = []
        if not is_array(rows) then
            return out
        end if
        i = 0
        for each r in rows
            i = i + 1
            if driver = "sqlite" then
                out = append(out, { name: studio_schema._f(r, "name"),
                                    type: studio_schema._f(r, "type"),
                                    nullable: studio_schema._yn(studio_schema._num(r, "notnull") = 0),
                                    pk: studio_schema._num(r, "pk") != 0,
                                    position: studio_schema._num(r, "cid") + 1 })
            end if
            if driver = "pg" then
                out = append(out, { name: studio_schema._f(r, "column_name"),
                                    type: studio_schema._f(r, "data_type"),
                                    nullable: lower(studio_schema._f(r, "is_nullable")),
                                    pk: false,
                                    position: studio_schema._num(r, "ordinal_position") })
            end if
            if driver = "odbc" then
                ' The NUMERIC `NULLABLE`, not `IS_NULLABLE`: psqlODBC returns
                ' nothing for the string one where the other three answer
                ' YES/NO, and all four populate the number.
                nul = ""
                if studio_schema._odbc_nullable_trusted(engine) then
                    nul = studio_schema._yn(studio_schema._num(r, "NULLABLE") != 0)
                end if
                out = append(out, { name: studio_schema._f(r, "COLUMN_NAME"),
                                    ' TYPE_NAME and not DATA_TYPE: the number is
                                    ' the driver's opinion and diverges across
                                    ' drivers for the same SQL type, so neither
                                    ' is portable and the readable one is the
                                    ' one worth showing.
                                    type: studio_schema._f(r, "TYPE_NAME"),
                                    nullable: nul,
                                    pk: false,
                                    position: studio_schema._num(r, "ORDINAL_POSITION") })
            end if
        end for
        return out
    end function

    ' Whether this engine's ODBC nullability can be repeated.
    '
    ' SQLite reports a PRIMARY KEY as `NULLABLE = 1`, which is simply wrong --
    ' so Studio declines to state it there rather than passing on an answer it
    ' knows to be false.
    '
    ' And an UNDECLARED engine is treated the same way, which is the part that
    ' had to be found by running it. `ui_sqlodbc` reaches SQLite through the
    ' SQLite3 driver and declares no `engine`, so the guard never fired and a
    ' primary key came back "nullable" -- exactly the statement it exists to
    ' prevent, from the exact connection it was written for. `odbc_driver` says
    ' "SQLite3" right there and reading it would have caught this one, but
    ' guessing the engine from the driver NAME is what `sql_engine` already
    ' refuses to do for the SQL builders, and it would be wrong the first time
    ' somebody points a generic driver at something else.
    '
    ' So the rule is the one already in force: an odbc connection that has not
    ' said which engine it reaches gets no claim it cannot vouch for. Declaring
    ' `"engine": "mssql"` is one line and turns it back on.
    function _odbc_nullable_trusted(engine)
        if engine = "" then
            return false
        end if
        if engine = "sqlite" then
            return false
        end if
        return true
    end function

    function _yn(b)
        if b then
            return "yes"
        end if
        return "no"
    end function

    ' A field, as a string, however absent it is. A driver that has no catalog
    ' returns `nothing` for one, and `nothing` is not "".
    function _f(rec, key)
        if not is_record(rec) then
            return ""
        end if
        if not has(rec, key) then
            return ""
        end if
        v = rec[key]
        if v = nothing then
            return ""
        end if
        if is_string(v) then
            return v
        end if
        return string(v)
    end function

    function _num(rec, key)
        if not is_record(rec) then
            return 0
        end if
        if not has(rec, key) then
            return 0
        end if
        v = rec[key]
        if is_number(v) then
            return v
        end if
        return 0
    end function

    ' ---- naming ------------------------------------------------------------

    ' How a table is written in SQL. The qualifier is included when there is
    ' one and left off when there is not -- `schema.table` built
    ' unconditionally produces `.orders` against SQLite and `nothing.orders`
    ' against MariaDB, which is the failure upstream measured and named.
    function qualified(t)
        if studio_schema._nonempty(t, "schema") then
            return t.schema + "." + t.name
        end if
        return t.name
    end function

    ' How a table is LISTED, which is a different question: the qualifier is
    ' worth seeing, and so is whether it is a view.
    function table_label(t)
        out = studio_schema.qualified(t)
        if t.kind != "table" then
            out = out + "  (" + t.kind + ")"
        end if
        return out
    end function

    ' One column, as a line. The three facts a person writing SQL wants, in the
    ' order they want them, and nothing said that the driver would not say.
    function column_label(c)
        out = c.name + "  " + c.type
        if c.pk then
            out = out + "  PK"
        end if
        if c.nullable = "no" then
            out = out + "  not null"
        end if
        if c.nullable = "" then
            ' Said out loud. An unreported nullability rendered as nothing is
            ' indistinguishable from "nullable", which is a claim Studio just
            ' declined to make.
            out = out + "  null?"
        end if
        return out
    end function

end library
