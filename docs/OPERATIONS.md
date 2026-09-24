# Operations Runbook

This runbook tells you what to do when a problem occurs. It extends the
Troubleshooting section of the README. It contains more scenarios,
recovery procedures and routine operations.

## Where to look

| Symptom                              | Look here first                               |
|--------------------------------------|-----------------------------------------------|
| The container does not start         | `docker logs <name>` + `./.ai-sandbox/run.sh --help` |
| The build fails                      | `./.ai-sandbox/build.sh` (without redirect)   |
| Claude/Codex errors                  | `.ai-sandbox/home/.config/*` (state)          |
| Network errors                       | `.ai-sandbox/allowed-domains.txt` + mode      |
| "command not found"                  | `versions.env` + `docker image inspect`       |

## Standard operations

### Full reinstallation of the sandbox in a project

```bash
# Make a snapshot of the state as a precaution
tar czf /tmp/ai-sandbox-home-$(date +%s).tgz .ai-sandbox/home/

# Remove the template
rm -rf .ai-sandbox/
rm .claude/settings.json .mcp.json

# Install it again
/path/to/template/install.sh .

# Restore the state if necessary
tar xzf /tmp/ai-sandbox-home-*.tgz -C .
```

### Reset of the user Codex settings

`run.sh` generates `.ai-sandbox/home/.codex/config.toml` again **if** the
file contains the marker `# managed-by: ai-sandbox/run.sh ...`. If you
removed the marker to edit the file manually, and you now want the
default back, do this:

```bash
rm .ai-sandbox/home/.codex/config.toml
./.ai-sandbox/run.sh -- true   # generates the file again
```

### Forced rebuild of the image

```bash
# Remove the cached image
source .ai-sandbox/versions.env
docker rmi "ai-sandbox:codex-${CODEX_VERSION}_claude-${CLAUDE_VERSION}"

# Build again without the cache
docker build --no-cache \
  --build-arg NODE_IMAGE="${NODE_IMAGE}" \
  --build-arg CODEX_VERSION="${CODEX_VERSION}" \
  --build-arg CLAUDE_VERSION="${CLAUDE_VERSION}" \
  -t "ai-sandbox:codex-${CODEX_VERSION}_claude-${CLAUDE_VERSION}" \
  -f .ai-sandbox/Dockerfile \
  .ai-sandbox
```

A shorter procedure:

```bash
docker rmi $(docker image ls 'ai-sandbox:*' -q)
./.ai-sandbox/build.sh
```

### Update to the latest CLI versions

```bash
./.ai-sandbox/check-updates.sh    # show the newer versions
./.ai-sandbox/update.sh           # update both + rebuild
```

To update only one CLI:

```bash
./.ai-sandbox/update.sh --claude 2.1.150        # only Claude
./.ai-sandbox/update.sh --codex 0.140.0         # only Codex
```

After an update, the old image stays locally (with a different tag). You
can go back to it:

```bash
docker image ls 'ai-sandbox:*'    # show all versions
./.ai-sandbox/update.sh --codex 0.133.0 --claude 2.1.142   # roll back
```

### Bulk update in many projects

If the template is installed in N projects, and you must update all of
them:

```bash
# Update the template
cd /path/to/template
git pull

# Install it again in each project
for proj in ~/projects/*/; do
  if [ -d "$proj/.ai-sandbox" ]; then
    /path/to/template/install.sh "$proj"
  fi
done
```

An alternative (if you used a git submodule):

```bash
for proj in ~/projects/*/; do
  if [ -d "$proj/.ai-sandbox-template" ]; then
    (cd "$proj" && git submodule update --remote .ai-sandbox-template)
  fi
done
```

### API key rotation

```bash
# 1. Generate a new key in the OpenAI/Anthropic dashboard
# 2. Replace it in credentials.env
chmod 600 ~/.config/ai-sandbox/credentials.env
$EDITOR ~/.config/ai-sandbox/credentials.env

# 3. All new sessions use the new key. An old session continues with the
#    old env value (Docker --env-file reads the file at the start)

# 4. Revoke the old key in the dashboard
```

If you think that the old key leaked, revoke it **immediately**, before
the replacement.

### State cleanup

Full: `rm -rf .ai-sandbox/home/`
Only Codex: `rm -rf .ai-sandbox/home/.codex/`
Only Claude: `rm -rf .ai-sandbox/home/.config/`

At the next start, the tools ask you to authenticate again.

### Backup of project data

`/workspace` (= the project root) contains the usual user files. Back them
up with the usual `tar`, `rsync` or git.

`.ai-sandbox/home/` is the container state. **It contains auth tokens.**
For a backup:
- Do NOT upload it to public hosting.
- Encrypt it (`gpg`, `age`).
- Use it only to move to a new machine.

## Recovery scenarios

### Scenario 1: The sandbox does not start after an update

```
Error: ai-sandbox-entrypoint: command not found
```

Possible causes and checks:

1. **The image was not built again after `update.sh`.**
   ```bash
   docker image ls 'ai-sandbox:*'
   source .ai-sandbox/versions.env
   # Does the last image agree with the current tag?
   ```
   Solution: `./.ai-sandbox/build.sh`

2. **`versions.env` is corrupted** (for example, after a `.bak` rollback).
   ```bash
   cat .ai-sandbox/versions.env
   # Expected lines: CODEX_VERSION=, CLAUDE_VERSION=, NODE_IMAGE=, CODEX_MODEL=
   ```
   Solution: restore it from the template or from `versions.env.bak`.

3. **`entrypoint.sh` lost its exec bit.**
   ```bash
   ls -la .ai-sandbox/entrypoint.sh
   # Expected: -rwxr-xr-x
   chmod +x .ai-sandbox/entrypoint.sh
   ```

### Scenario 2: "permission denied" in the container

Usually, you try to write to a read-only location.

```bash
# Make sure that read operations work
./.ai-sandbox/run.sh -- ls -la /workspace/.ai-sandbox/run.sh
# You must see the file. The ro overlay does not prevent reads

# Make sure that /workspace is writable
./.ai-sandbox/run.sh -- bash -lc 'echo x > /workspace/test && rm /workspace/test'
# This must work

# If it does not work, examine the permissions on the host
ls -la $PWD
# The owner must be your user, with write permission
```

If the write goes to `/workspace/.ai-sandbox/something`, it is ro **by
design**. Make changes to the template on the host, not in the container.

### Scenario 3: Codex/Claude do not see `OPENAI_API_KEY` / `ANTHROPIC_API_KEY`

```bash
# Make sure that credentials.env exists and is readable
ls -la ~/.config/ai-sandbox/credentials.env
# Expected: 600 (owner only), not empty

# Do a check in the container
./.ai-sandbox/run.sh -- env | grep -E 'OPENAI|ANTHROPIC'
```

If the variables are not there, `--env-file` did not read the file. Make
sure that:
- The file exists at the start.
- It has `chmod 600` (Docker can show a warning for 644).
- It has no BOM or CRLF (`file ~/.config/ai-sandbox/credentials.env`).

To use a different credentials file:
```bash
AI_SANDBOX_CREDS_FILE=/path/to/other.env ./.ai-sandbox/run.sh -- claude
```

### Scenario 4: Possible compromise (the agent did something strange)

Symptoms: unknown outgoing connections, unexpected new files, the agent
tries to read locations that it must not read.

```bash
# 1. STOP everything immediately
docker ps | grep ai-sandbox
docker stop <container-name>

# 2. Make a snapshot for analysis
tar czf /tmp/forensics-$(date +%s).tgz .ai-sandbox/home/ .claude/

# 3. Revoke the API keys (Anthropic and OpenAI dashboards)

# 4. Examine the bash history of the agent
cat .ai-sandbox/home/.bash_history 2>/dev/null
cat .ai-sandbox/home/.zsh_history 2>/dev/null

# 5. Examine the Claude/Codex session history
ls -la .ai-sandbox/home/.config/claude/
ls -la .ai-sandbox/home/.codex/sessions/

# 6. Look for unusual files in the workspace
git status
git diff
find $PWD -newer .ai-sandbox -not -path '*/.git/*' -not -path '*/.ai-sandbox/*' 2>/dev/null

# 7. Full cleanup
rm -rf .ai-sandbox/home/
docker rmi $(docker image ls 'ai-sandbox:*' -q)

# 8. (Optional) Build the image again from a clean template
```

After this, examine `.claude/settings.json` again. Add the bypass patterns
that you saw to the deny list. Update `allowed-domains.txt` if you saw
legitimate requirements for new hosts.

### Scenario 5: `--name` conflict between parallel sessions

After the 2026-05-28 iteration, the container name contains `$$` (the
PID). This prevents a conflict between shells. If you still see this
error:

```
docker: Error response from daemon: Conflict. The container name
"/ai-sandbox-myproject-12345" is already in use
```

A possible cause: a dead container from an earlier session has the same
PID in its name (rare). Remove the dead container manually:
```bash
docker rm -f $(docker ps -a -q --filter 'name=ai-sandbox-myproject')
```

### Scenario 6: The image build cannot download packages (npm registry is not available)

During the build, `npm install` fails with a timeout or 503.

```bash
# Make sure that the registry is available from the host
curl -I https://registry.npmjs.org/
```

If the registry is down, wait, or use a mirror:

```bash
# Add this to the Dockerfile temporarily (do NOT commit it):
RUN npm config set registry https://registry.npmmirror.com
# then the standard npm install
```

Or install the versions from a cached tarball, if you have one.

### Scenario 7: cgroup memory is not supported

```
docker: Your kernel does not support swap limit capabilities
```

This can occur on old Linux hosts without `swapaccount=1`.

Workaround:
```bash
AI_SANDBOX_MEMORY= ./.ai-sandbox/run.sh -- claude
```

Permanent solution: in `/etc/default/grub`, add
`GRUB_CMDLINE_LINUX_DEFAULT="... cgroup_enable=memory swapaccount=1"`.
Then run `update-grub` and reboot.

### Scenario 8: arm64 (Apple Silicon) — libnss_wrapper is not found

The 2026-05-28 iteration added an architecture-aware fallback. If the
library is still not found:

```bash
./.ai-sandbox/run.sh -- bash -lc 'ldconfig -p | grep nss_wrapper'
```

If there is no output:
```bash
./.ai-sandbox/run.sh -- bash -lc 'dpkg -L libnss-wrapper | grep \.so'
```

The output must contain `/usr/lib/aarch64-linux-gnu/libnss_wrapper.so`. If
it does not, make sure that the apt layer of the Dockerfile installs
`libnss-wrapper`.

## Regular maintenance

### Each week

- Run `./.ai-sandbox/check-updates.sh` to see if there are new versions.
- Examine `git status` and `git log` in each active project to see what
  the agent changed.

### Each month

- Audit `.ai-sandbox/home/.config/claude/sessions/` to see what the agent
  did.
- Remove old images: `docker image prune --filter 'until=720h'`.
- Rotate the API keys if your security policy requires it.

### When you change the dev machine

1. Copy `~/.config/ai-sandbox/credentials.env` (securely!).
2. For each active project, copy `.ai-sandbox/home/` (or let the agents
   authenticate again).
3. Install Docker.
4. Pull or build the image.

## Resource use

### Size of the images

```bash
docker image ls 'ai-sandbox:*' --format 'table {{.Tag}}\t{{.Size}}'
```

### Size of the state

```bash
du -sh ~/projects/*/.ai-sandbox/home/ 2>/dev/null | sort -h
```

### Removal of old images

```bash
# All ai-sandbox images older than 30 days
docker image prune -a --filter 'label=org.opencontainers.image.title=ai-sandbox' \
  --filter 'until=720h'

# Without the label filter (be careful — it can remove other images)
docker image prune --filter 'until=720h'
```

## Escalation

If no scenario helps:

1. Collect diagnostic data:
   ```bash
   {
     echo "=== docker version ==="
     docker version
     echo "=== docker info ==="
     docker info
     echo "=== versions.env ==="
     cat .ai-sandbox/versions.env
     echo "=== image inspect ==="
     source .ai-sandbox/versions.env
     docker image inspect "ai-sandbox:codex-${CODEX_VERSION}_claude-${CLAUDE_VERSION}" 2>&1
     echo "=== last container logs ==="
     docker ps -a --filter 'name=ai-sandbox' --format '{{.ID}}' | head -1 | xargs -r docker logs --tail=200
   } > /tmp/ai-sandbox-diag.txt 2>&1
   ```

2. Read ROADMAP.md and the known issues.
3. Open an issue in the template repository and attach the diagnostic
   data. First remove all keys and private data.
