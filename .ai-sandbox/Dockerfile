ARG NODE_IMAGE=node:22-bookworm-slim
FROM ${NODE_IMAGE}

ARG CODEX_VERSION=0.133.0
ARG CLAUDE_VERSION=2.1.142

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    git \
    jq \
    libnss-wrapper \
    python3 \
    ripgrep \
    tini \
  && rm -rf /var/lib/apt/lists/*

RUN npm install -g "@openai/codex@${CODEX_VERSION}" \
 && npm install -g "@anthropic-ai/claude-code@${CLAUDE_VERSION}" \
 && npm cache clean --force

RUN mkdir -p /etc/claude-code && cat > /etc/claude-code/managed-settings.json <<'JSON'
{
  "disableBypassPermissionsMode": "disable"
}
JSON

COPY entrypoint.sh /usr/local/bin/ai-sandbox-entrypoint
RUN chmod 0755 /usr/local/bin/ai-sandbox-entrypoint

WORKDIR /workspace
ENTRYPOINT ["/usr/bin/tini","--","/usr/local/bin/ai-sandbox-entrypoint"]
CMD ["bash"]