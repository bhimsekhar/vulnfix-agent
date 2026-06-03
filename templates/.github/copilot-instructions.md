# VulnFix Agent — Always-on Repository Policy

These instructions apply to all Copilot agent sessions in this repository.

## Security policy — internal repository only
All Maven dependency resolution MUST go through the internal Nexus/Artifactory
repository configured in `mcp/config/nexus-config.yaml`.
No agent in this repository may call Maven Central, mvnrepository.com,
search.maven.org, or any external package repository.
This is enforced at the preToolUse hook level, not just by instruction.

## Agent mode required
VulnFix agents only work in **Agent mode** in VS Code Copilot Chat.
The dropdown at the bottom of the chat panel must show "Agent" (not "Ask" or "Edit").

## Entry points
Use these slash commands to invoke the VulnFix agents:
- `/vuln-fix CVE-ID groupId:artifactId current-version severity` — start a fix
- `/vuln-resume CVE-ID` — resume an in-progress fix session
- `/vuln-scan-only CVE-ID groupId:artifactId current-version` — dry run only

Do NOT invoke subagents (@version-resolver, @pom-patcher, @code-adapter,
@test-guardian) directly. Always go through @conductor.

## Branch naming convention
All vulnerability fix branches must follow the pattern:
`vuln/fix-{cve-id-lowercase}-{unix-timestamp}`
Example: `vuln/fix-cve-2021-44228-1717123456`

## Pre-requisites for engineers
Before using VulnFix agents, ensure:
1. `NEXUS_TOKEN` environment variable is set in your shell profile
2. `~/.m2/settings.xml` contains a mirror entry for the internal Nexus repo
3. VS Code is in Agent mode (not Ask or Edit mode)

## Status files
Session state is stored locally at:
`~/.copilot/vuln-sessions/{CVE-ID}/`
These files are NEVER committed to git — they are on your local machine only.
