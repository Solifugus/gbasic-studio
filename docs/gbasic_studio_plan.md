# gBASIC Studio — Implementation Plan (Phase 0 architecture)

Status: **build-ready plan, not implemented.** This is the Studio equivalent of
`docs/gbasic_native_app_platform_plan.md`: an ordered, phased engineering plan that
turns the product/system design into buildable, one-session-at-a-time work now that the
Native Application Platform (NAP-0..NAP-13) is **complete and accepted**.

It **consumes** the completed platform and does not redesign any of it. It owns only the
Studio-specific gBASIC (project model, workspace, section/branch engine, replay, agent
orchestration, persistence). Source-of-truth documents it sits on top of:

- `docs/gbasic_studio_design.md` — Product & System Design (§1–23, MVP, milestones). The
  **what/why/behavior**. This plan references its sections rather than restating them.
- `docs/gbasic_studio_research.md` — feasibility study.
- `docs/gbasic_studio_gtk_requirements.md` — first-pass GTK/GI requirements.
- `docs/gbasic_native_app_platform_coverage.md` — platform coverage survey + capability
  matrix.
- `docs/gbasic_native_app_platform_plan.md` — the completed platform build (NAP-0..13,
  all DONE).

Where the design doc tags things REQUIRED/PROPOSED/DEFERRED, this plan converts them into
**phases** with dependencies, acceptance criteria, tests, and explicit out-of-scope
boundaries. Conventions follow the NAP plan exactly: byte-exact goldens, **one phase per
session, stop at each boundary for review**, headless-first tests, display tests under
`G_DEBUG=fatal-criticals`, valgrind on any new C path.

**Naming:** phases are `STU-n`. No phase implements a later phase's surface early.

---

## Vision

(Full treatment: `docs/gbasic_studio_design.md` §1. Summarized here so the plan stands on
its own.)

gBASIC Studio is the **desktop environment for anything a user makes or does with
gBASIC** — application development and maintenance, ETL, statistical analysis, research,
financial analysis, reporting, debugging, production support, exploratory programming — as
one mixed workload, with analytics being *one* workload among many, not the point.

Its organizing principle is **continuity of thought**: a user interrupted mid-task (pulled
onto a production bug, then an ETL failure) must be able to return — hours or days later —
to substantially the same intellectual *and computational* context they left. So:

> A **Studio project is a resumable working context**, not merely a folder of files.

The folder of `.bas` sources stays the canonical, Git-friendly, independently-runnable
artifact; the *working context* (open files, cursors, execution sections, results,
exploratory branches, agent context) is everything Studio layers **around** those files —
never inside them. Studio fuses three things usually kept apart — ordinary source files,
IDE editing/debugging, and Jupyter-style incremental execution — **without putting cells
into the language**, and pairs them with a first-class AI Agent that can put you back into
your work.

## Design principles

(Full list: `docs/gbasic_studio_design.md` "Design Principles" §. The load-bearing ones for
this plan:)

1. **Source is inviolate.** A `.bas` stays ordinary, runnable, Git-clean gBASIC. Studio
   overlays; it never rewrites the file format (design §2.1).
2. **Metadata beside, never inside.** One `.<filename>` per source; one consolidated
   `.gbasic/` for the rest; heavy state is regenerable and disposable (§2.2, §19).
3. **The project is a resumable working context**, not a folder — everything serves
   continuity of thought (§1).
4. **User abstraction over mechanism.** Persistent execution, restoration, and branching
   are specified against user-facing concepts; the mechanism (replay → checkpoints →
   snapshots) may evolve underneath without changing the UX (§8).
5. **Replay-first, snapshots-later.** Correct-by-replay now (forced by the non-reentrant
   evaluator); climb the fidelity/performance ladder without a UX change (§8.2).
6. **Honest state.** Never attach stale or re-executed effects to a result silently; favor
   explicit provenance and safe invalidation (§8.3, §9.3).
7. **Boundaries organize; breakpoints interrupt.** Keep the two models distinct (§5.2).
8. **Studio branches are not Git branches.** The only crossover is promotion into canonical
   source (§2.3, §18).
9. **Generalize by default.** If another sophisticated gBASIC app would want it, it belongs
   in the platform/runtime/library layer, not in Studio. Reserve native C for the one
   justified component (the general DataGrid) (§2.5, §20).
10. **The Agent is a first-class surface, powered by tools + context, not a vendor.** The
    same semantic tool layer serves user and Agent; provider-neutral (§11–§15).
11. **Semantic, not pixel.** Every action has a stable machine identity; the Agent observes
    and acts through the same semantic operations the UI uses (§12).
12. **Safe by tier.** Read is free, local actions configurable, external/destructive actions
    gated and audited (§17).
13. **Bounded and crash-safe.** Atomic writes, versioned schemas, compacted history,
    deletable caches (§19.2).

These are additionally operationalized as the per-phase **Global rules** below and the
**Risks** section (which carries forward the specific regression lessons from the completed
platform phases).

## Global rules (apply to every phase)

- [ ] Golden tests are **byte-exact**. Any stdout/stderr diff is a regression, never a
      silent rebaseline, unless explicitly approved for that specific diff.
- [ ] **One phase per session.** Stop at each `STU-n` boundary for review.
- [ ] **Studio is gBASIC.** No Studio-specific native C. If a capability tempts toward C,
      apply the platform test — *"would another sophisticated gBASIC desktop app need
      this?"* — and if yes it is a **general platform** addition (its own plan/phase,
      decided separately), never a Studio-private native path. The design's §2.5/§20
      verdict stands: the only native component in the whole stack is the general
      `DataGrid`, which Studio merely consumes.
- [ ] **Source is inviolate** (design §2.1). Nothing Studio does writes Studio metadata,
      cell markers, boundaries, or overlays *into* a `.bas`. Everything lives beside
      source (`.<filename>` + `.gbasic/`, design §2.2/§19).
- [ ] Prefer **headless** tests. The persistence spine, project model, boundary/anchor
      engine, replay orchestration, action history, and agent tool layer are all designed
      to be exercised without a display (mirroring `run_process.sh`/`run_nap_fs.sh`).
      GUI-only behavior is a **manual display checklist** recorded in the phase and a
      parse-only CI smoke (mirroring `run_gui_parse.sh`).
- [ ] Display-backed GTK tests run under `G_DEBUG=fatal-criticals` so any GLib lifetime
      assertion fails the suite. Any new C path (there should be none Studio-specific)
      runs under valgrind (0 leaks / 0 errors).
- [ ] **Atomic, versioned persistence.** Every store carries a schema version and is
      written via `atomic_replace` (NAP-10). A crash mid-write must never corrupt a store
      or the source tree. `.gbasic/` is always regenerable/deletable (design §19.2).
- [ ] **Strict JSON on every external/interchange boundary.** Use `json_encode` /
      `json_encodable`, **never** `encode`, for anything a non-gBASIC tool reads (config
      files meant to be hand-edited, LLM/API payloads, git-adjacent manifests). `encode`
      remains internal-only. (Carries the NAP-13 finding forward as a rule.)
- [ ] `make dev` green + the full battery at every boundary; a new `tests/run_studio*.sh`
      runner per phase, registered in CLAUDE.md, skipping cleanly when a display or
      optional dep is absent (never falsely gating headless coverage behind GI — the
      NAP-6 lesson).

---

## Layer legend

**S(model)** headless Studio gBASIC (project/persistence/boundary/replay/history/agent —
no display) · **S(ui)** Studio GTK composition over `gtk.bas`/`gtkui`/`sourceeditor` ·
**S(agent)** agent runtime over `llm.bas` + the semantic tool surface · **plat?** a
*candidate general-platform prerequisite* this plan surfaces but does not itself build.

Design principle throughout: **S(model) before S(ui).** Every Studio subsystem is built
as a headless, testable gBASIC model first, and the GTK composition is a thin view over
it. This is what makes Studio testable without a display and keeps the agent's semantic
action layer identical to the UI's (design §12).

---

## Platform assumptions (what each subsystem consumes)

Studio composes the **completed** platform. Verified public surfaces, by subsystem — this
is the contract; none of it is re-specified or re-implemented here.

| Studio subsystem | Consumes (completed platform) | Real API used |
|---|---|---|
| App shell, window, panes, tab strip | NAP-7 `gtk.bas` | `gtk.application`/`gtk.application_window`/`gtk.box`/`gtk.paned`/`gtk.scrolled`/`gtk.notebook`/`gtk.listbox`/`gtk.button`/`gtk.label`/`gtk.connect`/`gtk.enum` |
| Dynamic UI (tab strip, picker rows, inline section/branch widgets, inspector tree) | NAP-11 `gtkui` reconciler | `gtkui.mount`/`update`/`unmount`/`root`/`lookup`; nodes are record literals `{type,props,signals,children}`; native embed via `widget:` field |
| Source editor, gutter marks, inline anchors, highlight | NAP-7 `sourceeditor` (over GtkSourceView 5) | `sourceeditor.create()` → record; `ed.get_text/set_text/set_language/cursor/set_cursor/mark/highlight/unhighlight/on_change/view/scroll_to/add_inline` |
| Structured value inspection (right pane) | NAP-9 reflection | `reflect.variables()`/`get(name)`/`kind`/`type`/`category`/`serializable`/`count`/`fields`/`field`/`element`/`inspect` (own-frame scope) |
| Section execution, out-of-process runs, tests | multiprocessing + NAP-6 | `spawn fn(args)` → actor handle; `send`/`receive`/`self`/`monitor`/`demonitor`; `process.run({command,args,cwd,timeout})` → `{exit_code,stdout,stderr,success,signal,timed_out}` |
| Async results delivered without UI freeze | NAP-3 loop integration | `gi.watch_mailbox(fn)` (actor frame on the loop thread), `gi.timeout`/`gi.idle`/`gi.watch_fd`/`gi.source_remove` |
| State capture / replay checkpoints | multiprocessing serialization | per-`Value` `serialize`/`deserialize` (magic `gBS` v1); refuses live GObject/DB handles (honest §8.3 exclusion) |
| Persistence: metadata, config, manifests | NAP-10 + strict JSON + sqlite | `atomic_replace(temp,dest)`, `file_size`, `file_mtime`; `json_encode`/`json_encodable`; `sqlite.*` (behind `HAVE_SQLITE3`) for append-heavy history/registry |
| Large analytical tables | NAP-12 `datagrid` | `datagrid.new_registry()` (program-global `_DATAGRID`), `create`/`create_virtual`/`add_column`/`widget`/`selection`/`cell`/`row_count`/`selected`/`refresh`/`set_rows`/`set_count`/`destroy`/`destroyed` |
| Agent LLM + tool-calling | NAP-13 `llm.bas` | `llm.anthropic`/`openai`/`local`/`offline`/`with_transport`; `llm.tool(name,desc,schema,fn)`/`tool_error`/`with_tools`/`with_max_tool_rounds`/`run_tools`/`tool_calls`/`execute_tools`/`append_tool_results`/`chat`/`ask`/`ask_json`; a tool is a plain record whose body is an ordinary gBASIC function of one record arg; the registry is the sole dispatch authority (arguments arrive parsed as JSON, **never** evaluated as source) |
| Git integration (optional) | NAP-6 process API | `process.run` invoking `git` (no bespoke binding) |
| Efficient branch/state substrate (later) | COW value model | arrays/records are refcounted copy-on-write **by value** (transparent; no user API) — the natural substrate for cheap branch snapshots |
| Structural boundary anchoring (STU-3) | **plat?** — *gap* | The front end is reentrant in C (`libgbasic.a`/`gb_parse_ctx`, used by `gbasic-lsp`), but there is **no gBASIC-reachable parse/AST/outline API today**. See Risks R1 — a general outline/parse facility is the one candidate platform prerequisite Studio surfaces. |

---

## Major subsystems

Each maps to a design-doc section (the authority) and is realized by one or more phases
below. These are the parts, not a schedule — the schedule is the phase list.

1. **Project model & registry** — resumable working context, lifecycle status, picker
   (design §1, §3). → STU-0, STU-1.
2. **Persistence spine** — `.gbasic/` + `.<filename>` schema, versioned stores, atomic
   writes, logical stores (design §2.2, §19). → STU-0.
3. **Workspace shell** — window, resizable/collapsible panes, `[Agent] | file-tabs`
   strip (design §4). → STU-1, STU-2.
4. **Editor & tabs** — SourceEditor integration, per-file cursor/scroll, tab
   order/selection persistence (design §4, §5, §6.1). → STU-2.
5. **Execution-section engine** — boundaries as structural anchors, snap/move/merge,
   drift re-resolution, breakpoints distinct from boundaries (design §5). → STU-3.
6. **Persistent execution / replay** — replay-first section execution in actors,
   provenance, pure/effectful tagging (design §8). → STU-4.
7. **Contextual results model** — per-section console + right-pane state/inspection,
   viewer dispatch, modest tables (design §6, §7). → STU-5.
8. **Suspension / restoration** — cheap layer instant, expensive state lazy, graceful
   degradation (design §10). → threaded through STU-1/2/4, consolidated in STU-5.
9. **Semantic action history** — structured event log, rollups, "Where was I?" substrate
   (design §14). → STU-6.
10. **AI Agent runtime** — read-only first, then full observe+act over a semantic tool
    surface, teaching, permissions, selectable providers (design §11–§17). → STU-6
    (read-only), STU-10 (full).
11. **Exploratory branching** — state-only then code-overlay, staleness/rebase (design
    §9). → STU-7, STU-9.
12. **Rich viewers & large data** — library-registered viewers + DataGrid tier (design
    §6.2, §7). → STU-8.
13. **Git integration** — optional, over `process.run` (design §18). → STU-11 (additive).
14. **Layered configuration & secrets** — session>project>global, secure credential
    storage (design §16, §17). → STU-0 (config scaffold), STU-10 (secrets/permissions).

---

## Dependency graph

```
STU-0 persistence spine + project model + config scaffold  (S(model), headless)
  → STU-1 workspace shell + project picker                 (S(ui))
     → STU-2 editor + file tabs + cheap-layer restore       (S(ui))   ─┐
  → STU-3 execution-section engine (anchors, snap/merge)    (S(model)) │  [needs plat? R1]
     → STU-4 section execution via replay actors            (S(model)+S(ui))
        → STU-5 contextual results + inspection + modest tables (S(ui))
           → STU-6 read-only Agent + action history          (S(agent)) ── MVP COMPLETE
                                                                        ─┘
Post-MVP (each gated on its stated predecessor; otherwise independent):
  STU-7  state-only exploratory branches            (needs STU-4, STU-6 history)
  STU-8  rich viewers + large DataGrid              (needs STU-5; consumes NAP-12)
  STU-9  code-overlay branches + promote/rebase     (needs STU-7)
  STU-10 full Agent: act-tools + permissions + teaching + multi-provider + secrets
                                                    (needs STU-6; consumes NAP-13)
  STU-11 Git integration (additive)                 (needs STU-1; over process.run)
```

**MVP = STU-0 … STU-6** (design's "Studio 0 + core of Studio 1 + minimal read-only
Agent"). STU-7…STU-11 are the design's Studio 2–4, deferred off the MVP critical path.

---

## STU-0 — Persistence spine, project model & config scaffold · S(model) — headless

**Purpose.** Build the resumable-context substrate before any UI: the on-disk schema,
the project data model, and versioned/atomic reads and writes. Everything else hangs off
this, and it must be fully testable with no display.

**Scope.**
- `stdlib/studio/` library tree (pure gBASIC). A `studio.store` module: versioned
  read/write of a logical store (§19.1) as strict JSON via `json_encode`, written through
  `atomic_replace` to a temp sibling then renamed (crash-safe). Every store record carries
  `{schema_version, ...}`; unknown newer fields preserved on read, older migrated.
- The **`.gbasic/`** layout (project manifest, workspace state, heavy-state/cache dirs)
  and the **`.<filename>`** per-file dot-metadata format (§2.2) — creation, resolution of
  the 1:1 source↔dotfile mapping, and safe deletion (regenerable).
- **Project registry** (global, outside any project): the picker's backing list —
  name·path·description·status·tags·last-opened·pinned·git-present (§3.3). SQLite where
  append/query fits, else a manifest; decided and recorded in-phase.
- **Project model** object: open(path) → project; save/suspend(project) → persists
  workspace state + per-file metadata; a pure data model with no UI (§1, §10.1 data only).
- **Config scaffold**: layered `session > project > global` resolution (§16) as data
  (no secret storage yet — that is STU-10).

**Dependencies.** NAP-10 (`atomic_replace`/`file_size`/`file_mtime`), `json_encode`/
`json_encodable`, `sqlite` (optional; degrade to manifest when `HAVE_SQLITE3` absent).

**Acceptance criteria.**
- Round-trip a project through save→suspend→restore of the **data model** (registry entry,
  workspace state, per-file metadata) with byte-stable JSON.
- A simulated crash mid-write (write temp, do not rename) leaves the previous store intact
  and readable; `atomic_replace` makes the new store appear atomically.
- Schema-version up/down: a store written at v1 reads under a v2 reader with unknown
  fields preserved; a v0 fixture migrates.
- Deleting `.gbasic/` loses working context but never source; re-open regenerates a clean
  skeleton.

**Tests.** `tests/run_studio_store.sh` — GI-independent, never skips. Fixtures for
round-trip, crash-safety (temp-left-unrenamed), schema migration, dotfile 1:1 mapping,
strict-JSON assertion (`json_encodable` preflight true; `encode` **not** used). Negatives:
corrupt store, missing source for a dotfile, unwritable dir.

**Out of scope.** Any window/widget; editor; execution; boundaries; agent; secrets/keyring;
git. No `.bas` is parsed or run in this phase.

**DONE (2026-07-25).** The persistent backbone is implemented as five pure-gBASIC
stdlib libraries plus a thin entry point, all headless and testable without a display:
`stdlib/studio_json.bas` (a non-raising JSON validity gate — pre-validate before
`decode`, since gBASIC cannot catch a raise), `stdlib/studio_store.bas` (versioned,
crash-safe persistence: `json_encode` → write `.tmp` → `atomic_replace`; defensive
`read_status` reporting missing/corrupt/loaded), `stdlib/studio_model.bas` (the
settings/session/workspace/project/document model with counter-minted stable ids
`ws-N`/`proj-N`/`doc-N`, forward/back-compatible `normalize_*`, and future-version
detection), `stdlib/studio.bas` (the application object + deterministic startup/shutdown
pipelines + empty future-hook managers), and `stdlib/studio_shell.bas` (the minimal
GTK4 shell view). Entry: `examples/studio/studio.bas` (arg-dispatched modes). Full
reference: `docs/gbasic_studio_stu0.md`. Tests: `tests/run_studio.sh` (empty startup,
save/restore across a simulated relaunch incl. window state, corrupt-session recovery,
future-version rejection, 30× atomic save/reload stress, valgrind-clean 50-cycle memory
probe) — all pass; the shell parses in CI (`run_gui_parse.sh`) and its display smoke
runs clean under `G_DEBUG=fatal-criticals`. Zero unrelated rebaselines; `make dev` green.

**Deviations from this section's original sketch (both follow the accepted STU-0 session
brief):** (1) **A minimal application shell window is included** (header/menu placeholder,
empty nav pane, placeholder editor area, status bar), which this plan had slated for
STU-1 — the brief asked STU-0 to prove the architecture end-to-end with just enough UI.
The **project picker** itself remains STU-1. (2) **Persistence uses a config-home with
three JSON stores** (`settings.json`, `session.json`, `workspaces/<id>.json`) rather than
the `.gbasic/` per-project dot-metadata layout + SQLite registry sketched above. The
workspace/project/document/session/settings model and stable-id contract are delivered;
the SQLite-backed **project registry**, per-source **dot-metadata**, and the `.gbasic/`
per-project directory are deferred to the phases that first exercise them (registry →
STU-1 picker; dot-metadata → STU-2 per-file cursor/scroll). No JSON store uses `encode`;
all use `json_encode`. See DOGFOOD (2026-07-25) for the frictions hit.

---

## STU-1 — Workspace shell & project picker · S(ui)

**Purpose.** The application skeleton and the first-class project-selection experience;
restore the cheapest layer (window + layout) instantly.

**Scope.**
- `studio` app entry: `gtk.application` + `gtk.application_window`; main layout from
  `gtk.box`/`gtk.paned`/`gtk.scrolled` — editor area + collapsible right inspector pane +
  collapsible bottom console pane + a bottom `[Agent] | file-tabs` strip shell (§4). Panes
  are resizable/collapsible; sizes persist via STU-0.
- **Project picker** (§3.1): a modal over `gtk.listbox` (rows, not virtualized — hundreds/
  thousands fine, coverage §2), incremental search, status filters, pinned/recent to top,
  per-row `⋯` actions (open/pin/status/reveal/edit/remove-from-registry — never deletes
  files). Built as a `gtkui` tree so rows reconcile on search/filter.
- Wire registry (STU-0) → picker → open → workspace; on close, suspend workspace state.
- Restore **cheap layer** on reopen: window geometry, pane sizes/collapse, selected
  project (§10.3 top row), instantly and non-blocking.

**Dependencies.** STU-0; NAP-7 `gtk.bas`; NAP-11 `gtkui`.

**Acceptance criteria.**
- Launch → picker lists registry projects with search/filter/pin working; open → workspace
  window with the three panes and the tab-strip shell; collapse/resize a pane, close,
  reopen → layout restored.
- Picker handles a synthetic registry of 1,000+ projects without virtualization lag
  (GtkListBox, coverage §2).
- `remove-from-registry` drops the entry, leaves files on disk.

**Tests.** Headless tier: picker model + search/filter/sort logic driven without a display
(the `gtkui` node tree is a data structure — assert reconcile output). Display smoke
(`G_DEBUG=fatal-criticals`, gated on GTK4 typelib + a display): open picker, open a project,
collapse/restore panes, self-quit with a deterministic transcript. Parse-only CI smoke via a
`run_gui_parse.sh`-style entry.

**Out of scope.** Editor/tabs content (STU-2); any execution; agent; branches.

**DONE (2026-07-26).** Additive to the frozen STU-0 backbone (STU-0 stores/goldens
untouched). Delivered per this session's STU-1 brief, which emphasized **workspace
navigation + a filesystem project browser** over the picker-modal sketch above:
`stdlib/studio_browser.bas` (scan a project dir into a folders-first/sorted/lazily-
expanded tree; `flatten`/`visible_count`/`dump`; graceful empty on missing/unreadable
dirs), `studio_model.bas` extended with nav state (`nav.selected_path` + `expanded`
set) and project `remove_project`/`rename_project`/`project_by_id`, `studio.bas`
extended with a **workspace registry** (`<home>/workspaces.json`) + `launch`/`persist`
+ `create_registered_workspace`/`open_workspace`/`rename_workspace`/`close_workspace`
+ recent-list + `nav_summary`, and `studio_shell.bas` rendering the browser tree +
project list + status. Reference: `docs/gbasic_studio_stu1.md`. Tests: `run_studio.sh`
gains STU-1 cases (workspace lifecycle + multiple projects + navigation persistence via
`stu1_build`→`stu1_restore`, missing-project no-crash, browser correctness, tree
refresh, registry+recent, valgrind-clean 50-cycle memory) — all pass; shell parses in
CI and its display smoke renders clean under `G_DEBUG=fatal-criticals`. Full battery
green, zero unrelated rebaselines; `make dev` clean.

**Deviations from this section's original sketch (per the STU-1 session brief):** the
emphasis is a **filesystem project browser + workspace registry/switcher**, not the
search/filter/pin **project-picker modal** or the collapsible right-inspector / bottom-
console / `[Agent]`-tab-strip panes. Those panes and the picker's search/filter/pin
affordances are **deferred** — the right-inspector + bottom-console arrive with the
execution/results phases (STU-4/STU-5), the `[Agent]` tab with STU-6, and the picker's
richer affordances can layer onto the registry when needed. Persistence uses the
STU-0 config-home + JSON stores plus the new registry store (no SQLite/dot-metadata),
consistent with the STU-0 completion note.

---

## STU-2 — Editor, file tabs & cheap-layer file restore · S(ui)

**Purpose.** Real editing: open files into SourceEditor tabs with gBASIC highlighting;
persist and restore the file-level working view. Completes design "Studio 0".

**Scope.**
- Integrate `sourceeditor.create()` per open file; `ed.set_language("gbasic")` for
  highlighting; embed `ed.view()` in a tab page.
- **Tab strip** (§4): `[Agent]` fixed far-left (placeholder tab), file tabs scroll
  horizontally in a `gtk.scrolled`; reconciled via `gtkui` (keyed children for stable
  reorder). Per-tab indicators: modified `•`, error `!`, running/queued dot.
- Persist/restore (via STU-0 dotfiles + workspace state): open-file set, tab order,
  selected tab, per-file cursor (`ed.cursor()`/`set_cursor`) and scroll (`scroll_to`).
- Diagnostics surfacing: gutter marks + squiggles from `--json-diagnostics` (existing) via
  `ed.mark` / `ed.highlight`; opening a file with a parse error flags its tab `!`.

**Dependencies.** STU-1; NAP-7 `sourceeditor`; existing `--json-diagnostics`.

**Acceptance criteria.**
- Open several files → tabs with highlighting; reorder, select, edit (dirty `•`), close;
  reopen project → same open set, order, selection, cursor, scroll restored instantly.
- A file that fails to parse shows `!` and gutter diagnostics without crashing the editor.
- A file moved/deleted since suspend degrades gracefully (§10.3): the rest open; the
  missing tab is flagged, not fatal.

**Tests.** Headless: tab-model logic (open/close/reorder/select/dirty/error state) as a
data structure; dotfile cursor/scroll round-trip; diagnostics→mark mapping. Display smoke:
open→edit→reorder→reopen restore, under fatal-criticals. Reuse `sourceeditor`'s own
lifecycle guarantees (keeps its `_lm` alive — do not re-solve).

**Out of scope.** Execution boundaries or running code (STU-3/4); inspector content
(STU-5); agent.

**DONE (2026-07-26).** Additive to STU-0/STU-1 (their stores/goldens byte-exact). A
coherent document lifecycle owned by a headless document manager, with the editor as a
view: `stdlib/studio_docs.bas` (new) — the authoritative open-document store: stable
`doc-N` ids, canonical-path de-dupe (lexical, documented), safe open (reuse / directory
guard / missing → flagged, never crashes), content-vs-saved dirty derivation, in-place
save (perms/symlink-preserving; parent-dir pre-validated; failure keeps the buffer
dirty), explicit close policy (save/discard/cancel), external-change detection
(`file_size` + `number(file_mtime)`) with a safe checkpoint (clean→reload,
dirty→conflict, deleted→missing), and metadata-only persistence (`to_meta`/`from_meta`,
buffers re-read from disk). `studio_model.bas` gains a workspace `docs` field (additive,
normalized in). `studio.bas` `launch` rebuilds `app.dm` and `persist` folds it back,
plus `open_file`/`edit_document`/`save_document`/`save_all_documents`/`close_document`/
`checkpoint_documents`/`docs_summary`. `studio_shell.bas` renders a `GtkNotebook` of
SourceEditor tabs (gBASIC highlighting; `*`/`!` markers). Reference:
`docs/gbasic_studio_stu2.md`. Tests: `run_studio.sh` gains 11 STU-2 cases (lifecycle +
disk-save + savefail + close×3 + external + restore + missing-restore + browser +
valgrind 40-cycle memory) — all pass; display smoke shows a real dirty editor tab under
`fatal-criticals`. Full battery green, zero unrelated rebaselines; `make dev` clean.

**Deviations (per the STU-2 session brief):** (1) the emphasis is the **document
lifecycle** (open/edit/dirty/save/close/external-change/restore) with a **notebook**
tab layout; the horizontally-scrolling `gtkui`-reconciled tab strip, the fixed-left
`[Agent]` tab, and reorder are deferred (Agent tab → STU-6; a reconciled strip can
replace the notebook when tab reordering/indicators need it). (2) **Diagnostics→gutter
marks** (parse-error `!` via `--json-diagnostics`) are deferred — they edge into the
brief's excluded "parser integration"; only natural syntax highlighting is enabled.
(3) **Saves use in-place `write`, not `atomic_replace`**, to preserve source-file
permissions and symlinks (investigated; see the STU-2 doc + DOGFOOD). (4) Persistence
uses the workspace `docs` field (config-home JSON), consistent with STU-0/STU-1; no
per-file dot-metadata. **R1 unchanged:** STU-2 handled files as text and gives no new
evidence on the parse/outline decision, which remains the gate before STU-3.

---

## STU-3 — Execution-section engine (structural anchoring) · S(model) — headless · [needs plat? R1]

**Purpose.** The defining structural feature: **execution boundaries** between valid
portions of ordinary source, persisted as **structural anchors** that survive edits —
without putting cells into the language (§2.1, §5). Resolves design **Q1**.

**Scope.**
- Determine the **legal-location set** from a parse: the safe structural positions a
  boundary may occupy (between top-level statements; never inside an expression/loop/
  function body split that breaks scope) (§5.1, Q1).
- Boundary operations as a headless model over a file's structure: **add** (snap to nearest
  legal location), **move** (re-snap), **remove** (merge adjacent sections), enumerate
  sections.
- **Persistence as structural anchors** in the per-file dotfile (STU-0): a path/identity
  into the parse (e.g. "after the Nth top-level statement" + a statement fingerprint) plus
  a byte-offset hint (§5.3).
- **Drift re-resolution** on file open: re-parse, reattach anchors that still resolve;
  **flag stale** (not silently drop) anchors whose statement was deleted/rewritten, and
  invalidate any state hanging off them (§5.3, §8/§9 staleness ties).
- Keep **execution boundary vs. debug breakpoint** strictly distinct (§5.2) — breakpoints
  are a later, separate transient concept; this phase builds boundaries only.

**Platform prerequisite (see R1).** This phase needs **structural parse information
reachable from gBASIC** (the set of top-level statement spans / an outline), which the
runtime does not expose today. **Decide R1 before building STU-3.** Preferred resolution: a
*general* platform outline/parse facility (any editor/formatter/linter tool would want it),
specified and built as its own platform phase, then consumed here — not a Studio-private C
path. A stop-gap (shelling `./gbasic --ast` via `process.run` and consuming its output) is
possible but should be evaluated against a first-class API in R1.

**Dependencies.** STU-0 (dotfile anchor storage); a resolved R1 (gBASIC-reachable parse/
outline); STU-2 for the editor surface the boundaries render against (rendering itself is
STU-5-adjacent; this phase can be validated headless without rendering).

**Acceptance criteria.**
- Given a source file, enumerate its legal boundary locations correctly (matches a
  hand-checked fixture across top-level statements, functions, loops, `consider` blocks).
- add/move/remove/merge behave per §5.1 and round-trip through the dotfile.
- Edit the source (insert/delete a top-level statement, rename, delete a marked statement),
  re-open: surviving anchors reattach; the deleted-statement anchor is flagged stale, not
  dropped or misattached.

**Tests.** `tests/run_studio_sections.sh` — headless, deterministic, GI-independent.
Fixtures: legal-location enumeration; snap/move/merge; anchor round-trip; three drift
scenarios (insert-above shifts nothing structurally; delete-marked → stale; rewrite-marked
→ stale). Negatives: illegal-location add rejected; anchor into a nonexistent structure.

**Out of scope.** Running any section (STU-4); breakpoints; branches; rendering the
boundary widgets (validated as a model here; inline rendering lands with STU-5).

**DONE (2026-07-27).** Additive to STU-0/STU-1/STU-2 (their stores/goldens byte-exact).
**R1 resolved as preferred**: STU-3 consumes the general in-process `source_outline(text)`
builtin (PLAT-OUTLINE), not a Studio-private C path and not the `--ast`/`process.run`
stop-gap. `stdlib/studio_sections.bas` (new) — the section engine: structural derivation
of the executed list (a lone `program` block's body when present, else the file top
level; statement runs collapse, compound statements stay atomic, named declarations are
landmarks), Studio-owned `sec-N` ids from a never-rewinding per-document counter,
anchors (kind/name/ancestry/ordinal/header+body fingerprints/kinds signature/offset
hints) over whitespace-folding byte rolling hashes so reindent and blank-line inserts do
not disturb identity, four-tier reattachment gated on **bidirectional uniqueness** (so
the result is iteration-order independent), `ambiguous` flagging instead of guessing on
verbatim duplicates, `stale_ids` for ids nothing matched (never reused, never silently
dropped), last-known-good retention on `ok=false` parses, cursor resolution by byte
offset (`section_at`) and by editor 1-based BYTE line/column (`offset_of` /
`section_at_position`, clamping out-of-range), and persistence (`to_persist`/
`from_persist` + `persist_into`/`restore_from`/`forget`). `studio_model.bas` gains an
additive workspace `sections` slot, normalized in exactly like `nav` (STU-1) and `docs`
(STU-2), so a pre-STU-3 workspace loads with **no migration step**. Supporting parser
change: `%destructor` rules in `src/parser.y` (plus public single-node/aggregate frees in
`ast.c`/`ast.h`), because STU-3 reparses often-invalid source per refresh — measured
20,000 direct + 46,400 indirect bytes lost over 200 invalid `source_outline` calls before,
0 after; note the start symbol needs a per-symbol no-op destructor, since Bison also
discards it *on success*. Reference: `docs/gbasic_studio_stu3.md`.

**Delivered vs. the sketch above.** This session's STU-3 brief scoped the phase to
**derivation + identity + drift** (sections derived from structure, stable ids, anchors,
deterministic reattachment, ambiguity/stale handling, last-known-good, cursor resolution,
compatible persistence). The user boundary *editing* operations sketched above —
add/snap, move/re-snap, remove/merge — are **not** in this phase. Every seam between
derived sections is a legal boundary by construction, so that overlay is additive over
this model rather than a rework of it; see `docs/gbasic_studio_stu3.md` §Known
limitations.

---

## STU-4 — Section execution via replay actors · S(model) + S(ui)

**Purpose.** Jupyter-style immediacy on ordinary `.bas`: run a section, and reach section
*k* by **deterministic replay** of sections 1..k in a spawned actor process, delivering
results to the UI without freezing it (§8.1). The core distinctive experience.

**Scope.**
- **Replay driver**: to run/execute-through section *k*, materialize sections 1..k (the
  canonical source projected up to boundary *k* — never mutating the file on disk) and run
  them in a `spawn`ed actor; capture results/console via the actor's mailbox.
- **Async on the loop**: deliver the actor's frames through `gi.watch_mailbox(fn)` so the
  UI thread never blocks; a `gi.timeout` liveness indicator proves responsiveness during a
  long run (the NAP-3 responsiveness model, proven in the workbench spike).
- **State capture** from the actor via `serialize`/`deserialize` (magic `gBS` v1); live
  GObject/DB handles are *excluded* by design (§8.3) — captured as provenance, never
  snapshotted.
- **Provenance & purity**: tag each section **pure** vs **effectful/external** (static hint
  + observed calls, Q2/Q4). Pure sections replay freely; effectful sections carry a visible
  provenance record and require explicit confirmation to replay (§8.3). Studio never
  silently attaches re-executed effects to a result.
- **Restoration ladder rung 1 only** (§8.2): deterministic replay from the top. Cached
  checkpoints (rung 2) and whole-`Env` capture (rung 3) are **out of scope** — the UX is
  written against the abstraction so later rungs change nothing user-visible.
- Minimal per-section run status inline (ran/stale/error/running; last-run time — §6.1),
  wired to the STU-3 section model.

**Dependencies.** STU-3 (sections); multiprocessing (`spawn`/`send`/`receive`/`serialize`);
NAP-3 (`gi.watch_mailbox`/`gi.timeout`); NAP-6 (`process.run` for out-of-process tests).
Resolves design **Q2, Q4** (pure/effectful tag) and **Q7** (per-`Value` `serialize` +
explicit result vars suffice for v1; no whole-`Env` serializer needed).

**Acceptance criteria.**
- Running section *k* on a multi-section fixture reproduces the exact values a top-to-*k*
  run produces (determinism), delivered off the actor without blocking a concurrent
  `gi.timeout` ticker (`responsive=true`, ticks≥1 — the NAP-3 experiment shape).
- An effectful section (writes a file / calls `process.run`) is tagged effectful, shows
  provenance, and is **not** silently replayed.
- A section whose upstream anchor went stale (STU-3) refuses to present its old result as
  current.

**Tests.** `tests/run_studio_exec.sh` — headless tier: replay-determinism and
pure/effectful tagging driven with real actors + a deterministic mailbox delivery (no
display), mirroring `native_workbench`'s `async` tier. Display smoke: run a section, watch
the ticker keep ticking, see the result land — under fatal-criticals. **Regression
sensitivity (measure before reset):** if the replay driver uses run counters/instrumentation,
tests must observe the lifecycle event (result delivered on the loop) **before** any counter
reset — do not repeat the DataGrid setups/accesses measurement artifact.

**Out of scope.** Right-pane inspection UI (STU-5); modest/large tables; branches;
checkpoints/snapshots; breakpoints.

---

**DONE (2026-07-28).** Additive to STU-0..STU-3 (their stores/goldens byte-exact).
`stdlib/studio_session.bas` (new) — an execution session per document: an eight-state
machine (idle/materializing/running/stopping/unresponsive/finished/failed/refused) whose
every transition is recorded and golden-tested; append-only prefix materialization of the
literal byte prefix `source[0, section_N.end_offset)` from the document's IN-MEMORY
content (running does not save), written via a new `studio_store.write_text_atomic`, with
only two end-appends permitted (a trailing newline, and `end program` when the target sits
inside a program block) so that line N of the child's file is line N of the document;
`process.start("./gbasic", ["--json-diagnostics", prefix])` with NO timeout, driven from a
50ms `gi.timeout` — no actor, no mailbox (see the R2 amendment of the same date); error
attribution to target/prefix/outside through STU-3's ranges; polite `request_stop` (SIGTERM
only) with an `unresponsive` state rather than a hang, and `force_stop` as a separate
explicit escalation; restart that completes the stop first; refusal with a UI-displayable
reason for unparseable source, ambiguous, and stale/removed sections. Concurrency: per
document, since sessions share no mutable state — Studio-wide single-run would have meant
adding a coordinator, not removing one. Minimal UI in `studio_shell.bas` (run/stop/force
strip, session state line, prefix-vs-target output pane). 14 headless goldens + valgrind +
a display-gated `sessions_gui`. Reference: `docs/gbasic_studio_stu4.md`.

**Two findings recorded there, nothing built for either.** (1) Prefix and target output
are NOT separable within one run: one child yields one stream, and the append-only
invariant forbids the boundary marker that would split it, so `split` is `exact` only when
the target is section 1 and `combined` otherwise (everything shown, nothing claimed). (2) A
gBASIC child's stdout is BLOCK-BUFFERED on a pipe — measured: short output does not appear
until the child exits, while a shell child streams — which also settles the watchable-fd
question, since an `gi.watch_fd` design would have nothing to wake on. `seed(n)` does exist
in the runtime, but forcing a per-session seed would require PREPENDING to the prefix
(breaking attribution) and would misrepresent replay as reproducible.

## STU-5 — Contextual results, inspection & modest tables · S(ui)

**Purpose.** Make results *contextual*, not inlined: per-section console and right-pane
runtime state keyed to the selected section — the source area stays source (§6, §7).
Completes design "Studio 1" and consolidates the cheap+expensive restoration story (§10).

**Scope.**
- **Bottom console pane** (§6.3): per-section stdout/stderr/warnings/errors/log/timing;
  selecting a different section swaps the view (views onto per-section state, not a global
  log). Non-editable tagged text.
- **Right inspector pane** (§6.2): **changed variables first** (diff a section's before/
  after via `reflect.variables()` + shallow descriptors), then optionally all in-scope;
  type/shape summaries via `reflect.type`/`kind`/`count`; **lazy deep inspection** built on
  toggle via `reflect.fields`/`field`/`element` (never auto-copying a huge graph —
  `reflect.inspect` is shallow by design).
- **Viewer dispatch** by recognized structure (§6.2 table): scalar → formatted; nested
  record → tree (`gtkui`); matrix → grid; array-of-similar-records → offer `[Table]`.
- **Modest tables** (§7): up to a few thousand cells via a hand-built `gtk` grid /
  `GtkColumnView` model — **not** the DataGrid (that is STU-8). `[Inspect]`/`[Table]`
  affordances offered only for recognizably-tabular structures.
- **Restoration consolidation** (§10.3): cheap layer already instant (STU-1/2); expensive
  computational state left **cold** with a one-click "re-run to restore state" (never
  blocks reopen on a replay).

**Dependencies.** STU-4 (section results + provenance); NAP-9 reflection; NAP-11 `gtkui`.
Reflection's **own-frame scope** limit is respected: changed-variable detection works off
the actor's captured result vars + `reflect` descriptors, not paused-frame enumeration
(which needs the interpreter-context refactor — out of scope, design Q3).

**Acceptance criteria.**
- After a section runs, the right pane shows changed variables with correct type/shape
  summaries; expanding a nested record lazily builds children; a large array does not
  auto-materialize on selection.
- The console pane shows exactly that section's output; switching sections swaps both panes.
- An array-of-records offers `[Table]` and renders a modest table; a scalar does not.
- Reopen a suspended project: layout+code instant; a previously-computed section shows
  **cold** with a re-run affordance.

**Tests.** Headless: changed-variable diffing and viewer-dispatch selection as pure logic
over `reflect` descriptors + captured results; modest-table model. Display smoke: run →
inspect → expand → table, under fatal-criticals. **Regression sensitivity:** helper
functions that build the changed-variable/inspection records must return updated COW
containers correctly (R2) — a helper that mutates a nested record/array must return the new
value, not rely on in-place mutation of a copied argument.

**Out of scope.** Library-registered rich viewers and the large DataGrid (STU-8);
branches; agent.

---

## STU-6 — Read-only Agent & semantic action history · S(agent) — MVP-completing

**Purpose.** The continuity payoff: a **structured action history** and a **read-only
Agent** that answers *"Where was I?"* from project state + history (§11, §14). Completes
the MVP.

**Scope.**
- **Semantic action history** (§14): a structured event log (SQLite in `.gbasic/`, append-
  heavy) recording semantic events (`project_opened`, `file_opened`, `section_selected`,
  `section_executed`, `boundary_added`, `error_raised`, …) with timestamp + target identity
  + compact payload. **Retention/compaction**: rolling window of full events; older events
  compacted into periodic rollups; total size capped (§14, so it stays bounded).
- **Read-only semantic tool surface** (§12 read tools only): observe current project /
  metadata / open files / active file / sections / execution state / variables / console /
  recent actions. These are **the same** semantic operations the UI uses (design §12 — one
  action layer), exposed to the agent as read-only tools.
- **Agent runtime** (§15) over `llm.bas`: a **single selected provider** for v1
  (`llm.anthropic`/`openai`/`local`), assembling project+history context and answering
  "Where was I?" and general orientation questions. Uses `llm.with_tools` with **read-only
  tools**; the registry is the sole dispatch authority; **model-provided text is never
  evaluated as source** — only registered tools run (LLM tool-safety rule).
- **Agent tab** (the fixed far-left tab from STU-2) becomes the live read-only agent.

**Dependencies.** STU-0..5; NAP-13 `llm.bas` (tools/`with_tools`); `sqlite` for history
(degrade to a capped JSON log when absent). Offline-testable: `llm.offline`/
`with_transport` fixtures (no network in tests).

**Acceptance criteria.**
- Semantic events are recorded across a scripted session; the rolling-window + rollup
  keeps the store bounded (old detail compacted, not unbounded growth).
- "Where was I?" produces a correct reconstruction (selected file/section, last change,
  last error) from history + state, using an **offline** transport fixture — deterministic,
  no network.
- Only registered read tools are callable; a model attempt to invoke an unregistered or
  write tool is refused; no source text is ever evaluated.

**Tests.** `tests/run_studio_agent.sh` — fully **offline** (scripted transport, mirroring
`llm_tools_test.bas`): event recording, compaction bound, "Where was I?" over a fixture,
tool-safety negatives (unregistered tool, write tool, non-callable). GI-independent; never
hits the network.

**Out of scope.** Any **act/write** tools, permission tiers, UI teaching/highlighting,
multi-provider selection, secure secret storage — all STU-10. Branches; DataGrid.

> **MVP boundary.** STU-0…STU-6 is the design's MVP: resumable working context + Jupyter-
> style section execution on plain `.bas` + a read-only reorientation Agent. **Stop and
> review the MVP before starting any STU-7+ phase.**

---

## STU-7 — Exploratory branching: state-only · S(model) + S(ui)

**Purpose.** The second defining feature's cheapest form: alternate **state-only**
continuations at a boundary — same source, different runtime — as inline mutually-exclusive
selectors (§9.1, §9.2). Design "Studio 2".

**Scope.** Persistent execution tree/DAG (branch metadata in `.gbasic/`, SQLite/manifest);
inline branch selector widget (one selected path root-to-leaf rendered at a time, §9.1);
create/select/rename/reorder/delete/nest; **state-only** branches served entirely by the
replay model (each branch a distinct state/replay chain over identical code); **staleness**
across branches (§9.3) — upstream source/anchor change invalidates descendants, surfaced,
never shown as current. Studio branches are **not** Git branches (§2.3) — not stored,
surfaced, or created as one.

**Dependencies.** STU-4 (replay chains); STU-3 (anchors for the branch point); STU-6
(history records branch events). Sets a default for design **Q10** (action-log retention).

**Acceptance criteria.** Create two state-only branches at a boundary → each replays its own
chain; select swaps the rendered continuation; change shared upstream → descendants flagged
stale; deleting a branch is clean; no Git branch/ref is ever created.

**Tests.** Headless branch-model logic (tree ops, selection, staleness) + display smoke for
the inline selector under fatal-criticals.

**Out of scope.** Code-overlay branches, promote/discard/compare, rebase (STU-9); branch
comparison UI (design Q6, deferred); DataGrid.

---

## STU-8 — Rich viewers & large DataGrid · S(ui) (consumes NAP-12)

**Purpose.** Serious analytical viewing: library-registered rich viewers and the large-
table tier via the general `DataGrid` — arriving exactly when large data does (§6.2, §7).
Part of design "Studio 3".

**Scope.** The **library viewer registration convention** (design Q11): a library ships a
viewer/adapter/metadata for the types it defines (e.g. `stats.bas` model viewer) **without**
adding `display` semantics to the core language (§6.2 boundary). Large-table tier over
`datagrid` (`new_registry` once as program-global `_DATAGRID`; `create`/`create_virtual` +
`add_column` + `refresh`/`set_rows`); virtualization for 10⁴–10⁶ rows; selection/copy; lazy
`cell` access.

**Dependencies.** STU-5 (viewer dispatch + modest tables it upgrades); NAP-12 `datagrid`.
Resolves design **Q11**.

**Acceptance criteria.** A recognizably-large tabular result opens in a virtualized DataGrid
(row count from the native model; no full materialization); a `stats.bas`-style object opens
its registered viewer; core language remains presentation-free.

**Tests.** Headless native-model tier (DataGrid virtualization proof, no display, as
`run_datagrid.sh` does) + viewer-registration logic; display smoke under fatal-criticals.
**Regression sensitivity (GTK realization timing):** DataGrid factory `setup`/`bind` run when
cells get allocation — not at `present()`. Tests must **observe the bind lifecycle event
before resetting** `datagrid.accesses()`/`setups()` counters (the documented DataGrid
measurement artifact — do not repeat it).

**Out of scope.** Code overlays; agent act-tools.

---

## STU-9 — Exploratory branching: code overlays · S(model) + S(ui)

**Purpose.** Experiment with **downstream code changes** without touching canonical source
— overlays applied only below a branch point, stored in metadata, promotable (§9.2, §9.3).
Completes design "Studio 3".

**Scope.** Code-overlay representation (design **Q5**: scoped textual diff vs. AST patch vs.
shadow-file-for-actor — decided in-phase); overlays stored in `.gbasic/` (never in `.bas`,
§2.1), visibly marked experimental; materialized into a **temp source only for the spawned
actor** that runs the branch (canonical file never mutated); **promote** (write into
canonical → an ordinary working-tree edit git can see) / **discard** / **compare**;
**rebase** an overlay onto changed upstream, surfacing a **conflict** rather than silently
dropping/misapplying (§9.3).

**Dependencies.** STU-7 (branch model); STU-3 (anchors for overlay scope). Resolves design
**Q5**; advances **Q6** (compare).

**Acceptance criteria.** An overlay runs in an actor over a temp materialization while the
canonical file on disk is byte-unchanged; promote writes the change into source; a
non-applying overlay after upstream edit surfaces a conflict, not a silent drop.

**Tests.** Headless overlay-application + rebase/conflict logic (assert canonical file
unchanged via `file_mtime`/`file_size` + content hash); display smoke for the experimental
markings.

**Out of scope.** Agent-driven overlays (that is STU-10 act-tools + permissions).

---

## STU-10 — Full Agent: act-tools, permissions, teaching, multi-provider, secrets · S(agent)

**Purpose.** Continuity of thought made active: the Agent can observe **and act** through
the same semantic operations the user uses, under a permission model, teaching visually,
across selectable providers (§11–§17). Design "Studio 4".

**Scope.**
- **Act tools** (§12 write tools): switch/open/close/select files, navigate/scroll/search,
  edit code, add/move/remove boundaries, execute sections, open viewers, switch/create
  branches, run tests, git ops (when enabled) — **the same semantic operations the UI
  invokes** (parity by construction).
- **Permission tiers** (§17): read (auto) · reversible/local (configurable autonomy) ·
  external/destructive (explicit confirmation), interacting with config scopes
  (session>project>global, §16); every agent action recorded as an `agent_action` history
  event (auditable).
- **UI teaching** (§13): highlight/pulse/focus/scroll-into-view/annotate a source region by
  **stable widget id** — a generalized teaching facility over named widgets (CSS class
  toggle + `grab_focus` + `gi.timeout` pulse + temporary `GtkTextTag`), **no native path**.
- **Multi-provider + tool-calling** (§15): selectable providers via `llm.bas` adapters +
  `llm.with_tools`/`with_max_tool_rounds`/`run_tools`; the registry is the sole dispatch
  authority; **model text never evaluated as source**.
- **Secure credential storage** (§16, design **Q13**): API keys never plaintext — target OS
  keyring; near-term a crypto-protected local store via the existing `crypto` library.

**Dependencies.** STU-6 (read-only agent + history + tool surface); NAP-13 tool-calling;
`crypto` for secrets. Resolves design **Q13**.

**Acceptance criteria.** The agent performs a scripted multi-step task (open file → add
boundary → run section → report) via act-tools; a destructive action is gated by
confirmation; every action appears in history; a UI-teaching request highlights the correct
named widget; provider is switchable; secrets are not stored plaintext; only registered
tools run.

**Tests.** Offline agent-loop tests (scripted transport): act-tool dispatch, permission
gating (read auto / local configurable / destructive blocked without confirm), audit-trail
completeness, tool-safety negatives, secret-store round-trip (no plaintext on disk).
Display smoke for teaching highlights under fatal-criticals.

**Out of scope.** Anything beyond the design's Studio 4; multi-window (design Q14, deferred).

---

## STU-11 — Git integration (additive) · S(ui) over `process.run`

**Purpose.** Optional, well-integrated, visually quiet Git (§18) — over the general process
API, no bespoke binding.

**Scope.** Detect repo · init · clone/open · status · diff · commit · history · branch
switching · pull/push — all via `process.run` invoking `git`. Studio exploratory branches
stay **distinct** from Git branches (§2.3); the only crossover is **promotion** of an
overlay (STU-9) becoming an ordinary working-tree edit. Git UI stays collapsed unless a repo
is present and the user engages it.

**Dependencies.** STU-1 (workspace); NAP-6 `process.run`. Independent of STU-7/8/9/10 —
schedulable any time after STU-1.

**Acceptance criteria.** In a repo, status/diff/commit/history render from `git` output;
outside a repo, Git UI stays quiet; no Studio branch is ever mapped onto a Git ref except
via explicit promotion.

**Tests.** Headless: parse `git` porcelain output into the model over a fixture repo (no
network; local `git init` in a temp dir); display smoke for the quiet/engaged states.

**Out of scope.** Hosting-provider (GitHub/GitLab) APIs; merge-conflict resolution UI.

---

## Risks (architectural, surfaced early)

- **R1 — No gBASIC-reachable parse/outline (blocks STU-3).** The boundary engine needs the
  set of legal structural locations from a parse, but the reentrant front end
  (`libgbasic.a`/`gb_parse_ctx`) is only reachable from C (it powers `gbasic-lsp`), not from
  gBASIC. This is the **one candidate general-platform prerequisite** Studio surfaces
  (design Q1). Resolution must be a *general* facility (any editor/linter/formatter wants an
  outline API) decided on its own — a Studio-private native path violates the global rules.
  A `process.run ./gbasic --ast` stop-gap exists but should be weighed against a first-class
  API before STU-3 starts. **Decision required before STU-3.** **R1 investigation complete:
  see `docs/source_outline_design.md`** — recommends a general in-process `source_outline`
  builtin over a reusable outline core fed by the existing reentrant `gb_parse` (with a
  `gbasic --outline` CLI as an acceptable stopgap); two decisions remain for sign-off
  (exact-vs-approximate end positions, which implies a bounded grammar change; and freezing
  the outline record schema).
- **R2 — COW container updates in helpers.** Records/arrays are copy-on-write **by value**;
  a helper that "modifies" a nested container must **return** the updated value — relying on
  in-place mutation of a copied argument silently loses the update. This bit prior phases;
  STU-0 (store records), STU-5 (inspection records), STU-7/9 (branch/overlay trees) are the
  exposed spots. Rule: mutators return the new container; call sites reassign.
- **R3 — Scalar globals in callbacks shadow rather than update.** Signal/callback handlers
  that "update" a scalar global may create a shadowing local instead. Studio's UI is
  callback-heavy (signals, `gi.watch_mailbox`, `gi.timeout`). Rule: carry mutable per-grid/
  per-session state through a **registry record** (the DataGrid `_DATAGRID` pattern), not a
  bare scalar global, and mutate the record's field.
- **R4 — GTK realization timing.** Factory `setup`/`bind` (DataGrid) and allocation-time work
  fire when widgets get **allocation**, not at `present()` or during later loop spins. Tests
  must measure **around the actual lifecycle point** and observe the event **before**
  resetting any instrumentation counter (the DataGrid measurement artifact — STU-4, STU-8).
- **R5 — Non-reentrant evaluator forces replay.** The evaluator is global-state/non-reentrant
  (per design §8.1), so Studio cannot snapshot a live in-process interpreter; v1 is
  deterministic replay in actors (rung 1). Perf risk on long chains is mitigated by later
  ladder rungs (checkpoints, whole-`Env` capture) **without a UX change** — but those rungs
  (and true snapshots, design Q3) need the interpreter-context refactor and are out of the
  MVP.
- **R6 — Reflection scope is own-frame only.** `reflect.variables()` sees the current frame,
  not paused/enclosing frames or another interpreter. Studio's changed-variable view (STU-5)
  therefore works off the **actor's captured result vars + `serialize`**, not live paused-
  frame enumeration. Whole-`Env` capture is deferred (design Q7 answered: per-`Value`
  `serialize` + explicit result vars suffice for v1).
- **R7 — Effectful replay hazards.** Files, DB writes, sockets, LLM calls, time/random are
  not cleanly re-runnable (§8.3). Studio must tag pure vs. effectful and **never silently
  attach stale/re-executed effects to a result** — provenance + explicit confirmation, not
  pretend-perfect snapshots. Under-tagging is the risk; STU-4 owns the classification (Q2/Q4).
- **R8 — Strict-JSON discipline.** `encode` emits a gBASIC dialect (`nothing`/`unknown`),
  invalid as standard JSON. Every external/interchange path (hand-editable config, LLM/API
  payloads, git-adjacent manifests) **must** use `json_encode`/`json_encodable`. Slipping
  `encode` onto a wire is the risk; it is a global rule and a per-phase acceptance check.
- **R9 — LLM tool safety.** Only **registered** tools are callable and **model-provided text
  is never evaluated as source** — the `llm.bas` registry is the sole dispatch authority
  (STU-6, STU-10). Any path that `eval`s model output is forbidden.
- **R10 — Secret storage gap.** No OS-keyring integration exists (design Q13); near-term is a
  crypto-protected local store. Real multi-provider agent use (STU-10) must not land with
  plaintext keys.
- **R11 — Known language sharp edges (non-blocking, carry forward).** `this.method()`
  dispatch was fixed pre-spike, but **chained receiver `a.b.method()`** and **static GI
  methods** (3-part names) are not resolved; `error` is a reserved word (no `{error:...}`
  record literal — use a constructor, as `llm.tool_error` does); `call(...) = x` at
  expression position collides with the modifier-lexer mode (bind to a variable first).
  These are SHOULD-FIX-BEFORE-STUDIO ergonomics, not blockers; Studio code must route around
  them and each should be logged if newly hit.

---

## Boundary discipline

Stop after every `STU-n` for review. STU-0→STU-6 is the ordered path to the **MVP**;
STU-7→STU-11 are the design's Studio 2–4, picked up only after the MVP is accepted. No
phase implements a later phase's surface early. Studio adds **only Studio-specific gBASIC**
on top of the completed platform; the single native component in the entire stack is the
general `DataGrid`, which Studio consumes and does not own.

**Before STU-3**, resolve **R1** (gBASIC-reachable parse/outline) as a general-platform
decision — it is the one place Studio may require a new general capability, and it must not
be met with Studio-private native code.

**This document is a plan, not an implementation.** No Studio code is to be written until it
has been reviewed and accepted.
