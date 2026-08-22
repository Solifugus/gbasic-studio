#!/usr/bin/env bash
# gBASIC Studio — STU-6 agent suite (docs/gbasic_studio_plan.md, STU-6).
#
# FULLY OFFLINE and GI-INDEPENDENT. The provider is a scripted transport
# (llm.with_transport), so nothing here touches the network, needs an API key, or
# needs a display. That is not a convenience: an agent test that called a real
# provider would be neither deterministic nor a test.
#
# Separate from run_studio.sh because it is a separate claim — the backbone suite
# says Studio works, this one says the agent can only look.
set -euo pipefail

cd "$(dirname "$0")/.."

GBASIC="${GBASIC:-../gbasic/gbasic}"
export GBASIC
GBASIC_STDLIB="${GBASIC_STDLIB:-../gbasic/stdlib}"
if [ ! -x "$GBASIC" ]; then
    printf 'FAIL run_studio_agent: no gbasic interpreter at %s\n' "$GBASIC"
    exit 1
fi
if [ ! -d "$GBASIC_STDLIB" ]; then
    printf 'FAIL run_studio_agent: no gBASIC stdlib at %s\n' "$GBASIC_STDLIB"
    exit 1
fi

gbasic_dir="$(cd "$(dirname "$GBASIC")" && pwd)"
if [ -f "$gbasic_dir/Makefile" ]; then
    if ! (cd "$gbasic_dir" && make >/dev/null); then
        printf 'FAIL run_studio_agent: gbasic build failed in %s\n' "$gbasic_dir"
        exit 1
    fi
fi

export GBASIC_PATH="lib:$GBASIC_STDLIB"
AGENT=tests/drivers/agent.bas

tmproot="$(mktemp -d)"
stdout_file="$(mktemp)"
trap 'rm -rf "$tmproot" "$stdout_file"' EXIT

fail() { printf 'FAIL %s\n' "$1"; exit 1; }

run_agent() { # mode
    local mode="$1" home proj
    home="$tmproot/ag_$mode"; proj="$tmproot/ag_${mode}_proj"
    rm -rf "$home" "$proj"; mkdir -p "$home" "$proj"
    : >"$stdout_file"
    if ! timeout 120 "$GBASIC" "$AGENT" "$mode" "$home" "$proj" >"$stdout_file" 2>&1; then
        cat "$stdout_file"; fail "agent_$mode (nonzero exit)"
    fi
    if diff -u "tests/studio/agent_$mode.out" "$stdout_file"; then
        printf 'PASS agent_%s\n' "$mode"
    else
        fail "agent_$mode (output diff)"
    fi
}

for m in history bound tools agent; do
    run_agent "$m"
done

# ==========================================================================
# STU-10 — the permission model, and the act tools it exists to gate.
PERMS=tests/drivers/perms.bas
for m in scopes malformed tokens; do
    : >"$stdout_file"
    if ! timeout 60 "$GBASIC" "$PERMS" "$m" >"$stdout_file" 2>&1; then
        cat "$stdout_file"; fail "perms_$m (nonzero exit)"
    fi
    if diff -u "tests/studio/perms_$m.out" "$stdout_file"; then
        printf 'PASS perms_%s\n' "$m"
    else
        fail "perms_$m (output diff)"
    fi
done

ACTS=tests/drivers/acts.bas
for m in tiers gate task destructive; do
    h="$tmproot/acts_$m"; pj="$tmproot/acts_${m}_proj"
    rm -rf "$h" "$pj"; mkdir -p "$h" "$pj"
    : >"$stdout_file"
    if ! timeout 120 "$GBASIC" "$ACTS" "$m" "$h" "$pj" >"$stdout_file" 2>&1; then
        cat "$stdout_file"; fail "acts_$m (nonzero exit)"
    fi
    if diff -u "tests/studio/acts_$m.out" "$stdout_file"; then
        printf 'PASS acts_%s\n' "$m"
    else
        fail "acts_$m (output diff)"
    fi
done

# STU-6's tripwire asserted there was NO write tool to permit or forbid. STU-10
# ends that deliberately, so the claim it protected has to be replaced rather
# than dropped. Three properties take its place.
#
# 1. EVERY act tool declares a tier. A tool with no tier is a tool nothing
#    gates -- and `tier_of` would call it `read`, which for a write is the
#    worst possible default.
if "$GBASIC" tests/drivers/tiercheck.bas; then
    printf 'PASS agent_tiered (every act tool declares a permission tier)\n'
else
    fail "agent_tiered (an act tool has no tier)"
fi

# 2. PARITY BY CONSTRUCTION (design §12): an act tool performs the same semantic
#    operation the window does, by calling studio_ui. If `_perform` ever reaches
#    past it into the model or the filesystem, the agent has a second automation
#    path and "the Agent can do what the user can do" stops being structural.
if sed -n '/function _perform/,/^    end function/p' lib/studio_tools.bas \
        | grep -nE 'studio_docs\.(edit|save|close|create)|studio_model\.|studio\.(open_file|edit_document|close_document)|\b(write|remove|move|copy)\s*\(' ; then
    fail "agent_parity (an act tool reaches past studio_ui)"
fi
printf 'PASS agent_parity (every act calls the same studio_ui operation the window does)\n'

# 3. ONE GATE. Every act reaches the world through `invoke`, which decides
#    permission before dispatching. `call` -- the read path -- must refuse an act
#    outright rather than quietly performing it ungated.
if ! grep -q 'if studio_tools.is_act(name) then' lib/studio_tools.bas; then
    fail "agent_one_gate (the read path no longer refuses acts)"
fi
printf 'PASS agent_one_gate (the read path refuses acts; invoke is the only way through)\n'

# The agent must never evaluate what a model said. `eval`-shaped calls in the
# agent path would be the one way model text could become source.
if grep -nE '\b(eval|load|import)\s*\(' lib/studio_agent.bas lib/studio_tools.bas; then
    fail "agent_no_eval (the agent path can evaluate text)"
fi
printf 'PASS agent_no_eval (model text is never evaluated as source)\n'

# Offline by construction: nothing in the agent path names a transport, a URL or
# a key. The provider handle is built by the CALLER and injected.
if grep -nE 'https?://|api_key|ANTHROPIC_API_KEY|OPENAI_API_KEY' lib/studio_agent.bas lib/studio_tools.bas lib/studio_history.bas; then
    fail "agent_offline (the agent path hardcodes a provider or a key)"
fi
printf 'PASS agent_offline (no provider, url or key in the agent path)\n'

printf 'run_studio_agent: all cases passed\n'
