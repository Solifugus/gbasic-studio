# gBASIC Studio — STU-1 reference (workspace navigation & project browser)

Status: **implemented.** Documents exactly what STU-1 adds on top of the STU-0
backbone (`docs/gbasic_studio_stu0.md`): the first usable navigation application —
workspaces you can create/open/switch, projects as containers, and a filesystem
project browser. It answers *"what am I working on?"*, not *"how do I edit it?"*.
No editing, parsing, symbols, replay, execution, or AI (those are later phases).

STU-1 is **additive**: STU-0's `startup`/`shutdown`/`summary` and its three stores
are unchanged, so STU-0 persistence and goldens are untouched.

## Components added

| File | Layer | Responsibility |
|---|---|---|
| `stdlib/studio_browser.bas` | model (headless) | scan a project directory into a sorted, lazily-expanded tree; flatten/dump projections |
| `stdlib/studio_model.bas` (extended) | domain rules | nav state (selection + expanded dirs); project remove/rename; `project_by_id` |
| `stdlib/studio.bas` (extended) | lifecycle | workspace **registry**; `launch`/`persist`; create/open/rename/close workspace; recent list; `nav_summary` |
| `stdlib/studio_shell.bas` (extended) | view (display) | renders the project browser tree + project list + status from the model |
| `examples/studio/studio.bas` (extended) | entry | STU-1 headless modes (`stu1_build`/`restore`/`browse`/`missing`/`registry`/`cycles`) |

## Workspace ownership

The **workspace remains the primary ownership boundary** (STU-0). STU-1 adds a
**workspace registry** so more than one workspace can exist and be reopened:

- `<home>/workspaces/<id>.json` — one file per workspace (STU-0 shape, now also
  carrying `nav`).
- `<home>/workspaces.json` — **the registry**: the set of known workspaces plus a
  most-recent-first ordering. A separate store, persisted by `save_registry`
  (folded into `studio.persist`), never by the STU-0 `shutdown`.

Registry schema (version 1):

```json
{ "schema_version": 1,
  "entries": [ { "id": "ws-1", "name": "analytics" }, { "id": "ws-2", "name": "etl" } ],
  "recent":  [ "ws-2", "ws-1" ] }
```

Lifecycle (all on the app object, headless):

- `studio.launch(home)` = STU-0 `startup` + `load_registry`.
- `studio.persist(app)` = STU-0 `shutdown` + `save_registry`.
- `studio.create_registered_workspace(app, name)` — mint id, install active, register.
- `studio.open_workspace(app, id)` — load that workspace file, install active, mark
  recent. Missing/corrupt/future file → left closed with a diagnostic (never a crash).
- `studio.rename_workspace(app, name)` — rename active workspace + registry entry.
- `studio.close_workspace(app)` — clear the active workspace (registry entry kept).
- "Restore previous workspace" is STU-0 behavior: `launch` reopens the session's
  `active_workspace` when `settings.restore_last_session` is true.

## Project model

Projects are **containers**, addressed by stable id (`proj-N`), never manipulated in
content by STU-1:

- `studio_model.add_project(ws, name, path)` — create/open a project at a directory.
- `studio_model.remove_project(ws, id)` — drop it from the workspace (files on disk
  are untouched); active project falls back to the first remaining, or "".
- `studio_model.rename_project(ws, id, name)` — change display name (id/path fixed).
- `studio_model.set_active_project(ws, id)` / `project_by_id(ws, id)`.

## Navigation model

The navigation tree **reflects the authoritative model + the filesystem**; widgets
are never the source of truth. State lives in the workspace's `nav`:

```json
"nav": { "selected_path": "<path>", "expanded": ["<dir path>", ...] }
```

- Selection: `set_selected_path(ws, path)`.
- Expansion: `toggle_expanded` / `expand_path` / `is_expanded` — a set of directory
  paths that are open in the browser.

The **project browser** (`studio_browser`) turns a project directory into a tree:

- `scan(path, expanded)` / `scan_project(project, expanded)` → nodes
  `{ name, path, kind: "file"|"dir", expanded, children }`. Directories are scanned
  recursively **only when their path is in `expanded`** (lazy; bounds the scan to
  what is visible and lets expansion persist).
- `flatten(nodes)` → visible rows `{ name, path, kind, depth, expanded }` in display
  order. `visible_count(nodes)`; `dump(nodes)` → deterministic path-free text.
- Ordering is deterministic: **folders first, then files, each sorted by name**
  (readdir order is not stable, so it is sorted explicitly).
- **Refresh** is simply re-invoking `scan`: it re-reads the filesystem, so created or
  deleted files appear on the next scan. Expansion state is preserved because it is
  held in the model, not the widgets.
- Update flow: a UI action (select/expand) mutates the **model** via a
  `studio_model` function; the view re-reads the model (and re-scans as needed). No
  widget-to-widget coupling.

## Filesystem handling (graceful, never crashes)

The browser reads directories with the `list` builtin, which returns an **empty
array** for a missing or inaccessible directory. So:

- a **deleted or unreadable project** → an empty subtree, not a crash;
- `open_workspace` on a missing/corrupt file → the workspace stays closed with a
  diagnostic;
- no bespoke filesystem walking — the platform's `list`/`files`/`folders` +
  file/dir references do the work.

## Persistence additions

- New store `<home>/workspaces.json` (the registry), versioned and read defensively
  (missing/corrupt/future → empty registry + diagnostic).
- New workspace field `nav` (selection + expansion), added to the workspace defaults
  and filled in by `normalize_workspace` for older files — **forward/back
  compatible**; a STU-0 workspace file loads unchanged and gains an empty `nav`.
- `studio.persist` writes `settings, session, workspace, registry`. STU-0's plain
  `shutdown` (`settings, session, workspace`) is unchanged for STU-0 callers.

## Ownership & update flow (summary)

```
studio (lifecycle, owns app.model + app.registry)
  -> studio_model (workspace/project/nav rules; returns updated values, COW)
  -> studio_browser (scans the filesystem into a tree model)
  -> studio_store (versioned atomic I/O)  -> filesystem builtins
studio_shell (view) -> reads model + scans filesystem -> gtk.bas -> gi -> GTK
```

## Tests

`tests/run_studio.sh` (headless, GI-independent, path-free goldens) — STU-0 cases
unchanged, plus STU-1: workspace lifecycle + multiple projects + **navigation
persistence** across a relaunch (`stu1_build` → `stu1_restore`), **missing project**
(no crash), **browser** correctness (folders-first/sorted/lazy), **tree refresh** (a
new file appears after re-scan), **registry + recent**, and a valgrind-clean 50-cycle
memory probe. The shell parses in `run_gui_parse.sh`; its display smoke renders the
browser cleanly under `G_DEBUG=fatal-criticals`.

## What STU-1 is not

No editor, no file opening into an editor, no parsing/symbols/code intelligence, no
tabs wired to documents, no replay/execution, no AI, no DataGrid. The nav shell makes
those later phases' integration straightforward (the browser selects files by stable
path; STU-2 mounts an editor on selection).
