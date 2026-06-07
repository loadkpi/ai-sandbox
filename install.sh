#!/usr/bin/env bash
set -euo pipefail

TARGET="${1:-$PWD}"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -d "${TARGET}" ]]; then
  echo "Target directory does not exist: ${TARGET}" >&2
  exit 1
fi

TARGET="$(cd "${TARGET}" && pwd)"

if [[ "${TARGET}" == "${SRC}" ]]; then
  echo "Refusing to install into the template repository itself." >&2
  exit 1
fi

echo "Installing ai-sandbox into ${TARGET}"

mkdir -p "${TARGET}/.ai-sandbox"
cp -r "${SRC}/.ai-sandbox/." "${TARGET}/.ai-sandbox/"
echo "  + .ai-sandbox/"

for f in .claude/settings.json .mcp.json; do
  if [[ ! -e "${TARGET}/${f}" ]]; then
    mkdir -p "$(dirname "${TARGET}/${f}")"
    cp "${SRC}/${f}" "${TARGET}/${f}"
    echo "  + ${f}"
  else
    echo "  = ${f} (kept existing)"
  fi
done

GI="${TARGET}/.gitignore"
touch "${GI}"
for line in "/.ai-sandbox/home/" "/.claude/settings.local.json"; do
  if ! grep -qxF "${line}" "${GI}"; then
    echo "${line}" >> "${GI}"
    echo "  + .gitignore: ${line}"
  fi
done

cat <<EOF

Done. Next steps:
  1. Create ~/.config/ai-sandbox/credentials.env (see README)
  2. Run ./.ai-sandbox/run.sh -- claude
EOF
