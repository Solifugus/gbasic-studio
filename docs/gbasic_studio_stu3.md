# gBASIC Studio — STU-3 reference (execution-section engine)

Status: **implemented.** Documents what STU-3 adds on top of STU-0 (backbone),
STU-1 (navigation) and STU-2 (documents & editor): a headless **execution-section
engine** — derive a document's sections from its real structure, give each one a
Studio-owned stable id, and re-resolve those ids across edits by structural
evidence rather than line numbers. No execution, replay, results, provenance,
branches, breakpoints, AI, or boundary widgets (later phases).

STU-3 is **additive**: STU-0/STU-1/STU-2 stores, lifecycle, and goldens are
unchanged.

## Ownership direction

```
Platform  source_outline(text)         ' owns SOURCE STRUCTURE (parse, ranges, nesting)
        v
Studio    studio_sections.bas          ' owns SECTION IDENTITY (ids, anchors, matching)
        v
Workspace record  ws.sections          ' owns PERSISTENCE (per-document anchor bundles)
```

The split is the point. The platform answers *"what is in this text?"* and is
reparsed freely; Studio answers *"which of these did the user mean, and is it the
same one as last time?"* and must be stable across reparses. `studio_sections` never
reaches into the parser, and `source_outline` knows nothing about sections.

Resolves plan risk **R1** in its intended form: STU-3 consumes the *general*
in-process `source_outline(text)` builtin (PLAT-OUTLINE) rather than a Studio-private
C path or a `process.run ./gbasic --ast` stop-gap.

## Scope of a section (design §3, §6.2)

Sections are the top-level units of the **executed** statement list, because that is
the only place the evaluator can stop and later resume by replay
(`docs/gbasic_execution_boundaries.md` §1–§4, all VERIFIED against `eval.c`):

- **Scope selection.** With exactly one top-level `program` block, that block's
  **body** is the executed list: its wrapper is dropped and its direct children
  become section-level. Anything declared outside it is hoisted into its own
  sections ahead of them. Otherwise the file's top level is the executed list.
- **Runs of plain statements** between declarations collapse into one
  `kind="statements"` section. Compound statements (`if`/`while`/`for each`/
  `consider`/`with lock`) are **atomic** — never split, since the walker cannot
  resume inside one.
- **Named declarations** (`program`, `library`, `function`, `modifier`) are
  landmarks: each is its own section, carrying its name.

Sections are therefore **derived**, contiguous and non-overlapping, and cover the
executed list in source order. Every seam between them is a legal boundary by
construction.

## Identity: anchors and fingerprints

A section id (`sec-N`, minted from a per-document counter that never rewinds) is
Studio's, not the parser's. What lets an id find its section again after an edit is
its **anchor** — never a line number:

| Field | What it survives |
|---|---|
| `kind` | gates every match tier |
| `name` | rename detection (`nothing` for statement runs) |
| `ancestry` | `top` or `program:<name>` — the executed list it belongs to |
| `ordinal` | source position among same-kind siblings in the same ancestry |
| `header_fp` | fingerprint of the first line — the declaration header |
| `body_fp` | fingerprint of the whole range |
| `kinds_sig` | comma-joined member kinds — the shape of a statement run |
| `start_offset_hint` / `end_offset_hint` | last-known byte range, a hint only |

Fingerprints are a rolling hash over **bytes** with every whitespace run folded to a
single space and the ends trimmed. Reindenting a function, or inserting blank lines
above it, therefore does **not** change its fingerprint — which is why the
`insert_blank` case reattaches every id with the byte ranges all shifted. Collisions
are gated by kind/ancestry during matching, so the hash need not be cryptographic.

## Reattachment (deterministic, never guessing)

`refresh(state, source)` derives candidates and matches them against the previous
sections over four tiers, strongest first:

1. `header_fp` **and** `body_fp` equal — unchanged.
2. same `name` (named sections only) — body edited, still the same declaration.
3. same `body_fp` — renamed, body identical.
4. same `kinds_sig` **and** `ancestry` — a statement run of the same shape.

A pair reattaches **only when it is unique on both sides** at that tier: exactly one
surviving previous section matches this candidate, *and* exactly one unmatched
candidate matches that previous section. Bidirectional uniqueness is what makes the
result independent of iteration order — the outcome is the same whichever end you
walk from.

Then:

- Unmatched candidates that still resemble a surviving previous section at a strong
  tier (2 or 3) get a **fresh id and `status="ambiguous"`**. Duplicating a function
  verbatim is the canonical case: two identical candidates and one previous id, so
  neither may claim it. Studio flags the ambiguity instead of silently attaching
  state to a coin flip.
- Unmatched candidates with no such resemblance are genuinely **new** (fresh id,
  `active`).
- Previous ids nothing matched become **stale**: reported in `state.stale_ids`, not
  reused and not silently dropped — anything hanging off them (STU-4 results,
  captured state) can then be invalidated deliberately.

Cost is O(n²) in section count, which is bounded by top-level units per file.

## Invalid source: last known good

`source_outline` reports `ok=false` with diagnostics for source that does not parse —
the normal state of a file mid-keystroke. On that path `refresh`:

- **retains** the previous sections and their ids untouched,
- records `state.diagnostics`,
- sets `valid=false`, and
- leaves `revision` unchanged.

It never reattaches against a failed parse and never deletes a section because
parsing failed. When the source parses again, matching resumes from the retained
state and the ids come back (`sections_invalid` walks valid → broken → restored and
shows the same ids on both ends). Editing a file into a broken intermediate state
does not cost the user their section identities.

## Cursor resolution

`section_at(state, offset)` returns the id of the section containing a **byte
offset**, or `nothing` in a gap / before the first / past the last / in a stale
range. Sections do not overlap, so at most one can contain it; a position inside a
nested block resolves to its enclosing section, and `end_offset` is exclusive so a
cursor on a closing `end function` is still inside that function.

Editors do not speak byte offsets, so `offset_of(source, line, column)` converts the
**1-based BYTE** line/column that the outline, the diagnostics and `studio_docs`
cursors all use (`docs/source_outline_design.md` §1.3), and
`section_at_position(state, source, line, column)` is the one-call editor path.
Columns are byte columns: a line containing `héllo` advances the column by the UTF-8
byte length, not the character count. Out-of-range positions **clamp** to end of
source rather than raising, so a cursor left over from a longer previous revision
degrades to "past the last section" instead of breaking the caller.

## Persistence (compatible)

`to_persist(state)` emits a compact `{schema_version, next_sec, anchors}` record: ids
plus Studio anchors, deliberately **not** outline node ids or ranges-as-identity
(structure is regenerated by reparsing; ranges persist only as hints).
`from_persist(raw, doc_id)` rebuilds an anchor-only state whose ranges are last-
session hints until the next `refresh` reattaches them to freshly parsed structure.

The workspace record carries one additive slot, `ws.sections`: a list of those
records tagged with `doc_id`, managed by `persist_into` / `restore_from` / `forget`.
Compatibility works exactly as `nav` (STU-1) and `docs` (STU-2) did:

- a workspace written **before** STU-3 has no `sections` key; it reads back as
  `unknown`, `studio_model.normalize_workspace` backfills `[]`, and every accessor
  treats absent/`unknown`/`nothing` as "no sections yet" — **no migration step**;
- a reader that does not know the slot ignores it;
- the bundle is `json_encodable` end to end (offsets and fingerprints are numbers; an
  absent name is `nothing` → JSON `null` → `nothing` again on decode), so it goes
  through `studio_store.write_atomic` unchanged.

`sections_store` proves the full disk round-trip: persist → strict JSON →
`atomic_replace` → read → normalize → restore → reparse after an intervening edit,
with surviving ids identical and the deleted section's id stale.

## Parser-side change (supporting)

STU-3 makes `gb_parse` run **repeatedly on source that usually does not parse** — once
per refresh, as the user types. That made a pre-existing leak matter: Bison discarded
semantic values from the parser stack on every syntax error without freeing them.
`src/parser.y` now declares `%destructor` rules for every AST-bearing type.

One subtlety is load-bearing: Bison also treats **the start symbol as discarded when
the parse succeeds**, so the accept-path cleanup would run the `<stmt_list>`
destructor on the finished program — freeing the AST the evaluator is about to walk.
`program` therefore carries a per-symbol no-op destructor overriding the per-type one,
because its value has already moved to `ctx->parsed_program`.

Measured on this host (valgrind, `--leak-check=full`):

| Case | Before | After |
|---|---|---|
| one file with a syntax error | 100 bytes definitely lost in 4 blocks | 0 |
| a second, differently broken file | 96 bytes in 3 blocks | 0 |
| 200 `source_outline` calls on invalid source | 20,000 direct + 46,400 indirect bytes lost | 0 |

The third row is the STU-3 access pattern, and the reason the change belongs here.

## UI behavior (display)

STU-3 renders **nothing**. Boundary/section widgets are STU-5; this phase is a model,
validated headlessly. The display tier that exists (`sections_gui`) verifies the
*integration* rather than any drawing: with the real GTK 4 shell built and a real
editor tab open, the live document buffer derives sections and the document's own
line/column cursor resolves to a section id.

## Tests

`tests/run_studio.sh` (headless, GI-independent, path-free goldens), driver
`examples/studio/sections.bas` — a mode per scenario:

| Case | What it pins |
|---|---|
| `derive` | scope-level derivation, statement runs vs. declarations, ordinals |
| `cursor` | byte-offset → section, gaps and out-of-range |
| `cursor_pos` | line/column → offset → section, byte columns over UTF-8, clamping |
| `prog` | sections come from a `program` block's body |
| `insert_blank` | blank line above shifts every range, changes no id |
| `internal` | body edit keeps the id (tier 2) |
| `rename` | rename keeps the id (tier 3) |
| `sibling` | inserted function is new; neighbours keep ids |
| `duplicate` | verbatim duplicate → `ambiguous`, no guessed attachment |
| `delete` | removed section's id goes stale, is not reused |
| `invalid` | valid → broken (retained, `valid=false`) → restored (same ids) |
| `persist` | in-memory anchor round-trip, ids preserved through reparse |
| `store` | on-disk round-trip via `studio_store`, stale after an away-edit |
| `compat` | pre-STU-3 workspace loads with no migration; unknown doc id is empty |
| `multidoc` | two documents keep independent id spaces |
| `unicode` | byte offsets over multi-byte source |
| `repeated` | 25 refreshes of identical source are idempotent |
| `sections_memory` | valgrind, no definite leaks across refresh churn + store |
| `sections_gui` | GTK shell + live editor cursor (SKIPs without GTK 4/display) |

## Known limitations

- **Sections are derived, not user-placed.** The plan's STU-3 sketch also listed
  user boundary *editing* — add (snap to nearest legal location), move (re-snap),
  remove (merge adjacent sections). This phase implements the derivation, identity
  and drift half; the merge/split overlay on top of the derived set is not built.
  Every seam between derived sections is a legal boundary, so that overlay is
  additive over this model rather than a rework of it.
- **Anchors persist in the workspace record, not the per-file `.<filename>`
  dotfile.** This follows STU-2, which put open-document metadata in the workspace;
  moving both to dotfiles is one change, not two.
- **`ambiguous` is reported, not resolved.** No UI asks the user which duplicate they
  meant (there is no UI in this phase).
- **Fingerprints fold whitespace but not comments.** Editing only a comment inside a
  section changes its `body_fp`; the section still reattaches by name (tier 2) when
  it is a named declaration, but an anonymous statement run falls to tier 4.
- **O(n²) matching** in sections per document. Fine for top-level units per file; it
  would need revisiting only if sections ever became fine-grained.
