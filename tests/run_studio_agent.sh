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

# STU-10 provider selection (§15) and the ACTING agent loop. Offline: the
# transport is a function, so a scripted provider drives real tool calls against
# a real app and the tests assert what Studio actually did.
#
# ANTHROPIC_API_KEY / OPENAI_API_KEY are UNSET for these: the provider summary
# reports where a key came from, so a developer with one exported would see a
# different answer than CI and the golden would be about the machine.
LOOP=tests/drivers/actloop.bas
for m in providers acting gated; do
    h="$tmproot/loop_$m"; pj="$tmproot/loop_${m}_proj"
    rm -rf "$h" "$pj"; mkdir -p "$h" "$pj"
    : >"$stdout_file"
    if ! timeout 60 env -u ANTHROPIC_API_KEY -u OPENAI_API_KEY \
            "$GBASIC" "$LOOP" "$m" "$h" "$pj" >"$stdout_file" 2>/dev/null; then
        cat "$stdout_file"; fail "actloop_$m (nonzero exit)"
    fi
    if diff -u "tests/studio/actloop_$m.out" "$stdout_file"; then
        printf 'PASS actloop_%s\n' "$m"
    else
        fail "actloop_$m (output diff)"
    fi
done

# STU-10 secrets (§16, design Q13). The property is a NEGATIVE one -- that a
# secret is not on disk in the clear -- so the tests read the actual file and
# look for it.
#
# The store SKIPs, rather than failing, on an interpreter built without
# libcrypto: aes_gcm sits behind HAVE_LIBCRYPTO, and a build without it is a
# build where the honest behaviour is to refuse to store anything at all.
SEC=tests/drivers/secrets.bas
if "$GBASIC" tests/drivers/have_crypto.bas >/dev/null 2>&1; then
    for m in roundtrip onhurt refusals redact; do
        h="$tmproot/sec_$m"
        rm -rf "$h"; mkdir -p "$h"
        : >"$stdout_file"
        if ! timeout 60 "$GBASIC" "$SEC" "$m" "$h" >"$stdout_file" 2>/dev/null; then
            cat "$stdout_file"; fail "secrets_$m (nonzero exit)"
        fi
        if diff -u "tests/studio/secrets_$m.out" "$stdout_file"; then
            printf 'PASS secrets_%s\n' "$m"
        else
            fail "secrets_$m (output diff)"
        fi
    done
else
    printf 'SKIP secrets_* (this gBASIC was built without libcrypto)\n'
fi

# A key must never be written to disk by Studio. The store is ciphertext beside
# nothing that opens it; a key file next to its own lock protects against almost
# nothing, and writing one would let this claim to be encrypted while being, in
# practice, obfuscated.
# Matches a WRITE whose target is a key, or any literal .key path -- not merely
# the word "key", which appears in key_from_hex, key_bytes and key_var and made
# the first version of this fail on its own source.
if grep -nE 'write[[:space:]]*\([[:space:]]*[a-z_]*key|"[^"]*\.key"|key_path[[:space:]]*\(' lib/studio_secrets.bas; then
    fail "secrets_no_key_file (the store writes a key)"
fi
printf 'PASS secrets_no_key_file (the key comes from the environment and is never stored)\n'

# STU-10 teaching (§13): which widgets an agent may point at, which gestures each
# can perform, and the refusals — all plain data, no display.
TEACH=tests/drivers/teach.bas
for m in widgets cues ranges css; do
    : >"$stdout_file"
    if ! timeout 60 "$GBASIC" "$TEACH" "$m" >"$stdout_file" 2>&1; then
        cat "$stdout_file"; fail "teach_$m (nonzero exit)"
    fi
    if diff -u "tests/studio/teach_$m.out" "$stdout_file"; then
        printf 'PASS teach_%s\n' "$m"
    else
        fail "teach_$m (output diff)"
    fi
done

# The set an agent is TOLD it may point at and the set the window can actually
# resolve must be the same set. They live in two files and nothing but this keeps
# them together; a registry entry the shell cannot find is a teaching request that
# reports success and draws nothing.
if "$GBASIC" tests/drivers/widgetcheck.bas; then
    printf 'PASS agent_widgets (the teachable set is the same in both files)\n'
else
    fail "agent_widgets (the registry and the shell disagree)"
fi

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
# studio_providers is DELIBERATELY excluded: naming providers is its whole job.
# What must stay true is that the agent LOOP does not know about one -- the
# handle is built by the caller and injected, which is what makes every test on
# this page runnable with no network and no key.
if grep -nE 'https?://|api_key|ANTHROPIC_API_KEY|OPENAI_API_KEY' lib/studio_agent.bas lib/studio_tools.bas lib/studio_history.bas; then
    fail "agent_offline (the agent path hardcodes a provider or a key)"
fi
printf 'PASS agent_offline (no provider, url or key in the agent path)\n'

printf 'run_studio_agent: all cases passed\n'
