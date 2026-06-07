#!/usr/bin/env bash
set -euo pipefail

MODE="default"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CREDS_FILE="${AI_SANDBOX_CREDS_FILE:-$HOME/.config/ai-sandbox/credentials.env}"

source "${ROOT}/.ai-sandbox/versions.env"
IMAGE_TAG="ai-sandbox:codex-${CODEX_VERSION}_claude-${CLAUDE_VERSION}"

AI_SANDBOX_MEMORY="${AI_SANDBOX_MEMORY:-4g}"
AI_SANDBOX_CPUS="${AI_SANDBOX_CPUS:-2}"
AI_SANDBOX_PIDS="${AI_SANDBOX_PIDS:-1024}"

usage() {
  cat <<EOF
Usage:
  ./.ai-sandbox/run.sh [--mode default|webfetch|dev|open|offline] [--] [command...]

Modes:
  default   No Web*, no curl/wget. Bridge network (no L3 filter).
  webfetch  Claude WebFetch with host allow-list via net-guard.sh hook.
  dev       Bash + WebFetch with host allow-list; Codex gets network too.
  open      No restrictions (use only for trusted local work).
  offline   --network=none. Maximum isolation; no network at all.

Env knobs:
  AI_SANDBOX_MEMORY (default 4g)
  AI_SANDBOX_CPUS   (default 2)
  AI_SANDBOX_PIDS   (default 1024)

Examples:
  ./.ai-sandbox/run.sh
  ./.ai-sandbox/run.sh -- claude
  ./.ai-sandbox/run.sh --mode offline -- bash
  ./.ai-sandbox/run.sh --mode dev -- bash -lc 'npm ci && npm test'
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      if [[ $# -lt 2 ]]; then
        echo "--mode requires an argument" >&2
        usage >&2
        exit 1
      fi
      MODE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    *)
      break
      ;;
  esac
done

case "${MODE}" in
  default|webfetch|dev|open|offline) ;;
  *)
    echo "Unknown mode: ${MODE}" >&2
    exit 1
    ;;
esac

mkdir -p \
  "${ROOT}/.ai-sandbox/home/.codex" \
  "${ROOT}/.ai-sandbox/home/.config" \
  "${ROOT}/.claude"

render_claude_local_settings() {
  case "${MODE}" in
    default|offline)
      cat > "${ROOT}/.claude/settings.local.json" <<'JSON'
{
  "permissions": {
    "deny": [
      "WebFetch",
      "WebSearch",
      "Bash(curl *)",
      "Bash(wget *)",
      "Bash(ssh *)",
      "Bash(scp *)"
    ]
  }
}
JSON
      ;;
    webfetch)
      cat > "${ROOT}/.claude/settings.local.json" <<'JSON'
{
  "permissions": {
    "deny": [
      "WebSearch",
      "Bash(curl *)",
      "Bash(wget *)",
      "Bash(ssh *)",
      "Bash(scp *)"
    ]
  },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "WebFetch|WebSearch",
        "hooks": [
          {
            "type": "command",
            "command": "/workspace/.ai-sandbox/hooks/net-guard.sh"
          }
        ]
      }
    ]
  }
}
JSON
      ;;
    dev)
      cat > "${ROOT}/.claude/settings.local.json" <<'JSON'
{
  "permissions": {
    "deny": [
      "WebSearch"
    ]
  },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash|WebFetch|WebSearch",
        "hooks": [
          {
            "type": "command",
            "command": "/workspace/.ai-sandbox/hooks/net-guard.sh"
          }
        ]
      }
    ]
  }
}
JSON
      ;;
    open)
      cat > "${ROOT}/.claude/settings.local.json" <<'JSON'
{
  "permissions": {
    "deny": []
  }
}
JSON
      ;;
  esac
}

render_codex_config() {
  local target="${ROOT}/.ai-sandbox/home/.codex/config.toml"
  local marker="# managed-by: ai-sandbox/run.sh — DO NOT EDIT (regenerated each run)"

  if [[ -f "${target}" ]] && ! grep -qF "${marker}" "${target}"; then
    echo "[run.sh] preserving user-edited ${target}" >&2
    return 0
  fi

  local codex_network="false"
  if [[ "${MODE}" == "dev" || "${MODE}" == "open" ]]; then
    codex_network="true"
  fi

  cat > "${target}" <<EOF
${marker}
model = "gpt-5.5"
approval_policy = "untrusted"
sandbox_mode = "workspace-write"
web_search = "cached"

[sandbox_workspace_write]
network_access = ${codex_network}
exclude_slash_tmp = true
exclude_tmpdir_env_var = true

[shell_environment_policy]
inherit = "core"
include_only = ["PATH", "HOME", "USER", "LANG", "LC_ALL", "TERM",
                "GITHUB_TOKEN", "GH_TOKEN", "NPM_TOKEN", "PIP_INDEX_URL"]
EOF
}

render_claude_local_settings
render_codex_config

if ! docker image inspect "${IMAGE_TAG}" >/dev/null 2>&1; then
  "${ROOT}/.ai-sandbox/build.sh" >/dev/null
fi

CONTAINER_NAME="ai-sandbox-$(basename "${ROOT}")-$$"

DOCKER_ARGS=(
  run --rm -it
  --name "${CONTAINER_NAME}"
  --user "$(id -u):$(id -g)"
  --workdir /workspace
  --read-only
  --cap-drop=ALL
  --security-opt no-new-privileges
  --pids-limit "${AI_SANDBOX_PIDS}"
  --ulimit nofile=4096:4096
  --memory "${AI_SANDBOX_MEMORY}"
  --memory-swap "${AI_SANDBOX_MEMORY}"
  --cpus "${AI_SANDBOX_CPUS}"
  --tmpfs /tmp:rw,noexec,nosuid,nodev,size=1024m
  --tmpfs /run:rw,nosuid,nodev,size=64m
  -e HOME=/home/sandbox
  -e XDG_CONFIG_HOME=/home/sandbox/.config
  -e XDG_CACHE_HOME=/home/sandbox/.cache
  -e XDG_DATA_HOME=/home/sandbox/.local/share
  -e AI_SANDBOX_MODE="${MODE}"
  -e AI_SANDBOX_ALLOWED_DOMAINS_FILE=/workspace/.ai-sandbox/allowed-domains.txt
  -e CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
  -e DISABLE_TELEMETRY=1
  -e DISABLE_ERROR_REPORTING=1
  -e DISABLE_BUG_COMMAND=1
  -v "${ROOT}:/workspace:rw"
  -v "${ROOT}/.ai-sandbox/home:/home/sandbox:rw"
  -v "${ROOT}/.ai-sandbox/run.sh:/workspace/.ai-sandbox/run.sh:ro"
  -v "${ROOT}/.ai-sandbox/build.sh:/workspace/.ai-sandbox/build.sh:ro"
  -v "${ROOT}/.ai-sandbox/update.sh:/workspace/.ai-sandbox/update.sh:ro"
  -v "${ROOT}/.ai-sandbox/check-updates.sh:/workspace/.ai-sandbox/check-updates.sh:ro"
  -v "${ROOT}/.ai-sandbox/Dockerfile:/workspace/.ai-sandbox/Dockerfile:ro"
  -v "${ROOT}/.ai-sandbox/entrypoint.sh:/workspace/.ai-sandbox/entrypoint.sh:ro"
  -v "${ROOT}/.ai-sandbox/versions.env:/workspace/.ai-sandbox/versions.env:ro"
  -v "${ROOT}/.ai-sandbox/hooks:/workspace/.ai-sandbox/hooks:ro"
  -v "${ROOT}/.ai-sandbox/allowed-domains.txt:/workspace/.ai-sandbox/allowed-domains.txt:ro"
  -v "${ROOT}/.claude/settings.json:/workspace/.claude/settings.json:ro"
  -v "${ROOT}/.claude/settings.local.json:/workspace/.claude/settings.local.json:ro"
  -v "${ROOT}/.mcp.json:/workspace/.mcp.json:ro"
)

case "${MODE}" in
  offline)
    DOCKER_ARGS+=( --network=none )
    ;;
esac

if [[ -f "${CREDS_FILE}" ]]; then
  DOCKER_ARGS+=( --env-file "${CREDS_FILE}" )
fi

if [[ $# -eq 0 ]]; then
  set -- bash
fi

exec docker "${DOCKER_ARGS[@]}" "${IMAGE_TAG}" "$@"
