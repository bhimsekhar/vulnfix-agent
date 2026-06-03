---
name: vuln-resume
description: >
  Resume an in-progress vulnerability fix session. Reads the local
  status file to show what phases have completed and asks where to continue.
  Use after a VS Code restart, an end-of-day pause, or after manual intervention.
argument-hint: "CVE-ID  (e.g. CVE-2021-44228)"
agent: conductor
model: claude-sonnet-4-6
tools:
  - read
  - search
---

Resume the vulnerability fix session for: $ARGUMENTS

Normalise the CVE ID to uppercase (e.g. CVE-2021-44228).

Hand off to @conductor with instruction:
"Resume the VulnFix session for {CVE_ID}. Read
~/.copilot/vuln-sessions/{CVE_ID}/status.json and display the status panel.
Ask the developer whether to continue from the current phase, restart a
specific phase, or abandon the session."
