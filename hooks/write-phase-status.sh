#!/usr/bin/env bash
# =============================================================================
# VulnFix Agent — subagentStop hook  (observational — gate trigger)
# write-phase-status.sh
# =============================================================================
# Fires when a subagent completes, before returning to the parent conductor.
# Cannot block. Observational only.
#
# Responsibility:
#   Read the status.json already written by the subagent as its last
#   terminal action. Check whether the phase completed successfully or
#   failed. If FAILED, write a halt flag so the conductor knows to stop
#   before delegating the next phase.
#
# IMPORTANT (D1 fix):
#   This hook does NOT determine COMPLETE vs FAILED.
#   The subagent itself wrote that to status.json before stopping.
#   This hook only READS what was written and signals the conductor.
#
# INPUT:  JSON on stdin with: agent_id, agent_type, stop_reason
# OUTPUT: None (observational — conductor reads status.json directly)
# =============================================================================

set -uo pipefail

PAYLOAD=$(cat)

# ── Parse agent name from payload ────────────────────────────────────────────
AGENT_NAME=$(echo "$PAYLOAD" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    # agent_display_name is more reliable for matching our custom agents
    name = d.get('agent_display_name') or d.get('agent_name') or d.get('agent_id', '')
    print(name.lower())
except Exception:
    print('')
" 2>/dev/null || echo "")

[[ -z "$AGENT_NAME" ]] && exit 0

# ── Map agent name to phase ───────────────────────────────────────────────────
case "$AGENT_NAME" in
    *version-resolver*|*version_resolver*) PHASE="P1_VERSION_RESOLVE" ;;
    *pom-patcher*|*pom_patcher*)           PHASE="P2_POM_PATCH" ;;
    *code-adapter*|*code_adapter*)         PHASE="P3_CODE_ADAPT" ;;
    *test-guardian*|*test_guardian*)       PHASE="P4_TEST" ;;
    *)
        # Unknown subagent — not a vulnfix phase, exit cleanly
        exit 0
        ;;
esac

# ── Find active CVE session ───────────────────────────────────────────────────
# Find the most recently modified status.json
STATUS_FILE=$(find "$HOME/.copilot/vuln-sessions" -name "status.json" \
    -not -path "*/index.json" 2>/dev/null | \
    xargs ls -t 2>/dev/null | head -1 || echo "")

[[ -z "$STATUS_FILE" || ! -f "$STATUS_FILE" ]] && exit 0

# ── Read the phase status written by the subagent ────────────────────────────
PHASE_STATUS=$(python3 -c "
import json
try:
    with open('$STATUS_FILE') as f:
        d = json.load(f)
    for phase in d.get('phases', []):
        if phase.get('name') == '$PHASE':
            print(phase.get('status', 'UNKNOWN'))
            break
    else:
        print('NOT_FOUND')
except Exception as e:
    print('READ_ERROR')
" 2>/dev/null || echo "UNKNOWN")

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# ── If the phase was not updated by the subagent, mark it as FAILED ──────────
# This handles the case where the subagent crashed before writing its status
case "$PHASE_STATUS" in
    COMPLETE|MANUALLY_COMPLETE)
        echo "[vulnfix/subagentStop] $PHASE completed successfully" >&2
        ;;
    FAILED)
        echo "[vulnfix/subagentStop] $PHASE FAILED — conductor should halt" >&2
        # Write halt flag for conductor to read
        HALT_FILE="$(dirname "$STATUS_FILE")/halt.flag"
        echo "{\"phase\": \"$PHASE\", \"reason\": \"FAILED\", \"timestamp\": \"$TIMESTAMP\"}" > "$HALT_FILE"
        ;;
    NOT_STARTED|IN_PROGRESS|UNKNOWN|NOT_FOUND|READ_ERROR)
        # Subagent stopped without updating its phase — treat as failure
        echo "[vulnfix/subagentStop] $PHASE stopped without writing COMPLETE — marking FAILED" >&2
        python3 -c "
import json, os
try:
    with open('$STATUS_FILE') as f:
        d = json.load(f)
    for phase in d.get('phases', []):
        if phase.get('name') == '$PHASE':
            phase['status'] = 'FAILED'
            phase['lastError'] = 'Subagent stopped without writing phase status'
            phase['failedAt'] = '$TIMESTAMP'
            break
    d['lastError'] = '$PHASE failed — subagent stopped without writing status'
    with open('$STATUS_FILE', 'w') as f:
        json.dump(d, f, indent=2)
except Exception as e:
    pass
" 2>/dev/null || true
        # Write halt flag
        HALT_FILE="$(dirname "$STATUS_FILE")/halt.flag"
        echo "{\"phase\": \"$PHASE\", \"reason\": \"INCOMPLETE\", \"timestamp\": \"$TIMESTAMP\"}" > "$HALT_FILE"
        ;;
esac

exit 0
