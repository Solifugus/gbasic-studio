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

# The claim that matters most, checked against the source rather than the
# behaviour: there is no write tool to permit, forbid or get wrong. If one is
# ever added, this fails until someone decides deliberately that STU-6 is over.
if grep -nE '\b(write|save|delete|create|rename|run_section|edit)_' lib/studio_tools.bas \
        | grep -v '^\s*[0-9]*:\s*'"'" | grep -q 'name: "'; then
    grep -nE 'name: "' lib/studio_tools.bas
    fail "agent_readonly (a tool name suggests a write)"
fi
printf 'PASS agent_readonly (no write tool exists to be refused)\n'

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
