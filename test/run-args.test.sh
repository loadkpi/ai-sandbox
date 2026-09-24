#!/usr/bin/env bash
#
# Tests for run.sh argument handling — focused on the assembled `docker run`
# invocation, exercised via the AI_SANDBOX_PRINT_ARGS dry-run hook (no Docker
# daemon required).
#
# The real .ai-sandbox/run.sh is copied into a throwaway ROOT so that the
# settings.local.json / codex config it renders do not touch the repo.
#
# Usage: bash test/run-args.test.sh
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pass=0
fail=0
ok()   { printf 'PASS  %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf 'FAIL  %s\n' "$1"; fail=$((fail + 1)); }

# Throwaway sandbox root + fake host ~/.claude.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.ai-sandbox" "$TMP/.claude"
SRC="${AI_SANDBOX_TEST_SRC:-${ROOT}/.ai-sandbox}"   # override to test staged files
cp "${SRC}/run.sh"      "$TMP/.ai-sandbox/run.sh"
cp "${SRC}/versions.env" "$TMP/.ai-sandbox/versions.env"

FAKEH="$TMP/fakehome/.claude"
mkdir -p "$FAKEH/skills" "$FAKEH/agents"   # note: no commands/ dir on purpose
echo '{"oauth":"secret"}' > "$FAKEH/.claude.json"

# run_args <args...> -> prints the dry-run docker invocation
run_args() {
  AI_SANDBOX_PRINT_ARGS=1 AI_SANDBOX_HOST_CLAUDE_DIR="$FAKEH" \
    bash "$TMP/.ai-sandbox/run.sh" "$@" 2>/dev/null
}

# --- default: no host-skill mounts ----------------------------------------
out="$(run_args -- claude)"
grep -q "/home/sandbox/.claude/skills" <<<"$out" && bad "no skills mount without flag" || ok "no skills mount without flag"

# --- --with-host-skills: skills + agents mounted read-only ----------------
out="$(run_args --with-host-skills -- claude)"
grep -q "${FAKEH}/skills:/home/sandbox/.claude/skills:ro" <<<"$out" && ok "skills mounted ro"  || bad "skills mounted ro"
grep -q "${FAKEH}/agents:/home/sandbox/.claude/agents:ro" <<<"$out" && ok "agents mounted ro"  || bad "agents mounted ro"
# commands dir does not exist -> must not be mounted
grep -q "/home/sandbox/.claude/commands" <<<"$out" && bad "absent commands not mounted" || ok "absent commands not mounted"
# credentials must never be mounted
grep -q "claude.json" <<<"$out" && bad "claude.json never mounted" || ok "claude.json never mounted"

# --- offline adds --network=none ------------------------------------------
out="$(run_args --mode offline -- bash)"
grep -q -- "--network=none" <<<"$out" && ok "offline -> --network=none" || bad "offline -> --network=none"

# non-offline must NOT add --network=none
out="$(run_args --mode dev -- bash)"
grep -q -- "--network=none" <<<"$out" && bad "dev has no --network=none" || ok "dev has no --network=none"

# --- read-only rootfs + config mounts always present ----------------------
out="$(run_args -- bash)"
grep -q -- "--read-only" <<<"$out" && ok "rootfs --read-only present" || bad "rootfs --read-only present"
grep -q "settings.local.json:/workspace/.claude/settings.local.json:ro" <<<"$out" \
  && ok "settings.local.json mounted ro" || bad "settings.local.json mounted ro"

# --- validation: unknown mode + missing --mode arg ------------------------
# Capture first (these invocations exit non-zero, which pipefail would otherwise
# conflate with grep's result).
out="$(AI_SANDBOX_PRINT_ARGS=1 bash "$TMP/.ai-sandbox/run.sh" --mode bogus -- bash 2>&1)"
grep -q "Unknown mode" <<<"$out" && ok "unknown mode rejected" || bad "unknown mode rejected"
out="$(AI_SANDBOX_PRINT_ARGS=1 bash "$TMP/.ai-sandbox/run.sh" --mode 2>&1)"
grep -q "requires an argument" <<<"$out" && ok "--mode without arg rejected" || bad "--mode without arg rejected"

# --- Codex config: model + approval policy --------------------------------
CODEX_CFG="$TMP/.ai-sandbox/home/.codex/config.toml"
want_model="$(sed -n 's/^CODEX_MODEL=//p' "$TMP/.ai-sandbox/versions.env")"
run_args -- bash >/dev/null
grep -qx "model = \"${want_model}\"" "$CODEX_CFG" \
  && ok "model taken from versions.env (${want_model})" || bad "model taken from versions.env"
grep -qx 'approval_policy = "on-request"' "$CODEX_CFG" \
  && ok "approval_policy = on-request" || bad "approval_policy = on-request"
grep -q 'untrusted' "$CODEX_CFG" && bad "no retired untrusted policy" || ok "no retired untrusted policy"

AI_SANDBOX_CODEX_MODEL=gpt-6-sol run_args -- bash >/dev/null
grep -qx 'model = "gpt-6-sol"' "$CODEX_CFG" \
  && ok "AI_SANDBOX_CODEX_MODEL overrides model" || bad "AI_SANDBOX_CODEX_MODEL overrides model"

out="$(AI_SANDBOX_PRINT_ARGS=1 AI_SANDBOX_CODEX_MODEL='x"
approval_policy = "never' bash "$TMP/.ai-sandbox/run.sh" -- bash 2>&1)"
grep -q "Invalid Codex model name" <<<"$out" \
  && ok "TOML-breaking model name rejected" || bad "TOML-breaking model name rejected"
grep -q 'never' "$CODEX_CFG" && bad "config not poisoned by bad model" || ok "config not poisoned by bad model"

echo
echo "----------------------------------------"
echo "passed: ${pass}  failed: ${fail}"
[[ "$fail" -eq 0 ]]
