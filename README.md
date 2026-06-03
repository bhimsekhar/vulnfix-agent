# VulnFix — GitHub Copilot CVE Remediation Agent

VulnFix is a multi-agent system for VS Code GitHub Copilot that automatically fixes
dependency vulnerabilities (CVEs) in Java Maven projects.

**Install once per developer machine. Use on any Maven project.**

---

## How it works

```
Developer types: /vuln-fix CVE-2021-44228 org.apache.logging.log4j:log4j-core 2.14.1 CRITICAL
                                    │
                        ┌───────────▼──────────────┐
                        │  @conductor               │  orchestrates all phases
                        └──┬───────────────────────-┘
                           │ P1 ▶ @version-resolver   finds safe version from Nexus
                           │ P2 ▶ @pom-patcher        edits pom.xml, verifies dep tree
                           │ P3 ▶ @code-adapter        fixes Java API changes if needed
                           │ P4 ▶ @test-guardian       runs tests, fixes failures
                           │
                        Creates GitHub PR automatically
```

The **MCP server** (`maven-mcp`) is registered globally in VS Code — it handles all
Maven/Nexus calls. Only lightweight agent markdown files are added to each project.

---

## Architecture

```
~/.vulnfix/                    ← installed once on your machine
  bin/vulnfix                  ← CLI
  server/maven_mcp_server.py   ← FastMCP server (reads ~/.vulnfix/config.yaml)
  hooks/                       ← session/audit/security hook scripts
  knowledge-base/              ← library migration YAML database
  config.yaml                  ← YOUR Nexus URL + settings (not in git)
  templates/                   ← agent file templates (versioned here)

Each Java Maven project (committed to git, shared with team):
  .github/
    agents/        ← 5 agent .md files (conductor + 4 subagents)
    prompts/       ← /vuln-fix, /vuln-resume, /vuln-scan-only slash commands
    hooks/         ← vuln-hooks.json (references ~/.vulnfix/hooks/)
    skills/        ← vuln-remediation knowledge
    copilot-instructions.md

%APPDATA%/Code/User/mcp.json   ← VS Code global MCP (written by install)
  → maven-mcp server at ~/.vulnfix/server/maven_mcp_server.py
```

---

## Prerequisites

| Tool | Minimum version | Notes |
|---|---|---|
| VS Code | 1.99+ | Must have GitHub Copilot extension |
| GitHub Copilot | Agent mode preview | Switch dropdown to "Agent" in Chat panel |
| Python | 3.10+ | For the MCP server |
| Git | Any | For clone/update and branch creation |
| Maven | 3.8+ | For dependency:tree verification |
| Git Bash | Any (Windows) | Hooks run in bash; install via Git for Windows |

---

## One-time setup (per developer machine)

### Windows
```powershell
irm https://raw.githubusercontent.com/YOUR-ORG/vulnfix/main/install.ps1 | iex
```

### Mac / Linux
```bash
curl -sSL https://raw.githubusercontent.com/YOUR-ORG/vulnfix/main/install.sh | bash
```

The installer:
1. Clones this repo to `~/.vulnfix/`
2. Installs Python deps (`fastmcp httpx pyyaml packaging`)
3. Prompts for your Nexus URL → writes `~/.vulnfix/config.yaml`
4. Registers `maven-mcp` in VS Code user MCP settings
5. Creates `~/.m2/settings.xml` mirror block if missing
6. Adds `~/.vulnfix/bin` to your PATH

**After install: restart VS Code once.**

---

## Per-project setup (any Java Maven project)

```bash
cd /path/to/your-java-project      # must contain pom.xml
vulnfix init
git add .github/
git commit -m "Add VulnFix agent"
```

That's it. Every team member who has run the installer can now use `/vuln-fix`.

---

## Using the agent in VS Code

1. Open your Java project in VS Code
2. In Copilot Chat: click the dropdown → select **Agent** mode
3. Type:

```
/vuln-fix CVE-2021-44228 org.apache.logging.log4j:log4j-core 2.14.1 CRITICAL
```

**Other commands:**

| Command | Purpose |
|---|---|
| `/vuln-fix CVE-ID groupId:artifactId version CRITICAL\|HIGH\|MEDIUM` | Start a full fix |
| `/vuln-resume CVE-ID` | Resume an interrupted fix session |
| `/vuln-scan-only CVE-ID groupId:artifactId version` | Dry run — assess impact, no file changes |

---

## CLI reference

```bash
vulnfix init [--force]          # scaffold .github/ into current Maven project
vulnfix configure               # re-run Nexus config interactively
vulnfix update                  # pull latest agent version + re-install deps
vulnfix validate                # check all prerequisites are correct
vulnfix kb add groupId:artId    # add a knowledge-base YAML for a new artifact
```

---

## Configuring Nexus (production)

`~/.vulnfix/config.yaml` is written by the installer — **never committed to git**.

```yaml
nexus:
  base_url: "https://nexus.internal.yourorg.com"
  repo_releases: "maven-releases"
  auth_env_var: "NEXUS_TOKEN"   # set this env var in your shell profile
  timeout_seconds: 30
  test_mode: false              # true = use Maven Central (local testing only)

vulnfix:
  max_test_retry_cycles: 3
  branch_prefix: "vuln/fix-"
  session_folder: ".copilot/vuln-sessions"
```

Set your Nexus token **in your shell profile** (not in config.yaml):
```bash
# ~/.bashrc or ~/.zshrc
export NEXUS_TOKEN="your-personal-access-token"
```

---

## Adding a new library to the knowledge base

```bash
vulnfix kb add com.example:my-library
# Edit ~/.vulnfix/knowledge-base/com.example/my-library.yaml
# Commit to this repo so all developers get it on next `vulnfix update`
```

---

## Keeping VulnFix up to date

```bash
vulnfix update                  # pulls latest from org GitHub repo
vulnfix init --force            # refresh .github/agents/ in your project
git add .github/ && git commit -m "Update VulnFix agent to latest"
```

---

## Session state

All session state is local to each developer machine — never committed:

```
~/.copilot/vuln-sessions/CVE-2021-44228/
  status.json          ← phase progress (P1–P4)
  p1-output.json       ← safe version resolved by version-resolver
  migration-notes.json ← API change analysis by conductor
  audit.jsonl          ← append-only log of every file edit
  failure-report.md    ← written if P4 exceeds max retry cycles
  halt.flag            ← signals conductor to stop on phase failure
```

---

## Security policy

The `preToolUse` hook (`enforce-internal-only.sh`) **blocks** any terminal command
that calls external Maven repositories (Maven Central, mvnrepository.com, etc.)
during an active fix session. All dependency resolution goes through your internal
Nexus. This is enforced at the hook level, not just by instruction.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `maven-mcp` not showing in VS Code MCP panel | Restart VS Code; check Output → Copilot MCP |
| `NEXUS_TOKEN not set` error | `export NEXUS_TOKEN=...` in shell profile; restart VS Code |
| Conductor halts at settings.xml check | Run `vulnfix configure` to create `~/.m2/settings.xml` |
| `mvn not found` in dependency tree tool | Add Maven to PATH; restart VS Code |
| Hook scripts not found | Run `vulnfix update` to ensure `~/.vulnfix/hooks/` exists |
| Agent files outdated | `vulnfix update` then `vulnfix init --force` |
