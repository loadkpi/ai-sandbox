# FAQ

These are frequent questions about this sandbox. We add new questions when
they occur.

## General

### Why use this sandbox if `.devcontainer/` exists?

The devcontainer is for IDE integration (VS Code, JetBrains) and for a dev
workflow in a container. This sandbox:

- Is for CLI agents, not for an IDE.
- Has stricter security restrictions (read-only rootfs, RO bind overlays,
  a deny list).
- Works with all shells. It does not need a specified editor.
- Gives isolation modes that you select at each start (`--mode offline`
  for an audit).

Refer to [COMPARISON.md](./COMPARISON.md) for more data.

### Is this the same as the devcontainer + Claude Code recipe?

No. Anthropic publishes an official `.devcontainer/` example with an
iptables firewall. That example is about network isolation. It gives less
RO mount protection for the configs. This sandbox is about:

- Vendoring into each repository (as a submodule or a copy).
- Modes through one `run.sh`.
- Protection of the sandbox configs from the model.

NET-01 (iptables firewall) is postponed here. Refer to ADR-009.

### Why not use `docker run` directly?

You can. `run.sh` is a wrapper with good defaults. If you need different
defaults, read `run.sh` and change it. The sandbox does not prevent a
direct `docker run`.

### Is this open source?

Yes. The project uses the MIT license. Refer to the `LICENSE` file in the
repository root.

## Installation and setup

### Can I install the sandbox globally, not for each project?

Not at this time. The layout is for each project (`.ai-sandbox/` in each
project). This is intentional. Each project gets:
- Its own allowed-domains.txt.
- Its own deny list.
- Its own state in its own home.

You can put the template in `~/` and make a symlink to `.ai-sandbox` in
each project. But this is a hack. Global settings (master prompt, shared
config) are in ROADMAP §UX-01/02.

### How do I update the sandbox in many projects at the same time?

Refer to [OPERATIONS.md §Bulk update](./OPERATIONS.md). In short: run
install.sh in a loop, or run `git submodule update --remote` if you use a
submodule.

### Can I use the sandbox without credentials.env?

Yes. The file is optional. If it does not exist, the sandbox starts, but
Claude and Codex cannot authenticate to the API. This is useful if you get
the keys from a different source (for example, the Codex OAuth flow at the
first start, or `claude /login`).

### Does it work on macOS and Windows?

- **macOS (Docker Desktop)**: Yes. arm64 (Apple Silicon) is supported.
- **Windows (WSL2)**: Yes, in a WSL distribution.
- **Native Windows (no WSL)**: Not tested. Bind mounts of paths with
  backslashes can cause problems.

## Network

### Why can Codex not download packages?

In the `default` and `webfetch` modes, the Codex config has
`network_access = false`. This is intentional. Use `--mode dev` for
development with the network.

This is different from the container network. In the default mode, the
container has a Docker network (bridge). The Codex config removes the
network only for Codex.

### Can I add hosts to the allowlist?

Yes:
```bash
echo "myapi.example.com" >> .ai-sandbox/allowed-domains.txt
```

Then start the container again. Wildcards (`*.example.com`) are
supported.

### Where is the DNS resolver of the container?

It is the Docker embedded resolver at 127.0.0.11. Docker gives it to all
containers by default. In `--mode offline` (`--network=none`), DNS is also
disabled.

### Why does `nslookup evil.com` work in the default mode?

DNS (UDP/53) is not blocked at L3. NET-01 (iptables firewall) will close
this gap, but it is postponed. Refer to THREAT-MODEL.md §"Exfiltration
through DNS".

### Can I use a corporate proxy?

Not by default. Workaround:
- Add this to `.ai-sandbox/home/.codex/config.toml`:
  ```toml
  [shell_environment_policy]
  include_only = [..., "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY"]
  ```
- Add this to `~/.config/ai-sandbox/credentials.env`:
  ```
  HTTP_PROXY=http://proxy.corp:8080
  HTTPS_PROXY=http://proxy.corp:8080
  NO_PROXY=localhost,127.0.0.1
  ```

## Access to resources

### Can I give a GPU to the container?

Not by default. Add `--gpus all` to `run.sh` manually, and install the
nvidia-container-toolkit on the host. This is not a usual use case for
Claude Code or Codex. They use LLM APIs, not local inference.

### Can I publish a custom port?

Add `-p <host>:<container>` to `DOCKER_ARGS`. Use this for local
development servers.

### Why is `~/.ssh/` not available?

This is by design. Refer to THREAT-MODEL.md. If you need SSH keys for
git push, use one of these:
- HTTPS, not SSH, for the git remote.
- ssh-agent forwarding (`-v $SSH_AUTH_SOCK:/ssh-agent -e SSH_AUTH_SOCK=/ssh-agent`).
- GitHub CLI with a personal access token (you have more control).

### Why does Codex not see my `GITHUB_TOKEN`?

After the 2026-05-28 iteration, Codex must see it.
`shell_environment_policy.include_only` contains `GITHUB_TOKEN`,
`GH_TOKEN`, `NPM_TOKEN` and `PIP_INDEX_URL`. Put these variables in
credentials.env or in the environment of the parent shell.

If Codex does not see it, do this check:
```bash
./.ai-sandbox/run.sh -- env | grep -E 'GITHUB|GH_TOKEN'
```

If the variable is in the environment but Codex does not use it, the
problem is in the Codex config. Examine
`.ai-sandbox/home/.codex/config.toml`.

## Production and shared use

### Can I use the sandbox in CI?

Technically, yes. The sandbox is only Docker. But CI is usually an
isolated environment already. The main sandbox protections (RO mounts,
deny list) repeat what the CI already does (clean checkout, no persistent
state). The memory and CPU limits can be useful.

### Can I use the sandbox for production deployments?

**No.** It is a dev tool. The sandbox gives reasonable isolation against
prompt injection and user errors. To run untrusted code in production, use
a VM (Firecracker, gVisor) or a similar level of isolation.

### More than one user (many developers on one machine)

This is not supported. Each developer uses their own `~/.config/ai-sandbox/`
and their own project clones. `--user $(id -u):$(id -g)` makes sure that
new files get the current UID.

## Codex and Claude

### What is "Codex as an MCP server"?

Codex can run as an MCP server (`codex mcp-server`). In this mode, Claude
Code finds Codex through `.mcp.json`. Claude can then call Codex as a set
of tools (for example, to generate code with a GPT model).

Thus you have one Claude session, and the Codex tools are available in it.

### Can I disable MCP?

Yes. Remove `.mcp.json`, or remove the `codex` server from it.

### Which Codex model does the sandbox use?

The model is in `.ai-sandbox/versions.env`, in the `CODEX_MODEL` line. The
default is `gpt-6-astra`. `run.sh` writes this value into
`.ai-sandbox/home/.codex/config.toml` at each start. If your account has
no access to this model, refer to the next question.

### Can I use a different model?

Yes. To change the model permanently, edit `CODEX_MODEL` in
`.ai-sandbox/versions.env`:
```bash
CODEX_MODEL=gpt-6-sol
```

To change the model for one start only, use an environment variable:
```bash
AI_SANDBOX_CODEX_MODEL=gpt-6-sol ./.ai-sandbox/run.sh -- codex
```

If you select a model with `/model` in Codex, `run.sh` resets it at the
next start. To keep your own Codex config, remove the marker line:
```bash
sed -i '/^# managed-by:/d' .ai-sandbox/home/.codex/config.toml
```

`run.sh` does not change a config without the marker.

## Security

### Is this full sandboxing? Can I run malware?

No. Refer to THREAT-MODEL.md. The sandbox gives protection against
accidental and crude attacks. It does not give protection against a
targeted exploit. For malware analysis, use a VM (KVM, Firecracker,
gVisor).

### What if Anthropic or OpenAI is compromised?

The sandbox does not give protection against the API providers. If a
provider is compromised, the data that you sent through the API can leak.
This is a question of **trust in the vendor**, not of the sandbox.

### Are the API keys visible in the container?

Yes, through `/proc/self/environ` or `env`. This is by design, because
Claude and Codex must use them. But the keys are **not** visible:
- In the bash history (if the keys are in the environment, not in the
  commands).
- In `/workspace/` (they are only in the environment).

### Does the sandbox log what the agent does?

The sandbox does not. The Claude and Codex CLIs keep their state in
`.ai-sandbox/home/.config/claude/` and `.ai-sandbox/home/.codex/sessions/`.
To see the history, use the standard commands of these CLIs.

## Troubleshooting

### "Permission denied" at the first start of install.sh

```bash
chmod +x install.sh
```

### The Docker daemon does not respond

```bash
# Linux
sudo systemctl status docker
sudo systemctl start docker

# macOS / Windows: open Docker Desktop
```

### The image build takes 10 minutes

This is normal for the first build (apt + a global npm install). The next
builds take seconds (cache hit). If each build takes 10 minutes, there is
a problem with the Docker layer cache:
```bash
docker system df         # how much cache there is
docker builder prune     # clear it if it is full
```

### Where can I ask a question that is not in this FAQ?

Prepare a minimum repro (what you tried and what you saw). Then:
- Open an issue in the template repository.
- Read ROADMAP.md, OPERATIONS.md and THREAT-MODEL.md. The answer can be
  there already.
- Read README.md §Troubleshooting.
