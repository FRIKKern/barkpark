# Barkpark `bp` CLI installer for Windows (irm | iex).
#
#   irm https://raw.githubusercontent.com/FRIKKern/barkpark/main/scripts/install-cli.ps1 | iex
#
# Detects arch, downloads the matching bp-windows-<arch>.exe release binary,
# verifies its sha256 against the release's checksums.txt, installs it into the
# bin dir, and adds that dir to the user PATH. The Windows counterpart to
# scripts/install-cli.sh -- same env tunables, same checksum policy.
#
# ASCII-only on purpose: works whether piped through `iex` or saved and run as a
# file under Windows PowerShell 5.1 (which misreads UTF-8 files that lack a BOM).
#
# Tunables (env):
#   BARKPARK_CLI_VERSION       pin a release, e.g. 1.0.1 -- downloads from
#                              releases/download/cli-v<version> instead of latest
#   BARKPARK_CLI_RELEASE_BASE  base URL to fetch from; overrides _CLI_VERSION
#   BARKPARK_BIN_DIR           install dir (default: %LOCALAPPDATA%\Barkpark\bin)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Die($msg) { Write-Error "install-cli: $msg"; exit 1 }
function Note($msg) { Write-Host "install-cli: $msg" }

$RepoUrl = 'https://github.com/FRIKKern/barkpark'

# --- Resolve release base -----------------------------------------------------
if ($env:BARKPARK_CLI_RELEASE_BASE) {
  $releaseBase = $env:BARKPARK_CLI_RELEASE_BASE
} elseif ($env:BARKPARK_CLI_VERSION) {
  $releaseBase = "$RepoUrl/releases/download/cli-v$($env:BARKPARK_CLI_VERSION)"
} else {
  # Resolve the newest cli-v* release via the GitHub API instead of trusting
  # releases/latest: the repo also publishes build-<sha> server-artifact
  # releases (no bp assets), and one of those holding "latest" 404s every
  # unpinned install. The [0-9.]+ pattern skips prereleases (cli-v*-rc.*),
  # matching the old releases/latest rule.
  $releaseBase = "$RepoUrl/releases/latest/download"
  try {
    $apiUrl = 'https://api.github.com/repos/FRIKKern/barkpark/releases?per_page=30'
    $releases = Invoke-RestMethod -Uri $apiUrl -UseBasicParsing
    $cliTag = ($releases | Where-Object { $_.tag_name -match '^cli-v[0-9.]+$' } |
               Select-Object -First 1).tag_name
    if ($cliTag) { $releaseBase = "$RepoUrl/releases/download/$cliTag" }
  } catch {
    Note "GitHub API unreachable; falling back to releases/latest"
  }
}
$releaseBase = $releaseBase.TrimEnd('/')

# --- Detect arch --------------------------------------------------------------
# PROCESSOR_ARCHITECTURE is the *process* arch; on ARM64 a 32-bit PowerShell host
# would report otherwise, so also consult the OS arch via the WOW64 var.
$archRaw = $env:PROCESSOR_ARCHITEW6432
if (-not $archRaw) { $archRaw = $env:PROCESSOR_ARCHITECTURE }
switch ($archRaw) {
  'AMD64' { $arch = 'amd64' }
  'ARM64' { $arch = 'arm64' }
  'x86'   { Die "32-bit Windows is unsupported (need a 64-bit host)" }
  default { Die "unsupported arch '$archRaw' (supported: AMD64, ARM64)" }
}

$asset = "bp-windows-$arch.exe"
$url = "$releaseBase/$asset"

# --- Resolve install dir ------------------------------------------------------
if ($env:BARKPARK_BIN_DIR) {
  $binDir = $env:BARKPARK_BIN_DIR
} else {
  $binDir = Join-Path $env:LOCALAPPDATA 'Barkpark\bin'
}
New-Item -ItemType Directory -Force -Path $binDir | Out-Null

$dest = Join-Path $binDir 'bp.exe'
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "bp-install-$([System.IO.Path]::GetRandomFileName()).exe"
$sumsTmp = Join-Path ([System.IO.Path]::GetTempPath()) "bp-sums-$([System.IO.Path]::GetRandomFileName()).txt"

# TLS 1.2 for Windows PowerShell 5.1 (GitHub requires it; PS5.1 defaults lower).
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

Note "detected windows/$arch"
Note "downloading $url"
try {
  Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing
} catch {
  Write-Error "install-cli: download failed from $url"
  Write-Error "install-cli: if no CLI release has been published yet, build from source:"
  Write-Error "install-cli:   git clone $RepoUrl; cd barkpark; make cli-build"
  exit 1
}

# --- Verify sha256 against the release's checksums.txt -------------------------
# Hard-fail on mismatch or a missing entry; warn-and-continue only when
# checksums.txt itself is absent (mirrors install-cli.sh).
$sumsUrl = "$releaseBase/checksums.txt"
$haveSums = $true
try {
  Invoke-WebRequest -Uri $sumsUrl -OutFile $sumsTmp -UseBasicParsing
} catch {
  $haveSums = $false
}
if ($haveSums) {
  $line = Select-String -Path $sumsTmp -Pattern ('\s' + [regex]::Escape($asset) + '$') | Select-Object -First 1
  if (-not $line) { Remove-Item $tmp,$sumsTmp -ErrorAction SilentlyContinue; Die "checksums.txt has no entry for $asset" }
  $expected = ($line.Line -split '\s+')[0].ToLower()
  $actual = (Get-FileHash -Algorithm SHA256 -Path $tmp).Hash.ToLower()
  if ($actual -ne $expected) {
    Remove-Item $tmp,$sumsTmp -ErrorAction SilentlyContinue
    Die "checksum mismatch for $asset -- refusing to install (expected $expected, got $actual)"
  }
  Note "checksum OK ($actual)"
  Remove-Item $sumsTmp -ErrorAction SilentlyContinue
} else {
  Note "WARNING: checksums.txt not found at $sumsUrl; skipping verification"
}

Move-Item -Force -Path $tmp -Destination $dest

# Best-effort installed-version readout (non-TTY `bp version` emits JSON).
try {
  $ver = (& $dest version | ConvertFrom-Json).cli_version
} catch { $ver = $null }
if ($ver) { Note "installed bp $ver -> $dest" } else { Note "installed bp -> $dest" }

# --- Add bin dir to the user PATH (persistent + current session) --------------
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$onPath = ($userPath -split ';') -contains $binDir
if (-not $onPath) {
  $newPath = if ([string]::IsNullOrEmpty($userPath)) { $binDir } else { "$userPath;$binDir" }
  [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
  Note "added $binDir to your user PATH (new terminals pick it up automatically)"
}
# Make `bp` work in THIS session too, without reopening the terminal.
if (($env:Path -split ';') -notcontains $binDir) { $env:Path = "$env:Path;$binDir" }

# --- PATH postcondition (fresh-process verify) --------------------------------
# The registry write above is the persistence, but writing it does not prove a
# NEW terminal will resolve bp -- a new process builds PATH from the Machine +
# User registry, not this installer's in-memory $env:Path (which the line above
# just tweaked and could mask a failed write). So spawn a fresh, profile-less
# child whose PATH is rebuilt from the registry exactly as a brand-new terminal
# would, and confirm it resolves bp.
function Test-FreshShellResolvesBp {
  $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
  $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
  $fresh   = (@($machine, $user) | Where-Object { $_ }) -join ';'
  # Use the SAME host that is running this script (powershell.exe or pwsh.exe).
  $self = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
  $probe = "`$env:Path = '$fresh'; if (Get-Command bp -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }"
  & $self -NoProfile -NonInteractive -Command $probe *> $null
  return ($LASTEXITCODE -eq 0)
}

if (Test-FreshShellResolvesBp) {
  Note "verified: a fresh terminal resolves bp on PATH"
} else {
  Note "WARNING: a fresh terminal still can't resolve bp; add $binDir to your PATH manually"
}

# GUI-agent stale-PATH caveat: a Cursor / Claude Desktop / VS Code process
# spawns 'bp mcp serve' with the PATH captured when the AGENT launched, so an
# already-running agent won't see bp until it is fully quit and reopened.
Note "NOTE -- a GUI-launched agent (Cursor, Claude Desktop, VS Code) runs"
Note "        'bp mcp serve' with the PATH it captured at its own launch, so an"
Note "        already-running agent won't see bp until you fully quit and reopen"
Note "        it (a new terminal alone is not enough)."

Note "done."
Write-Host ""
Write-Host "  Get started:   bp          (first run launches the setup wizard)"
Write-Host "  Verify:        bp version"
