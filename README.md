# AI Sandbox for Claude Code + Codex

Per-repository Docker sandbox for running Claude Code CLI and OpenAI Codex CLI
in isolated, capability-dropped containers. Codex is also exposed as an MCP
server to Claude. The sandbox is shipped as a `.ai-sandbox/` subdirectory
vendored into your project.

## What you get

- Pinned Claude Code and Codex CLI versions (see `.ai-sandbox/versions.env`)
- Read-only rootfs, all capabilities dropped, `no-new-privileges`
- Configurable memory/CPU/PID limits
- Read-only bind mounts over sandbox config files (agent cannot rewrite its own rules)
- Five operating modes from full isolation to fully open
- L7 host allow-list hook for Claude `WebFetch`/`Bash` tool calls
- Shared host-level credentials file (one place to keep API keys)

## Prerequisites

- Docker Engine 24+ or Docker Desktop
- Linux, macOS, or Windows with WSL2
- A host-level credentials file at `~/.config/ai-sandbox/credentials.env`:

```bash
mkdir -p ~/.config/ai-sandbox
chmod 700 ~/.config/ai-sandbox
cat > ~/.config/ai-sandbox/credentials.env <<'EOF'
OPENAI_API_KEY=sk-...
ANTHROPIC_API_KEY=sk-ant-...
EOF
chmod 600 ~/.config/ai-sandbox/credentials.env
```

The file is mounted into the container via `--env-file`. Anything inside it
is visible as an environment variable to processes in the container.

## Install (three methods)

### A. install.sh

From inside your target project:

```bash
git clone https://example.com/ai-sandbox /tmp/ai-sandbox
/tmp/ai-sandbox/install.sh .
```

This copies `.ai-sandbox/` into your project, places `.claude/settings.json`
and `.mcp.json` if they do not already exist, and merges sandbox-relevant
lines into your `.gitignore`. The script is idempotent.

### B. Manual copy

```bash
git clone https://example.com/ai-sandbox /tmp/ai-sandbox
cp -r /tmp/ai-sandbox/.ai-sandbox ./
cp /tmp/ai-sandbox/.mcp.json ./
mkdir -p .claude && cp /tmp/ai-sandbox/.claude/settings.json .claude/
printf '/.ai-sandbox/home/\n/.claude/settings.local.json\n' >> .gitignore
```

### C. Git submodule

If you want updates via `git pull` instead of re-copying:

```bash
git submodule add https://example.com/ai-sandbox .ai-sandbox-template
ln -s .ai-sandbox-template/.ai-sandbox .ai-sandbox
cp .ai-sandbox-template/.mcp.json ./
mkdir -p .claude && cp .ai-sandbox-template/.claude/settings.json .claude/
```

## First run

```bash
./.ai-sandbox/run.sh -- claude
# or
./.ai-sandbox/run.sh -- codex
# or a plain shell:
./.ai-sandbox/run.sh
```

The first invocation builds the image; subsequent runs reuse it.

## Modes

Selected with `--mode <name>`. Default is `default`.

| Mode       | Claude Web tools     | Bash curl/wget   | Network            | Codex network |
|------------|----------------------|------------------|--------------------|---------------|
| `default`  | denied               | denied           | bridge             | denied        |
| `webfetch` | allow-listed via hook| denied           | bridge             | denied        |
| `dev`      | allow-listed via hook| allow-listed hook| bridge             | allowed       |
| `open`     | allowed              | allowed          | bridge             | allowed       |
| `offline`  | denied               | denied           | `--network=none`   | denied        |

L3 network is only restricted in `offline`. The L7 hook (`net-guard.sh`)
filters Claude tool calls against `.ai-sandbox/allowed-domains.txt`. The hook
does **not** protect Codex or arbitrary user shells — for hard network
isolation use `--mode offline`.

## Host skills / agents (opt-in)

By default the sandbox has an isolated `HOME`, so your **host** `~/.claude`
skills, subagents and slash-commands are not visible inside it (project-level
`.claude/` in the repo still is). To surface your personal ones, add
`--with-host-skills`:

```bash
./.ai-sandbox/run.sh --with-host-skills -- claude
```

This bind-mounts `~/.claude/{skills,agents,commands}` **read-only** (only those
that exist). It deliberately never mounts `~/.claude.json` or any credential
file, and the mounts are read-only so the agent cannot tamper with your host
config. Override the source dir with `AI_SANDBOX_HOST_CLAUDE_DIR`.

## Codex model

The Codex model is set in `.ai-sandbox/versions.env`:

```bash
CODEX_MODEL=gpt-6-astra
```

Change it there to switch permanently (e.g. `gpt-6-sol` if your account has no
Astra access). For a one-off run, override it from the environment:

```bash
AI_SANDBOX_CODEX_MODEL=gpt-6-sol ./.ai-sandbox/run.sh -- codex
```

`run.sh` writes the value into `.ai-sandbox/home/.codex/config.toml` on every
run, so a model picked via `/model` inside Codex is reset on the next start.
`update.sh` keeps `CODEX_MODEL` when it bumps the tool versions.

## Security model

- **Filesystem**: read-only rootfs, `/tmp` and `/run` tmpfs only.
  `/workspace` is read-write, but `run.sh`, `Dockerfile`, `entrypoint.sh`,
  hooks, allow-list, `.claude/settings.json`, and `.mcp.json` are bind-mounted
  on top as read-only. Agent cannot modify its own rules.
- **Capabilities**: `--cap-drop=ALL`, `--security-opt no-new-privileges`.
- **Resource limits**: `--memory`, `--memory-swap` (equal — closes swap escape),
  `--cpus`, `--pids-limit`, `--ulimit nofile`. Overridable via env:
  ```bash
  AI_SANDBOX_MEMORY=8g AI_SANDBOX_CPUS=4 ./.ai-sandbox/run.sh -- claude
  ```
- **User**: container runs as your host UID:GID via `--user` and
  `libnss-wrapper`. Files created in `/workspace` are owned by your host user.
- **Network**: see modes above.
- **Claude managed settings**: `disableBypassPermissionsMode` enforced via
  `/etc/claude-code/managed-settings.json` baked into the image.
- **Project Claude deny-list** (`.claude/settings.json`): forbids reading
  obvious secrets, writing to sandbox configs, and a sample of network
  bypass commands (`nc`, `socat`, `python -c 'import urllib'`, etc.).

### Known limitations

- `nc`, `socat`, and ad-hoc Python/Node network calls are denied at the L1
  permission level (Claude deny-list), but a determined process started by
  the user can still open sockets in any mode except `offline`. The proper
  fix is an iptables egress firewall — planned for a future iteration.
- The L7 hook's allow-list is enforced only on Claude tool calls. Codex does
  not consult it.

## Customizing the allow-list

Edit `.ai-sandbox/allowed-domains.txt`. One host per line. Wildcards
(`*.example.com` and `.example.com`) are supported by the L7 hook.
Restart the container to pick up changes.

## Updating CLI versions

```bash
./.ai-sandbox/check-updates.sh    # see what's newer on npm
./.ai-sandbox/update.sh           # bump versions.env and rebuild
./.ai-sandbox/update.sh --claude 2.2.0   # pin specific version
```

## Troubleshooting

**`docker: cgroups: memory limit unsupported`**
The host kernel lacks swap accounting. Either enable
`cgroup_enable=memory swapaccount=1` in the bootloader, or set
`AI_SANDBOX_MEMORY=` to an empty string to skip the limit.

**`fatal: not under version control` when using submodule install**
Run `git submodule update --init` after cloning.

**Container name conflict on parallel sessions**
The container name now includes `$$` (PID). If you still see conflicts,
set `AI_SANDBOX_NAME_SUFFIX=$(date +%s)` before invoking `run.sh`.

**Codex says `model gpt-5.5 not found`**
Either downgrade in `.ai-sandbox/home/.codex/config.toml` (just remove the
`# managed-by` marker line first to stop auto-regeneration) or delete the
`model = ...` line entirely to let Codex use its default.

**arm64 host**
Supported. The entrypoint detects `libnss_wrapper.so` via `ldconfig` and
falls back to `/usr/lib/aarch64-linux-gnu/libnss_wrapper.so`.

## Files

| File                                  | Purpose                                  |
|---------------------------------------|------------------------------------------|
| `.ai-sandbox/Dockerfile`              | Image definition (pinned CLI versions)   |
| `.ai-sandbox/versions.env`            | Codex/Claude/Node pinned versions        |
| `.ai-sandbox/run.sh`                  | Launches the container                   |
| `.ai-sandbox/build.sh`                | Builds the image                         |
| `.ai-sandbox/update.sh`               | Bumps pinned versions and rebuilds       |
| `.ai-sandbox/check-updates.sh`        | Reports newer npm versions               |
| `.ai-sandbox/entrypoint.sh`           | `nss_wrapper` setup, exec user command   |
| `.ai-sandbox/allowed-domains.txt`     | Host allow-list for the L7 hook          |
| `.ai-sandbox/hooks/net-guard.sh`      | Claude `PreToolUse` hook (L7 filter)     |
| `.ai-sandbox/.dockerignore`           | Trims build context                      |
| `.claude/settings.json`               | Project-level Claude restrictions        |
| `.mcp.json`                           | Codex registered as an MCP server        |
| `install.sh`                          | Installer for vendoring into projects    |
