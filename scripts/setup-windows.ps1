<#
.SYNOPSIS
  One-command native Barkpark setup for Windows. Installs the toolchain, brings
  up PostgreSQL, builds + seeds the API, and starts the dev server.

.DESCRIPTION
  Premium zero-friction local setup, encoding every Windows gotcha:
    * installs Scoop + Erlang/OTP + Elixir + PostgreSQL (no admin needed)
    * pins the Scoop toolchain ahead of any stale system Erlang/Elixir on PATH
    * initializes + starts a local Postgres cluster (trust auth)
    * fetches deps, creates/migrates/seeds the DB, starts Phoenix on :PORT
  The :image media dep (vix/libvips) auto-drops on Windows via mix.exs, so the
  build needs no C toolchain. Media renditions are the only feature affected.

  Always run the server through THIS script (e.g. `setup-windows.ps1 start`):
  it sets PATH correctly every time, so you never fight the stale system
  Erlang/Elixir that Windows keeps ahead of Scoop in new shells.

.PARAMETER Action
  full   (default) install everything, set up the DB, start the server
  start  start Postgres + the server (assumes `full` already ran)
  stop   stop Postgres (close the server window to stop Phoenix)
  status show toolchain, Postgres, and API health

.PARAMETER Profile
  demo  (default) 8 schemas + ~27 docs + the well-known `barkpark-dev-token`
  clean papers + media schemas only; one admin token printed once

.PARAMETER Port
  HTTP port for Phoenix (default 4000).

.PARAMETER NoStart
  With `full`: do everything except start the server.

.PARAMETER Recreate
  With `full`: drop + recreate the DB even if it already exists (DESTRUCTIVE).

.EXAMPLE
  .\scripts\setup-windows.ps1
.EXAMPLE
  .\scripts\setup-windows.ps1 start
.EXAMPLE
  .\scripts\setup-windows.ps1 full -Profile clean -Port 4001
#>
[CmdletBinding()]
param(
  [ValidateSet('full','start','stop','status')] [string]$Action = 'full',
  [ValidateSet('demo','clean')] [string]$Profile = 'demo',
  [int]$Port = 4000,
  [switch]$NoStart,
  [switch]$Recreate
)

$ErrorActionPreference = 'Stop'

# --- paths --------------------------------------------------------------------
$RepoRoot = Split-Path -Parent $PSScriptRoot
$ApiDir   = Join-Path $RepoRoot 'api'
$ScoopRoot = if ($env:SCOOP) { $env:SCOOP } else { Join-Path $env:USERPROFILE 'scoop' }

function Step($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "    $m" -ForegroundColor Green }
function Warn($m) { Write-Host "    $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }

# Prepend the Scoop toolchain so it shadows any stale system Erlang/Elixir.
function Use-Toolchain {
  $dirs = @(
    "$ScoopRoot\shims",
    "$ScoopRoot\apps\elixir\current\bin",
    "$ScoopRoot\apps\erlang\current\bin",
    "$ScoopRoot\apps\postgresql\current\bin",
    "$ScoopRoot\apps\imagemagick\current"
  )
  $env:Path = ($dirs -join ';') + ';' + $env:Path
}

# OTP version from the install dir (erl -eval quoting is too shell-fragile).
function Get-ErlangVersion {
  try {
    $base = Join-Path $ScoopRoot 'apps\erlang'
    $cur  = Get-Item (Join-Path $base 'current') -ErrorAction Stop
    if ($cur.Target) { return Split-Path -Leaf (@($cur.Target)[0]) }
    return (Get-ChildItem $base -Directory | Where-Object Name -ne 'current' |
            Sort-Object Name -Descending | Select-Object -First 1).Name
  } catch { return 'installed' }
}

function PgBin   { Join-Path $ScoopRoot 'apps\postgresql\current\bin' }
function PgData  { Join-Path $ScoopRoot 'apps\postgresql\current\data' }
function PgLog   { Join-Path $ScoopRoot 'apps\postgresql\current\pg.log' }

function Test-Pg {
  & (Join-Path (PgBin) 'pg_isready.exe') -h localhost -q 2>$null
  return ($LASTEXITCODE -eq 0)
}

# --- installers ---------------------------------------------------------------
function Install-Scoop {
  if (Get-Command scoop -ErrorAction SilentlyContinue) { Ok 'Scoop present'; return }
  Step 'Installing Scoop (no admin)'
  try { Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force } catch {}
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $admin = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $script = Invoke-RestMethod get.scoop.sh
  if ($admin) { & ([scriptblock]::Create($script)) -RunAsAdmin } else { & ([scriptblock]::Create($script)) }
  $env:Path = "$ScoopRoot\shims;$env:Path"
  Ok 'Scoop installed'
}

function Install-Toolchain {
  Step 'Installing Erlang + Elixir + PostgreSQL + ImageMagick via Scoop (idempotent)'
  scoop install erlang elixir postgresql imagemagick
  Use-Toolchain
  Ok ("erlang : OTP " + (Get-ErlangVersion))
  Ok ("elixir : " + ((& elixir --version 2>$null | Select-String '^Elixir').ToString()))
  Ok ("psql   : " + ((& (Join-Path (PgBin) 'psql.exe') --version 2>$null)))
}

# --- postgres -----------------------------------------------------------------
function Ensure-Postgres {
  Step 'Starting PostgreSQL'
  if (-not (Test-Path (Join-Path (PgData) 'PG_VERSION'))) {
    Warn 'No data cluster found; initializing (trust auth, postgres superuser)'
    & (Join-Path (PgBin) 'initdb.exe') -D (PgData) -U postgres --auth-local=trust --auth-host=trust -E UTF8 | Out-Null
  }
  if (Test-Pg) { Ok 'Postgres already accepting connections on :5432'; return }
  & (Join-Path (PgBin) 'pg_ctl.exe') -D (PgData) -l (PgLog) -w start | Out-Null
  if (Test-Pg) { Ok 'Postgres started on :5432' } else { Die "Postgres did not start; see $(PgLog)" }
}

function Stop-Postgres {
  Step 'Stopping PostgreSQL'
  if (Test-Pg) {
    & (Join-Path (PgBin) 'pg_ctl.exe') -D (PgData) -m fast stop | Out-Null
    Ok 'Postgres stopped'
  } else { Ok 'Postgres was not running' }
}

# --- elixir build + db --------------------------------------------------------
function Invoke-Mix([string]$mixArgs) {
  Push-Location $ApiDir
  try { cmd /c "mix $mixArgs" ; if ($LASTEXITCODE -ne 0) { throw "mix $mixArgs failed (exit $LASTEXITCODE)" } }
  finally { Pop-Location }
}

function Build-And-Seed {
  Step 'Fetching deps + building (vix/image auto-skipped on Windows)'
  Invoke-Mix 'local.hex --force'
  Invoke-Mix 'local.rebar --force'
  Invoke-Mix 'deps.get'
  Invoke-Mix 'compile'

  $env:BARKPARK_SEED_PROFILE = $Profile
  $dbExists = $false
  if (Test-Pg) {
    & (Join-Path (PgBin) 'psql.exe') -U postgres -h localhost -d barkpark_dev -tAc 'select 1' 2>$null | Out-Null
    $dbExists = ($LASTEXITCODE -eq 0)
  }
  if ($dbExists -and -not $Recreate) {
    Step "Database exists; migrating + seeding (profile: $Profile). Use -Recreate to wipe."
    Invoke-Mix 'ecto.migrate'
    Invoke-Mix 'run priv/repo/seeds.exs'
  } else {
    if ($dbExists) { Warn 'Recreate requested: dropping the existing database' }
    Step "Creating + migrating + seeding the database (profile: $Profile)"
    Invoke-Mix 'ecto.reset'
  }
  Ok 'Database ready'
}

# --- server -------------------------------------------------------------------
function Start-Server {
  Step "Starting Phoenix on :$Port (new window)"
  $dirs = "$ScoopRoot\shims;$ScoopRoot\apps\elixir\current\bin;$ScoopRoot\apps\erlang\current\bin;$ScoopRoot\apps\postgresql\current\bin;$ScoopRoot\apps\imagemagick\current"
  $cmd = "`$env:Path='$dirs;'+`$env:Path; `$env:PORT='$Port'; Set-Location '$ApiDir'; Write-Host 'Barkpark dev server -- close this window to stop' -ForegroundColor Cyan; mix phx.server"
  Start-Process powershell -ArgumentList '-NoExit','-NoProfile','-Command', $cmd | Out-Null

  Step 'Waiting for the API to answer'
  $deadline = (Get-Date).AddMinutes(2)
  while ((Get-Date) -lt $deadline) {
    try {
      $r = Invoke-WebRequest "http://localhost:$Port/api/schemas" -UseBasicParsing -TimeoutSec 3
      if ($r.StatusCode -eq 200) { Ok 'API is live'; return $true }
    } catch { Start-Sleep -Seconds 3 }
  }
  Warn 'API did not answer in time; check the server window for errors'
  return $false
}

function Show-Status {
  Step 'Status'
  Use-Toolchain
  Write-Host "    erlang : OTP $(Get-ErlangVersion)"
  Write-Host ("    elixir : " + ((& elixir --version 2>$null | Select-String '^Elixir').ToString()))
  if (Test-Pg) { Write-Host "    postgres: UP (:5432)" -ForegroundColor Green } else { Write-Host "    postgres: down" -ForegroundColor Yellow }
  try {
    $r = Invoke-WebRequest "http://localhost:$Port/api/schemas" -UseBasicParsing -TimeoutSec 3
    Write-Host "    api    : UP (http://localhost:$Port, HTTP $($r.StatusCode))" -ForegroundColor Green
  } catch { Write-Host "    api    : down (:$Port)" -ForegroundColor Yellow }
}

function Show-Summary([bool]$serverUp) {
  Write-Host ""
  Write-Host "============================================================" -ForegroundColor Cyan
  Write-Host " Barkpark is set up." -ForegroundColor Cyan
  Write-Host "============================================================" -ForegroundColor Cyan
  Write-Host "  Studio   : http://localhost:$Port/studio"
  Write-Host "  Reader   : http://localhost:$Port/papers/<slug>"
  Write-Host "  API      : http://localhost:$Port/api/schemas"
  if ($Profile -eq 'demo') { Write-Host "  Token    : barkpark-dev-token  (read+write+admin)" }
  else { Write-Host "  Token    : printed once above (clean profile)" }
  Write-Host ""
  Write-Host "  Create a paper:" -ForegroundColor Cyan
  Write-Host "    irm http://localhost:$Port/v1/plugins/bulldocs/papers -Method Post ``"
  Write-Host "      -Headers @{Authorization='Bearer barkpark-dev-ingest-token'} ``"
  Write-Host "      -ContentType 'application/json' -Body '{""slug"":""hi"",""blocks"":[{""type"":""heading"",""level"":1,""text"":""Hi""}]}'"
  Write-Host ""
  Write-Host "  Restart later: .\scripts\setup-windows.ps1 start"
  Write-Host "  Stop Postgres: .\scripts\setup-windows.ps1 stop"
  if (-not $serverUp -and -not $NoStart) { Warn 'Server not confirmed up -- see the server window.' }
}

# --- dispatch -----------------------------------------------------------------
if (-not (Test-Path $ApiDir)) { Die "api/ not found under $RepoRoot -- run this from a Barkpark checkout" }

switch ($Action) {
  'status' { Show-Status; break }
  'stop'   { Use-Toolchain; Stop-Postgres; Warn 'Close the Phoenix window to stop the server.'; break }
  'start'  {
    Use-Toolchain
    if (-not (Get-Command scoop -ErrorAction SilentlyContinue)) { Die "Toolchain missing -- run: .\scripts\setup-windows.ps1 full" }
    Ensure-Postgres
    $up = Start-Server
    Show-Summary $up
    break
  }
  'full'   {
    Write-Host "Barkpark native Windows setup (profile: $Profile, port: $Port)" -ForegroundColor Cyan
    Install-Scoop
    Install-Toolchain
    Ensure-Postgres
    Build-And-Seed
    $up = $false
    if (-not $NoStart) { $up = Start-Server } else { Warn 'NoStart: skipping server launch' }
    Show-Summary $up
    break
  }
}
