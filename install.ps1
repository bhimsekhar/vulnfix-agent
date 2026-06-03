# VulnFix — Windows installer
# ============================
# Run once per developer machine:
#   irm https://raw.githubusercontent.com/YOUR-ORG/vulnfix/main/install.ps1 | iex
#
# What this does:
#   1. Checks prerequisites (Python 3, Git, Maven)
#   2. Clones/updates ~/.vulnfix from the org GitHub repo
#   3. Installs Python dependencies for the MCP server
#   4. Prompts for Nexus config, writes ~/.vulnfix/config.yaml
#   5. Registers the maven-mcp server in VS Code user MCP settings
#   6. Creates ~/.m2/settings.xml mirror block if missing
#   7. Adds ~/.vulnfix/bin to the user PATH
#
# After running: restart VS Code, then `vulnfix init` inside any Java Maven project.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$REPO_URL   = "https://github.com/YOUR-ORG/vulnfix.git"
$INSTALL_DIR = Join-Path $env:USERPROFILE ".vulnfix"
$CONFIG_FILE = Join-Path $INSTALL_DIR "config.yaml"
$BIN_DIR     = Join-Path $INSTALL_DIR "bin"

function Write-Step { param($msg) Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok   { param($msg) Write-Host "    [OK] $msg" -ForegroundColor Green }
function Write-Warn { param($msg) Write-Host "    [WARN] $msg" -ForegroundColor Yellow }
function Write-Fail { param($msg) Write-Host "`n[FAIL] $msg" -ForegroundColor Red; exit 1 }

# ── 1. Prerequisites ──────────────────────────────────────────────────────────
Write-Step "Checking prerequisites"

$python = Get-Command python -ErrorAction SilentlyContinue
if (-not $python) { Write-Fail "Python 3 not found. Install from https://python.org and add to PATH." }
$pyVersion = & python --version 2>&1
Write-Ok "Python: $pyVersion"

$git = Get-Command git -ErrorAction SilentlyContinue
if (-not $git) { Write-Fail "Git not found. Install Git for Windows from https://git-scm.com." }
Write-Ok "Git: $(& git --version)"

$mvn = Get-Command mvn -ErrorAction SilentlyContinue
if (-not $mvn) { Write-Warn "Maven (mvn) not found on PATH. Add Maven to PATH before using vulnfix." }
else { Write-Ok "Maven: $(& mvn --version 2>&1 | Select-Object -First 1)" }

# ── 2. Clone or update ~/.vulnfix ─────────────────────────────────────────────
Write-Step "Installing VulnFix to $INSTALL_DIR"

if (Test-Path (Join-Path $INSTALL_DIR ".git")) {
    Write-Host "    Updating existing install..."
    & git -C $INSTALL_DIR pull --quiet
    Write-Ok "Updated"
} else {
    Write-Host "    Cloning $REPO_URL ..."
    & git clone --quiet $REPO_URL $INSTALL_DIR
    Write-Ok "Cloned"
}

# ── 3. Python dependencies ────────────────────────────────────────────────────
Write-Step "Installing Python dependencies"
& python -m pip install --quiet fastmcp httpx pyyaml packaging
Write-Ok "fastmcp, httpx, pyyaml, packaging installed"

# ── 4. Configure ~/.vulnfix/config.yaml ──────────────────────────────────────
Write-Step "Configuring VulnFix"

if (Test-Path $CONFIG_FILE) {
    $reconfig = Read-Host "    ~/.vulnfix/config.yaml already exists. Reconfigure? (y/N)"
    if ($reconfig -ne "y" -and $reconfig -ne "Y") {
        Write-Ok "Keeping existing config"
        goto SkipConfig
    }
}

$nexusUrl   = Read-Host "    Nexus/Artifactory base URL (e.g. https://nexus.internal.yourorg.com)"
$nexusRepo  = Read-Host "    Release repository name [maven-releases]"
if ([string]::IsNullOrWhiteSpace($nexusRepo)) { $nexusRepo = "maven-releases" }
$tokenVar   = Read-Host "    Nexus token environment variable name [NEXUS_TOKEN]"
if ([string]::IsNullOrWhiteSpace($tokenVar)) { $tokenVar = "NEXUS_TOKEN" }
$testMode   = Read-Host "    Use Maven Central for testing? (y=test mode, N=production) [N]"
$testModeVal = if ($testMode -eq "y" -or $testMode -eq "Y") { "true" } else { "false" }

$configContent = @"
# VulnFix developer machine config — written by install.ps1
# NOT committed to git. Run 'vulnfix configure' to change.

nexus:
  base_url: "$nexusUrl"
  repo_releases: "$nexusRepo"
  auth_env_var: "$tokenVar"
  timeout_seconds: 30
  test_mode: $testModeVal

vulnfix:
  max_test_retry_cycles: 3
  branch_prefix: "vuln/fix-"
  session_folder: ".copilot/vuln-sessions"
"@

Set-Content -Path $CONFIG_FILE -Value $configContent -Encoding UTF8
Write-Ok "Config written to $CONFIG_FILE"

:SkipConfig

# ── 5. Register global MCP server in VS Code user settings ────────────────────
Write-Step "Registering maven-mcp in VS Code user MCP settings"

$vscodeUserDir = Join-Path $env:APPDATA "Code\User"
$mcpFile       = Join-Path $vscodeUserDir "mcp.json"
$serverPath    = Join-Path $INSTALL_DIR "server\maven_mcp_server.py" -replace "\\", "\\\\"

$mcpEntry = @"
{
  "servers": {
    "maven-mcp": {
      "type": "stdio",
      "command": "python",
      "args": ["$($INSTALL_DIR -replace '\\','\\\\')\\\\server\\\\maven_mcp_server.py"],
      "env": {
        "NEXUS_TOKEN": "`${env:NEXUS_TOKEN}",
        "VULNFIX_CONFIG": "$($CONFIG_FILE -replace '\\','\\\\')",
        "VULNFIX_KB": "$($INSTALL_DIR -replace '\\','\\\\')\\\\knowledge-base"
      }
    }
  }
}
"@

if (Test-Path $mcpFile) {
    $existing = Get-Content $mcpFile -Raw | ConvertFrom-Json
    if ($existing.servers.PSObject.Properties.Name -contains "maven-mcp") {
        Write-Ok "maven-mcp already registered in $mcpFile"
    } else {
        # Merge: add maven-mcp to existing servers object
        $newEntry = $mcpEntry | ConvertFrom-Json
        $existing.servers | Add-Member -MemberType NoteProperty -Name "maven-mcp" `
            -Value $newEntry.servers."maven-mcp" -Force
        $existing | ConvertTo-Json -Depth 10 | Set-Content $mcpFile -Encoding UTF8
        Write-Ok "Added maven-mcp to existing $mcpFile"
    }
} else {
    New-Item -ItemType Directory -Force -Path $vscodeUserDir | Out-Null
    Set-Content -Path $mcpFile -Value $mcpEntry -Encoding UTF8
    Write-Ok "Created $mcpFile with maven-mcp"
}

# ── 6. Create ~/.m2/settings.xml if missing ───────────────────────────────────
Write-Step "Checking ~/.m2/settings.xml"

$m2Dir      = Join-Path $env:USERPROFILE ".m2"
$settingsFile = Join-Path $m2Dir "settings.xml"

if (-not (Test-Path $settingsFile)) {
    New-Item -ItemType Directory -Force -Path $m2Dir | Out-Null
    $nexusUrl2 = if ($nexusUrl) { $nexusUrl } else { "https://nexus.internal.yourorg.com" }
    $settingsContent = @"
<?xml version="1.0" encoding="UTF-8"?>
<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0"
          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
          xsi:schemaLocation="http://maven.apache.org/SETTINGS/1.0.0
                              http://maven.apache.org/xsd/settings-1.0.0.xsd">
  <mirrors>
    <mirror>
      <id>internal-nexus</id>
      <name>Internal Maven Repository (VulnFix)</name>
      <url>$nexusUrl2/repository/maven-public/</url>
      <mirrorOf>central</mirrorOf>
    </mirror>
  </mirrors>
</settings>
"@
    Set-Content -Path $settingsFile -Value $settingsContent -Encoding UTF8
    Write-Ok "Created $settingsFile with Nexus mirror"
} else {
    $settingsXml = Get-Content $settingsFile -Raw
    if ($settingsXml -match "<mirror>") {
        Write-Ok "$settingsFile already has a <mirror> block"
    } else {
        Write-Warn "$settingsFile exists but has no <mirror> block. Add one manually or run 'vulnfix configure'."
    }
}

# ── 7. Add ~/.vulnfix/bin to user PATH ────────────────────────────────────────
Write-Step "Adding $BIN_DIR to user PATH"

$currentPath = [Environment]::GetEnvironmentVariable("PATH", "User")
if ($currentPath -notlike "*$BIN_DIR*") {
    [Environment]::SetEnvironmentVariable("PATH", "$currentPath;$BIN_DIR", "User")
    Write-Ok "Added $BIN_DIR to user PATH (effective in new terminals)"
} else {
    Write-Ok "$BIN_DIR already in PATH"
}

# ── Done ──────────────────────────────────────────────────────────────────────
Write-Host @"

╔══════════════════════════════════════════════════════════════╗
║          VulnFix installed successfully!                     ║
╠══════════════════════════════════════════════════════════════╣
║  Next steps:                                                 ║
║  1. Restart VS Code (so maven-mcp MCP server is loaded)      ║
║  2. Open any Java Maven project folder                       ║
║  3. In that project folder, run:  vulnfix init               ║
║  4. In VS Code Copilot Chat (Agent mode):                    ║
║       /vuln-fix CVE-XXXX-XXXXX group:artifact ver CRITICAL   ║
╚══════════════════════════════════════════════════════════════╝
"@ -ForegroundColor Green
