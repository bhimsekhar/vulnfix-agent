---
name: vuln-fix
description: >
  Fix a dependency vulnerability in this Java Maven project.
  Provide the CVE ID, affected artifact, current version, and severity.
  The agent will resolve the safe version, patch pom.xml, fix Java source
  code, run tests, and raise a PR — all against the internal repository only.
argument-hint: "CVE-ID  groupId:artifactId  current-version  CRITICAL|HIGH|MEDIUM"
agent: conductor
model: claude-sonnet-4-6
tools:
  - read
  - search
---

Fix the following dependency vulnerability in this Java Maven project:

**Input:** $ARGUMENTS

Parse the arguments as:
1. CVE ID (e.g. CVE-2021-44228)
2. Maven artifact (e.g. org.apache.logging.log4j:log4j-core)
3. Current vulnerable version (e.g. 2.14.1)
4. Severity (CRITICAL / HIGH / MEDIUM)

Hand off to @conductor with all four values clearly stated.
The conductor will handle all validation, version resolution, patching,
code fixes, testing, and PR creation.

Example usage:
  /vuln-fix CVE-2021-44228 org.apache.logging.log4j:log4j-core 2.14.1 CRITICAL
