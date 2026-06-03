"""
VulnFix Agent — maven-mcp-server
=================================
Global FastMCP server exposing 3 tools for Maven repository operations.
Installed once per developer machine at ~/.vulnfix/server/.
Registered globally in VS Code user MCP settings — no per-project copy needed.

Config resolution order (first file found wins):
  1. $VULNFIX_CONFIG   env var (set by VS Code MCP registration)
  2. ~/.vulnfix/config.yaml
  3. <script-dir>/config/nexus-config.yaml  (backward-compat only)

Knowledge-base resolution:
  $VULNFIX_KB env var, else ~/.vulnfix/knowledge-base/

Tools:
  1. get_safe_version    — resolve latest non-vulnerable version
  2. check_availability  — confirm a specific version JAR exists
  3. get_dependency_tree — run mvn dependency:tree and return structured result

Transport: stdio (VS Code MCP protocol)
"""

import os
import subprocess
import sys
from pathlib import Path

import httpx
import yaml
from fastmcp import FastMCP
from packaging.version import Version, InvalidVersion

# ── CONFIG RESOLUTION ────────────────────────────────────────────────────────

def _find_config() -> Path:
    candidates = [
        os.environ.get("VULNFIX_CONFIG"),
        Path.home() / ".vulnfix" / "config.yaml",
        Path(__file__).parent / "config" / "nexus-config.yaml",
    ]
    for c in candidates:
        if c and Path(c).exists():
            return Path(c)
    print(
        "[maven-mcp] ERROR: No config file found. Run 'vulnfix configure' "
        "or set VULNFIX_CONFIG env var.",
        file=sys.stderr,
    )
    sys.exit(1)

def _kb_path() -> Path:
    env = os.environ.get("VULNFIX_KB")
    if env:
        return Path(env)
    return Path.home() / ".vulnfix" / "knowledge-base"

CONFIG_PATH = _find_config()
KB_PATH     = _kb_path()

def _load_config() -> dict:
    with open(CONFIG_PATH) as f:
        return yaml.safe_load(f)

CONFIG       = _load_config()
NEXUS_BASE   = CONFIG["nexus"]["base_url"].rstrip("/")
REPO_REL     = CONFIG["nexus"]["repo_releases"]
AUTH_ENV_VAR = CONFIG["nexus"]["auth_env_var"]
TIMEOUT      = int(CONFIG.get("nexus", {}).get("timeout_seconds", 30))
TEST_MODE    = bool(CONFIG.get("nexus", {}).get("test_mode", False))

MAVEN_CENTRAL_SEARCH = "https://search.maven.org/solrsearch/select"
MAVEN_CENTRAL_REPO   = "https://repo1.maven.org/maven2"

# ── AUTH ──────────────────────────────────────────────────────────────────────

def _headers() -> dict:
    if TEST_MODE:
        return {}
    token = os.environ.get(AUTH_ENV_VAR)
    if not token:
        raise EnvironmentError(
            f"[maven-mcp] {AUTH_ENV_VAR} env var not set. "
            "Set it in your shell profile and restart VS Code."
        )
    return {"Authorization": f"Bearer {token}"}

def _sort_versions(versions: list[str]) -> list[str]:
    def _key(v):
        try:
            return Version(v)
        except InvalidVersion:
            return Version("0")
    return sorted(versions, key=_key, reverse=True)

# ── SERVER ────────────────────────────────────────────────────────────────────

_mode = "TEST/Maven-Central" if TEST_MODE else "PRODUCTION/Internal-Nexus"
mcp = FastMCP(
    name="maven-mcp-server",
    description=(
        f"VulnFix global Maven repository tools — mode: {_mode}. "
        f"Config: {CONFIG_PATH}. "
        "3 tools: get_safe_version, check_availability, get_dependency_tree."
    ),
)

# ── TOOL 1 ────────────────────────────────────────────────────────────────────

@mcp.tool()
async def get_safe_version(
    group_id: str,
    artifact_id: str,
    current_version: str,
    cve_id: str,
) -> dict:
    """
    Resolve the latest stable version of a Maven artifact.

    TEST mode  : queries Maven Central (search.maven.org).
    PRODUCTION : queries internal Nexus/Artifactory only.

    Args:
        group_id:        Maven group   e.g. "org.apache.logging.log4j"
        artifact_id:     Maven artifact e.g. "log4j-core"
        current_version: current version  e.g. "2.14.1"
        cve_id:          CVE being fixed  e.g. "CVE-2021-44228"

    Returns: safe_version, all_available, source, repo, cve_id
    Raises RuntimeError if no versions found.
    """
    if TEST_MODE:
        params = {
            "q": f"g:{group_id} AND a:{artifact_id}",
            "core": "gav",
            "rows": "50",
            "wt": "json",
        }
        async with httpx.AsyncClient(timeout=TIMEOUT) as client:
            try:
                r = await client.get(MAVEN_CENTRAL_SEARCH, params=params)
                r.raise_for_status()
            except httpx.HTTPStatusError as e:
                raise RuntimeError(
                    f"[maven-mcp] Maven Central search HTTP {e.response.status_code} "
                    f"for {group_id}:{artifact_id}."
                )
            except httpx.ConnectError:
                raise RuntimeError(
                    "[maven-mcp] Cannot reach Maven Central. Check internet."
                )
        docs = r.json().get("response", {}).get("docs", [])
        if not docs:
            raise RuntimeError(
                f"[maven-mcp] {group_id}:{artifact_id} not found on Maven Central."
            )
        all_versions = _sort_versions([d["v"] for d in docs if "v" in d])
        source = "maven-central"
    else:
        url = (
            f"{NEXUS_BASE}/service/rest/v1/search"
            f"?repository={REPO_REL}&group={group_id}&name={artifact_id}"
            f"&sort=version&direction=desc"
        )
        async with httpx.AsyncClient(timeout=TIMEOUT) as client:
            try:
                r = await client.get(url, headers=_headers())
                r.raise_for_status()
            except httpx.HTTPStatusError as e:
                raise RuntimeError(
                    f"[maven-mcp] Nexus HTTP {e.response.status_code} for "
                    f"{group_id}:{artifact_id}. Check {AUTH_ENV_VAR}."
                )
            except httpx.ConnectError:
                raise RuntimeError(
                    f"[maven-mcp] Cannot connect to Nexus at {NEXUS_BASE}."
                )
        items = r.json().get("items", [])
        if not items:
            raise RuntimeError(
                f"[maven-mcp] {group_id}:{artifact_id} not found in '{REPO_REL}'."
            )
        all_versions = _sort_versions([i["version"] for i in items if "version" in i])
        source = "internal"

    return {
        "group_id":        group_id,
        "artifact_id":     artifact_id,
        "current_version": current_version,
        "safe_version":    all_versions[0],
        "all_available":   all_versions,
        "source":          source,
        "repo":            REPO_REL,
        "cve_id":          cve_id,
    }
# 💡 This is like a librarian who fetches the newest edition of a book from
#    either the public library (Maven Central) or a private archive (Nexus),
#    depending on which reading room (mode) is configured.
# ❓ In this metaphor, what represents the internal Nexus repository?
# 🔑 The private archive

# ── TOOL 2 ────────────────────────────────────────────────────────────────────

@mcp.tool()
async def check_availability(
    group_id: str,
    artifact_id: str,
    version: str,
) -> dict:
    """
    Confirm a specific version JAR exists and is downloadable.

    TEST mode  : checks repo1.maven.org (Maven Central).
    PRODUCTION : checks internal Nexus/Artifactory.

    Args:
        group_id:    e.g. "org.apache.logging.log4j"
        artifact_id: e.g. "log4j-core"
        version:     e.g. "2.17.2"

    Returns: available (bool), jar_url, source
    """
    group_path = group_id.replace(".", "/")
    jar_name   = f"{artifact_id}-{version}.jar"

    if TEST_MODE:
        jar_url = f"{MAVEN_CENTRAL_REPO}/{group_path}/{artifact_id}/{version}/{jar_name}"
        source  = "maven-central"
    else:
        jar_url = (
            f"{NEXUS_BASE}/repository/{REPO_REL}"
            f"/{group_path}/{artifact_id}/{version}/{jar_name}"
        )
        source = "internal"

    async with httpx.AsyncClient(timeout=TIMEOUT) as client:
        try:
            r = await client.head(jar_url, headers=_headers())
            available = r.status_code == 200
        except httpx.ConnectError:
            base = MAVEN_CENTRAL_REPO if TEST_MODE else NEXUS_BASE
            raise RuntimeError(f"[maven-mcp] Cannot connect to {base}.")

    return {
        "group_id":    group_id,
        "artifact_id": artifact_id,
        "version":     version,
        "available":   available,
        "jar_url":     jar_url if available else None,
        "source":      source,
    }
# ✅ Statement 1: Returns available=True when the JAR HEAD request returns HTTP 200.
# ✅ Statement 2: In test_mode the jar_url points to repo1.maven.org, not Nexus.
# ❌ Statement 3: Returns available=True for any 2xx status code from the server.
# ❓ Which of these three statements is false?
# 🔑 Statement 3: Returns available=True for any 2xx status code from the server.

# ── TOOL 3 ────────────────────────────────────────────────────────────────────

@mcp.tool()
def get_dependency_tree(
    pom_path: str,
    group_id: str,
    artifact_id: str,
    target_version: str,
) -> dict:
    """
    Run `mvn dependency:tree` on a pom.xml and return structured results.
    Called by pom-patcher after edits to verify no residual old version remains.
    Always a local subprocess call — uses developer's ~/.m2/settings.xml.

    Args:
        pom_path:       Path to pom.xml (absolute or relative to cwd)
        group_id:       e.g. "org.apache.logging.log4j"
        artifact_id:    e.g. "log4j-core"
        target_version: expected safe version e.g. "2.17.2"

    Returns: occurrences, residual_old_version, all_clean, error
    """
    pom = Path(pom_path)
    if not pom.exists():
        return {
            "pom_path": pom_path,
            "artifact_checked": f"{group_id}:{artifact_id}",
            "target_version": target_version,
            "occurrences": [],
            "residual_old_version": False,
            "all_clean": False,
            "raw_tree_lines": 0,
            "error": f"pom.xml not found at {pom_path}",
        }

    try:
        result = subprocess.run(
            [
                "mvn", "dependency:tree",
                f"-Dincludes={group_id}:{artifact_id}",
                "--no-transfer-progress", "-q",
            ],
            cwd=str(pom.parent),
            capture_output=True,
            text=True,
            timeout=300,
        )
        output = result.stdout + result.stderr
    except subprocess.TimeoutExpired:
        return {
            "pom_path": pom_path,
            "artifact_checked": f"{group_id}:{artifact_id}",
            "target_version": target_version,
            "occurrences": [],
            "residual_old_version": False,
            "all_clean": False,
            "raw_tree_lines": 0,
            "error": "mvn dependency:tree timed out after 300s",
        }
    except FileNotFoundError:
        return {
            "pom_path": pom_path,
            "artifact_checked": f"{group_id}:{artifact_id}",
            "target_version": target_version,
            "occurrences": [],
            "residual_old_version": False,
            "all_clean": False,
            "raw_tree_lines": 0,
            "error": "mvn not found — ensure Maven is on PATH",
        }

    lines       = output.splitlines()
    target_str  = f"{group_id}:{artifact_id}"
    occurrences = []
    for line in lines:
        if target_str in line:
            clean = (
                line.strip()
                    .replace("[INFO]", "")
                    .lstrip(" +-\\|")
                    .strip()
            )
            parts = clean.split(":")
            occurrences.append({
                "coordinates": clean,
                "version": parts[3] if len(parts) > 3 else "unknown",
                "scope":   parts[4] if len(parts) > 4 else "unknown",
            })

    residual  = any(o["version"] not in (target_version, "unknown") for o in occurrences)
    all_clean = bool(occurrences) and not residual

    return {
        "pom_path":             pom_path,
        "artifact_checked":     f"{group_id}:{artifact_id}",
        "target_version":       target_version,
        "occurrences":          occurrences,
        "residual_old_version": residual,
        "all_clean":            all_clean,
        "raw_tree_lines":       len(lines),
        "error":                None if result.returncode == 0
                                else f"mvn exited {result.returncode}",
    }
# 📝 This method returns all_clean=True when all occurrences match target_version,
#    and returns all_clean=False when the occurrences list is empty.
# ❓ What does all_clean equal when the artifact does not appear in the tree at all?
# 🔑 False (all_clean requires bool(occurrences) to be True and residual to be False)

# ── ENTRYPOINT ────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    mcp.run(transport="stdio")
