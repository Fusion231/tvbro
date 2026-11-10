import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/epg_ingest.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/data/source_store.dart';
import 'package:iptvs/player/player_screen.dart';
import 'package:iptvs/screens/channel_list_screen.dart';
import 'package:iptvs/screens/epg_mapping_screen.dart';
import 'package:iptvs/screens/favorites_tab_view.dart';
import 'package:iptvs/screens/live_tab_view.dart';
import 'package:iptvs/sources/demo_source.dart';
import 'package:iptvs/sources/epg_mapping.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/source_config.dart';
import 'package:iptvs/widgets/routed_focus_node.dart';

/// Exercises the real cached LibraryRepository.load path. Count channel models
/// materialized by its database boundary instead of timing an in-memory fixture.
class _HomeDatabase implements AppDatabase {
  final _cacheIdentities = <String, String>{};

  @override
  Future<bool> migrateSourceCacheIdentity(
    String sourceId,
    String name,
    String identity, {
    bool onlyIfUnknown = false,
  }) async {
    final current = _cacheIdentities[sourceId];
    if (onlyIfUnknown && current != null) return current == identity;
    _cacheIdentities[sourceId] = identity;
    return true;
  }

  @override
  Future<bool> sourceCacheIdentityMatches(
    String sourceId,
    String identity,
  ) async => _cacheIdentities[sourceId] == identity;

  int channelReads = 0;
  int channelModels = 0;
  int guideReads = 0;
  bool guideStale = false;
  String revision = 'cached';
  final favoriteRows = <({String sourceId, Channel channel})>[];
  final programmes = <String, Programme>{};

  @override
  final epgIngest = EpgIngestCoordinator();

  @override
  Stream<String> get epgChanged => const Stream.empty();

  @override
  Stream<void> get favoritesReplaced => const Stream.empty();

  @override
  Stream<void> get favoritesChanged => const Stream.empty();

  @override
  Stream<void> get playbackPositionsReplaced => const Stream.empty();

  @override
  Future<DateTime?> lastSynced(String sourceId) async => DateTime.now();

  @override
  Future<DateTime?> lastEpgSynced(String sourceId) async => guideStale
      ? DateTime.now().subtract(const Duration(days: 1))
      : DateTime.now();

  @override
  Future<List<Channel>> readChannels(String sourceId) async {
    channelReads++;
    const count = 50000;
    channelModels += count;
    return [
      for (var i = 0; i < count; i++)
        Channel(
          id: '$sourceId-$i',
          name: '$revision Channel $i',
          number: i + 1,
        ),
    ];
  }

  @override
  Future<List<Category>> readCategories(String sourceId) async => const [];

  @override
  Future<List<MediaCategory>> readMediaCategories(
    String sourceId,
    ContentKind kind,
  ) async => const [];

  @override
  Future<({Map<String, Programme> now, Map<String, Programme> next})>
  nowNextForChannels(
    String sourceId,
    List<String> channelIds,
    DateTime at,
  ) async {
    guideReads++;
    return (
      now: {for (final id in channelIds) id: ?programmes[id]},
      next: <String, Programme>{},
    );
  }

  @override
  Future<Set<String>> readFavoriteIds(
    String sourceId,
    ContentKind kind,
  ) async => kind == ContentKind.live
      ? {
          for (final row in favoriteRows)
            if (row.sourceId == sourceId) row.channel.id,
        }
      : {};

  @override
  Future<List<({String sourceId, Channel channel})>>
  readFavoriteChannelsAcrossSources() async => List.of(favoriteRows);

  @override
  Future<Channel> revealChannel(Channel channel) async => channel;

  @override
  Future<void> replaceEpg(
    String sourceId,
    Iterable<Programme> programmes, {
    Iterable<EpgGuideChannel>? guideChannels,
    String? expectedCacheIdentity,
  }) async {
    guideStale = false;
  }

  @override
  void notifyEpgChanged(String sourceId) {}

  @override
  Future<List<PlaybackPosition>> readRecentPositions(
    String sourceId, {
    int limit = 20,
  }) async => [];

  @override
  Future<List<EpgChannelOverride>> readEpgMappings(String sourceId) async => [];

  @override
  Future<List<EpgGuideChannel>> readEpgGuideChannels(String sourceId) async =>
      [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _HomeSource extends DemoSource {
  _HomeSource(String id) : super(sourceId: id);

  int connections = 0;
  int guideRequests = 0;
  final resolved = <String>[];

  @override
  Future<void> connect() async => connections++;

  @override
  Future<List<Programme>> epg(List<Channel> channels) async {
    guideRequests++;
    return [];
  }

  @override
  Future<StreamInfo> resolve(Channel channel) async {
    resolved.add(channel.id);
    return StreamInfo(url: 'https://example.test/${channel.id}', isLive: true);
  }
}

class _HomeConfig extends SourceConfig {
  _HomeConfig(this.source)
    : super(
        id: source.id,
        kind: SourceKind.demo,
        label: source.id,
        fields: const {},
      );

  final Source source;

  @override
  Source build() => source;
}

class _HomeStore extends SourceStore {
  List<SourceConfig> sources = [];

  @override
  Future<List<SourceConfig>> list() async => sources;
}

/// Inspect live-route arguments without building a playback engine.
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

class _HomeRepository extends LibraryRepository {
  _HomeRepository(String id, _HomeDatabase db)
    : super(source: _HomeSource(id), db: db, autoEnrichMetadata: false);

  final changes = StreamController<ContentKind>.broadcast(sync: true);
  final mediaLoads = <ContentKind>[];
  Future<void>? heldEpgRefresh;

  @override
  Future<void>? get pendingEpgRefresh => heldEpgRefresh ?? super.pendingEpgRefresh;

  @override
  Stream<ContentKind> get catalogChanged => changes.stream;

  @override
  Future<MediaLibrarySnapshot> loadMedia(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    bool forceRefresh = false,
    bool enrichChildren = true,
  }) async {
    mediaLoads.add(kind);
    return MediaLibrarySnapshot(
      kind: kind,
      categories: const [],
      items: [MediaItem(id: 'movie', title: 'Cached movie', kind: kind)],
      fromCache: true,
      syncedAt: DateTime.now(),
    );
  }
}

void main() {
  late _HomeDatabase db;
  late _HomeRepository repo;
  late _HomeStore store;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    debugDisableNetworkChannelLogos = true;
    db = _HomeDatabase();
    repo = _HomeRepository('home-source', db);
    store = _HomeStore()..sources = [_HomeConfig(repo.source)];
  });

  tearDown(() async {
    debugDisableNetworkChannelLogos = false;
    await repo.changes.close();
  });

  Future<void> pumpScreen(
    WidgetTester tester, {
    Future<void> Function()? refresh,
    Future<void> Function()? onBeforeSourcePreferences,
    VoidCallback? onSourcePreferencesChanged,
    _PlayerObserver? observer,
  }) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: observer == null ? [] : [observer],
        home: ChannelListScreen(
          repo: repo,
          config: SourceConfig(
            id: repo.source.id,
            kind: SourceKind.demo,
            label: 'Home source',
            fields: const {},
          ),
          store: store,
          onRefreshSource: refresh,
          onBeforeSourcePreferences: onBeforeSourcePreferences,
          onSourcePreferencesChanged: onSourcePreferencesChanged,
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> openSection(WidgetTester tester, ContentKind kind) async {
    final home = find.byTooltip('Home');
    if (home.evaluate().isNotEmpty) {
      await tester.tap(home);
      await tester.pump();
    }
    await tester.ensureVisible(find.byKey(ValueKey('home-${kind.name}')));
    await tester.tap(find.byKey(ValueKey('home-${kind.name}')));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('Home to Movies skips the 50k live cache until TV is selected', (
    tester,
  ) async {
    try {
      await pumpScreen(tester);
      final homeModels = db.channelModels;
      final homeGuideReads = db.guideReads;
      expect(find.byKey(const ValueKey('home-live')), findsOneWidget);
      expect(find.byKey(const ValueKey('home-movie')), findsOneWidget);
      expect(find.byKey(const ValueKey('home-series')), findsOneWidget);
      expect(
        focusRouteKey(FocusManager.instance.primaryFocus),
        'content.tab.live',
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(
        focusRouteKey(FocusManager.instance.primaryFocus),
        'content.tab.movie',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump();
      final movieModels = db.channelModels;
      final movieGuideReads = db.guideReads;
      expect(find.text('Cached movie'), findsWidgets);

      await openSection(tester, ContentKind.live);
      final tvModels = db.channelModels;
      expect(find.text('cached Channel 0'), findsWidgets);
      expect(
        focusRouteKey(FocusManager.instance.primaryFocus),
        'live.channels',
      );
      await openSection(tester, ContentKind.live);

      // Operation counts are the claim; this is not a SQLite latency benchmark.
      debugPrint(
        'HOME_LOAD_WORK ${jsonEncode({'fixtureChannels': 50000, 'homeModels': homeModels, 'movieModels': movieModels, 'tvModels': tvModels, 'homeGuideReads': homeGuideReads, 'movieGuideReads': movieGuideReads})}',
      );
      expect(homeModels, 0);
      expect(movieModels, 0);
      expect(homeGuideReads, 0);
      expect(movieGuideReads, 0);
      expect(tvModels, 50000);
      expect(
        db.channelReads,
        1,
        reason: 'returning to TV reuses its controller',
      );
      expect(repo.mediaLoads, [ContentKind.movie]);
      final source = repo.source as _HomeSource;
      expect(source.connections, 0);
      expect(source.guideRequests, 0);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('guide timers follow TV visibility and app lifecycle', (
    tester,
  ) async {
    await pumpScreen(tester);
    await openSection(tester, ContentKind.live);
    await tester.pump();
    final initialReads = db.guideReads;
    expect(initialReads, greaterThan(0));
    await tester.pump(const Duration(minutes: 1));
    expect(db.guideReads, initialReads + 1);

    await tester.tap(find.byTooltip('Home'));
    await tester.pump();
    final homeReads = db.guideReads;
    await tester.pump(const Duration(minutes: 2));
    expect(db.guideReads, homeReads);
    await openSection(tester, ContentKind.movie);
    await tester.pump(const Duration(minutes: 2));
    expect(db.guideReads, homeReads);

    await openSection(tester, ContentKind.live);
    await tester.pump();
    expect(db.guideReads, homeReads + 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(minutes: 2));
    expect(db.guideReads, homeReads + 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(db.guideReads, homeReads + 2);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a catalog change on Home is read when TV is first opened', (
    tester,
  ) async {
    try {
      await pumpScreen(tester);
      db.revision = 'refreshed';
      repo.changes.add(ContentKind.live);
      await tester.pump();
      final homeReads = db.channelReads;
      await openSection(tester, ContentKind.live);

      expect(homeReads, 0);
      expect(db.channelReads, 1);
      expect(find.text('refreshed Channel 0'), findsWidgets);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('Home refresh remains available before the first TV visit', (
    tester,
  ) async {
    var refreshes = 0;
    try {
      await pumpScreen(tester, refresh: () async => refreshes++);
      await tester.tap(find.byTooltip('Menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Refresh'));
      await tester.pump();

      expect(refreshes, 1);
      expect(db.channelReads, 0);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('Home settings pauses source sync until the panel is closed', (
    tester,
  ) async {
    var pauses = 0;
    var resumes = 0;
    final epgRefresh = Completer<void>();
    try {
      await pumpScreen(
        tester,
        onBeforeSourcePreferences: () async {
          pauses++;
        },
        onSourcePreferencesChanged: () => resumes++,
      );
      await tester.tap(find.byTooltip('Menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('app-settings-panel')), findsOneWidget);
      expect(pauses, 1);
      expect(resumes, 0);
      expect(db.channelReads, 0);

      await tester.tap(find.text('Source settings'));
      await tester.pumpAndSettle();
      expect(find.text('Organize channels'), findsOneWidget);
      expect(pauses, 1);
      expect(resumes, 0);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('app-settings-panel')), findsOneWidget);
      expect(pauses, 1);
      expect(resumes, 0);

      repo.heldEpgRefresh = epgRefresh.future;
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('app-settings-panel')), findsNothing);
      expect(pauses, 1);
      expect(resumes, 0);

      epgRefresh.complete();
      await tester.pumpAndSettle();

      expect(resumes, 1);
      expect(db.channelReads, 0);
      expect(tester.takeException(), isNull);
    } finally {
      if (!epgRefresh.isCompleted) {
        epgRefresh.complete();
      }
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('Home settings keeps EPG mapping lazy until explicitly opened', (
    tester,
  ) async {
    try {
      await pumpScreen(tester);
      await tester.tap(find.byTooltip('Menu'));
      await tester.pumpAndSettle();
      expect(find.text('Diagnostics'), findsNothing);
      expect(find.text('Correct EPG / channel matching'), findsNothing);
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      expect(db.channelReads, 0);
      expect(find.text('Channels & EPG'), findsOneWidget);
      expect(find.text('Source settings'), findsOneWidget);
      await tester.tap(find.text('EPG mapping'));
      await tester.pumpAndSettle();

      final mapping = tester.widget<EpgMappingScreen>(
        find.byType(EpgMappingScreen),
      );
      expect(mapping.channels, hasLength(50000));
      expect(db.channelReads, 1);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('Home and Movies do not fetch an overdue guide', (tester) async {
    db.guideStale = true;
    try {
      await pumpScreen(tester);
      await openSection(tester, ContentKind.movie);

      final source = repo.source as _HomeSource;
      expect(db.channelReads, 0);
      expect(db.guideReads, 0);
      expect(source.connections, 0);
      expect(source.guideRequests, 0);
      expect(repo.pendingEpgRefresh, isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await db.epgIngest.cancelAndWait();
    }
  });

  for (final liveOpen in [false, true]) {
    testWidgets(
      'source replacement reloads only active TV, liveOpen=$liveOpen',
      (tester) async {
        final previousRepo = repo;
        final previousDb = db;
        try {
          await pumpScreen(tester);
          await openSection(
            tester,
            liveOpen ? ContentKind.live : ContentKind.movie,
          );
          db = _HomeDatabase()..revision = 'new source';
          repo = _HomeRepository('new-source', db);
          await pumpScreen(tester);

          expect(previousDb.channelReads, liveOpen ? 1 : 0);
          expect(db.channelReads, liveOpen ? 1 : 0);
          if (!liveOpen) await openSection(tester, ContentKind.live);
          expect(db.channelReads, 1);
          expect(find.text('new source Channel 0'), findsWidgets);
          expect(
            focusRouteKey(FocusManager.instance.primaryFocus),
            'live.channels',
          );
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await previousRepo.changes.close();
        }
      },
    );
  }

  testWidgets(
    'same-source repository replacement on Home defers media loading',
    (tester) async {
      final previousRepo = repo;
      try {
        await pumpScreen(tester);
        await openSection(tester, ContentKind.movie);
        expect(previousRepo.mediaLoads, [ContentKind.movie]);
        await tester.tap(find.byTooltip('Home'));
        await tester.pump();
        final previousState = tester.state(find.byType(ChannelListScreen));

        // HomeShell keeps the same source-id key for a settings/metadata rebind.
        repo = _HomeRepository(previousRepo.source.id, db);
        await pumpScreen(tester);

        expect(
          tester.state(find.byType(ChannelListScreen)),
          same(previousState),
        );
        expect(find.byKey(const ValueKey('home-movie')), findsOneWidget);
        expect(repo.mediaLoads, isEmpty);
        expect(db.channelReads, 0);

        await openSection(tester, ContentKind.movie);
        expect(repo.mediaLoads, [ContentKind.movie]);
        expect(find.text('Cached movie'), findsWidgets);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await previousRepo.changes.close();
      }
    },
  );

  for (final foreign in [false, true]) {
    testWidgets(
      'Home Favorites plays its owner without loading Live, foreign=$foreign',
      (tester) async {
        final owner = foreign
            ? _HomeSource('foreign')
            : repo.source as _HomeSource;
        final channel = Channel(id: '${owner.id}-saved', name: 'Saved channel');
        db.favoriteRows.add((sourceId: owner.id, channel: channel));
        final now = DateTime.now();
        db.programmes[channel.id] = Programme(
          channelId: channel.id,
          start: now.subtract(const Duration(minutes: 10)),
          stop: now.add(const Duration(minutes: 10)),
          title: 'Saved programme',
        );
        store.sources = [
          _HomeConfig(repo.source),
          if (foreign) _HomeConfig(owner),
        ];
        final observer = _PlayerObserver();
        FakeAsync? playbackClock;
        try {
          await pumpScreen(tester, observer: observer);
          await tester.tap(find.byKey(const ValueKey('home-favorites')));
          await tester.pump();
          await tester.pump();
          final favorites = tester.widget<FavoritesTabView>(
            find.byType(FavoritesTabView),
          );
          // Own the catalog timer without pumping the unbuilt player route
          // into a real media engine in this host navigation test.
          final clock = FakeAsync();
          playbackClock = clock;
          clock.run((_) => favorites.onPlayChannel(favorites.channels.single));
          clock.flushMicrotasks();
          await tester.idle();

          expect(observer.playerRoute, isNotNull);
          final player = observer.player(
            tester.element(find.byType(ChannelListScreen)),
          );
          expect(player.sourceName, owner.name);
          expect(player.favoriteInitial, isTrue);
          expect(player.epgNow?.title, 'Saved programme');
          final zap = player.zap!;
          expect(zap.catalog.epgFor(zap.current).now?.title, 'Saved programme');
          expect(zap.catalog.isFavorite(zap.current), isTrue);
          expect(await zap.catalog.quickListCategories(), hasLength(2));
          expect(owner.resolved, [channel.id]);
          expect(db.channelReads, 0);

          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
          tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
          tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
          final playingReads = db.guideReads;
          clock.elapse(const Duration(minutes: 1));
          clock.flushMicrotasks();
          expect(db.guideReads, playingReads + 1);

          observer.navigator!.pop();
          clock.flushMicrotasks();
          final closedReads = db.guideReads;
          clock.elapse(const Duration(minutes: 2));
          expect(db.guideReads, closedReads);
          expect(clock.periodicTimerCount, 0);
        } finally {
          if (observer.playerRoute?.isCurrent == true) {
            observer.navigator!.pop();
            playbackClock?.flushMicrotasks();
            await tester.idle();
          }
          if (tester.binding.lifecycleState == AppLifecycleState.paused) {
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.hidden,
            );
          }
          if (tester.binding.lifecycleState == AppLifecycleState.hidden) {
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.inactive,
            );
          }
          if (tester.binding.lifecycleState == AppLifecycleState.inactive) {
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.resumed,
            );
          }
          await tester.pumpWidget(const SizedBox.shrink());
        }
      },
    );
  }
}
