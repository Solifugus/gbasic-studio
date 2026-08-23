# gBASIC Studio — STU-4B reference (materialization completeness)

STU-4 shipped execution sessions and named two gaps it could not close inside its
brief. STU-4B closes both, over one shared mechanism rather than two:

1. **A byte prefix cannot reach a declaration written below the target.** A program
   block whose body calls a helper defined after `end program` could not be
   section-run at all — and helpers-after-main is ordinary style, so this failed on
   a large class of normal programs.
2. **Prefix and target output shared one stdout stream** with no way to tell them
   apart, so every run with a prefix reported `split: combined`.

Both are position problems, so both are solved by generating content whose position
Studio itself knows, and recording that knowledge in a **position map**.

Read `docs/gbasic_studio_stu4.md` first; this document only covers what changed.

## Step 0 finding: gBASIC has no statement separator

This decided the output-separation design, so it was settled against the grammar
before anything was built.

**There is no statement separator, and no construct that permits a second statement
after a compound terminator.** Every statement production in `src/parser.y` ends in
`NEWLINE` (`statement:` at line 586ff, and the `consider` variant at 753ff). `COLON`
is a token, but the grammar uses it only for labels (`variable_name COLON`), record
field keys, and field policies. `;` is not a token at all — the lexer rejects it.

Measured, not inferred:

| input | result |
|---|---|
| `print 1 : print 2` | `syntax error, unexpected COLON, expecting NEWLINE` |
| `print 1 ; print 2` | `lexer error: unexpected token` |
| `end if print "b"` | `syntax error, unexpected PRINT, expecting NEWLINE` |
| `if x = 1 then print "a"` | works — an *inline if*, not a separator |
| `print 1 ' comment` | works — but a comment emits no output, so it cannot mark |

The one construct that puts two things on a line is `if <cond> then <statement>`,
which is a form of `if` and cannot be suffixed onto `end if`, `end while`,
`end function` or any other terminator.

**Therefore a zero-line-shift marker is impossible**, and STU-4B uses the specified
fallback: **one injected marker line, one offset**. Any child line at or after the
injection maps to document line − 1. There is no general N-marker scheme.

## Part 1 — Declaration hoisting

Materialization appends top-level declarations that sit **wholly after** the byte
prefix, in source order, at the very end. Appending shifts nothing before it, so the
prefix keeps its line numbers.

### What qualifies as hoistable

Exactly the top-level `function`, `modifier`, `library` and (since PLAT-WEB-5)
`server` declarations — and only when **the prefix contains a program block that
will execute**.

That condition is not a heuristic; it is the precise condition under which the
interpreter *already* treats these declarations as position-independent:

- `eval_program` (`src/eval.c`) pre-registers every top-level non-attached
  `function`, every `modifier` and every `server` block **before** running the
  program block, regardless of where in the file they appear, and
  `register_method_bodies_in` walks the whole root for dotted-def bodies.
- `library` resolution scans the root AST, so `load` finds a library declared
  anywhere. Verified: a program block's `load helper` resolves a `library helper`
  written after `end program`.

Under that condition hoisting **reproduces** the document's semantics. Without it —
a prefix with no program block — top-level statements execute in order, a
declaration below the target is invisible to the target in the real document too,
and hoisting would *manufacture* behavior the document does not have. Nothing is
hoisted in that case.

Detection is structural: a program block opens inside the prefix exactly when some
section with `program:` ancestry starts before the prefix end.

### Why nothing can be reordered

When a program block is present, **it is the only thing that runs.** Top-level
statements outside it never execute at all:

```
program main()
  print "B"
end program
print "C"          ' never runs
```
prints `B` and nothing else.

So there is no executable effect between the block and a hoisted declaration that
could be reordered — there is no executable effect out there at all. `sessions_hoist_inert`
proves it directly: a top-level `print "TOP-LEVEL-NEVER-RUNS"` sits between the
block and the hoisted helper, and the run reports `top_level_ran=false`.

### What is deliberately *not* hoisted

- **Executable statements** at top level (`statement`, `if`, `while`, `for_each`,
  `consider`, `watch`, `with_lock`, `without_watchers`) — reordering an effect is a
  correctness violation, not an inconvenience.
- **The `program` block itself.**
- **Anything already inside the prefix**, including a declaration that *is* the
  target: a section is either wholly before or wholly after the prefix end (sections
  do not overlap and the prefix ends on a section boundary), so a declaration is
  never hoisted into itself.

Attached (dotted) definitions are hoisted with everything else and are inert either
way: their bodies register, but the attachment statement never runs — which is
exactly what happens in the unmodified document, where `o.twice()` from inside a
program block fails whether or not the definition is below `end program`.

### No refusal was needed

The brief allowed refusing a run when a declaration could not be hoisted safely. No
such case exists: the rule hoists only where the runtime is already position-blind,
and declines to hoist everywhere else, so there is no configuration where hoisting
is attempted-but-unsafe. STU-4's four refusal codes are unchanged.

## Part 2 — Output separation

A marker line is injected at the **start of the line beginning section N**:

```
print "<nonce>"
```

At the line *start*, never at the section's own offset — the section's text then
begins on the next line with its indentation intact, so **columns never move** and
the map carries a line offset only. Nothing but whitespace can precede a section's
first token on its line, because gBASIC has no statement separator and a comment
runs to end of line.

It is appended to the end of section N−1's region rather than prepended inside
section N's, in the sense that matters: everything the marker shifts is content that
still needs mapping, and exactly one offset covers all of it.

### The nonce

Per run, never a fixed sentinel — a user program can print anything:

```
@@gbstudio-<epoch>-<run_seq>-<random>-<random>@@
```

Digits and hyphens only, so it is safe inside the generated string literal. A test
seam (`session.nonce_fixed`) lets a fixture print the nonce on purpose.

### Deciding the split

Once the run ends, the finished stream is searched:

| occurrences | `split_out` | meaning |
|---|---|---|
| — (target is section 1) | `exact` | no prefix exists; all output is the target's |
| 1 | `marked` | the stream splits there; the marker line is stripped from display |
| 0 | `combined` | `split_reason=marker-absent` |
| ≥2 | `combined` | `split_reason=marker-ambiguous` |

Zero occurrences is the **correct** answer, not an error, when the child died inside
the prefix (`sessions_split_die`) or the marker sat where it could never execute.
Two or more means a user program printed the nonce itself: there is then no way to
tell which occurrence is the boundary, so the run does not guess — the STU-3
ambiguity principle applied to a stream. Both occurrences stay in the displayed
text, because exactly one of them is ours and stripping the wrong one would delete
the user's output.

The split is decided **once, at the end**. A marker that has not arrived yet is not
the same as one that never will, and only a complete stream can tell those apart; a
run in flight reports `split_out=pending` and the UI shows the raw stream.

### Per stream, not per session

`split_out` and `split_err` are separate fields. **stderr is never separated when a
prefix exists** — the marker is a `print`, so it lands on stdout only and there is
no boundary in the diagnostic stream. `split_err` is `unavailable` in that case, and
says so rather than letting the UI infer that stderr was separated because stdout
was. It is `exact` only when the target is section 1 and there is nothing to
separate from.

## Part 3 — The shared position map

One layer translates a line of the materialized file to a line of the document,
covering the marker, the generated `end program`, and every hoisted declaration. It
is built while Studio generates the very content it describes, so it is **exact, not
inferential**.

```
map = { schema_version, marker_line, segments: [ {kind, c_start, c_end, delta} ] }
```

`studio_session.map_line(map, child_line)` returns:

| kind | `line` |
|---|---|
| `document` | a prefix line — its document line (delta 0 before the marker, −1 after) |
| `hoisted` | where that declaration really lives in the document |
| `marker` | 0 — no document counterpart |
| `generated` | 0 — the appended `end program` |
| `unmapped` | past the end of what Studio generated; passed through unchanged |

`sessions_map` probes it **directly**, not only through error attribution: one
materialization that produces all four segment kinds at once (marker + generated +
two hoisted declarations), with every child line of the result mapped and printed.

Attribution runs each diagnostic through the map before STU-3's byte ranges, and
gains a fourth verdict:

- `target` / `prefix` / `outside` — as STU-4, on real document positions
- **`generated`** — a line Studio itself produced. It has no document position, so
  none is invented: line and column are reported as 0.

A hoisted declaration is `prefix` when it is not the target: it is replayed context,
and that is the distinction the UI needs. `sessions_hoist_err` shows a raise inside a
hoisted helper reported by the child at line 5 and attributed to document line 12,
its real position.

## Part 4 — `--line-buffered`

Sessions now launch:

```
./gbasic --line-buffered --json-diagnostics <prefix>
```

PLAT-STREAM measured that a gBASIC child's stdout is block-buffered on a pipe, which
left STU-4's 50 ms poll loop with nothing to find. `sessions_stream` shows output
arriving **while the session state is still `running`**, and three existing goldens
changed to match: `stop`, `force` and `signal` now show the child's output where
they previously showed nothing, because a signalled process runs no stdio cleanup
and its buffered output simply died with it.

## Intentional golden changes

Every change below is a consequence of this phase. Any other change would be a
defect.

| golden | change | why |
|---|---|---|
| all `sessions_*` with a summary line | `split=X` → `split=out:X err:Y` | separation is per stream now |
| `clean`, `err_target`, `outside`, `edited` | `combined` → `marked`; output moves from `out_prefix` to `out_target` | the boundary marker separates them |
| `err_prefix` | `combined` + `split_reason=marker-absent` | the child dies in the prefix, so the marker never prints — correct, not an error |
| `stop`, `force`, `signal` | `out_target` now shows the child's output | `--line-buffered`: it reaches us before the kill instead of dying in the buffer |
| `sessions_gui` | target pane shows `5` instead of "(not separable…)" | same separation, through the UI |

`unresponsive`, `big` and `scratch` are byte-identical. All STU-0/1/2/3 goldens are
byte-identical.

## Tests

`tests/run_studio.sh`, headless tier, twelve new cases:

| case | proves |
|---|---|
| `hoist` | a helper defined after `end program`, section-run successfully |
| `hoist_before` | a helper defined before — nothing hoisted, behavior unchanged |
| `hoist_order` | several post-target declarations, source order preserved, each landing after the generated `end program` |
| `hoist_err` | an error inside a hoisted declaration mapping to its document position |
| `hoist_target` | a target that is itself a declaration — never hoisted into itself |
| `hoist_inert` | hoisting reorders no observable effect |
| `split` | separation succeeding with output on both sides |
| `split_nonce` | a user program printing the nonce → `combined`, `marker-ambiguous` |
| `split_die` | a child dying before the boundary → `combined`, `marker-absent` |
| `split_stderr` | stdout separated while stderr is reported unseparated |
| `map` | the position map probed directly across all four segment kinds |
| `stream` | output arriving during a run, not only at exit |

Scratch is asserted empty after every case, and the valgrind tier is unchanged.

## What this changes for STU-5

- **The STU-4 output-separation conflict is resolved** for the common case. STU-5's
  results view can show a real target/prefix split when `split_out=marked` — and must
  still handle `combined`, which is now a narrow, explained condition rather than the
  default.
- **stderr separation remains unsolved.** Doing it would need a marker in the
  diagnostic stream, which means either a second injected statement writing to
  stderr (there is no such builtin today) or a structural change to
  `--json-diagnostics`. Neither is in scope here.

  > **Update (PLAT-STDERR, 2026-07-28).** The first of those two routes now exists:
  > `print to error <expression>` writes to standard error and renders exactly what
  > `print` renders (`docs/reference.md`, Statements → "Print to standard error").
  > A future phase can inject a second marker statement at the same boundary to
  > separate stderr the same way stdout is separated here — the nonce, the
  > per-stream verdicts and the position map all already accommodate it, and
  > `split_err` already has `unavailable` as its honest current answer. Nothing in
  > Studio was changed for it; PLAT-STDERR built the capability only.
- **The append-only invariant is now stated more precisely.** Studio appends at the
  end (hoisted declarations, `end program`) and injects at exactly one boundary (the
  marker). What it never does is interleave content at more than that one point, or
  alter a byte of the document's own text — and every departure is recorded in the
  map, so no position is ever guessed.
- **Hoisting is bounded by the runtime's own rules.** If gBASIC ever pre-registers
  more (or less) than it does today, the hoisting rule must move with it; the
  condition is documented above precisely so that coupling is visible.

  > **Update (PLAT-GUARD, 2026-07-28).** That coupling is now enforced rather than
  > merely documented. `tests/run_pre_registration.sh` asserts the pre-registered
  > set both structurally (reading the `BEGIN/END PRE-REGISTRATION SET` markers in
  > `src/eval.c`) and behaviourally, and fails with a message naming this hoisting
  > rule as what must move with it. It is sited with the platform, next to the code
  > it describes, because that is the side that changes first.
