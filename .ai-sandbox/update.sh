#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSIONS_FILE="${ROOT}/.ai-sandbox/versions.env"

source "${VERSIONS_FILE}"

NEW_CODEX="${CODEX_VERSION}"
NEW_CLAUDE="${CLAUDE_VERSION}"

usage() {
  cat <<EOF
Usage:
  ./.ai-sandbox/update.sh                # bump both to latest npm versions and rebuild
  ./.ai-sandbox/update.sh --codex X.Y.Z
  ./.ai-sandbox/update.sh --claude X.Y.Z
  ./.ai-sandbox/update.sh --codex X.Y.Z --claude A.B.C
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --codex)
      if [[ $# -lt 2 ]]; then
        echo "--codex requires an argument" >&2
        usage >&2
        exit 1
      fi
      NEW_CODEX="$2"
      shift 2
      ;;
    --claude)
      if [[ $# -lt 2 ]]; then
        echo "--claude requires an argument" >&2
        usage >&2
        exit 1
      fi
      NEW_CLAUDE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ "${NEW_CODEX}" == "${CODEX_VERSION}" && "${NEW_CLAUDE}" == "${CLAUDE_VERSION}" ]]; then
  TMP_OUT="$("${ROOT}/.ai-sandbox/check-updates.sh" || true)"
  echo "${TMP_OUT}"

  LATEST_CODEX="$(echo "${TMP_OUT}" | awk -F': ' '/Latest Codex/{print $2}')"
  LATEST_CLAUDE="$(echo "${TMP_OUT}" | awk -F': ' '/Latest Claude/{print $2}')"

  [[ -n "${LATEST_CODEX}" ]] && NEW_CODEX="${LATEST_CODEX}"
  [[ -n "${LATEST_CLAUDE}" ]] && NEW_CLAUDE="${LATEST_CLAUDE}"
fi

cp "${VERSIONS_FILE}" "${VERSIONS_FILE}.bak"

cat > "${VERSIONS_FILE}" <<EOF
CODEX_VERSION=${NEW_CODEX}
CLAUDE_VERSION=${NEW_CLAUDE}
NODE_IMAGE=${NODE_IMAGE}
EOF

"${ROOT}/.ai-sandbox/build.sh"
