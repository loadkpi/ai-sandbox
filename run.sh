#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="ai-sandbox:latest"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(pwd)"
STATE_DIR="$WORKSPACE/.ai-sandbox/home"

mkdir -p "$STATE_DIR" "$WORKSPACE/.claude"

# Codex safe defaults
mkdir -p "$STATE_DIR/.codex"
if [ ! -f "$STATE_DIR/.codex/config.toml" ]; then
  cat > "$STATE_DIR/.codex/config.toml" <<'TOML'
# Ask approval before running "untrusted" commands; keep network disabled for command sandbox.
approval_policy = "untrusted"
sandbox_mode    = "workspace-write"

[sandbox_workspace_write]
network_access = false
TOML
fi

# Claude project settings
mkdir -p "$WORKSPACE/.claude"
if [ ! -f "$WORKSPACE/.claude/settings.json" ]; then
  cat > "$WORKSPACE/.claude/settings.json" <<'JSON'
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "permissions": {
    "deny": [
      "Read(./.env)",
      "Read(./.env.*)",
      "Read(./secrets/**)",
      "Read(./.ai-sandbox/**)",
      "Read(~/.codex/**)",
      "Read(~/.ssh/**)",
      "Read(~/.aws/**)",
      "Read(~/.gnupg/**)",
      "Bash(curl *)",
      "Bash(wget *)",
      "Bash(ssh *)",
      "Bash(scp *)",
      "WebFetch"
    ]
  },
  "sandbox": {
    "enabled": true,
    "enableWeakerNestedSandbox": true
  }
}
JSON
fi

# MCP: Codex as MCP for Claude
if [ ! -f "$WORKSPACE/.mcp.json" ]; then
  cat > "$WORKSPACE/.mcp.json" <<'JSON'
{
  "mcpServers": {
    "codex": {
      "command": "codex",
      "args": ["mcp-server"]
    }
  }
}
JSON
fi

docker build -t "$IMAGE_NAME" "$SCRIPT_DIR" >/dev/null

exec docker run --rm -it \
  --name "ai-sandbox-$(basename "$WORKSPACE")" \
  --user "$(id -u):$(id -g)" \
  --workdir /workspace \
  --mount "type=bind,src=$WORKSPACE,dst=/workspace" \
  --mount "type=bind,src=$STATE_DIR,dst=/home/sandbox" \
  --env HOME=/home/sandbox \
  --env XDG_CONFIG_HOME=/home/sandbox/.config \
  --env XDG_CACHE_HOME=/home/sandbox/.cache \
  --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,nodev,size=1024m \
  --tmpfs /var/tmp:rw,noexec,nosuid,nodev,size=1024m \
  --tmpfs /run:rw,nosuid,nodev,size=64m \
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  --pids-limit=512 \
  "$IMAGE_NAME" \
  "${@:-bash}"
