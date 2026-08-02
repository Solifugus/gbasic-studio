#!/usr/bin/env bash
# gBASIC Studio — STU-0 backbone suite (docs/gbasic_studio_plan.md, STU-0).
#
# Exercises the persistent BACKBONE only (project/session/settings model +
# versioned atomic persistence + startup/shutdown lifecycle). It is entirely
# headless and GI-independent: the studio_* stdlib libraries are pure gBASIC over
# the filesystem/JSON builtins, so this suite must run and be verified even on
# hosts without a display or GTK typelibs. The GTK shell (display-only) is covered
# by run_gui_parse.sh (parse) and a manual checklist in docs/harness_notes.md.
#
# Determinism: the app's summary output is PATH-FREE (ids are counter-minted, no
# timestamps, temp home never printed), so stdout is byte-stable against goldens
# regardless of the throwaway home directory each case runs in.
set -euo pipefail

cd "$(dirname "$0")/.."

# gBASIC lives in its own project. Both of these are overridable, and both
# default to a sibling checkout so `make`-fresh interpreter changes are what get
# tested; an installed gbasic works too once `make install` has been run there.
GBASIC="${GBASIC:-../gbasic/gbasic}"
export GBASIC
GBASIC_STDLIB="${GBASIC_STDLIB:-../gbasic/stdlib}"
if [ ! -x "$GBASIC" ]; then
    printf 'FAIL run_studio: no gbasic interpreter at %s\n' "$GBASIC"
    printf '  set GBASIC=/path/to/gbasic (and GBASIC_STDLIB=/path/to/stdlib)\n'
    exit 1
fi
if [ ! -d "$GBASIC_STDLIB" ]; then
    printf 'FAIL run_studio: no gBASIC stdlib at %s\n' "$GBASIC_STDLIB"
    printf '  Studio needs persist, filetree, gtk, sourceeditor and gi from it\n'
    exit 1
fi

# Build the interpreter if GBASIC points into a source tree, so a change over
# there is what gets tested rather than a stale binary. An installed gbasic has
# no Makefile beside it and is used as-is.
gbasic_dir="$(cd "$(dirname "$GBASIC")" && pwd)"
if [ -f "$gbasic_dir/Makefile" ]; then
    if ! (cd "$gbasic_dir" && make >/dev/null); then
        printf 'FAIL run_studio: gbasic build failed in %s\n' "$gbasic_dir"
        exit 1
    fi
fi

export GBASIC_PATH="lib:$GBASIC_STDLIB"
APP=app/studio.bas

tmproot="$(mktemp -d)"
stdout_file="$(mktemp)"
trap 'rm -rf "$tmproot" "$stdout_file"' EXIT

fail() { printf 'FAIL %s\n' "$1"; exit 1; }

mkproj() { # dir — a deterministic project tree for the browser cases
    local d="$1"
    mkdir -p "$d/src" "$d/docs"
    printf x > "$d/main.bas"; printf x > "$d/README.md"
    printf x > "$d/src/a.bas"; printf x > "$d/src/b.bas"; printf x > "$d/docs/guide.md"
}

mkproj_ui() { # dir — the STU-2B interaction fixture: a nested tree with two
              # files at the top level, so a click can open one, expand a
              # directory, and open one from inside it.
    local d="$1"
    mkdir -p "$d/src" "$d/docs"
    printf 'print "main"\n' > "$d/main.bas"
    printf '# readme\n'     > "$d/README.md"
    printf 'x\n'            > "$d/src/a.bas"
    printf 'y\n'            > "$d/src/b.bas"
    printf 'z\n'            > "$d/docs/guide.md"
}

mkproj2() { # dir — deterministic source files for the document cases
    local d="$1"
    mkdir -p "$d/sub"
    printf 'aaa\n' > "$d/a.bas"; printf 'bbb\n' > "$d/b.bas"; printf 'ccc\n' > "$d/c.bas"
}

run_golden3() { # name mode home arg2 golden
    local name="$1" mode="$2" home="$3" arg2="$4" golden="$5"
    : >"$stdout_file"
    if ! timeout 60 "$GBASIC" "$APP" "$mode" "$home" "$arg2" >"$stdout_file" 2>&1; then
        cat "$stdout_file"; fail "$name (nonzero exit)"
    fi
    if diff -u "$golden" "$stdout_file"; then printf 'PASS %s\n' "$name"; else fail "$name (output diff)"; fi
}

run_golden() { # name  mode  home  golden
    local name="$1" mode="$2" home="$3" golden="$4"
    : >"$stdout_file"
    if ! timeout 60 "$GBASIC" "$APP" "$mode" "$home" >"$stdout_file" 2>&1; then
        cat "$stdout_file"; fail "$name (nonzero exit)"
    fi
    if diff -u "$golden" "$stdout_file"; then
        printf 'PASS %s\n' "$name"
    else
        fail "$name (output diff)"
    fi
}

# 1. Empty startup — no prior session; defaults constructed.
run_golden "empty_startup" startup "$tmproot/empty" tests/studio/empty_startup.out

# 2. Save / restore — build+persist in one launch, restore in a SECOND launch on
#    the same home; restored state must equal the golden (window state included).
home_sr="$tmproot/sr"
timeout 60 "$GBASIC" "$APP" build "$home_sr" >"$stdout_file" 2>&1 || { cat "$stdout_file"; fail "save_restore (build)"; }
grep -q '^saved=settings,session,workspace:ws-1$' "$stdout_file" || { cat "$stdout_file"; fail "save_restore (saved line)"; }
run_golden "save_restore" startup "$home_sr" tests/studio/save_restore.out

# 3. Corrupt session — invalid JSON in session.json; startup recovers, no crash.
home_cor="$tmproot/cor"
timeout 60 "$GBASIC" "$APP" build "$home_cor" >/dev/null 2>&1 || fail "corrupt_session (setup)"
printf '%s' '{ not valid json ]' > "$home_cor/session.json"
run_golden "corrupt_session" startup "$home_cor" tests/studio/corrupt_session.out

# 4. Version mismatch — a future schema_version is rejected cleanly.
home_fut="$tmproot/fut"
timeout 60 "$GBASIC" "$APP" build "$home_fut" >/dev/null 2>&1 || fail "future_version (setup)"
printf '%s' '{"schema_version":999,"active_workspace":"ws-1","next_ws":2,"window":{"width":1,"height":1,"maximized":false},"recent_files":[]}' > "$home_fut/session.json"
run_golden "future_version" startup "$home_fut" tests/studio/future_version.out

# 5. Atomic persistence — 30 save/reload cycles; every reload must load cleanly
#    (a truncated store from a non-atomic write would surface as a failed reload).
: >"$stdout_file"
timeout 60 "$GBASIC" "$APP" stress "$tmproot/stress" >"$stdout_file" 2>&1 || { cat "$stdout_file"; fail "stress (exit)"; }
if grep -q '^stress_ok=true$' "$stdout_file"; then
    printf 'PASS stress\n'
else
    cat "$stdout_file"; fail "stress (not ok)"
fi

# 6. Memory — 50 startup/shutdown cycles under valgrind: 0 errors, 0 leaks.
#    (Studio is pure gBASIC — no new C — so this exercises the interpreter running
#    the backbone; it must be clean end-to-end.) Skips cleanly if valgrind absent.
if command -v valgrind >/dev/null 2>&1; then
    vg_log="$(mktemp)"
    : >"$stdout_file"
    if timeout 300 valgrind --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite \
            "$GBASIC" "$APP" cycles "$tmproot/cycles" >"$stdout_file" 2>"$vg_log"; then
        if grep -q '^cycles_done=50$' "$stdout_file"; then
            printf 'PASS memory_cycles (valgrind clean)\n'
        else
            cat "$stdout_file"; rm -f "$vg_log"; fail "memory_cycles (bad output)"
        fi
    else
        status=$?
        printf 'FAIL memory_cycles (valgrind exit %d)\n' "$status"
        grep -E 'definitely lost|ERROR SUMMARY|Invalid ' "$vg_log" || tail -20 "$vg_log"
        rm -f "$vg_log"
        exit 1
    fi
    rm -f "$vg_log"
else
    printf 'SKIP memory_cycles (valgrind not installed)\n'
fi

# ==========================================================================
# STU-1 — workspace navigation, project browser, registry.
# ==========================================================================

# No pure-gBASIC JSON validator survives anywhere in Studio. Every read goes
# through `try_decode`, an unconditional builtin, so no library needs loading for
# it and no caller can reintroduce a quadratic pre-pass by accident. Assert both
# halves: the file is gone, and nothing calls into it.
if [ -f lib/studio_json.bas ]; then
    printf 'FAIL no_gbasic_json_validator (lib/studio_json.bas is back)\n'
    exit 1
fi
if grep -rn 'studio_json\.' lib/*.bas app/*.bas tests/drivers/*.bas >/dev/null 2>&1; then
    printf 'FAIL no_gbasic_json_validator (a caller still uses studio_json)\n'
    grep -rn 'studio_json\.' lib/*.bas app/*.bas tests/drivers/*.bas
    exit 1
fi
printf 'PASS no_gbasic_json_validator (retired; all reads go through try_decode)\n'

# 7. Workspace lifecycle + multiple projects + navigation persistence:
#    build a workspace (2 projects incl. one missing dir, an expanded folder, a
#    selection) over a real tree, persist, and restore it in a SECOND launch.
#    Restored nav summary + browser tree must equal the golden (path-free).
proj_sr="$tmproot/proj_sr"; mkproj "$proj_sr"
home_s1="$tmproot/s1"
: >"$stdout_file"
timeout 60 "$GBASIC" "$APP" stu1_build "$home_s1" "$proj_sr" >"$stdout_file" 2>&1 || { cat "$stdout_file"; fail "stu1_build (exit)"; }
grep -q '^saved=settings,session,workspace:ws-1,registry$' "$stdout_file" || { cat "$stdout_file"; fail "stu1_build (saved line)"; }
run_golden "stu1_restore" stu1_restore "$home_s1" tests/studio/stu1_restore.out

# 8. Missing project — scanning a non-existent project directory yields no rows
#    and does not crash.
: >"$stdout_file"
timeout 60 "$GBASIC" "$APP" stu1_missing "$proj_sr" >"$stdout_file" 2>&1 || { cat "$stdout_file"; fail "stu1_missing (exit)"; }
if grep -q '^rows=0$' "$stdout_file"; then printf 'PASS stu1_missing\n'; else cat "$stdout_file"; fail "stu1_missing (rows)"; fi

# 9. Browser correctness — deterministic folders-first, sorted, lazy-expanded tree.
run_golden "stu1_browse" stu1_browse "$proj_sr" tests/studio/stu1_browse.out

# 10. Tree refresh — a new file on disk appears after a re-scan.
proj_rf="$tmproot/proj_rf"; mkproj "$proj_rf"
before="$(mktemp)"; after="$(mktemp)"
timeout 60 "$GBASIC" "$APP" stu1_browse "$proj_rf" >"$before" 2>&1 || { cat "$before"; fail "stu1_refresh (before)"; }
printf x > "$proj_rf/newfile.bas"
timeout 60 "$GBASIC" "$APP" stu1_browse "$proj_rf" >"$after" 2>&1 || { cat "$after"; fail "stu1_refresh (after)"; }
if ! grep -q 'newfile.bas' "$before" && grep -q 'newfile.bas' "$after" && [ "$(wc -l <"$after")" -gt "$(wc -l <"$before")" ]; then
    printf 'PASS stu1_refresh\n'
else
    echo "before:"; cat "$before"; echo "after:"; cat "$after"; rm -f "$before" "$after"; fail "stu1_refresh"
fi
rm -f "$before" "$after"

# 11. Workspace registry + recent — multiple workspaces are remembered and ordered.
run_golden "stu1_registry" stu1_registry "$tmproot/reg" tests/studio/stu1_registry.out

# 12. Memory — 50 STU-1 launch/persist cycles (registry included) under valgrind.
if command -v valgrind >/dev/null 2>&1; then
    vg_log="$(mktemp)"; : >"$stdout_file"
    if timeout 300 valgrind --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite \
            "$GBASIC" "$APP" stu1_cycles "$tmproot/s1cycles" >"$stdout_file" 2>"$vg_log"; then
        if grep -q '^cycles_done=50$' "$stdout_file"; then
            printf 'PASS stu1_memory_cycles (valgrind clean)\n'
        else
            cat "$stdout_file"; rm -f "$vg_log"; fail "stu1_memory_cycles (bad output)"
        fi
    else
        status=$?
        printf 'FAIL stu1_memory_cycles (valgrind exit %d)\n' "$status"
        grep -E 'definitely lost|ERROR SUMMARY|Invalid ' "$vg_log" || tail -20 "$vg_log"
        rm -f "$vg_log"; exit 1
    fi
    rm -f "$vg_log"
else
    printf 'SKIP stu1_memory_cycles (valgrind not installed)\n'
fi

# ==========================================================================
# STU-2 — documents & editor lifecycle.
# ==========================================================================

# 13. Document lifecycle: open, reuse (dup), directory guard, missing file, edit ->
#     dirty, revert -> clean, save. Plus a disk check that save wrote the file.
proj_life="$tmproot/life"; mkproj2 "$proj_life"
run_golden3 "stu2_lifecycle" stu2_lifecycle "$tmproot/lifehome" "$proj_life" tests/studio/stu2_lifecycle.out
if grep -qx 'saved by studio' "$proj_life/a.bas"; then printf 'PASS stu2_save_disk\n'; else echo "a.bas:"; cat "$proj_life/a.bas"; fail "stu2_save_disk (content)"; fi

# 14. Save failure — writing into a missing directory leaves the document dirty and
#     preserves the buffer (no crash, not marked clean).
: >"$stdout_file"
timeout 60 "$GBASIC" "$APP" stu2_savefail "$tmproot/failhome" >"$stdout_file" 2>&1 || { cat "$stdout_file"; fail "stu2_savefail (exit)"; }
if grep -qx 'savefail=error dirty=true' "$stdout_file"; then printf 'PASS stu2_savefail\n'; else cat "$stdout_file"; fail "stu2_savefail"; fi

# 15. Close a dirty document three ways (fresh dir each so prior saves can't bleed):
#     save -> closed, discard -> closed, cancel -> kept open.
for spec in "save:closed:0" "discard:closed:0" "cancel:cancelled:1"; do
    dec="${spec%%:*}"; rest="${spec#*:}"; want_status="${rest%%:*}"; want_open="${rest##*:}"
    cd_dir="$tmproot/close_$dec"; mkproj2 "$cd_dir"
    : >"$stdout_file"
    timeout 60 "$GBASIC" "$APP" stu2_close "$tmproot/closehome_$dec" "$cd_dir" "$dec" >"$stdout_file" 2>&1 || { cat "$stdout_file"; fail "stu2_close_$dec (exit)"; }
    if grep -qx "close($dec)=$want_status open=$want_open" "$stdout_file"; then
        printf 'PASS stu2_close_%s\n' "$dec"
    else
        cat "$stdout_file"; fail "stu2_close_$dec"
    fi
done

# 16. External changes — clean file changed on disk auto-reloads; a dirty file
#     changed on disk becomes a preserved conflict; a deleted file becomes missing.
proj_ext="$tmproot/ext"; mkproj2 "$proj_ext"
run_golden3 "stu2_external" stu2_external "$tmproot/exthome" "$proj_ext" tests/studio/stu2_external.out

# 17. Restore — open two documents, set cursors + active, persist, relaunch: the open
#     set, tab order, active document, and cursor positions are restored.
proj_res="$tmproot/res"; mkproj2 "$proj_res"
run_golden3 "stu2_restore" stu2_restore "$tmproot/reshome" "$proj_res" tests/studio/stu2_restore.out

# 18. Missing restored file — persist an open file, delete it, relaunch: the document
#     restores in a missing state, not a crash.
proj_mr="$tmproot/mr"; mkproj2 "$proj_mr"; home_mr="$tmproot/mrhome"
timeout 60 "$GBASIC" "$APP" stu2_open_persist "$home_mr" "$proj_mr" >/dev/null 2>&1 || fail "stu2_missing (setup)"
rm -f "$proj_mr/a.bas"
: >"$stdout_file"
timeout 60 "$GBASIC" "$APP" stu2_missing_restore "$home_mr" "$proj_mr" >"$stdout_file" 2>&1 || { cat "$stdout_file"; fail "stu2_missing (exit)"; }
if grep -q 'a.bas clean missing' "$stdout_file"; then printf 'PASS stu2_missing_restore\n'; else cat "$stdout_file"; fail "stu2_missing_restore"; fi

# 19. Browser integration — opening a file the browser points at activates its tab.
proj_br="$tmproot/br"; mkproj2 "$proj_br"
: >"$stdout_file"
timeout 60 "$GBASIC" "$APP" stu2_browser "$tmproot/brhome" "$proj_br" >"$stdout_file" 2>&1 || { cat "$stdout_file"; fail "stu2_browser (exit)"; }
if grep -qx 'browser_opened=a.bas active=doc-1' "$stdout_file"; then printf 'PASS stu2_browser\n'; else cat "$stdout_file"; fail "stu2_browser"; fi

# 20. Memory + callbacks — 40 open/edit/save/close/persist cycles under valgrind.
if command -v valgrind >/dev/null 2>&1; then
    proj_cy="$tmproot/cy"; mkproj2 "$proj_cy"
    vg_log="$(mktemp)"; : >"$stdout_file"
    if timeout 300 valgrind --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite \
            "$GBASIC" "$APP" stu2_cycles "$tmproot/cyhome" "$proj_cy" >"$stdout_file" 2>"$vg_log"; then
        if grep -qx 'cycles_done=40' "$stdout_file"; then
            printf 'PASS stu2_memory_cycles (valgrind clean)\n'
        else
            cat "$stdout_file"; rm -f "$vg_log"; fail "stu2_memory_cycles (bad output)"
        fi
    else
        status=$?
        printf 'FAIL stu2_memory_cycles (valgrind exit %d)\n' "$status"
        grep -E 'definitely lost|ERROR SUMMARY|Invalid ' "$vg_log" || tail -20 "$vg_log"
        rm -f "$vg_log"; exit 1
    fi
    rm -f "$vg_log"
else
    printf 'SKIP stu2_memory_cycles (valgrind not installed)\n'
fi

# ---- STU-3: execution-section engine (studio_sections) ----------------------
# Headless, GI-independent, path-free. The sections driver takes only a mode (no
# home): derivation, cursor resolution, program-body scope, reattachment across
# edits (blank-insert/internal/rename/sibling/duplicate/delete), invalid-source
# retention+recovery, persistence round-trip, multi-document isolation, Unicode byte
# offsets, and repeated-refresh determinism.
SEC=tests/drivers/sections.bas
run_sections() { # mode
    local mode="$1"
    : >"$stdout_file"
    if ! timeout 60 "$GBASIC" "$SEC" "$mode" >"$stdout_file" 2>&1; then
        cat "$stdout_file"; fail "sections_$mode (nonzero exit)"
    fi
    if diff -u "tests/studio/sections_$mode.out" "$stdout_file"; then
        printf 'PASS sections_%s\n' "$mode"
    else
        fail "sections_$mode (output diff)"
    fi
}
for m in derive cursor cursor_pos prog insert_blank internal rename sibling duplicate delete invalid persist multidoc unicode repeated; do
    run_sections "$m"
done

# The two disk-backed cases: sections ride in the workspace record through strict
# JSON + atomic_replace (store), and a pre-STU-3 workspace with no `sections` key
# still loads and accepts sections with no migration step (compat). They take a
# scratch directory; nothing about the path is printed, so the goldens stay
# path-free like the rest.
run_sections_dir() { # mode
    local mode="$1" d
    d="$tmproot/sec_$mode"
    rm -rf "$d"; mkdir -p "$d"
    : >"$stdout_file"
    if ! timeout 60 "$GBASIC" "$SEC" "$mode" "$d" >"$stdout_file" 2>&1; then
        cat "$stdout_file"; fail "sections_$mode (nonzero exit)"
    fi
    if diff -u "tests/studio/sections_$mode.out" "$stdout_file"; then
        printf 'PASS sections_%s\n' "$mode"
    else
        fail "sections_$mode (output diff)"
    fi
}
run_sections_dir store
run_sections_dir compat

# STU-3 memory: repeated derive/reattach churn under valgrind (no leak across
# refresh cycles; exercises match/stale/ambiguous/persist paths via the scenarios).
if command -v valgrind >/dev/null 2>&1; then
    vg_log="$(mktemp)"
    sec_ok=1
    for m in repeated duplicate invalid persist; do
        : >"$stdout_file"
        if ! timeout 300 valgrind --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite \
                "$GBASIC" "$SEC" "$m" >"$stdout_file" 2>"$vg_log"; then
            printf 'FAIL sections_memory (%s, valgrind)\n' "$m"
            grep -E 'definitely lost|ERROR SUMMARY|Invalid ' "$vg_log" || tail -20 "$vg_log"
            sec_ok=0; rm -f "$vg_log"; exit 1
        fi
    done
    # ...and the disk-backed store path (JSON encode/decode + atomic_replace).
    vg_dir="$tmproot/sec_vg_store"
    rm -rf "$vg_dir"; mkdir -p "$vg_dir"
    : >"$stdout_file"
    if ! timeout 300 valgrind --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite \
            "$GBASIC" "$SEC" store "$vg_dir" >"$stdout_file" 2>"$vg_log"; then
        printf 'FAIL sections_memory (store, valgrind)\n'
        grep -E 'definitely lost|ERROR SUMMARY|Invalid ' "$vg_log" || tail -20 "$vg_log"
        sec_ok=0; rm -f "$vg_log"; exit 1
    fi
    rm -f "$vg_log"
    [ "$sec_ok" -eq 1 ] && printf 'PASS sections_memory (valgrind clean: repeated/duplicate/invalid/persist/store)\n'
else
    printf 'SKIP sections_memory (valgrind not installed)\n'
fi

# STU-3 display tier (OPTIONAL — this suite stays headless-everywhere; the tier
# SKIPs, never fails, without GTK 4 or a display). STU-3 draws no widgets of its
# own (boundary rendering is STU-5), so what is verified here is the INTEGRATION:
# with the real GTK shell built and a real editor tab open, the live document
# buffer derives sections and the document's own line/column cursor resolves to a
# section id. Output is path-free like the rest (the doc lives under $tmproot and
# only its basename is ever printed).
if [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
    sec_home="$tmproot/sec_gui"
    mkdir -p "$sec_home"
    : >"$stdout_file"
    if timeout 120 env G_DEBUG="${G_DEBUG:+$G_DEBUG,}fatal-criticals" \
            "$GBASIC" "$APP" stu3_smoke "$sec_home" "$sec_home/live.bas" >"$stdout_file" 2>&1; then
        if diff -u tests/studio/sections_gui.out "$stdout_file"; then
            printf 'PASS sections_gui (GTK shell + live editor cursor)\n'
        else
            fail "sections_gui (output diff)"
        fi
    else
        if grep -q 'gi.require: could not load namespace' "$stdout_file"; then
            printf 'SKIP sections_gui (GTK 4 typelib not available)\n'
        else
            cat "$stdout_file"; fail "sections_gui (nonzero exit)"
        fi
    fi
else
    printf 'SKIP sections_gui (no display)\n'
fi

# ---- STU-4: execution sessions (studio_session) -----------------------------
# Headless, GI-independent, path-free. The sessions driver takes a mode and a
# scratch directory (never printed). Covers every state transition, a clean run,
# runtime errors in the target and in the replayed prefix, a diagnostic outside
# every section, polite stop, forced stop, a SIGTERM-ignoring child surfacing as
# `unresponsive`, restart mid-run, all three refusals, a child killed by signal
# with no diagnostic, output past a pipe buffer, an edit between two runs, and the
# scratch-file lifecycle.
SESS=tests/drivers/sessions.bas
run_session() { # mode
    local mode="$1" d
    d="$tmproot/sess_$mode"
    rm -rf "$d"; mkdir -p "$d"
    : >"$stdout_file"
    if ! timeout 180 "$GBASIC" "$SESS" "$mode" "$d" >"$stdout_file" 2>&1; then
        cat "$stdout_file"; fail "sessions_$mode (nonzero exit)"
    fi
    if diff -u "tests/studio/sessions_$mode.out" "$stdout_file"; then
        printf 'PASS sessions_%s\n' "$mode"
    else
        fail "sessions_$mode (output diff)"
    fi
    # No materialized prefix may survive a run, in any scenario.
    if [ -n "$(ls -A "$d" 2>/dev/null)" ]; then
        printf 'FAIL sessions_%s (scratch files left behind)\n' "$mode"
        ls -la "$d"
        exit 1
    fi
}
for m in clean err_target err_prefix outside prog stop force unresponsive restart \
         refuse signal big edited scratch vars; do
    run_session "$m"
done

# ---- STU-4B: materialization completeness -----------------------------------
# Declaration hoisting (helpers-after-main), boundary-marker output separation,
# the shared position map probed directly, and live output via --line-buffered.
for m in hoist hoist_before hoist_order hoist_err hoist_target hoist_inert \
         split split_nonce split_die split_stderr map stream; do
    run_session "$m"
done
printf 'PASS sessions_scratch_clean (no materialized prefix left by any case)\n'

# ---- STU-5A: persistent, section-linked results and history ------------------
# Headless and path-free: the driver takes a mode, a scratch directory for
# materialized prefixes, and a throwaway Studio home holding the results store.
# Neither path is printed, and every timestamp is pinned through the session's
# `clock_fixed` seam, so the goldens are byte-stable while real runs still happen.
RES=tests/drivers/results.bas
res_home_root="$tmproot/results_homes"
run_results() { # mode
    local mode="$1" d h
    d="$tmproot/res_$mode"; h="$res_home_root/$mode"
    rm -rf "$d" "$h"; mkdir -p "$d" "$h"
    : >"$stdout_file"
    if ! timeout 300 "$GBASIC" "$RES" "$mode" "$d" "$h" >"$stdout_file" 2>&1; then
        cat "$stdout_file"; fail "results_$mode (nonzero exit)"
    fi
    if diff -u "tests/studio/results_$mode.out" "$stdout_file"; then
        printf 'PASS results_%s\n' "$mode"
    else
        fail "results_$mode (output diff)"
    fi
    # Results are durable; materialized prefixes are not. No run may leave one.
    if [ -n "$(ls -A "$d" 2>/dev/null)" ]; then
        printf 'FAIL results_%s (scratch files left behind)\n' "$mode"
        ls -la "$d"
        exit 1
    fi
}
for m in persist history fingerprint orphan refused signal truncate truncate_unit \
         evict concurrent compat store view preview; do
    run_results "$m"
done
printf 'PASS results_scratch_clean (no materialized prefix left by any case)\n'

# The results store must live OUTSIDE the workspace record: STU-3's anchors are
# small and bounded, results are neither. Assert the separation on disk rather
# than trusting the code to have kept it.
res_store_dir="$res_home_root/truncate/results"
if [ -d "$res_store_dir" ] && [ -z "$(ls -A "$res_home_root/truncate" 2>/dev/null | grep -v '^results$')" ]; then
    printf 'PASS results_store_separate (results/ is the only thing the store writes)\n'
else
    printf 'FAIL results_store_separate\n'
    ls -la "$res_home_root/truncate" 2>/dev/null
    exit 1
fi

# The index must stay SMALL however much output was captured. The split was
# forced by a quadratic pure-gBASIC validator that no longer exists; it is kept
# for write amplification (the index is rewritten whole on every save) and lazy
# reads (a capture loads only when displayed).
# Assert the separation rather than trusting it: the biggest index in the suite is
# from `evict` (21 results), and it must still be far below one capture's cap.
biggest_index=$(find "$res_home_root" -name '*.json' -printf '%s\n' 2>/dev/null | sort -n | tail -1)
if [ -n "$biggest_index" ] && [ "$biggest_index" -lt 65536 ]; then
    printf 'PASS results_index_small (largest index %s bytes, under the 64K capture cap)\n' "$biggest_index"
else
    printf 'FAIL results_index_small (largest index %s bytes)\n' "${biggest_index:-none}"
    exit 1
fi

# Retention and the size cap are policy, so measure what they actually cost:
# `truncate` pushes ~84 KB of child output through a 64 KB cap, and `evict` writes
# past the per-section limit. Both must stay bounded on disk.
printf 'INFO results_disk_size total=%s truncate=%s evict=%s largest_index=%sB\n' \
    "$(du -sh "$res_home_root" 2>/dev/null | cut -f1)" \
    "$(du -sh "$res_home_root/truncate" 2>/dev/null | cut -f1)" \
    "$(du -sh "$res_home_root/evict" 2>/dev/null | cut -f1)" \
    "$biggest_index"

# STU-5A memory: the record/evict/truncate/classify paths under valgrind.
if command -v valgrind >/dev/null 2>&1; then
    vg_log="$(mktemp)"
    for m in persist truncate truncate_unit evict orphan; do
        d="$tmproot/res_vg_$m"; h="$res_home_root/vg_$m"
        rm -rf "$d" "$h"; mkdir -p "$d" "$h"
        : >"$stdout_file"
        if ! timeout 900 valgrind --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite \
                "$GBASIC" "$RES" "$m" "$d" "$h" >"$stdout_file" 2>"$vg_log"; then
            printf 'FAIL results_memory (%s, valgrind)\n' "$m"
            grep -E 'definitely lost|ERROR SUMMARY|Invalid ' "$vg_log" || tail -20 "$vg_log"
            rm -f "$vg_log"; exit 1
        fi
    done
    rm -f "$vg_log"
    printf 'PASS results_memory (valgrind clean: persist/truncate/truncate_unit/evict/orphan)\n'
else
    printf 'SKIP results_memory (valgrind not installed)\n'
fi

# STU-4 memory: the run/stop/attribute paths under valgrind. `force` and
# `unresponsive` are included because they are the ones that kill a child and
# release a live process handle.
if command -v valgrind >/dev/null 2>&1; then
    vg_log="$(mktemp)"
    for m in clean err_prefix force unresponsive; do
        d="$tmproot/sess_vg_$m"
        rm -rf "$d"; mkdir -p "$d"
        : >"$stdout_file"
        if ! timeout 900 valgrind --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite \
                "$GBASIC" "$SESS" "$m" "$d" >"$stdout_file" 2>"$vg_log"; then
            printf 'FAIL sessions_memory (%s, valgrind)\n' "$m"
            grep -E 'definitely lost|ERROR SUMMARY|Invalid ' "$vg_log" || tail -20 "$vg_log"
            rm -f "$vg_log"; exit 1
        fi
    done
    rm -f "$vg_log"
    printf 'PASS sessions_memory (valgrind clean: clean/err_prefix/force/unresponsive)\n'
else
    printf 'SKIP sessions_memory (valgrind not installed)\n'
fi

# STU-4 display tier (OPTIONAL; SKIPs, never fails, without GTK 4 or a display).
# Proves the UI integration: the real GTK shell builds, the section under the
# document's cursor is resolved and run, and a GTK TIMEOUT -- not an actor, not a
# mailbox -- drives the session to completion while the loop stays live.
if [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
    sess_home="$tmproot/sess_gui"
    mkdir -p "$sess_home"
    : >"$stdout_file"
    if timeout 180 env G_DEBUG="${G_DEBUG:+$G_DEBUG,}fatal-criticals" \
            "$GBASIC" "$APP" stu4_smoke "$sess_home" "$sess_home/live.bas" \
            >"$stdout_file" 2>/dev/null; then
        if diff -u tests/studio/sessions_gui.out "$stdout_file"; then
            printf 'PASS sessions_gui (GTK shell + timeout-driven run)\n'
        else
            fail "sessions_gui (output diff)"
        fi
    else
        if grep -q 'gi.require: could not load namespace' "$stdout_file"; then
            printf 'SKIP sessions_gui (GTK 4 typelib not available)\n'
        else
            cat "$stdout_file"; fail "sessions_gui (nonzero exit)"
        fi
    fi
    if [ -n "$(ls -A "$sess_home/scratch" 2>/dev/null)" ]; then
        printf 'FAIL sessions_gui (scratch files left behind)\n'
        exit 1
    fi
else
    printf 'SKIP sessions_gui (no display)\n'
fi

# STU-5A display tier (OPTIONAL; SKIPs, never fails, without GTK 4 or a display).
# The results pane over a REAL run: rendered before the run, again after the result
# has been written and READ BACK FROM DISK, and once more after the section is
# edited -- which is where the stale-content mark has to appear. The clock is
# pinned exactly as the headless cases pin it, so the golden is byte-stable.
if [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
    res_home="$tmproot/res_gui"
    mkdir -p "$res_home"
    : >"$stdout_file"
    if timeout 180 env G_DEBUG="${G_DEBUG:+$G_DEBUG,}fatal-criticals" \
            "$GBASIC" "$APP" stu5_smoke "$res_home" "$res_home/live.bas" \
            >"$stdout_file" 2>/dev/null; then
        if diff -u tests/studio/results_gui.out "$stdout_file"; then
            printf 'PASS results_gui (GTK shell + persisted result + stale mark)\n'
        else
            fail "results_gui (output diff)"
        fi
    else
        if grep -q 'gi.require: could not load namespace' "$stdout_file"; then
            printf 'SKIP results_gui (GTK 4 typelib not available)\n'
        else
            cat "$stdout_file"; fail "results_gui (nonzero exit)"
        fi
    fi
    if [ -n "$(ls -A "$res_home/scratch" 2>/dev/null)" ]; then
        printf 'FAIL results_gui (scratch files left behind)\n'
        exit 1
    fi
else
    printf 'SKIP results_gui (no display)\n'
fi

# ---- STU-2B: interaction (studio_ui + the wired shell) ----------------------
#
# The shell had no signal handlers at all before this phase, so nothing it drew
# responded to a click. What is asserted here is split in two, and the split is
# the architecture rather than a testing convenience:
#
#   ui_*      — headless, GI-independent, path-free. Every interaction's MEANING,
#               decided by a studio_ui function the driver calls directly. This is
#               the primary evidence and it runs everywhere.
#   ui_gui*   — display-only, SKIPs without GTK 4 or a display. The two inches a
#               headless test cannot reach: that the handler is connected, that
#               the index it reads off the widget is the row the user hit, and
#               that rebuilding a pane from inside that pane's own handler is
#               safe. Real signals are synthesised (GtkListBoxRow.activate,
#               GtkNotebook.set_current_page, GtkTextBuffer.set_text,
#               GtkButton.activate) — there is no gi.emit, but those methods emit
#               the signal we want as their documented effect.
UI=tests/drivers/ui.bas
run_ui() { # mode
    local mode="$1" home proj
    home="$tmproot/ui_$mode"
    proj="$tmproot/ui_${mode}_proj"
    rm -rf "$home" "$proj"; mkdir -p "$home"
    mkproj_ui "$proj"
    : >"$stdout_file"
    if ! timeout 60 "$GBASIC" "$UI" "$mode" "$home" "$proj" >"$stdout_file" 2>&1; then
        cat "$stdout_file"; fail "ui_$mode (nonzero exit)"
    fi
    if diff -u "tests/studio/ui_$mode.out" "$stdout_file"; then
        printf 'PASS ui_%s\n' "$mode"
    else
        fail "ui_$mode (output diff)"
    fi
}

for m in rows open expand project bounds tabs edit save newproj refresh \
         newfile newfolder adopt exit \
         names rename delete closetab notice \
         run runstop runerr cursor; do
    run_ui "$m"
done

# STU-2B memory: the interaction paths under valgrind. Redraw churn allocates a
# fresh row model on every mutation, so a leak here would grow with clicks.
if command -v valgrind >/dev/null 2>&1; then
    vg_log="$(mktemp)"
    ui_ok=1
    for m in open expand tabs edit refresh newfile newfolder adopt rename delete closetab cursor; do
        ui_home="$tmproot/ui_vg_$m"; ui_proj="$tmproot/ui_vg_${m}_proj"
        rm -rf "$ui_home" "$ui_proj"; mkdir -p "$ui_home"; mkproj_ui "$ui_proj"
        : >"$stdout_file"
        if ! timeout 300 valgrind --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite \
                "$GBASIC" "$UI" "$m" "$ui_home" "$ui_proj" >"$stdout_file" 2>"$vg_log"; then
            printf 'FAIL ui_memory (%s, valgrind)\n' "$m"
            grep -E 'definitely lost|ERROR SUMMARY|Invalid ' "$vg_log" || tail -20 "$vg_log"
            ui_ok=0; rm -f "$vg_log"; exit 1
        fi
    done
    rm -f "$vg_log"
    [ "$ui_ok" -eq 1 ] && printf 'PASS ui_memory (valgrind clean: open/expand/tabs/edit/refresh/newfile/newfolder/adopt/rename/delete/closetab/cursor)\n'
else
    printf 'SKIP ui_memory (valgrind not installed)\n'
fi

# STU-2B display tier (OPTIONAL; SKIPs, never fails, without GTK 4 or a display).
# stderr is discarded like the other loop-running tiers: GTK emits allocation
# warnings that vary by version and theme, and baking those into a byte-exact
# golden would make the suite fail on someone else's desktop. G_DEBUG makes a real
# GTK CRITICAL abort instead, which surfaces as a nonzero exit.
if [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
    ui_home="$tmproot/ui_gui"; ui_proj="$tmproot/ui_gui_proj"
    mkdir -p "$ui_home"; mkproj_ui "$ui_proj"
    : >"$stdout_file"
    if timeout 180 env G_DEBUG="${G_DEBUG:+$G_DEBUG,}fatal-criticals" \
            "$GBASIC" "$APP" stu2b_smoke "$ui_home" "$ui_proj" \
            >"$stdout_file" 2>/dev/null; then
        if diff -u tests/studio/ui_gui.out "$stdout_file"; then
            printf 'PASS ui_gui (synthesised clicks through the real handlers)\n'
        else
            fail "ui_gui (output diff)"
        fi
    else
        if grep -q 'gi.require: could not load namespace' "$stdout_file"; then
            printf 'SKIP ui_gui (GTK 4 typelib not available)\n'
        else
            cat "$stdout_file"; fail "ui_gui (nonzero exit)"
        fi
    fi

    # The cold-home path: an empty home is what a new user actually starts with,
    # and New Project is the only control that can move it. If this one button is
    # not wired there is no way into Studio at all.
    cold_home="$tmproot/ui_gui_cold"
    mkdir -p "$cold_home"
    : >"$stdout_file"
    if timeout 180 env G_DEBUG="${G_DEBUG:+$G_DEBUG,}fatal-criticals" \
            "$GBASIC" "$APP" stu2b_cold "$cold_home" \
            >"$stdout_file" 2>/dev/null; then
        if diff -u tests/studio/ui_gui_cold.out "$stdout_file"; then
            printf 'PASS ui_gui_cold (New Project on an empty home)\n'
        else
            fail "ui_gui_cold (output diff)"
        fi
    else
        if grep -q 'gi.require: could not load namespace' "$stdout_file"; then
            printf 'SKIP ui_gui_cold (GTK 4 typelib not available)\n'
        else
            cat "$stdout_file"; fail "ui_gui_cold (nonzero exit)"
        fi
    fi

    # STU-2C, the whole complaint end to end: from an empty home, build a
    # project, a file, its contents and a folder using nothing but the window,
    # then CLOSE it — and reopen the same home in a second process to prove that
    # closing saved it. The reopen is a separate interpreter run on purpose: a
    # process asserting its own in-memory state cannot show anything reached disk.
    c2_home="$tmproot/ui_gui_new"
    mkdir -p "$c2_home"
    : >"$stdout_file"
    if timeout 180 env G_DEBUG="${G_DEBUG:+$G_DEBUG,}fatal-criticals" \
            "$GBASIC" "$APP" stu2c_smoke "$c2_home" \
            >"$stdout_file" 2>/dev/null; then
        printf -- '-- reopening the home in a new process --\n' >>"$stdout_file"
        if ! timeout 60 "$GBASIC" "$UI" show "$c2_home" >>"$stdout_file" 2>&1; then
            cat "$stdout_file"; fail "ui_gui_new (reopen exited nonzero)"
        fi
        if diff -u tests/studio/ui_gui_new.out "$stdout_file"; then
            printf 'PASS ui_gui_new (cold home to a saved project, all from the window)\n'
        else
            fail "ui_gui_new (output diff)"
        fi
    else
        if grep -q 'gi.require: could not load namespace' "$stdout_file"; then
            printf 'SKIP ui_gui_new (GTK 4 typelib not available)\n'
        else
            cat "$stdout_file"; fail "ui_gui_new (nonzero exit)"
        fi
    fi
    # STU-2D: the name FIELD, which no headless test can reach — that Rename and
    # New File read what was typed into a GtkEntry, that the field empties once
    # consumed, and that Delete's arm survives exactly one redraw. GtkEntry text
    # is an ordinary property, which is why the name is a field and not a dialog:
    # a test can type into it.
    d2_home="$tmproot/ui_gui_name"; d2_proj="$tmproot/ui_gui_name_proj"
    mkdir -p "$d2_home"; mkproj_ui "$d2_proj"
    : >"$stdout_file"
    if timeout 180 env G_DEBUG="${G_DEBUG:+$G_DEBUG,}fatal-criticals" \
            "$GBASIC" "$APP" stu2d_smoke "$d2_home" "$d2_proj" \
            >"$stdout_file" 2>/dev/null; then
        if diff -u tests/studio/ui_gui_name.out "$stdout_file"; then
            printf 'PASS ui_gui_name (typed names, rename, and delete confirmed twice)\n'
        else
            fail "ui_gui_name (output diff)"
        fi
    else
        if grep -q 'gi.require: could not load namespace' "$stdout_file"; then
            printf 'SKIP ui_gui_name (GTK 4 typelib not available)\n'
        else
            cat "$stdout_file"; fail "ui_gui_name (nonzero exit)"
        fi
    fi
    # STU-2E: Run Section, clicked for real. Nothing in the test advances the
    # run — the button's handler starts a child interpreter and installs a GTK
    # timer, and the case waits for the window to drive itself to a finished
    # state. That the poll is installed and that it STOPS is the part no headless
    # loop can show.
    e5_home="$tmproot/ui_gui_run"; e5_proj="$tmproot/ui_gui_run_proj"
    mkdir -p "$e5_home" "$e5_proj"
    printf 'print "one"\n\nfunction add(a, b)\n  return a + b\nend function\n\nprint add(2, 3)\n' \
        > "$e5_proj/runme.bas"
    : >"$stdout_file"
    if timeout 180 env G_DEBUG="${G_DEBUG:+$G_DEBUG,}fatal-criticals" \
            "$GBASIC" "$APP" stu2e_smoke "$e5_home" "$e5_proj" \
            >"$stdout_file" 2>/dev/null; then
        if diff -u tests/studio/ui_gui_run.out "$stdout_file"; then
            printf 'PASS ui_gui_run (a section run from a click, polled by the window)\n'
        else
            fail "ui_gui_run (output diff)"
        fi
    else
        if grep -q 'gi.require: could not load namespace' "$stdout_file"; then
            printf 'SKIP ui_gui_run (GTK 4 typelib not available)\n'
        else
            cat "$stdout_file"; fail "ui_gui_run (nonzero exit)"
        fi
    fi

    # STU-5A': the caret drives the panes. Moving a caret is not a click, so no
    # other tier would notice a disconnected cursor handler; `set_cursor` moves
    # the real caret and GTK emits the real "notify::cursor-position".
    f5_home="$tmproot/ui_gui_cursor"; f5_proj="$tmproot/ui_gui_cursor_proj"
    mkdir -p "$f5_home" "$f5_proj"
    printf 'print "one"\n\nfunction add(a, b)\n  return a + b\nend function\n\nprint add(2, 3)\n' \
        > "$f5_proj/runme.bas"
    : >"$stdout_file"
    if timeout 180 env G_DEBUG="${G_DEBUG:+$G_DEBUG,}fatal-criticals" \
            "$GBASIC" "$APP" stu2f_smoke "$f5_home" "$f5_proj" \
            >"$stdout_file" 2>/dev/null; then
        if diff -u tests/studio/ui_gui_cursor.out "$stdout_file"; then
            printf 'PASS ui_gui_cursor (the panes follow the real caret)\n'
        else
            fail "ui_gui_cursor (output diff)"
        fi
    else
        if grep -q 'gi.require: could not load namespace' "$stdout_file"; then
            printf 'SKIP ui_gui_cursor (GTK 4 typelib not available)\n'
        else
            cat "$stdout_file"; fail "ui_gui_cursor (nonzero exit)"
        fi
    fi

    # Two Studio windows at once. This is a regression test for a real defect,
    # not a stress test: `gtk.application(id)` defaults to SINGLE-INSTANCE, so a
    # second Studio used to print nothing and quietly hand its "activate" to the
    # first — which then built a second shell over the same globals and wired
    # every handler twice. It showed up here as a display tier that occasionally
    # saw one click land twice. Both processes must now produce, byte for byte,
    # what one alone produces.
    solo_a="$tmproot/ui_gui_solo_a"; solo_b="$tmproot/ui_gui_solo_b"
    mkdir -p "$solo_a" "$solo_b"
    solo_out_a="$tmproot/solo_a.out"; solo_out_b="$tmproot/solo_b.out"
    timeout 180 env G_DEBUG="${G_DEBUG:+$G_DEBUG,}fatal-criticals" \
            "$GBASIC" "$APP" stu2b_cold "$solo_a" >"$solo_out_a" 2>/dev/null &
    solo_pid=$!
    timeout 180 env G_DEBUG="${G_DEBUG:+$G_DEBUG,}fatal-criticals" \
            "$GBASIC" "$APP" stu2b_cold "$solo_b" >"$solo_out_b" 2>/dev/null
    solo_rc_b=$?
    wait "$solo_pid"; solo_rc_a=$?
    if [ "$solo_rc_a" -ne 0 ] || [ "$solo_rc_b" -ne 0 ]; then
        if grep -q 'gi.require: could not load namespace' "$solo_out_a" "$solo_out_b"; then
            printf 'SKIP ui_gui_solo (GTK 4 typelib not available)\n'
        else
            cat "$solo_out_a" "$solo_out_b"; fail "ui_gui_solo (nonzero exit)"
        fi
    elif diff -u tests/studio/ui_gui_cold.out "$solo_out_a" \
         && diff -u tests/studio/ui_gui_cold.out "$solo_out_b"; then
        printf 'PASS ui_gui_solo (two instances at once, neither disturbing the other)\n'
    else
        fail "ui_gui_solo (a concurrent instance changed what the other did)"
    fi
else
    printf 'SKIP ui_gui (no display)\n'
    printf 'SKIP ui_gui_cold (no display)\n'
    printf 'SKIP ui_gui_new (no display)\n'
    printf 'SKIP ui_gui_name (no display)\n'
    printf 'SKIP ui_gui_solo (no display)\n'
    printf 'SKIP ui_gui_run (no display)\n'
    printf 'SKIP ui_gui_cursor (no display)\n'
fi

printf 'run_studio: all cases passed\n'
