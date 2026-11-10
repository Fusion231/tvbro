// Regression net for series playback handoff and Back navigation.
//
// Episodes picked in the series browser used to be played by a player route the
// MediaDetailsSheet pushed itself, which skipped the screen's post-playback
// "Continue watching" reload — so the series rail stayed stale until a manual
// refresh. The details now hand the episode to the parent via `onPlayEpisode`
// (the same path movies use, which reloads the rail on return). The details stay
// beneath that player route, so Back restores the expanded season, viewport and
// focused episode before another Back returns to the originating screen.
//
// Harness note: repo.loadMedia runs through sqflite_common_ffi (a background
// isolate) whose futures don't advance under the widget-test fake clock, so we
// drive the real event loop with runAsync between pumps (`pumpUntil`), the same
// approach as channel_list_focus_test.

import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
// The image provider exposes this cache interface for replacing I/O in tests.
// ignore: depend_on_referenced_packages
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/data/load_token.dart';
import 'package:iptvs/screens/media_tab_view.dart';
import 'package:iptvs/sources/demo_source.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/theme.dart';
import 'package:iptvs/widgets/routed_focus_node.dart';

class _EpisodeArtworkCache implements BaseCacheManager {
  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) => const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory tempDir;
  late AppDatabase db;

  setUp(() async {
    // Keep episode previews in their placeholder state without network or disk.
    CachedNetworkImageProvider.defaultCacheManager = _EpisodeArtworkCache();
    tempDir = Directory.systemTemp.createTempSync('iptvs_media_details_test');
    db = await AppDatabase.openAt('${tempDir.path}/iptv.db');
  });

  tearDown(() async {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    await db.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<void> pumpUntil(WidgetTester tester, Finder until) async {
    for (var i = 0; i < 60; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
      if (until.evaluate().isNotEmpty) break;
    }
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets(
    'series keeps its hero visible until View episodes is activated',
    (tester) async {
      tester.view.physicalSize = const Size(960, 540);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repo = LibraryRepository(source: DemoSource(), db: db);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: MediaDetailsSheet(
              repo: repo,
              item: MediaItem(
                id: 'demo-series-1',
                title: 'Codec Test Series',
                kind: ContentKind.series,
                description: List.filled(
                  6,
                  'Demo series description that leaves the seasons below the fold.',
                ).join(' '),
              ),
              favorite: false,
              onToggleFavorite: () {},
              onPlay: null,
              onPlayEpisode: (_) {},
            ),
          ),
        ),
      );
      await pumpUntil(tester, find.text('Season 1'));
      await tester.pump(const Duration(milliseconds: 300));
      final primary = find.widgetWithText(FilledButton, 'View episodes');
      final primaryNode = tester.widget<FilledButton>(primary).focusNode;
      expect(primary.hitTestable(), findsOneWidget);
      expect(find.text('Codec Test Series').hitTestable(), findsOneWidget);
      expect(FocusManager.instance.primaryFocus, same(primaryNode));
      final scroll = tester.state<ScrollableState>(
        find.descendant(
          of: find.byType(SingleChildScrollView),
          matching: find.byType(Scrollable),
        ),
      );
      expect(scroll.position.pixels, 0);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      // The focus reveal starts in a post-frame callback; its first tick
      // establishes the clock, so advance time only after that start frame.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('Season 1').hitTestable(), findsOneWidget);
      expect(FocusManager.instance.primaryFocus, isNot(same(primaryNode)));
      expect(find.byTooltip('Close details').hitTestable(), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await pumpUntil(tester, find.text('1. Big Buck Bunny'));
      expect(find.text('1. Big Buck Bunny'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('the series browser does not inherit a cancelled load token', (
    tester,
  ) async {
    // The sheet's season/episode drill-downs are the only `loadMedia` callers
    // that are not a MediaTabController. Every controller path sets
    // `repo.loadToken` in its own synchronous prologue; the sheet set
    // nothing, so it inherited whatever was left on the *shared* repository —
    // and the movie and series controllers share one, each cancelling only
    // its own token, while `MediaTabController.dispose` cancels one outright.
    // So a drill-down could begin already-cancelled through no act of its
    // own.
    //
    // What this pins is the contract — the sheet claims the field rather than
    // borrowing it. The caching assertion below currently holds either way,
    // because a superseded `loadMedia` still *seeds* an empty cache; that is
    // exactly the implicit coupling worth removing, since tightening the seed
    // rule would otherwise silently break the drill-down instead of this
    // test.
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repo = LibraryRepository(source: DemoSource(), db: db);
    // Exactly what a disposed sibling controller leaves behind.
    repo.loadToken = LoadToken()..cancel();

    const series = MediaItem(
      id: 'demo-series-1',
      title: 'Codec Test Series',
      kind: ContentKind.series,
      categoryId: 'demo-series',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaDetailsSheet(
            repo: repo,
            item: series,
            favorite: false,
            onToggleFavorite: () {},
            onPlay: null,
            onPlayEpisode: (_) {},
          ),
        ),
      ),
    );

    await pumpUntil(tester, find.text('Season 1'));
    expect(repo.loadToken, isNull);

    await tester.tap(find.text('Season 1'));
    await pumpUntil(tester, find.text('1. Big Buck Bunny'));
    expect(find.text('1. Big Buck Bunny'), findsOneWidget);
    expect(repo.loadToken, isNull);

    // And the drill-down actually cached, under its own (kind, parent) key.
    // Read through runAsync: sqflite_common_ffi answers from a background
    // isolate, whose futures never complete under the widget-test fake clock
    // (see the harness note at the top of this file).
    final cached = await tester.runAsync(() async {
      final seasons = await db.readMediaItems(
        'demo',
        ContentKind.season,
        parentId: 'demo-series-1',
      );
      final sync = await db.mediaSyncState(
        'demo',
        ContentKind.season,
        parentId: 'demo-series-1',
      );
      return (seasons: seasons, sync: sync);
    });
    expect(cached!.seasons, isNotEmpty);
    expect(cached.sync, isNotNull);
  });

  for (final size in const [Size(960, 540), Size(390, 844)]) {
    testWidgets('Back from a series episode restores details at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final repo = LibraryRepository(source: DemoSource(), db: db);
      // Ids must line up with DemoSource so its season/episode loads resolve.
      final series = MediaItem(
        id: 'demo-series-1',
        title: 'Codec Test Series',
        kind: ContentKind.series,
        categoryId: 'demo-series',
        description: List.filled(
          6,
          'Demo series description that leaves the seasons below the fold.',
        ).join(' '),
      );
      MediaItem? played;
      final navigatorKey = GlobalKey<NavigatorState>();

      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigatorKey,
          theme: AppTheme.dark,
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    useSafeArea: false,
                    builder: (_) => MediaDetailsSheet(
                      repo: repo,
                      item: series,
                      favorite: false,
                      onToggleFavorite: () {},
                      onPlay: null,
                      onPlayEpisode: (episode) {
                        played = episode;
                        navigatorKey.currentState!.push<void>(
                          MaterialPageRoute(
                            builder: (_) => const Scaffold(
                              body: Center(child: Text('Episode player')),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pump();

      // Seasons load async; wait for the season header, then expand it.
      await pumpUntil(tester, find.text('Season 1'));
      expect(find.byType(MediaDetailsSheet), findsOneWidget);
      final detailsState = tester.state(find.byType(MediaDetailsSheet));
      await tester.ensureVisible(find.text('Season 1'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Season 1'));

      // Episodes load async once the season expands.
      await pumpUntil(tester, find.text('1. Big Buck Bunny'));
      // Episodes are in (the progress spinner is gone), so the finite expansion
      // animation can settle before focusing an episode with the remote.
      await tester.pumpAndSettle();

      // The rail owns a stable focus node shared by all its episode cards.
      final episodeTile = find.text('1. Big Buck Bunny');
      await tester.ensureVisible(episodeTile);
      await tester.pumpAndSettle();
      final episodeFocus = FocusManager.instance.rootScope.descendants
          .whereType<RoutedFocusNode>()
          .singleWhere(
            (node) =>
                node.routeKey == 'media.episode.list.demo-series-1:season:1',
          );
      episodeFocus.requestFocus();
      await tester.pumpAndSettle();
      final scroll = tester
          .widget<SingleChildScrollView>(
            find.descendant(
              of: find.byType(MediaDetailsSheet),
              matching: find.byType(SingleChildScrollView),
            ),
          )
          .controller!;
      final episodeOffset = scroll.offset;
      expect(episodeOffset, greaterThan(0));
      expect(episodeTile.hitTestable(), findsOneWidget);
      expect(episodeFocus.hasPrimaryFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(played, isNotNull);
      expect(played!.id, 'bbb');
      expect(find.text('Episode player'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.text('Episode player'), findsNothing);
      expect(tester.state(find.byType(MediaDetailsSheet)), same(detailsState));
      expect(find.text('Season 1'), findsOneWidget);
      expect(episodeTile.hitTestable(), findsOneWidget);
      expect(scroll.offset, closeTo(episodeOffset, 0.1));
      expect(FocusManager.instance.primaryFocus, same(episodeFocus));

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.byType(MediaDetailsSheet), findsNothing);
      expect(find.text('open').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
