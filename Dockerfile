FROM node:22-bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash ca-certificates curl git jq ripgrep python3 \
    tini \
    bubblewrap socat \
    libnss-wrapper \
  && rm -rf /var/lib/apt/lists/*

# Codex CLI
RUN npm install -g @openai/codex@latest && npm cache clean --force

# Claude Code CLI
RUN npm install -g @anthropic-ai/claude-code@latest \
  || npm install -g @anthropic-ai/claude-code@latest --force --no-os-check \
  && npm cache clean --force

# Managed settings: disable bypass permissions
RUN mkdir -p /etc/claude-code && cat > /etc/claude-code/managed-settings.json <<'JSON'
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "disableBypassPermissionsMode": "disable",
  "env": {
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"
  }
}
JSON

# Entry: runtime passwd/group for current UID/GID using nss_wrapper
RUN cat > /usr/local/bin/ai-sandbox-entrypoint <<'SH'
#!/usr/bin/env bash
set -euo pipefail

uid="$(id -u)"
gid="$(id -g)"

mkdir -p "${HOME}/.nss_wrapper" "${HOME}/.local/bin"
PASSWD_FILE="${HOME}/.nss_wrapper/passwd"
GROUP_FILE="${HOME}/.nss_wrapper/group"

if [ ! -f "$PASSWD_FILE" ]; then
  echo "sandbox:x:${uid}:${gid}:sandbox:${HOME}:/bin/bash" > "$PASSWD_FILE"
fi
if [ ! -f "$GROUP_FILE" ]; then
  echo "sandbox:x:${gid}:" > "$GROUP_FILE"
fi

LIB="$(ldconfig -p 2>/dev/null | awk '/libnss_wrapper\.so/{print $NF; exit}')"
export LD_PRELOAD="${LIB:-/usr/lib/x86_64-linux-gnu/libnss_wrapper.so}"
export NSS_WRAPPER_PASSWD="$PASSWD_FILE"
export NSS_WRAPPER_GROUP="$GROUP_FILE"

export PATH="${HOME}/.local/bin:${PATH}"
exec "$@"
SH
RUN chmod 0755 /usr/local/bin/ai-sandbox-entrypoint

WORKDIR /workspace
ENTRYPOINT ["tini","--","/usr/local/bin/ai-sandbox-entrypoint"]
CMD ["bash"]
