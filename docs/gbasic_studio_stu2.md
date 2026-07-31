# gBASIC Studio — STU-2 reference (documents & editor)

Status: **implemented.** Documents what STU-2 adds on top of STU-0 (backbone) and
STU-1 (navigation): a coherent **document lifecycle** — open source files into editor
tabs, track unsaved changes, save safely, close with dirty-state handling, restore
open documents after relaunch, and recover gracefully when files move/disappear/change
externally. No sections, anchors, parser integration, outline APIs, execution, replay,
results, AI, or Git (later phases).

STU-2 is **additive**: STU-0/STU-1 stores, lifecycle, and goldens are unchanged.

## Document ownership (the ownership direction)

```
Studio application (studio.bas; owns app.dm)
        v
Document manager  (studio_docs.bas; the authoritative open-document store)
        v
Document models   (records: content + saved-state + file-state + cursor/scroll)
        v
Editor views      (studio_shell.bas; a SourceEditor mirroring a document)
```

The **document manager owns document state**; the editor widget is a **view**. A
document exists with its content and saved-state independently of any realized editor
widget — the whole lifecycle is testable headlessly (`studio_docs` has no GTK). The
editor reports edits back to the manager; it is never the authoritative store.

New/extended components:

| File | Layer | Responsibility |
|---|---|---|
| `stdlib/studio_docs.bas` (new) | manager (headless) | open/reuse/save/close, dirty tracking, external-change detection, persistence |
| `studio_model.bas` (extended) | domain | workspace gains a `docs` field (persisted open-document metadata) |
| `studio.bas` (extended) | lifecycle | `launch` rebuilds `app.dm`; `persist` folds it back; `open_file`/`save_document`/`close_document`/`checkpoint_documents`/… |
| `studio_shell.bas` (extended) | view (display) | a notebook of SourceEditor tabs from `app.dm`, dirty/missing tab markers |

## Identity and ownership

Documents are addressed by **stable id** (`doc-N`, minted from the document manager's
counter), never by tab index, array position, editor-widget identity, or display name.
Two open requests for the same file are **de-duplicated by canonical path**:

- Canonicalization is **lexical**: it resolves `.`, `//`, `..`, and a trailing `/`.
- It does **not** resolve symlinks or make a relative path absolute — so `a/b.bas`
  and `/abs/a/b.bas` are distinct documents. This is a deliberate, tested policy
  (a virtual-filesystem abstraction was explicitly avoided).
- `a/b.bas`, `./a/b.bas`, `a//b.bas`, and `a/x/../b.bas` all map to one document.

Files outside any registered project are allowed (`project_id` may be `""`).

## Document model

```
{ id, project_id, path, display_name,
  content,          # live buffer text (what the editor shows)
  saved_content,    # last-persisted text
  missing,          # file not present on disk
  external,         # "none" | "changed" | "deleted"
  fs_size, fs_mtime,# cheap file-state: bytes + epoch seconds (a datetime is NOT
                    #   JSON-encodable, so mtime is stored as number(file_mtime))
  cursor: {line,column}, scroll }
```

**Dirty is derived, not a label:** `is_dirty := content != saved_content`. Returning
the buffer to the saved text clears dirty. (Copy-on-write makes holding both `content`
and `saved_content` cheap — they share storage until an edit forks it.)

## Document lifecycle

- **Open** (`open_file` → `studio_docs.open`): reuse an already-open document (by
  canonical path) → `reused`; a directory → `is_directory` (nothing opened, no crash —
  `read`/`file_size` raise on a directory and gBASIC can't catch a raise, so the
  manager detects directories via the parent listing); a missing file →
  `opened_missing` (an empty, missing-flagged document); otherwise read the file →
  `opened`. Never crashes on a bad path.
- **Edit** (`edit_document`): the single mutation path — the editor's change callback
  passes the buffer text; the manager updates `content` and dirty is recomputed. (In
  the GUI the app is held in one program-global record and mutated by field, so the
  callback updates one authoritative model rather than shadowing a global.)
- **Save** (`save_document`): **in-place `write`** (see External/permissions below);
  pre-validates that the parent directory exists so a missing target is a clean
  `error` status rather than an uncatchable raise. On success the document becomes
  clean and its file-state is refreshed; **on failure the buffer and dirty state are
  preserved** and the status is `error`. A document is never marked clean before the
  write succeeds. `save_all_documents` saves every dirty document.
- **Close** (`close_document`): a clean document always closes. A dirty document takes
  an **explicit decision** — `"save"` (save then close; stays open if the save fails),
  `"discard"` (close, losing edits), or `"cancel"` (keep open). The decision is a
  parameter, not a modal buried in the model, so it is deterministically testable; the
  shell maps a confirmation dialog onto it. Closing a *view* and closing a *document*
  are conceptually distinct (STU-2 has one view per document; this leaves room for
  split views later).

## External-change policy

Cheap file-state (`file_size` + `number(file_mtime)`) is captured at load/save.
`checkpoint_documents` re-stats every open document at a deliberate checkpoint (STU-2
does not install a filesystem watcher) and applies a safe policy:

| On disk vs. Studio | Studio does |
|---|---|
| changed, document **clean** | **auto-reload** (adopt disk content; nothing to lose) |
| changed, document **dirty** | **conflict**: keep the buffer, flag `external="changed"` — never silently overwrites or discards |
| **deleted** | flag `missing` + `external="deleted"`, keep the buffer |

Studio never silently overwrites externally-changed content when it also has unsaved
edits. (A conflict-resolution dialog is a later phase; STU-2 surfaces the explicit
conflict state.)

## Persistence changes (compatible)

- New workspace field **`docs`**: `{ open: [meta], active, next_doc }`, added to the
  workspace defaults and filled by `normalize_workspace` for older files — **forward/
  back compatible**; STU-0/STU-1 workspace files load unchanged and gain an empty
  `docs`. Each `meta` entry holds `{ id, project_id, path, display_name, cursor,
  scroll, fs_size, fs_mtime }` — **no buffer content**.
- `launch` reconstructs the live document manager by re-reading each open file from
  disk (`studio_docs.from_meta`); a file that has since disappeared restores as a
  missing-flagged document. `persist` folds the live manager's metadata back into the
  workspace (`to_meta`) before the STU-0 shutdown.
- **Buffers of saved files are not persisted** (re-read from disk on restore).
  **Crash recovery for unsaved dirty buffers is out of scope for STU-2** and is a
  documented boundary: the close flow (save/discard/cancel) handles the normal case;
  a crash before saving loses unsaved edits. No dirty-buffer recovery subsystem was
  invented.

## Permissions / symlinks (investigated)

`atomic_replace` is `rename(2)`: verified to reset the saved file's permissions to the
umask default (600 → 664) and to replace a symlink `dest` with a regular file. There
is no `chmod`/`lstat` builtin to do a semantics-preserving atomic save. So **source
files are saved with in-place `write`**, which preserves permissions and writes through
symlinks — the least-surprising behavior for a user's source tree, trading whole-file
atomicity for semantic preservation. Studio's own metadata stores keep `atomic_replace`
(Studio-owned; permissions irrelevant).

## UI behavior (display)

The shell renders a `GtkPaned` with the STU-1 project browser on the left and a
`GtkNotebook` of SourceEditor tabs on the right — one page per open document, gBASIC
syntax highlighting via `sourceeditor.set_language("gbasic")`, tab labels carrying a
`*` (dirty) / `!` (missing) marker, and the active document's page selected. The
status bar shows the open-document count. Interactive wiring (browser row → open,
editor edit → manager, Save/Close actions) is owned by the entry program's handlers
over the one global app record. Verified on a display under `G_DEBUG=fatal-criticals`:
the shell builds with a real editor tab showing the dirty marker and exits clean.

## Tests

`tests/run_studio.sh` (headless, GI-independent, path-free goldens) — STU-0/STU-1
cases unchanged, plus STU-2: lifecycle (open/dup/dir/missing/edit/revert/save) with a
disk-content check, save-failure (dirty preserved), close three ways
(save/discard/cancel), external clean-reload / dirty-conflict / deletion, restore
(open set + active + cursors across a relaunch), missing restored file, browser→open,
and a valgrind-clean 40-cycle open/edit/save/close/persist memory probe. The shell
parses in `run_gui_parse.sh`; its display smoke opens a real file and shows the dirty
tab under `fatal-criticals`.

## Known limitations

- No dirty-buffer crash recovery (documented boundary; normal close prompts).
- Save-failure detection covers the testable case (missing parent directory);
  a mid-write OS failure (e.g. permission denied on an existing file) would surface as
  an uncatchable runtime error — tied to the standing `on error resume next` gap.
- External-change detection is checkpoint-based (save/refresh/switch), not a live
  watcher.
- No syntax diagnostics/error markers on tabs yet (that edges into parser territory,
  deferred; only natural highlighting is enabled).

## R1 (structural parse/outline) — unchanged

STU-2 treats files strictly as **text**; it needed no parse/AST/outline access, so it
provides **no new evidence** on R1. The parser/outline decision remains the gate
before STU-3.
