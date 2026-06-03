#!/usr/bin/env bash
# =============================================================================
# VulnFix Agent — sessionStart hook
# create-branch.sh
# =============================================================================
# Fires when a Copilot agent session starts.
# Responsibilities:
#   1. Read COPILOT_SESSION_ID and initial prompt from stdin JSON
#   2. Initialise ~/.copilot/vuln-sessions/{CVE_ID}/status.json
#      with all 4 phases set to NOT_STARTED
#   3. Write entry to the CVE→sessionId index file
#   4. Does NOT create the git branch — that is the conductor's first action
#      via github-mcp create_branch() (D2 fix)
#
# This hook's output is IGNORED by the agent — it is observational only.
# A failure here is logged but does not block the session.
# =============================================================================

set -euo pipefail

# ── Read hook payload from stdin ──────────────────────────────────────────────
PAYLOAD=$(cat)

SESSION_ID=$(echo "$PAYLOAD" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d.get('sessionId', ''))
" 2>/dev/null || echo "")

SOURCE=$(echo "$PAYLOAD" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d.get('source', 'new'))
" 2>/dev/null || echo "new")

INITIAL_PROMPT=$(echo "$PAYLOAD" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d.get('initialPrompt', ''))
" 2>/dev/null || echo "")

# ── Extract CVE ID from initial prompt (normalise to uppercase) ───────────────
CVE_ID=$(echo "$INITIAL_PROMPT" | grep -oiE 'CVE-[0-9]{4}-[0-9]+' | head -1 | tr '[:lower:]' '[:upper:]' || echo "")

if [[ -z "$CVE_ID" ]]; then
    # Not a vuln-fix session — exit cleanly, don't interfere
    exit 0
fi

# ── Set up session directory ──────────────────────────────────────────────────
SESSION_DIR="$HOME/.copilot/vuln-sessions/$CVE_ID"
STATUS_FILE="$SESSION_DIR/status.json"
INDEX_FILE="$HOME/.copilot/vuln-sessions/index.json"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

mkdir -p "$SESSION_DIR"

# ── Idempotency: skip init if resuming an existing session ───────────────────
if [[ "$SOURCE" == "resume" && -f "$STATUS_FILE" ]]; then
    echo "[vulnfix/sessionStart] Resuming existing session for $CVE_ID" >&2
    exit 0
fi

# ── Also skip if status.json already exists (handles VS Code restart scenario)
if [[ -f "$STATUS_FILE" ]]; then
    EXISTING_STATUS=$(python3 -c "
import json
with open('$STATUS_FILE') as f:
    d = json.load(f)
print(d.get('overallStatus', ''))
" 2>/dev/null || echo "")
    if [[ "$EXISTING_STATUS" != "" && "$EXISTING_STATUS" != "ABANDONED" ]]; then
        echo "[vulnfix/sessionStart] status.json already exists for $CVE_ID ($EXISTING_STATUS) — skipping init" >&2
        exit 0
    fi
fi

# ── Write fresh status.json ───────────────────────────────────────────────────
python3 -c "
import json, os
status = {
    'sessionId': '$SESSION_ID',
    'cveId': '$CVE_ID',
    'artifact': '',
    'fromVersion': '',
    'targetVersion': '',
    'branch': '',
    'overallStatus': 'STARTED',
    'currentPhase': 'PENDING',
    'startedAt': '$TIMESTAMP',
    'phases': [
        {'name': 'P1_VERSION_RESOLVE', 'status': 'NOT_STARTED', 'testCycles': None},
        {'name': 'P2_POM_PATCH',       'status': 'NOT_STARTED', 'filesChanged': []},
        {'name': 'P3_CODE_ADAPT',      'status': 'NOT_STARTED', 'filesChanged': []},
        {'name': 'P4_TEST',            'status': 'NOT_STARTED', 'testCycles': 0},
    ],
    'lastError': None,
    'auditLog': '$HOME/.copilot/vuln-sessions/$CVE_ID/audit.jsonl',
}
with open('$STATUS_FILE', 'w') as f:
    json.dump(status, f, indent=2)
print('[vulnfix/sessionStart] Initialised status.json for $CVE_ID')
"

# ── Update CVE → sessionId index ─────────────────────────────────────────────
python3 -c "
import json, os
index_path = '$INDEX_FILE'
index = {}
if os.path.exists(index_path):
    try:
        with open(index_path) as f:
            index = json.load(f)
    except Exception:
        index = {}
index['$CVE_ID'] = {
    'sessionId': '$SESSION_ID',
    'startedAt': '$TIMESTAMP',
    'statusFile': '$STATUS_FILE',
}
os.makedirs(os.path.dirname(index_path), exist_ok=True)
with open(index_path, 'w') as f:
    json.dump(index, f, indent=2)
"

echo "[vulnfix/sessionStart] Session initialised for $CVE_ID" >&2
