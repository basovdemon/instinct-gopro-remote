<#
.SYNOPSIS
  Builds bin/GoProRemote.prg for Instinct 3 Solar and optionally runs it in the simulator.
.EXAMPLE
  ./tools/build.ps1          # build only
  ./tools/build.ps1 -Run     # build, start simulator if needed, launch app (println output goes to this console)
  ./tools/build.ps1 -Test    # build with (:test) functions and run unit tests in the simulator
  ./tools/build.ps1 -DataField [-Run]   # the data field instead -> bin/GoProField.prg
  ./tools/build.ps1 -DataField -Lean    # ... without BLE logs, ~2 KB less memory (if 32 KB gets tight)
  ./tools/build.ps1 -Release            # Store build of the watch app: no logs, -O 3, no debug info ->
                                        #   bin/GoProRemote.iq (upload) + bin/GoProRemote-release.prg (sideload to try it)
  ./tools/build.ps1 -DataField -Release # the same for the data field -> bin/GoProField.iq, bin/GoProField-release.prg
#>
param(
    [switch]$Run,
    [switch]$Test,
    [switch]$DataField,
    [switch]$Lean,
    [switch]$Release,
    [string]$Device = "instinct3solar45mm"   # covers 45mm and 50mm
)
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root

# Active SDK is whatever SDK Manager marked as current.
$sdk = (Get-Content "$env:APPDATA\Garmin\ConnectIQ\current-sdk.cfg" -Raw).Trim()
if (-not (Test-Path "$sdk\bin\monkeyc.bat")) { throw "Connect IQ SDK not found at $sdk" }
if (-not (Test-Path "developer_key.der")) { throw "developer_key.der missing (see README.md -> Building)" }

if ($Release -and $Test) { throw "-Release and -Test do not mix: tests run on a normal build" }

New-Item -ItemType Directory -Force bin | Out-Null
$jungle = if ($DataField) { "datafield/monkey.jungle" } else { "monkey.jungle" }
# Later jungle files override earlier ones: nolog.jungle switches the BLE logs off.
if ($Lean -or $Release) { $jungle += ";nolog.jungle" }
$name = if ($DataField) { "GoProField" } else { "GoProRemote" }
$prg = if ($Test) { "bin/$name-test.prg" } elseif ($Release) { "bin/$name-release.prg" } else { "bin/$name.prg" }
# -l 3: strictest type checking; -t compiles (:test) functions in.
# -O 3: ~0.5 KB less, and it is what drops the disabled log calls; always for the data field (32 KB).
# -r: no debug information (smaller; crash logs then show fewer details).
$flags = @("-w", "-l", "3")
if ($DataField -or $Lean -or $Release) { $flags += @("-O", "3") }
if ($Release) { $flags += "-r" }
if ($Test) { $flags += "-t" }
& "$sdk\bin\monkeyc.bat" -d $Device -f $jungle -o $prg -y developer_key.der @flags
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

if ($Release) {
    # The Store package: built for every product in the manifest, signed with the developer key.
    # Store updates must be signed with the same key: keep a backup of developer_key.*: a lost key cannot be recovered.
    & "$sdk\bin\monkeyc.bat" -e -f $jungle -o "bin/$name.iq" -y developer_key.der @flags
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    Get-Item $prg, "bin/$name.iq" | ForEach-Object { "{0}  {1:N0} bytes" -f $_.Name, $_.Length }
}

if ($Run -or $Test) {
    if (-not (Get-Process simulator -ErrorAction SilentlyContinue)) {
        Start-Process "$sdk\bin\simulator.exe"
        Start-Sleep -Seconds 5
    }
    if ($Test) {
        & "$sdk\bin\monkeydo.bat" $prg $Device /t
    } else {
        & "$sdk\bin\monkeydo.bat" $prg $Device
    }
}
