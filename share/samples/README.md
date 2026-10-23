# Studio samples

Small programs, each showing one thing Studio does. Every file starts with a
short **Try this** list — open it, follow the steps, and change whatever you
like. This is your own copy (Project ▸ Open Samples made it the first time), so
nothing you do here touches the originals, and editing or breaking a sample is
the point.

| File | What it shows |
|---|---|
| `01_sections.bas` | How Studio splits a file into sections and runs one at a time |
| `02_tables.bas` | The Tables pane: a sample of the rows, the whole table, sorting |
| `03_errors.bas` | Where an error is reported — runtime and syntax — and that it is your line |
| `04_records.bas` | What a run leaves behind, in the Results pane |
| `05_branches.bas` | Trying a different value on a branch without editing the file |
| `06_overlays.bas` | Trying different code for one function on a branch |
| `07_sql.sql` | A `.sql` file as a notebook of statements, against a small SQLite database |

`.gstudio.json` is this project's own file: it names the `samples` database
that `07_sql.sql` uses (`samples.db` in this folder, created the first time it
runs, and hidden from the file tree by the project file's `ignore` list).
