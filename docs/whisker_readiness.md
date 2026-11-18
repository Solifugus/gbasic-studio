# Studio on a second GUI backend (Whisker): what it uses that Qt has

Measured 2026-11-18 against gBASIC `4481c992` (the 0.12.0 candidate). gBASIC
0.12.0 splits its `ui` module into one front over a backend table, and names
what one backend can do and another may not as eight **capability groups**,
asked with `ui.can(group)`. Qt has all eight. Whisker (SVG; a local window, a
browser, or a remote client) is planned for 0.13.0, and the user's direction
(2026-11-16) is Qt as the product for now, Whisker eventually, perhaps as a
web Studio -- and Whisker can be adapted to what Studio needs.

`GBASIC_UI_WITHHOLD="<group>"` takes a group away from the Qt backend, so
this is not a reading exercise: each row below is what Studio actually did
with that group withheld, running `probe` (the main window), `press` (every
menu item and the New Project window) and `samples` (the grid, snippet and
schema windows, and the lesson's notes).

| group | Studio uses it for | withheld, Studio | the way forward |
|---|---|---|---|
| `highlighting` | every editor's `language:` and `theme:` (10 sites) | **does not start**: the overlay editor's `language:` is refused at window build | Declare `language:`/`theme:` only when `ui.can`; a plain editor otherwise. Small. |
| `docking` | the whole main window: Files left, Console bottom, five panes right, and the saved layout (12 sites) | **does not start**: the `docks` is refused | The biggest item. Either Whisker gets docking, or Studio has a second layout (splits and tabs, the shape it had before §0.30) chosen by `ui.can`. Worth deciding with the Whisker work rather than guessing now. |
| `stylesheet` | nothing -- Studio writes no QSS -- except CLEARING a theme, `ui.theme("")` | **does not start** on the default theme | **Settled by gBASIC (2026-11-18), before the 0.12.0 tag**: `ui.theme("")` is every backend's and clears; only non-empty text needs `stylesheet`. Nothing for Studio to guard. |
| `figures` | `ui.capture` in `shoot` and the MCP `capture` tool | starts and runs; only a capture would refuse, by name | Already right: figures are a Linux, Qt thing (fonts pinned through fontconfig). `shoot` could check `ui.can` and say so before building anything. |
| `notebook` | results and prose under their sections (`ui.blocks`, `ui.fold`), the `block` event on every editor, the lesson's notes (22 sites) | **does not start**: `on <editor>.block` is refused | Small: `qt_blocks_probe` (which matches an error's WORDING) becomes `ui.can("notebook")`, and the block handler is attached only then. The results stay in their panes, as on an older gBASIC. |
| `icons` | the toolbar's five `SP_` standard pixmaps in the light theme (18 sites) | **does not start**: `SP_DialogSaveButton` is refused | Studio already ships SVG icons for the dark theme; a light set, used whenever `ui.can("icons")` is false (an icon that is a FILE is every backend's). Small. |
| `windows` | New Project, the table grid, Insert SQL, Schema -- each a second window (92 sites, mostly the windows' own code) | starts; **each second window is refused** when opened | A real design question for a browser backend: the four become pages of the main window, or dialogs Whisker draws inside it. Decide with the Whisker work. |
| `file_dialogs` | nothing | -- | Studio has no file chooser; names come from the header field. |

## What this says

- **Five of the seven are small and could be done now** without changing
  anything on Qt: highlighting, notebook, icons, figures, and stylesheet once
  gBASIC answers. Each is a `ui.can` asked once at launch -- the shape
  `qt_blocks_probe` already has -- carried on the app so the shell stays a
  pure function (`studio_shell_qt` must not call `ui.`; the tripwire
  `qt_shell_pure` enforces it).
- **Two are design work**, docking and windows, and both are about what a
  browser-shaped Studio should LOOK like, not about missing code. Since
  Whisker can be adapted, the cheaper answer may be on its side; that is the
  conversation to have when 0.13.0 starts.
- **`GBASIC_UI_WITHHOLD` makes each guard testable today**, on Qt: a tier
  per group, run with it withheld, is how a guard is proven before Whisker
  exists. A program that passes with groups withheld has not been run on
  Whisker, which lays out and draws differently -- gBASIC says so itself.

## Agreed with gBASIC (2026-11-18)

gBASIC recorded Whisker's requirements for 0.13.0 from this list: a source
editor with highlighting, blocks between lines and folds, a tree, and an
asking table. Docking and second windows stay open until Whisker work starts.
Studio's own guards (highlighting, notebook, icons, figures) come after the
0.12.0 tag, each with a tier run under `GBASIC_UI_WITHHOLD`.

## Not measured

- How Studio LOOKS on any backend but Qt.
- The event-loop contract under a remote client: the run poller, the buffer
  and caret polls each fire sixteen times a second, which is free in a local
  window and network traffic on a remote one (`whisker-direction` memory;
  the polls could be `changed` events now).
- A web Studio's security model: it runs programs and reads files on the
  machine that serves it, so who may connect, and what they may touch, has
  to be designed in.
