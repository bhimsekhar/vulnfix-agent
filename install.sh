#!/usr/bin/env bash
# VulnFix — Mac/Linux installer
# ===============================
# Run once per developer machine:
#   curl -sSL https://raw.githubusercontent.com/YOUR-ORG/vulnfix/main/install.sh | bash
#
# What this does:
#   1. Checks prerequisites (Python 3, Git, Maven)
#   2. Clones/updates ~/.vulnfix from the org GitHub repo
#   3. Installs Python dependencies for the MCP server
#   4. Prompts for Nexus config, writes ~/.vulnfix/config.yaml
#   5. Registers the maven-mcp server in VS Code user MCP settings
#   6. Creates ~/.m2/settings.xml mirror block if missing
#   7. Adds ~/.vulnfix/bin to shell profile PATH
#
# After running: restart VS Code, then `vulnfix init` inside any Java Maven project.

set -euo pipefail

REPO_URL="https://github.com/YOUR-ORG/vulnfix.git"
INSTALL_DIR="$HOME/.vulnfix"
CONFIG_FILE="$INSTALL_DIR/config.yaml"
BIN_DIR="$INSTALL_DIR/bin"

# Detect VS Code user settings path per OS
if [[ "$OSTYPE" == "darwin"* ]]; then
    VSCODE_USER_DIR="$HOME/Library/Application Support/Code/User"
else
    VSCODE_USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/Code/User"
fi
MCP_FILE="$VSCODE_USER_DIR/mcp.json"

step()  { echo; echo "==> $1"; }
ok()    { echo "    [OK] $1"; }
warn()  { echo "    [WARN] $1"; }
fail()  { echo; echo "[FAIL] $1" >&2; exit 1; }

# ── 1. Prerequisites ──────────────────────────────────────────────────────────
step "Checking prerequisites"

command -v python3 &>/dev/null || fail "Python 3 not found. Install it via your package manager."
ok "Python: $(python3 --version)"

command -v git &>/dev/null || fail "Git not found. Install git first."
ok "Git: $(git --version)"

if ! command -v mvn &>/dev/null; then
    warn "Maven (mvn) not found on PATH. Add Maven to PATH before using vulnfix."
else
    ok "Maven: $(mvn --version 2>&1 | head -1)"
fi

# ── 2. Clone or update ~/.vulnfix ─────────────────────────────────────────────
step "Installing VulnFix to $INSTALL_DIR"

if [[ -d "$INSTALL_DIR/.git" ]]; then
    echo "    Updating existing install..."
    git -C "$INSTALL_DIR" pull --quiet
    ok "Updated"
else
    echo "    Cloning $REPO_URL ..."
    git clone --quiet "$REPO_URL" "$INSTALL_DIR"
    ok "Cloned"
fi

# ── 3. Python dependencies ────────────────────────────────────────────────────
step "Installing Python dependencies"
python3 -m pip install --quiet fastmcp httpx pyyaml packaging
ok "fastmcp, httpx, pyyaml, packaging installed"

# ── 4. Configure ~/.vulnfix/config.yaml ──────────────────────────────────────
step "Configuring VulnFix"

if [[ -f "$CONFIG_FILE" ]]; then
    read -r -p "    ~/.vulnfix/config.yaml exists. Reconfigure? (y/N) " reconfig
    if [[ "$reconfig" != "y" && "$reconfig" != "Y" ]]; then
        ok "Keeping existing config"
        skip_config=1
    fi
fi

if [[ -z "${skip_config:-}" ]]; then
    read -r -p "    Nexus/Artifactory base URL [https://nexus.internal.yourorg.com]: " nexus_url
    nexus_url="${nexus_url:-https://nexus.internal.yourorg.com}"

    read -r -p "    Release repository name [maven-releases]: " nexus_repo
    nexus_repo="${nexus_repo:-maven-releases}"

    read -r -p "    Nexus token environment variable name [NEXUS_TOKEN]: " token_var
    token_var="${token_var:-NEXUS_TOKEN}"

    read -r -p "    Use Maven Central for testing? (y=test mode, N=production) [N]: " test_mode_input
    if [[ "$test_mode_input" == "y" || "$test_mode_input" == "Y" ]]; then
        test_mode="true"
    else
        test_mode="false"
    fi

    cat > "$CONFIG_FILE" << EOF
# VulnFix developer machine config — written by install.sh
# NOT committed to git. Run 'vulnfix configure' to change.

nexus:
  base_url: "$nexus_url"
  repo_releases: "$nexus_repo"
  auth_env_var: "$token_var"
  timeout_seconds: 30
  test_mode: $test_mode

vulnfix:
  max_test_retry_cycles: 3
  branch_prefix: "vuln/fix-"
  session_folder: ".copilot/vuln-sessions"
EOF
    ok "Config written to $CONFIG_FILE"
fi

# ── 5. Register global MCP server in VS Code user settings ────────────────────
step "Registering maven-mcp in VS Code user MCP settings"

mkdir -p "$VSCODE_USER_DIR"

MCP_ENTRY=$(python3 - << PYEOF
import json, os, sys
install_dir = os.path.expanduser("~/.vulnfix")
config_file = os.path.expanduser("~/.vulnfix/config.yaml")
kb_path     = os.path.expanduser("~/.vulnfix/knowledge-base")
entry = {
    "servers": {
        "maven-mcp": {
            "type": "stdio",
            "command": "python3",
            "args": [f"{install_dir}/server/maven_mcp_server.py"],
            "env": {
                "NEXUS_TOKEN": "\${env:NEXUS_TOKEN}",
                "VULNFIX_CONFIG": config_file,
                "VULNFIX_KB": kb_path,
            }
        }
    }
}
print(json.dumps(entry, indent=2))
PYEOF
)

if [[ -f "$MCP_FILE" ]]; then
    existing=$(cat "$MCP_FILE")
    if echo "$existing" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if 'maven-mcp' in d.get('servers',{}) else 1)" 2>/dev/null; then
        ok "maven-mcp already registered in $MCP_FILE"
    else
        # Merge new server into existing mcp.json
        python3 - << PYEOF
import json
with open("$MCP_FILE") as f:
    existing = json.load(f)
new_server = json.loads('''$MCP_ENTRY''')["servers"]["maven-mcp"]
existing.setdefault("servers", {})["maven-mcp"] = new_server
with open("$MCP_FILE", "w") as f:
    json.dump(existing, f, indent=2)
PYEOF
        ok "Added maven-mcp to existing $MCP_FILE"
    fi
else
    echo "$MCP_ENTRY" > "$MCP_FILE"
    ok "Created $MCP_FILE with maven-mcp"
fi

# ── 6. Create ~/.m2/settings.xml if missing ───────────────────────────────────
step "Checking ~/.m2/settings.xml"

M2_SETTINGS="$HOME/.m2/settings.xml"
mkdir -p "$HOME/.m2"

if [[ ! -f "$M2_SETTINGS" ]]; then
    the_url="${nexus_url:-https://nexus.internal.yourorg.com}"
    cat > "$M2_SETTINGS" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0"
          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
          xsi:schemaLocation="http://maven.apache.org/SETTINGS/1.0.0
                              http://maven.apache.org/xsd/settings-1.0.0.xsd">
  <mirrors>
    <mirror>
      <id>internal-nexus</id>
      <name>Internal Maven Repository (VulnFix)</name>
      <url>${the_url}/repository/maven-public/</url>
      <mirrorOf>central</mirrorOf>
    </mirror>
  </mirrors>
</settings>
EOF
    ok "Created $M2_SETTINGS"
elif grep -q "<mirror>" "$M2_SETTINGS"; then
    ok "$M2_SETTINGS already has a <mirror> block"
else
    warn "$M2_SETTINGS exists but has no <mirror> block. Add one manually or run 'vulnfix configure'."
fi

# ── 7. Add ~/.vulnfix/bin to shell profile PATH ───────────────────────────────
step "Adding $BIN_DIR to PATH"

chmod +x "$BIN_DIR/vulnfix" 2>/dev/null || true

PROFILE=""
if [[ -f "$HOME/.zshrc" ]]; then
    PROFILE="$HOME/.zshrc"
elif [[ -f "$HOME/.bashrc" ]]; then
    PROFILE="$HOME/.bashrc"
elif [[ -f "$HOME/.bash_profile" ]]; then
    PROFILE="$HOME/.bash_profile"
fi

PATH_LINE="export PATH=\"\$PATH:$BIN_DIR\""

if [[ -n "$PROFILE" ]]; then
    if grep -q "$BIN_DIR" "$PROFILE" 2>/dev/null; then
        ok "$BIN_DIR already in $PROFILE"
    else
        echo "" >> "$PROFILE"
        echo "# VulnFix CLI" >> "$PROFILE"
        echo "$PATH_LINE" >> "$PROFILE"
        ok "Added $BIN_DIR to $PROFILE"
    fi
else
    warn "Could not detect shell profile. Add manually: $PATH_LINE"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║          VulnFix installed successfully!                     ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  Next steps:                                                 ║"
echo "║  1. Restart your terminal (to pick up PATH change)           ║"
echo "║  2. Restart VS Code (so maven-mcp MCP server is loaded)      ║"
echo "║  3. Open any Java Maven project folder                       ║"
echo "║  4. In that project folder, run:  vulnfix init               ║"
echo "║  5. In VS Code Copilot Chat (Agent mode):                    ║"
echo "║       /vuln-fix CVE-XXXX-XXXXX group:artifact ver CRITICAL   ║"
echo "╚══════════════════════════════════════════════════════════════╝"
