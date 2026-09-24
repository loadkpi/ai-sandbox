# ai-sandbox improvements

This is the initial task list. Many items are now done. Refer to
IMPLEMENTATION.md and ROADMAP.md for the current status.

## Critical

### NET-01: Two network modes — isolated and usual

**Problem:** The container starts with full network access. The AI can
send arbitrary HTTP requests and exfiltrate data from the workspace. But
a full network shutdown is not practical. The AI needs access to the
Claude/OpenAI APIs, and frequently to npm, pip and git.

**Solution:** Two start modes through a flag in `run.sh`.

Changes in `run.sh`:
- Add argument parsing: `--offline` enables `--network=none`.
- The default is with the network (for the APIs).
- The `--offline` mode gives full network isolation.
- The `AI_SANDBOX_NETWORK_MODE` variable gives programmatic control.

Optional (advanced option):
- A third mode, `--restricted`, with a Docker network + iptables/firewall.
  It permits only allowlisted domains: `api.anthropic.com`,
  `api.openai.com`, `registry.npmjs.org`, `github.com` (similar to the
  [official devcontainer](https://code.claude.com/docs/en/devcontainer)).
- Implement it with a separate `setup-firewall.sh` script, or with
  docker-compose and a sidecar proxy.

Files: `run.sh`

---

### MEM-01: Memory and CPU limits

**Problem:** There are no memory limits. The AI process, or the commands
that it starts, can use all host RAM and start the OOM killer.

**Solution:** Add these options to `docker run` in `run.sh`:
```
--memory=4g
--memory-swap=4g
--cpus=2
```

Let the user change them through environment variables:
```bash
AI_SANDBOX_MEMORY="${AI_SANDBOX_MEMORY:-4g}"
AI_SANDBOX_CPUS="${AI_SANDBOX_CPUS:-2}"
```

Files: `run.sh`

---

## High

### SEC-01: Protect the config files from changes in the container

**Problem:** The full `$WORKSPACE` is mounted read-write. The AI can
overwrite:
- `run.sh` — to change the security parameters for the next start.
- `Dockerfile` — to inject code into the image.
- `.claude/settings.json` — to remove the deny rules.
- `.mcp.json` — to add a malicious MCP server.

**Solution:** Divide the mount into two parts:

1. The AI work directory (read-write): a separate subdirectory or the full
   workspace.
2. The config files: mount them separately as read-only.

```bash
--mount "type=bind,src=$WORKSPACE,dst=/workspace"
--mount "type=bind,src=$WORKSPACE/.claude/settings.json,dst=/workspace/.claude/settings.json,readonly"
--mount "type=bind,src=$WORKSPACE/.mcp.json,dst=/workspace/.mcp.json,readonly"
--mount "type=bind,src=$WORKSPACE/run.sh,dst=/workspace/run.sh,readonly"
--mount "type=bind,src=$WORKSPACE/Dockerfile,dst=/workspace/Dockerfile,readonly"
```

Note: a bind mount of a file on top of a directory mount replaces the
file. The file is read-only, also in a read-write parent mount.

Also add `run.sh` and `Dockerfile` to the deny list in
`.claude/settings.json`:
```json
"Edit(./run.sh)",
"Edit(./Dockerfile)",
"Edit(./.claude/settings.json)",
"Edit(./.mcp.json)",
"Write(./run.sh)",
"Write(./Dockerfile)",
"Write(./.claude/settings.json)",
"Write(./.mcp.json)"
```

Files: `run.sh`, `.claude/settings.json`

---

### BUILD-01: Add `.dockerignore`

**Problem:** `docker build` copies the full context (`$SCRIPT_DIR`) to the
daemon. This includes `.git/` and `.ai-sandbox/home/` (which can contain
caches and history). This makes the build slow, and it can accidentally
put sensitive data into the build context.

**Solution:** Create `.dockerignore`:
```
.git
.ai-sandbox
.claude
.mcp.json
*.md
.env
.env.*
secrets/
```

Files: new file `.dockerignore`

---

### BUILD-02: Pin the npm package versions

**Problem:** `@latest` in the Dockerfile has these results:
- The builds are not reproducible. Each `docker build` can give a
  different image.
- An update with breaking changes can break the sandbox without a warning.
- You cannot go back to a known good state.

**Solution:** Pin the versions in the `Dockerfile`:
```dockerfile
ARG CODEX_VERSION=0.1.2504262326
ARG CLAUDE_CODE_VERSION=1.0.16
RUN npm install -g @openai/codex@${CODEX_VERSION} && npm cache clean --force
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} && npm cache clean --force
```

Advantages:
- With `ARG`, you can change the versions through `--build-arg` without a
  Dockerfile change.
- The versions are pinned. The build is reproducible.
- An update is an intentional action.

**Update mechanism:**

1. An `update.sh` script. It finds new versions and builds the image again:
```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Current pinned versions from the Dockerfile
CURRENT_CODEX=$(grep -oP 'ARG CODEX_VERSION=\K.*' "$SCRIPT_DIR/Dockerfile")
CURRENT_CLAUDE=$(grep -oP 'ARG CLAUDE_CODE_VERSION=\K.*' "$SCRIPT_DIR/Dockerfile")

# Latest available versions
LATEST_CODEX=$(npm view @openai/codex version 2>/dev/null)
LATEST_CLAUDE=$(npm view @anthropic-ai/claude-code version 2>/dev/null)

echo "codex:       $CURRENT_CODEX -> $LATEST_CODEX"
echo "claude-code: $CURRENT_CLAUDE -> $LATEST_CLAUDE"

if [ "$CURRENT_CODEX" = "$LATEST_CODEX" ] && [ "$CURRENT_CLAUDE" = "$LATEST_CLAUDE" ]; then
  echo "Everything is up to date."
  exit 0
fi

read -rp "Update and rebuild? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  exit 0
fi

# Update the versions in the Dockerfile
sed -i "s/^ARG CODEX_VERSION=.*/ARG CODEX_VERSION=$LATEST_CODEX/" "$SCRIPT_DIR/Dockerfile"
sed -i "s/^ARG CLAUDE_CODE_VERSION=.*/ARG CLAUDE_CODE_VERSION=$LATEST_CLAUDE/" "$SCRIPT_DIR/Dockerfile"

# Rebuild without the cache for the npm install layers
docker build --no-cache -t ai-sandbox:latest "$SCRIPT_DIR"

echo "Updated. New versions:"
echo "  codex:       $LATEST_CODEX"
echo "  claude-code: $LATEST_CLAUDE"
```

2. A quick update of one package without a Dockerfile change (through
   `--build-arg`):
```bash
docker build \
  --build-arg CLAUDE_CODE_VERSION=1.0.20 \
  --no-cache \
  -t ai-sandbox:latest .
```
This overrides the `ARG` for the build, but it does not change the
Dockerfile. It is useful to test a new version before you pin it.

3. Add an `update` subcommand to `run.sh`:
```bash
case "${1:-}" in
  update)
    exec "$SCRIPT_DIR/update.sh"
    ;;
esac
```
Then `./run.sh update` is the single entry point.

4. Version check in the container (for diagnostics):
```bash
./run.sh claude --version
./run.sh codex --version
```

Files: `Dockerfile`, new `update.sh`, `run.sh`

---

## Medium

### SEC-02: Safe transfer of the API keys

**Included in task UX-01** (global reusable keys). UX-01 describes the
`--env-file` implementation with a global/project cascade.

In addition to UX-01:
- Make sure that `.ai-sandbox/` is in `.gitignore`.
- Make sure that `~/.ai-sandbox/.env` has the permissions `600` (owner
  only).
- In the README, tell the user that the keys are visible through
  `/proc/self/environ` in the container.

Files: `run.sh`, `.gitignore`

---

### FIX-01: Repair the `${@:-bash}` syntax in run.sh

**Problem:** Line 88 of `run.sh`:
```bash
"${@:-bash}"
```
`$@` is an array, but `:-` works only with scalar variables. In bash, this
works for an empty `$@`. But the behavior is not POSIX, and it can give
unexpected results in different shell versions.

**Solution:** Replace it with an explicit check:
```bash
if [ $# -eq 0 ]; then
  set -- bash
fi

exec docker run --rm -it \
  ...
  "$IMAGE_NAME" \
  "$@"
```

Files: `run.sh`

---

### SEC-03: Extend the deny list in settings.json

**Problem:** It is possible to bypass the current deny list:
- `Bash(curl *)` does not block `python3 -c "import urllib.request; ..."`.
- `Bash(wget *)` does not block `node -e "fetch('...')"`.
- There is no deny rule for `nc`, `ncat` and `socat` (socat is installed
  in the image!).

**Solution:** Add these items to the deny list:
```json
"Bash(nc *)",
"Bash(ncat *)",
"Bash(socat *)",
"Bash(python3 -c *import*urllib*)",
"Bash(python3 -c *import*requests*)",
"Bash(python3 -c *import*socket*)",
"Bash(node -e *fetch*)",
"Bash(node -e *http*)",
"Bash(node -e *net*)"
```

Note: The deny list is defense in depth. It is not the main protection.
The full solution is network isolation (NET-01). The deny list adds to
network isolation, but it does not replace it.

Files: `.claude/settings.json`

---

### UX-01: Global reusable API keys

**Problem:** At this time, `STATE_DIR` (`$WORKSPACE/.ai-sandbox/home`) is
local to each project. When you copy the sandbox into a new project, you
must set up the API keys again. The keys are duplicated in each project.
This is not convenient and not safe.

**Solution:** Add a global directory `~/.ai-sandbox/` on the host for
shared data. Keep the project `.ai-sandbox/` for the state of each project.

Structure:
```
~/.ai-sandbox/                      # global (on the host)
  ├── .env                          # API keys (ANTHROPIC_API_KEY, OPENAI_API_KEY)
  ├── master-prompt.md              # standard system prompt
  └── codex/
      └── config.toml               # global Codex config

$WORKSPACE/.ai-sandbox/             # for each project
  ├── home/                         # container HOME (caches, history)
  ├── .env                          # project key override (optional)
  └── prompt.md                     # project prompt override (optional)
```

Changes in `run.sh`:

1. Define the global directory:
```bash
GLOBAL_DIR="${AI_SANDBOX_GLOBAL_DIR:-$HOME/.ai-sandbox}"
mkdir -p "$GLOBAL_DIR"
```

2. Load `.env` as a cascade. The project file overrides the global file:
```bash
DOCKER_ENV_ARGS=""
if [ -f "$GLOBAL_DIR/.env" ]; then
  DOCKER_ENV_ARGS="--env-file $GLOBAL_DIR/.env"
fi
if [ -f "$WORKSPACE/.ai-sandbox/.env" ]; then
  DOCKER_ENV_ARGS="$DOCKER_ENV_ARGS --env-file $WORKSPACE/.ai-sandbox/.env"
fi
```
If `--env-file` sets a variable two times, Docker uses the last value.
Thus the project `.env` correctly overrides the global file.

3. Mount the global directory as read-only:
```bash
--mount "type=bind,src=$GLOBAL_DIR,dst=/home/sandbox/.ai-sandbox-global,readonly"
```

4. Create `~/.ai-sandbox/.env.example` at the first start:
```bash
if [ ! -f "$GLOBAL_DIR/.env" ] && [ ! -f "$GLOBAL_DIR/.env.example" ]; then
  cat > "$GLOBAL_DIR/.env.example" <<'EOF'
ANTHROPIC_API_KEY=sk-ant-...
OPENAI_API_KEY=sk-...
EOF
  echo "Created $GLOBAL_DIR/.env.example — fill it in and rename it to .env"
fi
```

Files: `run.sh`

Note: This task replaces SEC-02. It extends SEC-02 to a full global
config.

---

### UX-02: Standard master prompt

**Problem:** There is no single system prompt that sets the AI work style
in all projects. For each new project, you must explain the context, the
rules and the limits again.

**Solution:** The `master-prompt.md` file becomes the system prompt for
Claude through `CLAUDE.md`, and the `base-instructions` for Codex.

Prompt structure (`~/.ai-sandbox/master-prompt.md`):
```markdown
# AI Sandbox — system instructions

## Role
You work in an isolated Docker container (ai-sandbox).

## Limits
- Do not try to bypass the network restrictions.
- Do not change the sandbox config files (run.sh, Dockerfile, .claude/settings.json).
- Do not try to read API keys from the environment variables.
- Do not install packages without explicit permission from the user.

## Work style
- Explain what you will do before you do it.
- If an error occurs, suggest possible solutions.
- Do not make changes outside the work directory.
```

The connection mechanism is in `run.sh`:

1. A cascade: the global `master-prompt.md` + the project `prompt.md`:
```bash
PROMPT_FILE=""
if [ -f "$GLOBAL_DIR/master-prompt.md" ]; then
  PROMPT_FILE="$GLOBAL_DIR/master-prompt.md"
fi
if [ -f "$WORKSPACE/.ai-sandbox/prompt.md" ]; then
  PROMPT_FILE="$WORKSPACE/.ai-sandbox/prompt.md"
fi
```

2. For Claude Code, generate `CLAUDE.md` in the workspace:
```bash
CLAUDE_MD="$WORKSPACE/CLAUDE.md"
if [ ! -f "$CLAUDE_MD" ] || [ "$PROMPT_FILE" -nt "$CLAUDE_MD" ]; then
  {
    if [ -f "$GLOBAL_DIR/master-prompt.md" ]; then
      cat "$GLOBAL_DIR/master-prompt.md"
    fi
    if [ -f "$WORKSPACE/.ai-sandbox/prompt.md" ]; then
      echo ""
      echo "---"
      echo ""
      cat "$WORKSPACE/.ai-sandbox/prompt.md"
    fi
  } > "$CLAUDE_MD"
fi
```

3. For Codex, send it through `base-instructions` in the MCP call, or
   write it to `$STATE_DIR/.codex/instructions.md` and set it in
   config.toml:
```toml
instructions_file = "/home/sandbox/.ai-sandbox-global/master-prompt.md"
```

4. Create a template at the first start:
```bash
if [ ! -f "$GLOBAL_DIR/master-prompt.md" ]; then
  cat > "$GLOBAL_DIR/master-prompt.md" <<'EOF'
# AI Sandbox — system instructions
# Edit this file for your needs
EOF
fi
```

Files: `run.sh`, `master-prompt.md` template

---

## Low

### OPS-01: Add HEALTHCHECK to the Dockerfile

**Solution:** A simple check that the shell is available:
```dockerfile
HEALTHCHECK --interval=30s --timeout=5s --retries=2 \
  CMD [ "bash", "-c", "echo ok" ]
```

Files: `Dockerfile`

---

### OPS-02: Add README.md

**Contents:**
- What it is and why (1 paragraph).
- Requirements: Docker, API keys.
- Quick start: 3-4 commands.
- Network modes: usual, `--offline`, (optional `--restricted`).
- API keys through `.env`.
- Security settings: what is not permitted and why.
- Codex as an MCP server for Claude: the advantages.
- Customization: how to change the limits and add packages.

Files: new `README.md`
