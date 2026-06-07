#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/.ai-sandbox/versions.env"

NODE_IMAGE="${NODE_IMAGE:-node:22-bookworm-slim}"

get_latest() {
  local pkg="$1"
  docker run --rm "${NODE_IMAGE}" sh -lc "npm view ${pkg} version"
}

LATEST_CODEX="$(get_latest '@openai/codex')"
LATEST_CLAUDE="$(get_latest '@anthropic-ai/claude-code')"

echo "Pinned Codex   : ${CODEX_VERSION}"
echo "Latest Codex   : ${LATEST_CODEX}"
echo
echo "Pinned Claude  : ${CLAUDE_VERSION}"
echo "Latest Claude  : ${LATEST_CLAUDE}"

if [[ "${CODEX_VERSION}" != "${LATEST_CODEX}" || "${CLAUDE_VERSION}" != "${LATEST_CLAUDE}" ]]; then
  exit 10
fi