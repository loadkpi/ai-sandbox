# AI Sandbox — current architecture

This document shows the state of the project after the 2026-05-28 iteration.
It describes how the project works now. It does not describe alternative
designs.

## General concept

The project is a **template**. You copy it into a target project as the
`.ai-sandbox/` subdirectory. You also add some files to the project root
(`.claude/`, `.mcp.json`, `.gitignore` rules). After the installation, you
start Claude Code and Codex CLI in a Docker container. The container:

- Uses pinned CLI versions. This makes the environment reproducible.
- Has limits for memory, CPU, PIDs and open files.
- Uses a read-only root file system with a minimum set of capabilities.
- Has read-only overlays on its own configuration files. The agent cannot
  change its own rules.
- Has one control script, `run.sh`, with five modes.

## Topology

```
HOST (developer machine)
├── ~/.config/ai-sandbox/credentials.env       (API keys, 0600)
└── <project>/                                 (user work directory)
    ├── .ai-sandbox/                           (copied from the template)
    │   ├── Dockerfile
    │   ├── versions.env
    │   ├── run.sh         ───┐
    │   ├── build.sh          │ scripts on the host
    │   ├── update.sh         │
    │   ├── check-updates.sh  │
    │   ├── entrypoint.sh  ───┘ in the container
    │   ├── allowed-domains.txt
    │   ├── hooks/net-guard.sh
    │   ├── .dockerignore
    │   └── home/                              (container HOME, persistent)
    │       ├── .codex/config.toml             (run.sh generates it)
    │       └── .config/                       (Claude/Codex state)
    ├── .claude/
    │   ├── settings.json                      (committed, deny list)
    │   └── settings.local.json                (generated for each mode, gitignored)
    ├── .mcp.json                              (Codex as an MCP server)
    └── .gitignore                             (contains /.ai-sandbox/home/)

DOCKER DAEMON
└── ai-sandbox:codex-<X>_claude-<Y>            (image, pinned tag)
    └── runtime container (ephemeral, --rm)
        ├── /workspace                          ← bind mount <project> (rw)
        │   ├── .ai-sandbox/run.sh:ro          (file-over-file overlay)
        │   ├── .ai-sandbox/Dockerfile:ro
        │   ├── ...                            (all sandbox configs ro)
        │   ├── .claude/settings.json:ro
        │   └── .mcp.json:ro
        ├── /home/sandbox                       ← bind mount <project>/.ai-sandbox/home (rw)
        ├── /tmp                                 ← tmpfs, 1024m, noexec
        ├── /run                                 ← tmpfs, 64m
        └── /                                    ← read-only rootfs
```

## Life cycle

### Installation in a target project

There are three equivalent procedures (refer to README §Install). All of
them give the same set of files in the target project.

```
install.sh / manual cp / git submodule
        │
        ▼
target-project/
  ├── .ai-sandbox/          (full copy of the template)
  ├── .claude/settings.json (if it did not exist)
  ├── .mcp.json             (if it did not exist)
  └── .gitignore            (2 lines added)
```

You can run `install.sh` many times with the same result. It does not
overwrite an existing `.claude/settings.json` or `.mcp.json`.

### First start

```
./.ai-sandbox/run.sh -- claude
        │
        ▼
run.sh
  ├── source versions.env                       (Codex/Claude/Node versions)
  ├── parse --mode flag                          (default|webfetch|dev|open|offline)
  ├── mkdir -p .ai-sandbox/home/.codex .claude
  ├── render_claude_local_settings              (generates settings.local.json)
  ├── render_codex_config                       (idempotent, uses a marker)
  ├── docker image inspect ai-sandbox:X_Y       (does the image exist?)
  │       └── NO → build.sh
  │                  └── docker build -f Dockerfile ".ai-sandbox/"
  └── exec docker run [DOCKER_ARGS] image bash
```

After the build, Docker keeps the image by its tag. The next starts do not
build it again.

### In the container

```
tini (PID 1)
  └── /usr/local/bin/ai-sandbox-entrypoint
        ├── id -u / id -g  (from --user, host UID:GID)
        ├── create .nss_wrapper/{passwd,group}  (user "sandbox" → host UID)
        ├── find libnss_wrapper.so
        │     ├── ldconfig -p
        │     └── fallback: amd64 → arm64
        ├── export LD_PRELOAD, NSS_WRAPPER_*
        ├── PATH=$HOME/.local/bin:$PATH
        └── exec "$@"        (claude / codex / bash)
```

The container runs with the host UID. This UID is not in the container
`/etc/passwd`. Thus the container needs `libnss_wrapper`. The wrapper
replaces `getpwuid()` and related functions. Then tools such as git, ssh
and sudo see a valid user.

### Codex as an MCP server for Claude

```
Claude Code (in the container)
      │ reads .mcp.json
      ▼
{ "mcpServers": { "codex": { "command": "codex", "args": ["mcp-server"], ... } } }
      │
      ▼
spawn codex mcp-server                          (through stdio)
      │
      ▼
Claude can call the Codex tools/*
```

`--env-file credentials.env` supplies `OPENAI_API_KEY`. The
`${OPENAI_API_KEY}` substitution in `.mcp.json` sends it to Codex.

## Protection layers (defense in depth)

From the bottom to the top:

```
┌─────────────────────────────────────────────────────────────────┐
│ 6. Claude managed settings (image level)                        │
│    /etc/claude-code/managed-settings.json                       │
│    disableBypassPermissionsMode: "disable"                      │
│    → the agent cannot enable --dangerously-skip-permissions     │
├─────────────────────────────────────────────────────────────────┤
│ 5. Project deny list (.claude/settings.json)                    │
│    Read(./.env*, secrets, *.pem, *.key, ~/.ssh, ~/.aws)         │
│    Edit/Write(./.ai-sandbox/**, settings.json, .mcp.json)       │
│    Bash(sudo, docker, nsenter, mount, nc, socat, python -c ...)│
│    → blocks the obvious bypass vectors                          │
├─────────────────────────────────────────────────────────────────┤
│ 4. Mode-specific local settings (.claude/settings.local.json)   │
│    run.sh generates it again for the selected mode              │
│    WebFetch/WebSearch/Bash(curl|wget|ssh|scp) deny              │
│    + L7 hook for permitted hosts (webfetch/dev modes)           │
├─────────────────────────────────────────────────────────────────┤
│ 3. RO bind mounts on /workspace                                 │
│    /workspace is rw, but specified files are ro                 │
│    → root in the container cannot change run.sh / Dockerfile    │
├─────────────────────────────────────────────────────────────────┤
│ 2. Container constraints                                        │
│    --read-only rootfs                                           │
│    --cap-drop=ALL                                               │
│    --security-opt no-new-privileges                             │
│    --memory / --memory-swap / --cpus / --pids-limit             │
│    --tmpfs /tmp,/run (noexec,nosuid,nodev)                      │
├─────────────────────────────────────────────────────────────────┤
│ 1. Docker user namespace / cgroups (host kernel)                │
│    --user $UID:$GID + libnss_wrapper                            │
│    → container processes = unprivileged host user               │
└─────────────────────────────────────────────────────────────────┘
```

The network has a separate model. Refer to the next section.

## Network model

| Mode       | Docker network       | Claude WebFetch  | Bash curl/wget | Codex network |
|------------|----------------------|------------------|----------------|---------------|
| `default`  | bridge (default)     | deny             | deny           | deny          |
| `webfetch` | bridge               | L7 hook allowlist| deny           | deny          |
| `dev`      | bridge               | L7 hook allowlist| L7 hook allowlist| allow       |
| `open`     | bridge               | allow            | allow          | allow         |
| `offline`  | **none**             | deny             | deny           | deny          |

**Important:** Only the `offline` mode has L3 (Docker network) filtering.
In the other modes, the L7 hook (`net-guard.sh`) applies **only to Claude
tool calls**. Codex and the user shell can open sockets to all
destinations.

### L7 hook (net-guard.sh)

```
Claude is about to call a tool
      │
      ▼
settings.local.json: PreToolUse matcher
      │
      ▼
net-guard.sh < {tool_name, tool_input}
      │
      ├── WebFetch  → parses the URL → compares the host with allowed-domains.txt
      ├── WebSearch → deny
      └── Bash      → parses the command line with python3:
                       finds http(s)://, ssh://, git@host: URLs
                       → compares each host with the allowlist
      │
      ▼
allowed? → exit 0 (continue)
denied?  → JSON with hookSpecificOutput.permissionDecision="deny"
```

The hook works **at L7 only**. It sees only the call that Claude is about
to make. If the agent writes `curl_url="https://evil.com"; eval "curl $curl_url"`,
the hook finds the URL. If the agent runs `python3 myscript.py` and the URL
is in the file, the hook does not find it. The URL is not in the command
line.

### Allowlist format (allowed-domains.txt)

- One host on each line.
- Exact match: `github.com`.
- All subdomains: `.github.com` (matches the apex and all subdomains).
- Glob form: `*.githubusercontent.com`.
- The hook ignores `#` comments and empty lines.

The current allowlist permits: the OpenAI and Anthropic APIs, GitHub and
GitLab, and the npm, PyPI and RubyGems registries.

## Image build

```
build.sh
  │
  ├── source versions.env                  → ${CODEX_VERSION}, ${CLAUDE_VERSION}, ${NODE_IMAGE}
  └── docker build
        --build-arg NODE_IMAGE / CODEX_VERSION / CLAUDE_VERSION
        -t ai-sandbox:codex-X_claude-Y
        -f ${ROOT}/.ai-sandbox/Dockerfile
        ${ROOT}/.ai-sandbox                ← build context (minimum)
                  │
                  └── .dockerignore: home/, *.md, .git
```

The build context is only the `.ai-sandbox/` directory (some KB). It is not
the parent project. This gives these results:

- The build is fast. Docker does not copy `node_modules` or similar
  directories.
- User secrets do not go into the build context.
- `.dockerignore` removes `home/` (the state) from the context.

### Dockerfile stages

```
node:22-bookworm-slim                       (base image)
      │
      ▼
apt: bash, ca-certs, git, jq, libnss-wrapper, python3, ripgrep, tini
      │
      ▼
npm: @openai/codex@<X>, @anthropic-ai/claude-code@<Y>
      │
      ▼
/etc/claude-code/managed-settings.json      (added at build time, not from a mount)
      │
      ▼
COPY entrypoint.sh /usr/local/bin/
      │
      ▼
WORKDIR /workspace
ENTRYPOINT [tini, --, ai-sandbox-entrypoint]
CMD [bash]
```

The image has no state. All state (Claude and Codex history, caches) is in
`/home/sandbox`. This directory is a persistent mount from the host.

## CLI update

```
./.ai-sandbox/check-updates.sh              → npm view, compare with the pinned versions
./.ai-sandbox/update.sh [--codex X --claude Y]
        │
        ├── no arguments — update both to latest
        ├── write versions.env again (backup in .bak)
        └── build.sh                          (build the image again)
```

After an update, the image tag changes (`ai-sandbox:codex-X_claude-Y`).
The old image stays in the local Docker storage. To go back to it, use
`docker tag` manually, or run `update.sh --codex <old> --claude <old>`.

## State locations

| Path                                         | Persistence       | Purpose                             |
|----------------------------------------------|-------------------|-------------------------------------|
| `~/.config/ai-sandbox/credentials.env`       | host (vendor-independent) | API keys, shared by all projects |
| `<project>/.ai-sandbox/home/.codex/`         | bind mount, persistent | Codex config and history       |
| `<project>/.ai-sandbox/home/.config/`        | bind mount, persistent | Claude config and auth state   |
| `<project>/.claude/settings.local.json`     | host, generated for each run | Mode-specific Claude restrictions |
| `<project>/.claude/settings.json`            | host, committed   | Project-level deny list             |
| `<project>/.mcp.json`                        | host, committed   | MCP server registration             |
| Docker image                                 | Docker storage    | Pinned CLI versions                 |
| `/tmp`, `/run` in the container              | tmpfs, ephemeral  | Cleared at exit                     |

## `run.sh` structure (logical blocks)

The line numbers show the 2026-05-28 version. Later changes moved them.

```
1. CONFIG          (lines 1–13)
   ROOT, CREDS_FILE, IMAGE_TAG, AI_SANDBOX_MEMORY/CPUS/PIDS

2. CLI parsing     (lines 15–48)
   --mode, --help, -- end-of-options

3. RENDER          (lines 50–195)
   render_claude_local_settings (5 mode-specific templates)
   render_codex_config (idempotent, uses a marker)

4. BUILD CHECK     (lines 197–199)
   docker image inspect, fallback to build.sh

5. DOCKER_ARGS     (lines 201–234)
   Constraints: read-only, cap-drop, no-new-privileges, limits, tmpfs
   Env: HOME, XDG_*, AI_SANDBOX_*, telemetry off
   Mounts: workspace rw, home rw, configs ro

6. MODE-OVERRIDES  (lines 236–240)
   case offline → --network=none

7. CREDENTIALS     (lines 242–244)
   --env-file if credentials.env exists

8. EXEC            (lines 246–250)
   default $@ → bash
   exec docker run [...] image $@
```

## What the architecture does not do

These limits are intentional parts of the design:

- **It does not control more than one container.** There is one container
  for each session. For more services, use a separate docker-compose file.
- **It does not manage keys in the cloud.** The credentials are a file on
  the host. The user owns this file.
- **It does not update automatically.** To update the CLI, run `update.sh`.
- **It does not prevent a direct `docker run`.** The sandbox is `run.sh`.
  If the user does not use it, the user makes that decision.
- **It does not verify npm package signatures.** It trusts the npm registry.
  Version pinning gives reproducibility.
- **It does not have an L3 network filter, except in offline mode.** This
  is a **known gap** in the current version. Refer to ROADMAP.md §NET-01.
