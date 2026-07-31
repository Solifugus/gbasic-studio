# gBASIC Studio — STU-4 reference (execution sessions)

Status: **implemented.** Documents what STU-4 adds on top of STU-0 (backbone),
STU-1 (navigation), STU-2 (documents/editor) and STU-3 (sections): an **execution
session** that runs a section by replaying the prefix above it in a fresh child
interpreter, driven live from the GTK loop. No results persistence, no inspection,
no checkpoints, no branching (later phases).

STU-4 is **additive**: STU-0/1/2/3 stores, lifecycle and goldens are unchanged.

## Ownership direction

```
Platform  process.start/poll/read/stop/release   ' owns the CHILD PROCESS
        v
Studio    studio_session.bas                     ' owns the SESSION (state, prefix, attribution)
        v
Shell     run bar + output pane, gi.timeout      ' owns nothing; drives ticks and renders
```

The session is a plain record. It holds the live process handle, but every decision —
whether to run, what to materialize, when a stop has become unresponsive, which
section an error belongs to — is Studio's.

## The state machine

Eight states, all explicit. There is no "is_running" boolean anywhere; `is_active`
is derived from the state, never stored.

| State | Meaning |
|---|---|
| `idle` | nothing has run yet |
| `materializing` | writing the prefix file |
| `running` | child launched, being polled |
| `stopping` | SIGTERM sent, waiting for the child to go |
| `unresponsive` | SIGTERM sent, the grace window elapsed, child still alive |
| `finished` | the child exited — on its own or after a stop |
| `failed` | the run could not proceed (materialize or launch error) |
| `refused` | Studio declined to start (see Refusing to run) |

Transitions, each exercised by a golden:

```
idle|finished|failed|refused -> materializing    run requested and permitted
idle|finished|failed|refused -> refused          run requested and refused
materializing -> running                         child launched
materializing -> failed                          write or launch error
running -> running                               tick with the child alive
running -> finished                              child exited
running -> stopping                              stop requested
stopping -> finished                             child died
stopping -> unresponsive                         grace elapsed, still alive
unresponsive -> finished                         force stop killed it
running|stopping|unresponsive -> … -> materializing   restart, after the stop completes
```

Every move goes through one helper that appends `from>to` to `session.transitions`,
so the transition log in the goldens is the machine's actual history rather than a
narration of it. `sessions_unresponsive` is the interesting one:

```
idle>materializing materializing>running running>stopping stopping>unresponsive unresponsive>finished
```

## Concurrency

**A session belongs to one document, and different documents run concurrently.**
Studio-wide single-run was offered as an acceptable simplification; it was not
needed. A session is a self-contained record holding its own handle, buffers and
state — there is no shared mutable structure to contend for, so N sessions ticking
from one timer is the same code as one. Enforcing a global single-run would have
meant *adding* a coordinator, not removing one.

Within a document, at most one run is active: `run` refuses outright while
`is_active`, and `restart` completes the stop before starting again.

## Prefix materialization

Running section N materializes **the literal byte prefix of the document**,
`source[0, section_N.end_offset)`, written with `studio_store.write_text_atomic`
into a Studio-owned scratch directory.

That choice is the whole error-attribution mechanism. Because the file is a literal
prefix, **line 12 of the child's file is line 12 of the document** — so the 1-based
positions `--json-diagnostics` reports map straight back through STU-3's byte ranges
with no compensation arithmetic anywhere.

**APPEND ONLY.** Nothing is ever inserted between or inside sections, and there are
no sentinel markers. Two appends are permitted, both strictly at the end, neither
shifting a line of the prefix:

- a **trailing newline**, because STU-3's ranges are terminator-inclusive but
  newline-exclusive, so the raw prefix ends immediately after a terminator;
- **`end program`**, when the target section lives inside a `program` block — STU-3
  records that as ancestry `program:NAME` — because a byte prefix of such a document
  cuts the block open. `sessions_prog` shows a three-section program body truncated
  after its first section and closed by the append.

Materialization reads the document's **in-memory content**. Running does not save;
what executes is what is in the editor.

The slice itself is taken by binary search over `mid` (which counts codepoints)
using `byte_count` as the oracle — O(log n) C-level slices. The obvious
`byte_at`-in-a-loop is O(n²) in gBASIC, because `append` copies the array every call.

### Known limitation: declarations below the cut

A byte prefix cannot include a function declared *after* the target section. The
interpreter pre-registers every top-level function before running a `program` block,
so a document whose body calls a helper defined below `end program` runs normally but
will fail under a truncated prefix. STU-4 does not work around this; appending those
declarations would give them line numbers that no longer match the document, which
would break attribution for errors inside them. Recorded for STU-5.

> **RESOLVED in STU-4B** (`docs/gbasic_studio_stu4b.md`). Post-target top-level
> declarations are appended after the prefix, and a position map — built from the
> content Studio generated, so exact rather than inferred — translates their lines
> back to the document, which is what makes attribution survive the move.

## Running

`process.start("./gbasic", ["--json-diagnostics", <prefix path>])`, with **no
timeout**. The user has a stop button; a bound set in advance is not a substitute for
control.

The child is driven from a **GTK timeout at 50 ms**. The interval was chosen as the
largest one that is still imperceptible: at 20 services/second, output and state
changes appear instant, while the per-tick cost is two non-blocking `read`s and one
`waitpid(WNOHANG)` — microseconds. Going faster buys nothing observable (see the
buffering finding below, which dominates latency by orders of magnitude); going
slower starts to feel like lag on state changes. The tick is disarmed the moment the
session leaves an active state, so an idle Studio does no work.

### Finding: could a watchable fd replace the timer?

**Not today, and it would not help.**

`gi.watch_fd(fd, fn)` exists and takes a *numeric* descriptor
(`src/eval.c:14789`), so an event-driven design is expressible in principle. But
`process.start` returns an opaque `VALUE_PROCESS`; nothing in the PLAT-PROC surface
exposes the read ends, or even the pid — the status record is
`{running, exit_code, signal, success}` and the chunk record is `{stdout, stderr}`.
So the fd is unreachable from gBASIC.

Exposing it would need more than an accessor. The handle **owns** those descriptors
and closes them at EOF and on release, so a raw fd handed to gBASIC could be watched
after it was closed — and reused by an unrelated `open`. Two watches would be needed
(stdout and stderr). Neither `poll` nor `read` would become unnecessary, since exit
still has to be reaped. And a GSource on a closed fd is exactly the kind of thing
that trips `G_DEBUG=fatal-criticals`.

More decisively: **it would not improve anything measurable**, because the child's
own buffering, not the parent's polling strategy, sets the latency —

### Finding: a gBASIC child's stdout is block-buffered on a pipe

Measured directly. A child that prints, sleeps 2 seconds, then prints again:

| Child | First bytes observed while the child was still running? |
|---|---|
| `./gbasic` (prints, sleeps 2s, prints) | **no** — nothing arrived until it exited |
| `sh -c "printf …; sleep 2; printf …"` | **yes** |

`value_print` writes to `stdout` through ordinary stdio (`src/eval.c:1621`), which
is fully buffered when the destination is a pipe. So a gBASIC child's short output
does not stream at all; it appears in one burst at exit. Longer output does stream —
`sessions_big` moves ~155 KB and flushes progressively once the ~4 KB buffer fills.

This is why an fd watch would change nothing: there is nothing on the pipe to wake
up on. Making a gBASIC child line-buffered would be a runtime change (a `setvbuf`,
or flushing after each top-level statement), out of scope here and noted for STU-5.

## Output capture

`{out_prefix, out_target, err_prefix, err_target, split}`, in memory only.

**The prefix/target split is exact only when the target is the first section**, and
this is a genuine conflict in the phase's own requirements rather than an
implementation shortcut:

- one child produces **one** stdout stream for sections 1..N;
- splitting it at the N-1/N boundary requires a marker at that boundary;
- the APPEND-ONLY invariant forbids exactly that ("No sentinel markers between
  sections"), for the good reason that it would desynchronize line numbers.

So `split` records which case applies:

| `split` | When | Behavior |
|---|---|---|
| `exact` | target is section 1 — there is no prefix | all output is the target's |
| `combined` | target is a later section | the stream is reported under `prefix`, and the pane says it is not separable |

Everything is always shown. Nothing is discarded, and nothing is claimed to be the
target's that might not be — which is the animating requirement (prefix output is the
only way a user can see that a replay re-issued the prefix's side effects).

Options this leaves open to STU-5, none built here: a runtime facility that reports
the executed statement index alongside output; permitting a marker plus explicit
line-offset compensation; or a session-scoped baseline (the byte length of the
immediately preceding run of sections 1..N-1 at the same document revision), which
needs no extra execution but only works when the user ran N-1 first and the prefix is
deterministic.

> **RESOLVED in STU-4B for stdout** (`docs/gbasic_studio_stu4b.md`), by the second
> of those options: a per-run nonce marker injected at the one boundary, with a
> single line offset carried in the position map. `split` became per-stream
> (`split_out` / `split_err`) with values `exact` / `marked` / `combined`, because
> the marker is a `print` and therefore **stderr is still not separable** when a
> prefix exists. `combined` survives as the honest answer when the marker appears
> zero times or more than once.

## Error attribution

The child's stderr is split into structured diagnostics and plain text: with
`--json-diagnostics` each diagnostic is one JSON object per line, but the child's own
stderr writes land there too, so every line is validated with `studio_json.valid`
before `decode` (a raise cannot be caught from a library).

Each diagnostic's 1-based line/column goes through
`studio_sections.offset_of` → `studio_sections.section_at` to a section id, then:

| `where` | Meaning | Golden |
|---|---|---|
| `target` | the error is in the section the user ran | `sessions_err_target` |
| `prefix` | the error is in a replayed earlier section | `sessions_err_prefix` |
| `outside` | the position is in no section — a gap, or the appended `end program` | `sessions_outside` |

A child that **dies by signal with no diagnostic at all** is handled by the status
path alone: `sessions_signal` runs a document that kills its own interpreter from a
grandchild (`sh -c "kill -TERM $PPID"`) and finishes with `signal=15`,
`exit_code=-1`, `diagnostics=0` — no attribution, no crash, no hang.

## Stopping and restarting

- `studio_session.request_stop` sends **SIGTERM and nothing else**. (It is not named
  `stop` because `stop` is a gBASIC keyword.)
- If the child is still alive after `stop_grace_ticks` (default 20 ≈ 1 s at the 50 ms
  cadence), the session moves to **`unresponsive`** — a distinct state, never a hang.
- `studio_session.force_stop(session, grace)` is the **separate explicit escalation**:
  SIGTERM, bounded grace, then SIGKILL. It is never an automatic follow-up.
- `restart` completes the stop before starting again, so two runs of one session can
  never overlap.

`sessions_unresponsive` uses a child that genuinely traps and ignores SIGTERM. A
gBASIC child always dies on SIGTERM (it installs no handler unless `with lock` is
used, and that one `_exit`s), so the session's `interpreter` field — substitutable by
design — points at a helper that really refuses.

## Refusing to run

Refusal is checked **before** anything touches the filesystem, and carries a code the
UI can map plus fallback text:

| Reason | When |
|---|---|
| `source-invalid` | the document does not parse |
| `section-ambiguous` | the target section is ambiguous (STU-3) |
| `section-stale` | the target is stale, or its id is in `stale_ids` |
| `section-missing` | no such section in the current source |

Last-known-good sections exist so the **UI** stays coherent mid-edit, not so stale
code can be executed. Running against source that no longer parses would execute a
file whose bytes do not match the sections Studio is reasoning about, so it is
refused outright.

## Determinism

**Replay is not reproducible, and STU-4 does not present it as such.** No seed is
forced.

### Finding: a seed mechanism does exist

`seed(n)` is a builtin (`src/eval.c:19041`) that sets the PRNG state and returns the
seed; without it, `random` autoseeds from `/dev/urandom` (`src/eval.c:106-115`), so
replays of an unseeded program diverge.

Forcing a per-session seed would therefore be *mechanically* easy — but it is the
wrong trade, for three reasons:

1. **It cannot be done without violating the append-only invariant.** A `seed(n)`
   call would have to be *prepended* to the materialized prefix, shifting every line
   by one and breaking the attribution that the whole materialization design exists
   to preserve.
2. **It would make replay look reproducible when it is not.** The RNG is one
   nondeterminism source among many: `now()`, `epoch()`, `env()`, filesystem state,
   network responses, and anything the prefix's own side effects changed. Pinning the
   easy one buys a false impression of the hard ones.
3. **It would silently change the program's meaning.** A user who calls `seed()`
   themselves would have it overwritten or fought over, and a user who deliberately
   wants fresh randomness per run would stop getting it.

Finding only; nothing built.

## Scratch lifecycle

Materialized prefixes live in a Studio-owned scratch directory (`<home>/scratch`),
never in the project tree, named `run-<doc_id>-<seq>.bas`.

- The file is deleted when the run reaches `finished` — the child parsed it at
  startup, so removing it cannot disturb anything.
- `studio_session.sweep_scratch(dir)` removes everything left in the directory and
  returns the count. Studio calls it at launch, so a **crashed** Studio's orphaned
  prefix is collected on the next start rather than accumulating forever.

`sessions_scratch` proves both: zero files after a completed run, and two planted
orphans swept. Every other headless case additionally asserts an empty scratch
directory afterwards, and the runner fails loudly if any case leaves one behind.

## UI (display)

Minimal by design: a **Run Section** action for the section at the cursor, **Stop**,
**Force Stop**, a session-state line, and an output pane with separately labelled
prefix and target regions. No results history, no inspector, no gutter decoration.

`sessions_gui` (SKIPs without GTK 4 or a display) builds the real shell, resolves the
section under the document's cursor, starts a run, and drives it to completion from a
`gi.timeout` — no actor, no mailbox — under `G_DEBUG=fatal-criticals`.

## Tests

`tests/run_studio.sh`, driver `examples/studio/sessions.bas`, one mode per scenario:

| Case | What it pins |
|---|---|
| `clean` | a full run; section 1 `exact`, a later section `combined` |
| `err_target` | runtime error attributed to the target section |
| `err_prefix` | runtime error attributed to a replayed prefix section |
| `outside` | a diagnostic whose position is in no section at all |
| `prog` | truncating a `program` block and appending `end program` |
| `stop` | polite stop; child dies on SIGTERM (signal 15) |
| `force` | explicit escalation |
| `unresponsive` | a SIGTERM-ignoring child becomes a STATE, then is forced (signal 9) |
| `restart` | restart mid-run; the stop completes first, runs never overlap |
| `refuse` | all three refusals: unparseable source, ambiguous, stale |
| `signal` | child killed by signal, no diagnostic at all |
| `big` | ~155 KB of output, past a pipe buffer, no deadlock |
| `edited` | document edited between runs; the materialized prefix differs |
| `scratch` | files cleaned after a run; orphans swept |
| `sessions_memory` | valgrind over run/stop/attribute, including the kill paths |
| `sessions_gui` | GTK shell + timeout-driven run (SKIPs headless) |

## What this changes for STU-5

> All three items below were taken up by **STU-4B** and **PLAT-STREAM**; see
> `docs/gbasic_studio_stu4b.md` for what is resolved and what is not. Left as
> written, because they are what STU-4 concluded.

- **Output separation** is the open design question, not a detail. STU-5 should
  decide between a runtime statement-index facility, compensated markers, or the
  session-scoped baseline described above.
- **Child buffering** must be addressed before "live output" is a credible feature:
  today a short-running section shows nothing until it exits.
- **Declarations below the cut** (above) limit which documents can be prefix-run.
- The session record is the natural place for STU-5's results/history to hang, but it
  currently keeps output **in memory only** and drops it on the next run.
