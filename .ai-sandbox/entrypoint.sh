#!/usr/bin/env bash
set -euo pipefail

uid="$(id -u)"
gid="$(id -g)"

mkdir -p "${HOME}/.nss_wrapper" "${HOME}/.local/bin" "${HOME}/.config"

PASSWD_FILE="${HOME}/.nss_wrapper/passwd"
GROUP_FILE="${HOME}/.nss_wrapper/group"

cat > "${PASSWD_FILE}" <<EOF
sandbox:x:${uid}:${gid}:sandbox:${HOME}:/bin/bash
EOF

cat > "${GROUP_FILE}" <<EOF
sandbox:x:${gid}:
EOF

LIB="$(ldconfig -p 2>/dev/null | awk '/libnss_wrapper\.so/{print $NF; exit}')"
if [[ -z "${LIB}" ]]; then
  for cand in /usr/lib/x86_64-linux-gnu/libnss_wrapper.so \
              /usr/lib/aarch64-linux-gnu/libnss_wrapper.so; do
    [[ -e "${cand}" ]] && LIB="${cand}" && break
  done
fi
export LD_PRELOAD="${LIB}"
export NSS_WRAPPER_PASSWD="${PASSWD_FILE}"
export NSS_WRAPPER_GROUP="${GROUP_FILE}"

export PATH="${HOME}/.local/bin:${PATH}"

exec "$@"