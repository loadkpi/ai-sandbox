# Architecture Decision Records

These are short records of the key decisions. Each record tells what we
selected, what we rejected, and why. The format is a simplified ADR (one
number = one decision). If a decision changes, we do not delete the old
record. We mark it `Superseded by #N`.

---

## ADR-001: Base image — `node:22-bookworm-slim`

**Status:** accepted

**Context:** We need an image for `@openai/codex` and
`@anthropic-ai/claude-code` (both are npm packages). The candidates were
Alpine, Debian bookworm and Ubuntu.

**Decision:** `node:22-bookworm-slim`.

**Reasons:**
- It uses glibc. Alpine uses musl, and musl breaks some native npm modules.
- `bookworm-slim` is much smaller than the full `bookworm` (~80MB and
  ~200MB).
- Node 22 LTS meets the requirements of the current Claude and Codex CLIs.
- Debian has `libnss-wrapper` as a package. We need it to run with the
  host UID.

**Rejected:**
- Alpine. It has no `libnss-wrapper` without a separate build. The musl ABI
  breaks some native add-ons (sharp, sqlite3).
- Ubuntu. It is larger than bookworm and gives no advantages.
- Distroless. It has no shell, so interactive use does not work.

---

## ADR-002: Version pinning with `versions.env` + ARG

**Status:** accepted

**Context:** The builds must be reproducible. We must not use `@latest`.

**Decision:** Keep the versions in a separate file, `versions.env`. Send
them to the Dockerfile with `--build-arg`. Put them in the image tag
(`ai-sandbox:codex-X_claude-Y`).

**Reasons:**
- There is one source of truth (`versions.env`).
- The image tag shows the versions. Old builds stay available.
- `update.sh` changes one file and builds the image again.
- The Dockerfile does not change.

**Rejected:**
- Versions directly in the Dockerfile. Each update then changes the
  Dockerfile.
- npm shrinkwrap. It is too much for two packages, and it adds one more
  file.

**Open:** Pinning of the base image digest
(`node:22-bookworm-slim@sha256:...`). We must examine this separately.

---

## ADR-003: The `.ai-sandbox/` subdirectory layout

**Status:** accepted (iteration 2026-05-28)

**Context:** The project is a template that you copy into other projects.
We had to select a layout.

**Decision:** All sandbox files go into the `.ai-sandbox/` subdirectory of
the target project. The root of the target project gets only the files
that must be there (`.claude/`, `.mcp.json`, `.gitignore`).

**Reasons:**
- One prefix for the full sandbox. It is easy to find and easy to remove.
- `.ai-sandbox/` follows the de facto convention (`.devcontainer/`,
  `.github/`, `.vscode/`).
- `.claude/settings.json` and `.mcp.json` must be in the root. Claude Code
  and MCP require this.
- The workspace gets a minimum of new files.

**Rejected:**
- Files in the repository root. This gives too many top-level files.
- `.config/ai-sandbox/`. This location is not standard for project files.
- A binary with a config (`~/.local/bin/ai-sandbox`). This loses the
  isolation for each project.

---

## ADR-004: API keys in `~/.config/ai-sandbox/credentials.env`

**Status:** accepted

**Context:** All projects of the user must have access to the keys. The
keys must not be in the repository.

**Decision:** One file, `~/.config/ai-sandbox/credentials.env`. `--env-file`
sends it to the container.

**Reasons:**
- The path is XDG compatible (`$XDG_CONFIG_HOME`).
- One file gives one location for key rotation.
- `--env-file` is a native Docker mechanism. It does not need a mount.

**Rejected:**
- A `.env` file for each project. This duplicates the keys.
- The host keyring (secret-tool, security). It is more complex, and it does
  not work headless.
- Vault / 1Password CLI. This adds an external dependency.

**Open:** UX-01 in TASK.md describes a cascaded override (global + for
each project). It is postponed.

---

## ADR-005: Read-only rootfs + RO bind on the rw workspace

**Status:** accepted (iteration 2026-05-28)

**Context:** The agent must not change its own rules (`run.sh`,
`Dockerfile`, `settings.json`). But `/workspace` must be rw for usual work.

**Decision:** Mount `/workspace` as rw. On top of it, bind-mount the
specified config files as `:ro`, one file over one file.

**Reasons:**
- Linux correctly supports an RO mount on an rw parent.
- We do not need two mount points and a copy.
- The protection is **physical**. An agent that bypasses the deny list
  still cannot write.

**Rejected:**
- `chattr +i` (immutable). It does not work on overlayfs and some other
  file systems. It needs CAP_LINUX_IMMUTABLE.
- An RO mount of the full workspace. This breaks the main use case.
- OverlayFS with a read-only lowerdir. It is more complex and gives the
  same result.

---

## ADR-006: `--user $UID:$GID` + libnss_wrapper

**Status:** accepted

**Context:** The container must not run as root. Root gives a privilege
escalation risk, and root creates files on the host with root as the owner.

**Decision:** `docker run --user "$(id -u):$(id -g)"` + libnss_wrapper to
emulate the `/etc/passwd` entry for this UID.

**Reasons:**
- Files in the bind mounts have the correct owner on the host.
- Privilege escalation in the container is more difficult.
- This is a standard Docker security pattern.

**Rejected:**
- A fixed UID 1000. It does not work if the host UID is not 1000.
- User namespaces (`--userns-remap`). This is a Docker daemon setting, not
  a setting for each container.
- `useradd` with the host UID at build time. This gives one UID for each
  image.

**Related:** ADR-009 (no root→setpriv for a firewall).

---

## ADR-007: Five modes of operation

**Status:** accepted (iteration 2026-05-28)

**Context:** The user needs different levels of restriction for different
tasks (full isolation, usual development, debugging).

**Decision:** Five modes through `--mode`: `default`, `webfetch`, `dev`,
`open`, `offline`. Each mode generates `settings.local.json`, enables or
disables the hooks, and sets its network access.

**Reasons:**
- The modes cover the main scenarios.
- The user selects the mode explicitly. There is no hidden logic.
- Templates with `cat <<JSON` are simple.

**Rejected:**
- One mode with flags (`--web`, `--bash-net`, ...). There are too many
  combinations, and they are difficult to explain.
- A two-level model (`safe` / `unsafe`). It is not granular enough.

**Related:** ADR-008 (offline mode → `--network=none`).

---

## ADR-008: `offline` mode = `--network=none`

**Status:** accepted (iteration 2026-05-28)

**Context:** We need a mode with **full** network isolation. It is for
code audits and for the analysis of untrusted content.

**Decision:** `--mode offline` adds `--network=none` to docker run.

**Reasons:**
- It is simple, and it works on all Docker installations.
- It fully removes the network at L3. No bypass is possible.
- It is clear. The user knows that nothing goes out in offline mode.

**Rejected:**
- An iptables firewall only for offline. Refer to ADR-009 (postponed).
- A network namespace with loopback only. This is the same thing in a
  different Docker syntax.

---

## ADR-009: No iptables firewall in this iteration

**Status:** postponed (iteration 2026-05-28)

**Context:** Real L3 filtering in the default, webfetch and dev modes is
the goal of TASK.md NET-01. The Anthropic pattern (init-firewall.sh) needs
root in the container + `setpriv` to drop the privileges.

**Decision:** Do not implement it in this iteration. Use only the `offline`
mode for full isolation. The default, webfetch and dev modes use the bridge
network.

**Reasons for the rejection:**
- A start as root → setpriv breaks `--user` (refer to ADR-006).
- It does not work in rootless Docker or Podman (NET_ADMIN has no effect).
- It makes the entrypoint more complex (~60 lines, not 27).
- If an error occurs before setpriv, files with uid=0 can appear on the
  host.
- `docker exec` without `-u` gives root in the container.

**Accepted instead:** The L7 hook (`net-guard.sh`) for Claude tool calls +
a deny list for crude bypasses (`nc`, `socat`, ...).

**Postponed:** The real NET-01 with a **sidecar pattern** (the ROADMAP
recommends it). A separate init container with NET_ADMIN sets iptables in
the shared netns. The main container starts with `--user` and no caps.

**Documented as a limitation:** README.md §"Known limitations",
THREAT-MODEL.md, IMPLEMENTATION.md, ROADMAP.md.

---

## ADR-010: Codex as an MCP server for Claude

**Status:** accepted

**Context:** The project name is "Claude Code + Codex". You can run both in
parallel. But it costs less to give Codex to Claude as a tool.

**Decision:** `.mcp.json` registers Codex as a stdio MCP server.

**Reasons:**
- Claude gets the Codex tools without a separate session.
- There is one Docker container for each session.
- MCP is a standard protocol, and Codex supports it.

**Rejected:**
- Parallel shell sessions. They need two containers and state
  synchronization.
- Only Claude or only Codex. This loses the use of more than one model.

**Open:** A registry for more than one MCP server, in the ROADMAP.

---

## ADR-011: Resource limits through environment overrides

**Status:** accepted (iteration 2026-05-28)

**Context:** The user must be able to change the memory and CPU limits
without a change to the scripts.

**Decision:** `AI_SANDBOX_MEMORY` (default 4g), `AI_SANDBOX_CPUS`
(default 2), `AI_SANDBOX_PIDS` (default 1024). `run.sh` reads these
environment variables.

**Reasons:**
- 4g/2cpu is a good default for a usual npm or build workload.
- An environment override is simpler than a config file.
- `--memory-swap = --memory` closes the swap escape. You cannot change it.
  This is a fundamental decision.

**Rejected:**
- Limits for each mode. This adds complexity. The override already gives
  flexibility.
- A global config in `~/.config/`. This is for the next iteration (UX-01).

---

## ADR-012: arm64 support through an ldconfig lookup + an architecture-aware fallback

**Status:** accepted (iteration 2026-05-28)

**Context:** The initial entrypoint had a fixed path,
`/usr/lib/x86_64-linux-gnu/...`. It did not work on Apple Silicon or other
arm64 hosts.

**Decision:** First, use `ldconfig -p`. It finds the library on all
architectures. Then, as a fallback, try the amd64 and arm64 paths in a loop.

**Reasons:**
- `ldconfig` is always available in Debian-based images.
- The fallback covers the rare case when there is no ldconfig cache.
- It does not need a multi-arch image (but it does not prevent one).

**Rejected:**
- A full multi-arch image with buildx. This is a separate task (ROADMAP).
- An apt installation of only the necessary architecture. apt already
  installs the correct architecture.

---

## ADR-013: Defense-in-depth deny list in `.claude/settings.json`

**Status:** accepted (iteration 2026-05-28)

**Context:** The L7 hook catches network calls through Bash, but only if
the URL is in the command line. `python3 -c 'import urllib...'` or
`node -e 'fetch(...)'` bypass the hook. The URL is in a string argument,
not in URL format.

**Decision:** Add deny rules for these ad-hoc forms to
`.claude/settings.json` (`nc`, `socat`, `python3 -c *urllib*`, and
similar).

**Reasons:**
- This is defense in depth. It is not the main protection, but it blocks
  crude bypasses.
- It is a simple JSON string, with no code.
- Claude pattern matching covers most of the simple variants.

**Known limitation:**
- A change of quotes, variables or base64-encoded code bypasses a pattern
  deny. This is **L1 protection**, not a **guarantee**. THREAT-MODEL.md
  states this clearly.

**Rejected:**
- A full list of all possible bypasses. This is not possible. Explicit
  network isolation is better (NET-01, postponed).

---

## ADR-014: `install.sh` is idempotent and does not overwrite user files

**Status:** accepted (iteration 2026-05-28)

**Context:** You must be able to run install.sh again (to update the
template in an existing project).

**Decision:**
- `.ai-sandbox/` is always overwritten (`cp -r src/. dst/`).
- `.claude/settings.json` and `.mcp.json` are copied **only if they do not
  exist**. The output then shows `= kept existing`.
- `.gitignore` is merged with `grep -qxF`. It does not duplicate lines.

**Reasons:**
- The template can change freely.
- The user owns the customizations in `.claude/settings.json` and
  `.mcp.json`.
- The `.gitignore` merge does not lose lines.

**Rejected:**
- Overwrite all files. This loses the user changes.
- Do not update `.ai-sandbox/` if it changed. Then you cannot update
  without a removal.

---

## Template for new decisions

```markdown
## ADR-NNN: <short title>

**Status:** accepted / rejected / postponed / superseded by #M

**Context:** Why we had to make a decision.

**Decision:** What we selected.

**Reasons:** Why.

**Rejected:** The alternatives that we examined, and why we rejected them.

**Related:** Links to other ADRs and tasks.
```
