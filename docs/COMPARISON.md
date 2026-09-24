# Comparison with alternatives

This document tells you when to use this sandbox and when to use a
different approach.

## TL;DR

| Task                                             | Use                       |
|--------------------------------------------------|---------------------------|
| Run Claude/Codex locally with protection         | **this sandbox**          |
| A full IDE environment with Claude               | devcontainer / Codespaces |
| A quick test with no security concerns           | `npm install -g` directly |
| Analysis of untrusted code or malware            | Firecracker VM / gVisor   |
| A remote dev environment with a GUI              | Codespaces / Gitpod       |
| A CI pipeline                                    | GitHub Actions / GitLab CI|

## Details

### Compared with `npm install -g @anthropic-ai/claude-code` (no isolation)

| Parameter               | This sandbox            | Direct installation       |
|-------------------------|-------------------------|---------------------------|
| `~/.ssh` protection     | ✓ (deny + not mounted)  | ✗ (full access)           |
| `~/.aws` protection     | ✓                       | ✗                         |
| Memory/CPU limits       | ✓ (`--memory`, `--cpus`) | ✗                         |
| Read-only rootfs        | ✓                       | ✗                         |
| Prompt injection protection| partial (deny list + RO)| ✗                      |
| Isolation from other projects| ✓ (home for each project) | ✗ (shared `~`)   |
| Setup effort            | docker run + 1 file     | npm install               |
| Speed (cold start)      | ~2-5s (after the build) | immediate                 |

**Use the direct installation if:** you trust the model and the project,
you work alone, and the security risk is low.

**Use the sandbox if:** you work with untrusted code, you have sensitive
data on the machine, you want reproducibility, or you need different modes
for different tasks.

### Compared with a Docker DevContainer (`.devcontainer/`)

| Parameter               | This sandbox             | DevContainer             |
|-------------------------|--------------------------|--------------------------|
| Target users            | CLI agents               | IDE (VS Code, JetBrains) |
| IDE integration         | no                       | ✓ (LSP, debugger, etc.)  |
| Specification           | own format               | devcontainer.json (standard) |
| Isolation for each mode | ✓ (5 modes)              | ✗ (one config)           |
| RO bind on the workspace| ✓                        | ✗ (usually)              |
| Network firewall        | offline mode             | the Anthropic example has iptables |
| Setup effort            | install.sh + run.sh      | needs an IDE + the spec  |
| Vendoring               | submodule / cp           | submodule / cp           |

**Use a devcontainer if:** you use VS Code or JetBrains, and you want full
IDE integration with lint, debug and test in the container.

**Use the sandbox if:** you work in a terminal, you need flexible security
modes, and you do not use one specified IDE.

You can use **both** in one project. Use the devcontainer for the IDE, and
use the sandbox for CLI sessions.

### Compared with GitHub Codespaces / Gitpod

| Parameter               | This sandbox        | Codespaces / Gitpod          |
|-------------------------|---------------------|------------------------------|
| Location                | local               | remote, in the cloud         |
| Cost                    | free                | paid (you pay for compute time)|
| Access to local files   | ✓                   | no (only git push/pull)      |
| Offline mode            | ✓                   | ✗ (always needs the internet)|
| Setup effort            | install.sh          | some clicks in a browser     |
| Access from all locations| no (one machine)   | ✓ (browser)                  |
| API keys                | your local keys     | the service secrets manager  |

**Use Codespaces or Gitpod if:** you work on different machines or devices,
you do not want to install Docker, you accept the cost, and you have a
stable internet connection.

**Use the sandbox if:** you work locally, you want an offline mode, you do
not want to pay for compute, or sensitive data must not go to the cloud.

### Compared with a direct `docker run` of claude-code

```bash
docker run --rm -it \
  -v $PWD:/workspace \
  -w /workspace \
  -e ANTHROPIC_API_KEY=... \
  node:22 bash -c 'npm i -g @anthropic-ai/claude-code && claude'
```

| Parameter               | This sandbox    | Direct docker run     |
|-------------------------|-----------------|-----------------------|
| Setup lines             | install.sh + 1  | ~10                   |
| Reproducibility         | pinned versions | latest at each start  |
| Workspace protection    | RO bind         | none                  |
| Resource limits         | ✓               | none                  |
| Caps drop               | ✓               | none                  |
| User UID                | host UID        | root                  |

**Use a direct docker run if:** you do a single test and you do not need
protection.

**Use the sandbox if:** you use it regularly and you want protection by
default.

### Compared with Firecracker / KVM (a full VM)

| Parameter               | This sandbox       | Firecracker VM        |
|-------------------------|--------------------|-----------------------|
| Kernel isolation        | shared (Docker)    | separate kernel       |
| Start time              | ~1s                | ~100ms (Firecracker)  |
| Escape risk             | Docker 0-days      | much lower            |
| Setup effort            | install.sh         | much more difficult   |
| Good for malware        | no                 | ✓                     |
| Good for AI agents      | ✓                  | too much              |

**Use a VM if:** you analyze untrusted code, and you accept more complexity
for hard isolation.

**Use the sandbox if:** you have a usual workflow with an AI agent, and you
trust the model at a minimum as "not an active attacker".

### Compared with gVisor / runsc

| Parameter               | This sandbox       | gVisor                |
|-------------------------|--------------------|-----------------------|
| Kernel attack surface   | full Linux         | userspace re-implementation |
| Compatibility           | 100% (native Linux)| 95% (some syscalls are not available) |
| Setup effort            | install.sh         | runtime installation  |
| Performance overhead    | minimum            | large (10-50%)        |

**Use gVisor if:** you want hard kernel isolation without a full VM.

**Use the sandbox if:** you do not need that level, and you want a simple
solution.

### Compared with the official Anthropic devcontainer example

Anthropic publishes an [official devcontainer](https://code.claude.com/docs/en/devcontainer)
with `init-firewall.sh` (an iptables allowlist).

| Parameter               | This sandbox       | Anthropic devcontainer |
|-------------------------|--------------------|------------------------|
| Network firewall (L3)   | ✗ (postponed)      | ✓ (iptables/ipset)    |
| RO config overlay       | ✓                  | ✗                      |
| More than one mode      | ✓ (5)              | ✗ (one)               |
| Keeps `--user`          | ✓                  | ✗ (root in the container) |
| Rootless Docker         | works              | does not work (needs NET_ADMIN)|
| IDE integration         | ✗                  | ✓ (devcontainer)      |
| Vendoring               | submodule / cp     | spec-driven           |

**Use the Anthropic devcontainer if:** your main problem is the network
firewall, you do not need rootless Docker, and VS Code is acceptable.

**Use this sandbox if:** you need protection of the config itself (SEC-01),
more than one mode for different tasks, or rootless Docker, and you do not
want to use one specified IDE.

Refer to ADR-009 for the full reason why this iteration postpones NET-01.

## Can you use them together?

Yes:

- **Sandbox + devcontainer**: Use the devcontainer for IDE work. Use the
  sandbox for AI sessions in the terminal.
- **Sandbox + Codespaces**: Install the sandbox in a Codespace. You get
  double isolation, but you pay for compute.
- **Sandbox + Firecracker**: Run the sandbox in a Firecracker VM for
  hardened isolation. This is too much for a usual workflow.

## Not applicable to

- **Production deployments.** The sandbox is a dev tool. It is not a
  runtime.
- **Real-time GPU compute.** Docker adds overhead, and there is no GPU
  passthrough by default.
- **Scenarios with more than one container.** By design, there is one
  container for each session.
- **Headless CI with persistent state.** CI is usually ephemeral. The main
  sandbox protections repeat what the CI already does.

## Summary of the selection

```
Do you need local protection for Claude/Codex?
├── Can you spend time on the setup? → this sandbox
└── Do you need an IDE? → devcontainer
    └── Do you also need an L3 firewall? → Anthropic devcontainer
        └── Do you also need the cloud? → Codespaces

Do you run untrusted code? → Firecracker / VM
Do you only want to try it? → npm install -g
```
