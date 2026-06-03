---
name: vuln-scan-only
description: >
  Dry run — validate the vulnerability input and resolve the safe target
  version from the internal repository. Makes NO changes to pom.xml or
  Java source files. Use for impact assessment before committing to a fix.
argument-hint: "CVE-ID  groupId:artifactId  current-version"
agent: conductor
model: claude-sonnet-4-6
tools:
  - read
  - search
---

Perform a dry-run vulnerability assessment for: $ARGUMENTS

Hand off to @conductor with instruction:
"Run SCAN-ONLY mode for {CVE_ID} on {artifact} at {currentVersion}.
Complete Steps 1 and 2 (validation) and Step 4 (delegate P1 to
version-resolver for safe version resolution).
STOP after P1 completes. Do NOT proceed to conductor planning,
pom-patcher, code-adapter, or test-guardian.
Do NOT create a branch. Do NOT edit any files.
Output a summary showing: artifact validated, safe target version,
all available versions in internal repo, and estimated impact
(whether code changes will be needed based on fromVersion/toVersion)."
