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

program main(args)
  load studio_sql

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
