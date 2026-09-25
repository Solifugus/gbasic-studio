' Headless driver for studio_sql — where one SQL statement ends and the next
' begins.
'
' The scanner is the foundation the whole `.sql` document type sits on: if it
' splits wrongly, every cell boundary, every result and every stable id is
' filed against the wrong text. So the cases here are the ones a naive split on
' `;` gets wrong, which is the entire reason this is a scanner and not a split.
'
' args: mode. Output is path-free by construction — nothing here touches disk.

function show(label, text)
  print "== " + label + " =="
  n = 0
  for each st in studio_sql.statements(text)
    print "  " + n + ": " + studio_sql.summary(st)
    print "     <" + st.text + ">"
    n = n + 1
  end for
  if n = 0 then
    print "  (no statements)"
  end if
end function

function show_prog(pg)
  print pg.text + "  (result bound to `" + pg.names[0] + "`)"
end function

' One cell is the one-element case of a whole file, which is the point: there
' is no second generator to keep in step with this one.
function pad(s, w)
  out = s
  while byte_count(out) < w
    out = out + " "
  end while
  return out
end function

function one(conn, sql, tier, pw)
  return studio_sql.file_program(conn, [{ sql: sql, tier: tier, line: 1, column: 1 }], studio_session.vars_prefix(), "", pw)
end function

function shown(m)
  return m.kind + " " + m.line + ":" + m.column
end function

program main(args)
  load studio_sql
  load studio_session

  mode = args[0]

  if mode = "scan" then
    show("a semicolon inside a string is not a terminator",
         "insert into t values ('a;b');\nselect 1;\n")

    show("nor inside a doubled-quote escape",
         "insert into t values ('it''s; fine');\nselect 2;\n")

    show("nor inside a line comment",
         "select 1;  -- drop table t;\nselect 2;\n")

    show("nor inside a block comment, which PostgreSQL NESTS",
         "/* outer /* inner ; */ still outer ; */\nselect 1;\n")

    show("nor inside a quoted identifier, in any of the three spellings",
         "select \"a;b\" from t;\nselect `c;d` from t;\nselect [e;f] from t;\n")

    show("nor inside a dollar-quoted body",
         "create function f() returns int as $$ begin return 1; end $$ language plpgsql;\nselect 1;\n")

    show("nor inside a TAGGED dollar-quoted body",
         "create function f() returns int as $body$ select 1; $body$ language sql;\nselect 2;\n")

    ' `$1` is a parameter, not an opening quote. Treating it as one would
    ' swallow the rest of the file into a single statement.
    show("but $1 is a parameter and opens nothing",
         "select * from t where id = $1;\nselect 2;\n")
  end if

  if mode = "edges" then
    show("a last statement with no terminator", "select 1;\nselect 2\n")

    show("a file that is only comments", "-- nothing here\n/* nor here */\n")

    show("an empty file", "")

    show("blank space between statements belongs to neither",
         "select 1;\n\n\n   \n\nselect 2;\n")

    show("an unterminated string swallows the rest, as the engine would",
         "select 'oops;\nselect 2;\n")

    show("and so does an unterminated block comment",
         "/* oops;\nselect 2;\n")

    show("a bare terminator is not a statement", ";;;\nselect 1;\n")

    show("a comment BEFORE a statement is not part of it",
         "-- a header\n-- two lines\nselect 1;\n")

    show("a comment AFTER one, on its own line, is not either",
         "select 1;\n-- a trailing note\n")
  end if

  ' The two things a .sql file says about itself, and the program a cell
  ' becomes. Both pure -- nothing here connects to anything.
  if mode = "gen" then
    print "== the connection a file names =="
    f = "-- a note\n-- @database app\n\nselect 1;\n"
    print "  named:        [" + studio_sql.directive(f, "database") + "]"
    print "  absent key:   [" + studio_sql.directive(f, "nope") + "]"
    print "  no directive: [" + studio_sql.directive("select 1;\n", "database") + "]"
    ' It goes through the SCANNER, so a directive is only a directive where a
    ' comment is a comment. Otherwise a row of data could redirect the file.
    print "  inside a string:       [" + studio_sql.directive("insert into t values ('-- @database evil');\n", "database") + "]"
    print "  inside a block comment:[" + studio_sql.directive("/* -- @database evil */\nselect 1;\n", "database") + "]"
    print "  a path as the value:   [" + studio_sql.directive("-- @database ../shared/app\n", "database") + "]"

    ' It comes back OPEN -- no `end program` -- because studio_session appends
    ' the shared variable epilogue first and closes it after. So there is no
    ' out-file here and nothing to read back: the query's rows come home the
    ' same way every gBASIC run's variables do.
    print "== the program one cell becomes =="
    sq = { driver: "sqlite", path: "/tmp/app.db" }
    print "-- a read goes through query --"
    show_prog(one(sq, "select * from t", "read", ""))
    print "-- a write goes through exec, which reports rows_affected --"
    show_prog(one(sq, "delete from t", "destructive", ""))
    ' The statement is the USER'S text going into a gBASIC string literal. An
    ' apostrophe in it would end that literal early and the rest would be read
    ' as code, so it goes in through `quote` and never hand-written marks.
    print "-- an apostrophe in the statement does not end the literal --"
    show_prog(one(sq, "select * from t where name = 'O''Brien'", "read", ""))

    print "== and for the other two drivers =="
    ' No credential appears in any of these. The password travels in the
    ' child's ENVIRONMENT and the program reads it back with `env` -- because
    ' this text is written to a scratch file, handed to a child, quoted by
    ' diagnostics, and printed into this very golden, which is four ways for a
    ' password to end up somewhere it cannot be taken back from.
    pgc = { driver: "pg", host: "db.example", port: 5432, database: "acme", user: "matthew" }
    print "-- pg, with a password --"
    show_prog(one(pgc, "select 1", "read", studio_sql.password_expr("pg", "a b'c")))
    print "-- pg, with none: peer auth over a unix socket needs no password --"
    show_prog(one({ driver: "pg", host: "/var/run/postgresql", database: "acme" }, "select 1", "read",
                  studio_sql.password_expr("pg", "")))
    print "-- odbc, a DSN whose credentials are in odbc.ini --"
    show_prog(one({ driver: "odbc", dsn: "ERP" }, "select 1", "read", studio_sql.password_expr("odbc", "")))
    print "-- odbc, a DSN with a user and a password --"
    show_prog(one({ driver: "odbc", dsn: "ERP", user: "app" }, "select 1", "read",
                  studio_sql.password_expr("odbc", "hunter2")))

    ' SQL Server through FreeTDS. `options` is passed through verbatim because
    ' the option matrix is per-driver and per-version -- and `ClientCharset` is
    ' the one that produces a plausible WRONG ANSWER rather than an error, so
    ' it is the user's line and not Studio's.
    print "-- odbc, SQL Server through FreeTDS --"
    mssql = { driver: "odbc", odbc_driver: "FreeTDS", server: "sql.example", port: 1433,
              database: "sales", user: "sa",
              options: { TDS_Version: "7.4", ClientCharset: "UTF-8" } }
    show_prog(one(mssql, "select 1", "read", studio_sql.password_expr("odbc", "hunter2")))
    print "-- and the same connection, shown without its password --"
    print "  " + studio_sql.odbc_string(mssql)

    ' A connection string Studio's field set cannot express. Used verbatim,
    ' with only the credential appended.
    print "-- odbc, a whole connection string as written --"
    show_prog(one({ driver: "odbc", connection_string: "Driver=SQLite3;Database=/tmp/x.db" },
                  "select 1", "read", studio_sql.password_expr("odbc", "")))

    print "== a password with a delimiter in it =="
    ' An ODBC connection string is semicolon-delimited, so a password carrying
    ' one ends its option early and the rest is read as more options. Braced
    ' only where it is NEEDED: a driver that took the braces literally would
    ' turn every correct password into a wrong one.
    for each pw in ["hunter2", "a b'c", "p;wd", "k=v", "  spaced  "]
        print "  " + pad(quote(pw), 14) + " -> pg " + studio_sql.password_expr("pg", pw)
        print "  " + pad("", 14) + "    odbc " + studio_sql.password_expr("odbc", pw)
    end for
    print "  and `}` is the one it cannot carry at all:"
    for each pw in ["hunter2", "p}wd", ""]
        print "    " + pad(quote(pw), 10) + " ok=" + studio_sql.odbc_password_ok(pw)
    end for

    print "== which drivers take a password at all =="
    for each d in ["sqlite", "pg", "odbc"]
        print "  " + pad(d, 7) + " " + studio_sql.wants_password(d)
    end for

    ' Run All is the SAME generator with more cells -- one connect, one close,
    ' and the statements between them. One connection is the entire point: a
    ' `begin` in the first cell and a `commit` in the last only mean anything
    ' to the session that ran the ones between, and a child per cell would roll
    ' the transaction back before the second statement arrived.
    print "== a whole file is the same program with more statements =="
    whole = studio_sql.file_program(sq, [
        { sql: "begin",                          tier: "write",       line: 1, column: 1 },
        { sql: "delete from t",                  tier: "destructive", line: 3, column: 1 },
        { sql: "insert into t values (1, 'a')",  tier: "write",       line: 5, column: 1 },
        { sql: "select * from t",                tier: "read",        line: 7, column: 1 },
        { sql: "commit",                         tier: "write",       line: 9, column: 1 }
    ], studio_session.vars_prefix(), "", "")
    print whole.text
    print "  names: " + join(whole.names, ", ")

    ' Each statement's line in the generated program is counted WHILE it is
    ' built, and it is what carries an engine error back to the cell it came
    ' from. Nothing catches: a failing statement ends the run where it failed,
    ' which for a schema rebuild is the behaviour you want.
    print "== and where each cell's own line went =="
    for each m in whole.marks
      print "    child " + m.child + " -> document " + m.line + ":" + m.column
    end for
    print "  the map that produces:"
    for each seg in studio_session.text_map(whole.marks).segments
      print "    " + seg.kind + " child " + seg.c_start + ".." + seg.c_end + " delta=" + seg.delta + " column=" + seg.column
    end for
    mp = studio_session.text_map(whole.marks)
    print "  child 4:11 -> " + shown(studio_session.map_line(mp, 4))
    print "  child 7:11 -> " + shown(studio_session.map_line(mp, 7))
    print "  child 3:1  -> " + shown(studio_session.map_line(mp, 3))
    print "  child 99:1 -> " + shown(studio_session.map_line(mp, 99))
  end if

  if mode = "verbs" then
    ' The verb decides how far a statement can be taken back, and the name is
    ' what lets a result stay attached to `create table customers` after the
    ' columns are edited. Neither is used to execute anything.
    print "== what each statement IS =="
    for each t in ["select * from t",
                   "  select 1",
                   "with x as (select 1) select * from x",
                   "explain select 1",
                   "pragma table_info(t)",
                   "insert into t values (1)",
                   "update t set a = 1 where id = 2",
                   "update t set a = 1",
                   "delete from t where id = 2",
                   "delete from t",
                   "DELETE FROM T",
                   "drop table t",
                   "truncate table t",
                   "create table customers (id int)",
                   "create table if not exists customers (id int)",
                   "create or replace view big as select 1",
                   "create unique index idx_a on customers (a)",
                   "alter table customers add column note text",
                   "create role auditor with login",
                   "grant select on customers to auditor",
                   "create table \"my table\" (id int)",
                   "begin",
                   "commit",
                   ""]
      v = studio_sql.verb_of(t)
      nm = "-"
      if studio_sql.name_of(v, t) != nothing then
        nm = studio_sql.name_of(v, t)
      end if
      print "  " + studio_sql.tier_of(v, t) + "  " + v + "  name=" + nm + "   <" + t + ">"
    end for

    print "== a `where` in a comment does not count as a filter =="
    d = "delete from t  -- where id = 1"
    print "  " + studio_sql.tier_of("delete", d) + "  <" + d + ">"
  end if
end program
