# Studio on Windows: findings

The first run, 2026-11-14, against `docs/windows_readiness.md`'s handoff.
Branch `windows`, from `qt-polish` at 3eb536f.

## The environment

- Windows 11 Pro 10.0.26200, gBASIC built in MSYS2 UCRT64 with Qt 6.11.2
  (`WINDOWS_QT=1 make`, gbasic `windows-port` branch, uncommitted Qt work
  recorded in its `docs/windows_port_status.md` §37). No KSyntaxHighlighting.
- The Qt DLLs were found through `PATH` (`C:\msys64\ucrt64\bin`); nothing was
  deployed beside gbasic.exe.
- The handoff's PowerShell environment exactly, with `GBASIC_PATH=lib`
  (relative). Scratch homes and projects under `C:\gbt\sc`.

## Results

| step | command | result |
|---|---|---|
| 1 | `gbasic app\studio_cli.bas startup C:\gbt\sc\h1` | exit 0; settings, session, `projects=none`, diagnostics all default |
| 2 | `gbasic tests\drivers\ui.bas measured C:\gbt\sc\h2 C:\gbt\sc\p2` | **identical** to `tests/studio/ui_measured.out`, byte for byte |
| 2 | `gbasic tests\drivers\ui.bas lesson C:\gbt\sc\h3 C:\gbt\sc\p3` | **identical** to `tests/studio/ui_lesson.out`, byte for byte (on an LF checkout: see item 7) |
| 3 | `gbasic --line-buffered app\studio.bas gui C:\gbt\sc\h4` | the window opens ("gBASIC Studio"); stderr holds only warning 2115 (no KSyntaxHighlighting, so a plain editor) |

The projects were at Windows paths (`C:\gbt\sc\p2`) handed in on the command
line, and no Windows path appeared in either diff.

## Item 7, line endings: met first, through git

Git for Windows' default `core.autocrlf=true` checked out 343 of the 354 text
files with CRLF, `share/samples/08_lesson.bas` among them. The `lesson` mode
then differed from its golden in nine lines: every driver edit is a
`replace` over text containing `"\n"`, and against `"...\r\n..."` none of
them matched, so the "wrong solution", "divides by zero" and "two written"
steps ran on the unedited lesson, and the export-over-dirty refusal never
fired because the student copy had no unsaved edit.

gBASIC's `read` returns a CRLF file's bytes as they are, `\r` included
(measured: `read` of `a\r\nb\r\n` has length 6 and contains `"\r"`), which is
what it does on Linux too. So this is not a Windows defect in gBASIC; it is
what every Windows-saved text file will look like to Studio. Two separate
questions:

- **The repository**: a `.gitattributes` with `* text=auto eol=lf` (or `-text`
  on the goldens and samples) would make every checkout LF whatever the
  user's git says. Studio's to decide.
- **Studio on a CRLF file a person saved**: still to be tested (the
  handoff's "CRLF is its own test, later"). Section text, prose runs, lesson
  markers (`' @end\r`) and export fences would all carry the `\r`.

The run above re-checked out with `core.autocrlf=false` (this checkout only).

## Item 5: Open Samples opens nothing on Windows

In the window, Project > Open Samples left an empty view, and Lesson > Export
Student Edition then did nothing. Reproduced headlessly with the window
driven offscreen:

```
QT_QPA_PLATFORM=offscreen gbasic --line-buffered app\studio.bas samples C:\gbt\sc\h5
runtime error at app\studio.bas:2945:63: field access expects a record
```

(exit 1, stdout empty; on Linux `tests/studio/qtview_samples.out` begins
`Open Samples: samples-opened, on top: 01_sections.bas`.) No document is on
top after Open Samples, so `active_doc(...).display_name` fails.

The cause is item 5. `open_samples` copies the samples into
`app.paths.home + "/samples"`, and this run did copy them, to
`C:\gbt\sc\h5\samples`. Then `adopt_folder` passes that through
`studio_ui.expand_path`, which calls a path relative unless it begins with
`/` (`lib/studio_ui.bas:3708`), and joins it to the launch directory:
`C:\Users\matth\development\gbasic-studio/C:\gbt\sc\h5/samples`. No such
folder exists, so no project is adopted. On Linux the home begins with `/`,
which is why this is Windows-only. Every path the OS hands Studio on Windows
(a home, a folder typed or chosen) will meet the same test, as will
`studio_docs._canonical`, which has the same rule.

gBASIC has the right test in C (`path_is_absolute`, `src/eval.c`, reading
`C:\`, `C:/`, `\` and `/` on Windows) but not as a builtin. That is the ask
in item 5.

## Not yet measured

- Step 3's interaction past Open Samples (blocked by item 5).
- Items 1, 3, 4, 5, 6, 9 to 13 beyond what the steps above touched.
