import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/source_store.dart';
import 'package:iptvs/screens/channel_list_screen.dart';
import 'package:iptvs/screens/home_shell.dart';
import 'package:iptvs/screens/live_tab_view.dart';
import 'package:iptvs/sources/demo_source.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/source_config.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const sessionChannel = MethodChannel('iptvs/app_session');
  late _CachedDatabase db;
  late _CachedStore store;
  late GlobalKey<NavigatorState> navigator;
  late bool resetPending;
  late Duration nextReplyDelay;
  late int consumeCalls;

  Future<Object?> sessionReply(MethodCall call) async {
    expect(call.method, 'consumeInactivityReset');
    consumeCalls++;
    final delay = nextReplyDelay;
    nextReplyDelay = Duration.zero;
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    final pending = resetPending;
    resetPending = false;
    return pending;
  }

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    debugDisableNetworkChannelLogos = true;
    db = _CachedDatabase();
    store = _CachedStore();
    navigator = GlobalKey<NavigatorState>();
    resetPending = false;
    nextReplyDelay = Duration.zero;
    consumeCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(sessionChannel, sessionReply);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(sessionChannel, null);
    debugDisableNetworkChannelLogos = false;
  });

  Future<void> showHome(WidgetTester tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: HomeShell(db: db, store: store),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ChannelListScreen), findsOneWidget);
  }

  Future<void> resume(WidgetTester tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  }

  testWidgets('short return preserves the open screen and library session', (
    tester,
  ) async {
    await showHome(tester);
    final library = tester.state(find.byType(ChannelListScreen));
    final initialBuilds = store.config.builds;
    unawaited(
      navigator.currentState!.push<void>(
        MaterialPageRoute(
          builder: (_) => const Scaffold(body: Text('Open details')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final initialCalls = consumeCalls;

    await resume(tester);

    expect(consumeCalls, initialCalls + 1);
    expect(find.text('Open details'), findsOneWidget);
    expect(library.mounted, isTrue);
    expect(store.config.builds, initialBuilds);
    await finish(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('expired return removes stale loading routes after disposal', (
    tester,
  ) async {
    await showHome(tester);
    final library = tester.state(find.byType(ChannelListScreen));
    final initialBuilds = store.config.builds;
    final repo = tester
        .widget<ChannelListScreen>(find.byType(ChannelListScreen))
        .repo;
    final connections = store.config.source.connections;
    bool? libraryMountedWhenRouteReturns;
    unawaited(
      navigator.currentState!
          .push<void>(
            MaterialPageRoute(
              builder: (_) => const Scaffold(body: Text('Stale player loader')),
            ),
          )
          .then((_) {
            libraryMountedWhenRouteReturns = library.mounted;
          }),
    );
    await tester.pumpAndSettle();
    resetPending = true;

    await resume(tester);

    expect(find.text('Stale player loader'), findsNothing);
    expect(library.mounted, isFalse);
    // A late player-route completion must not restart the old live preview.
    expect(libraryMountedWhenRouteReturns, isFalse);
    final replacement = tester.widget<ChannelListScreen>(
      find.byType(ChannelListScreen),
    );
    expect(replacement.repo, same(repo));
    expect(store.config.builds, initialBuilds);
    expect(store.config.source.connections, connections);
    expect(find.text('Preparing your library'), findsNothing);
    expect(navigator.currentState!.canPop(), isFalse);
    await finish(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('a consumed reset is not repeated on the next short return', (
    tester,
  ) async {
    resetPending = true;
    await showHome(tester);
    final library = tester.state(find.byType(ChannelListScreen));
    final initialBuilds = store.config.builds;

    await resume(tester);

    expect(tester.state(find.byType(ChannelListScreen)), same(library));
    expect(store.config.builds, initialBuilds);
    await finish(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets(
    'late reset replies still remove stale routes and overlapping resumes share the read',
    (tester) async {
      await showHome(tester);
      final library = tester.state(find.byType(ChannelListScreen));
      final bootCalls = consumeCalls;
      unawaited(
        navigator.currentState!.push<void>(
          MaterialPageRoute(
            builder: (_) => const Scaffold(body: Text('Stale player loader')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      resetPending = true;
      nextReplyDelay = const Duration(seconds: 3);

      await resume(tester);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.text('Stale player loader'), findsOneWidget);
      expect(resetPending, isTrue);
      expect(consumeCalls, bootCalls + 1);

      // The UI deadline has elapsed, but the original native read still owns
      // the eventual one-shot response. A second resume must not consume it.
      await resume(tester);
      expect(consumeCalls, bootCalls + 1);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();

      expect(find.text('Stale player loader'), findsNothing);
      expect(library.mounted, isFalse);
      expect(resetPending, isFalse);
      expect(navigator.currentState!.canPop(), isFalse);
      final replacement = tester.state(find.byType(ChannelListScreen));

      await resume(tester);
      expect(consumeCalls, bootCalls + 2);
      expect(tester.state(find.byType(ChannelListScreen)), same(replacement));
      await finish(tester);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'a missing native channel preserves navigation and does not block later reset reads',
    (tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(sessionChannel, (_) async {
            throw MissingPluginException('Native session service unavailable');
          });
      await showHome(tester);
      final library = tester.state(find.byType(ChannelListScreen));
      unawaited(
        navigator.currentState!.push<void>(
          MaterialPageRoute(
            builder: (_) => const Scaffold(body: Text('Open details')),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await resume(tester);
      expect(find.text('Open details'), findsOneWidget);
      expect(library.mounted, isTrue);

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(sessionChannel, sessionReply);
      resetPending = true;
      await resume(tester);
      expect(consumeCalls, 1);
      expect(find.text('Open details'), findsNothing);
      expect(library.mounted, isFalse);
      await finish(tester);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}

class _CachedSource extends DemoSource {
  _CachedSource() : super(sourceId: 'cached-provider');

  int connections = 0;

  @override
  Future<void> connect() async => connections++;

  @override
  Future<List<Programme>> epg(List<Channel> channels) async => const [];

  @override
  Future<List<MediaCategory>> mediaCategories(ContentKind kind) async =>
      const [];

  @override
  Future<List<MediaItem>> mediaItems(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    int? maxPages,
  }) async => const [];
}

class _CachedConfig extends SourceConfig {
  _CachedConfig()
    : super(
        id: 'cached-provider',
        kind: SourceKind.demo,
        label: 'Cached provider',
        fields: const {},
      );

  final source = _CachedSource();
  int builds = 0;

  @override
  Source build() {
    builds++;
    return source;
  }
}

class _CachedStore extends SourceStore {
  final config = _CachedConfig();

  @override
  Future<List<SourceConfig>> list() async => [config];

  @override
  Future<String?> activeId() async => config.id;

  @override
  Future<SourceConfig?> activeConfig() async => config;
}

class _CachedDatabase implements AppDatabase {
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

  @override
  Future<void> migrateSourceNamespace(String from, String to) async {}

  @override
  Future<bool> hasLibraryContent(String sourceId) async => true;

  @override
  Future<DateTime?> lastCatalogSynced(
    String sourceId,
    ContentKind kind,
  ) async => DateTime.now();

  @override
  Stream<String> get epgChanged => const Stream.empty();

  @override
  Stream<void> get favoritesReplaced => const Stream.empty();

  @override
  Stream<void> get playbackPositionsReplaced => const Stream.empty();

  @override
  Future<List<PlaybackPosition>> readRecentPositions(
    String sourceId, {
    int limit = 20,
  }) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
