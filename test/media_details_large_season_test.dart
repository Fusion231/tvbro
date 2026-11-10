// Episode rails keep one D-pad cursor and build only the visible cards.
// Playback is a dummy route: these regressions exercise focus and scrolling,
// without opening a player, provider connection or metadata request.

import 'dart:async';
import 'dart:io';
import 'dart:ui' show Tristate;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
// The image provider exposes this cache interface for replacing I/O in tests.
// ignore: depend_on_referenced_packages
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/screens/media_tab_view.dart';
import 'package:iptvs/sources/demo_source.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/theme.dart';
import 'package:iptvs/widgets/routed_focus_node.dart';

const _series = MediaItem(
  id: 'large-series',
  title: 'Large series',
  kind: ContentKind.series,
  description:
      'A series description below the season browser. '
      'The episode viewport must keep its own scroll position.',
);

Finder _episodeList(int season) =>
    find.byKey(ValueKey('media.episodes.season-$season.list'));

Finder _episode(int index) => find.text('${index + 1}. Episode $index');

Finder _episodeSemantics(int season, int index) =>
    find.bySemanticsLabel('S${season}E${index + 1}, Episode $index');

FocusNode _seasonFocus(WidgetTester tester, int season) => Focus.of(
  tester.element(find.text('Season $season')),
  createDependency: false,
);

ScrollController _innerScroll(WidgetTester tester, int season) =>
    tester.widget<ListView>(_episodeList(season)).controller!;

ScrollController _outerScroll(WidgetTester tester) => tester
    .widget<SingleChildScrollView>(
      find.descendant(
        of: find.byType(MediaDetailsSheet),
        matching: find.byType(SingleChildScrollView),
      ),
    )
    .controller!;

Future<void> _finishMotion(WidgetTester tester) async {
  await tester.pump();
  // SQLite replies from a background isolate, outside the widget fake clock.
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 20)),
  );
  await tester.pumpAndSettle(
    const Duration(milliseconds: 20),
    EnginePhase.sendSemanticsUpdate,
    const Duration(seconds: 5),
  );
}

Future<void> _moveRight(WidgetTester tester, int count) async {
  for (var i = 0; i < count; i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
  }
  await _finishMotion(tester);
}

void _expectSelected(WidgetTester tester, int season, int index) {
  final row = _episodeSemantics(season, index);
  expect(row, findsOneWidget);
  expect(
    tester.getSemantics(row).getSemanticsData().flagsCollection.isSelected,
    Tristate.isTrue,
  );
  expect(
    find.descendant(of: row, matching: _episode(index)).hitTestable(),
    findsOneWidget,
  );
}

Future<void> _pumpDetails(
  WidgetTester tester, {
  required _SeasonRepository repo,
  required ValueChanged<MediaItem> onPlay,
  GlobalKey<NavigatorState>? navigatorKey,
  Size size = const Size(960, 540),
  double textScale = 1,
  bool disableAnimations = false,
  MediaItem item = _series,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigatorKey,
      theme: AppTheme.dark,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          disableAnimations: disableAnimations,
        ),
        child: child!,
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => showDialog<void>(
                context: context,
                useSafeArea: false,
                builder: (_) => MediaDetailsSheet(
                  repo: repo,
                  item: item,
                  favorite: false,
                  onToggleFavorite: () {},
                  onPlay: null,
                  onPlayEpisode: onPlay,
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
  await _finishMotion(tester);
  expect(find.text('Season 1'), findsOneWidget);
}

Future<FocusNode> _openFirstSeason(WidgetTester tester) async {
  final viewEpisodes = tester.widget<FilledButton>(
    find.byKey(const ValueKey('media.details.play')),
  );
  expect(FocusManager.instance.primaryFocus, same(viewEpisodes.focusNode));
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await _finishMotion(tester);
  final header = _seasonFocus(tester, 1);
  expect(FocusManager.instance.primaryFocus, same(header));
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await _finishMotion(tester);
  expect(_episodeList(1), findsOneWidget);
  await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
  await _finishMotion(tester);
  final node = FocusManager.instance.primaryFocus!;
  expect(focusRouteKey(node), 'media.episode.list.season-1');
  return node;
}

void main() {
  late Directory tempDir;
  late AppDatabase db;

  setUp(() async {
    CachedNetworkImageProvider.defaultCacheManager = _EpisodeArtworkCache();
    tempDir = Directory.systemTemp.createTempSync('iptvs_large_season_test');
    db = await AppDatabase.openAt('${tempDir.path}/iptv.db');
  });

  tearDown(() async {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    await db.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  for (final size in const [Size(960, 540), Size(390, 844)]) {
    for (final disableAnimations in [false, true]) {
      testWidgets(
        'opening a season reveals episodes at $size, reduced motion $disableAnimations',
        (tester) async {
          final repo = _SeasonRepository(db, const [7]);
          await _pumpDetails(
            tester,
            repo: repo,
            size: size,
            disableAnimations: disableAnimations,
            onPlay: (_) {},
          );
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await _finishMotion(tester);
          final header = _seasonFocus(tester, 1);
          final beforeExpansion = _outerScroll(tester).offset;

          await tester.tap(find.text('Season 1'));
          await _finishMotion(tester);

          expect(_outerScroll(tester).offset, greaterThan(beforeExpansion));
          expect(_episode(0).hitTestable(), findsOneWidget);
          expect(
            tester.getBottomLeft(_episodeList(1)).dy,
            lessThanOrEqualTo(size.height),
          );
          expect(FocusManager.instance.primaryFocus, same(header));
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }

  testWidgets('episodes loaded after expansion are revealed when ready', (
    tester,
  ) async {
    final gate = Completer<void>();
    final repo = _SeasonRepository(db, const [7])..episodeGate = gate.future;
    await _pumpDetails(tester, repo: repo, onPlay: (_) {});
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await _finishMotion(tester);
    final header = _seasonFocus(tester, 1);
    await tester.tap(find.text('Season 1'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(_episodeList(1), findsNothing);

    gate.complete();
    await _finishMotion(tester);

    expect(_episode(0).hitTestable(), findsOneWidget);
    expect(tester.getBottomLeft(_episodeList(1)).dy, lessThanOrEqualTo(540));
    expect(FocusManager.instance.primaryFocus, same(header));
    expect(repo.episodeLoads, {'season-1': 1});
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('manual scrolling cancels reveal for a delayed season', (
    tester,
  ) async {
    final gate = Completer<void>();
    final repo = _SeasonRepository(db, const [7])..episodeGate = gate.future;
    await _pumpDetails(tester, repo: repo, onPlay: (_) {});
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await _finishMotion(tester);
    await tester.tap(find.text('Season 1'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final beforeDrag = _outerScroll(tester).offset;
    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -80),
    );
    await tester.pump(const Duration(seconds: 1));
    final draggedOffset = _outerScroll(tester).offset;
    expect(draggedOffset, greaterThan(beforeDrag));

    gate.complete();
    await _finishMotion(tester);

    expect(_episodeList(1), findsOneWidget);
    expect(_outerScroll(tester).offset, closeTo(draggedOffset, 0.1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('collapsing a season stops its running scroll animation', (
    tester,
  ) async {
    final repo = _SeasonRepository(db, const [7]);
    await _pumpDetails(tester, repo: repo, onPlay: (_) {});
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await _finishMotion(tester);
    final header = _seasonFocus(tester, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    await tester.pump(const Duration(milliseconds: 40));
    expect(_outerScroll(tester).position.isScrollingNotifier.value, isTrue);
    expect(FocusManager.instance.primaryFocus, same(header));

    // A remote press avoids the pointer gesture itself stopping the scroll.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(_outerScroll(tester).position.isScrollingNotifier.value, isFalse);
    await _finishMotion(tester);
    expect(_episodeList(1), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('episode cards show and refresh watched and resume progress', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await db.savePlaybackPosition(
        'demo',
        ContentKind.episode,
        'season-1-episode-0',
        position: const Duration(minutes: 29),
        duration: const Duration(minutes: 30),
      );
      await db.savePlaybackPosition(
        'demo',
        ContentKind.episode,
        'season-1-episode-1',
        position: const Duration(minutes: 12, seconds: 34),
        duration: const Duration(minutes: 30),
      );
    });
    final repo = _SeasonRepository(db, const [3]);
    await _pumpDetails(
      tester,
      repo: repo,
      size: const Size(1280, 960),
      onPlay: (_) {},
    );
    await _openFirstSeason(tester);
    // This read is queued behind the UI's batch read on the same database.
    await tester.runAsync(() => db.readPlaybackPositionsForSync());
    await _finishMotion(tester);

    expect(find.text('Watched'), findsOneWidget);
    expect(find.text('Resume from 12:34'), findsOneWidget);
    expect(find.bySemanticsLabel('S1E1, Episode 0, Watched'), findsOneWidget);
    expect(
      find.bySemanticsLabel('S1E2, Episode 1, Resume from 12:34'),
      findsOneWidget,
    );
    final progress = find.descendant(
      of: _episodeList(1),
      matching: find.byType(LinearProgressIndicator),
    );
    expect(progress, findsNWidgets(2));
    expect(
      tester
          .widgetList<LinearProgressIndicator>(progress)
          .map((bar) => bar.value),
      contains(closeTo(754 / 1800, 0.001)),
    );

    final offset = _outerScroll(tester).offset;
    await tester.runAsync(
      () => db.savePlaybackPosition(
        'demo',
        ContentKind.episode,
        'season-1-episode-1',
        position: const Duration(minutes: 30),
        duration: const Duration(minutes: 30),
      ),
    );
    await tester.runAsync(() => db.readPlaybackPositionsForSync());
    await _finishMotion(tester);
    expect(find.text('Watched'), findsNWidgets(2));
    expect(find.text('Resume from 12:34'), findsNothing);
    expect(_outerScroll(tester).offset, closeTo(offset, 0.1));

    await tester.runAsync(() async {
      await db.clearPlaybackOutbox(await db.readPlaybackOutbox());
      await db.applyCloudPlaybackPositions(
        {'demo'},
        [
          (
            sourceId: 'demo',
            kind: ContentKind.episode,
            itemId: 'season-1-episode-1',
            positionMs: const Duration(minutes: 15).inMilliseconds,
            durationMs: const Duration(minutes: 30).inMilliseconds,
            updatedAt: DateTime.now().millisecondsSinceEpoch + 1000,
            removed: false,
          ),
        ],
      );
    });
    await tester.pump();
    await tester.runAsync(() => db.readPlaybackPositionsForSync());
    await _finishMotion(tester);
    expect(find.text('Watched'), findsNothing);
    expect(find.text('Resume from 15:00'), findsOneWidget);
    expect(_outerScroll(tester).offset, closeTo(offset, 0.1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('TV series shows compact seasons and episode totals before info', (
    tester,
  ) async {
    final series = _series.copyWith(durationSeconds: 2700);
    final repo = _SeasonRepository(db, const [3, 7]);
    await _pumpDetails(tester, repo: repo, item: series, onPlay: (_) {});

    final description = find.text(series.description!);
    final information = find.byKey(const ValueKey('media.details.information'));
    expect(find.text(series.title).hitTestable(), findsOneWidget);
    expect(find.text('Seasons: 2').hitTestable(), findsOneWidget);
    expect(find.text('Season 1').hitTestable(), findsOneWidget);
    expect(repo.episodeLoads, isEmpty);
    expect(find.textContaining('Episodes:'), findsNothing);
    expect(
      tester.getBottomLeft(find.text('Season 2')).dy,
      lessThan(tester.getTopLeft(description).dy),
    );
    expect(
      tester.getBottomLeft(description).dy,
      lessThan(tester.getTopLeft(information).dy),
    );

    await _openFirstSeason(tester);
    expect(find.text('Episodes: 3'), findsOneWidget);
    expect(find.text('Episodes: 7'), findsNothing);
    expect(repo.episodeLoads, {'season-1': 1});
    expect(
      tester.getBottomLeft(find.text('Episodes: 3')).dy,
      lessThanOrEqualTo(tester.getTopLeft(_episodeList(1)).dy),
    );
    expect(
      tester.getBottomLeft(_episodeList(1)).dy,
      lessThan(tester.getTopLeft(description).dy),
    );
    expect(
      tester
          .getSize(
            find.descendant(
              of: _episodeSemantics(1, 0),
              matching: find.byType(InkWell),
            ),
          )
          .width,
      lessThanOrEqualTo(240),
    );
    expect(_episode(0).hitTestable(), findsOneWidget);
    expect(find.byTooltip('Close details').hitTestable(), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await _finishMotion(tester);
    expect(FocusManager.instance.primaryFocus, same(_seasonFocus(tester, 2)));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await _finishMotion(tester);
    expect(find.text('Episodes: 7'), findsOneWidget);
    expect(repo.episodeLoads, {'season-1': 1, 'season-2': 1});
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await _finishMotion(tester);
    expect(
      focusRouteKey(FocusManager.instance.primaryFocus),
      'media.episode.list.season-2',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await _finishMotion(tester);
    expect(
      focusRouteKey(FocusManager.instance.primaryFocus),
      'media.details.synopsis',
    );
    expect(description.hitTestable(), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await _finishMotion(tester);
    expect(
      focusRouteKey(FocusManager.instance.primaryFocus),
      'media.details.info.duration',
    );
    expect(find.text('Duration').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('5000 episodes stay lazy and remote activation plays once', (
    tester,
  ) async {
    final played = <String>[];
    final repo = _SeasonRepository(db, const [5000]);
    await _pumpDetails(
      tester,
      repo: repo,
      onPlay: (episode) => played.add(episode.id),
    );
    final listFocus = await _openFirstSeason(tester);
    _expectSelected(tester, 1, 0);

    void expectBoundedCards() {
      final cards = find.descendant(
        of: _episodeList(1),
        matching: find.textContaining(RegExp(r'^\d+\. Episode \d+$')),
      );
      expect(cards.evaluate().length, inExclusiveRange(0, 30));
      expect(
        tester.widget<ListView>(_episodeList(1)).scrollDirection,
        Axis.horizontal,
      );
      expect(
        FocusManager.instance.rootScope.descendants
            .whereType<RoutedFocusNode>()
            .where((node) => node.routeKey.startsWith('media.episode.')),
        hasLength(1),
      );
    }

    expectBoundedCards();
    await _moveRight(tester, 50);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
    await _finishMotion(tester);
    _expectSelected(tester, 1, 52);
    expect(FocusManager.instance.primaryFocus, same(listFocus));
    expect(_innerScroll(tester, 1).offset, greaterThan(0));
    expect(_episode(0), findsNothing);
    expectBoundedCards();

    for (final key in const [
      LogicalKeyboardKey.enter,
      LogicalKeyboardKey.select,
      LogicalKeyboardKey.space,
    ]) {
      final previousCount = played.length;
      await tester.sendKeyDownEvent(key);
      await tester.sendKeyRepeatEvent(key);
      await tester.sendKeyUpEvent(key);
      await _finishMotion(tester);
      expect(played.length, previousCount + 1);
      expect(played.last, 'season-1-episode-52');
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final size in const [Size(960, 540), Size(390, 844)]) {
    testWidgets(
      'large-season Back preserves selection and both offsets $size',
      (tester) async {
        final repo = _SeasonRepository(db, const [5000]);
        final navigatorKey = GlobalKey<NavigatorState>();
        final played = <String>[];
        var pushPlayer = false;
        await _pumpDetails(
          tester,
          repo: repo,
          navigatorKey: navigatorKey,
          size: size,
          onPlay: (episode) {
            played.add(episode.id);
            if (!pushPlayer) return;
            navigatorKey.currentState!.push<void>(
              MaterialPageRoute(
                builder: (_) =>
                    const Scaffold(body: Center(child: Text('Episode player'))),
              ),
            );
          },
        );
        final listFocus = await _openFirstSeason(tester);
        final detailsState = tester.state(find.byType(MediaDetailsSheet));
        final listState = tester.state(
          find.descendant(
            of: _episodeList(1),
            matching: find.byType(Scrollable),
          ),
        );
        await _moveRight(tester, 30);
        var selected = 30;
        if (size.width < 600) {
          // Pointer activation must update the same cursor before the callback.
          selected = 29;
          await tester.ensureVisible(_episode(selected));
          await _finishMotion(tester);
          expect(_episode(selected).hitTestable(), findsOneWidget);
          await tester.tap(_episode(selected));
          await _finishMotion(tester);
          expect(played, ['season-1-episode-29']);
          expect(FocusManager.instance.primaryFocus, same(listFocus));
          _expectSelected(tester, 1, selected);
          played.clear();
        }
        final inner = _innerScroll(tester, 1);
        final outer = _outerScroll(tester);
        final innerOffset = inner.offset;
        final outerOffset = outer.offset;
        expect(innerOffset, greaterThan(0));
        expect(outerOffset, greaterThan(0));
        pushPlayer = true;
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await _finishMotion(tester);
        expect(played, ['season-1-episode-$selected']);
        expect(find.text('Episode player'), findsOneWidget);

        await tester.binding.handlePopRoute();
        await _finishMotion(tester);
        expect(find.text('Episode player'), findsNothing);
        expect(
          tester.state(find.byType(MediaDetailsSheet)),
          same(detailsState),
        );
        expect(
          tester.state(
            find.descendant(
              of: _episodeList(1),
              matching: find.byType(Scrollable),
            ),
          ),
          same(listState),
        );
        expect(FocusManager.instance.primaryFocus, same(listFocus));
        expect(inner.offset, closeTo(innerOffset, 0.1));
        expect(outer.offset, closeTo(outerOffset, 0.1));
        _expectSelected(tester, 1, selected);
        expect(repo.episodeLoads, {'season-1': 1});

        await tester.binding.handlePopRoute();
        await _finishMotion(tester);
        expect(find.byType(MediaDetailsSheet), findsNothing);
        expect(find.text('open').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  for (final size in const [Size(960, 540), Size(390, 844)]) {
    testWidgets(
      'short season swipes and arrow buttons move horizontally $size',
      (tester) async {
        final played = <String>[];
        final repo = _SeasonRepository(db, const [7]);
        await _pumpDetails(
          tester,
          repo: repo,
          size: size,
          onPlay: (episode) => played.add(episode.id),
        );
        final listFocus = await _openFirstSeason(tester);
        final list = _episodeList(1);
        expect(tester.widget<ListView>(list).scrollDirection, Axis.horizontal);
        expect(
          FocusManager.instance.rootScope.descendants
              .whereType<RoutedFocusNode>()
              .where((node) => node.routeKey.startsWith('media.episode.')),
          hasLength(1),
        );
        _expectSelected(tester, 1, 0);
        final inner = _innerScroll(tester, 1);
        final outer = _outerScroll(tester);
        final outerOffset = outer.offset;
        await tester.drag(list, Offset(-tester.getSize(list).width * 0.8, 0));
        await _finishMotion(tester);
        expect(inner.offset, greaterThan(0));
        expect(outer.offset, closeTo(outerOffset, 0.1));
        expect(played, isEmpty);

        final next = find.byKey(const ValueKey('media.episodes.season-1.next'));
        final previous = find.byKey(
          const ValueKey('media.episodes.season-1.previous'),
        );
        expect(next.hitTestable(), findsOneWidget);
        await tester.tap(next);
        await _finishMotion(tester);
        _expectSelected(tester, 1, 1);
        expect(FocusManager.instance.primaryFocus, same(listFocus));
        await tester.tap(previous);
        await _finishMotion(tester);
        _expectSelected(tester, 1, 0);
        expect(FocusManager.instance.primaryFocus, same(listFocus));
        expect(played, isEmpty);

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await _finishMotion(tester);
        _expectSelected(tester, 1, 1);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await _finishMotion(tester);
        expect(played, ['season-1-episode-1']);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'episode previews prefer posters then backdrops and series artwork',
    (tester) async {
      for (final series in [
        _series.copyWith(backdrop: 'https://images.test/series-backdrop.jpg'),
        _series.copyWith(poster: 'https://images.test/series-poster.jpg'),
        _series,
      ]) {
        final repo = _SeasonRepository(db, const [3]);
        final episodes = repo.episodeItems['season-1']!;
        episodes[0] = episodes[0].copyWith(
          backdrop: 'https://images.test/episode-backdrop.jpg',
        );
        episodes[1] = episodes[1].copyWith(
          poster: 'https://images.test/episode-poster.jpg',
          backdrop: 'https://images.test/ignored-backdrop.jpg',
        );
        await _pumpDetails(
          tester,
          repo: repo,
          item: series,
          size: const Size(1280, 960),
          onPlay: (_) {},
        );
        await _openFirstSeason(tester);
        for (var index = 0; index < episodes.length; index++) {
          final preview = find.descendant(
            of: _episodeSemantics(1, index),
            matching: find.byType(CachedNetworkImage),
          );
          final expectedUrl = switch (index) {
            0 => episodes[0].backdrop,
            1 => episodes[1].poster,
            _ => series.backdrop ?? series.poster,
          };
          if (expectedUrl == null) {
            expect(preview, findsNothing);
            expect(
              find.descendant(
                of: _episodeSemantics(1, index),
                matching: find.byIcon(Icons.tv_outlined),
              ),
              findsOneWidget,
            );
          } else {
            expect(preview, findsOneWidget);
            final image = tester.widget<CachedNetworkImage>(preview);
            expect(image.imageUrl, expectedUrl);
            expect(image.fit, BoxFit.cover);
            expect(tester.getSize(preview).aspectRatio, closeTo(16 / 9, 0.001));
          }
          expect(
            tester
                .widget<Text>(
                  find.descendant(
                    of: _episodeSemantics(1, index),
                    matching: find.text(episodes[index].description!),
                  ),
                )
                .maxLines,
            2,
          );
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await _finishMotion(tester);
      }
    },
  );

  testWidgets('long-season edges and reopening work with doubled text', (
    tester,
  ) async {
    final repo = _SeasonRepository(db, const [41, 42]);
    await _pumpDetails(
      tester,
      repo: repo,
      onPlay: (_) {},
      size: const Size(1280, 1000),
      textScale: 2,
    );
    final firstListFocus = await _openFirstSeason(tester);
    final firstHeader = _seasonFocus(tester, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await _finishMotion(tester);
    expect(FocusManager.instance.primaryFocus, same(firstHeader));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await _finishMotion(tester);
    expect(FocusManager.instance.primaryFocus, same(firstListFocus));
    _expectSelected(tester, 1, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await _finishMotion(tester);
    _expectSelected(tester, 1, 0);
    expect(FocusManager.instance.primaryFocus, same(firstListFocus));
    await _moveRight(tester, 40);
    _expectSelected(tester, 1, 40);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await _finishMotion(tester);
    _expectSelected(tester, 1, 40);
    expect(FocusManager.instance.primaryFocus, same(firstListFocus));
    // Up exits immediately even when the cursor is deep in the season.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await _finishMotion(tester);
    expect(FocusManager.instance.primaryFocus, same(firstHeader));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await _finishMotion(tester);
    _expectSelected(tester, 1, 40);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await _finishMotion(tester);
    expect(FocusManager.instance.primaryFocus, same(_seasonFocus(tester, 2)));

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await _finishMotion(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await _finishMotion(tester);
    expect(
      focusRouteKey(FocusManager.instance.primaryFocus),
      'media.episode.list.season-2',
    );
    await _moveRight(tester, 3);
    _expectSelected(tester, 2, 3);
    // Down exits immediately; reaching the last episode is not required.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await _finishMotion(tester);
    expect(
      focusRouteKey(FocusManager.instance.primaryFocus),
      'media.details.synopsis',
    );
    expect(find.text(_series.description!).hitTestable(), findsOneWidget);

    await tester.ensureVisible(find.text('Season 1'));
    await _finishMotion(tester);
    await tester.tap(find.text('Season 1'));
    await _finishMotion(tester);
    expect(_episodeList(1), findsNothing);
    await tester.tap(find.text('Season 1'));
    await _finishMotion(tester);
    expect(_episodeList(1), findsOneWidget);
    firstHeader.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await _finishMotion(tester);
    expect(
      focusRouteKey(FocusManager.instance.primaryFocus),
      'media.episode.list.season-1',
    );
    _expectSelected(tester, 1, 0);
    expect(repo.episodeLoads, {'season-1': 1, 'season-2': 1});
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

/// Keeps preview layout deterministic without networking, disk or cache timers.
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

class _SeasonRepository extends LibraryRepository {
  _SeasonRepository(AppDatabase database, List<int> counts)
    : seasons = [
        for (var i = 0; i < counts.length; i++)
          MediaItem(
            id: 'season-${i + 1}',
            parentId: _series.id,
            title: 'Season ${i + 1}',
            kind: ContentKind.season,
            seasonNumber: i + 1,
          ),
      ],
      episodeItems = {
        for (var season = 0; season < counts.length; season++)
          'season-${season + 1}': [
            for (var index = 0; index < counts[season]; index++)
              MediaItem(
                id: 'season-${season + 1}-episode-$index',
                parentId: 'season-${season + 1}',
                title: 'Episode $index',
                kind: ContentKind.episode,
                seasonNumber: season + 1,
                episodeNumber: index + 1,
                description:
                    'Episode description for scrolling and text scale.',
              ),
          ],
      },
      super(source: DemoSource(), db: database);

  final List<MediaItem> seasons;
  final Map<String, List<MediaItem>> episodeItems;
  final Map<String, int> episodeLoads = {};
  Future<void>? episodeGate;

  @override
  Future<MediaLibrarySnapshot> loadMedia(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    bool forceRefresh = false,
    bool enrichChildren = true,
  }) async {
    if (kind == ContentKind.episode) {
      episodeLoads.update(parent!.id, (value) => value + 1, ifAbsent: () => 1);
      await episodeGate;
    }
    return MediaLibrarySnapshot(
      kind: kind,
      categoryId: categoryId,
      parentId: parent?.id,
      categories: const [],
      items: kind == ContentKind.season
          ? seasons
          : episodeItems[parent?.id] ?? const [],
      fromCache: true,
      syncedAt: null,
    );
  }

  @override
  Future<ExternalMetadata?> cachedExternalMetadata(
    MediaItem item,
    String provider,
  ) async => null;
}
