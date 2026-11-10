import 'dart:async';
import 'dart:convert';
import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart'
    show
        TargetPlatform,
        debugDefaultTargetPlatformOverride,
        defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show OffsetLayer;
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_secure_storage_windows/flutter_secure_storage_windows.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/cloud_config.dart';
import 'package:iptvs/data/device_class.dart';
import 'package:iptvs/data/distribution_channel.dart';
import 'package:iptvs/data/provider_image_cache.dart';
import 'package:iptvs/data/provider_request_gate.dart';
import 'package:iptvs/data/secret_locator_vault.dart';
import 'package:iptvs/dvr/dvr_scheduler.dart';
import 'package:iptvs/dvr/dvr_service.dart';
import 'package:iptvs/l10n/app_localizations.dart';
import 'package:iptvs/main.dart' show IptvApp;
import 'package:iptvs/screens/home_shell.dart';
import 'package:iptvs/screens/language_selection_screen.dart';
import 'package:iptvs/screens/profile_pick_screen.dart';
import 'package:iptvs/screens/sources_screen.dart';
import 'package:iptvs/sources/source_config.dart';
import 'package:iptvs/widgets/tv_text_field.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:iptvs/main.dart' as original;
import 'support/isolated_host_paths.dart';

void main() {
  // Real-time Flutter frames let readiness complete on rendered app state,
  // without polling or fixed frame/delay loops around OS-backed storage IO.
  final binding = LiveTestWidgetsFlutterBinding.ensureInitialized()
    ..framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('TV entrypoint executes the original app bootstrap and source UI', (
    tester,
  ) async {
    expect(Platform.isWindows, isTrue);
    expect(CloudConfig.enabled, isFalse);
    expect(CloudConfig.isConfigured, isFalse);
    expect(DistributionConfig.channel, DistributionChannel.development);
    expect(isTelevision, isFalse, reason: 'This is the actual host, not a TV.');
    final directory = await isolatedHostDirectory(
      'TVBRO_BOOTSTRAP_PROBE_DIRECTORY',
      'bootstrap',
    );
    expect(await directory.list().isEmpty, isTrue);

    final oldPaths = PathProviderPlatform.instance;
    final oldStorage = FlutterSecureStoragePlatform.instance;
    final oldTarget = debugDefaultTargetPlatformOverride;
    final oldHttp = HttpOverrides.current;
    final network = _NoOutboundConnections();
    final rendered = _RenderedState(binding);
    final reached = <String>[];
    AppDatabase? database;
    var succeeded = false;
    var cleanedUp = false;
    int? mpvApiVersion;
    String? sourceId;
    PathProviderPlatform.instance = IsolatedHostPaths(directory.path);
    // FLUTTER_TEST defaults to Android options. Match the Windows host only;
    // never set debugIsTelevision or simulate Tizen/Linux identity.
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final hostTargetPlatform = defaultTargetPlatform.name;
    FlutterSecureStorageWindows.registerWith();
    HttpOverrides.global = network;
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    await binding.setSurfaceSize(const Size(1280, 720));

    try {
      expect(
        FlutterSecureStoragePlatform.instance,
        isA<FlutterSecureStorageWindows>(),
      );
      final mpvPath = Platform.environment['LIBMPV_LIBRARY_PATH'];
      expect(mpvPath, isNotNull);
      mpvApiVersion = DynamicLibrary.open(mpvPath!)
          .lookupFunction<Uint64 Function(), int Function()>(
            'mpv_client_api_version',
          )();
      expect(mpvApiVersion, greaterThan(0));
      await _verifyAndLoadOwnerAssets();

      // The host probe exercises the original engine and storage. The TV
      // entrypoint separately registers AVPlay before calling this same main.
      await original.main().timeout(const Duration(seconds: 20));
      reached.add('package:iptvs/main.dart main() (host backend)');
      await rendered.waitFor(
        () => tester.any(find.byType(LanguageSelectionScreen)),
        'original language screen',
      );
      final application = tester.widget<IptvApp>(find.byType(IptvApp));
      database = application.db;
      reached.add('IptvApp -> LanguageSelectionScreen');
      expect(await application.store.list(), isEmpty);
      final secure = const FlutterSecureStorage();
      expect(await secure.read(key: SecretLocatorVault.keyName), isNotNull);
      expect(await File(p.join(directory.path, 'iptv.db')).exists(), isTrue);

      await tester.tap(find.text('English'));
      await rendered.waitFor(
        () =>
            tester.any(find.byType(ProfilePickScreen)) &&
            tester.any(find.text('Skip')),
        'original profile picker ready',
      );
      reached.add('ProfilePickScreen');
      expect(
        await secure.read(key: AppLanguageController.storageKey),
        AppLanguage.english.code,
      );
      await tester.tap(find.text('Skip'));
      await rendered.waitFor(
        () =>
            tester.any(find.byType(HomeShell)) &&
            tester.any(find.text('Add a source')),
        'original home ready',
      );
      reached.add('HomeShell');
      await DvrScheduler.instance.ensureInitialized().timeout(
        const Duration(seconds: 10),
      );
      expect(DvrScheduler.instance.canResolve, isTrue);

      await tester.tap(find.text('Add a source'));
      await rendered.waitFor(
        () =>
            tester.any(find.byType(SourcesScreen)) &&
            tester.any(find.text('No sources yet — add one')),
        'original source list ready',
      );
      reached.add('SourcesScreen');
      await tester.tap(find.text('Add source'));
      await rendered.waitFor(
        () => tester.any(find.byType(EditSourceScreen)),
        'original source form',
      );
      await tester.tap(find.byType(DropdownButtonFormField<SourceKind>));
      await rendered.waitFor(
        () => tester.any(find.text('M3U').hitTestable()),
        'original source kind menu',
      );
      await tester.tap(find.text('M3U').last);
      await rendered.waitFor(
        () => tester.any(find.widgetWithText(TvTextField, 'Playlist URL')),
        'original M3U fields',
      );
      await _enterOwnerField(
        tester,
        rendered,
        'Label (optional)',
        'Bootstrap fixture',
      );
      await _enterOwnerField(
        tester,
        rendered,
        'Playlist URL',
        'https://fixture.invalid/bootstrap.m3u',
      );
      await tester.tap(find.text('Save source'));
      await rendered.waitFor(
        () =>
            !tester.any(find.byType(EditSourceScreen)) &&
            tester.any(find.text('Bootstrap fixture')) &&
            !tester.any(find.byType(CircularProgressIndicator)),
        'original source saved and badge ready',
      );
      reached.add('EditSourceScreen -> SourceStore.save -> SourcesScreen');
      final saved = (await application.store.list()).single;
      sourceId = saved.id;
      expect(isUuid(saved.id), isTrue);
      expect(saved.kind, SourceKind.m3u);
      expect(saved.label, 'Bootstrap fixture');
      expect(
        saved.fields['playlistUrl'],
        'https://fixture.invalid/bootstrap.m3u',
      );
      expect(await application.store.activeId(), saved.id);
      expect(network.attempts, 0);
      expect(isTelevision, isFalse);
      expect(tester.takeException(), isNull);
      await _captureSources(binding, directory);
      succeeded = true;
    } catch (_) {
      await File(p.join(directory.path, 'bootstrap-widget-tree.txt'))
          .writeAsString(binding.rootElement?.toStringDeep() ?? '<no tree>');
      rethrow;
    } finally {
      rendered.close();
      try {
        // Dispose UI owners first, then stop background work and its loopback
        // server before closing the database and restoring platform delegates.
        await tester.pumpWidget(const SizedBox.shrink());
        await DvrScheduler.instance.close();
        await DvrService.instance.close();
        await ProviderRequestGate.instance.flushCooldowns();
        await providerImageCache.dispose();
        await database?.close();
        cleanedUp = true;
      } finally {
        network.close();
        HttpOverrides.global = oldHttp;
        PathProviderPlatform.instance = oldPaths;
        FlutterSecureStoragePlatform.instance = oldStorage;
        debugDefaultTargetPlatformOverride = oldTarget;
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        await binding.setSurfaceSize(null);
        await File(p.join(directory.path, 'bootstrap-evidence.json'))
            .writeAsString(
              const JsonEncoder.withIndent('  ').convert({
                'scope':
                    'Host Flutter VM and normal wide layout; no native TV '
                    'build, television identity or playback qualification',
                'status': succeeded && cleanedUp ? 'succeeded' : 'failed',
                'processId': pid,
                'operatingSystem': Platform.operatingSystem,
                'flutterTargetPlatform': hostTargetPlatform,
                'hostStorage': 'FlutterSecureStorageWindows (DPAPI)',
                'applicationSupportDirectory': directory.path,
                'hostEntrypoint': 'package:iptvs/main.dart',
                'reached': reached,
                'cloudEnabled': CloudConfig.enabled,
                'distributionChannel': DistributionConfig.channel.name,
                'mpvLibrary': Platform.environment['LIBMPV_LIBRARY_PATH'],
                'mpvClientApiVersion': mpvApiVersion,
                'sourceId': sourceId,
                'outboundConnectionAttempts': network.attempts,
                'viewport': {'width': 1280, 'height': 720},
                'screenshot': p.join(directory.path, 'sources-1280x720.png'),
                'cleanupCompleted': cleanedUp,
              }),
              flush: true,
            );
      }
    }
    expect(cleanedUp, isTrue);
  }, timeout: const Timeout(Duration(seconds: 90)));
}

Future<void> _enterOwnerField(
  WidgetTester tester,
  _RenderedState rendered,
  String label,
  String value,
) async {
  final cell = find.widgetWithText(TvTextField, label);
  final field = find.descendant(of: cell, matching: find.byType(TextField));
  await tester.tap(cell);
  await rendered.waitFor(
    () => tester.widget<TextField>(field).focusNode!.hasFocus,
    'original field editing: $label',
  );
  await tester.enterText(field, value);
  expect(tester.widget<TextField>(field).controller!.text, value);
  // Finish through TvTextField's own edit-mode key handler before Save source.
  await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  await rendered.waitFor(
    () => !tester.widget<TextField>(field).focusNode!.hasFocus,
    'original field edit finished: $label',
  );
}

Future<void> _verifyAndLoadOwnerAssets() async {
  final assets =
      jsonDecode(await File('asset-staging.json').readAsString()) as List;
  final fontManifest =
      jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
  expect(assets, isNotEmpty);
  expect(
    fontManifest.cast<Map>().map((family) => family['family']),
    containsAll(['Inter', 'MaterialIcons']),
  );
  for (final asset in assets.cast<Map>()) {
    final bytes = await rootBundle.load(asset['assetKey'] as String);
    expect(
      sha256
          .convert(
            bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
          )
          .toString(),
      asset['sourceSha256'],
    );
  }
  for (final family in fontManifest.cast<Map>()) {
    final loader = FontLoader(family['family'] as String);
    for (final font in (family['fonts'] as List).cast<Map>()) {
      loader.addFont(rootBundle.load(font['asset'] as String));
    }
    await loader.load();
  }
}

Future<void> _captureSources(
  LiveTestWidgetsFlutterBinding binding,
  Directory directory,
) async {
  final layer = binding.renderViews.single.debugLayer! as OffsetLayer;
  final image = await layer.toImage(const Rect.fromLTWH(0, 0, 1280, 720));
  try {
    expect(image.width, 1280);
    expect(image.height, 720);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    await File(p.join(directory.path, 'sources-1280x720.png')).writeAsBytes(
      png!.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
      flush: true,
    );
  } finally {
    image.dispose();
  }
}

class _RenderedState {
  _RenderedState(this.binding) {
    binding.addPersistentFrameCallback((_) {
      if (_closed || _ready == null) return;
      binding.addPostFrameCallback((_) {
        if (!_closed && (_ready?.call() ?? false)) {
          _complete!.complete();
          _ready = null;
          _complete = null;
        }
      });
    });
  }

  final LiveTestWidgetsFlutterBinding binding;
  bool _closed = false;
  bool Function()? _ready;
  Completer<void>? _complete;

  Future<void> waitFor(bool Function() ready, String description) {
    if (ready()) return Future<void>.value();
    assert(_ready == null);
    final complete = Completer<void>();
    _ready = ready;
    _complete = complete;
    binding.scheduleFrame();
    return complete.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () => throw StateError('No rendered readiness: $description'),
    );
  }

  void close() => _closed = true;
}

class _NoOutboundConnections extends HttpOverrides {
  final _clients = <HttpClient>[];
  var attempts = 0;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.connectionFactory = (uri, proxyHost, proxyPort) async {
      attempts++;
      throw StateError(
        'The isolated bootstrap must not connect to HTTP hosts.',
      );
    };
    _clients.add(client);
    return client;
  }

  void close() {
    for (final client in _clients) {
      client.close(force: true);
    }
  }
}
