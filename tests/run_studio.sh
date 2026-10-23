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
    printf '  Studio needs persist and filetree from it, and the qt module for the window\n'
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
# New Project copies a LICENSE out of share/licenses/ rather than authoring one,
# and finds that directory the way ./studio tells it to. Without this the licence
# cases would exercise the "no text shipped" refusal instead of the licence.
export GBASIC_STUDIO_SHARE="$PWD/share"
APP=app/studio_cli.bas

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
    # A dotfile that stays hidden, so "the browser shows .gstudio.json" is a
    # statement about that file and not about dotfiles generally.
    printf 'shh\n'          > "$d/.hidden"
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
grep -q '^saved=settings,session$' "$stdout_file" || { cat "$stdout_file"; fail "save_restore (saved line)"; }
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
# STU-11 — optional git, over process.run. A fixture repository built by
# `git init` in a temp directory: no network, no display, and nothing that
# touches the developer's own repository.
#
# The fixture is built HERE rather than in the driver. Building it with
# process.run from inside the driver would make every case depend on the very
# thing it is testing, so a broken process.run would look like a broken parser.
#
# Each mode gets a FRESH repository: `commit` mutates the fixture, and a mode
# that inherits another's mutations is a mode whose golden depends on the order
# the loop happens to run in.
GITD=tests/drivers/git.bas
if command -v git >/dev/null 2>&1; then
    mkgitrepo() { # dir
        local d="$1"
        rm -rf "$d"; mkdir -p "$d/sub"
        git -C "$d" init -q -b main .
        git -C "$d" config user.email test@example.invalid
        git -C "$d" config user.name Test
        printf 'print "one"\n' > "$d/tracked.bas"
        printf 'x\n'           > "$d/sub/deep.bas"
        git -C "$d" add -A
        git -C "$d" -c commit.gpgsign=false commit -q -m "first commit"
        printf 'print "one"\nprint "two"\n' > "$d/tracked.bas"
        printf 'y\n'                        > "$d/untracked.bas"
    }
    for m in quiet detect status history diff commit tiers; do
        gh="$tmproot/git_$m"; gr="$tmproot/git_${m}_repo"
        rm -rf "$gh"; mkdir -p "$gh"
        mkgitrepo "$gr"
        : >"$stdout_file"
        if ! timeout 120 "$GBASIC" "$GITD" "$m" "$gh" "$gr" >"$stdout_file" 2>&1; then
            cat "$stdout_file"; fail "git_$m (nonzero exit)"
        fi
        if diff -u "tests/studio/git_$m.out" "$stdout_file"; then
            printf 'PASS git_%s\n' "$m"
        else
            fail "git_$m (output diff)"
        fi
    done
else
    printf 'SKIP git_* (git is not installed)\n'
fi

# A Studio exploratory branch is NOT a git branch (§2.3, §9). The one crossover
# the design allows is a PROMOTED overlay becoming an ordinary working-tree edit
# -- which git sees because it IS one, not because Studio told it anything.
# Checked against the source: the failure would be a `git branch`/`checkout`
# invocation added to make Studio branches "real", which is the exact thing the
# design forbids.
# Stated as "these modules never spawn anything", which is precise. The first
# version grepped for the WORD "branch" next to a comma and caught
# `["branch", "section_id", ...]` -- a list of record keys in the overlay's own
# persistence check. A tripwire that fires on its own vocabulary is one someone
# eventually deletes.
if grep -nE 'process\.(run|start)|refs/heads' lib/studio_branches.bas lib/studio_overlays.bas; then
    fail "git_not_branches (a Studio branch reaches for a git ref)"
fi
if grep -nE 'studio_branches\.|studio_overlays\.' lib/studio_git.bas; then
    fail "git_not_branches (the git layer knows about Studio branches)"
fi
printf 'PASS git_not_branches (Studio branches and git refs stay separate)\n'

# ==========================================================================
# STU-9 — code-overlay branches. Projection, scope, conflict, rebase, promote,
# discard and persistence, over plain data. No child process and no display.
OVL=tests/drivers/overlays.bas
run_overlays() { # mode
    local mode="$1" h
    h="$tmproot/ov_$mode"
    rm -rf "$h"; mkdir -p "$h"
    : >"$stdout_file"
    if ! timeout 60 "$GBASIC" "$OVL" "$mode" "$h" >"$stdout_file" 2>&1; then
        cat "$stdout_file"; fail "overlays_$mode (nonzero exit)"
    fi
    if diff -u "tests/studio/overlays_$mode.out" "$stdout_file"; then
        printf 'PASS overlays_%s\n' "$mode"
    else
        fail "overlays_$mode (output diff)"
    fi
}
for m in project scope conflict gone persist; do
    run_overlays "$m"
done

# An overlay is stored in Studio metadata and materialized for a run; it is
# never a second visible .bas and never a git ref (§2.1, §2.3). Checked against
# the source, because the failure would be a shadow file nobody noticed adding.
if grep -nE '"git"|git branch|git checkout|refs/heads|\.bas"' lib/studio_overlays.bas; then
    fail "overlays_not_files (the overlay model reaches for git or writes a .bas)"
fi
printf 'PASS overlays_not_files (no git ref, no shadow .bas)\n'

# ==========================================================================
# STU-8 — library-registered rich viewers. Sidecar discovery, validation,
# descriptor matching, specificity and rendering. Declarative JSON in, display
# lines out: no GTK, no child process, no display, and nothing evaluated.
VIEW=tests/drivers/viewers.bas
run_viewers() { # mode
    local mode="$1" h
    h="$tmproot/vw_$mode"
    rm -rf "$h"; mkdir -p "$h"
    : >"$stdout_file"
    if ! timeout 60 "$GBASIC" "$VIEW" "$mode" "$h" >"$stdout_file" 2>&1; then
        cat "$stdout_file"; fail "viewers_$mode (nonzero exit)"
    fi
    if diff -u "tests/studio/viewers_$mode.out" "$stdout_file"; then
        printf 'PASS viewers_%s\n' "$mode"
    else
        fail "viewers_$mode (output diff)"
    fi
}
for m in registry match render problems precedence; do
    run_viewers "$m"
done

# The registration convention is DECLARATIVE (design Q11, boundary §6.2). A sidecar
# is read, never run: if the registry ever grew a way to execute what a library
# ships, a viewer file would be arbitrary code with Studio's privileges, and the
# core language would have acquired display semantics by the back door.
if grep -nE 'process\.start|\beval\b|load *\(' lib/studio_viewers.bas; then
    fail "viewers_declarative (the registry executes something)"
fi
printf 'PASS viewers_declarative (sidecars are read, never run)\n'

# ==========================================================================
# STU-15 — the template registry: declared text with holes in it. Headless and
# over a temp directory; the `ship` tier reads what Studio actually installs
# under share/templates/, because a registry whose only data is a fixture is a
# registry nothing depends on.
TPL=tests/drivers/templates.bas
run_templates() { # mode
    local mode="$1" h
    h="$tmproot/tpl_$mode"
    rm -rf "$h"; mkdir -p "$h"
    : >"$stdout_file"
    if ! timeout 60 "$GBASIC" "$TPL" "$mode" "$h" >"$stdout_file" 2>&1; then
        cat "$stdout_file"; fail "templates_$mode (nonzero exit)"
    fi
    if diff -u "tests/studio/templates_$mode.out" "$stdout_file"; then
        printf 'PASS templates_%s\n' "$mode"
    else
        fail "templates_$mode (output diff)"
    fi
}
for m in load from render path ship; do
    run_templates "$m"
done

# A template is DECLARED, exactly as a viewer sidecar is, and for exactly the
# same reason: a file somebody can drop into a templates directory must not be
# able to run anything. Substitution is text, never evaluation -- there are no
# expressions, no conditionals and no loops, and adding any of them would make
# this a language rather than a placeholder.
if grep -nE 'process\.start|\beval\b|load *\(' lib/studio_templates.bas; then
    fail "templates_declarative (the registry executes something)"
fi
printf 'PASS templates_declarative (templates are filled, never run)\n'

# ==========================================================================
# STU-8 — the tabular tier. What gets a table affordance, where its rows come
# from, and the virtualization claim MEASURED rather than asserted. Headless;
# the `model` tier additionally needs the native GListModel adapter, which is
# behind gio-2.0 and skips cleanly without it.
TBL=tests/drivers/table.bas
run_table() { # mode
    local mode="$1" h
    h="$tmproot/tb_$mode"
    rm -rf "$h"; mkdir -p "$h"
    : >"$stdout_file"
    if ! timeout 120 "$GBASIC" "$TBL" "$mode" "$h" >"$stdout_file" 2>&1; then
        cat "$stdout_file"; fail "table_$mode (nonzero exit)"
    fi
    if diff -u "tests/studio/table_$mode.out" "$stdout_file"; then
        printf 'PASS table_%s\n' "$mode"
    else
        fail "table_$mode (output diff)"
    fi
}
for m in tier preview export sort; do
    run_table "$m"
done
if timeout 30 "$GBASIC" tests/drivers/have_rowmodel.bas >/dev/null 2>&1; then
    run_table model
else
    printf 'SKIP table_model (interpreter has no native row-model adapter)\n'
fi

# ==========================================================================
# STU-7 — exploratory branching, state-only. Pure model logic over plain data:
# tree operations, selection, nesting, bindings, staleness and persistence. No
# child process and no display, so it runs everywhere the backbone does.
BRANCH=tests/drivers/branches.bas
run_branch() { # mode
    local mode="$1" h
    h="$tmproot/br_$mode"
    rm -rf "$h"; mkdir -p "$h"
    : >"$stdout_file"
    if ! timeout 60 "$GBASIC" "$BRANCH" "$mode" "$h" >"$stdout_file" 2>&1; then
        cat "$stdout_file"; fail "branches_$mode (nonzero exit)"
    fi
    if diff -u "tests/studio/branches_$mode.out" "$stdout_file"; then
        printf 'PASS branches_%s\n' "$mode"
    else
        fail "branches_$mode (output diff)"
    fi
}
for m in tree bindings stale persist; do
    run_branch "$m"
done

# A Studio branch is NOT a Git branch (design §2.3): not stored as one, not
# surfaced as one, not created as one. Checked against the source, because the
# failure would be a `git` invocation nobody noticed adding.
if grep -nE '"git"|git branch|git checkout|refs/heads' lib/studio_branches.bas; then
    fail "branches_not_git (the branch model reaches for git)"
fi
printf 'PASS branches_not_git (no git ref is created, stored or surfaced)\n'

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
# `drafts` joined this list when unsaved buffers started surviving a close.
grep -q '^saved=settings,session,drafts$' "$stdout_file" || { cat "$stdout_file"; fail "stu1_build (saved line)"; }
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

# 11. A home written before the workspace was demoted: its projects lived in
#     workspaces/<id>.json with session.json only pointing at it. They must come
#     back, and the old file must still be there afterwards — until the first
#     clean save it is the ONLY copy of that state.
run_golden "stu1_migrate" stu1_migrate "$tmproot/mig" tests/studio/stu1_migrate.out

# 12. Memory — 50 STU-1 launch/persist cycles under valgrind.
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
for m in sql derive cursor cursor_pos prog insert_blank internal rename sibling duplicate delete invalid persist multidoc unicode repeated; do
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

# STU-14: the SQL statement scanner. It is the foundation the `.sql` document
# type sits on -- split wrongly and every cell boundary, result and stable id is
# filed against the wrong text -- and it needs no fixture at all.
SQLD=tests/drivers/sql.bas
for m in scan edges verbs gen catalog; do
    : >"$stdout_file"
    if ! timeout 60 "$GBASIC" "$SQLD" "$m" >"$stdout_file" 2>&1; then
        cat "$stdout_file"; fail "sql_$m (nonzero exit)"
    fi
    if diff -u "tests/studio/sql_$m.out" "$stdout_file"; then
        printf 'PASS sql_%s\n' "$m"
    else
        fail "sql_$m (output diff)"
    fi
done

for m in sqlconn rows open expand project bounds tabs edit save newproj refresh \
         newfile newfolder adopt exit \
         names rename delete closetab notice \
         run runstop runerr runrefuse badsyntax filetypes projfile projpin newproj2 panes context menus settings projtabs anchors cursor drafts branch table overlay overlay_conflict; do
    run_ui "$m"
done

# THE QT SHELL, AS DATA -- and the first tier in this suite that asserts the
# window's STRUCTURE rather than its text.
#
# Under GTK that was impossible: `studio_shell.build` decides what the window is
# while it makes a hundred widgets, so the layout could only be asserted by
# opening one -- which is why every `ui_gui*` tier skips without a display, and
# why not one of them can see a pane in the wrong place. `studio_shell_qt`
# returns a record instead, so the whole shape is a string and these two tiers
# need no display, no Qt and no toolkit of any kind.
QTSH=tests/drivers/qtshell.bas
for m in shape docs; do
    qh="$tmproot/qtshell_$m"; qp="$tmproot/qtshell_${m}_proj"
    rm -rf "$qh" "$qp"; mkdir -p "$qh"
    mkproj_ui "$qp"
    : >"$stdout_file"
    if ! timeout 60 "$GBASIC" "$QTSH" "$m" "$qh" "$qp" >"$stdout_file" 2>&1; then
        cat "$stdout_file"; fail "qtshell_$m (nonzero exit)"
    fi
    if diff -u "tests/studio/qtshell_$m.out" "$stdout_file"; then
        printf 'PASS qtshell_%s\n' "$m"
    else
        fail "qtshell_$m (output diff)"
    fi
done

# gBASIC'S OWN VALIDATOR, over the record this shell builds.
#
# `qt.check` needs no Qt and no display -- it is a check on a DECLARATION, and
# upstream deliberately put it outside the `#if HAVE_QT` guard for that reason.
# But the `qt` MODULE still has to be in the build, which is a build option like
# sqlite, so it is probed rather than assumed: a missing module would fail as
# "the window is malformed" and send someone looking in Studio.
#
# This is the tier that catches what a shape golden cannot -- a part with no
# name, two parts sharing one, a word that is not a widget, a split with no
# direction, an `item` somewhere things are laid out. It RAISES rather than
# answering false, so a malformed window is a nonzero exit here.
qtprobe="$tmproot/qt_probe.bas"
printf 'program main(args)\n  print qt.check({ kind: "window", name: "w", options: {}, items: [] })\nend program\n' > "$qtprobe"
if GBASIC_PATH="$GBASIC_STDLIB" timeout 60 "$GBASIC" "$qtprobe" >/dev/null 2>&1; then
    qh="$tmproot/qtshell_check"; qp="$tmproot/qtshell_check_proj"
    rm -rf "$qh" "$qp"; mkdir -p "$qh"
    mkproj_ui "$qp"
    : >"$stdout_file"
    if ! timeout 60 "$GBASIC" "$QTSH" check "$qh" "$qp" >"$stdout_file" 2>&1; then
        cat "$stdout_file"; fail "qtshell_check (nonzero exit)"
    fi
    if diff -u tests/studio/qtshell_check.out "$stdout_file"; then
        printf 'PASS qtshell_check (gBASIC validates the window with no display)\n'
    else
        fail "qtshell_check (output diff)"
    fi

    # AND THE WINDOW REALLY OPENS, with nothing on the screen.
    #
    # This is what retires the `ui_gui*` tiers, and it is strictly better than
    # what it replaces. Those need GTK 4 AND a display, and they assert TEXT --
    # they cannot see a pane in the wrong place, which is why every defect in
    # CLAUDE.md's browser and run-strip sections was found by taking a
    # screenshot. `QT_QPA_PLATFORM=offscreen` needs no display and no
    # compositor, so the window is built for real and asked about its own
    # LAYOUT: the three splits report their nesting from the widget tree,
    # walking up from a part, which is the one check a remembered position
    # would agree with while being wrong.
    #
    # No pixel is asserted. Qt re-proportions a splitter against its
    # allocation (upstream measured 260/540 of an 800-wide splitter coming
    # back 252/522), so the sizes are asserted as "it took them" and the
    # nesting carries the structure.
    #
    # GBASIC_SYNTAX_PATH points at the repository's Kate definition. A
    # definition the user installed in their own home SHADOWS it and reports
    # the identical language name, which is why the golden holds the language
    # and never the file.
    # EVERY Qt TIER KEEPS ITS STDERR, and SKIPS ONLY ON gBASIC'S OWN WORDS for
    # a build without Qt. The old rule skipped whenever `qt.` was missing from
    # STDOUT -- so a tier whose mode raised on stderr reported "this gBASIC has
    # no Qt backend" about a build that plainly had one. Found when three tiers
    # skipped beside three that passed on the same binary, hiding a stale
    # `tables_body` read.
    qt_err="$tmproot/qt_tier.err"
    : >"$qt_err"
    qh="$tmproot/qtshell_open"; qp="$tmproot/qtshell_open_proj"
    rm -rf "$qh" "$qp"; mkdir -p "$qh"
    mkproj_ui "$qp"
    : >"$stdout_file"
    if QT_QPA_PLATFORM=offscreen \
            GBASIC_SYNTAX_PATH="${GBASIC_SYNTAX_PATH:-$(dirname "$GBASIC_STDLIB")/editors/kate}" \
            timeout 120 "$GBASIC" "$QTSH" open "$qh" "$qp" \
            >"$stdout_file" 2>"$qt_err"; then
        if diff -u tests/studio/qtshell_open.out "$stdout_file"; then
            printf 'PASS qtshell_open (the whole window built and read back, with no display)\n'
        else
            fail "qtshell_open (output diff)"
        fi
    else
        if ! grep -q 'Qt support is not available' "$qt_err"; then
            cat "$stdout_file" "$qt_err"; fail "qtshell_open (nonzero exit)"
        else
            printf 'SKIP qtshell_open (this gBASIC has no Qt backend)\n'
        fi
    fi

    # THE NOTEBOOK, which was the one thing the Qt vocabulary could not express
    # until gBASIC built `qt.refresh(win, name, items)` for it (its §0.27, from
    # Studio's own measurements).
    #
    # THE LOAD-BEARING CHECK IS THAT A KEPT EDITOR STILL HOLDS WHAT WAS TYPED
    # INTO IT. Everything else in this tier passes on a reconcile that is a
    # rebuild dressed up -- the captions right, the count right, and every
    # unsaved buffer in the window thrown away. It also pins the thing that
    # made the first attempt fail: a built `tab` must carry a NAME, because
    # Studio's captions are what moves and a tab keyed on its caption is
    # rebuilt the moment the unsaved marker appears.
    qh="$tmproot/qtshell_reconcile"; qp="$tmproot/qtshell_reconcile_proj"
    rm -rf "$qh" "$qp"; mkdir -p "$qh"
    mkproj_ui "$qp"
    : >"$stdout_file"
    if QT_QPA_PLATFORM=offscreen \
            GBASIC_SYNTAX_PATH="${GBASIC_SYNTAX_PATH:-$(dirname "$GBASIC_STDLIB")/editors/kate}" \
            timeout 120 "$GBASIC" "$QTSH" reconcile "$qh" "$qp" \
            >"$stdout_file" 2>"$qt_err"; then
        if diff -u tests/studio/qtshell_reconcile.out "$stdout_file"; then
            printf 'PASS qtshell_reconcile (a tab set grew, a caption moved, and the editor kept its text)\n'
        else
            fail "qtshell_reconcile (output diff)"
        fi
    else
        if ! grep -q 'Qt support is not available' "$qt_err"; then
            cat "$stdout_file" "$qt_err"; fail "qtshell_reconcile (nonzero exit)"
        else
            printf 'SKIP qtshell_reconcile (this gBASIC has no Qt backend)\n'
        fi
    fi
else
    printf 'SKIP qtshell_check (this gBASIC has no qt module)\n'
    printf 'SKIP qtshell_open (this gBASIC has no qt module)\n'
    printf 'SKIP qtshell_reconcile (this gBASIC has no qt module)\n'
fi

# THE QT SHELL, OPENED AND RENDERED FOR REAL, through its own entry point.
#
# `qtshell_open` builds the record and reads it back; this drives the actual
# application: startup over a real home, the window opened, one render filling
# it from the model, then a browser row activated through the same
# `studio_ui.activate_row` a click calls, then an edit in the model. So it
# asserts the RENDERER -- every pane holding what studio_ui says it should --
# and the row model reaching the window, which between them is what the
# `ui_gui*` tiers need a display for.
#
# One tier and not two, because the cold window and the one-document window are
# the same code path with different data, and a tier that only ever sees an
# empty window is the STU-2B dead end wearing a golden.
qtprobe2="$tmproot/qt_probe2.bas"
printf 'program main(args)\n  print qt.check({ kind: "window", name: "w", options: {}, items: [] })\nend program\n' > "$qtprobe2"
if GBASIC_PATH="$GBASIC_STDLIB" timeout 60 "$GBASIC" "$qtprobe2" >/dev/null 2>&1; then
    qh="$tmproot/qtview_probe"; qp="$tmproot/qtview_probe_proj"
    rm -rf "$qh" "$qp"; mkdir -p "$qh"
    mkproj_ui "$qp"
    : >"$stdout_file"
    if QT_QPA_PLATFORM=offscreen \
            GBASIC_SYNTAX_PATH="${GBASIC_SYNTAX_PATH:-$(dirname "$GBASIC_STDLIB")/editors/kate}" \
            timeout 120 "$GBASIC" app/studio.bas probe "$qh" "$qp" \
            >"$stdout_file" 2>"$qt_err"; then
        if diff -u tests/studio/qtview_probe.out "$stdout_file"; then
            printf 'PASS qtview_probe (the Qt application opened, rendered and reacted, with no display)\n'
        else
            fail "qtview_probe (output diff)"
        fi
    else
        if ! grep -q 'Qt support is not available' "$qt_err"; then
            cat "$stdout_file" "$qt_err"; fail "qtview_probe (nonzero exit)"
        else
            printf 'SKIP qtview_probe (this gBASIC has no Qt backend)\n'
        fi
    fi
else
    printf 'SKIP qtview_probe (this gBASIC has no qt module)\n'
    printf 'SKIP qtview_press (this gBASIC has no qt module)\n'
    printf 'SKIP qtview_tables (this gBASIC has no qt module)\n'
    printf 'SKIP qtview_snippet (this gBASIC has no qt module)\n'
    printf 'SKIP qtview_schema (this gBASIC has no qt module)\n'
    printf 'SKIP qtview_branch (this gBASIC has no qt module)\n'
    printf 'SKIP qtview_overlay (this gBASIC has no qt module)\n'
    printf 'SKIP qtview_assistant (this gBASIC has no qt module)\n'
    printf 'SKIP qtview_git (this gBASIC has no qt module)\n'
    printf 'SKIP qtview_run (this gBASIC has no qt module)\n'
    printf 'SKIP qtview_cold (this gBASIC has no qt module)\n'
    printf 'SKIP qtview_open (this gBASIC has no qt module)\n'
    printf 'SKIP qtview_ctx (this gBASIC has no qt module)\n'
    printf 'SKIP qtview_edit (this gBASIC has no qt module)\n'
    printf 'SKIP qtview_reopen (this gBASIC has no qt module)\n'
fi

    # EVERY CONTROL PRESSED, FOR REAL, WITH NO DISPLAY.
    #
    # This is what retires `ui_gui_menus` and `ui_gui_name`, and it is better
    # than what it replaces in one specific way: `qt.invoke(win, item,
    # "trigger")` fires a QAction the way a person does, where a `Gtk.Button`
    # inside a popover that has never been shown silently ignores `activate()`
    # -- which cost STU-16 two rounds and is why the GTK tier has to pop each
    # menu up first.
    #
    # It presses sixteen menu items, the Save button and the run strip, selects
    # browser rows, arms and confirms a Delete, walks the zoom ladder, and
    # checks that a repeat press of the current theme answers `theme-same`
    # rather than reporting work that did not happen.
    qh="$tmproot/qtview_press"; qp="$tmproot/qtview_press_proj"
    rm -rf "$qh" "$qp"; mkdir -p "$qh"
    mkproj_ui "$qp"
    : >"$stdout_file"
    if QT_QPA_PLATFORM=offscreen \
            GBASIC_SYNTAX_PATH="${GBASIC_SYNTAX_PATH:-$(dirname "$GBASIC_STDLIB")/editors/kate}" \
            timeout 120 "$GBASIC" app/studio.bas press "$qh" "$qp" \
            >"$stdout_file" 2>"$qt_err"; then
        if diff -u tests/studio/qtview_press.out "$stdout_file"; then
            printf 'PASS qtview_press (every control pressed for real, with no display)\n'
        else
            fail "qtview_press (output diff)"
        fi
    else
        if ! grep -q 'Qt support is not available' "$qt_err"; then
            cat "$stdout_file" "$qt_err"; fail "qtview_press (nonzero exit)"
        else
            printf 'SKIP qtview_press (this gBASIC has no Qt backend)\n'
        fi
    fi

    # THE TABLES PANE AND THE GRID WINDOW (STU-8 under Qt).
    #
    # The run keeps a 50-row SAMPLE of 1,200 records, so the first open is a
    # sample that says so; Fetch re-runs the section and the second open is the
    # whole table. It reads CELLS back -- first and last row, every column --
    # because a wrong column mapping or a row offset shows plausible text under
    # the wrong heading, and the fixture's own numbering is what exposes that.
    #
    # STDERR IS CHECKED, not discarded: a raise inside a Qt handler abandons the
    # handler and the process still exits 0 (CLAUDE.md, the tab menu), so a
    # handler that died would otherwise read as a golden that merely moved.
    qh="$tmproot/qtview_tables"; qp="$tmproot/qtview_tables_proj"
    rm -rf "$qh" "$qp"; mkdir -p "$qh" "$qp"
    printf 'rows = []\nn = 0\nwhile n < 1200\n  rows = append(rows, { id: n, name: "row " + n, score: n * 1.5 })\n  n = n + 1\nend while\nprint "built " + count(rows)\n' \
        > "$qp/tabular.bas"
    : >"$stdout_file"
    if QT_QPA_PLATFORM=offscreen \
            GBASIC_SYNTAX_PATH="${GBASIC_SYNTAX_PATH:-$(dirname "$GBASIC_STDLIB")/editors/kate}" \
            timeout 120 "$GBASIC" app/studio.bas tables "$qh" "$qp" \
            >"$stdout_file" 2>"$qt_err"; then
        if grep -q 'runtime error' "$qt_err"; then
            grep 'runtime error' "$qt_err"; fail "qtview_tables (a handler raised)"
        fi
        if diff -u tests/studio/qtview_tables.out "$stdout_file"; then
            printf 'PASS qtview_tables (the Tables pane opens a grid, sample then fetched)\n'
        else
            fail "qtview_tables (output diff)"
        fi
    else
        if ! grep -q 'Qt support is not available' "$qt_err"; then
            cat "$stdout_file" "$qt_err"; fail "qtview_tables (nonzero exit)"
        else
            printf 'SKIP qtview_tables (this gBASIC has no Qt backend)\n'
        fi
    fi

    # ONE RUNNER FOR A Qt MODE that drives a feature end to end: a fixture the
    # caller built, the mode run once under offscreen, STDERR KEPT -- a raise in
    # a handler exits 0, so `runtime error` there fails the tier -- and a skip
    # only on gBASIC's own words for a build without Qt.
    qt_mode_tier() { # tier mode home proj description [more args for the mode]
        local tier="$1" mode="$2" home="$3" proj="$4" what="$5"
        shift 5
        : >"$stdout_file"; : >"$qt_err"
        # NO PROVIDER KEY reaches a Qt mode: the assistant's "not configured"
        # sentence must not depend on who runs the suite, and nothing else here
        # needs one.
        if env -u ANTHROPIC_API_KEY -u OPENAI_API_KEY -u GBASIC_STUDIO_SECRET_KEY \
                QT_QPA_PLATFORM=offscreen \
                GBASIC_SYNTAX_PATH="${GBASIC_SYNTAX_PATH:-$(dirname "$GBASIC_STDLIB")/editors/kate}" \
                timeout 120 "$GBASIC" app/studio.bas "$mode" "$home" "$proj" "$@" \
                >"$stdout_file" 2>"$qt_err"; then
            if grep -q 'runtime error' "$qt_err"; then
                grep 'runtime error' "$qt_err"; fail "$tier (a handler raised)"
            elif diff -u "tests/studio/$tier.out" "$stdout_file"; then
                printf 'PASS %s (%s)\n' "$tier" "$what"
            else
                fail "$tier (output diff)"
            fi
        elif grep -q 'Qt support is not available' "$qt_err"; then
            printf 'SKIP %s (this gBASIC has no Qt backend)\n' "$tier"
        else
            cat "$stdout_file" "$qt_err"; fail "$tier (nonzero exit)"
        fi
    }

    # INSERT SQL… under Qt (STU-15): the GTK `ui_gui_snippet` script, against
    # the same fixture. No database: nothing is run.
    qh="$tmproot/qtview_snippet"; qp="$tmproot/qtview_snippet_proj"
    rm -rf "$qh" "$qp"; mkdir -p "$qh"; mkproj_ui "$qp"
    printf -- '-- @database prod\n\nselect 1;\n' > "$qp/work.sql"
    printf '{"schema_version":1,"id":"gsp-1-1","databases":{"prod":{"driver":"pg","host":"db.example","database":"acme","user":"matthew"}}}\n' > "$qp/.gstudio.json"
    qt_mode_tier qtview_snippet snippet "$qh" "$qp" "a snippet picked, refused, filled and inserted"

    # SCHEMA… under Qt (STU-17): the GTK `ui_gui_schema` script against the
    # same SQLite fixture, probed for the sqlite module like that tier.
    qt_sqlprobe="$tmproot/sqlite_probe_qt.bas"
    printf 'load sqlite\nprogram main(args)\n  print "yes"\nend program\n' > "$qt_sqlprobe"
    if GBASIC_PATH="$GBASIC_STDLIB" timeout 60 "$GBASIC" "$qt_sqlprobe" >/dev/null 2>&1; then
        qh="$tmproot/qtview_schema"; qp="$tmproot/qtview_schema_proj"
        rm -rf "$qh" "$qp"; mkdir -p "$qh" "$qp/data"
        printf '{"schema_version":1,"id":"gsp-1-1","databases":{"app":{"driver":"sqlite","path":"data/app.db"}}}' > "$qp/.gstudio.json"
        printf -- '-- @database app\n\nselect 1;\n' > "$qp/work.sql"
        mkdb="$tmproot/mkdb_qt.bas"
        printf 'load sqlite\nprogram main(args)\n  db = sqlite.connect(args[0])\n  r = sqlite.exec(db, "create table customers (id integer primary key, name text not null, note text)", [])\n  r = sqlite.exec(db, "create table orders (id integer primary key, customer_id integer, total real)", [])\n  r = sqlite.exec(db, "create view big_orders as select * from orders where total > 100", [])\n  sqlite.close(db)\nend program\n' > "$mkdb"
        if ! GBASIC_PATH="$GBASIC_STDLIB" timeout 60 "$GBASIC" "$mkdb" "$qp/data/app.db" >/dev/null 2>&1; then
            fail "qtview_schema (could not build the fixture database)"
        fi
        qt_mode_tier qtview_schema schema "$qh" "$qp" "a catalog read shown, picked and inserted"
    else
        printf 'SKIP qtview_schema (this gBASIC has no sqlite module)\n'
    fi

    # BRANCHES, BIND AND THE OVERLAY STRIP under Qt (STU-7, STU-9): the GTK
    # `ui_gui_branch` and `ui_gui_overlay` scripts against their fixture. The
    # overlay tier's load-bearing pair is the source editor showing the FILE
    # while the branch runs the overlay, and the overlay only once promoted.
    for bm in branch overlay; do
        qh="$tmproot/qtview_$bm"; qp="$tmproot/qtview_${bm}_proj"
        rm -rf "$qh" "$qp"; mkdir -p "$qh" "$qp"
        printf 'threshold = 0.5\n\nfunction score(t)\n  return t * 100\nend function\n\nprint "score is " + score(threshold)\n' \
            > "$qp/branchy.bas"
        qt_mode_tier "qtview_$bm" "$bm" "$qh" "$qp" "the $bm controls pressed for real"
    done

    # THE ASSISTANT AND ITS TEACHING under Qt (STU-6, STU-10): "not configured"
    # with no key, a wrapper for every read tool, a scripted provider that
    # calls a tool, every teachable name resolving, and all five gestures.
    qh="$tmproot/qtview_assistant"; qp="$tmproot/qtview_assistant_proj"
    rm -rf "$qh" "$qp"; mkdir -p "$qh"; mkproj_ui "$qp"
    qt_mode_tier qtview_assistant assistant "$qh" "$qp" "Where was I? answered offline, and every cue drawn"

    # GIT under Qt (STU-11): the pane hidden outside a repository and the
    # summary inside one -- the retired `ui_gui_git` script, which was retired
    # with no Qt counterpart and found the Qt pane wrong when it was written.
    if command -v git >/dev/null 2>&1; then
        qh="$tmproot/qtview_git"; qp="$tmproot/qtview_git_proj"; qr="$tmproot/qtview_git_repo"
        rm -rf "$qh" "$qp" "$qr"; mkdir -p "$qh" "$qp"
        printf 'print "plain"\n' > "$qp/plain.bas"
        mkgitrepo "$qr"
        qt_mode_tier qtview_git git "$qh" "$qp" "quiet outside a repository, present inside one" "$qr"
    else
        printf 'SKIP qtview_git (git is not installed)\n'
    fi

    # A RUN READ BACK OFF THE WINDOW (the retired ui_gui_run, ui_gui_cursor
    # and results_gui): the strip following the caret, the four output panes
    # and the results pane after a real run, the results pane following the
    # caret, and the stale mark after an edit.
    qh="$tmproot/qtview_run"; qp="$tmproot/qtview_run_proj"
    rm -rf "$qh" "$qp"; mkdir -p "$qh" "$qp"
    printf 'print "first"\n\nfunction add(a, b)\n  return a + b\nend function\n\nprint add(2, 3)\n' > "$qp/run.bas"
    qt_mode_tier qtview_run run "$qh" "$qp" "a run read back off the window, following the caret"

    # A COLD HOME TO A FILE IN THE BROWSER (the retired ui_gui_cold): nothing
    # at all, New Project as the way in. The project argument is EMPTY.
    qh="$tmproot/qtview_cold"
    rm -rf "$qh"; mkdir -p "$qh"
    qt_mode_tier qtview_cold cold "$qh" "" "a cold home reaches a project with a file in it"

    # OPEN FOLDER AND PROJECT FILE (the retired ui_gui_open): a folder opened
    # by typing its path, opened again (activated, not duplicated), given a
    # project file only when asked, and a path that is not there refused. The
    # folder is called `opened` so the golden names it and nothing else.
    qh="$tmproot/qtview_open"; qo="$tmproot/qtview_open_at/opened"
    rm -rf "$qh" "$tmproot/qtview_open_at"; mkdir -p "$qh" "$qo/src"
    printf 'x\n' > "$qo/thing.bas"
    qt_mode_tier qtview_open open "$qh" "" "a folder opened by path, activated, given a project file" "$qo"

    # THE BROWSER MENU ON PROJECT AND FILE ROWS, AND THE HEADER ACTS IT SHARES
    # (the retired ui_gui_ctx, and the rest of ui_gui_name and
    # ui_gui_settings): two projects, a project file added from the
    # NON-active one's row without moving the active project, Delete arming
    # from a file's menu, a header Rename, Close project from its row, and the
    # session toggle. Folders are `alpha` and `beta` so the golden names them.
    qh="$tmproot/qtview_ctx"; qa="$tmproot/qtview_ctx_at"
    rm -rf "$qh" "$qa"; mkdir -p "$qh" "$qa/alpha/src" "$qa/beta"
    printf 'print "main"\n' > "$qa/alpha/main.bas"
    printf 'x\n' > "$qa/alpha/src/a.bas"
    printf 'print "b"\n' > "$qa/beta/b.bas"
    qt_mode_tier qtview_ctx ctx "$qh" "$qa/alpha" "the browser menu acts on the row it was raised on" "$qa/beta"

    # OPEN, SWITCH, TYPE, SAVE (the retired ui_gui and the rest of ui_gui_new):
    # the tab widget's own switch, the unsaved marker on the caption, the
    # toolbar's Save clearing it with the file changed on disk, Reload, and a
    # New Folder landing in the selected directory.
    qh="$tmproot/qtview_edit"; qp="$tmproot/qtview_edit_proj"
    rm -rf "$qh" "$qp"; mkdir -p "$qh"; mkproj_ui "$qp"
    qt_mode_tier qtview_edit edit "$qh" "$qp" "open, switch, type, save -- read back off the tabs"

    # A SECOND LAUNCH OVER A HOME THAT HAS BEEN USED.
    #
    # THIS IS THE TIER WHOSE ABSENCE LET A CRASH SHIP. Every other Qt tier
    # above does `rm -rf "$qh"` first, so all of them were testing a FIRST
    # launch -- and `app.dm` was reaching `app/studio.bas` only as a side
    # effect of `create_registered_workspace`, which runs only when a home has
    # no workspace yet. So an empty home got a document manager by accident and
    # a used one got none: `./studio qt` died with `unknown record field: dm`
    # out of `studio_ui.tab_rows` before the window was built, on every home
    # that had ever been opened before. Thirteen green tiers, none of them
    # looking at the second launch, and the user found it in a minute by
    # opening Studio twice.
    #
    # SO THIS ONE RUNS THE SAME MODE TWICE AGAINST ONE HOME and holds both
    # outputs. The second block is the assertion and the first is what leaves
    # something for it to find; the DIFFERENCE between them is the point --
    # `documents restored: 0` becomes `1`, the title gains the document, and
    # `dark applied` goes from false to true because the setting the first run
    # pressed was written down. A golden holding only one launch could not say
    # any of that.
    qh="$tmproot/qtview_reopen"; qp="$tmproot/qtview_reopen_proj"
    rm -rf "$qh" "$qp"; mkdir -p "$qh"
    mkproj_ui "$qp"
    : >"$stdout_file"
    reopen_ok=yes
    : >"$qt_err"
    for pass in 1 2; do
        printf -- '===== launch %s =====\n' "$pass" >>"$stdout_file"
        if ! QT_QPA_PLATFORM=offscreen \
                GBASIC_SYNTAX_PATH="${GBASIC_SYNTAX_PATH:-$(dirname "$GBASIC_STDLIB")/editors/kate}" \
                timeout 120 "$GBASIC" app/studio.bas reopen "$qh" "$qp" \
                >>"$stdout_file" 2>>"$qt_err"; then
            reopen_ok=no
            break
        fi
    done
    if [ "$reopen_ok" = yes ]; then
        if diff -u tests/studio/qtview_reopen.out "$stdout_file"; then
            printf 'PASS qtview_reopen (a used home opens, and what it kept came back)\n'
        else
            fail "qtview_reopen (output diff)"
        fi
    else
        if ! grep -q 'Qt support is not available' "$qt_err"; then
            cat "$stdout_file" "$qt_err"; fail "qtview_reopen (nonzero exit)"
        else
            printf 'SKIP qtview_reopen (this gBASIC has no Qt backend)\n'
        fi
    fi

# NO GTK ANYWHERE IN STUDIO.
#
# GTK is gone, and nothing may bring it back: not a call into `gi`, `gtk`,
# `sourceeditor` or `datagrid`, and not a `load` of one. EVERY library and
# entry file is scanned, which is stronger than walking the load graph -- a
# file that cannot mention GTK cannot load it transitively for anyone. It was
# two files until GTK went, and that let `studio_style`'s `load gi` reach the
# Qt process through the shell. Not a style point: `gi.new("Gtk.<Widget>")`
# SEGFAULTS before GTK is initialized rather than raising. Comments stripped,
# because these files explain the rule by naming what it forbids.
qtgtk="$tmproot/qt_no_gtk.txt"
for f in lib/*.bas app/*.bas; do sed -e "s/'.*//" "$f" | sed "s#^#$f: #"; done > "$qtgtk"
if grep -nE '(^|[^a-z_])(gi|gtk|sourceeditor|datagrid)\.|load +(gi|gtk|sourceeditor|datagrid)( |$)' "$qtgtk"; then
    fail "qt_no_gtk (Studio reaches GTK)"
fi
if ! grep -q 'studio_view_qt.render' "$qtgtk"; then
    fail "qt_no_gtk (the scanner read nothing)"
fi
printf 'PASS qt_no_gtk (no GTK anywhere in Studio)\n'

# NOTHING IN THE QT SHELL TOUCHES A TOOLKIT, and that is a tripwire rather than
# an intention. One `qt.read` in there would take the two tiers above down on a
# machine with no Qt -- and the whole value of the record is that the shape is
# decidable without one. Comments are stripped first, because this file's own
# header explains the rule by quoting it, which is the trap
# `run_libcurl_floor.sh` records for `smtp.c`.
qtpure="$tmproot/qt_shell_pure.txt"
sed -e "s/'.*//" lib/studio_shell_qt.bas > "$qtpure"
if grep -nE '(^|[^a-z_])(qt|gi|gtk|sourceeditor|datagrid)\.' "$qtpure"; then
    fail "qt_shell_pure (studio_shell_qt reaches a toolkit)"
fi
# ... and the control, because a scanner that reads nothing passes everything.
if ! grep -q 'window_for' "$qtpure"; then
    fail "qt_shell_pure (the scanner read nothing)"
fi
printf 'PASS qt_shell_pure (the Qt shell is a pure function over the model)\n'

# STU-14: a .sql cell run end to end, against a REAL SQLite file. Its own tier
# because it needs something the others do not -- an interpreter with the sqlite
# module compiled in, which is a build option and not a given. Probed rather
# than assumed: a missing module would otherwise fail as "the cell did not run"
# and send someone looking in Studio.
sqlprobe="$tmproot/sqlite_probe.bas"
printf 'load sqlite\nprogram main(args)\n  print "yes"\nend program\n' > "$sqlprobe"
if GBASIC_PATH="$GBASIC_STDLIB" timeout 60 "$GBASIC" "$sqlprobe" >/dev/null 2>&1; then
    run_ui sqlrun
    # STU-17: the schema browser, behind the SAME probe. It builds its tables
    # by RUNNING SQL through Studio and then reads them back through the
    # catalog, so what it finds is what a run put there -- and the generated
    # program it asserts is the one on disk, password-free.
    run_ui schema
else
    printf 'SKIP ui_sqlrun (this gBASIC has no sqlite module)\n'
    printf 'SKIP ui_schema (this gBASIC has no sqlite module)\n'
fi

# STU-15: the snippet builder. Needs no database and no probe -- a builder
# WRITES the statement into the file and never runs it, which is the design
# showing through the test: there is nothing to connect to.
run_ui snippets

# Where a database password comes from. Two of its cases read the ENCRYPTED
# store, and `crypto` is behind HAVE_LIBCRYPTO -- a build without it answers
# "unusable" where this golden says "ready", so it is probed rather than
# assumed. `GBSTUDIO_TEST_DBPASS` is the environment variable one case's
# `.gstudio.json` NAMES; it is exported here because a program cannot put a
# variable into the environment of the process it is already running in.
cryptoprobe="$tmproot/crypto_probe.bas"
printf 'program main(args)\n  load studio_secrets\n  if studio_secrets.available() then\n    print "yes"\n  else\n    print to error "no"\n  end if\nend program\n' > "$cryptoprobe"
if GBASIC_PATH="lib:$GBASIC_STDLIB" timeout 60 "$GBASIC" "$cryptoprobe" 2>/dev/null | grep -q yes; then
    GBSTUDIO_TEST_DBPASS=from-the-environment run_ui sqlcred
else
    printf 'SKIP ui_sqlcred (this gBASIC cannot encrypt)\n'
fi

# ODBC end to end, through the SQLite3 driver -- which is what gBASIC's own
# odbc cookbook uses, and for the same reason: it runs anywhere and nothing
# about the code's shape is SQLite-specific. This is the only tier that proves
# the credential path WHOLE: the password is in the encrypted store, Studio
# hands it to the child in its environment, and the generated program on disk
# carries `env("...")` and not the value.
odbcprobe="$tmproot/odbc_probe.bas"
printf 'load odbc\nprogram main(args)\n  for each d in odbc.drivers()\n    if d.name = "SQLite3" then\n      print "yes"\n    end if\n  next\nend program\n' > "$odbcprobe"
if GBASIC_PATH="$GBASIC_STDLIB" timeout 60 "$GBASIC" "$odbcprobe" 2>/dev/null | grep -q yes; then
    run_ui sqlodbc
else
    printf 'SKIP ui_sqlodbc (no odbc module, or no SQLite3 ODBC driver installed)\n'
fi

# PostgreSQL end to end -- OPT-IN, and deliberately so. Every other tier here
# builds what it needs in a temp directory and takes it away again; this one
# connects to a database SERVER that belongs to somebody. A suite that did that
# because it found a socket open is not one to trust, so the connection has to
# be NAMED before this runs at all:
#
#   GBASIC_STUDIO_TEST_PG='{"driver":"pg","host":"/var/run/postgresql","database":"postgres","user":"me"}' tests/run_studio.sh
#
# It uses TEMP tables, so it needs no privilege beyond connecting and leaves
# nothing behind -- and a `select` in the third cell finding the second cell's
# rows is what proves the run shared ONE connection.
if [ -n "${GBASIC_STUDIO_TEST_PG:-}" ]; then
    run_ui sqlpg
else
    printf 'SKIP ui_sqlpg (set GBASIC_STUDIO_TEST_PG to a databases entry to run it)\n'
fi

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


printf 'run_studio: all cases passed\n'
