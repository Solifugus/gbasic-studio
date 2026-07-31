# gBASIC Studio — STU-0 reference (persistence spine & application shell)

Status: **implemented.** This documents exactly what STU-0 delivers — the
persistent backbone the rest of Studio is built on. It is the reference for the
STU-0 phase of `docs/gbasic_studio_plan.md`; that plan owns the phasing, this
document owns the delivered format and lifecycle. Nothing here describes a later
phase as done.

STU-0's goal is **continuity of context, not editing**: launch Studio, create/open
a workspace, close it, relaunch, and find the working context restored. The editor,
execution sections, inspector, and agent are later phases.

## Components

All headless (no GTK) except the shell:

| File | Layer | Responsibility |
|---|---|---|
| `stdlib/studio_json.bas` | safe parse | non-raising JSON validity gate — pre-validate before `decode` |
| `stdlib/studio_store.bas` | I/O | crash-safe versioned persistence over the filesystem builtins |
| `stdlib/studio_model.bas` | domain rules | settings/session/workspace/project/document model; ids; normalization |
| `stdlib/studio.bas` | lifecycle | application object; startup/shutdown pipelines; future-hook placeholders |
| `stdlib/studio_shell.bas` | view (display) | the GTK 4 shell window, a pure view over the model |
| `examples/studio/studio.bas` | entry | mode dispatch (headless lifecycle + display shell) |

Layering is strict and one-directional:

```
studio (lifecycle)  ->  studio_model (rules)  ->  studio_store (I/O)  ->  filesystem builtins
                                              ->  studio_json (safe parse)
studio_shell (view) ->  reads the model studio owns  ->  gtk.bas -> gi -> GTK
```

Persistence never touches widgets; widgets never own persistent state.

## Persistence format

Everything lives under one **config home** directory (tests use a throwaway dir; a
real launch would use a per-user location). Three logical stores, each a standalone
**strict JSON** file written via `json_encode` (never the lenient `encode`
dialect):

```
<home>/settings.json            global, user-level preferences
<home>/session.json             last session: active workspace, window, recent files
<home>/workspaces/<id>.json     one file per workspace: projects, documents, tabs
```

Every record carries a `schema_version` (currently **1**). Writes are atomic: the
text is written to a `<file>.tmp` sibling and swapped in with `atomic_replace`
(a single `rename(2)`), so a crash mid-write can never leave a truncated store.

### settings.json (schema 1)

```json
{ "schema_version": 1, "theme": "system", "restore_last_session": true, "recent_limit": 10 }
```

### session.json (schema 1)

```json
{
  "schema_version": 1,
  "active_workspace": "ws-1",
  "next_ws": 2,
  "window": { "width": 1024, "height": 768, "maximized": true },
  "recent_files": ["/home/u/analytics/load.bas"]
}
```

### workspaces/&lt;id&gt;.json (schema 1)

```json
{
  "schema_version": 1,
  "id": "ws-1",
  "name": "member-analytics",
  "next_seq": 2,
  "active_project": "proj-1",
  "projects": [
    {
      "id": "proj-1",
      "name": "Analytics",
      "path": "/home/u/analytics",
      "next_seq": 3,
      "documents": [
        { "id": "doc-1", "path": "/home/u/analytics/load.bas",   "name": "load.bas" },
        { "id": "doc-2", "path": "/home/u/analytics/report.bas", "name": "report.bas" }
      ]
    }
  ],
  "tabs": { "order": ["doc-1", "doc-2"], "active": "doc-2" }
}
```

### Stable identifiers

Workspaces (`ws-N`), projects (`proj-N`), and documents (`doc-N`) each carry a
string id minted from a monotonic per-container counter (`session.next_ws`,
`workspace.next_seq`, `project.next_seq`). **Nothing refers to a thing by array
position** — the active project, tab order, and active tab are all id references,
so reordering or inserting never invalidates a reference. This is the identity
contract later phases (branches, replay, agent tools) build on.

### Compatibility (versioning)

- **Missing store** → recover to the typed default; diagnostic `<kind>:default`.
- **Corrupt store** (not valid JSON) → recover to default; diagnostic
  `<kind>:corrupt-recovered`. (Reads pre-validate with `studio_json.valid`, so a
  bad file never raises — gBASIC cannot catch a raise, so recovery *must* be
  pre-validated, not caught.)
- **Future `schema_version`** (newer than this build) → rejected, recover to
  default; diagnostic `<kind>:future-version-rejected`. Unknown newer state is
  never partially interpreted.
- **Older/loaded store** → `normalize_*` fills any missing field from the current
  defaults **while preserving unknown (future) keys**, so a round trip through an
  older build does not drop fields it did not recognize.

## Startup lifecycle

Deterministic pipeline (in `studio.startup(home)`), persistence kept entirely out
of widget construction:

```
main
  -> load global settings   (studio_store.read_status -> _policy -> normalize)
  -> load previous session  (same)
  -> load its workspace     (only if the session names one AND restore_last_session)
  -> construct the Studio model  { schema_version, settings, session, workspace }
  -> return the application object { home, paths, model, managers, diagnostics }
     (the UI, if any, is built afterwards from this object)
```

Each step recovers independently and records a diagnostic; startup never blocks or
crashes on bad stored state. Graceful degradation: a corrupt/future/missing
session resets to a clean session (so the last workspace is simply not reopened),
never a failure.

## Shutdown lifecycle

```
collect current state (the live model the app owns)
  -> json_encode settings / session / workspace
  -> write each to <file>.tmp
  -> atomic_replace(<file>.tmp, <file>)   (never a partial file)
  -> return the list of stores saved
```

## Model ownership

- **`studio.bas` owns the one authoritative in-memory model** (`app.model`).
  Startup produces it; every mutation goes through `studio_model` functions that
  **return** an updated value which the caller reassigns (copy-on-write: a function
  cannot mutate a caller's record in place, so nested updates read the element,
  mutate the copy, and write it back).
- **`studio_shell.bas` owns no state.** It is a view: it reads the model to label
  and populate its widgets and returns widget references. In the interactive app
  the live model is held in a single program-global record and mutated by field
  (the registry pattern), so callbacks update one authoritative model rather than
  shadowing globals.
- **Future hooks** — `studio.managers()` returns empty placeholder managers
  (`editor`, `section`, `replay`, `agent`, all `ready: false`). They are live
  extension points for later phases and are **not** persisted with the model.

## What STU-0 is not

No editor, no execution sections, no replay, no branches, no inspector, no agent,
no DataGrid, no syntax highlighting, no parser integration. Those are STU-1 and
later. STU-0 is the backbone they attach to.
