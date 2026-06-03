#!/usr/bin/env bash
# =============================================================================
# VulnFix Agent — preToolUse hook  *** BLOCKING ***
# enforce-internal-only.sh
# =============================================================================
# Fires BEFORE every tool execution. This is the ONLY hook that can block.
#
# Policy: Block any terminal/bash command that makes outbound HTTP calls
# to hosts other than the configured internal Nexus/Artifactory server.
# This covers: mvn, curl, wget, pip, npm, and any other HTTP tool.
#
# INPUT:  JSON on stdin with fields: tool_name, tool_input, tool_use_id
#         (NOT environment variables — D3 fix)
#
# OUTPUT: JSON on stdout to allow or deny the tool call.
#         Exit code 2 = deny (used as fail-safe if parsing fails)
#
# FAIL-SAFE DESIGN (D3 fix):
#   If jq is not installed or JSON parsing fails for any reason,
#   the script exits with code 2 which DENIES the tool call.
#   It NEVER silently passes on error.
# =============================================================================

set -uo pipefail

# ── Read Nexus base URL from global config ────────────────────────────────────
# Resolution order: VULNFIX_CONFIG env var → ~/.vulnfix/config.yaml
CONFIG_FILE="${VULNFIX_CONFIG:-$HOME/.vulnfix/config.yaml}"
NEXUS_HOST=""

if command -v python3 &>/dev/null && [[ -f "$CONFIG_FILE" ]]; then
    NEXUS_HOST=$(python3 -c "
import yaml, sys
try:
    with open('$CONFIG_FILE') as f:
        cfg = yaml.safe_load(f)
    url = cfg.get('nexus', {}).get('base_url', '')
    # Extract just the hostname
    import urllib.parse
    print(urllib.parse.urlparse(url).netloc)
except Exception as e:
    sys.exit(1)
" 2>/dev/null || echo "")
fi

# ── FAIL-SAFE: if we can't determine internal host, deny all HTTP ─────────────
# This should never happen in normal operation
if [[ -z "$NEXUS_HOST" ]]; then
    echo "[vulnfix/preToolUse] WARN: Could not read Nexus host from config. Allowing non-HTTP tools only." >&2
fi

# ── Read tool payload from stdin ──────────────────────────────────────────────
# Use jq if available, fall back to python3
if ! command -v jq &>/dev/null && ! command -v python3 &>/dev/null; then
    # Cannot parse — DENY as fail-safe
    echo '{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "Cannot parse tool input: jq and python3 both unavailable"}}'
    exit 2
fi

PAYLOAD=$(cat)

# Parse using python3 (more reliable than jq on all platforms)
PARSE_RESULT=$(echo "$PAYLOAD" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    tool_name = d.get('tool_name', '')
    tool_input = d.get('tool_input', {})
    # Get command from various tool input shapes
    command = (
        tool_input.get('command', '') or
        tool_input.get('cmd', '') or
        tool_input.get('bash', '') or
        str(tool_input.get('input', ''))
    )
    print(f'{tool_name}|||{command}')
except Exception as e:
    print(f'PARSE_ERROR|||{e}', file=sys.stderr)
    sys.exit(1)
" 2>/dev/null)

# ── Fail-safe: if parse failed, DENY ─────────────────────────────────────────
if [[ $? -ne 0 || -z "$PARSE_RESULT" ]]; then
    echo '{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "Failed to parse tool input JSON — denying as fail-safe"}}'
    exit 2
fi

TOOL_NAME=$(echo "$PARSE_RESULT" | cut -d'|||' -f1)
COMMAND=$(echo "$PARSE_RESULT" | cut -d'|||' -f2-)

# ── Only inspect terminal/bash tool calls ────────────────────────────────────
# Non-terminal tools (read, edit, search) are always allowed
case "$TOOL_NAME" in
    terminal|bash|run_command|execute_command|shell)
        : # Fall through to inspection
        ;;
    *)
        # Not a terminal call — allow unconditionally
        echo '{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow"}}'
        exit 0
        ;;
esac

# ── Check for external HTTP calls ─────────────────────────────────────────────
# Blocked external Maven/package hosts
BLOCKED_EXTERNAL=(
    "repo.maven.apache.org"
    "search.maven.org"
    "central.maven.org"
    "mvnrepository.com"
    "repo1.maven.org"
    "plugins.gradle.org"
    "pypi.org"
    "files.pythonhosted.org"
    "registry.npmjs.org"
    "npmjs.com"
)

# Check against all blocked hosts
for HOST in "${BLOCKED_EXTERNAL[@]}"; do
    if echo "$COMMAND" | grep -qi "$HOST"; then
        REASON="VulnFix security policy: external repository call blocked. Command contains '$HOST'. All dependency resolution must go through internal Nexus."
        echo "{\"hookSpecificOutput\": {\"hookEventName\": \"PreToolUse\", \"permissionDecision\": \"deny\", \"permissionDecisionReason\": \"$REASON\"}}"
        echo "[vulnfix/preToolUse] BLOCKED: $COMMAND" >&2
        exit 2
    fi
done

# Also block any outbound HTTP that is NOT going to internal Nexus
# Look for curl/wget/http calls that reference external URLs
if echo "$COMMAND" | grep -qiE '(curl|wget)\s+.*https?://'; then
    # Extract URL being called
    CALLED_URL=$(echo "$COMMAND" | grep -oiE 'https?://[^[:space:]"'"'"']+' | head -1)
    if [[ -n "$CALLED_URL" && -n "$NEXUS_HOST" ]]; then
        if ! echo "$CALLED_URL" | grep -qi "$NEXUS_HOST"; then
            REASON="VulnFix security policy: outbound HTTP call to external host blocked. URL: $CALLED_URL. Only $NEXUS_HOST is permitted."
            echo "{\"hookSpecificOutput\": {\"hookEventName\": \"PreToolUse\", \"permissionDecision\": \"deny\", \"permissionDecisionReason\": \"$REASON\"}}"
            echo "[vulnfix/preToolUse] BLOCKED external HTTP: $CALLED_URL" >&2
            exit 2
        fi
    fi
fi

# ── All checks passed — allow ─────────────────────────────────────────────────
echo '{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow"}}'
exit 0
