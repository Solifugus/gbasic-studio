# Asks for gBASIC, held until it has time

gBASIC is busy porting to other platforms (2026-11-11), so Studio's asks wait
here rather than being sent. Each one says what Studio does meanwhile, so
none of them blocks anything. **Before sending one, check gBASIC's HEAD:** a
request list is a snapshot and can be stale before it is read (CLAUDE.md,
§0.33's lesson). Remove an entry when it lands, and say what Studio changed.

Checked against gBASIC `018f18f5` on 2026-11-11 and 2026-11-14, and `5592db1e` (with `windows-port`) on 2026-11-14.

## Language

- **Line continuation after a binary operator.** A `+` at the end of a line is
  a parse error (`unexpected NEWLINE`), so a long string built over several
  lines has to be an array and a `join`. *Met by:* `studio_lesson.prelude`.

## Processes

- **`stdin:` on `process.run`.** `process.start` has `stdin: "pipe"`;
  `process.run` has nothing, so its child inherits Studio's stdin. *Met by:*
  the measured export and Check Lesson time out a program that calls `input`
  (10s) and refuse it. With `stdin: ""` (or a closed stdin) such a program
  would see end-of-input at once, and the checker's `--- input` could be
  offered.

## Across platforms (from `docs/windows_readiness.md`)

- **`GBASIC_PATH` on Windows.** Both splitters cut at `:` (`src/main.c:417`,
  `src/eval.c:9577`; the reference says "colon-separated"), so any absolute
  Windows entry (`C:\...`) comes apart at its drive letter. `;` on Windows,
  as `PATH` does, would be the expected answer. *Meanwhile:* a relative `lib`
  only, and gBASIC finding its own stdlib.
  (`studio_paths` now meets the next three in Studio, after the first
  Windows run; a builtin would make them one answer for every program.)
- **"Is this path absolute?" as a builtin.** gBASIC has `path_is_absolute` in
  C, reading both separators on Windows; programs test `left(p, 1) = "/"`,
  which calls `C:\x` relative.
- **A lexical path normaliser, and a same-file comparison.** `real_path`
  needs the path to exist; an editor canonicalises paths it is about to
  create, and decides whether two spellings are one open document. On Windows
  that comparison also has to ignore case. Something like `normal_path(p)`
  and `same_path(a, b)`.
- **Where per-user data goes.** gBASIC solved this for itself
  (`%LOCALAPPDATA%\gbasic` ahead of `HOME`, because PowerShell and cmd set no
  `HOME`); every application has the same question. A builtin answering the
  platform's per-user data directory would make it one answer.

## Qt

- **A header-less `markdown` block.** The collapse bar shows over open prose
  too; documentation reads better without it. *Met by:* nothing; it is
  cosmetic. (CLAUDE.md, "Documentation comments as prose".)
- **A palette verb.** A stylesheet does not move Qt's palette, so Studio's
  dark sheet cannot reach what the palette paints (standard-pixmap icons, a
  combo's arrow, dock buttons). *Met by:* Studio's own SVG icons and a light
  palette under a dark sheet. A named editor theme (D1) now covers the
  editor; the chrome is still open. Re-check before sending.
- **A `form` label on anything but a `field`.** New Project's licence `choice`
  carries `label: "Licence"` and shows none. Asked once; upstream has since
  fixed leaf labels in general (`qt_gui_design.md`, "`label:` had never
  reached any widget"), so **re-check first** -- this may be done.
## Built upstream, not yet used by Studio

Not asks -- follow-ups on Studio's side, kept here so they are not re-asked.

- **Content blocks in MCP results** (`mcp.content([mcp.text(t),
  mcp.image(bytes, mime)])`, gBASIC 15dcdba5, 2026-11-10). Studio's own
  protocol half (`lib/studio_mcp.bas`) could move onto `mcp.handle` now.
  This was on the list as an open ask for four days after it landed -- the
  stale-request lesson again.
- **Standard input in the event loop** (`watch w(stdin.lines)`, same commit).
  `./studio mcp` could serve a VISIBLE window, which is what watching an
  assistant work needs.

- **`qt.click` (a left click aimed like `qt.right_click`, after 0.10.0).** The
  browser's `itemClicked` single-click activation is the one handler with no
  tier (CLAUDE.md, "`itemClicked` has no tier"). It can have one now.

## Undecided -- to discuss with the gBASIC session

- **An `assert` or `raise` statement.** Not an ask yet: the user is still
  weighing it (2026-11-14) and wants to talk it over with the gBASIC session
  once that one is free. The case against, as it stands: a raise is a program
  giving up, and reaching for one is often a failure to be robust. Lesson
  checks are one data point for that side: Studio's rewrite of
  `print <expression>` check lines reports every check, keeps going past a
  false one, and returns the result as data -- telling "not yet" apart from
  "does not run" -- where an assert would stop at the first false claim.
