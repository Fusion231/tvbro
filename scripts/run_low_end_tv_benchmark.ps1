<#
.SYNOPSIS
Run the synthetic Android TV profile benchmark on an already booted device.
.EXAMPLE
.\scripts\run_low_end_tv_benchmark.ps1 -DeviceId emulator-5560 `
  -ArtifactDirectory D:\tvbro\validation\low-end-tv-run `
  -ChannelCount 100 -ProgrammesPerChannel 2 -KeyEvents 20
.NOTES
Start an existing AVD separately, if needed, with the SDK emulator executable:
  -avd TVBro_LowEnd_TV_API_36 -port 5560 -memory 1024 -cores 2
  -gpu swiftshader_indirect -no-snapshot -no-boot-anim
Set ANDROID_AVD_HOME to the existing AVD directory before launching it. When
using Start-Process, use -WindowStyle Hidden. Wait with adb wait-for-device;
if sys.boot_completed is not 1, observe the boot event rather than polling:
  adb -s emulator-5560 logcat -b events -s boot_progress_enable_screen:I -m 1

This helper does not create/erase AVDs, clear application data, reset graphics
counters, or install device tools. Flutter builds and deploys the development
benchmark APK. The harness redirects its support directory to a private
temporary directory: AppDatabase.open uses native Android sqflite with a
separate database, then restores the directory provider and removes its own
temporary files. Use a disposable development device/AVD.
The app is left running for the after snapshots; no uninstall or app-data
cleanup is requested. Snapshots are not peak PSS measurements, and a crashed
process may still be unavailable. Flutter frame metrics come from
TVBRO_LOW_END_PERFORMANCE, not from interpreting gfxinfo as Flutter timings.
An x86 emulator and software GPU do not reproduce an ARM TV Box or its decoder.
For an initial VM-service connection failure only, one attach with a fresh ADB
forward is allowed. A single ADB wait-for-device observer first allows up to
60 seconds for a disconnected device to return. The observed failure does not
establish DDS as its cause. The attach reuses the APK without rebuilding;
test failures or an existing driver result never trigger this fallback. The
helper removes only the forward it allocated after the attach process exits.
#>
[CmdletBinding()]
param(
  [ValidatePattern('^[A-Za-z0-9._:-]+$')]
  [string] $DeviceId = 'emulator-5560',
  [string] $ArtifactDirectory,
  [string] $FlutterPath,
  [string] $AdbPath,
  [ValidateRange(100, 1000000)]
  [int] $ChannelCount,
  [ValidateRange(2, 100000)]
  [int] $ProgrammesPerChannel,
  [ValidateRange(200, 2147483647)]
  [int] $ProgrammeCount,
  [ValidateRange(0, 1000000)]
  [int] $Episodes,
  [ValidateRange(20, 1000000)]
  [int] $KeyEvents,
  [ValidateRange(30, 86400)]
  [int] $TimeoutSeconds = 900
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
# Native failures are checked explicitly, including on hosts with PS 7's
# native-command error preference enabled.
$PSNativeCommandUseErrorActionPreference = $false
$AppRoot = Split-Path -Parent $PSScriptRoot
$WorkspaceRoot = Split-Path -Parent $AppRoot
$PackageName = 'app.tvbro.player.dev'
$TestFile = 'integration_test/low_end_tv_performance_test.dart'
$DriverFile = 'test_driver/low_end_tv_driver.dart'

function Resolve-Tool([string] $ExplicitPath, [string] $CommandName, [string[]] $Candidates) {
  if ($ExplicitPath) {
    if (-not (Test-Path -LiteralPath $ExplicitPath -PathType Leaf)) {
      throw "Executable was not found: $ExplicitPath"
    }
    return (Resolve-Path -LiteralPath $ExplicitPath -ErrorAction Stop).Path
  }
  $Command = Get-Command $CommandName -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($null -ne $Command) { return $Command.Source }
  foreach ($Candidate in $Candidates) {
    if ($Candidate -and (Test-Path -LiteralPath $Candidate -PathType Leaf)) {
      return (Resolve-Path -LiteralPath $Candidate).Path
    }
  }
  throw "$CommandName was not found. Pass its executable path explicitly."
}

function ConvertTo-ProcessArgument([string] $Value) {
  # Start-Process joins ArgumentList into a Windows command line. Quote each
  # argument using the CRT rules so spaces, quotes and trailing slashes survive.
  $Escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
  $Escaped = [regex]::Replace($Escaped, '(\\+)$', '$1$1')
  return '"' + $Escaped + '"'
}

function Invoke-Adb([string[]] $Arguments, [switch] $Required, [ValidateRange(1, 60)] [int] $CommandTimeoutSeconds = 30) {
  $OutputFile = [IO.Path]::GetTempFileName()
  $ErrorFile = [IO.Path]::GetTempFileName()
  $CommandProcess = $null
  try {
    $CommandLine = (@('-s', $DeviceId) + $Arguments | ForEach-Object {
      ConvertTo-ProcessArgument $_
    }) -join ' '
    $CommandProcess = Start-Process -FilePath $script:AdbExecutable `
      -ArgumentList $CommandLine -PassThru -WindowStyle Hidden `
      -RedirectStandardOutput $OutputFile -RedirectStandardError $ErrorFile
    $TimedOut = -not $CommandProcess.WaitForExit($CommandTimeoutSeconds * 1000)
    if ($TimedOut) {
      $CommandProcess.Kill()
      if (-not $CommandProcess.WaitForExit(5000)) {
        throw 'The terminated ADB command did not report its exit within five seconds.'
      }
      $Code = 124
    } else {
      $Code = $CommandProcess.ExitCode
    }
    $Output = [IO.File]::ReadAllText($OutputFile).TrimEnd()
    $StandardError = [IO.File]::ReadAllText($ErrorFile).TrimEnd()
    if ($StandardError) {
      if ($Output) { $Output += [Environment]::NewLine }
      $Output += $StandardError
    }
    if ($TimedOut) {
      $Output = "Timed out after $CommandTimeoutSeconds seconds.`r`n$Output"
    }
    if ($Code -ne 0) {
      if ($Required) { throw "ADB failed ($Code): $($Arguments -join ' '): $Output" }
      return "[ADB exit $Code]`r`n$Output"
    }
    return $Output
  } finally {
    if ($null -ne $CommandProcess) {
      try {
        if (-not $CommandProcess.HasExited) {
          $CommandProcess.Kill()
          if (-not $CommandProcess.WaitForExit(5000)) {
            Write-Warning "This run's terminated ADB command has not reported its exit."
          }
        }
      } finally {
        $CommandProcess.Dispose()
      }
    }
    Remove-Item -LiteralPath $OutputFile, $ErrorFile -Force -ErrorAction SilentlyContinue
  }
}

function Save-Snapshot([string] $Stage) {
  foreach ($Entry in @(
    @{ Name = 'meminfo'; Args = @('shell', 'dumpsys', 'meminfo', $PackageName) },
    @{ Name = 'gfxinfo'; Args = @('shell', 'dumpsys', 'gfxinfo', $PackageName, 'framestats') },
    @{ Name = 'exit-info'; Args = @('shell', 'dumpsys', 'activity', 'exit-info', $PackageName) },
    @{ Name = 'system-memory'; Args = @('shell', 'cat', '/proc/meminfo') }
  )) {
    Invoke-Adb -Arguments $Entry.Args |
      Set-Content -LiteralPath (Join-Path $ArtifactDirectory "$Stage-$($Entry.Name).txt") -Encoding UTF8
  }
}

function Invoke-FlutterDrive([string[]] $Arguments, [string] $DestinationLog) {
  $Writer = [IO.StreamWriter]::new($DestinationLog, $false, [Text.UTF8Encoding]::new($false))
  $PreviousPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    & $script:FlutterExecutable @Arguments 2>&1 | ForEach-Object {
      $Line = $_.ToString()
      $Writer.WriteLine($Line)
      Write-Host $Line
    }
    return $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $PreviousPreference
    $Writer.Dispose()
  }
}

function Wait-ForAdbDevice {
  $WaitOutput = Join-Path $ArtifactDirectory 'attach-wait-for-device.stdout.log'
  $WaitError = Join-Path $ArtifactDirectory 'attach-wait-for-device.stderr.log'
  $DeviceWaiter = Start-Process -FilePath $script:AdbExecutable `
    -ArgumentList @('-s', $DeviceId, 'wait-for-device') -PassThru -WindowStyle Hidden `
    -RedirectStandardOutput $WaitOutput -RedirectStandardError $WaitError
  try {
    if (-not $DeviceWaiter.WaitForExit(60000)) {
      throw "ADB wait-for-device timed out after 60 seconds. See $WaitError"
    }
    $DeviceWaiter.WaitForExit()
    if ($DeviceWaiter.ExitCode -ne 0) {
      throw "ADB wait-for-device failed with exit code $($DeviceWaiter.ExitCode). See $WaitError"
    }
  } finally {
    # Only this observer is owned by the helper. Do not stop the ADB server,
    # emulator, application or any other wait-for-device process.
    if (-not $DeviceWaiter.HasExited) {
      try {
        $DeviceWaiter.Kill()
        if (-not $DeviceWaiter.WaitForExit(5000)) {
          Write-Warning 'The terminated ADB observer did not report its exit within five seconds.'
        }
      } catch {
        Write-Warning "Could not finish this run's ADB observer: $($_.Exception.Message)"
      }
    }
    $DeviceWaiter.Dispose()
  }
}

if ($PSBoundParameters.ContainsKey('ProgrammeCount') -and
    $PSBoundParameters.ContainsKey('ProgrammesPerChannel')) {
  throw 'Use either ProgrammeCount or ProgrammesPerChannel, not both.'
}
$Defines = [ordered]@{ DISTRIBUTION_CHANNEL = 'development' }
if ($PSBoundParameters.ContainsKey('ChannelCount')) { $Defines['LOW_END_TV_CHANNEL_COUNT'] = $ChannelCount }
if ($PSBoundParameters.ContainsKey('ProgrammesPerChannel')) { $Defines['LOW_END_TV_PROGRAMMES_PER_CHANNEL'] = $ProgrammesPerChannel }
if ($PSBoundParameters.ContainsKey('ProgrammeCount')) {
  $EffectiveChannels = 50000
  if ($PSBoundParameters.ContainsKey('ChannelCount')) { $EffectiveChannels = $ChannelCount }
  if ($ProgrammeCount % $EffectiveChannels -ne 0 -or $ProgrammeCount / $EffectiveChannels -lt 2) {
    throw 'ProgrammeCount must be an exact multiple of ChannelCount (default 50000), with at least two programmes per channel.'
  }
  $Defines['LOW_END_TV_PROGRAMMES_PER_CHANNEL'] = [int] ($ProgrammeCount / $EffectiveChannels)
}
if ($PSBoundParameters.ContainsKey('Episodes')) { $Defines['LOW_END_TV_EPISODES'] = $Episodes }
if ($PSBoundParameters.ContainsKey('KeyEvents')) { $Defines['LOW_END_TV_KEY_EVENTS'] = $KeyEvents }

$FlutterExecutable = Resolve-Tool $FlutterPath 'flutter' @(
  (Join-Path $WorkspaceRoot 'evaluation\tooling\flutter\bin\flutter.bat')
)
$AdbCandidates = @()
foreach ($SdkRoot in @($env:ANDROID_SDK_ROOT, $env:ANDROID_HOME)) {
  if ($SdkRoot) { $AdbCandidates += Join-Path $SdkRoot 'platform-tools\adb.exe' }
}
if ($env:LOCALAPPDATA) {
  $AdbCandidates += Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
}
$script:AdbExecutable = Resolve-Tool $AdbPath 'adb' $AdbCandidates
foreach ($RequiredFile in @($TestFile, $DriverFile)) {
  if (-not (Test-Path -LiteralPath (Join-Path $AppRoot $RequiredFile) -PathType Leaf)) {
    throw "Benchmark file was not found: $RequiredFile"
  }
}
$DeviceState = Invoke-Adb -Arguments @('get-state') -Required
if ($DeviceState.Trim() -ne 'device') { throw "Device $DeviceId is not online: $DeviceState" }
$BootState = Invoke-Adb -Arguments @('shell', 'getprop', 'sys.boot_completed') -Required
if ($BootState.Trim() -ne '1') { throw 'Android is not booted. Wait for the boot event described in this script before running it.' }
$Characteristics = Invoke-Adb -Arguments @('shell', 'getprop', 'ro.build.characteristics') -Required
$Features = Invoke-Adb -Arguments @('shell', 'pm', 'list', 'features') -Required
if ($Characteristics -notmatch '(?i)\btv\b' -and $Features -notmatch 'android\.software\.leanback') {
  throw 'The selected device does not report Android TV/Leanback. Choose a TV device.'
}

if (-not $ArtifactDirectory) {
  $RunId = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmssZ') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
  $ArtifactDirectory = Join-Path $WorkspaceRoot "validation\low-end-tv-$RunId"
}
if (-not [IO.Path]::IsPathRooted($ArtifactDirectory)) {
  $ArtifactDirectory = Join-Path (Get-Location).ProviderPath $ArtifactDirectory
}
$ArtifactDirectory = [IO.Path]::GetFullPath($ArtifactDirectory)
if ((Test-Path -LiteralPath $ArtifactDirectory) -and
    @(Get-ChildItem -LiteralPath $ArtifactDirectory -Force).Count -gt 0) {
  throw 'ArtifactDirectory must be new or empty, so an earlier run is never overwritten.'
}
New-Item -ItemType Directory -Path $ArtifactDirectory -Force | Out-Null
$Features | Set-Content -LiteralPath (Join-Path $ArtifactDirectory 'device-features.txt') -Encoding UTF8

$Properties = [ordered]@{}
foreach ($Property in @('ro.build.characteristics', 'ro.product.model', 'ro.product.cpu.abi',
    'ro.build.version.sdk', 'ro.hardware', 'ro.kernel.qemu', 'dalvik.vm.heapsize',
    'dalvik.vm.heapgrowthlimit', 'debug.hwui.renderer')) {
  $Properties[$Property] = (Invoke-Adb -Arguments @('shell', 'getprop', $Property)).Trim()
}
$Properties | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $ArtifactDirectory 'device-properties.json') -Encoding UTF8
$Memory = Invoke-Adb -Arguments @('shell', 'cat', '/proc/meminfo') -Required
$CpuOnline = Invoke-Adb -Arguments @('shell', 'cat', '/sys/devices/system/cpu/online') -Required
$CpuCount = 0
foreach ($Part in $CpuOnline.Trim().Split(',')) {
  if ($Part -match '^([0-9]+)-([0-9]+)$') { $CpuCount += [int] $Matches[2] - [int] $Matches[1] + 1 }
  elseif ($Part -match '^[0-9]+$') { $CpuCount++ }
  else { throw "Unexpected CPU topology: $CpuOnline" }
}
$MemoryMatch = [regex]::Match($Memory, '(?m)^MemTotal:\s+([0-9]+)\s+kB')
if (-not $MemoryMatch.Success) { throw 'Could not read device memory.' }
$RamMiB = [Math]::Round([double] $MemoryMatch.Groups[1].Value / 1024, 1)
if ($RamMiB -gt 1536 -or $CpuCount -gt 2) {
  Write-Warning "Device reports $RamMiB MiB and $CpuCount online cores; it exceeds the 1 GiB / 2-core reference profile."
}
Invoke-Adb -Arguments @('shell', 'wm', 'size') |
  Set-Content -LiteralPath (Join-Path $ArtifactDirectory 'display-size.txt') -Encoding UTF8
Invoke-Adb -Arguments @('shell', 'wm', 'density') |
  Set-Content -LiteralPath (Join-Path $ArtifactDirectory 'display-density.txt') -Encoding UTF8

$FlutterArguments = @('drive', '--target', $TestFile, '--driver', $DriverFile, '-d', $DeviceId,
  '--profile', '--flavor', 'development', '--no-pub', '--no-dds', '--keep-app-running', '--timeout', $TimeoutSeconds.ToString())
foreach ($Define in $Defines.GetEnumerator()) { $FlutterArguments += "--dart-define=$($Define.Key)=$($Define.Value)" }
$Run = [ordered]@{
  startedUtc = [DateTime]::UtcNow.ToString('o'); deviceId = $DeviceId
  mode = 'profile'; flavor = 'development'; packageName = $PackageName
  onlineCores = $CpuCount; memoryMiB = $RamMiB; dartDefines = $Defines
  flutterVersion = $null; gitHead = $null; workingTreeDirty = $null
  defaults = @{ channels = 50000; programmesPerChannel = 4; episodes = 0; keyEvents = 240 }
  flutterPath = $FlutterExecutable; adbPath = $script:AdbExecutable
  arguments = $FlutterArguments; exitCode = $null; finishedUtc = $null
  driverResultAvailable = $false
  initialExitCode = $null; attachFallbackAttempted = $false
  attachFallbackExitCode = $null; attachFallbackError = $null
  attachForwardRemoved = $null
}
# Read the SDK's cached version instead of starting a second Flutter command.
$VersionFile = Join-Path (Split-Path -Parent $FlutterExecutable) 'cache\flutter.version.json'
if (Test-Path -LiteralPath $VersionFile -PathType Leaf) {
  $Run.flutterVersion = Get-Content -LiteralPath $VersionFile -Raw | ConvertFrom-Json
}
$Git = Get-Command 'git' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($null -ne $Git) {
  $PreviousPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $Head = @(& $Git.Source -C $AppRoot rev-parse HEAD 2>&1)
    if ($LASTEXITCODE -eq 0) { $Run.gitHead = ($Head -join '').Trim() }
    $Status = @(& $Git.Source -C $AppRoot status --porcelain --untracked-files=normal 2>&1)
    if ($LASTEXITCODE -eq 0) { $Run.workingTreeDirty = $Status.Count -gt 0 }
  } finally {
    $ErrorActionPreference = $PreviousPreference
  }
}
$RunFile = Join-Path $ArtifactDirectory 'run.json'
$Run | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $RunFile -Encoding UTF8
Save-Snapshot 'before'
$LogFile = Join-Path $ArtifactDirectory 'flutter-drive.log'
$EffectiveLogFile = $LogFile
$ResultsFile = Join-Path $ArtifactDirectory 'low_end_tv_results.json'
$OwnedForward = $null
$ExitCode = 1
$PreviousResultsDirectory = [Environment]::GetEnvironmentVariable('LOW_END_TV_RESULTS_DIR', 'Process')
Push-Location -LiteralPath $AppRoot
try {
  $env:LOW_END_TV_RESULTS_DIR = $ArtifactDirectory
  $ExitCode = Invoke-FlutterDrive -Arguments $FlutterArguments -DestinationLog $LogFile
  $Run.initialExitCode = $ExitCode
  $InitialLog = Get-Content -LiteralPath $LogFile -Raw
  $ServiceConnectionFailed = $InitialLog -match '(?i)Service has disappeared|Service connection disposed'
  $ApplicationTestFailed = $InitialLog -match 'EXCEPTION CAUGHT BY FLUTTER TEST FRAMEWORK'
  if ($ExitCode -ne 0 -and -not (Test-Path -LiteralPath $ResultsFile -PathType Leaf) -and
      $ServiceConnectionFailed -and -not $ApplicationTestFailed) {
    $Run.attachFallbackAttempted = $true
    $FallbackLog = Join-Path $ArtifactDirectory 'flutter-drive-attach.log'
    try {
      Wait-ForAdbDevice
      $ProcessIds = (Invoke-Adb -Arguments @('shell', 'pidof', $PackageName) -Required).Trim()
      $AppProcessId = ($ProcessIds -split '\s+')[0]
      if ($AppProcessId -notmatch '^[0-9]+$') { throw 'No valid running application PID was found.' }
      $DeviceLog = Invoke-Adb -Arguments @('logcat', "--pid=$AppProcessId", '-d', '-s', 'flutter:I') -Required
      $DeviceLog | Set-Content -LiteralPath (Join-Path $ArtifactDirectory 'attach-device-log.txt') -Encoding UTF8
      $ServiceMatches = [regex]::Matches($DeviceLog,
        'The Dart VM service is listening on http://127\.0\.0\.1:([0-9]+)/([A-Za-z0-9_=-]+)/')
      if ($ServiceMatches.Count -eq 0) { throw 'The running process did not report a Dart VM service URI.' }
      $Service = $ServiceMatches[$ServiceMatches.Count - 1]
      $GuestPort = [int] $Service.Groups[1].Value
      if ($GuestPort -lt 1 -or $GuestPort -gt 65535) { throw 'Invalid guest VM service port.' }
      $ForwardOutput = Invoke-Adb -Arguments @('forward', 'tcp:0', "tcp:$GuestPort") -Required
      $PortMatches = [regex]::Matches($ForwardOutput, '(?m)^([0-9]+)\r?$')
      if ($PortMatches.Count -eq 0) { throw 'ADB did not return its allocated host port.' }
      $ForwardPort = [int] $PortMatches[$PortMatches.Count - 1].Groups[1].Value
      $OwnedForward = "tcp:$ForwardPort"
      $ExistingApp = "http://127.0.0.1:$ForwardPort/$($Service.Groups[2].Value)/"
      $AttachArguments = @('drive', '--use-existing-app', $ExistingApp, '--driver', $DriverFile,
        '--profile', '--flavor', 'development', '--no-pub', '--no-dds', '--keep-app-running',
        '-d', $DeviceId, '--timeout', $TimeoutSeconds.ToString())
      $EffectiveLogFile = $FallbackLog
      $ExitCode = Invoke-FlutterDrive -Arguments $AttachArguments -DestinationLog $FallbackLog
      $Run.attachFallbackExitCode = $ExitCode
    } catch {
      $Run.attachFallbackError = $_.Exception.Message
      $_.ToString() | Add-Content -LiteralPath $FallbackLog -Encoding UTF8
      Write-Warning "The single VM-service attach fallback failed. See $FallbackLog"
    }
  }
} finally {
  $ErrorActionPreference = 'Stop'
  if ($null -ne $OwnedForward) {
    # The synchronous driver invocation has terminated. Never remove forwards
    # belonging to Flutter, another device or a previous benchmark run.
    $Removal = Invoke-Adb -Arguments @('forward', '--remove', $OwnedForward)
    $Run.attachForwardRemoved = $Removal -notmatch '^\[ADB exit '
    if (-not $Run.attachForwardRemoved) { Write-Warning "Could not remove this run's ADB forward: $Removal" }
  }
  Pop-Location
  [Environment]::SetEnvironmentVariable('LOW_END_TV_RESULTS_DIR', $PreviousResultsDirectory, 'Process')
  Save-Snapshot 'after'
  $Run.exitCode = $ExitCode
  $Run.finishedUtc = [DateTime]::UtcNow.ToString('o')
  $Run.driverResultAvailable = Test-Path -LiteralPath (Join-Path $ArtifactDirectory 'low_end_tv_results.json') -PathType Leaf
  $Run | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $RunFile -Encoding UTF8
}
Write-Host "Artifacts: $ArtifactDirectory"
if ($ExitCode -ne 0) { throw "Flutter benchmark failed with exit code $ExitCode. See $EffectiveLogFile" }
if (-not (Test-Path -LiteralPath (Join-Path $ArtifactDirectory 'low_end_tv_results.json') -PathType Leaf)) {
  throw "Flutter exited successfully but the driver result is missing. See $EffectiveLogFile"
}
