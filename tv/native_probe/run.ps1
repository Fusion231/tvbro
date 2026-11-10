param(
    [string]$FlutterSdk,
    [string]$PubCache,
    [string]$SqliteLibrary,
    [string]$MpvLibrary
)

$ErrorActionPreference = 'Stop'
$appDirectory = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$workspaceDirectory = Split-Path $appDirectory -Parent
if (-not $FlutterSdk) { $FlutterSdk = Join-Path $workspaceDirectory 'evaluation/tooling/flutter' }
$FlutterSdk = [IO.Path]::GetFullPath($FlutterSdk)
if (-not $PubCache) { $PubCache = Join-Path $workspaceDirectory 'evaluation/tooling/pub-cache' }
if (-not $SqliteLibrary) { $SqliteLibrary = Join-Path $appDirectory '.dart_tool/lib/sqlite3.dll' }
if (-not $MpvLibrary) { $MpvLibrary = Join-Path $appDirectory 'windows/libmpv/libmpv-2.dll' }
$flutterCommand = Join-Path $FlutterSdk 'bin/flutter.bat'
$dartCommand = Join-Path $FlutterSdk 'bin/cache/dart-sdk/bin/dart.exe'
$packageConfigPath = Join-Path $appDirectory '.dart_tool/package_config.json'
$packageGraphPath = Join-Path $appDirectory '.dart_tool/package_graph.json'
$probeDirectory = Join-Path $appDirectory 'tv/output/native-probe'
$probeConfigDirectory = Join-Path $probeDirectory '.dart_tool'
$probeConfigPath = Join-Path $probeConfigDirectory 'package_config.json'
$testPath = Join-Path $PSScriptRoot 'test/reuse_test.dart'
$epgTestPath = Join-Path $appDirectory 'test/epg_grid_test.dart'
$storageTestPath = Join-Path $PSScriptRoot 'test/storage_reuse_test.dart'
$bootstrapTestPath = Join-Path $PSScriptRoot 'test/bootstrap_reuse_test.dart'
$tvEntrypoint = Join-Path $appDirectory 'tv/app/main.dart'
$storageDirectory = Join-Path $probeDirectory ('storage-' + [Guid]::NewGuid().ToString('N'))
$bootstrapDirectory = Join-Path $probeDirectory ('bootstrap-' + [Guid]::NewGuid().ToString('N'))

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'The durable-storage phase requires the existing Windows host DPAPI plugin.'
}
foreach ($requiredPath in @($flutterCommand, $dartCommand, $packageConfigPath, $packageGraphPath, $SqliteLibrary, $MpvLibrary, $testPath, $epgTestPath, $storageTestPath, $bootstrapTestPath, $tvEntrypoint)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Missing cached prerequisite: $requiredPath. This probe does not install dependencies."
    }
}

$protectedPaths = @(
    (Join-Path $appDirectory 'lib/main.dart'),
    (Join-Path $appDirectory 'lib/theme.dart'),
    (Join-Path $appDirectory 'lib/data/device_class.dart'),
    (Join-Path $appDirectory 'lib/data/cloud_config.dart'),
    (Join-Path $appDirectory 'lib/data/distribution_channel.dart'),
    (Join-Path $appDirectory 'lib/data/parental_controls.dart'),
    (Join-Path $appDirectory 'lib/data/provider_image_cache.dart'),
    (Join-Path $appDirectory 'lib/data/provider_request_gate.dart'),
    (Join-Path $appDirectory 'lib/dvr/dvr_scheduler.dart'),
    (Join-Path $appDirectory 'lib/dvr/dvr_service.dart'),
    (Join-Path $appDirectory 'lib/l10n/app_language.dart'),
    (Join-Path $appDirectory 'lib/screens/language_selection_screen.dart'),
    (Join-Path $appDirectory 'lib/screens/profile_pick_screen.dart'),
    (Join-Path $appDirectory 'lib/screens/home_shell.dart'),
    (Join-Path $appDirectory 'lib/screens/sources_screen.dart'),
    (Join-Path $appDirectory 'lib/sources/source.dart'),
    (Join-Path $appDirectory 'lib/sources/source_config.dart'),
    (Join-Path $appDirectory 'lib/sources/source_identity.dart'),
    (Join-Path $appDirectory 'lib/sources/m3u_source.dart'),
    (Join-Path $appDirectory 'lib/sources/xtream_source.dart'),
    (Join-Path $appDirectory 'lib/data/library_repository.dart'),
    (Join-Path $appDirectory 'lib/data/app_database.dart'),
    (Join-Path $appDirectory 'lib/data/secret_locator_vault.dart'),
    (Join-Path $appDirectory 'lib/data/source_store.dart'),
    (Join-Path $appDirectory 'lib/data/local_profile_store.dart'),
    (Join-Path $appDirectory 'lib/data/secure_local_storage.dart'),
    (Join-Path $appDirectory 'lib/data/metadata_config.dart'),
    (Join-Path $appDirectory 'lib/screens/epg_grid_screen.dart'),
    $epgTestPath,
    (Join-Path $appDirectory 'pubspec.yaml'),
    (Join-Path $appDirectory 'pubspec.lock'),
    $packageConfigPath,
    $packageGraphPath,
    $tvEntrypoint,
    $bootstrapTestPath,
    $storageTestPath,
    (Join-Path $PSScriptRoot 'test/support/isolated_host_paths.dart'),
    $PSCommandPath,
    $MpvLibrary
)
$before = @{}
foreach ($path in $protectedPaths) { $before[$path] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }

[IO.Directory]::CreateDirectory($probeConfigDirectory) | Out-Null
$config = Get-Content -LiteralPath $packageConfigPath -Raw | ConvertFrom-Json
$configUri = [Uri]::new($packageConfigPath)
foreach ($package in $config.packages) {
    $package.rootUri = [Uri]::new($configUri, $package.rootUri).AbsoluteUri
}
$iptvs = @($config.packages | Where-Object { $_.name -eq 'iptvs' })
$expectedSourceUri = [Uri]::new($appDirectory + [IO.Path]::DirectorySeparatorChar).AbsoluteUri
if ($iptvs.Count -ne 1 -or $iptvs[0].rootUri -ne $expectedSourceUri) {
    throw 'The iptvs package must resolve to the original app directory.'
}
$flutterPackage = @($config.packages | Where-Object { $_.name -eq 'flutter' })
$expectedFlutterUri = [Uri]::new((Join-Path $FlutterSdk 'packages/flutter') + [IO.Path]::DirectorySeparatorChar).AbsoluteUri.TrimEnd('/')
if ($flutterPackage.Count -ne 1 -or $flutterPackage[0].rootUri.TrimEnd('/') -ne $expectedFlutterUri) {
    throw 'The selected Flutter SDK must match the existing package config. Mixed CLI/framework SDKs are not qualified.'
}
$storagePackage = @($config.packages | Where-Object { $_.name -eq 'flutter_secure_storage_windows' })
if ($storagePackage.Count -ne 1) {
    throw 'The existing package graph must contain flutter_secure_storage_windows; this probe does not install it.'
}
$storagePluginRoot = [Uri]::new($storagePackage[0].rootUri).LocalPath
$storagePluginSource = Join-Path $storagePluginRoot 'lib/src/flutter_secure_storage_windows_ffi.dart'
$storagePluginManifest = Join-Path $storagePluginRoot 'pubspec.yaml'
foreach ($path in @($storagePluginSource, $storagePluginManifest)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing cached plugin input: $path" }
    $protectedPaths += $path
    $before[$path] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
}
$config.packages = @($config.packages) + @([PSCustomObject]@{
    name = 'tvbro_native_reuse_probe'
    rootUri = [Uri]::new($probeDirectory + [IO.Path]::DirectorySeparatorChar).AbsoluteUri
    packageUri = 'lib/'
    languageVersion = '3.13'
})
$config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $probeConfigPath -Encoding UTF8
$graph = Get-Content -LiteralPath $packageGraphPath -Raw | ConvertFrom-Json
$graph.roots = @('tvbro_native_reuse_probe')
$graph.packages = @($graph.packages) + @([PSCustomObject]@{
    name = 'tvbro_native_reuse_probe'
    version = '0.0.0'
    dependencies = @('flutter', 'iptvs')
    devDependencies = @('flutter_test', 'flutter_secure_storage', 'flutter_secure_storage_platform_interface', 'flutter_secure_storage_windows', 'path', 'path_provider', 'path_provider_platform_interface')
})
$graph | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $probeConfigDirectory 'package_graph.json') -Encoding UTF8

# Generate the root Flutter asset declaration from the owner manifest. Preserve
# asset keys (including font paths) and verify every staged file byte-for-byte.
$stageAssetsPath = Join-Path $probeDirectory 'stage-assets.dart'
@'
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

void main(List<String> arguments) {
  final manifest = File(arguments[0]);
  final owner = manifest.parent.resolveSymbolicLinksSync();
  final output = Directory(arguments[1]).resolveSymbolicLinksSync();
  final document = loadYaml(manifest.readAsStringSync()) as YamlMap;
  final flutter = document['flutter'] as YamlMap;
  final keys = <String>[
    for (final asset in flutter['assets'] as YamlList? ?? const [])
      asset as String,
    for (final family in flutter['fonts'] as YamlList? ?? const [])
      for (final font in (family as YamlMap)['fonts'] as YamlList)
        (font as YamlMap)['asset'] as String,
  ];
  final evidence = <Map<String, Object>>[];
  for (final key in keys.toSet()) {
    if (p.isAbsolute(key) || p.split(p.normalize(key)).contains('..')) {
      throw StateError('Owner asset must be relative to its project: $key');
    }
    final source = File(p.join(owner, key)).resolveSymbolicLinksSync();
    if (!p.isWithin(owner, source)) {
      throw StateError('Owner asset resolves outside its project: $key');
    }
    final destination = File(p.join(output, key));
    destination.parent.createSync(recursive: true);
    File(source).copySync(destination.path);
    final sourceHash = sha256.convert(File(source).readAsBytesSync()).toString();
    final stagedHash = sha256.convert(destination.readAsBytesSync()).toString();
    if (sourceHash != stagedHash) throw StateError('Staged asset differs: $key');
    evidence.add({
      'assetKey': key,
      'sourcePath': source,
      'stagedPath': destination.path,
      'sourceSha256': sourceHash,
      'stagedSha256': stagedHash,
    });
  }
  File(p.join(output, 'owner-flutter.yaml'))
      .writeAsStringSync('flutter: ${jsonEncode(flutter)}\n');
  File(p.join(output, 'asset-staging.json'))
      .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(evidence));
}
'@ | Set-Content -LiteralPath $stageAssetsPath -Encoding UTF8
& $dartCommand "--packages=$packageConfigPath" $stageAssetsPath (Join-Path $appDirectory 'pubspec.yaml') $probeDirectory
if ($LASTEXITCODE -ne 0) { throw 'Owner asset staging failed.' }
$ownerFlutterYaml = (Get-Content -LiteralPath (Join-Path $probeDirectory 'owner-flutter.yaml') -Raw).TrimEnd()
$assetEvidence = @(Get-Content -LiteralPath (Join-Path $probeDirectory 'asset-staging.json') -Raw | ConvertFrom-Json)
foreach ($asset in $assetEvidence) {
    $protectedPaths += $asset.sourcePath
    $before[$asset.sourcePath] = $asset.sourceSha256.ToUpperInvariant()
}

# A generated host test project only. The original pubspec/lock/config are read-only.
# The supported sqlite3 hook uses an existing host DLL, so it cannot fetch a binary.
$sqliteYamlPath = [Uri]::new([IO.Path]::GetFullPath($SqliteLibrary)).AbsoluteUri.Replace("'", "''")
@"
name: tvbro_native_reuse_probe
publish_to: none
environment:
  sdk: ^3.13.5
dependencies:
  flutter:
    sdk: flutter
  iptvs:
    path: ../../..
dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_secure_storage: any
  flutter_secure_storage_platform_interface: any
  flutter_secure_storage_windows: any
  path: any
  path_provider: any
  path_provider_platform_interface: any
$ownerFlutterYaml
hooks:
  user_defines:
    sqlite3:
      source: system
      name: '$sqliteYamlPath'
"@ | Set-Content -LiteralPath (Join-Path $probeDirectory 'pubspec.yaml') -Encoding UTF8

$savedPubCache = $env:PUB_CACHE
$savedTemp = $env:TEMP
$savedTmp = $env:TMP
$savedDashSuppressAnalytics = $env:DASH__SUPPRESS_ANALYTICS
$savedStoragePhase = $env:TVBRO_STORAGE_PROBE_PHASE
$savedStorageDirectory = $env:TVBRO_STORAGE_PROBE_DIRECTORY
$savedBootstrapDirectory = $env:TVBRO_BOOTSTRAP_PROBE_DIRECTORY
$savedMpvLibrary = $env:LIBMPV_LIBRARY_PATH
$temporaryDirectory = Join-Path $probeDirectory 'tmp'
[IO.Directory]::CreateDirectory($temporaryDirectory) | Out-Null
[IO.Directory]::CreateDirectory($storageDirectory) | Out-Null
$phases = @(
    [ordered]@{ name = 'core-and-epg'; tests = @($testPath, $epgTestPath); log = 'test.log'; reporter = 'tests.jsonl'; status = 'not_run' },
    [ordered]@{ name = 'storage-write'; tests = @($storageTestPath); log = 'storage-write.log'; reporter = 'storage-write-tests.jsonl'; status = 'not_run' },
    [ordered]@{ name = 'storage-read'; tests = @($storageTestPath); log = 'storage-read.log'; reporter = 'storage-read-tests.jsonl'; status = 'not_run' },
    [ordered]@{ name = 'bootstrap'; tests = @($bootstrapTestPath); log = 'bootstrap.log'; reporter = 'bootstrap-tests.jsonl'; status = 'not_run' }
)
$exitCode = 1
Push-Location $probeDirectory
try {
    $env:PUB_CACHE = $PubCache
    $env:TEMP = $temporaryDirectory
    $env:TMP = $temporaryDirectory
    # Also suppress telemetry in Dart subprocesses started by native-asset hooks.
    $env:DASH__SUPPRESS_ANALYTICS = 'true'
    $exitCode = 0
    foreach ($phase in $phases) {
        if ($phase.name -eq 'storage-read' -and $phases[1].status -ne 'succeeded') {
            $phase.status = 'skipped'
            $phase.reason = 'The dependent storage-write phase did not succeed.'
            $phase.completedAt = [DateTime]::UtcNow.ToString('o')
            $phase.reason | Set-Content -LiteralPath (Join-Path $probeDirectory $phase.log) -Encoding UTF8
            [IO.File]::WriteAllText((Join-Path $probeDirectory $phase.reporter), '')
            continue
        }
        $env:TVBRO_STORAGE_PROBE_PHASE = switch ($phase.name) {
            'storage-write' { 'write' }
            'storage-read' { 'read' }
            default { $null }
        }
        $env:TVBRO_STORAGE_PROBE_DIRECTORY = $storageDirectory
        if ($phase.name -eq 'bootstrap') {
            [IO.Directory]::CreateDirectory($bootstrapDirectory) | Out-Null
            $env:TVBRO_BOOTSTRAP_PROBE_DIRECTORY = $bootstrapDirectory
            $env:LIBMPV_LIBRARY_PATH = [IO.Path]::GetFullPath($MpvLibrary)
        }
        $phase.startedAt = [DateTime]::UtcNow.ToString('o')
        $phase.status = 'running'
        try {
            $arguments = @('--no-version-check', '--suppress-analytics', '--packages', $probeConfigPath,
                'test', '--no-pub', '--reporter', 'expanded', '--concurrency', '1',
                '--file-reporter', "json:$($phase.reporter)")
            # Original widget tests need Flutter's cached Material shader.
            # Assets are generated only in this ignored host project.
            if ($phase.name -in @('storage-write', 'storage-read')) { $arguments += '--no-test-assets' }
            if ($phase.name -eq 'bootstrap') {
                $arguments += @('--dart-define=TVBRO_CLOUD_ENABLED=false', '--dart-define=DISTRIBUTION_CHANNEL=development')
            }
            $arguments += $phase.tests
            & $flutterCommand @arguments 2>&1 | Tee-Object -FilePath (Join-Path $probeDirectory $phase.log)
            $phase.exitCode = $LASTEXITCODE
            $phase.status = if ($phase.exitCode -eq 0) { 'succeeded' } else { 'failed' }
        } catch {
            $phase.exitCode = 1
            $phase.status = 'failed'
            $phase.error = $_.Exception.Message
        } finally {
            $phase.completedAt = [DateTime]::UtcNow.ToString('o')
        }
        if ($phase.exitCode -ne 0) { $exitCode = $phase.exitCode }
    }
} finally {
    Pop-Location
    $env:PUB_CACHE = $savedPubCache
    $env:TEMP = $savedTemp
    $env:TMP = $savedTmp
    $env:DASH__SUPPRESS_ANALYTICS = $savedDashSuppressAnalytics
    $env:TVBRO_STORAGE_PROBE_PHASE = $savedStoragePhase
    $env:TVBRO_STORAGE_PROBE_DIRECTORY = $savedStorageDirectory
    $env:TVBRO_BOOTSTRAP_PROBE_DIRECTORY = $savedBootstrapDirectory
    $env:LIBMPV_LIBRARY_PATH = $savedMpvLibrary
    $changedPaths = @()
    foreach ($path in $protectedPaths) {
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $before[$path]) { $changedPaths += $path }
    }
    [ordered]@{
        completedAt = [DateTime]::UtcNow.ToString('o')
        scope = 'Host Flutter VM; original app entrypoint/UI bootstrap, EPG widget and Windows DPAPI persistence; no Tizen/webOS build, playback or device qualification'
        exitCode = $exitCode
        originalPackageConfig = $packageConfigPath
        resolvedIptvsRoot = $iptvs[0].rootUri
        flutter = Get-Content -LiteralPath (Join-Path $FlutterSdk 'bin/cache/flutter.version.json') -Raw | ConvertFrom-Json
        sqliteLibrary = $sqliteYamlPath
        phases = $phases
        storageDirectory = $storageDirectory
        bootstrapDirectory = $bootstrapDirectory
        tvEntrypoint = $tvEntrypoint
        mpvLibrary = [IO.Path]::GetFullPath($MpvLibrary)
        stagedAssets = $assetEvidence
        storagePluginRoot = $storagePackage[0].rootUri
        sourceAndManifestSha256Before = $before
        changedProtectedPaths = $changedPaths
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $probeDirectory 'evidence.json') -Encoding UTF8
    if ($changedPaths.Count -ne 0) { throw "Read-only input changed during the run: $($changedPaths -join ', ')" }
}
if ($exitCode -ne 0) { throw "Reuse probe failed with exit code $exitCode. See tv/output/native-probe/evidence.json and phase logs." }
