#!/usr/bin/env bash
# =============================================================================
# VulnFix Agent — postToolUse hook  (observational only)
# audit-edit.sh
# =============================================================================
# Fires AFTER every tool execution. Cannot block — observational only.
#
# Responsibility:
#   When the tool was an edit call on a .xml or .java file,
#   append a structured JSON entry to the session's audit.jsonl file.
#   This provides a complete, append-only audit trail of every file
#   change made by the agent — for security review purposes.
#
# INPUT:  JSON on stdin with: tool_name, tool_input, tool_use_id
# OUTPUT: None (observational — any output is logged and ignored)
# =============================================================================

set -uo pipefail

PAYLOAD=$(cat)

# ── Parse tool name and file path from stdin JSON ─────────────────────────────
PARSE_RESULT=$(echo "$PAYLOAD" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    tool_name  = d.get('tool_name', '')
    tool_input = d.get('tool_input', {})
    # File path may be in different keys depending on tool
    file_path = (
        tool_input.get('path', '') or
        tool_input.get('file', '') or
        tool_input.get('target_file', '') or
        ''
    )
    tool_use_id = d.get('tool_use_id', '')
    print(f'{tool_name}|||{file_path}|||{tool_use_id}')
except Exception:
    sys.exit(0)  # Parse failure — exit cleanly (non-blocking hook)
" 2>/dev/null || echo "")

[[ -z "$PARSE_RESULT" ]] && exit 0

TOOL_NAME=$(echo "$PARSE_RESULT"   | cut -d'|||' -f1)
FILE_PATH=$(echo "$PARSE_RESULT"   | cut -d'|||' -f2)
TOOL_USE_ID=$(echo "$PARSE_RESULT" | cut -d'|||' -f3)

# ── Only audit edit tool calls on .xml or .java files ────────────────────────
case "$TOOL_NAME" in
    edit|editFiles|write_file|str_replace_editor) : ;;
    *) exit 0 ;;
esac

case "$FILE_PATH" in
    *.xml|*.java) : ;;
    *) exit 0 ;;
esac

# ── Find CVE ID from active session ──────────────────────────────────────────
CVE_ID=$(find "$HOME/.copilot/vuln-sessions" -name "status.json" -newer "$HOME/.copilot/vuln-sessions/index.json" 2>/dev/null | \
    head -1 | xargs dirname 2>/dev/null | xargs basename 2>/dev/null || echo "UNKNOWN")

AUDIT_FILE="$HOME/.copilot/vuln-sessions/$CVE_ID/audit.jsonl"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

mkdir -p "$(dirname "$AUDIT_FILE")"

# ── Append audit entry ────────────────────────────────────────────────────────
python3 -c "
import json
entry = {
    'timestamp':   '$TIMESTAMP',
    'tool_use_id': '$TOOL_USE_ID',
    'tool_name':   '$TOOL_NAME',
    'file_path':   '$FILE_PATH',
    'file_type':   '$(echo "$FILE_PATH" | grep -oE '\.[^.]+$' || echo unknown)',
    'cve_id':      '$CVE_ID',
}
with open('$AUDIT_FILE', 'a') as f:
    f.write(json.dumps(entry) + '\n')
" 2>/dev/null || true

exit 0
