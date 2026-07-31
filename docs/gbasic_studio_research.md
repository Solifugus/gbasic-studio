# gBASIC Studio — Design Research Report

Status: **research study only. Nothing in this document is implemented.** It is a
repository-grounded feasibility study to inform a future Studio design.

Date: 2026-07-19
Method: direct inspection of the current tree (`src/eval.c`, `src/parser.y`,
`src/ast.c`, `stdlib/*.bas`, `docs/*`, `PLAN.md`). Every capability claim is tagged
and, where practical, cited `file:line`. Design-doc claims were **cross-checked
against `eval.c`**; where a doc describes unbuilt work it is called out.

Status tags used throughout:

- **VERIFIED** — confirmed present and working in the current binary/source.
- **PARTIAL** — present but materially limited.
- **PROPOSED** — a design recommendation for Studio; not built.
- **REQUIRED** — must be added to gBASIC before Studio can be built comfortably
  in gBASIC.
- **OPTIONAL/LATER** — desirable but deferrable.

Section map (matches the requested deliverable outline): 1 Executive summary ·
2 What exists today · 3 Feasibility · 4 Required gaps · 5 Studio architecture ·
6 UI architecture · 7 Persistent project/workspace model · 8 Execution sections &
snapshots · 9 Exploratory branching · 10 Results/variable inspection ·
11 AI Agent/MCP · 12 LLM provider abstraction · 13 Git · 14 Configuration & AI
rules · 15 Persistence/file layout · 16 Security/reliability · 17 Implementation
phases · 18 Open questions.

---

## 1. Executive summary

The honest one-paragraph answer (expanded in §17 and the closing recommendation):
**gBASIC Studio cannot today be implemented *primarily in gBASIC* as a rich GTK
desktop IDE.** Two facts dominate. First, the code editor — the heart of any IDE —
is **not reachable through the current GObject-Introspection bridge**: editing a
`GtkTextView`/`GtkSourceView` needs `GtkTextIter` out-parameters and boxed structs
that the `gi` marshaller explicitly rejects (bridge is scalar/string/object/enum
only; `src/eval.c:13221-13228`, `12780-12874`). Second, the vision's
"continuity of thought" (pause/resume, snapshot, restore live runtime state,
branchable histories) runs against an interpreter that is **single global state
with native C recursion** — no interpreter-context struct, no `Env` serializer,
no continuation (`PLAN.md:5`; `src/eval.c:397-500`, `18529`).

What *is* strong: the **backend brains** of Studio are very buildable in gBASIC
today. There is a shipped, provider-pluggable LLM client (`stdlib/llm.bas`), a
solid embedded SQLite store with transactions and prepared statements
(`src/eval.c:11264`), JSON via `encode`/`decode`, broad file IO, an arbitrary
HTTPS client, crypto primitives for an encrypted secrets file, and a fork+exec
**actor** model that already gives *process-level* isolation
(`src/eval.c:8299-8360`).

The recommended shape is therefore a **hybrid**: keep Studio's *logic* (project
model, execution-section engine, exploratory-branch engine, persistence, agent
orchestration, LLM access) in gBASIC, and put the *presentation surface* — the
editor with syntax highlighting and inline widgets, the rich value viewers — in a
technology that can render it today. The most pragmatic surface is a **browser /
webview front end** (a CodeMirror/Monaco editor solves the single hardest problem
for free; inline branch tabs and boundary markers are trivial DOM), with gBASIC
acting as the kernel behind it. The all-gBASIC-over-GTK4 path is achievable *only
after* a substantial native investment in the `gi` bridge (boxed/out-param
marshalling, a text-editor binding, tree/table models, GLib event-source
integration), at which point most of that work is C, not gBASIC.

The rest of this report backs each of those claims with code, then lays out a
phased architecture that lets "primarily in gBASIC" become progressively more true.

---

## 2. What exists today (verified from code)

### 2.1 Front end vs. interpreter reentrancy

- **Front end (lex → parse → AST) is reentrant.** `gb_parse` threads a
  stack-allocated `gb_parse_ctx` and shares no file-scope parser state
  (`src/frontend.c`, `include/parse_ctx.h:21-37`; `PLAN.md:94-133` records the
  two-contexts-in-one-process test passing). `libgbasic.a` is a real build target
  (`PLAN.md` Phase 0), already consumed by a second binary, `gbasic-lsp`.
- **The evaluator is NOT reentrant.** `eval_program(AstStmtList)` takes no context
  (`include/eval.h:6`); state lives in `static Env global_env` + `current_env`
  and ~60 file-scope statics (`src/eval.c:397-500`). `PLAN.md:5` is explicit: "The
  interpreter (`src/eval.c`) stays global-state for now." The context-struct
  refactor is **PLAN Phase 3 — deferred, not started** (`PLAN.md:580-586`).

### 2.2 Language & runtime surface (relevant subset)

- **Values** (`src/eval.c:167-260`): 18 kinds incl. NUMBER(double), STRING
  (binary-safe, length-prefixed), ARRAY, RECORD, DATETIME, DURATION, MONEY, FILE,
  DIR, SQLITE/POSTGRES connections, XML_READER, GOBJECT, ACTOR, FUNCTION. Arrays
  deep-copy on assignment; **record fields are refcounted copy-on-write cells**
  (`ValueCell.refcount`, `src/eval.c:879-890`, `1256-1373`) — a genuinely useful
  primitive for branch state (§9).
- **Serialize/deserialize** (`src/eval.c:6959-7111`, `7385`): a deep, binary-safe
  codec for a single `Value`, cycle-guarded by a depth cap (`SER_MAX_DEPTH 256`,
  error "value nested too deeply (possible cycle)"). Functions serialize **by name
  + library only** (not code/closure); DB connections and GObjects are **rejected**;
  actor handles only valid inside spawn/handle-passing frames. **There is no
  whole-`Env` serializer.** Output is an ordinary gBASIC string, so any *pure-data*
  value can be persisted to disk via a file write.
- **RNG** (`src/eval.c:77-119`): seedable xoshiro256\*\* with a `seed()` entry
  (reproducibility is a stated design goal). Live 256-bit state is **not exposed**
  for capture/restore — you can replay from a seed but not resume mid-stream.
- **Actors** (`src/eval.c:8155-8475`, `src/actor.c`): `spawn` = `fork()` +
  `execv("/proc/self/exe", {"--actor", entry, source, fds…})` — re-executes the
  **gBASIC interpreter itself** on a named function, shared-nothing, mailbox over
  `AF_UNIX`/`SOCK_SEQPACKET`. Startup args cross via the serializer; handles cross
  as `SCM_RIGHTS` fds. Monitors/links/PDEATHSIG orphan cleanup present.
- **Execution engine** (`src/eval.c:18528-18548`): tree-walking C recursion
  (`eval_stmt_list` → `eval_stmt` → `eval_expr`); the program counter is a local
  `size_t pc`; control flow unwinds via an `EvalResult` flag struct. No VM stack,
  no continuation, no coroutine — **pausing mid-program is not possible** without
  replacing the engine.

### 2.3 Storage, IO, network, crypto (Studio plumbing)

| Capability | Status | Cite |
|---|---|---|
| SQLite: connect/create, query/exec, **transactions**, **prepared+bound params**, last_insert_rowid | VERIFIED | `src/eval.c:11264-11287`, `10796`, `10926` |
| PostgreSQL client (query/exec/txn) | VERIFIED | `src/eval.c:12114` |
| JSON parse/emit via `encode`/`decode` (deterministic field order) | VERIFIED | `src/eval.c:15259`, `6793`, `8938` |
| File read/write/append/overwrite/list/mkdir/copy/**move**/delete; path join/basename/dirname/ext | VERIFIED | `src/eval.c:4835-5370`, `4654-4720` |
| File **mtime/size** exposed to gBASIC | ABSENT | (stat used internally only, `src/eval.c:5047`) |
| File **rename** (distinct from copy+delete `move`) | ABSENT | `src/eval.c:4951` |
| **Filesystem watching** (inotify/kqueue) | ABSENT | (no inotify anywhere) |
| `watch` = in-language reactive **value** watcher (NOT files) | VERIFIED | `src/eval.c:3578`, `reference.md:196-208` |
| General **subprocess / shell exec** | ABSENT | (only actor `spawn`, `src/eval.c:8155`) |
| Raw TCP sockets | ABSENT | — |
| HTTP **server**: single-shot buffered, `Connection: close`, **no** keep-alive/chunked/SSE/WebSocket/TLS | PARTIAL | `src/eval.c:10495`, `10204` |
| HTTP(S) **client**: arbitrary method + headers + JSON body | VERIFIED | `src/eval.c:9556`, `9299-9340` |
| HTTP client **streaming/SSE** | ABSENT | `webclient_design.md:540` |
| LLM client (Anthropic + OpenAI-compatible/local, retries, env keys) | VERIFIED | `stdlib/llm.bas:50-341` |
| LLM **streaming / tool-calling** | ABSENT | `llm_design.md:116-119` |
| Crypto: SHA/HMAC/AES-GCM/Ed25519/secure-random; password_hash (libxcrypt) | VERIFIED | `src/eval.c:14208-14344`, `13802` |
| **KDF** (PBKDF2/scrypt/Argon2) | ABSENT | `crypto_design.md:123` |
| **OS keyring / secret-service** | ABSENT | — |
| **Git** (libgit2 or CLI) | ABSENT | (and no exec to shell out) |
| Env var **read** (`env`) / **write** | PARTIAL (read-only) | `src/eval.c:13725` |

### 2.4 GUI

Two mutually-exclusive subsystems (loading both is refused, `src/eval.c:12985`):

- **`gui.*` (GTK3, `HAVE_GTK`) — a frozen 5-widget declarative POC.** Renders a
  record tree of exactly `vert`/`horiz`/`label`/`input`/`button`/`spacer`
  (`src/eval.c:2908-2935`); interaction mutates the backing record `value` and
  fires gBASIC **watchers**; the event loop is a manual `gtk_main_iteration_do`
  spin (`src/eval.c:2533-2539`). **No dynamic tree mutation after `gui.window`**
  (`docs/gui_design.md:17,394`; `examples/gui/README.md:24`). No editor, tree,
  table, tabs, panes, menus, dialogs, or drawing. **Not a viable IDE substrate.**
- **`gi.*` (GTK4, `HAVE_GIR`) — a generic GObject-Introspection FFI.** `require`,
  `new`, `get`, `set`, `call`, `invoke`, `connect`, `disconnect`, `enum`, `is_a`,
  `type_name`, `main`, `quit` (`src/eval.c:13551-13563`). Dispatch is genuinely
  generic (any introspectable type by name; walks class+interface+parent for
  methods). **Real signal handlers are gBASIC functions** via a `GClosure`
  marshaller that snapshots/restores error state (`src/eval.c:12915-12965`).
  Runtime widget construction/insertion works (`examples/gi/gtk4_hello.bas`,
  `calculator.bas` build trees inside the `activate` handler).

  **But the marshaller is a scalar/string/object/enum subset**, and this is the
  crux for Studio:
  - No **out/inout** arguments — "unsupported out/inout argument"
    (`src/eval.c:13221-13228`).
  - No **boxed/struct** types (`GtkTextIter`, `cairo_t`, `GVariant`, `GdkRGBA`,
    `GdkRectangle`), no **arrays/GList/GHash** (NULL-only), no **GError**
    (`src/eval.c:12780-12874`).
  - Signal handlers **cannot return a value** to GTK (`src/eval.c:12918`) — so no
    `close-request` handling, no event-propagation control.
  - No **subclassing / vfunc override** → no custom widgets, no custom draw funcs.
  - **No GLib idle/timeout/fd source binding** (`timeout_add`/`idle_add`/
    `io_add_watch` absent) → a running GTK loop **cannot poll an actor mailbox**;
    background work either blocks the UI or has no wired path back into it.

  Consequences: **GtkTextView/SourceView editing, Cairo drawing, TreeView/
  ColumnView/ListView models, file dialogs, and clipboard/DnD are all not
  reachable today** without new C in the bridge. Simple layout (windows, boxes,
  labels, buttons, entries, `Gtk.Grid`, property get/set, GApplication lifecycle)
  *is* reachable.

---

## 3. Feasibility of implementing Studio in gBASIC

Break the product into three layers and grade each.

### 3.1 Presentation shell (editor, widgets, panes, tabs, inline controls, viewers)

**Not feasible in gBASIC today (VERIFIED-blocked).** The editor alone requires a
multi-line text widget with syntax highlighting, cursor/scroll access, and
*inline child widgets* (branch tabs, boundary markers) embedded in the text — a
`GtkTextView` with child anchors, or `GtkSourceView`. None is reachable through
`gi` (§2.4). Tree/list/table viewers, tabs (`GtkNotebook`/`GtkStack`), and
splitters (`GtkPaned`) are *instantiable* but unproven and, for data-bound
widgets, blocked by iter/model marshalling. Building this in gBASIC-over-GTK4
first requires a large native bridge expansion (§4), after which the shell is
effectively a C achievement.

### 3.2 Execution/state engine (sections, snapshots, branches, live runtime restore)

**Partially feasible now, fully feasible only after interpreter work.** True
in-process pause/resume and live-state snapshot/restore are **infeasible**
(global state, native recursion, no `Env` serializer — §2.1/§2.2). *But* a
**re-execution ("replay") model** built on the existing actor/subprocess +
serializer + file IO is feasible today and gives most of the user-visible value
(§8). It is the right v1.

### 3.3 Backend brains (project model, persistence, agent, LLM, orchestration)

**Feasible in gBASIC now (VERIFIED building blocks).** SQLite state store, JSON
config/metadata, file IO, HTTPS client, the `llm.bas` provider abstraction, crypto
for an encrypted secrets file, and actors for isolated execution are all present.
The gaps here are additive libraries, not architectural rewrites (§4).

**Verdict:** the *brains* are gBASIC-ready; the *body* (UI) is not. This is why the
recommended architecture puts the UI outside gBASIC and keeps the brains inside it.

---

## 4. Required gBASIC / runtime / library gaps

Grouped by which layer they unblock and tagged by necessity. "REQUIRED" means
Studio (in the recommended hybrid) is impractical without it; "OPTIONAL/LATER"
means a workaround exists.

### 4.1 To make the *all-gBASIC-over-GTK4* UI path viable (large native effort)

- **REQUIRED (large):** `gi` bridge — boxed/struct marshalling (`GtkTextIter`,
  `cairo_t`, `GVariant`, `GdkRGBA`), out/inout params, array/GList marshalling,
  GError, and a way to return values from signal handlers. Without these, no
  editor, no drawing, no data-bound tree/table.
- **REQUIRED (large):** a native **text-editor widget binding** (GtkSourceView or a
  purpose-built C widget) exposing buffer text, cursor/scroll offsets, tags/marks,
  and **inline child anchors** for injected UI.
- **REQUIRED (medium):** GLib **event-source integration** (`idle_add`/`timeout_add`/
  `io_add_watch`) so actor results can reach a running GTK loop without blocking.
- **OPTIONAL/LATER:** tree/list/table model helpers, dialogs, clipboard, DnD.

Because this list is mostly C and roughly the size of writing the shell natively,
it argues *against* the all-gBASIC-GTK4 path for v1 and *for* the browser/webview
shell (§6), which needs none of it.

### 4.2 To make the execution/section/branch engine solid

- **REQUIRED (medium):** an **environment-dump / introspection** primitive — a way
  for a running program to enumerate and `serialize` its top-level variables at a
  boundary (there is no whole-`Env` serializer today; `serialize` is per-`Value`).
  This powers "changed variables at a boundary" and replay-result caching.
- **OPTIONAL/LATER (large):** the **PLAN Phase 3 interpreter-context struct**
  (`PLAN.md:580-586`) — prerequisite for in-process multi-interpreter, true
  snapshot/restore, and eventually pause/resume.
- **OPTIONAL/LATER:** expose the **256-bit RNG state** for exact capture/restore
  (`src/eval.c:77`) — needed for deterministic replay when a section consumes
  randomness; until then, capture and re-apply the 64-bit `seed()`.
- **OPTIONAL/LATER (large):** an explicit-stack / CPS execution engine for genuine
  statement-boundary pause/resume. Not needed for the replay model.

### 4.3 To make the agent and integrations complete

- **REQUIRED (small–medium):** **subprocess exec** builtin (run a command, capture
  stdout/stderr/exit). Unblocks git-CLI integration, running external tests/tools,
  and a reverse proxy. There is no `system`/`popen` today (`src/eval.c` grep).
  The fork+exec plumbing already exists for actors and can be generalized.
- **REQUIRED (small):** **file metadata** (`mtime`, `size`) and ideally a
  **filesystem-watch** builtin (inotify) — for reliable "source changed on disk"
  detection. Today there is neither, so change-detection must poll and hash file
  contents.
- **REQUIRED (small, for a good agent):** **tool/function-calling** support in
  `llm.bas` (adapter + provider JSON) so the agent's tool loop is reliable rather
  than prompt-parsed JSON. A pure-gBASIC tool loop over `ask_json` is possible as a
  stopgap.
- **OPTIONAL/LATER:** **HTTP streaming/SSE** in `webclient` (token streaming) and
  in `webserver` (push to the UI / streaming MCP transport). Both are ABSENT today.
- **OPTIONAL/LATER:** a **KDF** (Argon2/scrypt) and/or **OS-keyring** binding for
  secret handling. Workaround: AES-GCM-encrypted secrets file with the key from an
  env var or user prompt.
- **OPTIONAL/LATER:** git via **libgit2** (cleaner than CLI shelling once a
  subprocess exists).

### 4.4 Small language ergonomics that will bite Studio code (from `DOGFOOD.md`)

- **No modulo** operator/builtin — workaround `a - floor(a/b)*b` (`DOGFOOD.md`
  S6). A `mod()` builtin is worth adding.
- **`on error resume next` unwinds to the top frame** — a library function cannot
  catch a raise (e.g. `decode`) and return a fallback; it must *pre-validate*
  (`DOGFOOD.md` S13; the pattern is all over `stdlib/llm.bas`). Studio's agent-tool
  and parsing code must follow the pre-validate discipline.
- **O(n²) traps:** `arr[i]` in a `while i<count()` loop deep-copies the array each
  step; `append` copies each call. Use `for each`. Relevant to large result sets.

---

## 5. Proposed Studio architecture

**PROPOSED.** A three-tier hybrid that maximizes gBASIC ownership of logic while
not pretending gBASIC can render an IDE today.

```
┌──────────────────────────────────────────────────────────────┐
│  PRESENTATION  (browser or webview — NOT gBASIC in v1)         │
│  • CodeMirror/Monaco editor  • inline boundary + branch tabs   │
│  • right value-inspector pane • bottom console/events pane     │
│  • project picker • rich viewers (table/tree/grid/model)       │
│  Talks to the kernel over a local JSON protocol (§11, §15).    │
└───────────────▲───────────────────────────────┬───────────────┘
                │  widget/state model + events   │  semantic commands
┌───────────────┴───────────────────────────────▼───────────────┐
│  KERNEL  (gBASIC — the "brains")                               │
│  • project/workspace model      • section (cell) engine         │
│  • exploratory-branch engine     • snapshot/replay manager      │
│  • persistence (SQLite + JSON + blobs)  • semantic action log    │
│  • Agent orchestrator + tool dispatch   • LLM provider layer     │
│  Spawns isolated runners; serves the UI; enforces permissions.  │
└───────────────────────────────┬───────────────────────────────┘
                                 │  fork+exec actor (§2.2)
┌────────────────────────────────▼──────────────────────────────┐
│  RUNNERS  (gBASIC interpreter processes, one per section/branch)│
│  • run ancestry+section source  • capture stdout/vars/errors    │
│  • fully isolated; crash-safe; killable; deterministic (seed)   │
└────────────────────────────────────────────────────────────────┘
```

Why this shape:

- The **kernel-in-gBASIC** keeps "primarily in gBASIC" true for everything that
  encodes Studio's *behavior and knowledge*.
- The **runner tier reuses the actor model** (`src/eval.c:8299-8360`): every
  section/branch executes in a throwaway `gbasic` process, so a runaway loop, a
  crash, or a `flock` never touches the kernel — matching the crash-safety and
  isolation the vision needs.
- The **presentation tier** is where a rich code editor exists *for free* today. It
  is deliberately dumb: it renders a machine-readable widget/state model and emits
  semantic commands, exactly what the Agent also consumes (§11) — one model, two
  clients (human UI and agent).

The all-gBASIC-GTK4 variant remains a **long-term OPTIONAL** target: once §4.1
lands, the presentation tier could be re-hosted in gBASIC-over-`gi` behind the same
widget/state protocol, with no kernel changes.

---

## 6. UI architecture

### 6.1 Recommended: browser/webview shell (PROPOSED)

Map the vision's layout to standard web building blocks — all trivially available,
none blocked:

- Project picker: a scrollable searchable list with status filters — plain DOM.
- Main editor: **CodeMirror 6 or Monaco**, which gives syntax highlighting,
  cursor/scroll state, gutters, and **widget decorations** (CodeMirror) / **view
  zones + inline widgets** (Monaco) — the exact mechanism for injecting inline
  **execution-boundary bars** and the horizontal **branch tab strip**
  (`[ Baseline ][ Robust ][ + ]`) into the source flow.
- Right value-inspector and bottom console: resizable panes via CSS grid + a
  draggable splitter — no `GtkPaned` needed.
- Bottom file tabs with a fixed leftmost **Agent** tab and horizontal scrolling:
  a flex row with `overflow-x:auto`.
- Contextual highlight/pulse for agent teaching: a CSS class toggle on any element
  addressed by stable id (§6.3).
- Rich viewers (table/tree/grid/model): native HTML tables, tree components,
  canvas/SVG — far richer than anything `gi` can render today.

Transport between shell and kernel: because gBASIC's `webserver` is **buffered,
`Connection: close`, no SSE/WebSocket** (`src/eval.c:10204`), v1 uses
**request/response polling** (the UI long-polls a `/events` route that returns
queued semantic events as JSON). Live push (streaming agent tokens, live variable
updates) is **OPTIONAL/LATER**, gated on adding SSE/WebSocket to the webserver
(§4.3). A webview host (e.g. a tiny native shell embedding a WebView2/WebKitGTK
view pointed at the local kernel) avoids an external browser; that host is small
and language-agnostic.

Trade-off to state plainly: this shell is HTML/JS, not gBASIC. It is the price of
having a working editor in v1. The widget/state protocol (§6.3) keeps it swappable.

### 6.2 Alternative: all-gBASIC over GTK4 `gi` (OPTIONAL/LATER)

Only viable after §4.1. Even then, `GtkNotebook`/`GtkStack` (tabs), `GtkPaned`
(splitters), and simple widgets are the easy part; the editor with inline anchors,
data-bound trees, and rich model viewers is the multi-month native effort. Not
recommended for v1. If pursued, use `GtkStack` + a custom tab strip for the bottom
tabs, `GtkPaned` for the two splitters, and a `GtkSourceView` binding for the
editor — and expose the identical widget/state model so the shell stays swappable.

### 6.3 Widget/state model (PROPOSED, shared by human UI and Agent)

Every addressable UI element carries a **stable string id** independent of layout
(`editor`, `pane.inspector`, `tab.file:products_per_member_calc`, `section:7`,
`branch:robust`, `var:members`). The shell renders from, and the Agent reads/acts
on, one JSON model: `{ tabs[], activeTab, editor{path,cursor,scroll,sections[],
branches{}}, inspector{vars[]}, console{events[]}, project{...} }`. This is the
"machine-readable widget/state model rather than forcing the Agent to infer
visually" the vision asks for.

---

## 7. Persistent project/workspace model

**PROPOSED.** This is where "continuity of thought" lives: enough persisted context
that returning to a project drops the user back exactly where they left off.

### 7.1 Project metadata (deliberately small — not a PM suite)

One row per project in a global registry (`~/.config/gbasic-studio/projects.db`,
SQLite) plus the per-project `.gbasic/` store:

```
{ id, name, path, description, status, tags[], last_opened, pinned,
  git{present, remote?, branch?}, ai_rules_ref }
```

- **Lifecycle status** is a small fixed enum matching the vision:
  `Idea | Planning | Active | Paused | Maintenance | Completed | Retired`. The
  project picker is a **vertically scrolling, searchable list** with **status
  filters** and **pinned** projects surfaced first — plain list rendering over this
  table (SQLite `query` + client-side filter). `last_opened` drives recency sort.
- `git{...}` is populated only if a repo is detected (optional, §13); absence is
  normal.
- Keep the model minimal — name, path, description, status, tags, last_opened,
  pinned, git presence, and a pointer to project AI rules. Resist growing this into
  a task/issue tracker; anything richer belongs in the user's own tools.

### 7.2 Workspace restoration (the continuity contract)

Selecting a project restores its prior Studio workspace from the per-file rows in
`.gbasic/workspace.db` (§15). What is restored, and how feasible each is today:

| Restored context | Mechanism | Feasibility |
|---|---|---|
| Open files + tab order + selected tab | JSON/SQLite metadata | VERIFIED-feasible |
| Cursor + scroll position per file | metadata (editor reports it) | VERIFIED-feasible |
| Execution boundaries / sections | content-anchored metadata (§8.2) | VERIFIED-feasible |
| Breakpoint / boundary markers | metadata | VERIFIED-feasible |
| Branch graph + selected branch + overlays | branch store (§9, §15) | VERIFIED-feasible |
| Cached outputs / results per section | content-addressed blobs (§15) | VERIFIED-feasible |
| Inline result references | metadata → blob refs | VERIFIED-feasible |
| **Live runtime state at a boundary** | replay / (later) snapshots (§8.3) | PARTIAL — replayed, not resumed, in v1 |
| Git branch/working state | git (§13) | OPTIONAL/LATER |

The key honesty point: in v1 Studio restores **everything except a live
interpreter**. Reopening a project shows the exact editor layout, boundaries,
branch selection, and the **cached results** of previously-run sections; if the user
wants live variables back, Studio **replays** the relevant path (§8.3), fast because
unchanged ancestry is cached. True "resume the interpreter exactly" is the
snapshot phase (§8.3 Phase C), gated on interpreter work (§4.2).

All of this is metadata + blobs over VERIFIED primitives (SQLite, JSON,
content-addressed files) — no core-language change is needed for the *restoration*
itself; the only gap is live-state resume.

---

## 8. Execution sections and snapshots

### 8.1 Boundary model (PROPOSED, grounded in the AST audit)

From the AST: a program is a **flat top-level `AstStmtList`** and the *only* safe
seams are **between consecutive top-level statements** (`parser.y:542-549`,
`eval_stmt_list` `src/eval.c:18528-18548`). Nested bodies (while/for/if/consider/
function) execute atomically and may be re-entered by loops or jumped into by
labels; `goto`/`gosub` are **barred at top level** (`src/eval.c:18362,18372`), so
top-level seams carry no in-flight control state. Therefore:

- **A "section" = one or more contiguous top-level statements.** Boundaries **snap
  to top-level statement starts**; they may never fall inside a compound body — the
  editor should reject or snap such placements. This is exactly the "boundaries snap
  to structurally valid AST points" requirement, and the valid set is precisely
  computable from a parse.
- **Definitions vs. values.** In "script mode" (no `program` block), functions and
  modifiers register **on-reach** (`src/eval.c:18276-18282`); libraries import on
  `use`/`load`. So a section calling a function must run after the section defining
  it — Jupyter's ordering rule. Note the sharp edge: a top-level `program main`
  block changes semantics (top-level statements outside it don't run, functions are
  hoisted, `src/eval.c:18569-18605`). **Recommendation:** Studio's notebook mode
  operates on **script-mode** files; a `program` block is treated as a single
  opaque section (run whole) or disallowed in notebook mode.
- **Traditional breakpoints** are conceptually separate and, given no in-process
  pause/resume, are **OPTIONAL/LATER** (they need the CPS engine, §4.2) — v1 offers
  section-level execution, not line-level stepping.

### 8.2 Anchoring sections across edits (PROPOSED)

Nodes carry `line`/`column` but **no stable identity**; every re-parse allocates
fresh nodes (AST audit; `ast.h:125-126,167-168`). Studio must synthesize anchors:

- Track sections as **[start,end] top-level statement ranges**, re-derived on each
  parse.
- Re-associate a stored section with its edited counterpart by a **structural
  fingerprint** of each top-level statement's subtree (kind + salient names:
  `function.name`, `program.name`, `library.name`, assignment target). Named
  declarations are the most re-identifiable.
- Persist boundaries as **content anchors** (fingerprint + nearby line) not raw
  offsets, so they survive edits above them; on ambiguity, fall back to nearest
  line and flag the boundary "moved" for user confirmation.

### 8.3 Snapshot strategy — phased, replay-first (PROPOSED)

Because in-process live-state snapshot/restore is infeasible today (§2.1/§2.2),
adopt a **replay model** first and earn true snapshots later:

- **Phase A — Replay (buildable now).** Running section *k* = spawn a fresh
  `gbasic` runner that executes **the concatenated source of the selected
  root-to-*k* path** with a **fixed captured seed**, capturing stdout/events, raised
  errors, and an **environment dump** at the boundary (needs the §4.2 env-dump
  primitive; interim: a convention where the runner `encode`s a declared result
  record). Results are cached (content-addressed by the path's source fingerprint +
  seed, §15) so unchanged ancestry is not re-run. Determinism comes from the
  seedable RNG (`src/eval.c:77`) plus no wall-clock/network in pure sections.
  Restoring a project restores **cached results**, not a live interpreter.
- **Phase B — Incremental replay with warm state.** Persist each section's boundary
  env dump; when only downstream sections change, restore the nearest upstream dump
  into a runner instead of replaying from the top. Requires deserializing a dumped
  `Env` into a fresh interpreter — a bounded extension of the existing
  deserializer.
- **Phase C — True in-process snapshots.** After PLAN Phase 3 (interpreter-context
  struct) + an `Env` serializer + RNG-state capture + a live-handle policy (below),
  snapshot/restore an interpreter without full replay.

**Live handles never snapshot** (DB/socket/lock/GObject/actor-fd are rejected or
unserializable — §2.2). Policy: sections that open such handles are marked
**impure**; their results are cached but not their live state, and re-entering them
re-runs them. File *values* are just path strings and are safe
(`src/eval.c:244`).

---

## 9. Exploratory branching

**PROPOSED. Distinct from Git branches** (the vision is emphatic; keep them
separate — §13).

### 9.1 Model

- **Branch root** = a top-level section boundary. Everything above it is **shared
  ancestry**; below it, one **active root-to-leaf path** is selected among sibling
  branches (`[ Baseline ][ Robust ][ No Outliers ][ + ]`).
- Two branch kinds, matching the vision:
  1. **State-only** — same downstream source, different parameters/inputs injected
     at the root (a values record fed into the runner).
  2. **Code-overlay** — a temporary **downstream source patch** applied below the
     branch point. Overlays are **exploratory, not files and not Git branches**:
     stored as diffs against canonical source in Studio's store, materialized only
     when a runner for that branch is spawned.

### 9.2 Mechanics (built on §8's replay engine)

- A branch's result = replay(shared-ancestry ++ branch-overlay-applied-downstream,
  captured seed, injected state). The **refcounted COW record cells**
  (`src/eval.c:1256-1373`) mean the *kernel's* representation of shared ancestry
  state can be shared cheaply across branches without deep copies; the *runner*
  isolation is process-level.
- **Source fingerprinting** (§8.2) drives **stale-descendant detection**: if shared
  upstream source or state changes, every descendant branch's cached result is
  marked **stale** and visually flagged; re-running refreshes it. A branch also goes
  stale if its own overlay no longer applies cleanly to edited canonical source —
  attempt a **patch/rebase** (3-way apply of the overlay onto the new base); on
  conflict, mark the branch **needs-attention** and surface the conflict, never
  silently drop it.
- **Lifecycle:** create/rename/reorder/delete branches as pure metadata ops in the
  branch graph (§15). Deleting a branch drops its overlay + cached results.
- **Promotion:** a successful code-overlay is **promoted** by applying its diff to
  the canonical `.bas` file (an ordinary edit + a `code_edited` log entry), after
  which the overlay is retired. The `.bas` on disk is only ever touched by explicit
  promotion or normal editing — overlays never leak into it, preserving "source
  files remain ordinary `.bas`."

---

## 10. Results and variable inspection model

**PROPOSED.** Per executed section, the runner returns a structured record the
kernel stores and the UI renders:

```
{ section, console:[events], vars_changed:[{name, type, summary, ref}],
  errors:[{message, line, column, source}], seed, source_fingerprint, ts }
```

- **Changed variables** come from diffing the section's boundary env dump against
  the prior boundary's (needs §4.2 env-dump). Deep values are fetched lazily by
  `ref` via an `inspect_var(path, depth)` tool/endpoint so large structures don't
  flood the payload — this is the "avoid flooding source with large outputs" rule.
- **Rich views**, chosen by structural recognition (all data gBASIC already models):
  - array of similarly-shaped records → **table**;
  - nested record → **tree**;
  - matrix (from `stdlib/matrix.bas`) / array-of-arrays → **grid**;
  - statistical/model objects (the `stats` suite emits records with known fields) →
    **specialized viewer**;
  - **library-registered viewers** — a library exports a
    `studio_view(value) -> {kind, payload}` descriptor so a type can register its
    own Studio viewer *without any core-language change*. This satisfies the
    explicit constraint: **do not add generic `display` semantics to the core
    language**; rich presentation is Studio/library-driven, purely by convention
    over records the UI knows how to render.
- Errors carry `line/column/source` — the runner already has structured diagnostics
  (`--json-diagnostics`, `include/diagnostics.h`), so the kernel can consume the
  runner's JSON diagnostics directly rather than scraping stderr.

---

## 11. AI Agent / MCP architecture

**PROPOSED.** The Agent is a permanent surface scoped to the current project. Its
tools operate on the §6.3 widget/state model and the §8/§9 engines — i.e. they are
**semantic actions**, never coordinate clicks.

### 11.1 Tool groups (stable, provider-independent)

| Group | Representative tools (read / act) |
|---|---|
| project | `list_projects`, `open_project`, `project_status`, `set_project_status` |
| editor | `read_file`, `read_visible`, `search`, `goto`, `edit_range` (guarded) |
| execution | `list_sections`, `add/move/remove_boundary`, `run_section`, `run_to` |
| state | `list_vars`, `inspect_var(path, depth)`, `diff_vars(section)` |
| results | `get_console(section)`, `get_errors(section)`, `get_view(var)` |
| ui | `switch_tab`, `switch_project`, `scroll`, `highlight(id)`, `pulse(id)` |
| branch | `list_branches`, `create_branch`, `select_branch`, `promote_branch` |
| git | `status`, `diff`, `commit` (guarded), `push` (guarded, confirm) |
| filesystem | `list_dir`, `read`, `write` (guarded), `delete` (guarded, confirm) |
| database | `query` (read), `exec` (guarded) |
| testing | `run_tests`, `get_test_results` |

Each tool is a gBASIC function returning JSON. Because the Agent orchestrator runs
**in-process in the kernel**, the internal agent does **not** need a network MCP
transport — tools are direct calls over Studio's own state. This sidesteps the
webserver's lack of SSE.

### 11.2 Studio as an MCP *server* (OPTIONAL/LATER)

Exposing the same tool surface to *external* MCP clients (e.g. Claude Desktop) is
attractive but constrained: gBASIC can serve **plain buffered local HTTP JSON**
(the non-streaming "Streamable HTTP" subset) but **not SSE, WebSockets, or TLS**
(`src/eval.c:10204`; `webserver_design.md:444-513`). So a read-mostly MCP endpoint
is buildable now; a streaming one needs §4.3. Defer.

### 11.3 Semantic action log (PROPOSED)

A structured, append-only log (an SQLite table in `.gbasic/workspace.db`) of
`project_opened`, `file_opened`, `code_edited`, `section_executed`,
`branch_created`, `branch_selected`, `variable_inspected`, `table_filtered`,
`error_raised`, `test_run`, `git_commit`, `agent_action`, each with timestamp,
actor (human/agent), and payload. This answers "Where was I?" and "Why did this
result change?" (correlate a result delta with the edits/branch-switches between
its two runs). **Bound its size** (rolling window + periodic compaction) — an
unbounded log is a listed risk (§16).

### 11.4 Permission tiers & confirmation boundaries (PROPOSED)

Three tiers, configured globally and overridable per project (§14):

1. **Observe** (always allowed): all read tools.
2. **Act-in-Studio** (allowed by default, revocable): edits, boundary changes,
   section runs, branch ops — reversible within Studio.
3. **External/Destructive** (confirmation required each time unless durably
   allowed): git push, filesystem delete/overwrite outside the project, DB `exec`
   writes, real external HTTP the tools didn't originate, running arbitrary tests
   that touch the network. These cross Studio's boundary or are hard to undo.

### 11.5 LLM tool-calling reality

`llm.bas` has **no native tool-calling** (`llm_design.md:116-119`). v1 implements
the agent loop in gBASIC by asking the model for a JSON tool call and parsing it
with the existing non-raising validator (`ask_json`, `stdlib/llm.bas:630`). This is
serviceable but brittle; adding provider tool-calling to `llm.bas` (§4.3) is the
right medium-term fix.

---

## 12. LLM provider abstraction

**Largely VERIFIED via `stdlib/llm.bas`.** The provider layer the vision needs
already exists and is vendor-neutral:

- Constructors `llm.anthropic(model,key)`, `llm.openai(model,key)`,
  `llm.local(base_url,model)` cover Anthropic, OpenAI, and OpenAI-compatible local
  runtimes (Ollama/vLLM/Groq/Together) — **local models, OpenAI, Anthropic, and
  future providers** as the vision lists (`stdlib/llm.bas:50-62`).
- Key sourcing from arg or env var, never written to disk (`_resolve_key`,
  `stdlib/llm.bas:99`); retry/backoff on 429/5xx (`_send`, `:300`); an **injectable
  transport seam** (`with_transport`, `:71`) that makes the whole thing testable and
  lets Studio route calls through its own permissioned HTTP layer.
- The **Agent runtime is decoupled from the provider**: tools (§11.1) are gBASIC
  functions; the LLM only chooses which to call. Swapping providers is a handle
  change, not an architecture change — exactly the "must not depend on one model
  vendor" requirement.

Gaps to close for a first-class agent (§4.3): **tool-calling** (adapter work) and
**streaming** (needs `webclient` SSE). Until then, JSON-tool-call prompting +
buffered responses. Provider/model selection and the local-AI endpoint live in
global config (§14); a project may pin to local-only models for privacy (§16).

---

## 13. Git integration

**ABSENT today, and not shimmable (VERIFIED).** No libgit2, no git builtin, and —
because there is **no subprocess/`system`/`popen`** — Studio **cannot even shell
out to the `git` CLI** (`src/eval.c` grep; only actor `spawn`). Options, in order
of recommendation:

1. **REQUIRED first step:** add a **subprocess-exec builtin** (§4.3), then drive the
   **`git` CLI** for status/diff/commit/branch/push. Simplest, matches "first-class
   but optional," and reuses the existing fork+exec plumbing.
2. **OPTIONAL/LATER:** a **libgit2** native binding for richer, dependency-clean
   integration.

Git support must stay **optional** (projects work without a repo) and its mutating
operations (commit, push) sit in the **External/Destructive** permission tier
(§11.4) with confirmation. Keep the exploratory-branch graph (§9) **entirely
separate** from Git refs — they are different concepts and must never be conflated
in the UI or the store.

---

## 14. Configuration and AI rules

**PROPOSED.** Three scopes with precedence
**session > project > global** (as the vision proposes):

- **Global user config** (`~/.config/gbasic-studio/config.json`): preferred
  model/provider, local AI endpoint, UI preferences, git preferences, execution
  defaults, agent permission policy, and persistent AI rules/instructions.
- **Project config** (`.gbasic/project.json`, optionally committed): project-level
  AI rules, execution defaults, permission overrides.
- **Session instructions**: transient, highest precedence.

**Secrets never as plaintext config (VERIFIED constraint, real gap).** gBASIC has
**no OS keyring** and **no KDF** (§2.3). Recommended handling: keep API keys in
**environment variables** (which `llm.bas` already reads) or in an
**AES-GCM-encrypted secrets file** using the shipped crypto builtins
(`src/eval.c:14251`), with the encryption key supplied at launch via env var or a
user prompt — *not* stored beside the ciphertext. Document that this is weaker than
an OS keyring and flag a keyring/KDF binding as OPTIONAL/LATER (§4.3).

---

## 15. Persistence and file layout

**PROPOSED. Goal: a clean visible project folder; `.bas` files stay ordinary.**

Recommended layout — **one hidden project directory, not a proliferation of
dot-files**:

```
project/
  products_per_member_calc.bas        ← ordinary source (git-tracked)
  .gbasic/
    workspace.db        ← SQLite: per-file workspace state, boundaries,
                          branch graph, action log, result index
    config.json         ← project config + AI rules (optionally committed)
    shared.json         ← opt-in shareable subset (e.g. blessed boundaries)
    blobs/<hash>        ← content-addressed heavy snapshots / cached results
    tmp/                ← staging for atomic writes
```

Rationale and mechanics, all on VERIFIED primitives:

- **SQLite for structured state** (`workspace.db`) — transactions and prepared
  statements make it crash-safe and concurrent-write-safe
  (`src/eval.c:11264-11287`), and it collapses the per-file dot-file sprawl the
  vision warns against into one file. Per-source workspace rows key on the source
  path; this replaces the proposed `.products_per_member_calc.bas` companion (a
  leading-dot `.bas` risks being mistaken for source by other tools — avoid it).
- **JSON** (`encode`/`decode`) for human-diffable config and the shareable subset.
- **Content-addressed blobs** (`blobs/<sha256>`) for heavy items — cached section
  results and (Phase B+) env dumps — using the `sha256` builtin
  (`src/eval.c:14209`) and `serialize`/`encode` payloads. Dedup + stale-cleanup by
  hash; a blob is reachable iff referenced by a live row.
- **Atomic writes:** write to `.gbasic/tmp/` then **`move`** into place
  (`src/eval.c:4951`) — the only rename primitive available. (Note: `move` is
  copy+delete, not an atomic `rename(2)`; a true atomic-rename builtin is a small
  REQUIRED addition for strict crash-safety.)
- **Versioning:** a `schema_version` row; the store is forward-compatible-tolerant
  (unknown keys ignored) so a newer Studio doesn't corrupt an older project.
- **Stale-metadata detection:** every cached artifact stores the **source
  fingerprint** it was produced from (§8.2); a mismatch marks it stale rather than
  trusting it.

**Git policy (make explicit, per the vision):**

- **Committed by default:** `.bas` sources only.
- **Ignored by default:** the whole `.gbasic/` directory (add to `.gitignore` on
  project init) — it holds machine-local state, caches, and the action log.
- **Optionally shareable:** `.gbasic/config.json` and `.gbasic/shared.json` (blessed
  execution boundaries, project AI rules) if the team wants them versioned — an
  explicit opt-in, never automatic.
- **Never committed:** secrets, blobs, tmp, the action log.

---

## 16. Security and reliability considerations

Risks the vision names, each with the code reality and a guardrail (PROPOSED):

- **AI modifying production systems / DB writes / git push / destructive FS ops.**
  Route all such actions through the **External/Destructive tier** (§11.4) with
  per-action confirmation unless durably authorized; make every mutating tool
  return a preview/diff first. DB `exec` and git `push` are never silent.
- **Secrets.** No keyring/KDF (§2.3) — keep keys in env or an AES-GCM file with an
  externally-supplied key (§14); never log secrets; redact them from the action log
  and from any value inspector payloads.
- **Restoring stale runtime state.** The replay model (§8.3) plus source
  fingerprints (§8.2) mean a restored result is always tagged with the source it
  came from; never present a stale cached result as live — flag and offer re-run.
- **Snapshot corruption.** Content-address blobs (`sha256`) and verify on read;
  a bad blob invalidates to "must re-run," never a crash. Atomic temp+`move` writes
  avoid torn files.
- **Huge datasets / unbounded logs.** The action log is **bounded** (rolling +
  compaction, §11.3); large results live as blobs fetched lazily by `ref` (§10), not
  inlined; watch the O(n²) `append`/index traps (§4.4) in any accumulation code.
- **External resources that can't be rewound.** Mark sections that do network/DB/
  file-mutation as **impure** (§8.3); replaying them re-executes side effects —
  warn before replaying an impure section, and prefer state-only branches there.
- **Branch overlays diverging from source.** 3-way rebase with explicit
  conflict surfacing (§9.2); never silently discard an overlay.
- **Runner isolation.** Each section/branch runs as a **separate OS process**
  (`src/eval.c:8299-8360`) with `PDEATHSIG` cleanup — a crash, infinite loop, or
  `flock` cannot take down the kernel; runners are killable and resource-bounded.
- **Local vs. cloud model privacy.** The provider is a per-call choice
  (`llm.local` vs cloud, §12); Studio should let a project **pin** to local-only
  models and warn when project content would be sent to a cloud provider.

---

## 17. Recommended implementation phases

Sequenced so each phase ships something usable and grows the gBASIC share.

- **Phase 0 — Foundations (mostly gBASIC + a few small C builtins).**
  Add the small REQUIRED builtins that everything leans on: **subprocess exec**,
  **file mtime/size**, **atomic rename**, and an **env-dump/serialize-all-top-level
  vars** primitive. Build the `.gbasic/` SQLite store, JSON config, and the
  semantic action log in gBASIC. *No UI yet.*
- **Phase 1 — Kernel + minimal shell.** gBASIC kernel: project model, file
  open/save, the **section engine with replay** (§8.3 Phase A), structured result
  capture (§10). A minimal browser/webview shell (§6.1) with a CodeMirror editor,
  boundary bars, a console pane, and a variable pane over the widget/state model
  (§6.3), talking to the kernel by polling.
- **Phase 2 — Agent.** Agent orchestrator + tool dispatch (§11) over `llm.bas`;
  read tools first, then Act-in-Studio tools, then guarded External tools with
  confirmation and permission tiers. JSON-tool-call prompting until `llm.bas`
  tool-calling lands.
- **Phase 3 — Branching.** Exploratory-branch engine (§9): state-only, then
  code-overlay branches; inline branch tab strip; stale detection; promotion.
- **Phase 4 — Rich views & Git.** Library-registered viewers (§10); table/tree/grid
  recognizers; Git integration via the Phase-0 subprocess (§13), optional and
  guarded.
- **Phase 5 — Depth (OPTIONAL/LATER).** Streaming (webclient/webserver SSE) for live
  agent tokens and push updates; `llm.bas` native tool-calling; true snapshots
  (§8.3 Phase C) after PLAN Phase 3; MCP-server surface; a keyring/KDF binding.
- **Phase 6 — All-gBASIC UI (OPTIONAL/LATER, large).** Only if desired: expand the
  `gi` bridge (§4.1) and re-host the presentation tier in gBASIC-over-GTK4 behind
  the unchanged widget/state protocol.

---

## 18. Open design questions

1. **Notebook mode vs. `program` blocks.** Confirm that Studio's incremental mode
   targets script-mode files and treats a `program main` block as opaque/disallowed
   (§8.1). Does Studio need incremental execution *inside* a `program` block, and if
   so how (it would require the hoisting semantics)?
2. **Determinism boundary.** Replay assumes captured-seed determinism; how are
   sections that read wall-clock (`now`), files, DB, or network treated — always
   impure and re-run, or memoized with a staleness policy? What is the UX when a
   replay's side effects are not idempotent?
3. **Env-dump granularity.** Should the boundary env dump capture *all* top-level
   variables or a user-declared result set? All-vars is automatic but can be heavy
   and includes unserializable handles; declared-results is precise but manual.
4. **Editor host decision.** Browser vs. embedded webview vs. (later) GTK4 — the
   single biggest product decision, gating §6/§4.1. Recommendation: embedded webview
   for a desktop feel without an external browser.
5. **Shell language.** Accept HTML/JS for the shell in v1, or invest up-front in the
   `gi` bridge to keep it gBASIC? (Report recommends the former.)
6. **Multi-window / multiple projects open at once.** The vision implies one active
   project; is concurrent multi-project needed, and does the polling transport scale
   to it?
7. **Snapshot retention & GC.** Policy for evicting cached results/blobs (LRU by
   size? keep only the active path + N?) to bound `.gbasic/` growth.
8. **Overlay rebase semantics.** Exact 3-way merge behavior and conflict UX when
   canonical source edits collide with a live branch overlay (§9.2).
9. **Agent write-safety.** Should agent `edit_range` operations always land as a
   *proposed diff* the user accepts, or may the agent edit directly under
   Act-in-Studio permission? (Report leans: propose-diff by default, direct only
   with explicit per-project opt-in.)
10. **MCP exposure.** Is exposing Studio as an external MCP server in-scope, given
    the buffered-HTTP-only constraint (§11.2)?

---

## Closing recommendation

> **Can gBASIC Studio realistically be implemented primarily in gBASIC, and what
> must be added to gBASIC first to make that a sound choice?**

**Not as a self-contained GTK desktop IDE today — but yes for its brains, under a
hybrid architecture, and increasingly so over time.** The blocker is not gBASIC's
*logic* capabilities (which are strong: LLM abstraction, SQLite, JSON, file IO,
crypto, and process-isolated actors are all shipped and verified) but its *UI* and
*persistent-execution* capabilities. The `gi` GTK4 bridge cannot render a code
editor (no `GtkTextView`/`GtkSourceView` editing, no inline anchors, no data-bound
trees — the marshaller is scalar/object-only), and the interpreter cannot pause,
resume, or snapshot live state in-process (global state, native recursion, no `Env`
serializer).

The sound choice is to **write Studio's kernel — project model, section/replay
engine, branch engine, persistence, agent, and provider layer — in gBASIC**, and to
**render its UI in a browser/webview** where a rich editor exists for free, behind a
machine-readable widget/state protocol that keeps the shell swappable (and re-
hostable in gBASIC-over-GTK4 later).

To make even that hybrid comfortable, add these to gBASIC **first**, in rough order:

1. **Subprocess-exec builtin** (unblocks Git, external tests/tools, reverse proxy).
2. **File metadata (`mtime`/`size`) + atomic rename** (unblocks change-detection
   and crash-safe writes); ideally a **filesystem-watch** builtin.
3. **Environment-dump / serialize-all-top-level-vars** primitive (unblocks the
   replay engine's variable diffs and result caching).
4. **`llm.bas` tool-calling** (unblocks a reliable agent loop).

And to progressively *increase* the gBASIC share (all OPTIONAL/LATER, larger):

5. **PLAN Phase 3 interpreter-context struct** + an **`Env` serializer** + **RNG
   state capture** (unblocks true snapshots and multi-interpreter).
6. **HTTP streaming/SSE** in webclient/webserver (unblocks token streaming, push
   UI, streaming MCP).
7. **`gi` bridge expansion** (boxed/out-param/array marshalling, a text-editor
   binding, GLib event sources) — the prerequisite for an all-gBASIC GTK4 UI.

With items 1–4, a genuinely useful, mostly-gBASIC Studio is buildable. Items 5–7
turn "mostly" into "primarily," including — eventually — the UI itself.
