import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/data/recently_watched_store.dart';
import 'package:iptvs/screens/library_home_view.dart';
import 'package:iptvs/screens/recently_watched_view.dart';
import 'package:iptvs/sources/demo_source.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/theme.dart';

class _HistoryDatabase implements AppDatabase {
  final channel = const Channel(id: 'tv', name: 'News TV');
  final movie = const MediaItem(
    id: 'film',
    title: 'Movie',
    kind: ContentKind.movie,
  );
  final episode = const MediaItem(
    id: 'episode',
    title: 'Series · S01E02',
    kind: ContentKind.episode,
  );

  @override
  Future<Channel?> readChannel(String sourceId, String channelId) async =>
      channelId == channel.id ? channel : null;

  @override
  Future<List<MediaItem>> readMediaItemsByIds(
    String sourceId,
    ContentKind kind,
    List<String> ids,
  ) async => [
    for (final item in [movie, episode])
      if (item.kind == kind && ids.contains(item.id)) item,
  ];

  @override
  Future<List<PlaybackPosition>> readRecentPositions(
    String sourceId, {
    int limit = 20,
  }) async => [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test(
    'mixed history survives reopening, deduplicates and stays bounded',
    () async {
      final store = RecentlyWatchedStore();
      await Future.wait([
        store.record('source', ContentKind.live, 'tv'),
        store.record('source', ContentKind.movie, 'film'),
        store.record('source', ContentKind.episode, 'episode'),
        store.record('source', ContentKind.live, 'tv'),
      ]);
      final reopened = RecentlyWatchedStore();
      expect((await reopened.read('source')).map((e) => e.itemId), [
        'tv',
        'episode',
        'film',
      ]);
      expect(await reopened.read('another-source'), isEmpty);
      for (var i = 0; i < 25; i++) {
        await store.record('source', ContentKind.movie, '$i');
      }
      final entries = await store.read('source');
      expect(entries.length, RecentlyWatchedStore.limit);
      expect(entries.first.itemId, '24');
      store.dispose();
      reopened.dispose();
    },
  );

  test('history stays with the profile that opened the store', () async {
    const storage = FlutterSecureStorage();
    await storage.write(key: 'active_local_profile_id', value: 'one');
    final first = RecentlyWatchedStore();
    await first.record('source', ContentKind.movie, 'first');
    await storage.write(key: 'active_local_profile_id', value: 'two');
    final second = RecentlyWatchedStore();
    expect(await second.read('source'), isEmpty);
    await first.record('source', ContentKind.live, 'late-write');
    expect(await second.read('source'), isEmpty);
    await storage.write(key: 'active_local_profile_id', value: 'one');
    final restored = RecentlyWatchedStore();
    expect((await restored.read('source')).map((e) => e.itemId), [
      'late-write',
      'first',
    ]);
    first.dispose();
    second.dispose();
    restored.dispose();
  });

  for (final size in [
    const Size(360, 800),
    const Size(960, 540),
    const Size(1280, 720),
  ]) {
    testWidgets('home history fits at $size and opens each content kind', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final store = RecentlyWatchedStore();
      final db = _HistoryDatabase();
      final repo = LibraryRepository(source: DemoSource(), db: db);
      final nodes = {
        for (final kind in [
          ContentKind.live,
          ContentKind.movie,
          ContentKind.series,
        ])
          kind: FocusNode(),
      };
      final favorites = FocusNode();
      final selected = <Object>[];
      await store.record(repo.source.id, ContentKind.movie, 'film');
      await store.record(repo.source.id, ContentKind.episode, 'episode');
      await store.record(repo.source.id, ContentKind.live, 'tv');
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: LibraryHomeView(
              onSelected: (_) {},
              focusNodes: nodes,
              onFavoritesSelected: () {},
              favoritesFocusNode: favorites,
              recentlyWatched: RecentlyWatchedView(
                repo: repo,
                store: store,
                channelAllowed: (_) => true,
                mediaAllowed: (_) => true,
                onPlayChannel: selected.add,
                onPlayMedia: selected.add,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final key in [
        'recent-live-tv',
        'recent-episode-episode',
        'recent-movie-film',
      ]) {
        final card = find.byKey(ValueKey(key));
        await tester.ensureVisible(card);
        await tester.pumpAndSettle();
        await tester.tap(card);
      }
      expect(selected, [db.channel, db.episode, db.movie]);
      expect(tester.takeException(), isNull);
      // The TV remote can move from the last home tile into history.
      favorites.requestFocus();
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(selected.length, 4);
      await tester.pumpWidget(const SizedBox.shrink());
      for (final node in nodes.values) {
        node.dispose();
      }
      favorites.dispose();
      store.dispose();
      await repo.source.dispose();
    });
  }

  testWidgets(
    'missing and protected items are hidden; new playback refreshes the rail',
    (tester) async {
      final store = RecentlyWatchedStore();
      final db = _HistoryDatabase();
      final repo = LibraryRepository(source: DemoSource(), db: db);
      await store.record(repo.source.id, ContentKind.movie, 'removed');
      await store.record(repo.source.id, ContentKind.live, 'tv');
      Widget home(int visit) => MaterialApp(
        home: Scaffold(
          body: RecentlyWatchedView(
            key: ValueKey((repo, visit)),
            repo: repo,
            store: store,
            channelAllowed: (_) => false,
            mediaAllowed: (_) => true,
            onPlayChannel: (_) {},
            onPlayMedia: (_) {},
          ),
        ),
      );
      await tester.pumpWidget(home(0));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('recent-live-tv')), findsNothing);
      await store.record(repo.source.id, ContentKind.movie, 'film');
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('recent-movie-film')), findsOneWidget);
      final playbackStore = RecentlyWatchedStore();
      await playbackStore.record(
        repo.source.id,
        ContentKind.episode,
        'episode',
      );
      await tester.pumpWidget(home(1));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('recent-episode-episode')),
        findsOneWidget,
      );
      playbackStore.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
      store.dispose();
      await repo.source.dispose();
    },
  );
}
