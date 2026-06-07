#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/.ai-sandbox/versions.env"

IMAGE_TAG="ai-sandbox:codex-${CODEX_VERSION}_claude-${CLAUDE_VERSION}"

docker build \
  --build-arg NODE_IMAGE="${NODE_IMAGE}" \
  --build-arg CODEX_VERSION="${CODEX_VERSION}" \
  --build-arg CLAUDE_VERSION="${CLAUDE_VERSION}" \
  -t "${IMAGE_TAG}" \
  -f "${ROOT}/.ai-sandbox/Dockerfile" \
  "${ROOT}/.ai-sandbox"

echo "${IMAGE_TAG}"