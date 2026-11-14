# Studio on Windows: what will meet it, before anyone tries

Written 2026-11-14 from Linux, by reading, ahead of the first Windows run.
gBASIC's Qt backend has just been ported to Windows and is not fully pushed;
Studio has never run there. Nothing below is measured on Windows. Each item
is either **Studio's to fix** or **gBASIC's to answer** (also in
`docs/gbasic_asks.md`), so the first run is a test of how seamless gBASIC
makes a real application across platforms, not only of Studio.

Read against gBASIC `018f18f5` and its `docs/windows_port_status.md`, which
already covers a great deal: `process.*` including `which` (the CreateProcess
search, `.exe` appended, not PATHEXT) and `stop` (CTRL_BREAK to the group,
then `TerminateJobObject`), argument quoting, `env` merging, `cwd`, timeouts,
CRLF reading, a UTF-8 BOM, `%LOCALAPPDATA%\gbasic` for its own state, and the
separator rule: **gBASIC speaks `/`; on Windows the path splitters also read
`\`**.

## Would stop it at once

1. **`GBASIC_PATH` is split at `:`** -- `src/main.c:417` and `src/eval.c:9577`
   both `strchr(start, ':')`, and the reference says "colon-separated". Every
   absolute Windows path has a colon (`C:\...`), so
   `C:\studio\lib;C:\gbasic\stdlib` splits into `C`, `\studio\lib;C` and
   `\gbasic\stdlib`, and no Studio library is found. **gBASIC's.** *Meanwhile:*
   Studio's launcher could pass only a RELATIVE `lib` (it runs from the
   install tree) and let gBASIC find its stdlib unaided, which the port notes
   say it does.
2. **The launcher is bash** (`./studio`, 198 lines): it finds the interpreter
   and stdlib, sets `GBASIC_PATH`, `GBASIC_STUDIO_SHARE`, `GBASIC_STUDIO_CWD`,
   the syntax path, `--line-buffered`, and routes modes. **Studio's.** The
   seamless answer is a launcher written in gBASIC itself -- it has
   `program_file()`, `platform()`, `join_path` and `process.run` with `env`
   now -- so ONE launcher runs on both, and only a two-line `studio.cmd` /
   shell stub is per-platform.
3. **`HOME` is read for the home directory** (`studio_ui.home_dir`, and
   `~/.gbasic-studio` as the default home). PowerShell and cmd do not set
   `HOME`, which gBASIC itself met and solved for its own state
   (`%LOCALAPPDATA%\gbasic`). **Both:** Studio should keep its home where
   gBASIC's conventions put per-user data; gBASIC could answer "where does
   per-user data go" once, for every program (an ask).

## Would misbehave quietly

4. **Paths are built and split by hand, with `/`.** About 120 `+ "/"` joins in
   19 files, and FOUR hand-written splitter sets: `studio_docs._canonical /
   _basename / _dirname`, `studio_model._basename`, `studio_history._leaf`,
   `studio_ui._leaf`, plus `studio_permissions._canonical`. A Windows path
   handed in by the OS or typed (`C:\Users\x\proj\main.bas`) has no `/`, so a
   leaf is the whole path and a directory is `.`. **Studio's**, and gBASIC
   already has the tools: `file_name`, `directory_name`, `stem`, `extension`,
   `join_path` read both separators on Windows. They are "since 0.11.0"
   (installed: 0.10.0), so one Studio module over `has_builtin` with today's
   code as the fallback, then every call site through it.
5. **"Is this absolute?" is `left(p, 1) = "/"`** (`studio_ui.expand_path`,
   `studio_docs._canonical`). `C:\x`, `C:/x` and `\\server\share` all read as
   relative and get the launch directory prepended. **gBASIC has the answer
   in C** (`path_is_absolute`, reading both separators under `_WIN32`) but not
   as a builtin -- an ask. `real_path` cannot stand in: it requires the path
   to exist, and Studio canonicalises paths it is about to create.
6. **A lexical canonical form, and case.** `studio_docs._canonical` is how a
   file opened twice by two spellings is ONE document (`find_open`), and how a
   document is attributed to a project by prefix. On Windows `C:\A\b.bas` and
   `c:/a/B.bas` are the same file; compared as strings they are two documents,
   and a prefix test can attribute a file to the wrong project. **gBASIC's to
   answer** (a lexical `normal_path`, and a `same_path(a, b)` that knows the
   platform's case rule), or Studio compares through `real_path` where the
   file exists.
7. **Line endings.** Studio splits documents on `"\n"`. gBASIC reads CRLF
   (the port measured it), but if `read` hands `"\r\n"` through, every line of
   a Windows-saved file ends in `\r`: section text, prose runs, lesson
   markers (`' @end\r` is not `' @end`), and the export's fences. **To measure
   first**: `read` of a CRLF file, then decide whether Studio normalises on
   open (and writes back what it found).
8. **Scratch and temporary files** are `<home>/scratch/...` built with `/`,
   which Windows accepts, so these should work as they are -- but `temp_dir`
   (0.11.0) is the platform-correct place and creates, rather than names, the
   directory.

## The window

9. **Highlighting and the print theme are found through `XDG_DATA_DIRS` and
   `GBASIC_SYNTAX_PATH`.** KSyntaxHighlighting on Windows looks under
   `%LOCALAPPDATA%\org.kde.syntax-highlighting` and the Qt install, not XDG.
   **To measure**: does `qt.highlighting` resolve gBASIC on a Windows build,
   and where does Studio's `studio-print.theme` have to go.
10. **Figures pin fonts through fontconfig** (`share/fonts/fonts.conf`,
   `FONTCONFIG_FILE`), which Windows Qt does not use. Book figures are made on
   Linux; on Windows `shoot` and the figure environment should refuse plainly
   rather than draw with whatever fonts are there. **Studio's.**
11. **`SP_` toolbar icons** come from the platform style, so they will look
   different -- expected, not a defect. Studio's own SVGs for the dark theme
   need Qt's SVG plugin in the Windows build.
12. **The `.desktop` entry and hicolor icons** are Linux-only; Windows wants a
   Start-menu shortcut (gBASIC's MSIX already makes one for itself).

## Tests

13. **Both runners are bash** (`tests/run_studio.sh`, `run_studio_agent.sh`)
   and lean on `diff`, `timeout`, `mktemp`, `TZ=America/New_York` (a POSIX
   zone string), and valgrind for five tiers. The drivers are gBASIC and
   should run as they are. A first Windows pass could run the headless
   drivers by hand (`gbasic tests/drivers/ui.bas <mode> <home> <proj>`) and
   diff against the goldens -- the gBASIC port did exactly this with its own
   Linux suites (`windows_port_status.md` §11).

## A suggested first run

In order, each one a single command, stopping at the first that fails:

1. `gbasic app/studio_cli.bas startup <scratch home>` with `GBASIC_PATH` set
   to the relative `lib` (item 1) -- the model load, no window, no paths from
   the OS.
2. The `ui` driver's `measured` and `lesson` modes against a scratch project
   with a Windows path -- items 4 to 7 show up here first.
3. `gbasic app/studio.bas gui <scratch home> <project>` -- the window.

Then send back what broke; the fixes split along the lines above.
