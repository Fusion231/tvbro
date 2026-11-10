import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/data/source_store.dart';
import 'package:iptvs/player/player_screen.dart';
import 'package:iptvs/screens/channel_list_screen.dart';
import 'package:iptvs/screens/live_preview_controller.dart';
import 'package:iptvs/screens/live_tab_view.dart';
import 'package:iptvs/sources/demo_source.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/source_config.dart';

typedef _NowNext = ({Map<String, Programme> now, Map<String, Programme> next});

class _StartupDatabase implements AppDatabase {
  @override
  Stream<String> get epgChanged => const Stream.empty();

  @override
  Stream<void> get favoritesReplaced => const Stream.empty();
  @override
  Stream<void> get playbackPositionsReplaced => const Stream.empty();

  @override
  Future<Set<String>> readFavoriteIds(
    String sourceId,
    ContentKind kind,
  ) async => {};

  @override
  Future<List<({String sourceId, Channel channel})>>
  readFavoriteChannelsAcrossSources() async => [];

  @override
  Future<List<PlaybackPosition>> readRecentPositions(
    String sourceId, {
    int limit = 20,
  }) async => [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StartupRepository extends LibraryRepository {
  _StartupRepository() : super(source: DemoSource(), db: _StartupDatabase());

  final channels = [
    for (var i = 0; i < 100; i++)
      Channel(id: 'ch$i', name: 'Channel $i', number: i + 1),
  ];
  final guide = Completer<_NowNext>();
  final resolved = <String>[];
  final guideReads = <List<String>>[];
  final blockedIds = <String>{};
  final pendingStreams = <String, Completer<StreamInfo>>{};

  @override
  Future<LibrarySnapshot> load({bool forceRefresh = false}) async =>
      LibrarySnapshot(
        categories: const [],
        channels: channels,
        fromCache: true,
        syncedAt: DateTime.now(),
      );

  @override
  Future<_NowNext> nowNext({List<String>? channelIds}) {
    final ids = channelIds ?? channels.map((channel) => channel.id).toList();
    guideReads.add(List.of(ids));
    if (ids.any(blockedIds.contains)) return guide.future;
    return Future.value((
      now: <String, Programme>{},
      next: <String, Programme>{},
    ));
  }

  @override
  Future<StreamInfo> resolve(Channel channel) async {
    resolved.add(channel.id);
    final pending = pendingStreams[channel.id];
    if (pending != null) return pending.future;
    return StreamInfo(
      url: 'https://example.test/${channel.id}.m3u8',
      isLive: true,
    );
  }

  @override
  Future<MediaLibrarySnapshot> loadMedia(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    bool forceRefresh = false,
    bool enrichChildren = true,
  }) async => MediaLibrarySnapshot(
    kind: kind,
    categoryId: categoryId,
    categories: const [],
    items: const [],
    fromCache: true,
    syncedAt: DateTime.now(),
  );
}

/// Inspect the pushed route without building a playback engine or opening a URL.
class _PlayerObserver extends NavigatorObserver {
  PageRouteBuilder<dynamic>? playerRoute;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PageRouteBuilder) playerRoute = route;
  }

  PlayerScreen player(BuildContext context) => playerRoute!.pageBuilder(
    context,
    const AlwaysStoppedAnimation(1),
    const AlwaysStoppedAnimation(0),
  ) as PlayerScreen;
}

void main() {
  const config = SourceConfig(
    id: 'demo',
    kind: SourceKind.demo,
    label: 'Demo',
    fields: {},
  );

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    debugDisableNetworkChannelLogos = true;
  });

  tearDown(() => debugDisableNetworkChannelLogos = false);

  Future<LiveTabView> openList(
    WidgetTester tester,
    _StartupRepository repo,
    _PlayerObserver observer, {
    bool wide = false,
  }) async {
    tester.view.physicalSize = wide
        ? const Size(1600, 900)
        : const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [observer],
        home: ChannelListScreen(
          repo: repo,
          config: config,
          store: SourceStore(),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('home-live')));
    await tester.pump();
    return tester.widget<LiveTabView>(find.byType(LiveTabView));
  }

  Future<void> closeList(
    WidgetTester tester,
    _StartupRepository repo,
    _PlayerObserver observer,
  ) async {
    for (final entry in repo.pendingStreams.entries) {
      if (!entry.value.isCompleted) {
        entry.value.complete(
          StreamInfo(
            url: 'https://example.test/${entry.key}.m3u8',
            isLive: true,
          ),
        );
      }
    }
    if (!repo.guide.isCompleted) {
      repo.guide.complete((
        now: <String, Programme>{},
        next: <String, Programme>{},
      ));
    }
    await tester.idle();
    if (observer.playerRoute?.isCurrent == true) {
      observer.navigator!.pop();
      await tester.idle();
    }
    await tester.pumpWidget(const SizedBox.shrink());
  }

  for (final destination in [
    'Home',
    'Movies',
    'replacement source',
    'dispose',
  ]) {
    testWidgets('$destination abandons a pending live stream open', (
      tester,
    ) async {
      final repo = _StartupRepository();
      final observer = _PlayerObserver();
      final pending = repo.pendingStreams['ch0'] = Completer<StreamInfo>();
      final tab = await openList(tester, repo, observer);
      final originalState = tester.state(find.byType(ChannelListScreen));
      try {
        tab.onPlayChannel(repo.channels.first);
        await tester.idle();
        expect(repo.resolved, ['ch0']);
        expect(observer.playerRoute, isNull);

        if (destination == 'replacement source') {
          await tester.pumpWidget(
            MaterialApp(
              navigatorObservers: [observer],
              home: ChannelListScreen(
                repo: _StartupRepository(),
                config: config,
                store: SourceStore(),
              ),
            ),
          );
          expect(
            tester.state(find.byType(ChannelListScreen)),
            same(originalState),
          );
        } else if (destination == 'dispose') {
          await tester.pumpWidget(const SizedBox.shrink());
        } else {
          await tester.tap(find.byTooltip('Home'));
          await tester.pump();
          expect(find.byKey(const ValueKey('home-live')), findsOneWidget);
          if (destination == 'Movies') {
            await tester.tap(find.byKey(const ValueKey('home-movie')));
            await tester.pump();
          }
        }

        pending.complete(
          const StreamInfo(url: 'https://example.test/ch0.m3u8', isLive: true),
        );
        // Observe navigation before a new route could build a playback engine.
        await tester.idle();
        expect(
          observer.playerRoute,
          isNull,
          reason: 'Leaving the playback request must discard its late reply.',
        );
        expect(tester.takeException(), isNull);
      } finally {
        await closeList(tester, repo, observer);
      }
    });
  }

  testWidgets('a cancelled live failure stays silent after Home', (
    tester,
  ) async {
    final repo = _StartupRepository();
    final observer = _PlayerObserver();
    final pending = repo.pendingStreams['ch0'] = Completer<StreamInfo>();
    final tab = await openList(tester, repo, observer);
    try {
      tab.onPlayChannel(repo.channels.first);
      await tester.idle();
      await tester.tap(find.byTooltip('Home'));
      await tester.pump();

      pending.completeError(StateError('cancelled-provider-error'));
      await tester.pump();

      expect(observer.playerRoute, isNull);
      expect(find.textContaining('cancelled-provider-error'), findsNothing);
      expect(find.byKey(const ValueKey('home-live')), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await closeList(tester, repo, observer);
    }
  });

  testWidgets('a cancelled live reply does not clear a newer open', (
    tester,
  ) async {
    final repo = _StartupRepository();
    final observer = _PlayerObserver();
    final first = repo.pendingStreams['ch0'] = Completer<StreamInfo>();
    final second = repo.pendingStreams['ch1'] = Completer<StreamInfo>();
    var tab = await openList(tester, repo, observer);
    try {
      tab.onPlayChannel(repo.channels.first);
      await tester.idle();
      await tester.tap(find.byTooltip('Home'));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('home-live')));
      await tester.pump();
      tab = tester.widget<LiveTabView>(find.byType(LiveTabView));
      tab.onPlayChannel(repo.channels[1]);
      await tester.pump();
      expect(repo.resolved, ['ch0', 'ch1']);

      first.complete(
        const StreamInfo(url: 'https://example.test/ch0.m3u8', isLive: true),
      );
      await tester.pump();
      expect(observer.playerRoute, isNull);
      expect(
        tester.widget<LiveTabView>(find.byType(LiveTabView)).resolving,
        isTrue,
      );

      second.complete(
        const StreamInfo(url: 'https://example.test/ch1.m3u8', isLive: true),
      );
      await tester.idle();
      expect(observer.playerRoute, isNotNull);
      expect(
        observer.player(tester.element(find.byType(ChannelListScreen))).title,
        repo.channels[1].name,
      );
    } finally {
      await closeList(tester, repo, observer);
    }
  });

  testWidgets('live open proceeds while the target guide read is stalled', (
    tester,
  ) async {
    final repo = _StartupRepository();
    final observer = _PlayerObserver();
    final tab = await openList(tester, repo, observer);
    final channel = repo.channels[98];
    repo.blockedIds.add(channel.id);
    try {
      tab.onPlayChannel(channel);
      await tester.idle();

      expect(repo.guideReads.any((ids) => ids.contains(channel.id)), isTrue);
      expect(repo.guide.isCompleted, isFalse);
      expect(repo.resolved, [channel.id]);
      expect(observer.playerRoute, isNotNull);
      final player = observer.player(
        tester.element(find.byType(ChannelListScreen)),
      );
      final zap = player.zap!;
      expect(zap.bannerPayload()['epgNowTitle'], isNull);

      final at = DateTime.now();
      repo.guide.complete((
        now: {
          channel.id: Programme(
            channelId: channel.id,
            start: at.subtract(const Duration(minutes: 10)),
            stop: at.add(const Duration(minutes: 20)),
            title: 'Guide arrived later',
          ),
        },
        next: <String, Programme>{},
      ));
      await tester.idle();

      expect(zap.bannerPayload()['epgNowTitle'], 'Guide arrived later');
      expect(repo.resolved, [
        channel.id,
      ], reason: 'guide arrival must not reopen');
    } finally {
      await closeList(tester, repo, observer);
    }
  });

  testWidgets('ready preview hands off without waiting for its guide', (
    tester,
  ) async {
    final repo = _StartupRepository();
    final observer = _PlayerObserver();
    final tab = await openList(tester, repo, observer, wide: true);
    final channel = repo.channels[98];
    final preview = (tab.previewVideoBuilder() as PreviewVideo).preview;
    preview.channelId = channel.id;
    preview.stream = const StreamInfo(url: 'https://example.test/already-open');
    repo.blockedIds.add(channel.id);
    try {
      tab.onPlayChannel(channel);
      await tester.idle();

      expect(repo.guideReads.any((ids) => ids.contains(channel.id)), isTrue);
      expect(repo.guide.isCompleted, isFalse);
      expect(observer.playerRoute, isNotNull);
      expect(
        repo.resolved,
        isEmpty,
        reason: 'handoff reuses the resolved stream',
      );
    } finally {
      await closeList(tester, repo, observer);
    }
  });

  testWidgets('zap resolution proceeds while its guide refresh is stalled', (
    tester,
  ) async {
    final repo = _StartupRepository();
    final observer = _PlayerObserver();
    final tab = await openList(tester, repo, observer);
    try {
      tab.onPlayChannel(repo.channels[98]);
      await tester.idle();
      final player = observer.player(
        tester.element(find.byType(ChannelListScreen)),
      );
      final zap = player.zap!;
      repo.blockedIds.add(repo.channels[99].id);

      zap.channelUp();
      var finished = false;
      final resolving = zap.catalog
          .resolve(zap.current)
          .then((_) => finished = true);
      await tester.idle();

      expect(repo.guideReads.any((ids) => ids.contains('ch99')), isTrue);
      expect(repo.guide.isCompleted, isFalse);
      expect(finished, isTrue);
      expect(repo.resolved, ['ch98', 'ch99']);
      await resolving;
    } finally {
      await closeList(tester, repo, observer);
    }
  });
}
