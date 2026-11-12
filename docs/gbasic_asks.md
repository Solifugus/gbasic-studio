# Asks for gBASIC, held until it has time

gBASIC is busy porting to other platforms (2026-11-11), so Studio's asks wait
here rather than being sent. Each one says what Studio does meanwhile, so
none of them blocks anything. **Before sending one, check gBASIC's HEAD:** a
request list is a snapshot and can be stale before it is read (CLAUDE.md,
§0.33's lesson). Remove an entry when it lands, and say what Studio changed.

Checked against gBASIC `018f18f5` on 2026-11-11.

## Language

- **An `assert`, or a `raise` statement.** A program has no way to fail on
  purpose with a message except `exit(n)`, which carries no text. *Met by:*
  lesson checks (`lib/studio_lesson.bas`), which rewrite each
  `print <expression>` check line into a call that prints a pass/fail marker
  Studio parses. With `assert(cond, msg)` a check could be the author's own
  line, run as is.
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
- **A stdin source in the event loop.** `./studio mcp` blocks on `input()`
  and drives Qt call by call, so it is offscreen only; a visible window would
  not repaint between requests. Needed for watching an assistant work in a
  real window.

## Standard library

- **Content blocks in `mcp.handle` results.** Its tool result is text only,
  and Studio's `capture` answers with an image block; `tools.dispatch` also
  wants one function value per tool, which cannot close over the app. *Met
  by:* `lib/studio_mcp.bas`, Studio's own protocol half.

## Built upstream, not yet used by Studio

Not asks -- follow-ups on Studio's side, kept here so they are not re-asked.

- **`qt.click` (a left click aimed like `qt.right_click`, after 0.10.0).** The
  browser's `itemClicked` single-click activation is the one handler with no
  tier (CLAUDE.md, "`itemClicked` has no tier"). It can have one now.
