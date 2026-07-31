# gBASIC Studio — Product & System Design

Status: **authoritative design, not implemented.** This is the product and system
design for gBASIC Studio. It sits on top of, and does not duplicate, the generalized
native-platform research:

- `docs/gbasic_studio_research.md` — feasibility study (18 sections).
- `docs/gbasic_studio_gtk_requirements.md` — first-pass GTK/GI requirements (superseded
  on the SourceEditor question by the coverage doc).
- `docs/gbasic_native_app_platform_coverage.md` — GTK4/GtkSourceView coverage survey +
  capability matrix + item reclassification.
- `docs/gbasic_native_app_platform_plan.md` — build-ready phased plan (NAP-0..NAP-13),
  now **complete/accepted** (all phases DONE).
- `docs/gbasic_studio_plan.md` — the Studio **implementation plan** (phases STU-0..STU-11)
  that turns this design into buildable work now that the platform is complete. This
  design remains the *what/why/behavior*; that plan is the *ordered how*.

Those four documents own the **low-level generalized GTK/GI/runtime work**. This
document owns **what Studio is, how it behaves, and how its major systems fit
together.** Where a capability is a generalized platform prerequisite, this document
*references* it (by WI-*/NAP-* name) rather than re-specifying it. §20 and the closing
"Relationship to Native Application Platform" section draw the boundary precisely.

Tags used below: **REQUIRED** (must hold for the design to work), **PROPOSED** (a
design choice open to revision), **DEFERRED** (explicitly out of the near-term path),
**VERIFIED** (grounded in current repo code, cited).

---

## 1. Core vision

gBASIC Studio is the **desktop environment for anything a user makes or does with
gBASIC.** It is not a statistics IDE with other features bolted on; analytics is one
important workload among many. A single Studio installation must comfortably carry a
mixed organizational workload:

- application development
- application maintenance
- ETL / data pipelines
- statistical analysis
- research
- financial / investment analysis
- reporting
- debugging
- production support
- exploratory programming

The motivating scenario is **interruption**. A representative user is mid-way through
an analytical project, is pulled into an urgent production-report bug, diverts to an
ETL failure, and returns — hours or days later — to the original analysis. Each of
those is a distinct *project*, and each deserves to be resumed as it was left.

The central product principle:

> **Preserve continuity of thought.**

A user should be able to suspend a complex task, work on several unrelated projects,
and return later to substantially the same intellectual **and computational** context
they left behind. Concretely, resumption targets — where applicable to the project:

project · open files · selected file · tab ordering · cursor positions · scroll
positions · execution section · execution history · variable/result state · console
output · exploratory branches · debugging context · recent user actions · Agent
context.

The consequence is definitional and shapes the entire architecture:

> A **Studio project is a resumable working context**, not merely a folder of files.

The folder-of-files is the *canonical artifact* (the `.bas` sources, Git-friendly,
runnable outside Studio). The *working context* is everything Studio layers around
those files to put the user back into their work. §2 keeps these two strictly separate.

---

## 2. Fundamental architectural principles

These five principles are load-bearing. Every later section is constrained by them,
and §23 audits the document against them.

### 2.1 Source remains ordinary source (REQUIRED)

A `.bas` file remains a normal gBASIC source file — nothing more. Studio must **not**
require notebook syntax, embedded output, branch markup, cell delimiters, or Studio
metadata *inside* the source. A Studio-owned file must remain:

- readable outside Studio,
- executable outside Studio (`./gbasic file.bas` runs it unchanged),
- clean in Git (no Studio noise in diffs),
- understandable as ordinary gBASIC by a human or another tool.

Studio overlays interactive behavior *around* source without contaminating it. This is
the hard line that distinguishes Studio from a notebook environment: **the notebook is
a projection Studio computes, never a file format it imposes.** (VERIFIED enabler: the
front end is reentrant and exposes lex→parse→AST via `libgbasic.a`/`gb_parse_ctx`, so
Studio can understand the structure of a file without altering it — see §5.)

### 2.2 Studio metadata is separate and unobtrusive (REQUIRED)

Interactive state lives *beside* source, never inside it. Two tiers plus a heavy-state
area:

| Tier | Location | Holds | Format bias |
|---|---|---|---|
| **Per-file metadata** | `.<filename>` sibling (e.g. `.products_per_member_calc.bas` for `products_per_member_calc.bas`) | cursor/scroll, per-file boundary positions (as structural anchors, see §5), per-file tab state, per-file overlay references | small, human-diffable (JSON/TOML) |
| **Project metadata** | one consolidated `.gbasic/` directory | project registry entry, workspace layout, tab order, open-file set, selected file, selected branch path, project AI rules, action-history index | mixed: human-readable manifest + SQLite for logs/history |
| **Heavy state / cache** | inside `.gbasic/` (e.g. `.gbasic/state/`, `.gbasic/cache/`) | serialized environments, replay checkpoints, branch snapshots, computed indexes, viewer caches | opaque, regenerable, bounded, deletable |

Design rules:

- **One dot-file per source file, not several.** The single `.<filename>` prefix
  preserves an obvious 1:1 relationship and keeps `ls` clean. Avoid a proliferation of
  `.foo.cursor`, `.foo.marks`, `.foo.state` companions.
- **Everything heavy is consolidated under `.gbasic/`.** Snapshots, caches, indexes,
  and logs never sprinkle across the project tree.
- **`.gbasic/` is regenerable and disposable.** Deleting it loses working context but
  never source. This is the crash-safety and "easy cleanup" guarantee (see §19).
- Responsibilities, restated crisply: per-file dot metadata = *how this file was being
  viewed/edited*; project metadata = *how the workspace was arranged and what the
  project is*; heavy state = *the expensive-to-recompute computational context*.

### 2.3 Git is optional (REQUIRED)

Studio supports Git well when present but a Studio project must **never require** it.
Four concepts stay strictly distinct and are never conflated (§23 audits this):

| Concept | What it is |
|---|---|
| **Studio project** | a resumable working context (§1) |
| **Studio exploratory branch** | an alternate *execution/experiment* continuation at a boundary (§9) — an interactive construct |
| **Git repository** | optional version control of the canonical source |
| **Git branch** | a VCS ref |

A Studio exploratory branch is **not** a Git branch, is not stored as one, and does
not create one. The only bridge between the two worlds is *promotion* (§9, §18): a
successful code-overlay experiment, once promoted into canonical source, becomes an
ordinary working-tree change that Git can then see like any edit.

### 2.4 Studio is primarily written in gBASIC (REQUIRED)

Studio is a native GTK4 application written primarily in gBASIC. The Native Application
Platform work (coverage + plan docs) exists precisely to make this practical. Studio
assumes, and consumes:

- native GTK4 UI over the generalized `gi` bridge,
- GtkSourceView-based source editing (via the gBASIC `SourceEditor` **library**, not a
  native wrapper — SW-1 withdrawn),
- generalized GI bridge improvements (WI-1/2/3/4/6/7/8/10 + LE-1 dispatch),
- reusable gBASIC UI/application libraries (`gtk.bas`, reconciler),
- actors / process isolation for blocking work (VERIFIED: shared-nothing fork+exec
  actors, `root_mailbox`),
- GLib event-loop integration (`gi.watch_fd`/`watch_mailbox`, WI-4),
- a reusable native `DataGrid` adapter **only** for high-volume virtualized tables.

### 2.5 No Studio-specific native C where a generalized capability serves (REQUIRED)

Restated from the platform principle and binding on this document: **do not introduce
Studio-specific native infrastructure where a bounded, reusable gBASIC/GI/GTK
capability can solve the problem.** The test for anything that reaches toward C:
*"Would another sophisticated gBASIC desktop application unrelated to Studio reasonably
need this?"* If yes, it belongs in the generalized layer (and is specified in the
platform docs, not here). If no, it is Studio's own gBASIC code. Per the coverage
survey, exactly **one** native component survives this test — the general `DataGrid`
(§7) — and it is a platform component Studio merely *consumes*.

---

## 3. Project selection and lifecycle

A user may accumulate **hundreds** of projects over years. Project selection is a
first-class experience, not a dropdown.

### 3.1 The project picker (PROPOSED)

A dedicated modal picker/dialog, opened at launch and on demand:

```
┌─ Open Project ─────────────────────────────────────────────┐
│  [ search…                                    ]  ⌕          │
│  Status: (•)All ( )Active ( )Paused ( )Maintenance  ▸more   │
│ ────────────────────────────────────────────────────────── │
│  ★ member-analytics        Active       opened 2h ago   ⋯   │
│  ★ prod-report-hotfix      Maintenance  opened 1d ago   ⋯   │
│    etl-nightly             Active       opened 3d ago   ⋯   │
│    portfolio-var           Paused       opened 2w ago   ⋯   │
│    q3-research             Idea         opened 1mo ago  ⋯   │
│    …(scrolls)…                                              │
│ ────────────────────────────────────────────────────────── │
│  [ + New Project ]                        [ Open ]  [Cancel]│
└────────────────────────────────────────────────────────────┘
```

- **Search** at top (name/description/tag substring; incremental).
- **Vertically scrolling list** of rows. (VERIFIED sizing: a `GtkListBox` of rows
  handles hundreds–thousands of projects with no virtualization — coverage §2. The
  picker does *not* need the DataGrid.)
- **Status filters** as a quick segmented control, with a "more" affordance for tags.
- **Pinned (★) and recent** float to the top; "opened … ago" gives temporal recall.
- Per-row `⋯` menu: open, pin/unpin, change status, reveal in files, edit metadata,
  remove-from-registry (never deletes files).

### 3.2 Lifecycle status (PROPOSED)

Built-in status set, chosen to describe *the work*, not to become a task tracker:

`Idea → Planning → Active → Paused → Maintenance → Completed → Retired`

- Status is advisory metadata used for filtering/sorting and Agent reorientation
  ("you have 3 Active projects; member-analytics was last touched").
- **Custom statuses** are DEFERRED — allow later via a project-registry field, but v1
  ships the built-in set only.
- Status transitions are just metadata edits; Studio imposes no workflow gates.

### 3.3 Project metadata (PROPOSED)

Stored in the project registry (global) and/or `.gbasic/` (per project):

name · path · description · status · tags · last-opened · pinned · Git-present flag ·
current-workspace summary (a short human/Agent-readable "where this project is") ·
project-level AI rules (§16).

**Non-goal (REQUIRED boundary):** Studio is not Jira. No assignees, sprints, tickets,
burndowns, or multi-user workflow. The picker exists to help *one user find and resume
their own work*. Anything beyond that is out of scope.

---

## 4. Main workspace layout

The primary window. Behavior and information architecture are specified; visual
styling is deliberately left minimal.

```
┌───────────────────────────────────────────────────────────────────────┐
│  member-analytics ▾    [Active]        ⌕  ⚙  ⎇git:clean                 │  header
├─────────────────────────────────────────────┬─────────────────────────┤
│                                             │   INSPECTOR (right)       │
│   SOURCE / EDITOR AREA                       │   state for the selected  │
│   (GtkSourceView via SourceEditor library)   │   execution section:      │
│   — execution boundaries between sections    │   • changed variables     │
│   — inline branch selectors at branch points │   • type/shape summaries  │
│   — gutter marks (boundaries, breakpoints,   │   • expandable deep tree  │
│     diagnostics)                             │   • [Inspect] [Table] …   │
│                                             │  (resizable · collapsible)│
│                                             ├─────────────────────────┤
│                                             │   CONSOLE / OUTPUT (bottom)│
│                                             │   stdout · stderr ·        │
│                                             │   warnings · errors · log ·│
│                                             │   timing  (per section)    │
│                                             │  (resizable · collapsible)│
├─────────────────────────────────────────────┴─────────────────────────┤
│ [ Agent ] │ [analysis.bas] [load.bas•] [report.bas!] [utils.bas] … ▸    │  tab strip
└───────────────────────────────────────────────────────────────────────┘
```

Regions:

- **Source/editor area** — the focus; primarily source (§5, §6).
- **Right inspector pane** — resizable and collapsible; runtime state for the selected
  section (§6).
- **Bottom console pane** — resizable and collapsible; contextual execution events for
  the selected section (§6).
- **Bottom tab strip** — `[ Agent ] | [file tabs…]`.

Tab-strip requirements (REQUIRED behavior; VERIFIED reachable — coverage §2):

- **Agent tab is fixed at the far left**, always present, never scrolls away (§11).
- **File tabs scroll horizontally** when they overflow.
- **Tab order persists per project**; reordering is user-controlled.
- **Selected tab persists**; **open-file set persists**.
- Compact per-tab indicators: modified (`•`), error (`!`), running/queued (a spinner or
  dot), so state is legible without opening the file.

The Agent-at-left + scrollable-file-tabs strip is composed from an ordinary box +
scrolled window (coverage §2), not a bespoke widget.

---

## 5. Source editing and execution sections

This is a defining feature. Studio fuses three things usually kept apart:

1. the clarity of **normal source files**,
2. traditional **IDE editing/debugging**,
3. the incremental immediacy of **Jupyter-style execution**.

…**without putting cells into the language** (§2.1).

### 5.1 Execution boundaries (PROPOSED, REQUIRED to be structural)

Studio introduces **execution boundaries**: markers *between* structurally valid
portions of ordinary gBASIC source. The region between two adjacent boundaries (or a
boundary and the file edge) is an **execution section**.

Boundaries are a Studio overlay, **not** source text (§2.1). They are persisted in the
per-file dot metadata (§2.2) as **structural anchors**, not raw byte offsets — see
§5.3.

The gBASIC front end makes this sound: Studio parses the file to an AST
(`libgbasic.a`/`gb_parse_ctx`, reentrant — VERIFIED) and thereby knows the set of
**safe structural locations** where a boundary may legally sit (e.g. between top-level
statements; not inside an expression, a `while`, or a function body split that would
break scope). A boundary that isn't at such a location is illegal.

Users can:

- **add** a boundary (snaps to the nearest safe structural location),
- **move** a boundary (re-snaps),
- **remove** a boundary (conceptually **merges** the two adjacent sections into one),
- **execute one section**,
- **execute through** a section (run from a known state up to and including it),
- **continue execution** (advance to the next section from current state),
- **restore/revisit** an earlier execution point where supported (§8).

### 5.2 Execution boundary vs. debug breakpoint (REQUIRED distinction)

These are different concepts and must never be conflated (§23 audits this):

| | **Execution boundary** | **Debug breakpoint** |
|---|---|---|
| Purpose | a persistent *stage* in interactive development | a diagnostic *stop* while investigating |
| Granularity | between top-level structural units | any line, including inside loops/functions |
| Lifetime | persistent working structure of the project | transient investigative aid |
| Associations | carries state/results, replay, branching, resumability (§6, §8, §9) | carries nothing persistent; just pauses execution |
| Conditional? | no | may be conditional |
| Model | *organizes* execution | *interrupts* execution |

They coexist freely: a section may contain breakpoints; hitting one pauses the run of
that section for inspection. Boundaries shape *what* runs as a unit; breakpoints shape
*when a run pauses*.

### 5.3 Boundary persistence and source drift (PROPOSED)

Because source is canonical and edited freely (including outside Studio), boundary
positions must survive edits:

- Persist each boundary as a **structural anchor** — a path/identity into the AST
  (e.g. "after the Nth top-level statement" / a statement fingerprint), *plus* a byte
  offset as a hint.
- On file open, **re-resolve** anchors against a fresh parse. Anchors that still
  resolve reattach silently. Anchors that no longer resolve (the statement they marked
  was deleted/rewritten) are **flagged stale** and surfaced, not silently dropped, and
  any state hanging off them is invalidated (§8, §9 stale handling).
- Boundaries are never written into the `.bas`. Editing the file outside Studio can at
  most *invalidate* a boundary; it can never corrupt the source.

---

## 6. Contextual results model

The failure mode to avoid: turning source into a vertically enormous notebook where
every result is inlined and the code scrolls off the bottom. Studio's answer: **the
source area stays source; results live in contextual panes keyed to the selected
section.**

### 6.1 What goes inline (PROPOSED, deliberately sparse)

Inline elements are used *only* when they convey execution **structure** or **compact
status** — never bulk output:

- execution boundaries (thin separators between sections),
- branch selectors at branch points (§9),
- compact execution status (ran / stale / error / running; last run time),
- errors/warnings tied to a source location (gutter mark + squiggle, from
  `--json-diagnostics` — VERIFIED structured diagnostics exist),
- optionally, a *small* scalar summary where genuinely useful (e.g. a one-line result
  badge), never a table or a large object.

Everything larger belongs in the panes.

### 6.2 Right pane — runtime state for the selected section (PROPOSED)

When the user selects or places focus within an execution section, the right pane shows
the runtime state **associated with that section**:

- **changed variables** first (what this section produced/modified — the primary view),
- optionally **all variables** in scope,
- **type/shape summaries** (`array[48,291]`, `record{7 fields}`, `matrix 12×12`),
- **expandable deep inspection** (lazy: children built on toggle — VERIFIED reachable
  with `keys`/`values`/`type`/`is_*`, coverage §4),
- **available rich viewers**, chosen by structural recognition:

| Recognized structure | Offered viewer |
|---|---|
| scalar | formatted value |
| nested record | tree |
| array of similarly-shaped records | table option (§7) |
| matrix | grid |
| statistical/model object | library-provided specialized viewer |
| other recognized structures | appropriate registered viewer |

**REQUIRED boundary (§2.1 corollary):** Studio does **not** add generic
presentation/`display` semantics to the core gBASIC language merely to render these.
Viewers are Studio-side (and library-side): a **library** may register, by convention,
a viewer/adapter/metadata for the types it defines (e.g. `stats.bas` ships a model
viewer). The core language stays presentation-free.

### 6.3 Bottom pane — execution events for the selected section (PROPOSED)

Contextual execution output for the selected section: stdout · stderr · warnings ·
errors · execution log · timing/status. (VERIFIED reachable: a tagged non-editable
`GtkTextView`, one buffer per section — coverage §6.)

Selecting a *different* section swaps both panes to that section's state and output.
The panes are **views onto per-section state**, not a running global log.

---

## 7. Tabular data

Studio must **not** assume every large structure is a table. After a section runs,
Studio knows which variables changed and their structures (§8, §14). It then *offers*
an appropriate view:

```
customers    array[48,291]    [Inspect] [Table]
weights      matrix 12×12      [Inspect] [Grid]
config       record{7}         [Inspect]
```

Only structures that are *recognizably tabular* (e.g. an array of similarly-shaped
records, a matrix, a query result) get a `[Table]`/`[Grid]` affordance.

Two tiers (REQUIRED distinction — small vs. large is a real architectural fork,
coverage §5):

- **Lightweight / modest tables** (up to a few thousand cells) use **generalized GTK**
  facilities (a hand-built `GtkColumnView` model or a grid of labels). No native
  component. VERIFIED reachable on the platform's critical path.
- **Large analytical tables** use the reusable generalized **`DataGrid`** component
  (NAP-12) — the single justified native piece (a fixed C `GListModel` adapter), and a
  **general** gBASIC application component, **not** a Studio-specific grid.

Desired eventual DataGrid behavior: virtualization · very large row counts (10⁴–10⁶+) ·
sorting · filtering · column resize · selection/copy · lazy access · later
profiling/summary extensions. The DataGrid is DEFERRED off Studio's MVP critical path
(§21, §MVP); modest tables carry early Studio.

---

## 8. Persistent execution model

The user-facing promise must be **implementation-independent**:

> Studio can associate execution state/results with execution boundaries, and return to
> earlier working points where feasible.

**REQUIRED separation** (§23 audits this): the *user-facing execution-state
abstraction* is distinct from the *underlying restoration strategy*. The UX must never
depend on which mechanism restored a state.

### 8.1 Why replay-first (VERIFIED constraint → PROPOSED strategy)

The gBASIC evaluator is **global-state and non-reentrant** (VERIFIED: `static Env
global_env` + ~60 file-scope statics; the interpreter-context refactor is PLAN Phase 3,
DEFERRED). Therefore Studio **cannot** snapshot a live in-process interpreter today.
The initial strategy is **deterministic replay**: each section runs in a spawned
**actor process** (VERIFIED: shared-nothing fork+exec actors, `root_mailbox`,
`gi.watch_mailbox` result on the GTK thread — coverage §7); to reach section *k*, run
sections 1..*k* from a known start. State/results are captured from the actor via
serialization (VERIFIED: per-`Value` `serialize`/`deserialize`, magic `gBS` v1).

### 8.2 The restoration-strategy ladder (PROPOSED, evolvable)

The same user abstraction is served by progressively better mechanisms, added without
changing the UX:

1. **Deterministic replay** (v1) — re-run from the start of a chain. Always correct for
   pure computation; possibly slow.
2. **Cached replay checkpoints** — persist a section's ending environment (serialized)
   so a descendant can start from the nearest checkpoint instead of the top.
3. **Serialized environments** — whole-scope capture once a general `reflect`/env-dump
   exists (NAP-9; today `serialize` is per-Value, no whole-`Env` serializer — VERIFIED
   gap).
4. **True interpreter snapshots** — only after the interpreter-context refactor (PLAN
   Phase 3) makes the evaluator reentrant/snapshottable.
5. **Copy-on-write / persistent state** — efficient branch restoration (the value model
   is already refcounted COW cells — VERIFIED — a natural substrate later).

**REQUIRED:** the Studio UX in §6/§9 is written against abstraction, not against any
rung of this ladder. Moving up the ladder is a performance/fidelity upgrade, never a
UX change.

### 8.3 Non-rewindable resources (REQUIRED honesty)

Some effects cannot be re-run or snapshotted cleanly. Studio must favor **explicit
provenance and safe invalidation over pretending everything snapshots**:

| Resource | Replay hazard | Studio stance |
|---|---|---|
| open files (write) | re-running re-writes / appends | mark section as *effectful*; warn before replay; require explicit opt-in |
| DB connections / writes | side effects, non-idempotent | *effectful*; never silently replay writes; read-only replays flagged as potentially-stale data |
| sockets / external APIs | non-repeatable, rate-limited, costly (LLM calls) | *effectful + external*; cache last result as provenance; replay requires confirmation |
| GUI handles | live objects, not serializable (VERIFIED: `serialize` rejects GObject/DB handles) | never snapshotted; excluded from state capture; recreated by code, not restored |
| actors / processes | live PIDs | not restored; provenance records they ran |
| time-dependent ops | `now()`/timers differ per run | recorded as provenance; determinism not assumed |
| random state | differs per run unless seeded | `seed` captured as provenance where used; else flagged non-deterministic |

Mechanism: each section is tagged **pure** vs **effectful/external** (by static hint +
observed calls). Pure sections replay freely. Effectful sections carry a visible
provenance record ("last run 14:02, wrote 3 rows to `orders`") and require explicit
confirmation to replay. **Studio never silently attaches stale or re-executed effects
to a result.**

---

## 9. Exploratory branching

The second defining feature. At an execution boundary, the user may create alternate
**exploratory continuations**.

### 9.1 The model (PROPOSED)

```
… shared ancestry (sections above the branch point) …
────────────────────────── branch point ──────────────────────────
   [ Baseline ] [ Robust ] [ No Outliers ] [ + ]        ← inline selector
────────────────────────────────────────────────────────────────────
… the SELECTED branch's continuation displays below …
```

Mental model (REQUIRED):

> **Everything above the branch point is shared ancestry. Everything below may
> diverge.**

- The inline selector behaves like **mutually-exclusive inline tabs/buttons**.
- **Exactly one** branch is selected at a branch point at a time.
- Below the branch point, Studio displays the **selected** continuation until the next
  branch point.
- The true underlying structure is a **persistent execution tree/DAG-like history**;
  the editor normally renders **one root-to-leaf path** at a time. Nested branch points
  create deeper trees.

Operations: create · select · rename · reorder (if useful) · delete · **compare**
(later) · nest.

**REQUIRED distinction (§2.3, §23):** a Studio exploratory branch is **not** a Git
branch — not stored as one, not surfaced as one, not created as one.

### 9.2 Two kinds of branch (PROPOSED)

**State-only branch** — *same canonical source*, different runtime:

- different inputs, variable values, assumptions, parameters, or captured state.
- No source changes at all. Cheapest; served entirely by the execution model (§8) —
  each branch is a distinct state/replay chain over identical code.

**Temporary code-overlay branch** — experiment with *downstream code changes* without
touching canonical source yet:

- changes **apply only below the branch point**,
- are **stored in Studio metadata** (`.gbasic/` overlays; §19), **not** in the `.bas`,
- are **visibly marked experimental** in the editor,
- are **not** Git branches and **not** separate visible `.bas` files (§2.1, §2.3).

A code-overlay is a *pending, scoped diff* Studio applies as a projection when that
branch is selected, and materializes into a temp source only for the spawned actor that
runs it. The canonical file on disk is never mutated by selecting/running an overlay.

Resolution of a successful overlay experiment:

- **Promote** → write the change into canonical source (it then becomes an ordinary
  working-tree edit Git can see — §18),
- **Discard** → drop the overlay from metadata,
- **Compare** → diff overlay against canonical (and later, against sibling branches).

### 9.3 Staleness across branches (REQUIRED honesty)

If **shared upstream** (canonical source above a branch point, or a boundary anchor)
changes, descendants may become stale. Studio must design for this, not ignore it:

- **stale detection** — upstream source/anchor change invalidates descendant state
  (ties to §5.3 anchor re-resolution and §8 provenance),
- **invalidation** — mark descendant results/branches stale; never show stale results
  as current (§6.1 status),
- **recomputation/replay** — offer to re-run affected chains,
- **overlay reapplication / rebase** — attempt to reapply a code-overlay onto changed
  upstream; where it no longer applies cleanly, surface a **conflict** rather than
  silently dropping or misapplying it,
- **conflict handling** — explicit, user-visible, with the option to edit/rebase or
  discard.

> **REQUIRED:** Studio never silently attaches stale execution state to changed source.

---

## 10. Project suspension and restoration

Central enough to warrant its own section. Leaving a project persists enough context to
resume naturally; reopening restores it where practical.

### 10.1 What is captured on suspend (PROPOSED)

selected file · open-file set · tab ordering · cursor positions · scroll positions ·
pane layout (sizes, collapsed/expanded) · selected execution section · selected
exploratory-branch path (root-to-leaf) · execution/results state (§8, at whatever ladder
rung is active) · recent relevant activity (§14) · Agent context (§11).

Split across the metadata tiers (§2.2): per-file items in `.<filename>`; workspace/tab/
branch-selection items in `.gbasic/`; heavy state under `.gbasic/state/`.

### 10.2 The restoration goal (REQUIRED framing)

The target is not:

> "Reopen my files."

It is:

> "Put me back into the work I was doing."

### 10.3 Graceful degradation (REQUIRED)

Restoration is **best-effort and layered**; each layer degrades independently and
visibly:

| If this can't be restored | Degrade to |
|---|---|
| a source file moved/deleted | reopen the rest; flag the missing tab, don't fail the project |
| a boundary anchor no longer resolves (§5.3) | drop that boundary, flag it, keep the file |
| replayed state is expensive/effectful (§8.3) | restore layout + code instantly; leave state **cold** with a one-click "re-run to restore state" |
| a code-overlay no longer applies (§9.3) | restore as a flagged conflict, not silently |
| Agent context is large (§14 retention) | restore a compacted summary, note truncation |

Studio always restores *at least* the cheap layer (files, tabs, cursors, layout,
selection) instantly, and restores expensive computational state lazily/on-demand. It
never blocks reopening on a slow replay.

---

## 11. AI Agent

The Agent is a **permanent first-class Studio surface**, not an optional chatbot. It is
the **fixed leftmost bottom tab**, labeled `Agent` (§4). Its context is primarily the
**current project**.

Purposes: teaching gBASIC · teaching Studio (§13) · coding assistance · debugging ·
analysis · navigation · project reorientation · explaining results · helping resume
interrupted work.

A defining interaction (REQUIRED to be answerable):

> **"Where was I?"**

The Agent reconstructs a useful answer from **project state + action history** (§14):
which file/section was selected, which branch, what changed last, what failed, what the
open question was. This is the continuity-of-thought principle (§1) expressed through
the Agent.

---

## 12. Agent observability and control

Subject to permissions (§17), the Agent can **observe essentially everything the user
can observe** and **perform essentially every meaningful semantic action the user can
perform** — via **MCP-style semantic tools**, not pixel automation (REQUIRED: semantic,
not coordinate-based; this is what makes the Agent robust and teachable — §13).

**Observe** (read tools): current project · project metadata · open files · active file
· visible source · surrounding source above/below · cursor/selection · execution
sections · execution state · branches · variables · deep values · tables · widgets and
their contents · console/results/errors · Git state (if enabled) · recent user actions.

**Act** (action tools): switch/open projects · open/close/select files · navigate
source · scroll · search · select code · edit code · add/move/remove execution
boundaries · execute sections · inspect variables · open rich viewers · switch/create
exploratory branches · run tests · interact with Git (when enabled) · use permitted
database/filesystem/process tools.

Design consequence (REQUIRED): **Studio's own UI is built on the same semantic action
layer the Agent uses.** Every user-facing action (open a file, add a boundary, select a
branch) is a semantic operation with a stable name; the Agent invokes the same
operations the toolbar/gutter do. This guarantees parity ("the Agent can do what the
user can do") by construction and avoids a divergent automation path.

---

## 13. Agent teaching capabilities

Studio UI elements have **stable machine-readable identities** and **semantic actions**
(§12). This lets the Agent teach **visually**, without screenshots:

- highlight a control,
- pulse/blink an area,
- focus a panel,
- scroll something into view,
- temporarily annotate/draw attention to a source region.

Example: *"To create an execution boundary, use the gutter here"* → Studio highlights
the gutter location.

VERIFIED reachable, no native component (coverage §3): programmatic highlight/focus =
CSS class toggle + `grab_focus` (CA); a **pulse** = CSS class + a `gi.timeout`
(WI-4/NAP-3); a **source-region annotation** = a temporary `GtkTextTag` range
(WI-2/NAP-2). The requirement (REQUIRED): this "point at a UI element by stable id and
draw attention to it" capability is **generalized** — a Studio-side teaching facility
over named widgets, not a special native path.

---

## 14. Semantic action history

Studio maintains a **structured action/event log** the Agent can inspect. It records
**semantic** events, never raw mouse movement.

Event vocabulary (PROPOSED, extensible):

`project_opened · project_switched · file_opened · file_closed · code_edited ·
section_selected · section_executed · boundary_added · boundary_removed ·
branch_created · branch_selected · variable_inspected · table_filtered · error_raised ·
test_run · git_operation · agent_action`

Each event carries a timestamp, the target identity (file/section/branch/variable), and
a compact payload. Uses: reorientation · provenance ("why did this result change?" ties
to §8/§9 staleness) · "what did I just do?" · interruption recovery ("Where was I?" §11).

**Retention/compaction (REQUIRED, so it stays bounded — §19, §23):**

- store recent events in full (a rolling window),
- **compact** older events into periodic summaries (e.g. hourly/daily rollups: "12
  edits to load.bas, ran section 3 nine times, 2 errors resolved"),
- cap total size; oldest detail is summarized then evicted,
- persisted in `.gbasic/` (SQLite is a good fit — §19), regenerable-lossy (losing old
  history degrades reorientation, never source or current state).

---

## 15. Agent architecture and selectable LLMs

Three layers kept strictly separate (REQUIRED: the Agent must not depend on one
vendor):

```
┌──────────────────────────────────────────────┐
│  Studio Agent runtime (gBASIC)                │  orchestration, context assembly,
│    — assembles project context (§11,§14)      │  permission enforcement (§17)
│    — decides tool calls, applies results      │
├──────────────────────────────────────────────┤
│  MCP / semantic tool layer (§12)              │  the stable Studio tool surface
│    — observe + act tools, permission-gated    │
├──────────────────────────────────────────────┤
│  LLM provider (pluggable)                     │  local · OpenAI · Anthropic · future
│    — via stdlib/llm.bas adapters + tool-calling│  (NAP-13 adds tool-calling)
└──────────────────────────────────────────────┘
```

- **Selectable providers**: local models, OpenAI, Anthropic, future providers.
  (VERIFIED substrate: `stdlib/llm.bas` already has anthropic + openai adapters;
  tool-calling is added generally in NAP-13, DEFERRED off Studio MVP.)
- **Different models for different roles** later (e.g. a cheap local model for
  navigation, a frontier model for hard debugging) — PROPOSED, but **v1 keeps it
  simple**: one selected provider.
- **REQUIRED:** the Agent's capability comes from **tools + context**, not vendor magic.
  A local model and a frontier model operate against the **same** semantic tool surface,
  differing only in capability. This keeps Studio provider-neutral and future-proof.

---

## 16. AI / global configuration

Studio needs layered configuration for preferences and persistent AI rules.

Scopes and precedence (REQUIRED): **session > project > global**.

| Scope | Examples | Stored |
|---|---|---|
| **Global** | preferred LLM/provider · local model endpoint · UI preferences · Git preferences · execution defaults · Agent permission defaults (§17) · persistent AI behavior rules | user-level config (outside any project) |
| **Project** | project conventions · database/environment warnings · testing requirements · project-specific AI instructions | `.gbasic/` (§19) |
| **Session** | temporary rules, e.g. *"Do not edit anything during this investigation"* | in-memory, not persisted (or a short-lived note) |

**Secrets (REQUIRED):** API keys/passwords are **never** stored as ordinary plaintext
config. Use or design toward **secure credential storage**. (VERIFIED gap: no OS-keyring
integration today; near-term acceptable fallback is an OS-permissioned,
crypto-protected store using the existing crypto library, with keyring integration as
the target. This is a Studio/platform decision to make explicitly — §22 open question.)

---

## 17. Agent permissions and safety

Because the Agent may eventually do nearly everything the user can (§12), Studio defines
**permission tiers** (REQUIRED: understandable, configurable, auditable):

| Tier | Examples | Default policy |
|---|---|---|
| **Read / inspect** | observe project, files, state, variables, history (§12 read tools) | normally automatic |
| **Reversible / local actions** | navigate · create exploratory branch · edit code · execute local sections | **configurable autonomy** (per project/session) |
| **External / destructive / sensitive** | delete files · write production DB · push Git · send external requests with sensitive data · alter production systems | **require stronger permission or explicit confirmation** |

- Tiers interact with config scopes (§16): global sets defaults; project narrows;
  session can clamp everything down (*"read-only this session"*).
- **Auditable:** every Agent action is an `agent_action` event in the history (§14),
  so what the Agent did is always reconstructable.
- Reversibility maps to the execution model: local edits/branches are reversible
  (discard/compare, §9); effectful/external actions are exactly the §8.3 non-rewindable
  set and get the strongest gate.

---

## 18. Git integration

Git is optional (§2.3) but well-integrated when present, and **visually quiet** when
not needed.

Potential features (PROPOSED): detect repo · init · clone/open · status · diff · commit
· history · branch switching · pull/push. (VERIFIED gap: no git integration exists
today; these run over the general **`process.run`** API — NAP-6 — invoking `git`, not a
bespoke binding. This is the generalized-capability path, §20.)

REQUIRED boundaries:

- Studio exploratory branches remain conceptually and technically **distinct** from Git
  branches (§2.3, §9).
- The **only** crossover: a promoted code-overlay experiment (§9.2) becomes an ordinary
  working-tree change, which Git then sees like any edit. Studio does not otherwise map
  its branches onto Git.
- Git UI stays collapsed/quiet unless a repo is present and the user engages it.

---

## 19. Persistence architecture

A clean conceptual model, separated from storage-technology choices that may evolve.

### 19.1 Logical stores (PROPOSED)

| Logical store | Scope | Typical content | Format bias |
|---|---|---|---|
| Global Studio configuration | user | preferences, provider, permission defaults, AI rules (§16) | human-readable (JSON/TOML) |
| Project registry | user | the list of projects + metadata (§3.3) for the picker | small DB or manifest |
| Project workspace state | project | tab order, open set, selected file/section/branch, pane layout (§10) | manifest in `.gbasic/` |
| Per-source dot metadata | per file | cursor/scroll, boundary anchors, per-file overlay refs (§2.2, §5.3) | small, human-diffable |
| Heavy runtime state / cache | project | serialized environments, replay checkpoints, branch snapshots, indexes, viewer caches (§8) | opaque, regenerable |
| Action history | project | semantic event log + compacted rollups (§14) | append-heavy → SQLite |
| Branch metadata | project | the execution tree/DAG, branch names/order, selection (§9) | structured → SQLite or manifest |
| Code overlays | project | scoped experimental diffs (§9.2) | small structured blobs |
| Execution provenance | project | per-section pure/effectful tags, last-run records, staleness (§8.3, §9.3) | structured |

### 19.2 Design requirements (REQUIRED)

- **Minimal hidden-file clutter** — one `.<filename>` per source; everything else
  consolidated under a single `.gbasic/` (§2.2).
- **Crash safety + atomic updates** — writes to workspace/registry/metadata use atomic
  replace (VERIFIED gap: `move` is copy+delete today; NAP-10 adds a real `rename(2)`
  `replace`). A crash mid-write must never corrupt a store.
- **Schema/version evolution** — every store carries a version; unknown newer fields are
  preserved, older ones migrated. (VERIFIED precedent: `serialize` already carries a
  magic+version, `gBS` v1.)
- **Stale-source detection** — anchors/overlays/state validated against current source
  on load (§5.3, §9.3), never silently trusted.
- **Easy cleanup + bounded growth** — `.gbasic/` is deletable to reclaim space (loses
  working context, never source); history and caches are compacted/capped (§14).

### 19.3 Technology choices (PROPOSED, separated from logic)

- **SQLite** where it fits: the action history (append-heavy, queryable), branch
  metadata, provenance, and possibly the project registry. (VERIFIED available:
  `sqlite` module behind `HAVE_SQLITE3`.)
- **Human-readable** (JSON/TOML) where diffability/hand-editing helps: global config,
  project manifest, per-file dot metadata.
- **Opaque serialized blobs** for heavy state (via `serialize`/`deserialize`), under
  `.gbasic/state/`, always regenerable.

No over-commitment: the *logical* model above is authoritative; the storage tech may
change without changing the logical design.

---

## 20. Generalized platform boundary

Studio **consumes, never reinvents** the generalized capabilities. The dividing rule
(REQUIRED, §2.5):

> If another sophisticated gBASIC application would reasonably need it, it belongs in
> the generalized platform/runtime/library layer — not in Studio.

| Belongs to the generalized platform (Studio consumes) | Owned/specified in |
|---|---|
| generalized GI bridge (WI-1/2/3/4/6/7/8/10) | coverage + plan (NAP-1..4) |
| `.property`/`.method()` dispatch (LE-1) | plan (NAP-5) |
| GTK application libraries (`gtk.bas`, reconciler) | plan (NAP-7, NAP-11) |
| GtkSourceView integration + `SourceEditor` library + `gbasic.lang` | plan (NAP-7) |
| process API (`process.run`/`start`) | plan (NAP-6) |
| runtime introspection/reflection (`reflect.*`) | plan (NAP-9) |
| filesystem metadata/atomic replace/watch | plan (NAP-10) |
| SQLite / JSON | existing runtime |
| AI/LLM tool-calling (`llm.bas`) | plan (NAP-13) |
| actor/event-loop integration (`gi.watch_fd`/`watch_mailbox`) | plan (NAP-3) |
| reusable **DataGrid** component (if needed) | plan (NAP-12) |

| Genuinely Studio-specific (owned here, all gBASIC) |
|---|
| the project model + registry semantics + picker UX (§3) |
| the workspace/window composition + tab strip (§4) |
| the execution-**section**/boundary engine (structural anchoring, snap/merge) (§5) |
| the contextual results model (per-section panes, viewer dispatch) (§6) |
| the **replay/branch engine** + provenance + staleness (§8, §9) |
| project **suspension/restoration** (§10) |
| the **Agent runtime** + semantic tool surface + teaching + history (§11–§14, §17) |
| layered **configuration** semantics (§16) |
| the **persistence layout** (`.gbasic/` schema, dot-metadata) (§19) |

**REQUIRED:** none of the Studio-specific items require Studio-specific *native C*.
They are gBASIC over generalized capabilities. The only native component in the whole
stack is the general DataGrid, which is a platform component.

---

## 21. Implementation strategy

Not a waterfall. Product milestones that **co-evolve** with the Native Application
Platform plan (which they consume) without duplicating it. Each milestone is shippable
and demonstrates incremental distinctive value.

### Studio 0 — Workspace skeleton
project registry + picker (§3) · persistent projects · source editor (via
`SourceEditor` library) · file tabs (§4) · Agent **placeholder** tab · workspace
restoration (cheap layer of §10). **Consumes:** NAP-7 (SourceEditor + gtk.bas), and
therefore all of NAP-1..5. *Value: continuity of files/tabs/cursors across projects —
already more than a text editor.*

### Studio 1 — Interactive execution
execution boundaries (§5) · section execution · contextual console (§6.3) · basic
variable inspection (§6.2) · **replay-first** state restoration (§8.1). **Consumes:**
NAP-3 (async actor results on the loop), NAP-6 (`process.run` for running sections/tests
out-of-process). *Value: Jupyter-style immediacy on ordinary `.bas` files — the core
distinctive experience.*

### Studio 2 — Exploratory execution
execution history (§14 subset) · branch selectors (§9.1) · **state-only** branches
(§9.2) · stale detection (§9.3) · branch persistence (§19). *Value: alternate
continuations without Git branches or notebook forks — a second distinctive feature.*

### Studio 3 — Rich analysis / debugging
rich value viewers (§6.2) · large **DataGrid** (§7; consumes NAP-12) · **code-overlay**
branches + promote/discard/compare (§9.2) · stronger debugging (breakpoints, §5.2).
*Value: serious analytical + debugging work; the DataGrid arrives exactly when large
data does.*

### Studio 4 — Agent (matured; parts may appear earlier)
semantic MCP tools (§12) · action history (§14, full) · project reorientation / "Where
was I?" (§11) · UI teaching/highlighting (§13) · code + execution assistance · selectable
LLM providers (§15; consumes NAP-13) · permission model (§17). *Value: continuity of
thought made active — the Agent that can put you back into your work.*

Sequencing note (PROPOSED refinement): a **minimal read-only Agent** (observe + "Where
was I?") can land as early as Studio 1 on top of the action history, since it needs only
read tools and no destructive permissions. Full act-tools + permissions mature in
Studio 4. This front-loads the continuity payoff.

---

## 22. Open questions

Genuine unresolved questions. Each tagged **BLOCKS-EARLY** (must resolve before the
relevant early milestone) or **DEFERRABLE** (safe to settle later).

| # | Question | Status |
|---|---|---|
| Q1 | **Exact execution-boundary semantics** — is a boundary strictly "between top-level statements", or may it split richer structures? What is the precise legal-location set from the AST? | **BLOCKS-EARLY** (Studio 1) — the boundary engine can't be built without it |
| Q2 | **Replay determinism** — how are `now()`/random/env reads classified and surfaced so replay is trustworthy? Static hint, runtime observation, or both? | **BLOCKS-EARLY** (Studio 1) — determines §8.3 provenance |
| Q3 | **Snapshot evolution** — when (if ever) does the interpreter-context refactor (PLAN Phase 3) happen, unlocking true snapshots (ladder rung 4, §8.2)? | **DEFERRABLE** — replay-first works without it |
| Q4 | **External/non-rewindable resources** — the exact policy per resource class (§8.3); how much is auto-detected vs. user-declared? | **BLOCKS-EARLY** (Studio 1) for the *pure/effectful tag*; finer policy DEFERRABLE |
| Q5 | **Code-overlay representation** — scoped textual diff vs. AST patch vs. shadow-file-for-actor? Affects rebase (§9.3). | **BLOCKS-EARLY** (Studio 3) — DEFERRABLE until then |
| Q6 | **Branch comparison** — what does "compare branches" show (state diff? source diff? result diff?) and how? | **DEFERRABLE** (Studio 3+) |
| Q7 | **Runtime reflection** — is whole-`Env` enumeration/serialization needed for state capture, or does per-`Value` `serialize` + explicit result vars suffice for v1? (VERIFIED: no whole-`Env` serializer today.) | **BLOCKS-EARLY** (Studio 1) — picks the §8 capture mechanism |
| Q8 | **Large-state persistence** — cap/eviction policy for `.gbasic/state/` checkpoints; when to recompute vs. cache. | **DEFERRABLE** |
| Q9 | **Agent context limits** — how much project state/history fits a model context; compaction strategy for "Where was I?" | **DEFERRABLE** (Studio 4; minimal Agent can use a small window) |
| Q10 | **Action-log retention** — exact rolling-window + rollup policy (§14). | **DEFERRABLE** (Studio 2 sets a default) |
| Q11 | **Library-defined rich viewers** — the registration convention by which a library ships a viewer for its types (§6.2) without core `display` semantics. | **DEFERRABLE** (Studio 3) |
| Q12 | **Project metadata sharing** — should any project metadata (e.g. project AI rules, boundary anchors) be *shareable/committable* alongside source for teams, or always local? | **DEFERRABLE** — affects whether some `.gbasic/` content is Git-tracked |
| Q13 | **Secure credential storage** — OS keyring vs. crypto-protected local store for API keys (§16). | **BLOCKS-EARLY** (Studio 4 / any real LLM use) |
| Q14 | **Multi-window behavior** — multiple Studio windows / projects open simultaneously; interaction with the non-reentrant evaluator (each window's runs are separate actor processes, so likely fine, but layout/registry contention needs thought). | **DEFERRABLE** |

---

## 23. Internal consistency audit

Re-read for the five conflation risks the design must avoid:

1. **Execution boundaries vs. debug breakpoints** — separated explicitly in §5.2 (table)
   and never merged; boundaries organize, breakpoints interrupt; they coexist. ✔
2. **Studio branches vs. Git branches** — separated in §2.3 (four-concept table), §9.1
   (REQUIRED distinction), §18 (only crossover is promotion). ✔
3. **Source vs. Studio metadata** — separated in §2.1 (source is inviolate) and §2.2
   (metadata lives beside, in `.<filename>` + `.gbasic/`); boundaries/overlays are
   metadata, never source (§5.1, §9.2). ✔
4. **Replay vs. snapshots** — separated in §8.2 as distinct rungs of the restoration
   ladder under one user abstraction (§8, REQUIRED separation); v1 is replay, snapshots
   are a later rung, UX unchanged. ✔
5. **Studio functionality vs. generalized platform functionality** — separated in §2.5
   and §20 (two-column ownership table + the reuse rule); the platform docs own the
   generalized layer, this doc owns Studio-specific gBASIC. ✔

No internal contradictions found among §§1–22 on these axes.

---

## Design Principles

Principles to govern future implementation decisions:

1. **Source is inviolate.** A `.bas` stays ordinary, runnable, Git-clean gBASIC. Studio
   overlays; it never rewrites the file format.
2. **Metadata beside, never inside.** One dot-file per source; one consolidated
   `.gbasic/` for the rest; heavy state is regenerable and disposable.
3. **The project is a resumable working context**, not a folder. Everything serves
   continuity of thought.
4. **User abstraction over mechanism.** Persistent execution, restoration, and branching
   are specified against user-facing concepts; the mechanism (replay → snapshots) may
   evolve underneath without changing the UX.
5. **Replay-first, snapshots-later.** Correct-by-replay now (forced by the non-reentrant
   evaluator); climb the fidelity/performance ladder without a UX change.
6. **Honest state.** Never attach stale or re-executed effects to a result silently;
   favor explicit provenance and safe invalidation over pretend-perfect snapshots.
7. **Boundaries organize; breakpoints interrupt.** Keep the two models distinct.
8. **Studio branches are not Git branches.** The only crossover is promotion into
   canonical source.
9. **Generalize by default.** If another sophisticated gBASIC app would want it, build
   it in the platform/runtime/library layer, not in Studio. Reserve native C for the one
   justified component (DataGrid).
10. **The Agent is a first-class surface, powered by tools + context, not a vendor.**
    Same semantic tool layer for user and Agent; provider-neutral.
11. **Semantic, not pixel.** Every action has a stable machine identity; the Agent
    observes and acts through the same semantic operations the UI uses.
12. **Safe by tier.** Read is free, local actions are configurable, external/destructive
    actions are gated and audited.
13. **Bounded and crash-safe.** Atomic writes, versioned schemas, compacted history,
    deletable caches.

---

## MVP Definition

The smallest Studio that already demonstrates its **distinctive** value — not merely
another text editor:

**MVP = Studio 0 + the core of Studio 1 + a minimal read-only Agent.**

Concretely, the MVP delivers:

- **Project picker + registry** with lifecycle status and persistence (§3).
- **Native workspace**: editor area, collapsible right/bottom panes, `[Agent] | file
  tabs` strip with persisted order/selection (§4).
- **`SourceEditor`** with gBASIC syntax highlighting (consumes NAP-7).
- **Execution boundaries + section execution** over ordinary `.bas`, runs out-of-process
  as actors (§5), with **replay-first** state (§8.1).
- **Per-section contextual console + basic variable inspection** (§6), including the
  `[Inspect]`/`[Table]` offer for recognizably-tabular results using **modest** (non-
  DataGrid) tables (§7).
- **Suspension/restoration of the cheap layer** — files, tabs, cursors, scroll, pane
  layout, selected section — restored instantly on reopen, with expensive state restored
  lazily (§10).
- **A minimal read-only Agent**: observe project + action history, answer "Where was
  I?" (§11, §14) — no destructive tools yet.

This is already unlike any plain editor: it *resumes your working context* and gives
*Jupyter-style section execution on plain source files with a read-only reorientation
Agent* — the three things that make Studio Studio, in their smallest honest form.

**MVP explicitly excludes** everything in Deferred Capabilities below.

---

## Deferred Capabilities

Must **not** block the MVP:

- **Exploratory branching** of any kind (state-only and code-overlay) — Studio 2/3.
- **Code overlays**, promotion/discard/compare, rebase (§9.2/§9.3) — Studio 3.
- **Rich/library-registered viewers** and the **large DataGrid** (NAP-12) — Studio 3.
- **Snapshot/checkpoint restoration** beyond plain replay (ladder rungs 2–5, §8.2).
- **True interpreter snapshots** (needs PLAN Phase 3 interpreter-context refactor).
- **Full Agent act-tools + permission model** (§12 write tools, §17) — Studio 4;
  MVP Agent is read-only.
- **UI teaching/highlighting** (§13) — Studio 4.
- **Selectable multi-provider LLM + tool-calling** (§15, NAP-13) — Studio 4 (MVP Agent
  can use a single provider, no tool-calls).
- **Git integration** (§18) — additive whenever `process.run` (NAP-6) is present.
- **Reflection facility** (NAP-9), **filesystem watch** (NAP-10 `watch_file`),
  **reconciler** (NAP-11) — as their consuming features arrive.
- **Custom project statuses, multi-window, team/shared metadata** (§3.2, Q12, Q14).
- **Secure keyring** beyond a crypto-protected local store (Q13) — before real
  multi-provider use.

---

## Relationship to Native Application Platform

Studio is a **consumer** of the generalized platform. The precise expectations:

**From `docs/gbasic_native_app_platform_coverage.md`** (the survey establishing what is
reachable and how it is classified) Studio adopts, without re-deciding them:

- the verdict that the **entire UI surface** (windows, panes, tabs, menus, lists,
  console, editor, inline boundary/branch widgets, value inspector) is **CA/BG** — no
  Studio native code;
- **SourceEditor as a gBASIC library** over generic GI (SW-1 native wrapper withdrawn) —
  Studio's §5/§6 editor is this library;
- the **async safety model** (§7 of coverage): actors + `gi.watch_fd`/`watch_mailbox`,
  no interpreter threads — Studio's §8 replay and §12 responsiveness ride exactly this;
- the single justified native component, the general **DataGrid** (coverage §5/§8) —
  Studio's §7 large-table tier consumes it, does not define it;
- the reflection/process/filesystem/llm generalizations (coverage §9) — Studio's §8/§12/
  §18/§19 depend on these as *platform* facilities.

**From `docs/gbasic_native_app_platform_plan.md`** (the ordered build) Studio expects, as
prerequisites, the completion of specific phases before specific milestones:

| Studio milestone | Requires (NAP) |
|---|---|
| Studio 0 (skeleton, editor, tabs) | NAP-1..5 (bridge core + dispatch) + NAP-7 (SourceEditor + gtk.bas + gbasic.lang) |
| Studio 1 (section execution, replay, console) | NAP-3 (async results on the loop) + NAP-6 (`process.run`) |
| Studio 2 (branches, history) | — (gBASIC over existing capabilities; may use NAP-9 reflection if available) |
| Studio 3 (rich viewers, large data, overlays) | NAP-12 (DataGrid) + NAP-10/NAP-11 as convenient |
| Studio 4 (full Agent) | NAP-13 (llm tool-calling) |

Studio itself begins **only after the Native Application Platform Spike (NAP-8) is
accepted** — the plan's proof point — since that spike validates every capability
Studio 0/1 lean on (editor, panes, dynamic widgets, async actor results, `process.run`,
inline child-anchor widgets, programmatic highlight). Studio then adds **only
Studio-specific gBASIC** (the section/branch engine, replay, agent orchestration,
project/workspace model, persistence) on top of the platform.

### Contradictions found with the four existing documents

**None.** This design is consistent with all four. Specifically checked:

- The **replay-first, non-in-process-snapshot** stance (§8) matches the coverage/plan
  premise that the evaluator is non-reentrant and concurrency is process-actors.
- The **SourceEditor-as-library, DataGrid-as-only-native-component** split (§5, §7, §20)
  matches the coverage reclassification exactly (SW-1 → B, SW-2 → C).
- The **async model** (§8, §12) matches coverage §7 (`gi.watch_fd`/`watch_mailbox`, no
  threads).
- The **Studio-begins-after-NAP-8** sequencing matches the plan's boundary discipline
  ("Studio is a separate subsequent effort that consumes this platform").

No changes were made to the four source documents. Had a contradiction been found, it
would be reported here rather than silently reconciled — none was.
