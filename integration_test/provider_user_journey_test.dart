// Credential-free Android TV journey through the original application.
//
// flutter drive --profile --no-dds --flavor development -d emulator-5560 \
//   --target integration_test/provider_user_journey_test.dart \
//   --driver test_driver/low_end_tv_driver.dart \
//   --dart-define=DISTRIBUTION_CHANNEL=development \
//   --dart-define=TVBRO_CLOUD_ENABLED=false
// LOW_END_TV_RESULTS_DIR selects the existing driver's JSON output directory.
// All provider responses and artwork are synthetic, served on device loopback.
// Native SQLite/media_kit and the original app.main/UI remain in use. Storage
// paths and secure-storage contents are isolated before app.main is invoked.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show FramePhase, FrameTiming;

import 'package:flutter/foundation.dart' show kProfileMode, kReleaseMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
// Test-only platform seams; supplied transitively by the existing plugins.
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/cloud_config.dart';
import 'package:iptvs/data/device_class.dart';
import 'package:iptvs/data/distribution_channel.dart';
import 'package:iptvs/data/provider_image_cache.dart';
import 'package:iptvs/data/provider_request_gate.dart';
import 'package:iptvs/dvr/dvr_scheduler.dart';
import 'package:iptvs/dvr/dvr_service.dart';
import 'package:iptvs/main.dart' as application;
import 'package:iptvs/screens/channel_list_screen.dart';
import 'package:iptvs/screens/global_search_view.dart';
import 'package:iptvs/screens/home_shell.dart';
import 'package:iptvs/screens/language_selection_screen.dart';
import 'package:iptvs/screens/media_tab_view.dart';
import 'package:iptvs/screens/profile_pick_screen.dart';
import 'package:iptvs/screens/sources_screen.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/source_config.dart';
import 'package:iptvs/widgets/routed_focus_node.dart';
import 'package:iptvs/widgets/tv_text_field.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite/sqflite.dart' as native_sqlite;

const _channelCount = int.fromEnvironment(
  'JOURNEY_CHANNELS',
  defaultValue: 1000,
);
const _movieCount = int.fromEnvironment('JOURNEY_MOVIES', defaultValue: 1000);
const _seriesCount = int.fromEnvironment('JOURNEY_SERIES', defaultValue: 100);
const _episodesPerSeason = int.fromEnvironment(
  'JOURNEY_EPISODES_PER_SEASON',
  defaultValue: 30,
);
const _navigationKeys = int.fromEnvironment('JOURNEY_KEYS', defaultValue: 30);
const _movieId = '10001';
const _seriesId = '50001';
const _seasonId = '$_seriesId:season:1';
const _catalogActions = <String>[
  'get_live_categories',
  'get_live_streams',
  'get_vod_categories',
  'get_vod_streams',
  'get_series_categories',
  'get_series',
];

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized()
    ..framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('original Android TV app: cold and warm provider user journey', (
    tester,
  ) async {
    expect(Platform.isAndroid, isTrue);
    expect(CloudConfig.enabled, isFalse);
    expect(DistributionConfig.channel, DistributionChannel.development);
    expect(_channelCount, greaterThanOrEqualTo(100));
    expect(_movieCount, greaterThanOrEqualTo(100));
    expect(_seriesCount, greaterThanOrEqualTo(2));
    expect(_episodesPerSeason, greaterThanOrEqualTo(2));
    expect(_navigationKeys, greaterThanOrEqualTo(4));

    final oldPaths = PathProviderPlatform.instance;
    final oldStorage = FlutterSecureStoragePlatform.instance;
    final oldHttp = HttpOverrides.current;
    final oldDatabasePath = await native_sqlite.getDatabasesPath();
    final directory = await Directory.systemTemp.createTemp('tvbro_journey_');
    final fixture = await _XtreamFixture.start();
    final network = _LoopbackOnlyHttp();
    final rendered = _RenderedState(binding);
    final input = _NativeTextInput(binding.defaultBinaryMessenger);
    final phases = <Map<String, Object?>>[];
    final metrics = <String, Object?>{
      'schema': 1,
      'status': 'running',
      'buildMode': kProfileMode
          ? 'profile'
          : kReleaseMode
          ? 'release'
          : 'debug',
      'platform': Platform.operatingSystem,
      'osVersion': Platform.operatingSystemVersion,
      'logicalProcessors': Platform.numberOfProcessors,
      'physicalWidth': tester.view.physicalSize.width,
      'physicalHeight': tester.view.physicalSize.height,
      'devicePixelRatio': tester.view.devicePixelRatio,
      'refreshRateHz': tester.view.display.refreshRate,
      'entrypoint': 'package:iptvs/main.dart main()',
      'ui': 'original onboarding, sources, home and browsing widgets',
      'databaseBackend': 'native Android sqflite',
      'databaseIsolation': 'fresh temporary directory and default SQLite path',
      'secureStorage': 'empty in-memory platform implementation',
      'textInput': 'actual native IME client ID; synthetic editing events',
      'providerTransport': 'real HTTP to synthetic device-loopback Xtream',
      'channels': _channelCount,
      'movies': _movieCount,
      'series': _seriesCount,
      'seasonsPerSeries': 2,
      'episodesPerSeason': _episodesPerSeason,
      'navigationKeysPerPhase': _navigationKeys,
      'playback': 'excluded from this browsing workload',
      'phases': phases,
    };
    binding.reportData = {'provider_user_journey': metrics};
    AppDatabase? database;
    Object? failure;
    PathProviderPlatform.instance = _IsolatedPaths(directory.path);
    FlutterSecureStoragePlatform.instance = _MemorySecureStorage();
    await native_sqlite.databaseFactory.setDatabasesPath(directory.path);
    HttpOverrides.global = network;

    Future<void> measure(String name, Future<void> Function() action) =>
        _measure(tester, fixture, name, phases, action);

    Future<void> home() async {
      await tester.tap(find.byTooltip('Home').hitTestable());
      await rendered.waitFor(
        () => tester.any(find.byKey(const ValueKey('home-live'))),
        'library home',
      );
    }

    Future<void> openTab(ContentKind kind) async {
      await tester.tap(find.byKey(ValueKey('home-${kind.name}')));
      await rendered.waitFor(
        () => kind == ContentKind.live
            ? tester.any(find.textContaining('Fixture Channel').hitTestable())
            : tester
                  .widgetList<MediaTabView>(find.byType(MediaTabView))
                  .any(
                    (view) =>
                        view.kind == kind &&
                        !view.loading &&
                        view.visible.isNotEmpty,
                  ),
        '${kind.name} catalogue ready',
      );
    }

    Future<void> search(ContentKind kind) async {
      final query = switch (kind) {
        ContentKind.live => 'Channel 00001',
        ContentKind.movie => 'Movie 00001',
        _ => 'Series 00001',
      };
      final result = switch (kind) {
        ContentKind.live => 'search.live.1',
        ContentKind.movie => 'search.movie.$_movieId',
        _ => 'search.series.$_seriesId',
      };
      final field = find.byWidgetPredicate(
        (widget) =>
            widget is TvTextField && widget.hintText.startsWith('Search '),
      );
      await _enterField(tester, rendered, input, field, query);
      await rendered.waitFor(
        () =>
            tester.any(find.byType(GlobalSearchView)) &&
            tester.any(find.byKey(ValueKey(result)).hitTestable()),
        '${kind.name} local search result',
      );
      await _enterField(tester, rendered, input, field, '');
      await rendered.waitFor(
        () => !tester.any(find.byType(GlobalSearchView)),
        '${kind.name} search closed',
      );
    }

    Future<void> openMovie() async {
      await tester.tap(find.text('More info').hitTestable().first);
      await rendered.waitFor(
        () =>
            tester.any(find.byType(MediaDetailsSheet)) &&
            tester.any(find.text('Synthetic movie details 10001')),
        'movie details',
      );
    }

    Future<void> closeDetails() async {
      await tester.tap(find.byKey(const ValueKey('media.details.close')));
      await rendered.waitFor(
        () => !tester.any(find.byType(MediaDetailsSheet)),
        'details closed',
      );
    }

    Future<void> openSeries() async {
      await tester.tap(find.byKey(const ValueKey('media.featured.primary')));
      await rendered.waitFor(
        () => tester.any(find.byKey(const ValueKey('media.season.$_seasonId'))),
        'series seasons',
      );
      final season = find.byKey(const ValueKey('media.season.$_seasonId'));
      await tester.ensureVisible(season);
      await tester.tap(
        find.descendant(of: season, matching: find.text('Season 1')),
      );
      await rendered.waitFor(
        () => tester.any(find.textContaining('Fixture Episode 01')),
        'selected season episodes',
      );
      await tester.ensureVisible(find.textContaining('Fixture Episode 01'));
      expect(
        find.textContaining('Fixture Episode 01'),
        findsOneWidget,
        reason: 'Only the selected season should mount its episodes.',
      );
    }

    try {
      await measure('fresh_boot_language', () async {
        await application.main();
        await rendered.waitFor(
          () => tester.any(find.byType(LanguageSelectionScreen)),
          'original language onboarding',
        );
        expect(isTelevision, isTrue, reason: 'Use a real Android TV image.');
        final app = tester.widget<application.IptvApp>(
          find.byType(application.IptvApp),
        );
        database = app.db;
        expect(await app.store.list(), isEmpty);
      });
      await measure('language_profile_source_form', () async {
        await tester.tap(find.text('English'));
        await rendered.waitFor(
          () =>
              tester.any(find.byType(ProfilePickScreen)) &&
              tester.any(find.text('Skip')),
          'original profile picker',
        );
        await tester.tap(find.text('Skip'));
        await rendered.waitFor(
          () =>
              tester.any(find.byType(HomeShell)) &&
              tester.any(find.text('Add a source')),
          'fresh home',
        );
        await tester.tap(find.text('Add a source'));
        await rendered.waitFor(
          () => tester.any(find.text('Add source')),
          'source list',
        );
        await tester.tap(find.text('Add source'));
        await rendered.waitFor(
          () => tester.any(find.byType(EditSourceScreen)),
          'source form',
        );
        await tester.tap(find.byType(DropdownButtonFormField<SourceKind>));
        await rendered.waitFor(
          () => tester.any(find.text('XTREAM').hitTestable()),
          'source kinds',
        );
        await tester.tap(find.text('XTREAM').last);
        await rendered.waitFor(
          () => tester.any(find.widgetWithText(TvTextField, 'Host')),
          'Xtream form',
        );
        for (final field in <String, String>{
          'Label (optional)': 'Synthetic loopback provider',
          'Host': fixture.base,
          'Username': 'fixture-user',
          'Password': 'fixture-password',
        }.entries) {
          await _enterField(
            tester,
            rendered,
            input,
            find.widgetWithText(TvTextField, field.key),
            field.value,
          );
        }
      });
      await measure('source_save_and_cold_catalog_import', () async {
        await tester.ensureVisible(find.text('Save source'));
        await tester.pump();
        // A scroll jump changes paint coordinates on the following frame.
        await tester.tap(find.text('Save source'));
        await tester.pump();
        await rendered.waitFor(
          () =>
              !tester.any(find.byType(EditSourceScreen)) &&
              tester.any(find.text('Synthetic loopback provider')),
          'saved source',
        );
        await binding.handlePopRoute();
        await rendered.waitFor(
          () =>
              tester.any(find.byType(ChannelListScreen)) &&
              tester.any(find.byKey(const ValueKey('home-live'))),
          'complete original catalog preload',
          timeout: const Duration(minutes: 2),
        );
        final view = tester.widget<ChannelListScreen>(
          find.byType(ChannelListScreen),
        );
        await view.repo.pendingEpgRefresh;
        expect(
          await database!.readChannels(view.config.id),
          hasLength(_channelCount),
        );
        expect(
          await database!.countMediaItems(view.config.id, ContentKind.movie),
          _movieCount,
        );
        expect(
          await database!.countMediaItems(view.config.id, ContentKind.series),
          _seriesCount,
        );
        metrics['programmeSearchEngine'] = database!.programmeSearchEngine.name;
        for (final action in _catalogActions) {
          expect(
            fixture.counts[action],
            1,
            reason: 'Exactly one cold root catalog: $action',
          );
        }
      });

      for (final kind in const [
        ContentKind.live,
        ContentKind.movie,
        ContentKind.series,
      ]) {
        await measure('cold_${kind.name}_browse', () async {
          await openTab(kind);
          await _navigate(tester, kind);
        });
        await measure('cold_${kind.name}_search', () => search(kind));
        if (kind == ContentKind.movie) {
          await measure('cold_movie_details', openMovie);
          await closeDetails();
        } else if (kind == ContentKind.series) {
          await measure('cold_series_selected_season', openSeries);
          await closeDetails();
        }
        await home();
      }

      expect(fixture.counts['get_vod_info'], 1);
      expect(fixture.counts['get_series_info'], 1);
      expect(
        fixture.counts['artwork'],
        1,
        reason: 'Shared artwork should be downloaded once.',
      );
      final warmStart = Map<String, int>.from(fixture.counts);
      for (final kind in const [
        ContentKind.live,
        ContentKind.movie,
        ContentKind.series,
      ]) {
        await measure('warm_${kind.name}_browse', () async {
          await openTab(kind);
          await _navigate(tester, kind);
        });
        await measure('warm_${kind.name}_search', () => search(kind));
        if (kind == ContentKind.movie) {
          await measure('warm_movie_details_reopen', openMovie);
          await closeDetails();
        } else if (kind == ContentKind.series) {
          await measure('warm_series_selected_season_reopen', openSeries);
          await closeDetails();
        }
        await home();
      }
      metrics['warmRequestDelta'] = fixture.delta(warmStart);
      expect(
        fixture.delta(warmStart),
        isEmpty,
        reason: 'Warm browsing, searches and reopened details must use the local caches.',
      );
      expect(network.deniedHosts, isEmpty);
      expect(fixture.unexpectedRequests, isEmpty);
      expect(tester.takeException(), isNull);
      metrics['status'] = 'succeeded';
    } catch (error) {
      failure = error;
      metrics['status'] = 'failed';
      metrics['failure'] = '$error';
      final failureUi = _uiSnapshot(tester);
      metrics['failureUi'] = failureUi;
      // Profile builds strip debug widget-tree diagnostics. Keep a bounded
      // snapshot of visible state without recording text-input contents.
      // ignore: avoid_print
      print('TVBRO_PROVIDER_FAILURE_UI ${jsonEncode(failureUi)}');
      rethrow;
    } finally {
      rendered.close();
      fixture.phase = 'cleanup';
      try {
        await tester.pumpWidget(const SizedBox.shrink());
        await DvrScheduler.instance.close();
        await DvrService.instance.close();
        await ProviderRequestGate.instance.flushCooldowns();
        await providerImageCache.dispose();
        await database?.close();
        metrics['cleanupCompleted'] = true;
      } finally {
        metrics['requestCounts'] = Map<String, int>.from(fixture.counts);
        metrics['requests'] = fixture.requests;
        metrics['deniedOutboundHosts'] = network.deniedHosts.toList();
        metrics['unexpectedRequests'] = fixture.unexpectedRequests;
        metrics['processLifetimeMaxRssBytes'] = ProcessInfo.maxRss;
        await fixture.close();
        network.close();
        input.close();
        HttpOverrides.global = oldHttp;
        PathProviderPlatform.instance = oldPaths;
        FlutterSecureStoragePlatform.instance = oldStorage;
        await native_sqlite.databaseFactory.setDatabasesPath(oldDatabasePath);
        if (await directory.exists()) await directory.delete(recursive: true);
        if (failure != null) metrics['status'] = 'failed';
        // ignore: avoid_print
        print('TVBRO_PROVIDER_JOURNEY ${jsonEncode(metrics)}');
      }
    }
  }, timeout: const Timeout(Duration(minutes: 8)));
}

Future<void> _enterField(
  WidgetTester tester,
  _RenderedState rendered,
  _NativeTextInput input,
  Finder cell,
  String value,
) async {
  await tester.ensureVisible(cell);
  await tester.pump();
  final cellFocus = tester.widget<TvTextField>(cell).cellFocusNode;
  if (cellFocus == null) {
    await tester.tap(cell);
  } else {
    // Browse as a television user: focus the real search cell and press OK.
    cellFocus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(
      LogicalKeyboardKey.enter,
      physicalKey: PhysicalKeyboardKey.enter,
      platform: 'android',
    );
  }
  final field = find.descendant(of: cell, matching: find.byType(TextField));
  await rendered.waitFor(
    () => tester.widget<TextField>(field).focusNode!.hasFocus,
    'field edit',
  );
  await input.enterText(value);
  await tester.pump();
  expect(tester.widget<TextField>(field).controller!.text, value);
  await tester.sendKeyEvent(
    LogicalKeyboardKey.escape,
    physicalKey: PhysicalKeyboardKey.escape,
    platform: 'android',
  );
  await rendered.waitFor(
    () => !tester.widget<TextField>(field).focusNode!.hasFocus,
    'field committed',
  );
  expect(tester.widget<TextField>(field).controller!.text, value);
}

Map<String, Object?> _uiSnapshot(WidgetTester tester) => {
  'screens': [
    for (final type in [
      LanguageSelectionScreen,
      ProfilePickScreen,
      HomeShell,
      SourcesScreen,
      EditSourceScreen,
      ChannelListScreen,
      MediaDetailsSheet,
    ])
      if (tester.any(find.byType(type))) '$type',
  ],
  'fields': [
    for (final field in tester.widgetList<TvTextField>(
      find.byType(TvTextField),
    ))
      {
        'label': field.label,
        'hint': field.hintText,
        'characters': field.controller.text.length,
        'error': field.errorText,
      },
  ],
  'text': [
    for (final text in tester.widgetList<Text>(find.byType(Text)).take(30))
      if (text.data?.isNotEmpty == true) text.data,
  ],
  'focusedRoute': focusRouteKey(FocusManager.instance.primaryFocus),
  'viewInsetsBottom': tester.view.viewInsets.bottom,
};

// Preserve the real Android IME while observing its current connection ID.
// tester.enterText uses ID -1 without a registered keyboard stub; Flutter only
// accepts that special ID in debug builds, so profile would drop every edit.
class _NativeTextInput {
  _NativeTextInput(this.messenger) {
    messenger.setMockMessageHandler(SystemChannels.textInput.name, (message) {
      final call = SystemChannels.textInput.codec.decodeMethodCall(message!);
      if (call.method == 'TextInput.setClient') {
        _client = (call.arguments as List).first as int;
      } else if (call.method == 'TextInput.clearClient') {
        _client = null;
      }
      return messenger.delegate.send(SystemChannels.textInput.name, message);
    });
  }
  final TestDefaultBinaryMessenger messenger;
  int? _client;

  Future<void> enterText(String text) async {
    final client = _client;
    if (client == null) throw StateError('No active native IME client.');
    final value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    await messenger.handlePlatformMessage(
      SystemChannels.textInput.name,
      SystemChannels.textInput.codec.encodeMethodCall(
        MethodCall('TextInputClient.updateEditingState', [
          client,
          value.toJSON(),
        ]),
      ),
      (_) {},
    );
    // Keep the real keyboard's own state synchronized with the injected edit.
    await messenger.delegate.send(
      SystemChannels.textInput.name,
      SystemChannels.textInput.codec.encodeMethodCall(
        MethodCall('TextInput.setEditingState', value.toJSON()),
      ),
    );
  }

  void close() {
    messenger.setMockMessageHandler(SystemChannels.textInput.name, null);
  }
}

Future<void> _navigate(WidgetTester tester, ContentKind kind) async {
  if (kind == ContentKind.live) {
    final focus = tester
        .widgetList<Focus>(find.byType(Focus))
        .firstWhere(
          (widget) => focusRouteKey(widget.focusNode) == 'live.channels',
        );
    focus.focusNode!.requestFocus();
  }
  for (var i = 0; i < _navigationKeys; i++) {
    final key = kind == ContentKind.live
        ? (i < _navigationKeys ~/ 2
              ? LogicalKeyboardKey.arrowDown
              : LogicalKeyboardKey.arrowUp)
        : (i < _navigationKeys ~/ 2
              ? LogicalKeyboardKey.arrowRight
              : LogicalKeyboardKey.arrowLeft);
    final physical = switch (key) {
      LogicalKeyboardKey.arrowDown => PhysicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.arrowUp => PhysicalKeyboardKey.arrowUp,
      LogicalKeyboardKey.arrowRight => PhysicalKeyboardKey.arrowRight,
      _ => PhysicalKeyboardKey.arrowLeft,
    };
    await tester.sendKeyEvent(key, physicalKey: physical, platform: 'android');
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _measure(
  WidgetTester tester,
  _XtreamFixture fixture,
  String phase,
  List<Map<String, Object?>> phases,
  Future<void> Function() action,
) async {
  final binding = tester.binding;
  final frames = <FrameTiming>[];
  final before = Map<String, int>.from(fixture.counts);
  binding.addTimingsCallback(frames.addAll);
  fixture.phase = phase;
  await tester.pump();
  final start = binding.currentSystemFrameTimeStamp.inMicroseconds;
  final watch = Stopwatch()..start();
  final rssBefore = ProcessInfo.currentRss;
  var succeeded = false;
  int? elapsed;
  try {
    await action();
    elapsed = watch.elapsedMilliseconds;
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull, reason: phase);
    succeeded = true;
  } finally {
    elapsed ??= watch.elapsedMilliseconds;
    watch.stop();
    final end = binding.currentSystemFrameTimeStamp.inMicroseconds;
    // Engine timing delivery is batched. One bounded drain; exclude its frames.
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    binding.removeTimingsCallback(frames.addAll);
    final measured = frames.where((frame) {
      final stamp = frame.timestampInMicroseconds(FramePhase.buildStart);
      return stamp >= start && stamp <= end;
    }).toList();
    Map<String, Object?> summary(Iterable<int> values) {
      final sorted = values.toList()..sort();
      int? percentile(double value) =>
          sorted.isEmpty ? null : sorted[((sorted.length - 1) * value).round()];
      return {
        'p50Us': percentile(.5),
        'p95Us': percentile(.95),
        'p99Us': percentile(.99),
        'maxUs': sorted.isEmpty ? null : sorted.last,
      };
    }

    final budget = 1000000 / tester.view.display.refreshRate;
    final result = <String, Object?>{
      'phase': phase,
      'status': succeeded ? 'completed' : 'failed',
      'actionElapsedMs': elapsed,
      'phaseElapsedMs': watch.elapsedMilliseconds,
      'frameCount': measured.length,
      'build': summary(
        measured.map((frame) => frame.buildDuration.inMicroseconds),
      ),
      'raster': summary(
        measured.map((frame) => frame.rasterDuration.inMicroseconds),
      ),
      'total': summary(measured.map((frame) => frame.totalSpan.inMicroseconds)),
      'framesOverRefreshBudget': measured
          .where(
            (frame) =>
                frame.buildDuration.inMicroseconds > budget ||
                frame.rasterDuration.inMicroseconds > budget,
          )
          .length,
      'rssBeforeBytes': rssBefore,
      'rssAfterBytes': ProcessInfo.currentRss,
      'processLifetimeMaxRssBytes': ProcessInfo.maxRss,
      'requests': fixture.delta(before),
    };
    phases.add(result);
    // ignore: avoid_print
    print('TVBRO_PROVIDER_PHASE ${jsonEncode(result)}');
  }
}

// Observe completed UI frames. No fake-clock pump-until loops around native IO.
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

  Future<void> waitFor(
    bool Function() ready,
    String description, {
    Duration timeout = const Duration(seconds: 30),
  }) {
    if (ready()) return Future<void>.value();
    if (_ready != null) throw StateError('Only one UI observer may be active.');
    final complete = Completer<void>();
    _ready = ready;
    _complete = complete;
    binding.scheduleFrame();
    return complete.future.timeout(
      timeout,
      onTimeout: () {
        _ready = null;
        _complete = null;
        throw StateError('No rendered readiness: $description');
      },
    );
  }

  void close() => _closed = true;
}

class _XtreamFixture {
  _XtreamFixture(this.server) {
    _subscription = server.listen(_serve);
  }
  static Future<_XtreamFixture> start() async =>
      _XtreamFixture(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
  final HttpServer server;
  late final StreamSubscription<HttpRequest> _subscription;
  final counts = <String, int>{};
  final requests = <Map<String, Object?>>[];
  final unexpectedRequests = <String>[];
  String phase = 'setup';
  String get base => 'http://127.0.0.1:${server.port}';
  String get artwork => '$base/artwork.png';

  Map<String, int> delta(Map<String, int> before) => {
    for (final entry in counts.entries)
      if (entry.value != (before[entry.key] ?? 0))
        entry.key: entry.value - (before[entry.key] ?? 0),
  };

  Future<void> _serve(HttpRequest request) async {
    final path = request.uri.path;
    final action = path == '/player_api.php'
        ? request.uri.queryParameters['action'] ?? 'auth'
        : path == '/xmltv.php'
        ? 'xmltv'
        : path == '/artwork.png'
        ? 'artwork'
        : 'unexpected';
    counts.update(action, (value) => value + 1, ifAbsent: () => 1);
    final record = <String, Object?>{'phase': phase, 'action': action};
    final itemId =
        request.uri.queryParameters['vod_id'] ??
        request.uri.queryParameters['series_id'];
    if (itemId != null) record['itemId'] = itemId;
    requests.add(record);
    try {
      if (action == 'artwork') {
        request.response.headers.contentType = ContentType('image', 'png');
        request.response.headers.set(
          HttpHeaders.cacheControlHeader,
          'public, max-age=86400',
        );
        request.response.add(
          base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAADAAAABICAYAAACwc3YrAAAAjUlEQVR4nO3PMQ3CYBgA0SqpAmbQQYIGZnQggKEiavFHRIeXL7nh9nvb/nivyW16IIAeCKAHAuiBAHoggB4IoAcC6IEAeuAy4Pb8rskF0AXQBdAF0AXQBdAF0AXQzQfcP8eaXABdAF0AXQBdAF0AXQBdAN18wOt3rskF0AXQBdAF0AXQBdAF0AXQjQf8AXBP++X1mZpJAAAAAElFTkSuQmCC',
          ),
        );
      } else if (action == 'xmltv') {
        _requireFixtureCredentials(request);
        request.response.headers.contentType = ContentType(
          'application',
          'xml',
          charset: 'utf-8',
        );
        request.response.write(_guide());
      } else if (path == '/player_api.php') {
        _requireFixtureCredentials(request);
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(_payload(action, itemId)));
      } else {
        unexpectedRequests.add(path);
        request.response.statusCode = HttpStatus.notFound;
      }
      record['status'] = request.response.statusCode;
      await request.response.close();
    } catch (error) {
      unexpectedRequests.add('$action: ${error.runtimeType}');
      request.response.statusCode = HttpStatus.internalServerError;
      await request.response.close();
    }
  }

  void _requireFixtureCredentials(HttpRequest request) {
    if (request.uri.queryParameters['username'] != 'fixture-user' ||
        request.uri.queryParameters['password'] != 'fixture-password') {
      throw StateError('Expected synthetic credentials only.');
    }
  }

  Object _payload(String action, String? itemId) => switch (action) {
    'auth' => {
      'user_info': {
        'auth': 1,
        'status': 'Active',
        'exp_date': '0',
        'allowed_output_formats': ['ts'],
      },
      'server_info': {'timezone': 'UTC', 'server_protocol': 'http'},
    },
    'get_live_categories' ||
    'get_vod_categories' ||
    'get_series_categories' => [
      for (var i = 0; i < 5; i++)
        {
          'category_id': '${i + 1}',
          'category_name': 'Fixture Group ${i + 1}',
          'parent_id': 0,
        },
    ],
    'get_live_streams' => [
      for (var i = 1; i <= _channelCount; i++)
        {
          'num': i,
          'stream_id': i,
          'name': 'Fixture Channel ${_pad(i)}',
          'stream_type': 'live',
          'category_id': '${(i - 1) % 5 + 1}',
          'stream_icon': artwork,
          'epg_channel_id': 'fixture.$i',
          'tv_archive': 0,
          'tv_archive_duration': 0,
        },
    ],
    'get_vod_streams' => [
      for (var i = 1; i <= _movieCount; i++)
        {
          'num': i,
          'stream_id': 10000 + i,
          'name': 'Fixture Movie ${_pad(i)}',
          'stream_type': 'movie',
          'category_id': '${(i - 1) % 5 + 1}',
          'stream_icon': artwork,
          'container_extension': 'ts',
          'added': '${2000000000 - i}',
        },
    ],
    'get_series' => [
      for (var i = 1; i <= _seriesCount; i++)
        {
          'num': i,
          'series_id': 50000 + i,
          'name': 'Fixture Series ${_pad(i)}',
          'category_id': '${(i - 1) % 5 + 1}',
          'cover': artwork,
          'last_modified': '${2000000000 - i}',
        },
    ],
    'get_vod_info' => {
      'info': {
        'name': 'Fixture Movie 00001',
        'plot': 'Synthetic movie details $itemId',
        'movie_image': artwork,
        'duration_secs': 20,
      },
      'movie_data': {
        'stream_id': int.parse(itemId!),
        'container_extension': 'ts',
      },
    },
    'get_series_info' => {
      'info': {
        'name': 'Fixture Series 00001',
        'plot': 'Synthetic series details $itemId',
        'cover': artwork,
      },
      'seasons': [
        for (var season = 1; season <= 2; season++)
          {'season_number': season, 'name': 'Season $season', 'cover': artwork},
      ],
      'episodes': {
        for (var season = 1; season <= 2; season++)
          '$season': [
            for (var episode = 1; episode <= _episodesPerSeason; episode++)
              {
                'id': '${60000 + season * 1000 + episode}',
                'episode_num': episode,
                'title':
                    'Fixture Episode ${episode.toString().padLeft(2, '0')}',
                'container_extension': 'ts',
                'info': {'movie_image': artwork, 'duration_secs': 20},
              },
          ],
      },
    },
    _ => throw UnsupportedError('Unexpected fixture action $action'),
  };

  String _guide() {
    final now = DateTime.now().toUtc();
    final start = DateTime.utc(
      now.year,
      now.month,
      now.day,
    ).subtract(const Duration(days: 1));
    String stamp(DateTime date) =>
        '${date.year}${date.month.toString().padLeft(2, '0')}${date.day.toString().padLeft(2, '0')}${date.hour.toString().padLeft(2, '0')}0000 +0000';
    final xml = StringBuffer('<?xml version="1.0"?><tv>');
    for (var i = 1; i <= _channelCount; i++) {
      xml.write(
        '<channel id="fixture.$i"><display-name>Fixture Channel ${_pad(i)}</display-name></channel>',
      );
      for (var day = 0; day < 3; day++) {
        final from = start.add(Duration(days: day));
        xml.write(
          '<programme channel="fixture.$i" start="${stamp(from)}" stop="${stamp(from.add(const Duration(days: 1)))}"><title>Fixture Programme ${_pad(i)}</title></programme>',
        );
      }
    }
    return '${xml.toString()}</tv>';
  }

  Future<void> close() async {
    await server.close(force: true);
    await _subscription.cancel();
  }
}

String _pad(int value) => value.toString().padLeft(5, '0');

class _IsolatedPaths extends PathProviderPlatform {
  _IsolatedPaths(this.path);
  final String path;
  @override
  Future<String> getApplicationSupportPath() async => path;
  @override
  Future<String> getTemporaryPath() async => path;
  @override
  Future<String> getLibraryPath() async => path;
  @override
  Future<String> getApplicationDocumentsPath() async => path;
  @override
  Future<String> getApplicationCachePath() async => path;
  @override
  Future<String> getExternalStoragePath() async => path;
  @override
  Future<List<String>> getExternalCachePaths() async => [path];
  @override
  Future<List<String>> getExternalStoragePaths({
    StorageDirectory? type,
  }) async => [path];
  @override
  Future<String> getDownloadsPath() async => path;
}

class _MemorySecureStorage extends FlutterSecureStoragePlatform {
  final _values = <String, String>{};
  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async => _values[key] = value;
  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) async => _values[key];
  @override
  Future<bool> containsKey({
    required String key,
    required Map<String, String> options,
  }) async => _values.containsKey(key);
  @override
  Future<void> delete({
    required String key,
    required Map<String, String> options,
  }) async => _values.remove(key);
  @override
  Future<Map<String, String>> readAll({
    required Map<String, String> options,
  }) async => Map.of(_values);
  @override
  Future<void> deleteAll({required Map<String, String> options}) async =>
      _values.clear();
}

class _LoopbackOnlyHttp extends HttpOverrides {
  final deniedHosts = <String>{};
  final _clients = <HttpClient>[];
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.findProxy = (_) => 'DIRECT';
    client.connectionFactory = (uri, proxyHost, proxyPort) {
      if (uri.host != '127.0.0.1' &&
          uri.host != 'localhost' &&
          uri.host != '::1') {
        deniedHosts.add(uri.host);
        throw StateError('Only synthetic device-loopback HTTP is allowed.');
      }
      return Socket.startConnect(uri.host, uri.port);
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
