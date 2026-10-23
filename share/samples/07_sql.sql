-- 07 — SQL: a .sql file is a notebook of statements.
--
-- Each statement is a cell. The line below names which database this file
-- runs against; `.gstudio.json` in this folder says that `samples` is a
-- SQLite file, samples.db, in this folder (created the first time).
--
-- Try this:
--   1. Press "Run All" at the bottom: every statement runs, top to bottom, in
--      one connection.
--   2. Put the cursor on the final `select` and Run Section: just that one.
--      Its rows appear in the Tables pane.
--   3. Press "Schema…" to see the table, and the exact question Studio asked
--      the database to find out about it.
--   4. Press "Insert SQL…" for statements Studio can write for you.

-- @database samples

drop table if exists planets;

create table planets (name text primary key, moons integer, ringed integer);

insert into planets (name, moons, ringed) values
    ('Mercury', 0, 0), ('Venus', 0, 0), ('Earth', 1, 0), ('Mars', 2, 0),
    ('Jupiter', 95, 1), ('Saturn', 146, 1), ('Uranus', 28, 1), ('Neptune', 16, 1);

select name, moons from planets where ringed = 1 order by moons desc;
