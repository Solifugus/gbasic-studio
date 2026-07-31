# gBASIC Studio — R2: execution architecture investigation

Status: **investigation only, nothing implemented.** Establishes, from the code, what
execution substrate STU-4 can actually stand on. Gate before STU-4 is specified, the
way `docs/source_outline_design.md` (R1) gated STU-3.

Companions: `docs/gbasic_execution_boundaries.md` (the boundary/replay spec — note that
its §8/§9 are tagged PROPOSED, not shipped), `docs/gbasic_studio_plan.md` (STU-4),
`PLAN.md` (Phases 3/4, deferred).

All `file:line` cites are against the tree at `fae2e85`. Claims marked **(probe)** were
tested empirically this session; the probes were throwaway scratch files, not repo code.

---

## Finding 0 — there is no Jupyter kernel

The task framed finding 1 as "the Jupyter kernel implementation." **No such component
exists in this repository**, and no partial or vestigial one exists either. This is
reported rather than worked around, because several downstream questions ("what does the
kernel hold between cells", "is it reachable from gBASIC") presuppose it.

What the search actually returns:

- `jupyter` appears in exactly four files, all prose, all as a *simile* for a desired
  feel: `docs/gbasic_studio_plan.md:51,520,665`, `docs/gbasic_studio_design.md:285,927,1059`,
  `docs/gbasic_studio_research.md:470`, and the (protected, untouched)
  `docs/future_library_ideas.md`. Every occurrence is of the form "Jupyter-style
  incremental execution" — an aspiration for STU-4, never a component.
- `kernel` matches three unrelated things: an OS-kernel comment about process death
  signalling (`src/eval.c:8773`), a socket-buffer comment (`src/actor.c:59`), and a
  Bartlett **kernel** in the statistics library (`stdlib/stats.bas:6871`).
- There is no ZMQ dependency, no message-protocol code, no `ipynb` handling, no cell
  concept anywhere in `src/`, `include/`, or the `Makefile` target list.

So the real question is what executes gBASIC source today, and the answer is: one
function, one shot.

**Entry point.** `main()` (`src/main.c:798`) reads the file, calls `gb_parse`
(`src/frontend.c:10` → `parse_source_reentrant`, `src/parser.y:1240`), then
`eval_program(program)` (`src/main.c:879`, declared `include/eval.h:6`, defined
`src/eval.c:21355`). `eval_program` picks the single `program` block if there is one,
pre-registers top-level functions/modifiers, and walks the statement list with
`eval_stmt_list` (`src/eval.c:21333`) — a linear `pc` walk that advances only after a
statement completes.

**Shape.** It is an **in-process library** (`libgbasic.a`) with a CLI on top. It is not a
separate process, and there is no protocol. The one process-shaped thing in the tree is
the actor runner (`gbasic --actor …`, `src/main.c:741-780`), covered in Finding 3 — and
it is not a kernel either.

**What holds state.** 76 file-scope mutables in `src/eval.c` (counted by pattern over
file-scope `static` declarations). The load-bearing ones: `global_env` (`:442`),
`current_env` (`:443`), `functions`/`function_count` (`:444-445`),
`modifiers` (`:446`), `locks` (`:448`), `watchers` (`:452`), `active_root` (`:481`),
`root_source_path` (`:482`), `loaded_files` (`:484`), `used_pairs` (`:486`), the module
tables (`webservers :501`, `gui_windows :541`), the actor tables (`root_mailbox :7805`,
`actor_children :7886`, `monitor_head :8197`), and the RNG (`:80-81`). `PLAN.md:580`
("Phase 3 — Interpreter context struct") describes collecting exactly these into a
`gb_interp` and is explicitly **deferred**, sequenced last, "largest effort; most
regression risk."

---

## Finding 1 — the evaluator can be re-invoked, but it destroys its state on the way out

This is the crux, and the answer is sharper than "no reusable context exists."

`eval_program` **can** be called repeatedly in one process. Its epilogue
(`src/eval.c:21430-21466`) then unconditionally tears everything down:

```
error_clear_state();  error_mode = ERROR_MODE_STOP;  runtime_stopped = 0;
actor_cleanup_children();  retain_clear();  monitor_clear();  lock_clear();
watcher_clear();  modifier_clear();  function_clear();  loaded_files_clear();
use_pairs_clear(&used_pairs, …);  use_pairs_clear(&use_stack, …);
gui_clear_native_windows();  webserver_clear();  …
env_clear(&global_env);       /* <-- the whole global environment */
active_root = ast_stmt_list_empty();
```

**(probe)** Linking `libgbasic.a` and calling `gb_parse` + `eval_program` three times:

```
[run1: set counter=41] exit=0
[run2: read counter]   runtime error at 1:1: undefined variable: counter   exit=1
[run3: liveness]       still alive                                          exit=0
```

Run 3 proves the interpreter is not left broken by a prior run — it is genuinely
re-entrant across calls. Run 2 proves state does not survive: `env_clear(&global_env)`
wiped it. So incremental execution against carried-over state is unavailable **not
because a context is missing, but because the only entry point is defined to end by
destroying the environment.**

Three further structural obstacles, independent of the teardown:

1. **No sub-range entry point.** `eval_program` takes a whole `AstStmtList`. Nothing in
   `include/eval.h` or `include/gbasic.h` accepts "statements *k*..*m*" or "this
   statement against that environment." Sections are statement runs, not functions, so
   even the actor path (which invokes a *named function*, Finding 3) cannot address them.
2. **AST ownership.** `function_register` stores pointers into the AST, and `main.c:885`
   calls `ast_free_program(program)` after `eval_program` returns. The teardown is what
   makes that safe; removing it would leave dangling function definitions.
3. **Embedder-hostile termination.** `with lock` installs SIGINT/SIGTERM/SIGHUP handlers
   (`lock_install_cleanup`, `src/eval.c:1881-1895`) whose handler `lock_cleanup_on_signal`
   (`:1866-1879`) ends in `_exit(128 + signal_number)` — it terminates the host process
   rather than unwinding. `PLAN.md:580` names converting these to context teardown as
   part of the deferred Phase 3.

**(probe)** Re-running the *same* parsed AST three times in one process is deterministic
and clean (`a=2; b=a*3; print b` → `6`, `6`, `6`, exit 0 each). Replay works today; it is
carry-over that does not.

---

## Finding 2 — what Studio can actually reach

Studio is written in gBASIC and runs as an ordinary gBASIC program. That single fact
decides most of this section.

**The C API is not reachable.** `gb_parse` (`include/gbasic.h`), `eval_program`
(`include/eval.h`), and `gb_set_active_sink` (`include/diagnostics.h:119`) are C
functions. `gb_set_active_sink` is genuinely public and a C embedder could use it — but
Studio cannot call any of them. There is no FFI-to-C from gBASIC, and there is **no
eval-of-string builtin**: the builtin registry (`src/builtins.c`, 152 names) has no
`eval`/`exec`/`compile`, and the only runtime call to `parse_source` is the library
loader `loaded_file_get` (`src/eval.c:4203`), which parses a **file** for `load`.

From gBASIC there are therefore exactly two ways to cause code to run:

**(a) `spawn NAME(args)` — actors.** A keyword expression (`src/parser.y:1015`,
`AST_EXPR_SPAWN`) that forks and execs `/proc/self/exe` (`actor_self_exe_path`,
`src/eval.c:8489`) with:

```c
char *child_argv[] = { exe, "--actor", entry, root_source_path,
                       "--actor-inbox", …, "--actor-self", …, "--actor-control", … };
```
(`src/eval.c:8712`)

Two consequences that constrain STU-4 hard:

- The child re-execs **`root_source_path` — the spawning program's own source file**
  (`src/eval.c:482, 8517, 8712`; set by `eval_set_source_path`, `:818`). When Studio
  spawns, the child is *another copy of Studio*. An actor is intra-program concurrency,
  **not a way to run a different program.**
- The entry must be a **named top-level function**: `eval_run_actor`
  (`src/eval.c:8790-8865`) registers declarations, then `find_top_level_function(entry)`
  and `invoke_function`. Sections are statement runs, not functions, so a section can
  never be an actor entry point.

**(b) `process.run(options)` — an arbitrary child process.** `process_do_run`
(`src/eval.c:~15133-15476`): `fork` + `execvp` with a literal argv (no shell), captured
stdout/stderr, `{exit_code, stdout, stderr, success, signal, timed_out}`
(`src/eval.c:15183`), optional `timeout` that `SIGKILL`s the child's process group
(`:15235`). Documented as **blocking** (`docs/reference.md:1634`).

**So STU-4 spawns a process, and the process is `./gbasic` on a file.** The isolation
boundary is an **OS process boundary**, and it is total: the child gets a fresh
interpreter with its own 76 globals, sharing only the pipes and the filesystem. Studio
owns the parent side (it decides what to write, what to launch, when to give up); the
child owns everything about the execution.

Non-blocking composition already exists and is documented: run `process.run` **inside a
spawned actor** and deliver the result to the GTK loop via `gi.watch_mailbox`
(`src/eval.c:15111`, `gi_do_watch_mailbox`) — `docs/reference.md:1636-1638`, proven in
NAP-3's `loop_responsive` case. Note this composes the two mechanisms honestly: the actor
is Studio's own code (a), and it shells out to the user's program (b).

One practical corollary: the child reads source **from disk**. Studio's unsaved editor
buffer is therefore irrelevant to execution — Studio must materialize what it wants run
into a file regardless. That turns a would-be limitation into a non-issue, since a
prefix has to be materialized anyway.

---

## Finding 3 — interruption and restart

**Restart: yes, trivially.** Launch another process.

**Interrupt: no. There is no mechanism today.**

- **No cooperative cancel.** `eval_stmt_list` (`src/eval.c:21333`) checks only
  `did_goto` / `did_return` / `did_gosub` / `did_stop` / `did_break` / `did_continue`.
  There is no interrupt flag, no deadline check, no callback hook in the statement walk.
  `runtime_stopped` (`:476`) is set only by `runtime_error_raise` (`:1281`) — it is an
  error state, not an external control.
- **Signals terminate rather than unwind**, and are only installed at all if the program
  used `with lock` (`src/eval.c:1881-1895`); the handler `_exit`s (`:1866-1879`).
  Otherwise the default disposition applies: SIGINT/SIGTERM kill the process.
- **`process.run` cannot be cancelled.** It is synchronous; the caller is inside the
  call. Its `timeout` (`src/eval.c:15203, 15235`) SIGKILLs the child group — that is
  *bounded execution*, decided before the run starts, not user-initiated interruption.
- **Actors have no kill.** The actor surface is `self`, `send`, `receive`, `monitor`,
  `demonitor` (`src/builtins.c:80-84`; dispatch `src/eval.c:18002-18110`) plus the
  `spawn` keyword. There is no `kill`/`stop`/`terminate`. Children are killed only at
  program teardown: `actor_cleanup_children` → `kill(-actor_group_pgid, SIGTERM)`
  (`src/eval.c:7963`), and `PR_SET_PDEATHSIG, SIGTERM` (`:8778`) ensures children die
  with the parent.

**Does it survive the boundary in Finding 2?** The boundary is exactly where interruption
*would* work — killing a child process is the natural implementation, and the machinery
(process groups, PDEATHSIG) is already there. What is missing is a gBASIC-reachable way
to name a live child and signal it. `process.run` never yields a handle (it returns only
after the child is gone), and actor handles carry no kill operation. So the capability is
one small platform surface away, but it is **not present**. See Blockers.

---

## Finding 4 — output and error capture

**`print` writes straight to `stdout`.** `AST_STMT_PRINT` (`src/eval.c:20977`) calls
`value_print`, which does `fwrite(…, stdout)` (`value_print` `src/eval.c:1621`, the write at `:1636`). There is no output
sink, no indirection, and no redirect builtin — `dup2` appears in `eval.c` exactly once,
inside `process.run`'s child (`:15384`).

**Actor output is not capturable.** The spawn child closes only descriptors from 3 up:

```c
for (int fd = 3; fd < (int)maxfd; fd++) { … close(fd); }
```
(`src/eval.c:8687`)

fds 0/1/2 are inherited untouched, so a spawned actor's `print` lands on **Studio's own
stdout**. This is why an actor cannot be the capturing runner.

**`process.run` is the capture mechanism**, and it is a good one: binary-safe stdout and
stderr, exit code, signal, `timed_out` (`src/eval.c:15176-15183`), with `poll()`-based
dual capture so neither pipe can deadlock.

**Returned values do not cross a process.** A process yields an `int` status. Values come
back only by being printed, or by an actor `send` of a serialized value — and
serialization is per-**value**, never per-environment (Finding 5).

**Diagnostics are structured and reachable — via the CLI, not the library.** The
`gb_diagnostics` sink is C-only (`main.c:878` brackets `eval_program` with
`gb_set_active_sink`). Studio reaches it through the `--json-diagnostics` flag, which
emits JSON on stderr for **runtime** errors as well as parse errors.

**(probe)** `./gbasic --json-diagnostics` on `x=1 / print x / y = x/0 / print "after"`:

```
stdout: 1
stderr: {"severity":"error","code":"GB_DIAG_RUNTIME_ERROR","subcode":1002,
         "path":"…/rt.bas","start":{"line":3,"column":7},"end":{"line":3,"column":7},
         "message":"division by zero"}
exit:   1
```

Output produced before the error is preserved, and the error carries exact 1-based
line/column — directly mappable back to a section through STU-3's ranges. This is
sufficient for STU-4 and it is already structured; nothing needs to be built to get it.

---

## Finding 5 — replay-first: cost, checkpoints, and the side-effect problem

### Cost profile

Running section *N* means executing sections 1..*N*. Walking a document of *N* sections
once, running each in turn, costs `Σ(k=1..N) cost(1..k)` — quadratic in the number of
sections against a linear amount of user-visible progress. The constant matters more than
the exponent for realistic *N*: each replay also pays a fresh `fork`+`exec`, a file read,
and a full re-parse. PLAT-OUTLINE measured in-process parse of a 40k-line file at ~87ms,
so parse is not free but is small beside typical program work; the dominant term is
re-executing whatever the prefix actually does. **(probe)** In-process replay of an
identical AST is deterministic and immediate for pure code.

### What a checkpoint would be

**There is no whole-environment serializer.** `serialize`/`deserialize`
(`src/eval.c:17976-18000` dispatch; `serialize_value` `:7313-7467`) are strictly
per-**value**.

A checkpoint is nevertheless **constructible in gBASIC today**, from three existing
pieces: `reflect.variables()` (`reflect_do_variables`, `src/eval.c:15581`) returns the
current frame's own names — at top level, the global frame; `reflect.get(name)` fetches
each; `reflect.serializable(v)` predicts whether `serialize` will accept it.

**(probe)** A program with six globals enumerated them, confirmed all six serializable,
serialized a record of them to 166 bytes, and round-tripped it back correctly.

Two constraints bound this sharply:

1. **Own-frame only.** The implementation comment is explicit
   (`src/eval.c:15576-15580`): v1 reflects `current_env`'s own frame; "enclosing/parent
   frames and paused frames are deferred to the interpreter-context refactor."
2. **It runs inside the executing program.** Studio, in a different process, cannot reach
   into the child's environment. A checkpoint would have to be an **epilogue appended to
   the prefix Studio runs** — i.e. Studio-injected code, not an inspection facility.

And it can only ever hold the serializable subset (below).

### The side-effect problem, concretely

`serialize_value` rejects live handles outright: database/XML readers
(`src/eval.c:7393`), GObjects (`:7397`), boxed values (`:7401`), actor handles (`:7449`).
**(probe)** `reflect.serializable(sqlite.connect(":memory:"))` → `false`;
`reflect.serializable(now())` → `true`. Files and directories serialize as **paths only**
(`src/eval.c:~7382`) — a name to reopen, not a handle or a file position.

What actually breaks when a prefix is re-executed:

| Effect | What replay does |
|---|---|
| **Filesystem** | `write` truncates and rewrites (roughly idempotent); **append duplicates content every replay**; `make_dir`/`remove`/`atomic_replace` re-run and are order-dependent |
| **Network** | `webclient` re-issues every request. A non-idempotent POST is performed again — charged twice, sent twice. Not rewindable by any mechanism in this tree |
| **Databases** | `sqlite.exec`/`pg.exec` re-run. Every `insert` in the prefix inserts again unless a constraint stops it |
| **GUI** | `gi`/`gtk` calls re-create widgets; a prefix that opened a window opens one **per replay** |
| **Actors** | `spawn` in a replayed prefix starts a **new child each time**. PDEATHSIG reaps them at process exit, but they coexist during the run |
| **Webserver** | `eval_program` calls `webserver_run_event_loop()` after the body whenever a server is active (`src/eval.c:21426`). A prefix that starts a server **never returns** — replay hangs until a timeout kills it |
| **Locks** | `with lock` re-acquires, and installs the `_exit` signal handlers of Finding 1 |
| **RNG** | `gbasic_rng_autoseed` (`src/eval.c:106-115`) draws from `/dev/urandom` when `seed()` was never called — **replay produces different random values** |
| **Clock / env** | `now()`, `epoch()`, `env()` differ between replays by construction |

So replay is faithful **only for the pure, deterministic subset**, and the runtime offers
no help identifying that subset: `docs/gbasic_execution_boundaries.md` §9 proposes an
effect classification (Pure / Capturable / Ext-read / Ext-effect), but it is tagged
PROPOSED and **nothing in `eval.c` classifies effects today**. Any such policy would be
Studio-authored, and would be a heuristic over source text rather than a runtime fact.

---

## Finding 6 — what STU-4 would add versus reuse

**Reuse (exists today, no C changes):**

- The entire interpreter, as a process: `./gbasic <file>`.
- `process.run` capture: stdout, stderr, exit code, signal, `timed_out`, bounded by
  `timeout`.
- `--json-diagnostics` for structured parse **and runtime** errors with exact positions.
- `spawn` + `gi.watch_mailbox` to keep the GTK loop responsive around a blocking run.
- `serialize`/`deserialize` and `reflect.*` if checkpointing is later wanted.
- STU-3's byte ranges to slice a prefix exactly, and `studio_store.write_atomic` to
  materialize it crash-safely.

**Add (Studio-side gBASIC only):** prefix materialization from STU-3 ranges; a runner
actor and a result message shape; mapping `--json-diagnostics` positions back to section
ids; a run-state model per document; if wanted later, checkpoint-epilogue injection and
whatever effect *policy* Studio decides to adopt, since the runtime has none.

**Not reachable without new C:** in-process incremental execution against carried-over
state; interrupting a running section; capturing an actor's stdout; a whole-environment
snapshot; any runtime effect classification.

---

## Conclusion

**B.**

No reusable evaluation context exists, and none is reachable from Studio. Section
execution must be **replay-first**: running section *N* means executing sections 1..*N*
(or from a checkpoint) in a fresh process.

The finding is worth stating precisely, because "no reusable context" understates it in
one direction and overstates it in another:

- `eval_program` **is** re-invocable in one process, and replaying the same AST is
  deterministic **(probe)**. The machinery is not fragile.
- But it **defines itself to end with `env_clear(&global_env)`** plus a full teardown of
  functions, modifiers, loads, module tables and actor children
  (`src/eval.c:21430-21466`), so nothing carries over **(probe: `counter` set in run 1 is
  undefined in run 2)**.
- And Studio, being gBASIC, cannot call `eval_program` at all. Its only levers are
  `spawn` (which re-execs *Studio's own source*) and `process.run` (which runs an
  arbitrary command). For Studio the question is settled before the C-level question even
  arises.

Answer A is false today and is not reachable with bounded work: it is `PLAN.md`'s
deferred Phase 3 (`PLAN.md:580`), described there as the largest effort and highest
regression risk, and it would additionally require a gBASIC-reachable API that does not
exist. Per the task, no recommendation to build it is made here.

---

## Recommended STU-4 execution architecture

Substrate only — no replay/branching UX, no results model, no STU-5/6 concerns.

1. **Unit of execution: a materialized prefix file.** Take the document's bytes from the
   start of section 1 through the end of section *N* using STU-3's half-open byte ranges,
   and write them to Studio's scratch area with `studio_store.write_atomic`. This
   sidesteps unsaved buffers entirely (the child reads from disk regardless, Finding 2)
   and needs no new parsing.

2. **Runner: `process.run("./gbasic", ["--json-diagnostics", <prefix>], {timeout})`,
   executed inside a spawned actor**, with the result delivered to the GTK loop through
   `gi.watch_mailbox`. This is the documented, NAP-3-proven pattern
   (`docs/reference.md:1636-1638`) and the only way to run user code without blocking
   Studio's UI.

3. **Isolation boundary: the OS process, owned by Studio's parent side.** Studio never
   shares an interpreter with user code. A user program that crashes, loops, `_exit`s
   from a lock signal handler, opens GTK windows, or starts a webserver cannot damage
   Studio — the worst case is a child that outlives its usefulness and is reaped by the
   timeout.

4. **Capture: `process.run`'s stdout/stderr, plus the JSON diagnostic stream.** Errors
   arrive structured, with 1-based line/column that STU-3's ranges map back to a section
   id.

5. **State: none carried between runs.** Every run is a fresh process from the prefix
   start. Checkpointing is a strictly later, opt-in refinement, viable only for the
   serializable subset and only as a Studio-injected epilogue (Finding 5).

This is the replay-first ladder the design docs already anticipated
(`docs/gbasic_studio_design.md` §8.2, `docs/gbasic_execution_boundaries.md` §8.1) — the
value of this investigation is that it is now known to be what the code supports, rather
than assumed.

---

## Open questions this investigation could not settle

1. **Per-section output attribution.** `process.run` returns one stdout blob for the
   whole prefix, and nothing in the runtime marks which section emitted which bytes.
   Differencing prefix *N* against prefix *N−1* only works if runs are deterministic,
   which Finding 5 shows they often are not. Injecting sentinel prints between sections
   would work mechanically but alters the user's program text; whether that is acceptable
   was not evaluated.
2. **Real cost at scale.** Nothing here measures prefix re-execution on an actual
   project. The only hard numbers are PLAT-OUTLINE's ~87ms parse for a 40k-line file and
   the observation that pure in-process replay is immediate.
3. **Which interpreter binary to launch.** Actors use `/proc/self/exe`; `process.run`
   takes whatever argv it is given. Whether Studio should launch its own binary, a PATH
   `gbasic`, or an installed one is a decision, not a finding.
4. **Prefix cuts and `load`.** `load`/`use` are documented as idempotent and
   declaration-only (`docs/gbasic_execution_boundaries.md` §2.7), but a prefix that cuts
   between a `load` and its first use was not tested.
5. **Distinguishing "slow" from "hung"**, and what a sane default `timeout` is. There is
   no progress signal from a running child.

---

## Platform blockers

Named, not scoped, per the task.

**BLOCKER — there is no way to interrupt a running section.** This is genuine and it is
the only one. `process.run` is synchronous and yields no handle to a live child; its
`timeout` is a bound set before the run, not a control during it. Actors expose no
`kill`/`stop`. The only signal handlers in the tree `_exit` the process and are installed
only by `with lock`. Consequently STU-4, built on today's platform, can offer *bounded*
execution but **cannot offer a stop button** — a user who runs a prefix containing an
infinite loop, a blocking read, or a webserver (`src/eval.c:21426`, which never returns)
waits for the timeout or restarts Studio. Whether STU-4 ships with timeout-only bounding,
or a platform phase precedes it, is Matthew's call; this document does not scope one.

Two things that are **not** blockers, recorded so they are not mistaken for one:

- *Actor stdout is not capturable* (Finding 4). Real, but it only forces `process.run` to
  be the runner — which is the recommended architecture anyway.
- *Studio cannot execute an unsaved buffer directly.* Moot: a prefix must be materialized
  to a file regardless, so the buffer never needed to be executed in place.

---

## Amendment — 2026-07-28

The findings above stand unchanged. Two things have since happened that change what
follows from them; both are recorded here rather than edited into the text, so the
investigation stays readable as of its own date.

**1. The named blocker is resolved.** PLAT-PROC (`452bb4b`, `803bfd1`) added live
child control — `process.start` / `poll` / `read` / `wait` / `stop` / `release`.
Studio can now stop a running child, escalate to SIGKILL as a separate explicit
action, and read output as it arrives. The "cannot offer a stop button" conclusion
no longer holds.

**2. The actor is no longer needed to keep the GTK loop alive.** §Recommended STU-4
execution architecture, item 2, prescribed running `process.run` *inside a spawned
actor* with the result delivered via `gi.watch_mailbox` — solely because
`process.run` blocks. `process.start`, `poll` and `read` do not block, so STU-4
drives the child **directly from a GTK timeout callback** and the loop stays free.
No `spawn`, no mailbox, no serialization round-trip in the execution path. That is
what STU-4 implements; everything else in the recommended architecture (byte-prefix
materialization from STU-3 ranges, `--json-diagnostics` for structured errors, the
OS process as the isolation boundary, no state carried between runs) is unchanged.

STU-4 also produced two measurements worth carrying forward, both in
`docs/gbasic_studio_stu4.md`: a gBASIC child's stdout is **block-buffered** on a
pipe (so short output does not stream until the child exits, regardless of how the
parent polls), and the process handle exposes no descriptor, so an event-driven
`gi.watch_fd` alternative to the timer is not reachable today — and would not help
while the buffering dominates.
