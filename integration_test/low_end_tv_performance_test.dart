// Credential-free, opt-in Android TV workload. Run on a disposable development
// emulator, in profile mode; never substitute captured provider data.
//
// flutter drive --profile --target integration_test/low_end_tv_performance_test.dart \
//   --driver test_driver/low_end_tv_driver.dart --flavor development -d emulator-5560 \
//   --dart-define=DISTRIBUTION_CHANNEL=development
//
// Optional separate stress run: --dart-define=LOW_END_TV_EPISODES=5000.
// Each completed phase is printed immediately so an OOM cannot erase earlier
// observations. Frame timings use engine timestamps, not callback arrival time.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show FramePhase, FrameTiming;

import 'package:flutter/foundation.dart'
    show compute, kProfileMode, kReleaseMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
// Test-only SPI for an isolated path; already supplied by path_provider. Keep
// the production dependency set and native SQLite implementation unchanged.
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/device_class.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/data/source_store.dart';
import 'package:iptvs/screens/channel_list_screen.dart';
import 'package:iptvs/screens/epg_grid_screen.dart';
import 'package:iptvs/screens/media_tab_view.dart';
import 'package:iptvs/sources/demo_source.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/source_config.dart';
import 'package:iptvs/theme.dart';
import 'package:iptvs/widgets/routed_focus_node.dart';

import 'support/native_search_comparison.dart';

const _channelCount = int.fromEnvironment(
  'LOW_END_TV_CHANNEL_COUNT',
  defaultValue: 50000,
);
const _programmesPerChannel = int.fromEnvironment(
  'LOW_END_TV_PROGRAMMES_PER_CHANNEL',
  defaultValue: 4,
);
const _keyEvents = int.fromEnvironment(
  'LOW_END_TV_KEY_EVENTS',
  defaultValue: 240,
);
const _episodeCount = int.fromEnvironment(
  'LOW_END_TV_EPISODES',
  defaultValue: 0,
);
const _fixtureId = '00000000-0000-4000-8000-000000005000';
const _config = SourceConfig(
  id: _fixtureId,
  kind: SourceKind.demo,
  label: 'Synthetic TV workload',
  fields: {},
);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets(
    'low-end TV: native SQLite, 50k channels, guide and D-pad',
    (tester) async {
      expect(_channelCount, greaterThanOrEqualTo(100));
      expect(_programmesPerChannel, greaterThanOrEqualTo(2));
      expect(_keyEvents, greaterThanOrEqualTo(20));
      expect(_episodeCount, greaterThanOrEqualTo(0));
      await detectDeviceClass();
      expect(
        isTelevision,
        isTrue,
        reason: 'Use an Android TV/Google TV image.',
      );
      MediaKit.ensureInitialized();

      // Unlike openAt(), open() selects the actual Android sqflite plugin.
      // Redirect only its support path; the real app database is never opened.
      final nativePaths = PathProviderPlatform.instance;
      final sandbox = await Directory.systemTemp.createTemp('tvbro_low_end_');
      PathProviderPlatform.instance = _SandboxPaths(nativePaths, sandbox.path);
      addTearDown(() async {
        PathProviderPlatform.instance = nativePaths;
        if (await sandbox.exists()) await sandbox.delete(recursive: true);
      });
      final db = await AppDatabase.open();
      final source = _FixtureSource();
      final repo = _ObservedRepository(source: source, db: db);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await db.epgIngest.shutdown();
        await source.dispose();
        await db.close();
      });

      final now = DateTime.now().toUtc();
      final anchor = DateTime.utc(
        now.year,
        now.month,
        now.day,
        (now.hour ~/ 6) * 6,
      );
      final phases = <Map<String, Object?>>[];
      final metrics = <String, Object?>{
        'schema': 1,
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
        'channels': _channelCount,
        'programmes': _channelCount * _programmesPerChannel,
        'programmesPerChannel': _programmesPerChannel,
        'programmeSlotHours': 6,
        'epgAnchorUtc': anchor.toIso8601String(),
        'keyEventsPerNavigationPhase': _keyEvents,
        'episodes': _episodeCount,
        'databaseBackend': 'Android sqflite (production open)',
        'programmeSearchEngine': db.programmeSearchEngine.name,
        'databaseIsolation': 'private temporary support directory',
        'logosAndPlayback': 'excluded; synthetic metadata only',
        'phases': phases,
      };
      binding.reportData = {'low_end_tv_performance': metrics};
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          ),
        ),
      );

      Future<void> measure(String phase, Future<void> Function() action) =>
          _measure(tester, phase, phases, action);

      await measure('import_channels', () async {
        final channels = await compute(_fixtureChannels, _channelCount);
        await db.replaceLibrary(_fixtureId, 'Synthetic TV workload', [
          for (var i = 0; i < 50; i++) Category(id: '$i', title: 'Group $i'),
        ], channels);
      });
      await measure('import_epg', () async {
        await db.replaceEpgStream(_fixtureId, _fixtureProgrammes(anchor));
      });

      late List<Channel> cached;
      await measure('cached_channels', () async {
        cached = await db.readChannels(_fixtureId);
        expect(cached, hasLength(_channelCount));
      });
      await measure('epg_queries', () async {
        final queryWatch = Stopwatch()..start();
        final queryTimes = <String, int>{};
        metrics['queryTimingsMs'] = queryTimes;
        final ids = cached.take(40).map((channel) => channel.id).toList();
        final current = await db.nowNextForChannels(_fixtureId, ids, now);
        queryTimes['nowNext40'] = queryWatch.elapsedMilliseconds;
        expect(current.now.length, ids.length);
        queryWatch.reset();
        final window = await db.programmesForChannels(
          _fixtureId,
          ids,
          from: anchor,
          to: anchor.add(const Duration(hours: 24)),
        );
        queryTimes['guide40'] = queryWatch.elapsedMilliseconds;
        expect(window.length, ids.length);
        queryWatch.reset();
        final results = await db.searchProgrammes(
          'Fixture programme',
          sourceId: _fixtureId,
          allowedChannelIds: cached.take(1000).map((c) => c.id).toSet(),
          from: now,
          limit: 80,
        );
        queryTimes['searchAllowlist'] = queryWatch.elapsedMilliseconds;
        expect(results, hasLength(80));
      });

      if (const bool.fromEnvironment('LOW_END_TV_COMPARE_SEARCH')) {
        metrics['searchComparison'] = await compareNativeSearches(
          db: db,
          path: '${sandbox.path}/iptv.db',
          sourceId: _fixtureId,
          channelIds: cached.map((channel) => channel.id).toList(),
          now: now,
        );
      }

      await measure('cached_screen_open', () async {
        final watch = Stopwatch()..start();
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.dark,
            home: ChannelListScreen(
              repo: repo,
              config: _config,
              store: _EmptyStore(),
            ),
          ),
        );
        await tester.tap(find.byKey(const ValueKey('home-live')));
        await tester.pump();
        await repo.firstLoad.future.timeout(const Duration(minutes: 2));
        metrics['channelSnapshotReadyMs'] = watch.elapsedMilliseconds;
        await repo.firstGuide.future.timeout(const Duration(minutes: 2));
        metrics['viewportNowNextReadyMs'] = watch.elapsedMilliseconds;
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.byType(EpgGridScreen), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(EpgGridScreen),
            matching: find.textContaining('Fixture programme'),
          ),
          findsWidgets,
          reason: 'Measure populated guide rows, not loading or empty states.',
        );
      });

      _focusChannels(tester);
      await measure('grid_navigation', () => _navigate(tester));
      await tester.tap(find.byTooltip('Channel list'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(EpgGridScreen), findsNothing);
      _focusChannels(tester);
      await measure('channel_navigation', () => _navigate(tester));
      metrics['nowNextQueryCalls'] = repo.nowNextCalls;
      metrics['maxNowNextIdsPerCall'] = repo.maximumWindowIds;
      expect(repo.maximumWindowIds, lessThanOrEqualTo(128));
      expect(
        source.resolveCalls,
        0,
        reason: 'The workload must not open streams.',
      );

      if (_episodeCount > 0) {
        final episodeRepo = _EpisodeRepository(source: source, db: db);
        const episodeTimeout = Duration(seconds: 30);
        Future<void> episodeStep(String step, Future<void> future) async {
          await future.timeout(
            episodeTimeout,
            onTimeout: () => throw TimeoutException(
              'Episode workload timed out during $step; '
              'requests: ${episodeRepo.requestedKinds.map((kind) => kind.name).join(', ')}',
              episodeTimeout,
            ),
          );
          expect(tester.takeException(), isNull, reason: 'Episode step: $step');
        }

        await episodeStep(
          'mount details',
          tester.pumpWidget(
            MaterialApp(
              key: const ValueKey('low-end-tv-episode-app'),
              theme: AppTheme.dark,
              home: Scaffold(
                body: MediaDetailsSheet(
                  repo: episodeRepo,
                  item: const MediaItem(
                    id: 'series',
                    title: 'Synthetic series',
                    kind: ContentKind.series,
                  ),
                  favorite: false,
                  onToggleFavorite: () {},
                  onPlay: null,
                  onPlayEpisode: (_) =>
                      throw StateError('Playback is outside this workload.'),
                ),
              ),
            ),
          ),
        );
        expect(find.byType(MediaDetailsSheet), findsOneWidget);
        await episodeStep('build details', tester.pump());
        await episodeStep('load seasons', episodeRepo.seasonsReady.future);
        await episodeStep(
          'layout seasons',
          tester.pump(const Duration(milliseconds: 300)),
        );
        final episodesButton = find.byKey(const ValueKey('media.details.play'));
        expect(episodesButton, findsOneWidget);
        await episodeStep(
          'reveal View episodes',
          tester.ensureVisible(episodesButton),
        );
        await episodeStep(
          'layout View episodes',
          tester.pump(const Duration(milliseconds: 200)),
        );
        expect(episodesButton.hitTestable(), findsOneWidget);
        await episodeStep('activate View episodes', tester.tap(episodesButton));
        await episodeStep(
          'layout episode section',
          tester.pump(const Duration(milliseconds: 300)),
        );
        final seasonHeader = find.descendant(
          of: find.byType(MediaDetailsSheet),
          matching: find.text('Season 1'),
        );
        expect(seasonHeader, findsOneWidget);
        await episodeStep(
          'reveal season header',
          tester.ensureVisible(seasonHeader),
        );
        await episodeStep(
          'layout season header',
          tester.pump(const Duration(milliseconds: 200)),
        );
        expect(seasonHeader.hitTestable(), findsOneWidget);
        await episodeStep(
          'measure expansion',
          measure('episodes_expand', () async {
            await episodeStep('expand season', tester.tap(seasonHeader));
            // ExpansionTile mounts its lazy child only on the next frame.
            // Pump before awaiting the repository call that child starts.
            await episodeStep('mount episode loader', tester.pump());
            await episodeStep(
              'load episodes',
              episodeRepo.episodesReady.future,
            );
            await episodeStep(
              'layout episodes',
              tester.pump(const Duration(milliseconds: 300)),
            );
            expect(find.text('1. Episode 0'), findsOneWidget);
            metrics['mountedEpisodeFocusNodes'] = find
                .byType(Focus)
                .evaluate()
                .where(
                  (element) =>
                      focusRouteKey((element.widget as Focus).focusNode)
                          .startsWith('media.episode.'),
                )
                .length;
            expect(metrics['mountedEpisodeFocusNodes'], greaterThan(0));
            if (_episodeCount > 40) {
              expect(metrics['mountedEpisodeFocusNodes'], 1);
            }
          }),
        );
      }
      final exception = tester.takeException();
      expect(exception, isNull);
      // ignore: avoid_print
      print('TVBRO_LOW_END_PERFORMANCE ${jsonEncode(metrics)}');
    },
    skip: !Platform.isAndroid,
    timeout: const Timeout(Duration(minutes: 15)),
  );
}

List<Channel> _fixtureChannels(int count) => [
  for (var i = 0; i < count; i++)
    Channel(
      id: 'fixture-$i',
      name: 'Channel ${i.toString().padLeft(5, '0')}',
      number: i + 1,
      categoryId: '${i % 50}',
      archiveDays: 7,
      extra: {'url': 'https://stream.invalid/$i.ts', 'tvgId': 'fixture-$i'},
    ),
];

Stream<List<Programme>> _fixtureProgrammes(DateTime anchor) async* {
  var batch = <Programme>[];
  for (var channel = 0; channel < _channelCount; channel++) {
    for (var slot = 0; slot < _programmesPerChannel; slot++) {
      final start = anchor.add(Duration(hours: (slot - 1) * 6));
      batch.add(
        Programme(
          channelId: 'fixture-$channel',
          start: start,
          stop: start.add(const Duration(hours: 6)),
          title: 'Fixture programme $channel-$slot',
          description: 'Synthetic guide entry. No provider data.',
        ),
      );
      if (batch.length == 1000) {
        yield batch;
        batch = <Programme>[];
      }
    }
  }
  if (batch.isNotEmpty) yield batch;
}

class _FixtureSource extends DemoSource {
  _FixtureSource() : super(sourceId: _fixtureId);
  int resolveCalls = 0;
  @override
  Future<List<Channel>> channels({String? categoryId}) async =>
      throw StateError(
        'The synthetic channel cache should already be populated.',
      );
  @override
  Future<List<Programme>> epg(List<Channel> channels) async =>
      throw StateError('The synthetic guide cache should already be fresh.');
  @override
  Future<StreamInfo> resolve(Channel channel) async {
    resolveCalls++;
    throw StateError('Playback is outside this workload.');
  }
}

class _EmptyStore extends SourceStore {
  @override
  Future<List<SourceConfig>> list() async => const [];
}

class _SandboxPaths extends PathProviderPlatform {
  _SandboxPaths(this.native, this.supportPath);
  final PathProviderPlatform native;
  final String supportPath;

  @override
  Future<String?> getApplicationSupportPath() async => supportPath;
  @override
  Future<String?> getTemporaryPath() => native.getTemporaryPath();
  @override
  Future<String?> getLibraryPath() => native.getLibraryPath();
  @override
  Future<String?> getApplicationDocumentsPath() =>
      native.getApplicationDocumentsPath();
  @override
  Future<String?> getApplicationCachePath() => native.getApplicationCachePath();
  @override
  Future<String?> getExternalStoragePath() => native.getExternalStoragePath();
  @override
  Future<List<String>?> getExternalCachePaths() =>
      native.getExternalCachePaths();
  @override
  Future<List<String>?> getExternalStoragePaths({StorageDirectory? type}) =>
      native.getExternalStoragePaths(type: type);
  @override
  Future<String?> getDownloadsPath() => native.getDownloadsPath();
}

class _ObservedRepository extends LibraryRepository {
  _ObservedRepository({required super.source, required super.db})
    : super(autoEnrichMetadata: false);
  final firstLoad = Completer<void>();
  final firstGuide = Completer<void>();
  int nowNextCalls = 0;
  int maximumWindowIds = 0;
  @override
  Future<LibrarySnapshot> load({bool forceRefresh = false}) async {
    final snapshot = await super.load(forceRefresh: forceRefresh);
    if (!firstLoad.isCompleted) firstLoad.complete();
    return snapshot;
  }

  @override
  Future<({Map<String, Programme> now, Map<String, Programme> next})> nowNext({
    List<String>? channelIds,
  }) async {
    nowNextCalls++;
    final count = channelIds?.length ?? _channelCount;
    if (count > maximumWindowIds) maximumWindowIds = count;
    final guide = await super.nowNext(channelIds: channelIds);
    if (!firstGuide.isCompleted && guide.now.isNotEmpty) firstGuide.complete();
    return guide;
  }
}

class _EpisodeRepository extends LibraryRepository {
  _EpisodeRepository({required super.source, required super.db})
    : super(autoEnrichMetadata: false);
  final seasonsReady = Completer<void>();
  final episodesReady = Completer<void>();
  final requestedKinds = <ContentKind>[];
  @override
  Future<ExternalMetadata?> cachedExternalMetadata(
    MediaItem item,
    String provider,
  ) async => null;
  @override
  Future<MediaLibrarySnapshot> loadMedia(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    bool forceRefresh = false,
    bool enrichChildren = true,
  }) async {
    requestedKinds.add(kind);
    if (kind != ContentKind.season && kind != ContentKind.episode) {
      throw StateError('Unexpected episode workload request: ${kind.name}');
    }
    final items = kind == ContentKind.season
        ? [
            const MediaItem(
              id: 'season',
              title: 'Season 1',
              kind: ContentKind.season,
              parentId: 'series',
              seasonNumber: 1,
            ),
          ]
        : [
            for (var i = 0; i < _episodeCount; i++)
              MediaItem(
                id: 'episode-$i',
                title: 'Episode $i',
                kind: ContentKind.episode,
                parentId: 'season',
                episodeNumber: i + 1,
                seasonNumber: 1,
              ),
          ];
    final observer = kind == ContentKind.season ? seasonsReady : episodesReady;
    if (!observer.isCompleted) observer.complete();
    return MediaLibrarySnapshot(
      kind: kind,
      parentId: parent?.id,
      categories: const [],
      items: items,
      fromCache: true,
      syncedAt: DateTime.now(),
    );
  }
}

void _focusChannels(WidgetTester tester) {
  final focus = tester
      .widgetList<Focus>(find.byType(Focus))
      .firstWhere(
        (widget) => focusRouteKey(widget.focusNode) == 'live.channels',
      );
  focus.focusNode!.requestFocus();
}

Future<void> _navigate(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < _keyEvents; i++) {
    final down = i < (_keyEvents * 3 ~/ 4);
    final key = down
        ? LogicalKeyboardKey.arrowDown
        : LogicalKeyboardKey.arrowUp;
    await tester.sendKeyEvent(
      key,
      physicalKey: down
          ? PhysicalKeyboardKey.arrowDown
          : PhysicalKeyboardKey.arrowUp,
      platform: 'android',
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(focusRouteKey(FocusManager.instance.primaryFocus), 'live.channels');
}

Future<void> _measure(
  WidgetTester tester,
  String phase,
  List<Map<String, Object?>> phases,
  Future<void> Function() action,
) async {
  final binding = tester.binding;
  final frames = <FrameTiming>[];
  binding.addTimingsCallback(frames.addAll);
  await tester.pump();
  final startFrame = binding.currentSystemFrameTimeStamp.inMicroseconds;
  final watch = Stopwatch()..start();
  final rssBefore = ProcessInfo.currentRss;
  var sampledPeak = rssBefore;
  var lastTick = 0;
  var longestTickGap = 0;
  final sampler = Timer.periodic(const Duration(milliseconds: 250), (_) {
    final rss = ProcessInfo.currentRss;
    if (rss > sampledPeak) sampledPeak = rss;
    final tick = watch.elapsedMicroseconds;
    final gap = tick - lastTick;
    if (gap > longestTickGap) longestTickGap = gap;
    lastTick = tick;
  });
  var succeeded = false;
  int? actionElapsedMs;
  try {
    await action();
    actionElapsedMs = watch.elapsedMilliseconds;
    await tester.pump(const Duration(milliseconds: 300));
    succeeded = true;
  } finally {
    actionElapsedMs ??= watch.elapsedMilliseconds;
    watch.stop();
    sampler.cancel();
    final rssAfter = ProcessInfo.currentRss;
    if (rssAfter > sampledPeak) sampledPeak = rssAfter;
    final endFrame = binding.currentSystemFrameTimeStamp.inMicroseconds;
    // Engine timing reports can be batched for about one second. This is a
    // bounded flush, not polling; timestamps exclude these drain-only frames.
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    binding.removeTimingsCallback(frames.addAll);
    final measured = frames.where((frame) {
      final stamp = frame.timestampInMicroseconds(FramePhase.buildStart);
      return stamp >= startFrame && stamp <= endFrame;
    }).toList();
    final budget = 1000000 / tester.view.display.refreshRate;
    Map<String, Object?> summary(Iterable<int> values) {
      final sorted = values.toList()..sort();
      int? percentile(double p) =>
          sorted.isEmpty ? null : sorted[((sorted.length - 1) * p).round()];
      return {
        'p50Us': percentile(.5),
        'p95Us': percentile(.95),
        'p99Us': percentile(.99),
        'maxUs': sorted.isEmpty ? null : sorted.last,
      };
    }

    final result = <String, Object?>{
      'phase': phase,
      'status': succeeded ? 'completed' : 'failed',
      'actionElapsedMs': actionElapsedMs,
      'phaseElapsedMs': watch.elapsedMilliseconds,
      'settleRequestedMs': 300,
      'settleElapsedMs': watch.elapsedMilliseconds - actionElapsedMs,
      'frameCount': measured.length,
      'build': summary(measured.map((f) => f.buildDuration.inMicroseconds)),
      'raster': summary(measured.map((f) => f.rasterDuration.inMicroseconds)),
      'total': summary(measured.map((f) => f.totalSpan.inMicroseconds)),
      'framesOverRefreshBudget': measured
          .where(
            (f) =>
                f.buildDuration.inMicroseconds > budget ||
                f.rasterDuration.inMicroseconds > budget,
          )
          .length,
      'framesOver33ms': measured
          .where((f) => f.totalSpan.inMicroseconds > 33333)
          .length,
      'framesOver100ms': measured
          .where((f) => f.totalSpan.inMicroseconds > 100000)
          .length,
      'rssBeforeBytes': rssBefore,
      'rssAfterBytes': rssAfter,
      'sampledPeakRssBytes': sampledPeak,
      'processLifetimeMaxRssBytes': ProcessInfo.maxRss,
      'rssSampleIntervalMs': 250,
      'maxMainIsolateTimerGapUs': longestTickGap,
    };
    phases.add(result);
    // ignore: avoid_print
    print('TVBRO_LOW_END_PHASE ${jsonEncode(result)}');
  }
}
