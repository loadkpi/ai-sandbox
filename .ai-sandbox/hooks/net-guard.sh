#!/usr/bin/env bash
set -euo pipefail

INPUT="$(cat)"
TOOL_NAME="$(jq -r '.tool_name // ""' <<<"$INPUT")"
ALLOW_FILE="${AI_SANDBOX_ALLOWED_DOMAINS_FILE:-/workspace/.ai-sandbox/allowed-domains.txt}"

normalize_host() {
  tr '[:upper:]' '[:lower:]'
}

is_allowed_host() {
  local host
  host="$(normalize_host <<<"${1:-}")"
  [[ -z "$host" ]] && return 0

  while IFS= read -r line; do
    line="${line%%#*}"
    line="$(echo "$line" | xargs || true)"
    [[ -z "$line" ]] && continue

    line="$(normalize_host <<<"$line")"

    if [[ "$line" == "*."* ]]; then
      local dom="${line#*.}"
      [[ "$host" == "$dom" || "$host" == *".${dom}" ]] && return 0
    elif [[ "$line" == .* ]]; then
      local dom="${line#.}"
      [[ "$host" == "$dom" || "$host" == *".${dom}" ]] && return 0
    else
      [[ "$host" == "$line" ]] && return 0
    fi
  done < "$ALLOW_FILE"

  return 1
}

deny() {
  local reason="$1"
  jq -n --arg r "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  exit 0
}

extract_hosts_from_command() {
  local cmd="$1"

  python3 - <<'PY' "$cmd"
import re, sys
from urllib.parse import urlparse

cmd = sys.argv[1]
hosts = set()

for m in re.finditer(r'(https?|ssh)://[^\s"\']+', cmd):
    u = m.group(0)
    try:
        p = urlparse(u)
        if p.hostname:
            hosts.add(p.hostname.lower())
    except Exception:
        pass

for m in re.finditer(r'\bgit@([a-zA-Z0-9.\-]+):', cmd):
    hosts.add(m.group(1).lower())

for h in sorted(hosts):
    print(h)
PY
}

case "$TOOL_NAME" in
  "WebFetch")
    URL="$(jq -r '.tool_input.url // ""' <<<"$INPUT")"
    HOST="$(python3 - <<'PY' "$URL"
from urllib.parse import urlparse
import sys
u=sys.argv[1]
try:
    p=urlparse(u)
    print((p.hostname or "").lower())
except Exception:
    print("")
PY
)"
    if ! is_allowed_host "$HOST"; then
      deny "WebFetch to '$HOST' is not allowed. Add it to .ai-sandbox/allowed-domains.txt to permit."
    fi
    ;;

  "WebSearch")
    deny "WebSearch is disabled in this sandbox mode."
    ;;

  "Bash")
    CMD="$(jq -r '.tool_input.command // ""' <<<"$INPUT")"
    while IFS= read -r host; do
      [[ -z "$host" ]] && continue
      if ! is_allowed_host "$host"; then
        deny "Network access to '$host' is not allowed. Add it to .ai-sandbox/allowed-domains.txt to permit."
      fi
    done < <(extract_hosts_from_command "$CMD")
    ;;

  *)
    ;;
esac

exit 0