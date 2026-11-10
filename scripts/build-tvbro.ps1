[CmdletBinding()]
param(
    [ValidateSet('Prepare', 'Windows', 'Android', 'All')]
    [string]$Target = 'All',
    [string]$FlutterRoot = $env:FLUTTER_ROOT,
    [string]$PubCache = $env:PUB_CACHE,
    [string]$GradleUserHome = $env:GRADLE_USER_HOME,
    [string]$JavaHome = $env:JAVA_HOME,
    [string]$AndroidSdk = $env:ANDROID_HOME,
    [ValidateSet('android-arm,android-arm64,android-x64', 'android-x64')]
    [string]$AndroidTargetPlatform = 'android-arm,android-arm64,android-x64',
    [switch]$Offline
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$toolingRoot = Join-Path (Split-Path -Parent $projectRoot) 'evaluation/tooling'

# Prefer explicit configuration, then this workspace's evaluated toolchain.
if (-not $FlutterRoot -and (Test-Path "$toolingRoot/flutter/bin/flutter.bat")) {
    $FlutterRoot = Join-Path $toolingRoot 'flutter'
}
if (-not $FlutterRoot -or -not (Test-Path "$FlutterRoot/bin/flutter.bat")) {
    throw 'Set FLUTTER_ROOT or pass -FlutterRoot with a compatible Flutter SDK.'
}
$flutter = (Resolve-Path "$FlutterRoot/bin/flutter.bat").Path
if (-not $PubCache) {
    $PubCache = if (Test-Path "$toolingRoot/pub-cache") {
        Join-Path $toolingRoot 'pub-cache'
    } else {
        Join-Path $env:LOCALAPPDATA 'Pub/Cache'
    }
}
if (-not $GradleUserHome -and (Test-Path "$toolingRoot/gradle-cache")) {
    $GradleUserHome = Join-Path $toolingRoot 'gradle-cache'
}
if (-not $AndroidSdk) {
    $AndroidSdk = if ($env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT } else {
        Join-Path $env:LOCALAPPDATA 'Android/Sdk'
    }
}
if (-not $JavaHome) {
    $JavaHome = Get-ChildItem "$env:ProgramFiles/Microsoft/jdk-*" -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1 -ExpandProperty FullName
}
$env:FLUTTER_ROOT = (Resolve-Path $FlutterRoot).Path
$env:PUB_CACHE = [System.IO.Path]::GetFullPath($PubCache)
$env:PATH = "$env:FLUTTER_ROOT/bin;$env:PATH"
$env:DASH__SUPPRESS_ANALYTICS = 'true'
if ($GradleUserHome) { $env:GRADLE_USER_HOME = $GradleUserHome }
if ($JavaHome) { $env:JAVA_HOME = $JavaHome }
$env:ANDROID_HOME = $AndroidSdk
Write-Host "Flutter: $flutter"
Write-Host "Pub cache: $env:PUB_CACHE"
Write-Host "Android SDK: $AndroidSdk"
Write-Host "Java: $JavaHome"

Push-Location $projectRoot
try {
    $pubArguments = @('get')
    if ($Offline) { $pubArguments += '--offline' }
    # Windows PowerShell 5.1 turns redirected native stderr into ErrorRecords.
    # Inspect the actual exit code so Flutter's symlink fallback remains reachable.
    $previousErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $pubOutput = & $flutter pub @pubArguments 2>&1
        $pubExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorAction
    }
    $pubOutput | ForEach-Object { Write-Host $_ }
    if ($pubExit -ne 0) {
        if (-not ($pubOutput -match 'requires symlink support')) {
            throw "Flutter dependency preparation failed ($pubExit)."
        }
        # Junctions work without enabling Windows Developer Mode. Flutter's first
        # attempt writes this metadata before plugin-link creation fails.
        $metadata = Get-Content '.flutter-plugins-dependencies' -Raw | ConvertFrom-Json
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
        & $flutter pub @pubArguments
        if ($LASTEXITCODE -ne 0) { throw 'Flutter plugin preparation failed.' }
    }
    # Building with --no-pub before this exists can produce an APK that hangs
    # during startup because its platform plugins were never registered.
    if (-not (Test-Path 'android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java')) {
        throw 'Android plugin registration is missing. Run dependency preparation again.'
    }
    if ($Target -in @('Windows', 'All')) {
        & $flutter build windows --debug --no-pub --dart-define=DISTRIBUTION_CHANNEL=development
        if ($LASTEXITCODE -ne 0) { throw 'Windows debug build failed.' }
        Write-Host "Windows app: $projectRoot/build/windows/x64/runner/Debug/tvbro.exe"
    }
    if ($Target -in @('Android', 'All')) {
        if (-not (Test-Path "$AndroidSdk/platforms/android-37*/android.jar")) {
            throw 'Android SDK Platform 37 is required by this project.'
        }
        if (-not $JavaHome -or -not (Test-Path "$JavaHome/bin/java.exe")) {
            throw 'Set JAVA_HOME or pass -JavaHome with a compatible JDK.'
        }
        [string[]]$splitArguments = @()
        if ($AndroidTargetPlatform -eq 'android-x64') { $splitArguments += '--split-per-abi' }
        & $flutter build apk --debug --flavor development --no-pub --target-platform $AndroidTargetPlatform --dart-define=DISTRIBUTION_CHANNEL=development @splitArguments
        if ($LASTEXITCODE -ne 0) { throw 'Android development debug build failed.' }
        $apkDirectory = Join-Path $projectRoot 'build/app/outputs/flutter-apk'
        $apkName = if ($AndroidTargetPlatform -eq 'android-x64') {
            'tvbro-development-debug-x64.apk'
        } else {
            'tvbro-development-debug-universal.apk'
        }
        $builtApkName = if ($AndroidTargetPlatform -eq 'android-x64') {
            'app-x86_64-development-debug.apk'
        } else {
            'app-development-debug.apk'
        }
        Copy-Item -LiteralPath "$apkDirectory/$builtApkName" -Destination "$apkDirectory/$apkName"
        Write-Host "Android APK: $apkDirectory/$apkName"
    }
} finally {
    Pop-Location
}
