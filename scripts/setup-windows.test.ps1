<# Native regression checks for Windows runtime selection; no install or database writes. #>
[CmdletBinding()]
param([switch]$RealRuntime)
$ErrorActionPreference = 'Stop'
$SourceRoot = Split-Path -Parent $PSScriptRoot
$Launcher = Join-Path $PSScriptRoot 'setup-windows.ps1'
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($Launcher, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
# Load only these definitions; the setup action dispatcher must never execute.
foreach ($name in @('Use-Toolchain', 'Get-ErlangVersion', 'Start-Server')) {
  $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
  if (-not $definition) { throw "Missing launcher function: $name" }
  . ([scriptblock]::Create($definition.Extent.Text))
}
function Assert($condition, $message) { if (-not $condition) { throw $message } }
function Step($message) {}
function Ok($message) {}
function Warn($message) {}
$originalPath = $env:Path
$originalLimit = $env:ERL_CRASH_DUMP_BYTES
$originalErlOptions = $env:ELIXIR_ERL_OPTIONS
$fixtureBase = Join-Path $SourceRoot ('.artifacts\windows-runtime-guard\' + [guid]::NewGuid())
$otpFloor = [int]([regex]::Match((Get-Content (Join-Path $SourceRoot '.tool-versions') -Raw), '(?m)^erlang\s+(\d+)\.').Groups[1].Value)
$elixirFloor = [regex]::Match((Get-Content (Join-Path $SourceRoot 'api\mix.exs') -Raw), 'elixir:\s*"~>\s*(\d+\.\d+(?:\.\d+)?)"').Groups[1].Value
$passed = 0
function Fixture([string]$name, [int]$otp = $otpFloor, [string]$elixir = $elixirFloor, [string]$missing = '') {
  $script:RepoRoot = Join-Path $fixtureBase $name
  $script:ApiDir = Join-Path $RepoRoot 'api'
  $script:ScoopRoot = Join-Path $RepoRoot 'scoop'
  $release = Join-Path $ScoopRoot "apps\erlang\current\releases\$otp"
  foreach ($path in @($ApiDir, $release, "$ScoopRoot\apps\erlang\current\bin", "$ScoopRoot\apps\elixir\current\bin", "$ScoopRoot\shims")) {
    New-Item -ItemType Directory -Path $path -Force | Out-Null
  }
  [IO.File]::WriteAllText((Join-Path $RepoRoot '.tool-versions'), "erlang $otpFloor.0`n")
  [IO.File]::WriteAllText((Join-Path $ApiDir 'mix.exs'), "elixir: `"~> $elixirFloor`"")
  [IO.File]::WriteAllText((Join-Path $release 'OTP_VERSION'), "$otp.0")
  [IO.File]::WriteAllText("$ScoopRoot\apps\elixir\current\VERSION", $elixir)
  foreach ($relative in @('erlang\current\bin\erl.exe', 'elixir\current\bin\elixir.bat', 'elixir\current\bin\mix.bat')) {
    if ($relative -ne $missing) { [IO.File]::WriteAllBytes((Join-Path "$ScoopRoot\apps" $relative), [byte[]]@()) }
  }
  [IO.File]::WriteAllBytes("$ScoopRoot\shims\erl.exe", [byte[]]@())
  $env:Path = "$ScoopRoot\shims;$originalPath"
  $env:ERL_CRASH_DUMP_BYTES = $null
  $env:ELIXIR_ERL_OPTIONS = $null
}
function Rejected([scriptblock]$operation, [string]$pattern) {
  $errorText = ''
  try { & $operation } catch { $errorText = $_.Exception.Message }
  Assert ($errorText -match $pattern) "Expected rejection '$pattern'; got '$errorText'"
}
function Check([string]$name, [scriptblock]$body) {
  & $body
  $script:passed++
  Write-Host "PASS $name"
}
try {
  Check 'missing Erlang never falls through to the system runtime' {
    Fixture 'missing-erl' -missing 'erlang\current\bin\erl.exe'
    $before = $env:Path
    Rejected { Use-Toolchain } 'Scoop runtime missing'
    Assert ($env:Path -eq $before) 'Rejected install changed PATH'
  }
  Check 'missing Elixir refuses startup' {
    Fixture 'missing-elixir' -missing 'elixir\current\bin\elixir.bat'
    Rejected { Use-Toolchain } 'Scoop runtime missing'
  }
  Check 'missing Mix refuses startup' {
    Fixture 'missing-mix' -missing 'elixir\current\bin\mix.bat'
    Rejected { Use-Toolchain } 'Scoop runtime missing'
  }
  Check 'legacy OTP is rejected before VM startup' {
    Fixture 'legacy-otp' -otp ($otpFloor - 1)
    Rejected { Use-Toolchain } 'too old'
  }
  Check 'legacy Elixir is rejected before VM startup' {
    Fixture 'legacy-elixir' -elixir '1.0.0'
    Rejected { Use-Toolchain } 'too old'
  }
  Check 'invalid runtime metadata refuses startup' {
    Fixture 'invalid-version' -elixir 'installed'
    Rejected { Use-Toolchain } 'metadata is invalid'
  }
  Check 'selected runtime bins beat stale shims and system PATH' {
    Fixture 'path-selection'
    Use-Toolchain
    Assert ((Get-Command erl.exe).Source -eq "$ScoopRoot\apps\erlang\current\bin\erl.exe") 'Stale Erlang won command resolution'
    Assert ((Get-Command elixir.bat).Source -eq "$ScoopRoot\apps\elixir\current\bin\elixir.bat") 'Stale Elixir won command resolution'
  }
  Check 'default dump limit is 64 MiB' {
    Fixture 'default-limit'
    Use-Toolchain
    Assert ($env:ERL_CRASH_DUMP_BYTES -eq '67108864') 'Default dump size is unbounded'
  }
  Check 'explicit disabled dumps remain disabled' {
    Fixture 'disabled-dumps'
    $env:ERL_CRASH_DUMP_BYTES = '0'
    Use-Toolchain
    Assert ($env:ERL_CRASH_DUMP_BYTES -eq '0') 'Explicit zero was overridden'
  }
  Check 'explicit operator limit is preserved' {
    Fixture 'operator-limit'
    $env:ERL_CRASH_DUMP_BYTES = '32768'
    Use-Toolchain
    Assert ($env:ERL_CRASH_DUMP_BYTES -eq '32768') 'Operator limit was overridden'
  }
  Check 'automated VMs cannot read console input and keep operator flags' {
    Fixture 'no-console-input'
    $env:ELIXIR_ERL_OPTIONS = '+S 2:2'
    Use-Toolchain
    Use-Toolchain
    Assert ($env:ELIXIR_ERL_OPTIONS -eq '+S 2:2 -noinput') 'Console input remains enabled, flags were lost, or the noinput flag was duplicated'
  }
  Check 'Phoenix child inherits the validated PATH and dump limit' {
    Fixture 'child-inheritance'
    Use-Toolchain
    $script:Port = 4567
    function Start-Process { param($FilePath, $ArgumentList) $script:childArguments = $ArgumentList; $script:childPath = $env:Path; $script:childLimit = $env:ERL_CRASH_DUMP_BYTES; $script:childErlOptions = $env:ELIXIR_ERL_OPTIONS }
    function Invoke-WebRequest { param($Uri, [switch]$UseBasicParsing, $TimeoutSec) return @{ StatusCode = 200 } }
    Assert (Start-Server) 'Mocked health check failed'
    Assert ($childPath -eq $env:Path -and $childLimit -eq '67108864') 'Child lost inherited runtime settings'
    Assert ($childErlOptions -match '(^|\s)-noinput($|\s)') 'Child lost console-input protection'
    Assert (($childArguments -join ' ') -notmatch '\$env:Path=|shims') 'Child command overrides the validated PATH'
  }
  Check 'Postgres stop does not require a usable Erlang runtime' {
    Fixture 'stop-with-legacy-otp' -otp ($otpFloor - 1)
    $script:postgresStopCalled = $false
    function Stop-Postgres { $script:postgresStopCalled = $true }
    $dispatcher = $ast.Find({ param($node) $node -is [Management.Automation.Language.SwitchStatementAst] }, $true)
    $stop = $dispatcher.Clauses | Where-Object { $_.Item1.Value -eq 'stop' } | Select-Object -First 1
    Assert ($null -ne $stop) 'Cannot find the stop action'
    # Execute its real commands; omit only the switch's terminating break.
    $commands = ($stop.Item2.Statements | Where-Object { $_ -isnot [Management.Automation.Language.BreakStatementAst] } | ForEach-Object { $_.Extent.Text }) -join "`n"
    & ([scriptblock]::Create($commands))
    Assert $postgresStopCalled 'The stop action was blocked by the VM guard'
  }

  if ($RealRuntime) {
    $script:RepoRoot = $SourceRoot
    $script:ApiDir = Join-Path $SourceRoot 'api'
    $script:ScoopRoot = if ($env:SCOOP) { $env:SCOOP } else { Join-Path $env:USERPROFILE 'scoop' }
    $env:Path = $originalPath
    $env:ERL_CRASH_DUMP_BYTES = $null
    Use-Toolchain
    $actualErlang = (Get-Command erl.exe).Source
    $actualElixir = (Get-Command elixir.bat).Source
    $version = @(& $actualElixir --erl '-noinput' --version 2>&1)
    Assert ($LASTEXITCODE -eq 0) 'Installed Elixir version probe failed'
    $observedOtp = [regex]::Match(($version -join "`n"), 'Erlang/OTP (\d+)')
    Assert ($observedOtp.Success -and [int]$observedOtp.Groups[1].Value -ge $otpFloor) 'Installed VM does not meet the repository OTP floor'
    Write-Host ($version -join "`n")
    Assert ($env:ERL_CRASH_DUMP_BYTES -eq '67108864') 'Installed runtime did not inherit the dump limit'
    Write-Host "PASS real runtime: $actualErlang; $actualElixir; ERL_CRASH_DUMP_BYTES=$env:ERL_CRASH_DUMP_BYTES"

    # A small deliberate VM exit proves Erlang enforces a byte cap. No OOM,
    # application boot, database connection, or existing dump is involved.
    $probeDirectory = Join-Path $fixtureBase 'real-runtime'
    New-Item -ItemType Directory -Path $probeDirectory -Force | Out-Null
    $probeFile = Join-Path $probeDirectory 'bounded-halt.exs'
    $probeDump = Join-Path $probeDirectory 'bounded-halt.dump'
    $inputProbe = Join-Path $probeDirectory 'no-input.exs'
    [IO.File]::WriteAllText($inputProbe, 'unless match?({:ok, _}, :init.get_argument(:noinput)), do: System.halt(2); IO.puts("console input disabled")')
    $inputReceipt = @(& $actualElixir $inputProbe 2>&1)
    Assert ($LASTEXITCODE -eq 0 -and ($inputReceipt -join '') -match 'console input disabled') 'Actual VM did not inherit console-input protection'
    Write-Host 'PASS real Erlang console input is disabled through inherited ELIXIR_ERL_OPTIONS'
    [IO.File]::WriteAllText($probeFile, ':erlang.halt(~c"bounded crash dump verification")')
    $originalDumpPath = $env:ERL_CRASH_DUMP
    try {
      $env:ERL_CRASH_DUMP = $probeDump
      $env:ERL_CRASH_DUMP_BYTES = '4096'
      # Windows PowerShell turns expected native stderr into ErrorRecords.
      # Capture them while allowing the VM to finish writing its small dump.
      $nativeErrorPreference = $ErrorActionPreference
      try {
        $ErrorActionPreference = 'Continue'
        $null = & $actualElixir --erl '-noinput' $probeFile 2>&1
      } finally { $ErrorActionPreference = $nativeErrorPreference }
      Assert ($LASTEXITCODE -ne 0) 'The deliberate VM exit unexpectedly succeeded'
      Assert (Test-Path -LiteralPath $probeDump) 'Erlang did not write the probe dump'
      # The Windows CRT expands LF to CRLF after Erlang counts source bytes.
      # Erlang then appends a newline and its abort marker outside that body.
      $dumpText = [IO.File]::ReadAllText($probeDump).Replace("`r`n", "`n")
      $markerOffset = $dumpText.IndexOf('=abort:CRASH DUMP SIZE LIMIT REACHED')
      Assert ($markerOffset -gt 0) 'Dump did not record reaching its configured size limit'
      $body = $dumpText.Substring(0, $markerOffset)
      if ($body.EndsWith("`n")) { $body = $body.Substring(0, $body.Length - 1) }
      $bodyBytes = [Text.Encoding]::UTF8.GetByteCount($body)
      Assert ($bodyBytes -le 4096) 'Erlang did not truncate the dump body at the configured byte limit'
      Write-Host "PASS real Erlang crash dump: $bodyBytes body bytes at the 4096-byte limit; $((Get-Item -LiteralPath $probeDump).Length) on-disk bytes including CRLF and the abort marker"
    } finally { $env:ERL_CRASH_DUMP = $originalDumpPath }
  }
  Write-Host "$passed Windows runtime regression checks passed. No install, migration, seed or database operation ran."
} finally {
  $env:Path = $originalPath
  $env:ERL_CRASH_DUMP_BYTES = $originalLimit
  $env:ELIXIR_ERL_OPTIONS = $originalErlOptions
}
