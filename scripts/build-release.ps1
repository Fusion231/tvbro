[CmdletBinding()]
param(
    [ValidateSet('Android', 'Windows', 'All')]
    [string]$Target = 'All',
    [string]$OutputDirectory = 'apkRelease',
    [string]$SigningConfig,
    [string]$DartDefineFile,
    [ValidateSet('githubDirect', 'googlePlay', 'microsoftStore')]
    [string]$DistributionChannel = 'githubDirect',
    [string]$UpdateSigningConfig,
    [ValidatePattern('^[A-Za-z0-9-]+/[A-Za-z0-9_.-]+$')]
    [string]$UpdateRepository = 'Fusion231/tvbro',
    [ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version,
    [ValidateRange(0, 2100000000)][int]$BuildNumber,
    [string]$FlutterRoot,
    [string]$PubCache,
    [string]$GradleUserHome,
    [string]$JavaHome,
    [string]$AndroidSdk,
    [switch]$Offline
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$flutterProjectRoot = Join-Path $repositoryRoot 'clients/player'
$workspaceRoot = Split-Path -Parent $repositoryRoot
$signingVariables = @('IPTVS_ANDROID_KEYSTORE_PATH', 'IPTVS_ANDROID_KEYSTORE_PASSWORD', 'IPTVS_ANDROID_KEY_ALIAS', 'IPTVS_ANDROID_KEY_PASSWORD')
$previousSigning = @{}
foreach ($name in $signingVariables) { $previousSigning[$name] = [Environment]::GetEnvironmentVariable($name) }
try {
$buildAndroid = $Target -in @('Android', 'All')
$buildWindows = $Target -in @('Windows', 'All')
if ($DistributionChannel -eq 'googlePlay' -and $Target -ne 'Android') {
    throw 'Google Play requires -Target Android.'
}
if ($DistributionChannel -eq 'microsoftStore' -and $Target -ne 'Windows') {
    throw 'Microsoft Store requires -Target Windows.'
}
$pubspec = Get-Content -LiteralPath (Join-Path $flutterProjectRoot 'pubspec.yaml') -Raw
if ($pubspec -notmatch '(?m)^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$') {
    throw 'pubspec.yaml must declare a numeric version and build number.'
}
if (-not $Version) { $Version = $Matches[1] }
if (-not $BuildNumber) { $BuildNumber = [int]$Matches[2] }
if ($DistributionChannel -eq 'microsoftStore') {
    if ($Version -notmatch '^([1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') {
        throw 'Microsoft Store requires a three-part version with a non-zero major component, such as 1.0.0.'
    }
    foreach ($part in $Version.Split('.')) {
        [uint16]$storeComponent = 0
        if (-not [uint16]::TryParse($part, [ref]$storeComponent)) {
            throw 'Every Microsoft Store version component must be between 0 and 65535.'
        }
    }
    $BuildNumber = 0
}
if ($DistributionChannel -eq 'githubDirect') {
    if (-not $UpdateSigningConfig) {
        $UpdateSigningConfig = Join-Path $workspaceRoot '.signing/update-signing.clixml'
    }
    if (-not (Test-Path -LiteralPath $UpdateSigningConfig -PathType Leaf)) {
        throw 'Configure TVBro update signing with scripts/setup-update-signing.ps1 before building a direct release.'
    }
    $updateSigning = Import-Clixml -LiteralPath $UpdateSigningConfig
    if ($updateSigning.Credential -isnot [Management.Automation.PSCredential] -or
        [Convert]::FromBase64String($updateSigning.PublicKey).Length -ne 32) {
        throw 'The update signing configuration is invalid.'
    }
    $updatePublicKey = $updateSigning.PublicKey
    Remove-Variable updateSigning
}

# Use the same protected signing configuration as the Gradle release build.
if ($buildAndroid) {
    if (-not $SigningConfig) {
        $signingFilename = if ($DistributionChannel -eq 'googlePlay') { 'play-upload.clixml' } else { 'android-release.clixml' }
        $SigningConfig = Join-Path $workspaceRoot ".signing/$signingFilename"
    }
    $configuredSigning = @($signingVariables | Where-Object {
        -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($_))
    })
    if (($configuredSigning.Count -eq 0 -or $PSBoundParameters.ContainsKey('SigningConfig')) -and (Test-Path -LiteralPath $SigningConfig -PathType Leaf)) {
        # Windows DPAPI binds this credential to the Windows user and computer.
        $localSigning = Import-Clixml -LiteralPath $SigningConfig
        if ($localSigning.Credential -isnot [System.Management.Automation.PSCredential]) {
            throw 'The local signing configuration must contain an encrypted PSCredential.'
        }
        $env:IPTVS_ANDROID_KEYSTORE_PATH = $localSigning.KeystorePath
        $env:IPTVS_ANDROID_KEY_ALIAS = $localSigning.Credential.UserName
        $env:IPTVS_ANDROID_KEYSTORE_PASSWORD = $localSigning.Credential.GetNetworkCredential().Password
        $env:IPTVS_ANDROID_KEY_PASSWORD = $env:IPTVS_ANDROID_KEYSTORE_PASSWORD
        Remove-Variable localSigning
        Write-Host "Loaded local release signing: $SigningConfig"
    }
    $missingSigning = @($signingVariables | Where-Object {
        [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($_))
    })
    if ($missingSigning.Count -gt 0) {
        throw "Release signing is not configured. Set: $($missingSigning -join ', '). See docs/android-signing.md."
    }
    $keystorePath = $env:IPTVS_ANDROID_KEYSTORE_PATH
    if (-not [System.IO.Path]::IsPathRooted($keystorePath)) {
        $keystorePath = Join-Path $flutterProjectRoot "android/app/$keystorePath"
    }
    if (-not (Test-Path -LiteralPath $keystorePath -PathType Leaf)) {
        throw 'The release keystore does not exist. Check IPTVS_ANDROID_KEYSTORE_PATH.'
    }
}

if (-not [System.IO.Path]::IsPathRooted($OutputDirectory)) {
    $OutputDirectory = Join-Path $repositoryRoot $OutputDirectory
}
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
if ($DartDefineFile) {
    if (-not [System.IO.Path]::IsPathRooted($DartDefineFile)) {
        $DartDefineFile = Join-Path $repositoryRoot $DartDefineFile
    }
    $DartDefineFile = (Resolve-Path -LiteralPath $DartDefineFile).Path
}

# Reuse toolchain discovery, dependency resolution and Windows plugin junctions.
$prepareArguments = @{ Target = 'Prepare' }
foreach ($name in @('FlutterRoot', 'PubCache', 'GradleUserHome', 'JavaHome', 'AndroidSdk', 'Offline')) {
    if ($PSBoundParameters.ContainsKey($name)) {
        $prepareArguments[$name] = $PSBoundParameters[$name]
    }
}
if ($buildAndroid) {
    # JAVA_HOME may still point to a debug-compatible JDK that cannot run release lint.
    $javaCandidates = if ($PSBoundParameters.ContainsKey('JavaHome')) {
        @($JavaHome)
    } else {
        @($env:JAVA_HOME) + @(Get-ChildItem "$env:ProgramFiles/Microsoft/jdk-*" -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -ExpandProperty FullName)
    }
    $releaseJavaHome = $null
    foreach ($candidate in $javaCandidates) {
        if (-not $candidate -or -not (Test-Path -LiteralPath "$candidate/bin/java.exe" -PathType Leaf)) { continue }
        $javaVersion = (& "$candidate/bin/java.exe" --version) -join "`n"
        if ($LASTEXITCODE -eq 0 -and $javaVersion -match '^(?:openjdk|java)\s+(\d+)' -and [int]$Matches[1] -ge 21) {
            $releaseJavaHome = $candidate
            break
        }
    }
    if (-not $releaseJavaHome) {
        throw 'Release lint requires JDK 21 or newer. Install a compatible JDK or pass -JavaHome with its path.'
    }
    $prepareArguments['JavaHome'] = $releaseJavaHome
}
& "$PSScriptRoot/build-tvbro.ps1" @prepareArguments
if ($buildWindows) {
    # pub get may succeed without recreating links when its metadata is unchanged.
    # Ensure junctions exist before building without Windows symlink privileges.
    $metadata = Get-Content (Join-Path $flutterProjectRoot '.flutter-plugins-dependencies') -Raw | ConvertFrom-Json
    $allowedRoots = @($env:PUB_CACHE, $flutterProjectRoot) | ForEach-Object {
        [System.IO.Path]::GetFullPath($_).TrimEnd('\', '/') + '\'
    }
    foreach ($platform in @('windows', 'linux')) {
        $linkRoot = Join-Path $flutterProjectRoot "$platform/flutter/ephemeral/.plugin_symlinks"
        New-Item -ItemType Directory -Path $linkRoot -Force | Out-Null
        foreach ($plugin in $metadata.plugins.$platform) {
            $pluginPath = [System.IO.Path]::GetFullPath($plugin.path)
            $withinScope = $allowedRoots | Where-Object {
                $pluginPath.StartsWith($_, [System.StringComparison]::OrdinalIgnoreCase)
            }
            if (-not $withinScope) { throw "Plugin is outside the project/cache: $pluginPath" }
            $linkPath = Join-Path $linkRoot $plugin.name
            if (-not (Test-Path -LiteralPath $linkPath)) {
                New-Item -ItemType Junction -Path $linkPath -Target $pluginPath | Out-Null
            }
        }
    }
}
if ($buildAndroid) {
    if (-not (Test-Path "$env:ANDROID_HOME/platforms/android-37*/android.jar")) {
        throw 'Android SDK Platform 37 is required by this project.'
    }
}

# Keep each build and its Dart symbols together without overwriting older runs.
$releaseDirectory = Join-Path $OutputDirectory (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
$symbolsDirectory = Join-Path $releaseDirectory 'symbols'
New-Item -ItemType Directory -Path $symbolsDirectory -Force | Out-Null
$configurationArguments = @('--release', '--tree-shake-icons', "--build-name=$Version", "--build-number=$BuildNumber")
if ($DartDefineFile) { $configurationArguments += "--dart-define-from-file=$DartDefineFile" }
$configurationArguments += "--dart-define=DISTRIBUTION_CHANNEL=$DistributionChannel"
if ($DistributionChannel -eq 'githubDirect') {
    $updateParts = $UpdateRepository.Split('/')
    $configurationArguments += @(
        "--dart-define=UPDATE_MANIFEST_PUBLIC_KEY=$updatePublicKey",
        "--dart-define=UPDATE_GITHUB_OWNER=$($updateParts[0])",
        "--dart-define=UPDATE_GITHUB_REPO=$($updateParts[1])"
    )
}
# Android keeps pub enabled to regenerate the release plugin registry without
# dev-only plugins such as integration_test after Prepare's pub get.

Push-Location $flutterProjectRoot
try {
    if ($buildWindows) {
        $windowsSymbols = Join-Path $symbolsDirectory 'windows'
        New-Item -ItemType Directory -Path $windowsSymbols -Force | Out-Null
        # Preserve Prepare's plugin junctions on Windows without symlink privileges.
        $windowsArguments = @('build', 'windows', '--no-pub', "--split-debug-info=$windowsSymbols") + $configurationArguments
        & "$env:FLUTTER_ROOT/bin/flutter.bat" @windowsArguments
        if ($LASTEXITCODE -ne 0) { throw 'Windows production release build failed.' }

        $windowsBuild = Join-Path $flutterProjectRoot 'build/windows/x64/runner/Release'
        foreach ($requiredFile in @('tvbro.exe', 'flutter_windows.dll', 'libmpv-2.dll', 'data/app.so', 'data/icudtl.dat', 'data/flutter_assets/AssetManifest.bin')) {
            if (-not (Test-Path -LiteralPath (Join-Path $windowsBuild $requiredFile) -PathType Leaf)) {
                throw "Windows release file is missing: $requiredFile"
            }
        }
        # The executable needs its DLLs and data directory alongside it.
        $windowsDestination = Join-Path $releaseDirectory 'windows-x64'
        Copy-Item -LiteralPath $windowsBuild -Destination $windowsDestination -Recurse
        Write-Host "Windows application: $windowsDestination/tvbro.exe"
        if ($DistributionChannel -eq 'githubDirect') {
            $windowsArchive = Join-Path $releaseDirectory "iptvs-$Version-windows-x64.zip"
            Compress-Archive -Path "$windowsDestination/*" -DestinationPath $windowsArchive -CompressionLevel Optimal
            Write-Host "Windows ZIP: $windowsArchive"
        } else {
            Write-Host 'Microsoft Store payload ready. Package with scripts/package_windows_msix.ps1 using your Partner Center identity.'
        }
    }

    if ($buildAndroid) {
        $androidFormat = if ($DistributionChannel -eq 'googlePlay') { 'appbundle' } else { 'apk' }
        $buildArguments = @(
            'build', $androidFormat, '--flavor', $DistributionChannel,
            '--target-platform', 'android-arm,android-arm64,android-x64',
            "--split-debug-info=$symbolsDirectory"
        ) + $configurationArguments
        & "$env:FLUTTER_ROOT/bin/flutter.bat" @buildArguments
        if ($LASTEXITCODE -ne 0) { throw 'Android production release build failed.' }

        if ($DistributionChannel -eq 'googlePlay') {
            $androidSource = Join-Path $flutterProjectRoot 'build/app/outputs/bundle/googlePlayRelease/app-googlePlay-release.aab'
            $androidName = "tvbro-$Version-google-play.aab"
        } else {
            $androidSource = Join-Path $flutterProjectRoot 'build/app/outputs/flutter-apk/app-githubdirect-release.apk'
            $androidName = "iptvs-$Version-android.apk"
        }
        if (-not (Test-Path -LiteralPath $androidSource -PathType Leaf)) {
            throw "Expected Android release is missing: $androidSource"
        }
        Copy-Item -LiteralPath $androidSource -Destination (Join-Path $releaseDirectory $androidName)
        Write-Host "Android release: $releaseDirectory/$androidName"
    }
    if ($DistributionChannel -eq 'githubDirect') {
        & "$PSScriptRoot/sign-release.ps1" -ReleaseDirectory $releaseDirectory -Version $Version -SigningConfig $UpdateSigningConfig -ExpectedPublicKey $updatePublicKey
    }
    [ordered]@{
        version = $Version; build_number = $BuildNumber; distribution_channel = $DistributionChannel
        update_repository = if ($DistributionChannel -eq 'githubDirect') { $UpdateRepository } else { $null }
        update_public_key = $updatePublicKey
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $releaseDirectory 'release-info.json') -Encoding UTF8
    Write-Host "Release outputs: $releaseDirectory"
    Write-Host "Keep the matching Dart symbols for crash diagnostics: $symbolsDirectory"
} finally {
    Pop-Location
}
} finally {
    foreach ($name in $signingVariables) { [Environment]::SetEnvironmentVariable($name, $previousSigning[$name], 'Process') }
}
