[CmdletBinding()]
param(
    [ValidateSet('Android', 'Windows', 'All')]
    [string]$Target = 'All',
    [string]$OutputDirectory = 'apkRelease',
    [string]$SigningConfig,
    [string]$DartDefineFile,
    [string]$FlutterRoot,
    [string]$PubCache,
    [string]$GradleUserHome,
    [string]$JavaHome,
    [string]$AndroidSdk,
    [switch]$Offline
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$buildAndroid = $Target -in @('Android', 'All')
$buildWindows = $Target -in @('Windows', 'All')

# Use the same protected signing configuration as the Gradle release build.
if ($buildAndroid) {
    $signingVariables = @(
        'IPTVS_ANDROID_KEYSTORE_PATH',
        'IPTVS_ANDROID_KEYSTORE_PASSWORD',
        'IPTVS_ANDROID_KEY_ALIAS',
        'IPTVS_ANDROID_KEY_PASSWORD'
    )
    if (-not $SigningConfig) {
        $SigningConfig = Join-Path (Split-Path -Parent $projectRoot) '.signing/android-release.clixml'
    }
    $configuredSigning = @($signingVariables | Where-Object {
        -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($_))
    })
    if ($configuredSigning.Count -eq 0 -and (Test-Path -LiteralPath $SigningConfig -PathType Leaf)) {
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
        $keystorePath = Join-Path $projectRoot "android/app/$keystorePath"
    }
    if (-not (Test-Path -LiteralPath $keystorePath -PathType Leaf)) {
        throw 'The release keystore does not exist. Check IPTVS_ANDROID_KEYSTORE_PATH.'
    }
}

if (-not [System.IO.Path]::IsPathRooted($OutputDirectory)) {
    $OutputDirectory = Join-Path $projectRoot $OutputDirectory
}
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
if ($DartDefineFile) {
    if (-not [System.IO.Path]::IsPathRooted($DartDefineFile)) {
        $DartDefineFile = Join-Path $projectRoot $DartDefineFile
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
& "$PSScriptRoot/build-tvbro.ps1" @prepareArguments
if ($buildWindows) {
    # pub get may succeed without recreating links when its metadata is unchanged.
    # Ensure junctions exist before building without Windows symlink privileges.
    $metadata = Get-Content (Join-Path $projectRoot '.flutter-plugins-dependencies') -Raw | ConvertFrom-Json
    $allowedRoots = @($env:PUB_CACHE, $projectRoot) | ForEach-Object {
        [System.IO.Path]::GetFullPath($_).TrimEnd('\', '/') + '\'
    }
    foreach ($platform in @('windows', 'linux')) {
        $linkRoot = Join-Path $projectRoot "$platform/flutter/ephemeral/.plugin_symlinks"
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
    if (-not $env:JAVA_HOME -or -not (Test-Path "$env:JAVA_HOME/bin/java.exe")) {
        throw 'Set JAVA_HOME or pass -JavaHome with JDK 21 or newer.'
    }
    $javaVersion = (& "$env:JAVA_HOME/bin/java.exe" --version) -join "`n"
    if ($LASTEXITCODE -ne 0 -or $javaVersion -notmatch '^(?:openjdk|java)\s+(\d+)' -or [int]$Matches[1] -lt 21) {
        throw 'Release lint requires JDK 21 or newer. Set JAVA_HOME or pass -JavaHome.'
    }
}

# Keep each build and its Dart symbols together without overwriting older runs.
$releaseDirectory = Join-Path $OutputDirectory (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
$symbolsDirectory = Join-Path $releaseDirectory 'symbols'
New-Item -ItemType Directory -Path $symbolsDirectory -Force | Out-Null
$configurationArguments = @('--release', '--tree-shake-icons')
if ($DartDefineFile) { $configurationArguments += "--dart-define-from-file=$DartDefineFile" }
$configurationArguments += '--dart-define=DISTRIBUTION_CHANNEL=githubDirect'
# Android keeps pub enabled to regenerate the release plugin registry without
# dev-only plugins such as integration_test after Prepare's pub get.

Push-Location $projectRoot
try {
    if ($buildWindows) {
        $windowsSymbols = Join-Path $symbolsDirectory 'windows'
        New-Item -ItemType Directory -Path $windowsSymbols -Force | Out-Null
        # Preserve Prepare's plugin junctions on Windows without symlink privileges.
        $windowsArguments = @('build', 'windows', '--no-pub', "--split-debug-info=$windowsSymbols") + $configurationArguments
        & "$env:FLUTTER_ROOT/bin/flutter.bat" @windowsArguments
        if ($LASTEXITCODE -ne 0) { throw 'Windows production release build failed.' }

        $windowsBuild = Join-Path $projectRoot 'build/windows/x64/runner/Release'
        foreach ($requiredFile in @('tvbro.exe', 'flutter_windows.dll', 'libmpv-2.dll', 'data/app.so', 'data/icudtl.dat', 'data/flutter_assets/AssetManifest.bin')) {
            if (-not (Test-Path -LiteralPath (Join-Path $windowsBuild $requiredFile) -PathType Leaf)) {
                throw "Windows release file is missing: $requiredFile"
            }
        }
        # The executable needs its DLLs and data directory alongside it.
        $windowsDestination = Join-Path $releaseDirectory 'windows-x64'
        Copy-Item -LiteralPath $windowsBuild -Destination $windowsDestination -Recurse
        $windowsArchive = Join-Path $releaseDirectory 'tvbro-windows-x64-release.zip'
        Compress-Archive -Path "$windowsDestination/*" -DestinationPath $windowsArchive -CompressionLevel Optimal
        Write-Host "Windows application: $windowsDestination/tvbro.exe"
        Write-Host "Windows ZIP: $windowsArchive"
    }

    if ($buildAndroid) {
        $buildArguments = @(
            'build', 'apk', '--flavor', 'githubDirect',
            '--split-per-abi', '--target-platform', 'android-arm,android-arm64,android-x64',
            "--split-debug-info=$symbolsDirectory"
        ) + $configurationArguments
        & "$env:FLUTTER_ROOT/bin/flutter.bat" @buildArguments
        if ($LASTEXITCODE -ne 0) { throw 'Android production release build failed.' }

        $apkDirectory = Join-Path $projectRoot 'build/app/outputs/flutter-apk'
        $artifacts = @('armeabi-v7a', 'arm64-v8a', 'x86_64') | ForEach-Object {
            $source = Join-Path $apkDirectory "app-$_-githubdirect-release.apk"
            if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
                throw "Expected release APK is missing: $source"
            }
            [PSCustomObject]@{ Source = $source; Name = "tvbro-$_-release.apk" }
        }
        foreach ($artifact in $artifacts) {
            Copy-Item -LiteralPath $artifact.Source -Destination (Join-Path $releaseDirectory $artifact.Name)
        }
        Write-Host "Release APKs: $releaseDirectory"
        Get-ChildItem -LiteralPath $releaseDirectory -Filter '*.apk' | ForEach-Object {
            Write-Host ("  {0} ({1:N1} MB)" -f $_.Name, ($_.Length / 1MB))
        }
    }
    Write-Host "Release outputs: $releaseDirectory"
    Write-Host "Keep the matching Dart symbols for crash diagnostics: $symbolsDirectory"
} finally {
    Pop-Location
}
