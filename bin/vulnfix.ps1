# VulnFix CLI — Windows PowerShell wrapper
# ==========================================
# Installed to ~/.vulnfix/bin/vulnfix.ps1
# Delegates to the bash script via Git Bash.
#
# Commands:
#   vulnfix init [--force]
#   vulnfix configure
#   vulnfix update
#   vulnfix validate
#   vulnfix kb add <groupId:artifactId>

$BinDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$InstallDir = Split-Path -Parent $BinDir
$BashScript = Join-Path $InstallDir "bin\vulnfix"

# Find bash (Git Bash or WSL)
$BashExe = $null
$candidates = @(
    "C:\Program Files\Git\bin\bash.exe",
    "C:\Program Files\Git\usr\bin\bash.exe",
    (Get-Command bash -ErrorAction SilentlyContinue)?.Source
)
foreach ($c in $candidates) {
    if ($c -and (Test-Path $c)) { $BashExe = $c; break }
}

if (-not $BashExe) {
    Write-Error "bash not found. Install Git for Windows (https://git-scm.com) to use VulnFix."
    exit 1
}

# Convert Windows path to bash-compatible path
$BashScriptPath = $BashScript -replace "\\", "/" -replace "^([A-Za-z]):", "/`$1"

& $BashExe $BashScriptPath @args
exit $LASTEXITCODE
