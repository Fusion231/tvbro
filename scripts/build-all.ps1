#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidatePattern('^[1-9][0-9]*\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$')]
    [string]$Version,
    [ValidateRange(1, 2100000000)][int]$BuildNumber,
    [string]$OutputDirectory,
    [string]$ConfigFile,
    [string]$DartDefineFile,
    [string]$AndroidSigningConfig,
    [string]$PlaySigningConfig,
    [string]$UpdateSigningConfig,
    [ValidatePattern('^[A-Za-z0-9-]+/[A-Za-z0-9_.-]+$')]
    [string]$UpdateRepository = 'Fusion231/tvbro',
    [string]$FlutterRoot = $env:FLUTTER_ROOT,
    [string]$PubCache = $env:PUB_CACHE,
    [string]$GradleUserHome = $env:GRADLE_USER_HOME,
    [string]$JavaHome = $env:JAVA_HOME,
    [string]$AndroidSdk = $env:ANDROID_HOME,
    [switch]$Offline,
    [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$workspaceRoot = Split-Path -Parent $projectRoot
$toolingRoot = Join-Path $workspaceRoot 'evaluation/tooling'
$pubspecPath = Join-Path $projectRoot 'pubspec.yaml'
$environmentNames = @(
    'PATH', 'FLUTTER_ROOT', 'PUB_CACHE', 'GRADLE_USER_HOME', 'JAVA_HOME',
    'ANDROID_HOME', 'ANDROID_SDK_ROOT', 'DASH__SUPPRESS_ANALYTICS',
    'IPTVS_ANDROID_KEYSTORE_PATH', 'IPTVS_ANDROID_KEYSTORE_PASSWORD',
    'IPTVS_ANDROID_KEY_ALIAS', 'IPTVS_ANDROID_KEY_PASSWORD', 'TVBRO_UPDATE_KEY_PASSWORD'
)
$previousEnvironment = @{}
foreach ($name in $environmentNames) {
    $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
$runDirectory = $null
$releaseLock = $null
$versionReserved = $false
$summary = $null
$utf8 = [Text.UTF8Encoding]::new($false)

function Resolve-ProjectPath([string]$Path) {
    if (-not [IO.Path]::IsPathRooted($Path)) { $Path = Join-Path $projectRoot $Path }
    return [IO.Path]::GetFullPath($Path)
}

function Assert-File([string]$Path, [string]$Description) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Description is missing: $Path" }
}

function Read-SigningConfig([string]$Path, [string]$Description, [switch]$Update) {
    Assert-File $Path $Description
    try {
        $signing = Import-Clixml -LiteralPath $Path
        if ($signing.Credential -isnot [Management.Automation.PSCredential] -or
            [string]::IsNullOrWhiteSpace($signing.Credential.GetNetworkCredential().Password)) {
            throw 'Invalid credential.'
        }
    } catch {
        throw "$Description cannot be read. Use the Windows user and computer that created this protected configuration."
    }
    if ($Update) {
        try { $validPublicKey = [Convert]::FromBase64String($signing.PublicKey).Length -eq 32 } catch { $validPublicKey = $false }
        if (-not $validPublicKey) { throw 'The update signing configuration has an invalid public key.' }
        Assert-File $signing.PrivateKeyPath 'Encrypted update signing key'
    } else {
        $keystorePath = $signing.KeystorePath
        if ([string]::IsNullOrWhiteSpace($keystorePath)) { throw "$Description has no keystore path." }
        if (-not [IO.Path]::IsPathRooted($keystorePath)) { $keystorePath = Join-Path $projectRoot "android/app/$keystorePath" }
        Assert-File $keystorePath "$Description keystore"
    }
    return $signing
}

function Get-SourceFiles {
    $listed = (& git -C $projectRoot ls-files --cached --others --exclude-standard -z) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw 'Cannot list the current application source with git.' }
    $files = @($listed.Split([char]0, [StringSplitOptions]::RemoveEmptyEntries) | Sort-Object -Unique)
    foreach ($relative in $files) {
        $path = [IO.Path]::GetFullPath((Join-Path $projectRoot $relative))
        if (-not $path.StartsWith($projectRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Git returned a source path outside the application.'
        }
        # These local settings are never part of the corresponding-source archive.
        if ($path -in $privateSourcePaths -or
            $relative -in @('scripts/release-config.json', 'dart_define.json')) { continue }
        # Published source archives must not be nested into later source archives.
        if ($relative -like 'panel/public/downloads/*-source.zip') { continue }
        if (Test-Path -LiteralPath $path -PathType Leaf) { $relative }
    }
}

function Get-SourceHashes {
    $hashes = @{}
    foreach ($relative in @(Get-SourceFiles)) {
        # Flutter regenerates these from the frozen dependency graph during builds.
        if ($relative -match '^(windows|linux)/flutter/generated_(plugin_registrant\.(cc|h)|plugins\.cmake)$' -or
            $relative -eq 'macos/Flutter/GeneratedPluginRegistrant.swift') { continue }
        $hashes[$relative] = (Get-FileHash -LiteralPath (Join-Path $projectRoot $relative) -Algorithm SHA256).Hash
    }
    return $hashes
}

function Assert-SourceUnchanged {
    $current = Get-SourceHashes
    if ($current.Count -ne $sourceHashes.Count) { throw 'Application source changed during the release build. Keep the source unchanged and start a new run.' }
    foreach ($relative in $sourceHashes.Keys) {
        if ($current[$relative] -cne $sourceHashes[$relative]) {
            throw "Application source changed during the release build: $relative. Start a new run."
        }
    }
    if ((Get-FileHash -LiteralPath $DartDefineFile -Algorithm SHA256).Hash -cne $defineHash) {
        throw 'Dart define settings changed during the release build. Start a new run.'
    }
}

function Invoke-LoggedStep([string]$Name, [scriptblock]$Action) {
    Write-Host "[$Name]"
    # Transcription preserves native stderr semantics in Windows PowerShell 5.1.
    Start-Transcript -LiteralPath (Join-Path $runDirectory "logs/$Name.log") | Out-Null
    try {
        $global:LASTEXITCODE = 0
        & $Action
        if ($LASTEXITCODE -ne 0) { throw "$Name failed with exit code $LASTEXITCODE." }
    } finally {
        Stop-Transcript | Out-Null
    }
}

function Invoke-Channel([string]$Name, [string]$Channel, [string]$Target, [string]$SigningPath) {
    Assert-SourceUnchanged
    $staging = Join-Path $runDirectory ".build-$Name"
    $arguments = @{
        DistributionChannel = $Channel; Target = $Target; OutputDirectory = $staging
        Version = $Version; BuildNumber = $BuildNumber; DartDefineFile = $DartDefineFile
        UpdateSigningConfig = $UpdateSigningConfig; UpdateRepository = $UpdateRepository
    }
    foreach ($entry in $toolchain.GetEnumerator()) { $arguments[$entry.Key] = $entry.Value }
    if ($SigningPath) { $arguments['SigningConfig'] = $SigningPath }
    Invoke-LoggedStep $Name { & (Join-Path $PSScriptRoot 'build-release.ps1') @arguments }
    Assert-SourceUnchanged
    $built = @(Get-ChildItem -LiteralPath $staging -Directory)
    if ($built.Count -ne 1) { throw "$Name did not produce exactly one new release directory." }
    $destination = Join-Path $runDirectory $Name
    # Both move targets are generated children of this unique run directory.
    foreach ($path in @($built[0].FullName, $destination)) {
        if (-not [IO.Path]::GetFullPath($path).StartsWith($runDirectory.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Refusing to move release files outside this run directory.'
        }
    }
    Move-Item -LiteralPath $built[0].FullName -Destination $destination
    Remove-Item -LiteralPath $staging
}

function Write-Summary {
    [IO.File]::WriteAllText((Join-Path $runDirectory 'release-summary.json'), ($summary | ConvertTo-Json -Depth 6), $utf8)
    $lines = @(
        "TVBro $Version+$BuildNumber", "Status: $($summary.status)",
        "Microsoft Store MSIX: $($summary.microsoft_store_msix)",
        "Source commit: $($summary.source_commit)",
        'GitHub direct: github-direct (signed APK, Windows ZIP, update manifest and signature)',
        'Google Play: google-play (signed AAB)',
        'Microsoft Store: microsoft-store (Windows payload; MSIX when identity is configured)',
        "Corresponding source: tvbro-$Version-source.zip", 'Checksums: SHA256SUMS.txt',
        'Keep each channel''s symbols and the logs for diagnostics.',
        'This command builds locally; it does not publish or submit anything.'
    )
    if ($summary.microsoft_store_msix -eq 'pending-identity') {
        $lines += 'MSIX pending: copy scripts/release-config.example.json to scripts/release-config.json and fill all four Partner Center identity values.'
    }
    if ($summary.error) { $lines += "Failure: $($summary.error)" }
    [IO.File]::WriteAllLines((Join-Path $runDirectory 'release-summary.txt'), $lines, $utf8)
}

try {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Build all release channels on Windows.' }
    foreach ($relative in @('scripts/build-tvbro.ps1', 'scripts/build-release.ps1', 'scripts/sign-release.ps1', 'scripts/verify_release.dart', 'scripts/package_windows_msix.ps1')) {
        Assert-File (Join-Path $projectRoot $relative) 'Release tool'
    }
    $pubspecBytes = [IO.File]::ReadAllBytes($pubspecPath)
    $pubspecText = $utf8.GetString($pubspecBytes)
    $versionMatch = [regex]::Match($pubspecText, '(?m)^(version:[ \t]*)(\d+\.\d+\.\d+)\+(\d+)([ \t]*(?:#[^\r\n]*)?)(?=\r?$)')
    if (-not $versionMatch.Success) { throw 'pubspec.yaml must declare one numeric version and Android build number.' }
    $previousVersion = [version]$versionMatch.Groups[2].Value
    $previousBuild = [long]$versionMatch.Groups[3].Value
    if (-not $Version) { $Version = "$($previousVersion.Major).$($previousVersion.Minor).$($previousVersion.Build + 1)" }
    if (-not $PSBoundParameters.ContainsKey('BuildNumber')) {
        if ($previousBuild -ge 2100000000) { throw 'The Android build number has reached its supported maximum.' }
        $BuildNumber = [int]($previousBuild + 1)
    }
    if ([version]$Version -le $previousVersion -or $BuildNumber -le $previousBuild) {
        throw "Version and BuildNumber must both increase beyond $previousVersion+$previousBuild."
    }
    if ($Version.Split('.').Count -ne 3 -or [version]$Version -lt [version]'1.0.0' -or
        @($Version.Split('.') | Where-Object { [long]$_ -gt 65535 }).Count -gt 0) {
        throw 'Every Microsoft Store version component must be between 0 and 65535, with a non-zero major component.'
    }

    if (-not $OutputDirectory) { $OutputDirectory = Join-Path $workspaceRoot 'output/distribution' }
    $OutputDirectory = Resolve-ProjectPath $OutputDirectory
    if ($OutputDirectory -eq $projectRoot -or $OutputDirectory.StartsWith($projectRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Choose an output directory outside the application source tree.'
    }
    if (Test-Path -LiteralPath $OutputDirectory -PathType Leaf) { throw 'OutputDirectory must be a directory.' }
    $explicitConfig = $PSBoundParameters.ContainsKey('ConfigFile')
    if (-not $ConfigFile) { $ConfigFile = Join-Path $PSScriptRoot 'release-config.json' }
    $ConfigFile = Resolve-ProjectPath $ConfigFile
    $store = @{}
    if (Test-Path -LiteralPath $ConfigFile -PathType Leaf) {
        try { $configuration = Get-Content -LiteralPath $ConfigFile -Raw | ConvertFrom-Json } catch { throw 'Release config must contain a JSON object.' }
        if ($configuration -isnot [pscustomobject] -or $configuration.MicrosoftStore -isnot [pscustomobject]) {
            throw 'Release config must contain a MicrosoftStore object. See scripts/release-config.example.json.'
        }
        foreach ($name in @('IdentityName', 'Publisher', 'PublisherDisplayName', 'DisplayName')) {
            $value = $configuration.MicrosoftStore.$name
            if ($null -ne $value -and $value -isnot [string]) { throw "MicrosoftStore.$name must be a string." }
            if (-not [string]::IsNullOrWhiteSpace($value)) { $store[$name] = $value.Trim() }
        }
    } elseif ($explicitConfig) { throw 'The requested release config file does not exist.' }
    if ($store.Count -notin @(0, 4)) { throw 'Fill all four MicrosoftStore identity values, or leave all four empty for a payload-only build.' }
    if ($store.Count -eq 4 -and $store.IdentityName -notmatch '^[A-Za-z0-9.-]{3,50}$') { throw 'MicrosoftStore.IdentityName is not a valid package identity name.' }

    $privateDefinePath = Join-Path $projectRoot 'dart_define.json'
    $defineDescription = 'explicit settings'
    if (-not $DartDefineFile) {
        if (Test-Path -LiteralPath $privateDefinePath -PathType Leaf) {
            $DartDefineFile = $privateDefinePath
            $defineDescription = 'private local settings'
        } else {
            $DartDefineFile = Join-Path $projectRoot 'dart_define.example.json'
            $defineDescription = 'public example service URLs; no private dart_define.json was found'
        }
    }
    $DartDefineFile = Resolve-ProjectPath $DartDefineFile
    Assert-File $DartDefineFile 'Dart define file'
    try { $defines = Get-Content -LiteralPath $DartDefineFile -Raw | ConvertFrom-Json } catch { throw 'The Dart define file must contain a JSON object.' }
    if ($defines -isnot [pscustomobject]) { throw 'The Dart define file must contain a JSON object.' }
    Remove-Variable defines

    if (-not $FlutterRoot) { $FlutterRoot = Join-Path $toolingRoot 'flutter' }
    $FlutterRoot = Resolve-ProjectPath $FlutterRoot
    Assert-File (Join-Path $FlutterRoot 'bin/flutter.bat') 'Flutter SDK'
    Assert-File (Join-Path $FlutterRoot 'bin/dart.bat') 'Dart SDK launcher'
    if (-not $PubCache) {
        $PubCache = if (Test-Path -LiteralPath (Join-Path $toolingRoot 'pub-cache') -PathType Container) { Join-Path $toolingRoot 'pub-cache' } else { Join-Path $env:LOCALAPPDATA 'Pub/Cache' }
    }
    if (-not $GradleUserHome -and (Test-Path -LiteralPath (Join-Path $toolingRoot 'gradle-cache') -PathType Container)) {
        $GradleUserHome = Join-Path $toolingRoot 'gradle-cache'
    }
    if (-not $AndroidSdk) {
        $AndroidSdk = if ($env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT } else { Join-Path $env:LOCALAPPDATA 'Android/Sdk' }
    }
    $AndroidSdk = Resolve-ProjectPath $AndroidSdk
    if (-not (Test-Path (Join-Path $AndroidSdk 'platforms/android-37*/android.jar'))) { throw 'Android SDK Platform 37 is required. Pass -AndroidSdk with the installed SDK path.' }
    Assert-File (Join-Path $AndroidSdk 'platform-tools/adb.exe') 'Android platform tools'
    if (-not @(Get-ChildItem -Path (Join-Path $AndroidSdk 'build-tools/*/apksigner.bat') -ErrorAction SilentlyContinue).Count) {
        throw 'Android SDK Build-Tools are missing.'
    }
    if (-not @(Get-ChildItem -Path (Join-Path $AndroidSdk 'cmdline-tools/*/bin/apkanalyzer.bat') -ErrorAction SilentlyContinue).Count) {
        throw 'Android SDK Command-line Tools are required to build the Google Play AAB.'
    }
    $javaCandidates = if ($PSBoundParameters.ContainsKey('JavaHome')) { @($JavaHome) } else {
        @($JavaHome) + @(Get-ChildItem "$env:ProgramFiles/Microsoft/jdk-*" -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -ExpandProperty FullName)
    }
    $JavaHome = $null
    foreach ($candidate in $javaCandidates) {
        if (-not $candidate -or -not (Test-Path -LiteralPath (Join-Path $candidate 'bin/java.exe') -PathType Leaf)) { continue }
        $javaVersion = (& (Join-Path $candidate 'bin/java.exe') --version) -join "`n"
        if ($LASTEXITCODE -eq 0 -and $javaVersion -match '^(?:openjdk|java)\s+(\d+)' -and [int]$Matches[1] -ge 21) {
            $JavaHome = Resolve-ProjectPath $candidate
            break
        }
    }
    if (-not $JavaHome) { throw 'Release lint requires JDK 21 or newer. Pass -JavaHome with a compatible JDK path.' }
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
    Assert-File $vswhere 'Visual Studio discovery tool'
    $visualStudio = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($LASTEXITCODE -ne 0 -or -not $visualStudio) { throw 'Install the Visual Studio Desktop development with C++ toolchain.' }
    if ($store.Count -eq 4) {
        $makeAppx = Get-Command makeappx.exe -ErrorAction SilentlyContinue
        if (-not $makeAppx -and -not @(Get-ChildItem -Path (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits/10/bin/*/x64/makeappx.exe') -ErrorAction SilentlyContinue).Count) {
            throw 'Microsoft Store packaging requires makeappx.exe from the Windows SDK.'
        }
    }
    $git = Get-Command git -ErrorAction Stop
    $gitRoot = (& git -C $projectRoot rev-parse --show-toplevel) -join ''
    if ($LASTEXITCODE -ne 0 -or [IO.Path]::GetFullPath($gitRoot) -ne $projectRoot) { throw 'Run this wrapper from an application Git checkout.' }
    $openssl = Get-Command openssl -ErrorAction SilentlyContinue
    if (-not $openssl) {
        foreach ($candidate in @((Join-Path (Split-Path -Parent $git.Source) '../mingw64/bin'), (Join-Path $env:ProgramFiles 'Git/mingw64/bin'))) {
            if (Test-Path -LiteralPath (Join-Path $candidate 'openssl.exe') -PathType Leaf) {
                $env:PATH = "$([IO.Path]::GetFullPath($candidate));$env:PATH"
                $openssl = Get-Command openssl -ErrorAction Stop
                break
            }
        }
    }
    if (-not $openssl) { throw 'OpenSSL is required for update manifest signing. Install Git for Windows with its bundled OpenSSL.' }

    if (-not $AndroidSigningConfig) { $AndroidSigningConfig = Join-Path $workspaceRoot '.signing/android-release.clixml' }
    if (-not $PlaySigningConfig) { $PlaySigningConfig = Join-Path $workspaceRoot '.signing/play-upload.clixml' }
    if (-not $UpdateSigningConfig) { $UpdateSigningConfig = Join-Path $workspaceRoot '.signing/update-signing.clixml' }
    $AndroidSigningConfig = Resolve-ProjectPath $AndroidSigningConfig
    $PlaySigningConfig = Resolve-ProjectPath $PlaySigningConfig
    $UpdateSigningConfig = Resolve-ProjectPath $UpdateSigningConfig
    $directSigning = Read-SigningConfig $AndroidSigningConfig 'Direct Android signing configuration'
    $playSigning = Read-SigningConfig $PlaySigningConfig 'Google Play upload signing configuration'
    $updateSigning = Read-SigningConfig $UpdateSigningConfig 'Update signing configuration' -Update
    $privateSourcePaths = @($ConfigFile, $privateDefinePath, $AndroidSigningConfig, $PlaySigningConfig, $UpdateSigningConfig, (Resolve-ProjectPath $updateSigning.PrivateKeyPath))
    if ($DartDefineFile -ne (Join-Path $projectRoot 'dart_define.example.json')) { $privateSourcePaths += $DartDefineFile }
    foreach ($signing in @($directSigning, $playSigning)) {
        $keyPath = $signing.KeystorePath
        if (-not [IO.Path]::IsPathRooted($keyPath)) { $keyPath = Join-Path $projectRoot "android/app/$keyPath" }
        $privateSourcePaths += [IO.Path]::GetFullPath($keyPath)
    }
    $updatePublicKey = $updateSigning.PublicKey
    $env:TVBRO_UPDATE_KEY_PASSWORD = $updateSigning.Credential.GetNetworkCredential().Password
    try {
        $publicPem = (& $openssl.Source pkey -in $updateSigning.PrivateKeyPath -passin env:TVBRO_UPDATE_KEY_PASSWORD -pubout 2>$null) -join "`n"
        if ($LASTEXITCODE -ne 0) { throw 'Cannot read update key.' }
        $publicDer = [Convert]::FromBase64String(($publicPem -replace '-----[A-Z ]+-----', '' -replace '\s', ''))
        if ($publicDer.Length -lt 32 -or [Convert]::ToBase64String($publicDer[($publicDer.Length - 32)..($publicDer.Length - 1)]) -cne $updatePublicKey) { throw 'Update key mismatch.' }
    } catch { throw 'The encrypted update private key could not be verified against its configured public key.' }
    [Environment]::SetEnvironmentVariable('TVBRO_UPDATE_KEY_PASSWORD', $previousEnvironment['TVBRO_UPDATE_KEY_PASSWORD'], 'Process')
    Remove-Variable directSigning, playSigning, updateSigning, signing, publicPem, publicDer
    $toolchain = @{ FlutterRoot = $FlutterRoot; PubCache = (Resolve-ProjectPath $PubCache); JavaHome = $JavaHome; AndroidSdk = $AndroidSdk; Offline = $Offline }
    if ($GradleUserHome) { $toolchain['GradleUserHome'] = Resolve-ProjectPath $GradleUserHome }

    $buildDrives = @($projectRoot, $OutputDirectory, $toolchain.PubCache, $toolchain.GradleUserHome, [IO.Path]::GetTempPath()) |
        Where-Object { $_ } | ForEach-Object { [IO.Path]::GetPathRoot($_) } | Sort-Object -Unique
    foreach ($driveRoot in $buildDrives) {
        $drive = [IO.DriveInfo]::new($driveRoot)
        if ($drive.IsReady -and $drive.AvailableFreeSpace -lt 4GB) {
            throw "Insufficient free space on $driveRoot. At least 4 GB is required before starting; allow 10 GB for a clean build."
        }
    }

    Write-Host "Preflight passed: next release $Version+$BuildNumber"
    Write-Host "Dart defines: $DartDefineFile ($defineDescription)"
    Write-Host "Output root: $OutputDirectory"
    if ($store.Count -eq 0) { Write-Host 'Microsoft Store MSIX: pending Partner Center identity; the Store Windows payload will still be built.' }
    if ($CheckOnly) { Write-Host 'CheckOnly: no build started and pubspec.yaml was not changed.'; return }

    $lockDirectory = Join-Path $projectRoot 'build'
    New-Item -ItemType Directory -Path $lockDirectory -Force | Out-Null
    try {
        $releaseLock = [IO.File]::Open((Join-Path $lockDirectory 'build-all.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    } catch { throw 'Another build-all release is running. Wait for it to finish before starting a new run.' }
    $runDirectory = Join-Path $OutputDirectory "tvbro-$Version+$BuildNumber-$(Get-Date -Format 'yyyyMMdd-HHmmss-fff')-$([guid]::NewGuid().ToString('N').Substring(0, 6))"
    New-Item -ItemType Directory -Path $runDirectory | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $runDirectory 'logs') | Out-Null
    $summary = [ordered]@{
        version = $Version; build_number = $BuildNumber; status = 'building'
        started_utc = [DateTime]::UtcNow.ToString('o'); completed_utc = $null
        source_commit = $null; source_has_local_changes = $null
        microsoft_store_msix = if ($store.Count -eq 4) { 'planned' } else { 'pending-identity' }
        error = $null
    }
    Write-Summary
    # Replace only the numeric version bytes; preserve BOM, newline style and comments.
    $numberStart = $versionMatch.Groups[2].Index
    $numberLength = $versionMatch.Groups[2].Length + 1 + $versionMatch.Groups[3].Length
    $newPubspec = $pubspecText.Remove($numberStart, $numberLength).Insert($numberStart, "$Version+$BuildNumber")
    if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($pubspecPath)) -cne [Convert]::ToBase64String($pubspecBytes)) {
        throw 'pubspec.yaml changed during preflight. Start the wrapper again.'
    }
    [IO.File]::WriteAllBytes($pubspecPath, $utf8.GetBytes($newPubspec))
    $versionReserved = $true
    Write-Host "Reserved pubspec.yaml version $Version+$BuildNumber. A later build failure will leave this version consumed."
    Invoke-LoggedStep 'prepare' { & (Join-Path $PSScriptRoot 'build-tvbro.ps1') -Target Prepare @toolchain }
    if ([IO.File]::ReadAllText($pubspecPath) -notmatch "(?m)^version:[ \t]*$([regex]::Escape($Version))\+$BuildNumber(?:[ \t]|\r?$)") {
        throw 'pubspec.yaml changed during preparation. Start a new run.'
    }
    $sourceHashes = Get-SourceHashes
    if ($sourceHashes.Count -eq 0) { throw 'No application source files were found.' }
    $defineHash = (Get-FileHash -LiteralPath $DartDefineFile -Algorithm SHA256).Hash
    $summary.source_commit = (& git -C $projectRoot rev-parse HEAD) -join ''
    if ($LASTEXITCODE -ne 0) { throw 'Cannot record the application commit.' }
    $summary.source_has_local_changes = [bool]((& git -C $projectRoot status --porcelain) -join '')
    if ($LASTEXITCODE -ne 0) { throw 'Cannot record the application source state.' }
    Write-Host 'Source hashes recorded, including current uncommitted files. Keep the application source and Dart defines unchanged until this run finishes.'
    Invoke-Channel 'github-direct' 'githubDirect' 'All' $AndroidSigningConfig
    Invoke-LoggedStep 'verify-direct' {
        Push-Location $projectRoot
        try {
            & (Join-Path $FlutterRoot 'bin/dart.bat') run scripts/verify_release.dart (Join-Path $runDirectory 'github-direct') $Version $updatePublicKey
            if ($LASTEXITCODE -ne 0) { throw 'The direct release manifest or artifact verification failed.' }
        } finally { Pop-Location }
    }
    Invoke-Channel 'google-play' 'googlePlay' 'Android' $PlaySigningConfig
    Invoke-Channel 'microsoft-store' 'microsoftStore' 'Windows' ''
    if ($store.Count -eq 4) {
        Invoke-LoggedStep 'msix' {
            & (Join-Path $projectRoot 'scripts/package_windows_msix.ps1') -BuildDirectory (Join-Path $runDirectory 'microsoft-store/windows-x64') -Version $Version -OutputPath (Join-Path $runDirectory "microsoft-store/tvbro-$Version-windows-x64.msix") @store
        }
        $summary.microsoft_store_msix = 'ready'
    }
    Assert-SourceUnchanged
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archivePath = Join-Path $runDirectory "tvbro-$Version-source.zip"
    $archive = [IO.Compression.ZipFile]::Open($archivePath, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($relative in @(Get-SourceFiles)) {
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, (Join-Path $projectRoot $relative), "tvbro-$Version/$($relative.Replace('\', '/'))", [IO.Compression.CompressionLevel]::Optimal) | Out-Null
        }
    } finally { $archive.Dispose() }
    Assert-SourceUnchanged
    $summary.status = if ($store.Count -eq 4) { 'complete' } else { 'complete-msix-pending' }
    $summary.completed_utc = [DateTime]::UtcNow.ToString('o')
    Write-Summary
    $checksums = @(Get-ChildItem -LiteralPath $runDirectory -File -Recurse | Sort-Object FullName | ForEach-Object {
        $relative = $_.FullName.Substring($runDirectory.Length + 1).Replace('\', '/')
        "$( (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() )  $relative"
    })
    [IO.File]::WriteAllLines((Join-Path $runDirectory 'SHA256SUMS.txt'), $checksums, $utf8)
    Write-Host "Release build complete: $runDirectory"
    if ($store.Count -eq 0) { Write-Host 'MSIX remains pending the Partner Center identity in scripts/release-config.json. See release-summary.txt.' }
} catch {
    if ($summary -and $runDirectory) {
        $summary.status = 'failed'
        $summary.completed_utc = [DateTime]::UtcNow.ToString('o')
        $summary.error = $_.Exception.Message
        try { Write-Summary } catch { Write-Warning 'Could not write the failure summary.' }
        Write-Host "Release run failed. Partial outputs and logs: $runDirectory"
    }
    if ($versionReserved) { Write-Host "Version $Version+$BuildNumber remains reserved in pubspec.yaml; the next automatic run will increment it again." }
    throw
} finally {
    if ($releaseLock) { $releaseLock.Dispose() }
    foreach ($name in $environmentNames) {
        if ($null -eq $previousEnvironment[$name]) {
            Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
        } else {
            [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], 'Process')
        }
    }
}
