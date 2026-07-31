# gBASIC Studio — STU-5A reference (persistent section-linked results and history)

STU-4/STU-4B run a section and produce a result **in memory**. When the session
ends, it is gone. STU-5A makes results durable, browsable, and — the part that
carries the most weight — honest about whether a stored result still describes the
code on screen.

State inspection is **not** here; that is STU-5B and needs the reflect-epilogue
design R2 sketched. Read `docs/gbasic_studio_stu4.md` and `stu4b.md` first.

## The result record

One run, one record. Emitted by `studio_session.to_result(session, sections)`,
which reads what a run already produced — it changes nothing about how a run
happens.

```
{ result_id, section_id, section_fingerprint, section_kind, section_name,
  started_epoch, finished_epoch, duration_seconds,
  outcome, exit_code, signal, success, reason, message,
  split_out, split_err, split_reason,
  captures: { out_prefix, out_target, err_prefix, err_target },   ' byte counts
  truncated: [ <capture name> ], attribution: [ ... ], run_seq }
```

`outcome` is the session's terminal state: `finished`, `refused` or `failed`. **A
refusal is recorded**, with its STU-4 reason code — Studio declining to run is an
event, and a history that quietly omitted it would misrepresent the session.

`attribution` is STU-4B's resolved per-diagnostic section attribution, carried
through unchanged, so a stored result still says which section each error belonged
to.

### Timing is second-resolution, and says so

`epoch()` is whole seconds; the runtime exposes no finer clock. A run shorter than
a second therefore records `duration_seconds: 0`. That is reported as it is rather
than dressed up with a millisecond figure the platform cannot measure. The session
gains a `clock_fixed` seam (mirroring `nonce_fixed`) so goldens stay byte-stable
while real runs still happen.

### The section fingerprint

**A result records the fingerprint of the section content it actually ran**, taken
at emit time from the sections state the run was launched against.

Section ids are stable across edits *by design* — that is STU-3's entire purpose —
so a result keyed by id alone would silently appear to describe code that has since
changed. The fingerprint is STU-3's own `header_fp:body_fp` pair, which folds
whitespace runs, so reindenting or inserting a blank line does **not** read as a
content change while any real edit does.

The comparison is **surfaced, not merely stored** — see *Standing* below.

## The store

### Not the workspace record

STU-3's anchors live in the workspace record because they are small and bounded.
Results are neither: one STU-4 case moves ~155 KB of output in a single run, and
history accumulates. Putting them there would make every settings or navigation
write rewrite megabytes.

### Location and granularity: one file per document

```
<home>/results/<key>.json
```

- **Per document, not per workspace.** A document is the unit of concurrency: STU-4
  permits one session per document and several at once. Distinct documents write
  distinct files, so non-clobbering is **structural** rather than hoped for —
  gBASIC has no lock primitive that could make a shared file safe.
- **Per document, not per section.** A section's results are only ever wanted in
  the context of its document. Per-section files would multiply small-file overhead
  and turn "this document's history" into a directory scan.

### Keyed by path, not by `doc_id`

`doc-N` is minted per launch from an open-order counter (`studio_docs.open`), so it
is **not stable across restarts** — open the same files in a different order and
`doc-2` means a different document. STU-3 can key its anchors by `doc_id` because
they are a cache that re-derives correctly on open; a result history is not
self-healing, and attaching one document's runs to another is exactly the silent
wrongness this project refuses at every other layer.

The filename is a readable path tail (so a directory listing means something to a
human) plus a rolling hash of the whole path (so two files sharing a basename never
collide). Pure gBASIC on purpose: `sha256` sits behind `HAVE_LIBCRYPTO`, and
results must not stop working where crypto is compiled out.

### Format: a small index plus sidecar capture files

```
<home>/results/<key>.json    the index -- metadata for every result
<home>/results/<key>.d/      the captures -- raw bytes, one file per stream
                               res-1.out_target, res-1.err_prefix, ...
```

The index goes through `studio_store` with the same atomicity discipline as every
other store: `json_encode` to a `.tmp` sibling, then `atomic_replace` (one
`rename(2)`), and a pre-validated read that never raises.

**The split was forced by measurement, not taste.** The first implementation put
the four capture texts inside the JSON. `studio_store`'s read path must
pre-validate with `studio_json.valid`, because `decode` raises and gBASIC cannot
catch a raise — and that validator is pure gBASIC walking one character at a time,
at roughly **2 KB/s**:

| | time |
|---|---|
| `studio_json.valid` on 116 KB | **53 s** |
| `decode` (C builtin) on the same 116 KB | **< 1 s** |
| `studio_results.open()` on a store holding two 64 KB captures | **74 s** |
| the same `open()` after moving captures out | **0.10 s** |

At the chosen retention that layout would have taken *tens of minutes* to open a
well-used document's results — the policy would have been unusable, not merely
slow.

> **Update (PLAT-JSON, 2026-07-28).** The validator is gone: `studio_store` now
> reads through the `try_decode` builtin, and the numbers above no longer apply to
> anything. A 115 KB index opens in well under a second, and even a 4.6 MB index of
> 9 600 records loads in under one. **The sidecar layout is kept anyway**, on the
> two grounds that were never about parse speed: the index is rewritten whole on
> every save (`atomic_replace`), so inlining capture text would mean rewriting
> megabytes on every run; and captures are read only when displayed, so browsing
> history touches none of them. The layout is unchanged — only its justification
> is now narrower and more accurate. Captured output is opaque bytes that JSON gains nothing from holding, so it
lives beside the index: the index stays a few hundred bytes per result and loads
instantly however much output was captured, and a capture is read with a plain
`read()` that validates nothing.

`studio_results.capture(home, store, result_id, name)` reads one on demand;
`capture_bytes(result, name)` answers "how much output is there?" from the index
alone, so browsing history pulls nothing off disk.

**Crash-safety survives the split by ordering.** Capture files are written first,
then the index is swapped in atomically. A crash in between leaves capture files
nothing references — never an index pointing at a capture that is not there — and
`sweep_captures` clears them on the next save. Eviction deletes the dropped
results' capture files, so the retention bound is a fact on disk and not just in
the index.

### No migration step

A pre-STU-5A home has no `results/` directory, so it loads as an empty store. There
is nothing to migrate — the same additive-by-construction property STU-3's
`sections` slot has, achieved here by living in a separate place entirely.

## Retention and truncation

Unbounded growth is not acceptable, and neither is silent loss.

| policy | value | why |
|---|---|---|
| results kept **per section** | 20 | per *section*, not per document: churning one section must not evict the history of another the user has not touched. Deep enough for an editing session's attempts, shallow enough to stay bounded without a background collector. |
| size cap **per capture** | 64 KB | one pipe buffer's worth — more than anyone reads in a results pane, and it keeps the hard ceiling (20 × 4 captures × 64 KB ≈ 5 MB per document) small. Capture size no longer affects load time at all, since captures are not in the validated index; the cap bounds *disk*. |
| eviction | **on write** | append-then-prune, so the store is never over the bound even momentarily at rest. No sweep, no background task. |

An oversized capture keeps its **head**, not its tail: the head is where a program
says what it is doing and where the first error appears; the tail of a runaway loop
is its least informative part. The cut lands on a codepoint boundary (binary search
over `mid` with `byte_count` as the oracle), so truncation never produces invalid
UTF-8.

**A truncated capture is recorded as truncated, twice over**: the capture's name
goes in `truncated`, *and* a notice line is appended to the stored text itself. A
reader that ignored the field still cannot mistake a cut capture for a complete one.
A truncated capture presented as complete is the same class of error as a fabricated
boundary.

## Standing — orphaned results and the fingerprint comparison

`studio_results.standing_of(result, sections)` compares a stored result against the
sections **as they stand now**. It is computed on every read and **never stored**:
it is a function of the current sections, and persisting it would recreate exactly
the stale-result bug it exists to prevent.

| standing | when |
|---|---|
| `current` | the section is active and its content is unchanged |
| `stale-content` | the section still exists, but its text has changed since the run |
| `section-ambiguous` | STU-3 could not decide which section this id names |
| `section-gone` | the section was removed, or went stale |
| `source-invalid` | the document does not parse, so the sections on hand are last-known-good and nothing can honestly be compared against the live text |

**Results are never deleted because a section changed, and never reattached to a
different section.** They are only ever evicted by the retention policy.

### What STU-3 actually does, and why `ambiguous` mostly reads as `gone`

Measured, not assumed (`results_orphan` prints the section state):

when a declaration is duplicated verbatim, STU-3 mints **fresh ids** for both
candidates (`sec-4`, `sec-5`, both `ambiguous`) and sends the original `sec-2` to
`stale_ids`. A result naming `sec-2` therefore finds no section and reads
`section-gone` — because the id it names no longer denotes anything, and attaching
it to either copy would be a guess. Silence is the honest answer.

`section-ambiguous` is still reachable, by the one path that produces a result
against an ambiguous section: **asking to run it**. STU-4 refuses with
`section-ambiguous`, STU-5A records the refusal, and that record classifies as
`section-ambiguous` — distinct from gone. `results_orphan` exercises exactly this.

## The minimal view

`studio_results.view_text(store, sections, section_id)` renders the latest result,
its output, its truncation note and its diagnostics, then the history behind it —
newest first, each line carrying its standing:

```
Results — sec-2  (2 run(s))
latest: res-2  finished exit 0  at 1100  0s  [section edited since this run]
history:
  res-1  finished exit 0  at 1000  0s  [section edited since this run]
```

`studio_shell.results_pane()` mounts it in GTK, and `studio_shell.results_text()`
delegates the wording to that one function, so the headless goldens and the display
tier cannot drift apart — the view is one function rendered in two places.

Nothing else: no inspector, no diffing between runs, no charts, no gutter work.

## Tests

`tests/run_studio.sh`, headless tier, twelve new cases over
`examples/studio/results.bas`:

| case | proves |
|---|---|
| `persist` | a result written and restored byte-identically across a simulated restart |
| `history` | ordering newest-first, per-section filtering, survival of a restart |
| `fingerprint` | a section edited after a run — id survives, fingerprint does not, mismatch surfaced; reindentation does *not* count as a change |
| `orphan` | results surviving removal, ambiguity (with STU-3's actual id behaviour shown) and an unparseable document, never deleted, never reattached |
| `refused` | two refusals recorded with their reason codes and restored |
| `signal` | a child killed by SIGTERM recorded with `signal=15` |
| `truncate` | ~84 KB of output cut at the cap, head kept, notice in the text, name in `truncated`, both surviving a reload |
| `truncate_unit` | the truncation path without a child: per-capture independence, an empty capture writing no file, JSON-encodability, and a multi-byte codepoint straddling the cap never split in half |
| `evict` | 23 runs of one section pruned to 20 newest, another section's single result untouched, the dropped results' capture FILES deleted, and a stray file from an interrupted write swept on the next save |
| `concurrent` | two documents with children alive simultaneously, distinct files, neither store clobbered |
| `compat` | a pre-STU-5A home, plus corrupt and future-schema stores, each reported rather than misread |
| `store` | the on-disk shape: schema, index keys, the sidecar capture files, that the index holds no capture text, and that results live outside the workspace record |
| `view` | the rendered pane in every standing, including the mismatch mark |

Plus a scratch-empty assertion after every case, a store-separation check on disk,
an assertion that the largest index in the suite stays under one capture's cap, an
on-disk size report, and a valgrind tier over
`persist/truncate/truncate_unit/evict/orphan`.

The display tier (`stu5_smoke`) records a real run, persists it, re-reads it, and
renders the pane before, after, and after an edit. It SKIPs cleanly without GTK 4
or a display.

## Intentional golden changes

None. STU-0 through STU-4B goldens are byte-identical: STU-5A adds fields to the
session record but changes no summary line, and every result path is new surface.

## On-disk cost, measured

After a full test run (13 cases, each with its own throwaway home):

| | data (apparent) | allocated | files |
|---|---|---|---|
| whole test run | 211 KB | 528 KB | 82 |
| `evict` (21 results, one document) | 10 KB | 176 KB | 42 |
| `truncate` (one 84 KB capture, cut) | 66 KB | 72 KB | 2 |
| `persist` (one clean run) | 546 B | 12 KB | 3 |

Two things worth stating plainly rather than quoting only the flattering number:

- **The index stays small.** The largest in the suite is 9 887 bytes for 21
  results — about 470 bytes each, and independent of how much output they
  captured. That is what keeps `open()` at ~0.1 s.
- **Block overhead dominates when captures are tiny.** `evict` holds 10 KB of real
  data in 176 KB of allocated blocks, because 41 capture files of a few bytes each
  still take a filesystem block apiece. Empty captures write no file at all, so a
  typical run leaves one or two rather than four; at the retention limit a
  heavily-used document costs roughly 160 KB of blocks. That is the price of
  instant loads, and it is bounded — but it is block overhead, not data, and
  `du -sh` will say the larger number.

## What this changes for STU-5B

- **The record is the extension point.** State inspection adds fields to a shape
  that already persists, versions and evicts, rather than needing a second store.
- **Standing generalizes.** Whatever STU-5B captures about state is subject to the
  same question — does this still describe the code on screen? — and gets the same
  answer from the same fingerprint.
- **Second-resolution timing is a known limit.** If STU-5B wants meaningful
  durations it needs a platform-side monotonic clock; that is a PLAT change, not a
  Studio one.
- **`split_err` is still `unavailable`** whenever a prefix exists. STU-4C can close
  it now that PLAT-STDERR exists (`print to error`), and stored results will pick up
  the improvement without a schema change — the field is already per-stream.
