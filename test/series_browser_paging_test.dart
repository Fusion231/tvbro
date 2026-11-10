import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/screens/media_tab_view.dart';
import 'package:iptvs/sources/demo_source.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/theme.dart';

void main() {
  late Directory directory;
  late AppDatabase db;
  late _PagedSource source;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('series_browser_paging_');
    db = await AppDatabase.openAt('${directory.path}/library.db');
    source = _PagedSource();
  });

  tearDown(() async {
    source.release();
    await db.close();
    await directory.delete(recursive: true);
  });

  Future<void> pumpUntil(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 80; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
      if (finder.evaluate().isNotEmpty) return;
    }
    expect(finder, findsWidgets);
  }

  Future<void> showSeries(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          body: MediaDetailsSheet(
            repo: LibraryRepository(source: source, db: db),
            item: const MediaItem(
              id: 'series',
              title: 'Paged series',
              kind: ContentKind.series,
            ),
            favorite: false,
            onToggleFavorite: () {},
            onPlay: null,
            onPlayEpisode: (_) {},
          ),
        ),
      ),
    );
    await pumpUntil(
      tester,
      find.byKey(const ValueKey('media.series:series.loadMore')),
    );
  }

  Future<void> activate(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(finder);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
  }

  const seasonsMore = ValueKey('media.series:series.loadMore');
  const episodesMore = ValueKey('media.season:s1.loadMore');

  testWidgets('series pages load only when requested and keep D-pad access', (
    tester,
  ) async {
    await showSeries(tester);
    expect(source.seasonPages, [1]);
    expect(source.episodePages, isEmpty);

    await activate(tester, find.byKey(seasonsMore));
    await pumpUntil(tester, find.text('Season 2'));
    expect(source.seasonPages, [1, 2]);
    expect(source.episodePages, isEmpty);

    await activate(tester, find.text('Season 1'));
    await pumpUntil(tester, find.byKey(episodesMore));
    expect(source.episodePages, ['s1:1']);
    final more = find.byKey(episodesMore);
    await activate(tester, more);
    await pumpUntil(tester, find.text('Episodes: 2'));
    expect(source.episodePages, ['s1:1', 's1:2']);

    final moreFocus = tester.widget<FilledButton>(more).focusNode!;
    moreFocus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'media.episode.list.s1',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus, same(moreFocus));

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    final seasonHeaderFocus = FocusManager.instance.primaryFocus;
    for (var page = 3; page <= 4; page++) {
      await activate(tester, more);
      await pumpUntil(tester, find.text('Episodes: $page'));
      expect(source.episodePages, [
        for (var loaded = 1; loaded <= page; loaded++) 's1:$loaded',
      ]);
    }
    moreFocus.requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await pumpUntil(tester, find.text('Episodes: 5'));
    await tester.pump();
    expect(find.byKey(episodesMore), findsNothing);
    expect(FocusManager.instance.primaryFocus, same(seasonHeaderFocus));
    expect(source.episodePages, ['s1:1', 's1:2', 's1:3', 's1:4', 's1:5']);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'switching seasons cancels paging and resumes the correct parent',
    (tester) async {
      await showSeries(tester);
      await activate(tester, find.byKey(seasonsMore));
      await pumpUntil(tester, find.text('Season 2'));
      await activate(tester, find.text('Season 1'));
      await pumpUntil(tester, find.byKey(episodesMore));

      source.hold();
      await activate(tester, find.byKey(episodesMore));
      // SQLite replies and widget continuations use different clocks. Advance
      // both until the fixture has received page 2 before switching seasons.
      for (var i = 0; i < 80 && !source.started!.isCompleted; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(source.started!.isCompleted, isTrue);
      await activate(tester, find.text('Season 2'));
      await pumpUntil(
        tester,
        find.byKey(const ValueKey('media.season:s2.loadMore')),
      );
      await tester.runAsync(() async {
        source.release();
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
      expect(source.episodePages.where((page) => page.startsWith('s1:')), [
        's1:1',
        's1:2',
      ]);
      final state = await tester.runAsync(
        () => db.mediaSyncState('demo', ContentKind.episode, parentId: 's1'),
      );
      expect(state!.loadedPages, 1);

      await activate(tester, find.text('Season 2'));
      await activate(tester, find.byKey(episodesMore));
      await pumpUntil(tester, find.text('Episodes: 2'));
      expect(source.episodePages.where((page) => page.startsWith('s1:')), [
        's1:1',
        's1:2',
        's1:2',
      ]);
      await activate(tester, find.byKey(episodesMore));
      await pumpUntil(tester, find.text('Episodes: 3'));
      expect(source.episodePages.where((page) => page.startsWith('s1:')), [
        's1:1',
        's1:2',
        's1:2',
        's1:3',
      ]);
      expect(source.episodePages.where((page) => page.startsWith('s2:')), [
        's2:1',
      ]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('empty child pages retain access to later provider pages', (
    tester,
  ) async {
    source.emptyFirstSeasonPage = true;
    source.emptyFirstEpisodePage = true;
    await showSeries(tester);
    expect(find.text('No seasons found'), findsOneWidget);
    await activate(tester, find.byKey(seasonsMore));
    await pumpUntil(tester, find.text('Season 2'));
    await activate(tester, find.text('Season 2'));
    final more = find.byKey(const ValueKey('media.season:s2.loadMore'));
    await pumpUntil(tester, more);
    expect(find.text('No episodes found'), findsOneWidget);
    await activate(tester, more);
    await pumpUntil(tester, find.text('Episodes: 1'));
    expect(source.seasonPages, [1, 2]);
    expect(source.episodePages, ['s2:1', 's2:2']);
    await activate(tester, more);
    await pumpUntil(tester, find.text('Episodes: 2'));
    expect(source.episodePages, ['s2:1', 's2:2', 's2:3']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

class _PagedSource extends DemoSource {
  final seasonPages = <int>[];
  final episodePages = <String>[];
  bool emptyFirstSeasonPage = false;
  bool emptyFirstEpisodePage = false;
  Completer<void>? gate;
  Completer<void>? started;

  void hold() {
    gate = Completer<void>();
    started = Completer<void>();
  }

  void release() {
    gate?.complete();
    gate = null;
  }

  @override
  Future<List<MediaCategory>> mediaCategories(ContentKind kind) async => [];

  @override
  Future<MediaPage> mediaItemsPage(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    int page = 1,
  }) async {
    if (kind == ContentKind.season) {
      seasonPages.add(page);
      return MediaPage(
        items: [
          if (!emptyFirstSeasonPage || page != 1)
            MediaItem(
              id: 's$page',
              title: 'Season $page',
              kind: kind,
              parentId: parent!.id,
              seasonNumber: page,
            ),
        ],
        page: page,
        totalPages: 2,
      );
    }
    episodePages.add('${parent!.id}:$page');
    if (parent.id == 's1' && page == 2 && gate != null) {
      started!.complete();
      await gate!.future;
    }
    return MediaPage(
      items: [
        if (!emptyFirstEpisodePage || page != 1)
          MediaItem(
            id: '${parent.id}-episode-$page',
            title: 'Episode $page',
            kind: kind,
            parentId: parent.id,
            seasonNumber: parent.seasonNumber,
            episodeNumber: page,
          ),
      ],
      page: page,
      totalPages: 5,
    );
  }
}
