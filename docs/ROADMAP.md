# AI Sandbox — options for further development

This file is a roadmap, not a plan. The ideas are sorted by priority. But
the order of implementation depends on how people use the project.
TASK.md stays the source of truth for the initial design. This file
contains the items that remain from TASK.md, and new items from the
current iteration.

## Tier 1 — close the initial TASK.md

### NET-01: real network isolation (iptables / nftables firewall)

**Why:** At this time, the `default`, `webfetch` and `dev` modes have a
bridge network without an L3 filter. The L7 hook covers only Claude tool
calls. Codex and all user shells can open sockets to all destinations.
This is the main gap in the sandbox.

**Implementation options** (from simple to clean):

1. **root → setpriv in the entrypoint** (Anthropic devcontainer pattern)
   - Advantage: no architecture changes are necessary.
   - Disadvantage: it breaks rootless Docker and Podman, conflicts with
     `--user`, makes the entrypoint more complex, and gives `docker exec`
     risks without `-u`. `IMPLEMENTATION.md` lists the disadvantages.

2. **Sidecar init container**
   - The first `docker run --rm` with `NET_ADMIN` in a shared network
     namespace sets iptables and stops.
   - The second container is the main one, with `--user` and no caps.
   - Advantage: clean separation of roles. `--user` stays.
   - Disadvantage: the orchestration in `run.sh` becomes more complex (two
     commands + a wait + a shared namespace through
     `--network=container:<name>`).

3. **DNS allowlist through an unbound/coredns sidecar**
   - A custom bridge network. The container uses `--dns=<sidecar-ip>`. The
     sidecar returns NXDOMAIN for domains that are not permitted.
   - Advantage: no `NET_ADMIN` is necessary. It works rootless.
   - Disadvantage: `getent ahosts` + a raw IP, or `--resolver` in
     curl/wget, easily bypass it. The protection is not real.

4. **Egress proxy (mitmproxy/squid) in a sidecar**
   - The container gets the `HTTP_PROXY`/`HTTPS_PROXY` environment
     variables. The proxy filters by a host/path allowlist.
   - Advantage: real L7 control. It works with TLS through a MITM
     certificate (the container trusts only this certificate).
   - Disadvantage: it breaks applications that ignore `HTTP_PROXY`
     (possibly also Claude/Codex for non-HTTP calls). MITM on TLS has many
     edge cases.

**Recommendation for the next iteration:** option 2 (sidecar init
container). It keeps `--user`, it does not break rootless mode, and it
does not make the entrypoint more complex.

### UX-01: global API keys

At this time, the credentials are in `~/.config/ai-sandbox/credentials.env`.
This is half done. The remaining items from TASK.md:

- A cascade: a project `.ai-sandbox/.env` on top of the global file.
- A `.env.example` template at the first start.
- A global directory `~/.ai-sandbox/` for shared data (separate from the
  state of each project).

### UX-02: master prompt

A standard `~/.ai-sandbox/master-prompt.md`. The sandbox renders it into
the `CLAUDE.md` of the target project and into the Codex
`instructions_file`. TASK.md §UX-02 gives the full description.

### OPS-01: HEALTHCHECK in the Dockerfile

This is simple:
```dockerfile
HEALTHCHECK --interval=30s --timeout=5s --retries=2 \
  CMD [ "bash", "-c", "echo ok" ]
```

### OPS-02 → README — partially done. The remaining items:

- Screenshots or an asciicast of the first start.
- A "FAQ" section with real user questions (added when questions occur).
- Versions for the template itself (CHANGELOG.md).

## Tier 2 — code quality improvements

### Tests for the sandbox

`test/` now contains Bash tests for the net-guard hook and for the `run.sh`
arguments. They do not need Docker. The next step is a `bats` (Bash
Automated Testing System) suite that also starts containers:

- `test/test_install.bats` — install.sh in a tmpdir, idempotency check.
- `test/test_run_smoke.bats` — `./.ai-sandbox/run.sh -- true` (smoke).
- `test/test_ro_mounts.bats` — a write to an RO mount → blocked.
- `test/test_offline.bats` — `--mode offline` blocks the network.
- `test/test_limits.bats` — `--memory` is applied.

CI through GitHub Actions with `docker-in-docker`.

### Multi-arch images

At this time, the image is built for the architecture of the build host.
For Apple Silicon + amd64 servers:

```bash
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t ai-sandbox:... \
  --push .
```

Publish pre-built images (for example, `ghcr.io/<owner>/ai-sandbox`). Then
users do not have to build locally. `run.sh` can do a `docker pull` if the
image is not found.

### First-class support for rootless Docker and Podman

Make sure that the current configuration works in:
- Rootless Docker (Linux)
- Podman (crun driver)
- Docker Desktop (macOS / Windows)

If there are differences, add mode detection to `run.sh`.

### Pre-commit hook for the allowlist

A script `.ai-sandbox/check-allowed-domains.sh` that:
- Makes sure that all lines in `allowed-domains.txt` are valid domain
  names (no `://`, no paths, no ports).
- Resolves each name, and shows a warning if a name does not resolve.
- Can be a git pre-commit hook in the template.

## Tier 3 — feature extensions

### Support for `--mode custom`

The user supplies their own `.claude/settings.json.template` and
`config.toml.template`. `run.sh` renders them. At this time, the modes are
fixed in `render_claude_local_settings`. Use `envsubst` or a simple `cat`
for the templates.

### Log of blocked requests

`net-guard.sh` knows what it blocks, but it does not write a log. Add:
- A log in `${HOME}/.ai-sandbox/blocked.log` (in the container).
- Optionally, a JSON event to the host stderr (through a bind-mounted unix
  socket).
- Later analysis: the domains that the agent often tries to use are
  candidates for the allowlist.

### Session recording and playback

An optional feature: record stdin/stdout of the full session (with
`script` or `asciinema`) to `.ai-sandbox/home/sessions/<timestamp>.cast`.
This is useful for audits and debugging.

### More than one model in one session

At this time, one Codex MCP server starts and uses one model. An
extension: more MCP servers in `.mcp.json` for different models (a
different GPT model, Claude through the API, a local llama through
ollama). The user selects the models. The sandbox must only map the
environment keys correctly.

### Web UI for the configuration

Very optional: a small `cmd-app` that:
- Edits `allowed-domains.txt` with suggestions (resolution).
- Shows the current limits and mode.
- Opens credentials.env in an editor with masked values.

Do not do this until users ask for it.

## Tier 4 — separate directions

### A sandbox for non-AI tools

The current architecture (`run.sh` + image + permission JSON) is general.
All CLIs that need a restricted environment can use the same tooling. You
can move the lower layer into a `lib-sandbox/` library. Then `ai-sandbox/`
is a special case.

### Dependency cache

At this time, `/home/sandbox/.cache/npm`, `pip` and `cargo` are isolated
for each project. You can add an optional shared volume
`~/.ai-sandbox/cache/<lang>/`. Then the next `npm ci` or `pip install`
uses the local cache. Risk: a cache trojan can go from one project to a
different project. By default, this is off.

### MCP servers on request

At this time, `.mcp.json` registers Codex statically. Add a registry of
MCP servers in `~/.ai-sandbox/mcp-registry.json`, and mode flags such as
`--mcp codex,github,filesystem`. `run.sh` then builds the final
`.mcp.json` at the start.

## What not to do

Anti-patterns to avoid:

- **Do not make it a general-purpose container orchestration.** This is a
  sandbox for one repository. If you need more related containers, use
  docker-compose or k8s.
- **Do not add an automatic `--pull always`.** The image must be
  reproducible from `versions.env`. An automatic pull causes "it works on
  my machine" problems.
- **Do not put cloud credentials in the config.** AWS/GCP keys need a
  separate cascade. Do not mix them with OPENAI_API_KEY in one file.
- **Do not add a `--privileged` mode, also not for debugging.** If the
  user needs it, the user runs `docker run` directly.

## Open questions

- Must we publish pre-built images on GHCR? The project is now public, so
  this is possible.
- Do we need native Windows support (without WSL2)? Most pipelines use
  WSL. Native Windows needs much work for a small result.
- Is an integration with `act` (a local GitHub Actions runner) useful? The
  sandbox can be a platform to run CI workflows locally with the same
  restrictions.
