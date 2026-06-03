---
name: vuln-remediation
description: >
  Use when remediating a Java Maven dependency vulnerability (CVE).
  Provides conductor with pom.xml editing patterns, Maven multi-module
  knowledge, CVSS severity handling, and restart decision logic.
---

# VulnFix Skill — Vulnerability Remediation Knowledge

This skill is preloaded into the conductor agent. It provides reference
knowledge for common remediation patterns.

## pom.xml editing patterns

### Multi-module project: prefer property-based version management
If the vulnerable artifact's version is controlled via a property in the
parent pom, edit ONLY the property. Example:
```xml
<!-- Before -->
<log4j.version>2.14.1</log4j.version>
<!-- After -->
<log4j.version>2.17.1</log4j.version>
```

### Spring Boot managed dependencies
Spring Boot BOMs manage many library versions. To override a managed version:
```xml
<dependencyManagement>
  <dependencies>
    <!-- Override Spring Boot managed version for security fix -->
    <dependency>
      <groupId>org.apache.logging.log4j</groupId>
      <artifactId>log4j-bom</artifactId>
      <version>2.17.1</version>
      <type>pom</type>
      <scope>import</scope>
    </dependency>
  </dependencies>
</dependencyManagement>
```

### Excluding transitive dependency
If the vulnerable artifact comes in as a transitive dependency:
```xml
<dependency>
  <groupId>some.parent</groupId>
  <artifactId>parent-lib</artifactId>
  <exclusions>
    <exclusion>
      <groupId>org.apache.logging.log4j</groupId>
      <artifactId>log4j-core</artifactId>
    </exclusion>
  </exclusions>
</dependency>
```

## CVSS severity handling

| Severity | Action |
|---|---|
| CRITICAL (9.0–10.0) | Fix immediately. Do not stop for minor compile warnings. |
| HIGH (7.0–8.9) | Fix. Report any ambiguous code changes to developer. |
| MEDIUM (4.0–6.9) | Fix. Extra caution — take more conservative approach to code changes. |

## Restart decision logic

When status.json shows a session is in progress, decide based on currentPhase:

| currentPhase | Default action |
|---|---|
| PENDING / P1_VERSION_RESOLVE | Restart from P1 (cheap and fast) |
| P1_COMPLETE | Skip P1 — start at conductor planning step |
| P2_COMPLETE | Skip P1 and P2 — start at P3 |
| P3_COMPLETE | Skip P1, P2, P3 — start at P4 |
| P4_FAILED | Show failure-report.md — ask dev to fix manually then resume |

## Common migration patterns by library

### Log4j 1.x → Log4j 2.x
- `org.apache.log4j.Logger` → `org.apache.logging.log4j.LogManager`
- `Logger.getLogger(Foo.class)` → `LogManager.getLogger(Foo.class)`
- `org.apache.log4j.Level` → `org.apache.logging.log4j.Level`

### Log4j 2.14.x → 2.17.x (CVE-2021-44228 / Log4Shell)
No API changes. Only version bump required. No code-adapter work needed.
The vulnerability is in the JNDI lookup feature, not the API.

### Spring Boot 2.x → 3.x
- `javax.*` packages → `jakarta.*` packages (major migration, flag for developer)
- Spring Security API changes — consult migration-notes.json

### Jackson < 2.13 → 2.13+
- `@JsonIgnoreProperties(ignoreUnknown = true)` behaviour unchanged
- Default typing changes — explicit ObjectMapper configuration may be needed
