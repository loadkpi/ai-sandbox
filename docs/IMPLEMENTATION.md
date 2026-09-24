# AI Sandbox — iteration report

Date: 2026-05-28
Branch: `main`
Base commit: `180d215`

This is a historical report. It shows the state on the date above. Later
changes are not included. For example, the Codex model is now set in
`versions.env` (`CODEX_MODEL`), not in `run.sh`.

## Context

The `ai-sandbox` repository is a Docker sandbox template for Claude Code +
Codex CLI. You copy it into a target project as the `.ai-sandbox/`
subdirectory. Before this iteration, it did not work:

- All sandbox files were in the repository root. But the scripts used
  `${ROOT}/.ai-sandbox/...` (`ROOT = parent of script dir`). These paths did
  not exist.
- `.gitignore` had a typo: `/.ai_sandbox/`, not `.ai-sandbox/`. Thus git
  could commit the local state with keys and AI history.
- The README stopped in the middle of a code block at line 46.
- There were no instructions to install the template in a different
  project.
- TASK.md described critical security improvements (NET-01, MEM-01, SEC-01,
  BUILD-01, SEC-03). They were not implemented.

## User decisions

| Question | Decision |
|----------|----------|
| Layout | Move all files into `.ai-sandbox/` (this is a template for vendoring) |
| Installation | Three procedures in the README: manual copy / git submodule / `install.sh` |
| Iteration scope | Blockers + security (without NET-01) |
| NET-01 (iptables firewall) | Postponed. The disadvantages of root→setpriv (refer to the next section) were more important. Only `--mode offline` (`--network=none`) gives full isolation |
| Codex model | `gpt-5.5` (newer than `gpt-5.4`). Verify it after the build |
| Web search during planning | Permitted |

### Why NET-01 is postponed

An Anthropic-style iptables firewall needs a container start as root +
`setpriv` to drop the privileges. The user did not accept these
disadvantages:

1. Files can accidentally get root as the owner before setpriv.
2. If init-firewall.sh fails, the container can stay in a dangerous,
   partially applied state.
3. `docker exec` without `-u` gives root in the container.
4. Rootless Docker and Podman stop working (NET_ADMIN has no effect).
5. `setpriv --clear-groups` removes the supplementary groups.
6. The entrypoint becomes more complex (~60 lines, not 27).
7. CI/CD pipelines conflict with our `--user` logic.
8. On a read-only rootfs + root, each `apt install` or `/etc` change
   fails. This can surprise users.

## Plan

1. Layout: `git mv` / `mv` all sandbox files into `.ai-sandbox/`.
2. Repair `.gitignore`.
3. Dockerfile: the COPY path (the context is now `.ai-sandbox/`).
4. run.sh: limits + RO mounts + offline mode + unique name + codex marker + gpt-5.5.
5. build.sh: make the context smaller, only `.ai-sandbox/`.
6. entrypoint.sh: arm64 libnss fallback.
7. `.ai-sandbox/.dockerignore`: new.
8. `.claude/settings.json`: a larger deny list.
9. README.md: a full rewrite.
10. `install.sh`: new, in the repository root.
11. Verification.

## What was done

### 1. Layout
```
Dockerfile         → .ai-sandbox/Dockerfile         (git mv)
run.sh             → .ai-sandbox/run.sh             (git mv)
entrypoint.sh      → .ai-sandbox/entrypoint.sh      (mv)
build.sh           → .ai-sandbox/build.sh           (mv)
update.sh          → .ai-sandbox/update.sh          (mv)
check-updates.sh   → .ai-sandbox/check-updates.sh   (mv)
versions.env       → .ai-sandbox/versions.env       (mv)
allowed-domains.txt → .ai-sandbox/allowed-domains.txt (mv)
hooks/net-guard.sh → .ai-sandbox/hooks/net-guard.sh (mv)
```
These files stayed in the root: `.claude/`, `.mcp.json`, `README.md`,
`TASK.md`, `.gitignore`, `install.sh` (new), `IMPLEMENTATION.md` (this
file).

### 2. `.gitignore`
```gitignore
/.ai-sandbox/home/
/.claude/settings.local.json
/.idea/
/.vscode/
/.env
/.env.*
```
The `_` → `-` typo is repaired. Git now ignores `settings.local.json`.

### 3. Dockerfile
Only `COPY` changed:
- Before: `COPY .ai-sandbox/entrypoint.sh /usr/local/bin/ai-sandbox-entrypoint`
- After: `COPY entrypoint.sh /usr/local/bin/ai-sandbox-entrypoint`

The build context is now `.ai-sandbox/`.

### 4. run.sh (main changes)
- New environment overrides: `AI_SANDBOX_MEMORY` (4g), `AI_SANDBOX_CPUS`
  (2), `AI_SANDBOX_PIDS` (1024).
- The `offline` mode is added to the validator and to
  `render_claude_local_settings`.
- `render_codex_config` is now idempotent. The first line is the marker
  `# managed-by: ai-sandbox/run.sh — DO NOT EDIT (regenerated each run)`.
  If the file exists without the marker, the script does not change it.
- Codex model: `gpt-5.4` → `gpt-5.5`.
- `include_only` for shell_environment_policy now also contains
  `GITHUB_TOKEN`, `GH_TOKEN`, `NPM_TOKEN`, `PIP_INDEX_URL`.
- `--name` is now `ai-sandbox-<basename>-$$` (PID). This removes the
  conflict between parallel sessions.
- New items in `DOCKER_ARGS`:
  - `--memory ${AI_SANDBOX_MEMORY}`
  - `--memory-swap ${AI_SANDBOX_MEMORY}` (= memory, closes the swap escape)
  - `--cpus ${AI_SANDBOX_CPUS}`
  - `--pids-limit ${AI_SANDBOX_PIDS}`
  - RO bind mounts (on the rw `/workspace`):
    - `.ai-sandbox/run.sh`
    - `.ai-sandbox/build.sh`
    - `.ai-sandbox/update.sh`
    - `.ai-sandbox/check-updates.sh`
    - `.ai-sandbox/Dockerfile`
    - `.ai-sandbox/entrypoint.sh`
    - `.ai-sandbox/versions.env`
    - `.ai-sandbox/hooks/` (directory)
    - `.ai-sandbox/allowed-domains.txt`
    - `.claude/settings.json`
    - `.mcp.json`
- `case "${MODE}" in offline) DOCKER_ARGS+=( --network=none ) ;; esac`

### 5. build.sh
The last argument changed: `"${ROOT}"` → `"${ROOT}/.ai-sandbox"`. The
build context is now only the sandbox directory.

### 6. entrypoint.sh
The fixed fallback `/usr/lib/x86_64-linux-gnu/libnss_wrapper.so` is
replaced by an architecture-aware loop:
```bash
LIB="$(ldconfig -p 2>/dev/null | awk '/libnss_wrapper\.so/{print $NF; exit}')"
if [[ -z "${LIB}" ]]; then
  for cand in /usr/lib/x86_64-linux-gnu/libnss_wrapper.so \
              /usr/lib/aarch64-linux-gnu/libnss_wrapper.so; do
    [[ -e "${cand}" ]] && LIB="${cand}" && break
  done
fi
export LD_PRELOAD="${LIB}"
```

### 7. `.ai-sandbox/.dockerignore` (new)
```
home/
*.md
.git
```

### 8. `.claude/settings.json`
These items are added to the existing `Read(...)` deny list:
- `Edit/Write` for `./.ai-sandbox/**`, `.claude/settings.json`, `.mcp.json`
- `Bash(nc *)`, `Bash(ncat *)`, `Bash(socat *)`
- `Bash(python[3] -c *urllib*|*requests*|*socket*|*http.client*)`
- `Bash(node -e *fetch*|*http*|*https*|*net*)`
- `Bash(perl -e *Socket*)`, `Bash(perl -MIO::Socket*)`

This is defense in depth on top of the RO bind mounts and the L7 hook.

### 9. README.md (full rewrite)
Structure:
1. What it is and why
2. What you get (features)
3. Prerequisites + credentials.env
4. Install — 3 procedures (A: install.sh, B: manual copy, C: git submodule)
5. First run
6. **Modes** — a table with 5 modes × 4 columns
7. Security model (FS / caps / limits / user / network / Claude managed)
8. **Known limitations** — states clearly that NET-01 comes later
9. Customizing the allowlist
10. Updating CLI versions
11. Troubleshooting (cgroups, submodule, name conflicts, codex model, arm64)
12. Files table

### 10. install.sh (new, in the repository root)
```bash
./install.sh [target-dir]
```
- It is idempotent (`cp -r .../.` for `.ai-sandbox/`).
- It does not overwrite an existing `.claude/settings.json` or `.mcp.json`.
- It merges `.gitignore`. It adds the missing lines and does not duplicate
  lines.
- It does not install the template into itself.
- It prints `+` or `=` for each file.

### 11. Verification (without Docker)
- `bash -n` on all 7 shell scripts: OK.
- `jq .` on `settings.json` and `.mcp.json`: OK.
- `install.sh` in `mktemp -d`, two runs:
  - First run: 13 files copied, `.gitignore` created with 2 lines.
  - Second run: `.ai-sandbox/` updated, user files kept
    (`= kept existing`), `.gitignore` not duplicated.
- `grep` for the key changes in run.sh: all are present
  (`gpt-5.5`, `managed-by`, `GITHUB_TOKEN`, `--memory`, `--cpus`,
  `offline`).

## What was not done (known limitations)

### NET-01 — network isolation outside `offline`
In the `default`, `webfetch`, `dev` and `open` modes, the container has
full bridge access to the internet. The L7 hook `net-guard.sh` filters
**only** Claude tool calls. Codex and all user shells can open sockets to
all destinations. Defense in depth (the deny list in settings.json for
`nc`, `socat`, etc.) blocks simple bypasses. It does not stop an attacker
with a unique payload.

**Only `--mode offline` (`--network=none`) gives full isolation.**

Next iteration: an iptables firewall with correct root→setpriv handling,
or a sidecar pattern.

### Docker verification
The sandbox harness for this work did not permit `docker` commands. Do
these checks locally:

```bash
# Build (must be fast — the context is some tens of KB)
./.ai-sandbox/build.sh

# Memory/CPU limits
./.ai-sandbox/run.sh -- bash -lc 'cat /sys/fs/cgroup/memory.max; nproc'
# expected: 4294967296, 2

AI_SANDBOX_MEMORY=2g AI_SANDBOX_CPUS=1 ./.ai-sandbox/run.sh -- \
  bash -lc 'cat /sys/fs/cgroup/memory.max; nproc'
# expected: 2147483648, 1

# RO mounts block writes
./.ai-sandbox/run.sh -- bash -lc '
  echo x >> /workspace/.ai-sandbox/run.sh && echo WROTE || echo blocked
  echo x >> /workspace/.claude/settings.json && echo WROTE || echo blocked
'
# expected: blocked for both

# The workspace stays writable
./.ai-sandbox/run.sh -- bash -lc 'echo ok > /workspace/scratch && cat /workspace/scratch && rm /workspace/scratch'

# Offline — no network
./.ai-sandbox/run.sh --mode offline -- bash -lc \
  'curl -sS --max-time 3 https://api.anthropic.com/ || echo blocked'

# Default — network is available
./.ai-sandbox/run.sh --mode default -- bash -lc \
  'curl -sS --max-time 5 https://api.anthropic.com/ -o /dev/null -w "%{http_code}\n"'

# The Codex model is valid
./.ai-sandbox/run.sh -- bash -lc 'codex --version'

# Parallel sessions — must not fail with a --name conflict
./.ai-sandbox/run.sh -- sleep 60 &
./.ai-sandbox/run.sh -- bash -lc 'hostname'
wait
```

### Codex model `gpt-5.5`
The Plan agent recommended this model. It referred to
`developers.openai.com/codex/models`. It was not verified on a live build.
If Codex CLI does not accept it, there are two options in
`.ai-sandbox/home/.codex/config.toml`:

1. Remove the `# managed-by: ...` line (this stops the regeneration).
   Then change it to `model = "gpt-5.4"`, or remove the `model = ...` line.
2. In `.ai-sandbox/run.sh`, change the `render_codex_config` function back:
   `model = "gpt-5.5"` → `model = "gpt-5.4"`.

README.md contains this fallback in the troubleshooting section.

### Not changed

- `.ai-sandbox/hooks/net-guard.sh`: correct, used as it is.
- `.ai-sandbox/versions.env`: the pinning format works.
- `.ai-sandbox/update.sh`, `.ai-sandbox/check-updates.sh`: the paths are
  correct after the move.
- `.mcp.json`: the Claude Code docs confirm that the `${OPENAI_API_KEY}`
  syntax works.
- `disableBypassPermissionsMode: "disable"`: the line is correct (the docs
  confirm it).
- `TASK.md`: kept as a roadmap for the next iterations (UX-01/02,
  OPS-01/02, NET-01).

## Changed files

| File | Action |
|------|--------|
| `Dockerfile` → `.ai-sandbox/Dockerfile` | mv + COPY path fix |
| `run.sh` → `.ai-sandbox/run.sh` | mv + large rework (refer to §4) |
| `entrypoint.sh` → `.ai-sandbox/entrypoint.sh` | mv + arm64 fallback |
| `build.sh` → `.ai-sandbox/build.sh` | mv + context |
| `update.sh` → `.ai-sandbox/update.sh` | mv (no changes) |
| `check-updates.sh` → `.ai-sandbox/check-updates.sh` | mv (no changes) |
| `versions.env` → `.ai-sandbox/versions.env` | mv (no changes) |
| `allowed-domains.txt` → `.ai-sandbox/allowed-domains.txt` | mv (no changes) |
| `hooks/net-guard.sh` → `.ai-sandbox/hooks/net-guard.sh` | mv (no changes) |
| `.ai-sandbox/.dockerignore` | new |
| `.gitignore` | rewritten |
| `.claude/settings.json` | larger deny list |
| `README.md` | full rewrite |
| `install.sh` | new, in the repository root |
| `IMPLEMENTATION.md` | this file |
