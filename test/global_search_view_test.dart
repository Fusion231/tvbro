import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
// The image provider exposes this cache interface for replacing I/O in tests.
// ignore: depend_on_referenced_packages
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/screens/global_search_view.dart';
import 'package:iptvs/screens/media_tab_view.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/widgets/routed_focus_node.dart';

/// Keeps artwork in its placeholder state without networking, disk or timers.
class _SearchArtworkCache implements BaseCacheManager {
  final requested = <String>[];

  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) {
    requested.add(url);
    return const Stream.empty();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SearchRepository implements LibraryRepository {
  @override
  final AppDatabase db = _SearchDatabase();

  final calls = <(ContentKind, String, String?)>[];
  final pending = <(ContentKind, String), Completer<List<MediaItem>>>{};

  @override
  Future<List<MediaItem>> searchMedia(
    ContentKind kind,
    String query, {
    String? categoryId,
  }) {
    calls.add((kind, query, categoryId));
    final result = Completer<List<MediaItem>>();
    pending[(kind, query)] = result;
    return result.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SearchDatabase implements AppDatabase {
  @override
  Stream<String> get epgChanged => const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _SearchRepository repo;
  late _SearchArtworkCache artworkCache;

  setUp(() {
    repo = _SearchRepository();
    artworkCache = _SearchArtworkCache();
    // Assign before reading the default: its lazy initializer opens disk caches.
    CachedNetworkImageProvider.defaultCacheManager = artworkCache;
  });

  tearDown(() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  void useWindow(WidgetTester tester, Size size) {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  Widget search(
    String query, {
    ValueChanged<MediaItem>? onOpenMedia,
    bool Function(MediaItem)? isMediaAllowed,
    double textScale = 1,
  }) => MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: Scaffold(
      body: GlobalSearchView(
        repo: repo,
        query: query,
        channels: const [Channel(id: 'live', name: 'Live match')],
        channelsLoading: false,
        channelsError: null,
        hiddenMovieCategories: const {'hidden'},
        hiddenSeriesCategories: const {},
        isMediaAllowed: isMediaAllowed ?? (item) => item.id != 'locked',
        onPlayChannel: (_) {},
        onOpenMedia: onOpenMedia ?? (_) {},
      ),
    ),
  );

  testWidgets('waits for a typing pause and cancels pending searches', (
    tester,
  ) async {
    await tester.pumpWidget(search('s'));
    await tester.pump(const Duration(milliseconds: 799));
    expect(repo.calls, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    final singleLetterCalls = [
      (ContentKind.movie, 's', null),
      (ContentKind.series, 's', null),
    ];
    expect(repo.calls, singleLetterCalls);

    await tester.pumpWidget(search('sp'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(repo.calls, singleLetterCalls);
    await tester.pumpWidget(search('spa'));
    await tester.pump(const Duration(milliseconds: 799));
    expect(repo.calls, singleLetterCalls);
    await tester.pump(const Duration(milliseconds: 1));
    final expectedCalls = [
      ...singleLetterCalls,
      (ContentKind.movie, 'spa', null),
      (ContentKind.series, 'spa', null),
    ];
    expect(repo.calls, expectedCalls);

    await tester.pumpWidget(search('spa '));
    await tester.pump(const Duration(milliseconds: 800));
    expect(repo.calls, expectedCalls);

    await tester.pumpWidget(search('space'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpWidget(search(''));
    await tester.pump(const Duration(milliseconds: 800));
    expect(repo.calls, expectedCalls);

    await tester.pumpWidget(search('space'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 800));
    expect(repo.calls, expectedCalls);
    expect(tester.takeException(), isNull);
  });

  testWidgets('filters each section once until its data or parent changes', (
    tester,
  ) async {
    var permissionChecks = 0;
    var allowMovies = true;
    bool isAllowed(MediaItem item) {
      permissionChecks++;
      return allowMovies || item.kind != ContentKind.movie;
    }

    await tester.pumpWidget(search('match', isMediaAllowed: isAllowed));
    await tester.pump(const Duration(milliseconds: 800));
    repo.pending[(ContentKind.movie, 'match')]!.complete([
      for (var i = 0; i < 1000; i++)
        MediaItem(id: 'movie-$i', title: 'Movie $i', kind: ContentKind.movie),
    ]);
    await tester.pump();
    expect(permissionChecks, 1000);

    repo.pending[(ContentKind.series, 'match')]!.complete(const [
      MediaItem(id: 'series', title: 'Series', kind: ContentKind.series),
    ]);
    await tester.pump();
    expect(
      permissionChecks,
      1001,
      reason: 'the independent series reply must not re-filter every movie',
    );

    // A stable callback may read changed parental-control state.
    allowMovies = false;
    await tester.pumpWidget(search('match', isMediaAllowed: isAllowed));
    expect(permissionChecks, 2002);
    expect(find.text('No movies found'), findsOneWidget);
    expect(find.text('Movie 0'), findsNothing);
    expect(repo.calls, hasLength(2));
  });

  testWidgets('debounces, searches all categories and ignores stale replies', (
    tester,
  ) async {
    useWindow(tester, const Size(1280, 960));
    await tester.pumpWidget(search('old'));
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pumpWidget(search('ne'));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpWidget(search('new'));
    await tester.pump(const Duration(milliseconds: 800));
    expect(repo.calls, [
      (ContentKind.movie, 'old', null),
      (ContentKind.series, 'old', null),
      (ContentKind.movie, 'new', null),
      (ContentKind.series, 'new', null),
    ]);

    repo.pending[(ContentKind.movie, 'new')]!.complete(const [
      MediaItem(id: 'new', title: 'New movie', kind: ContentKind.movie),
      MediaItem(id: 'locked', title: 'Locked movie', kind: ContentKind.movie),
      MediaItem(
        id: 'hidden',
        title: 'Hidden movie',
        kind: ContentKind.movie,
        categoryId: 'hidden',
      ),
    ]);
    repo.pending[(ContentKind.series, 'new')]!.complete(const []);
    await tester.pump();
    expect(find.text('New movie'), findsOneWidget);
    expect(find.text('Hidden movie'), findsNothing);
    expect(find.text('Locked movie'), findsNothing);

    repo.pending[(ContentKind.movie, 'old')]!.complete(const [
      MediaItem(id: 'old', title: 'Old movie', kind: ContentKind.movie),
    ]);
    repo.pending[(ContentKind.series, 'old')]!.complete(const []);
    await tester.pump();
    expect(find.text('New movie'), findsOneWidget);
    expect(find.text('Old movie'), findsNothing);

    await tester.pumpWidget(search('unmounted'));
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pumpWidget(const SizedBox());
    repo.pending[(ContentKind.movie, 'unmounted')]!.complete(const []);
    repo.pending[(ContentKind.series, 'unmounted')]!.complete(const []);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'one failed section preserves other results and retries independently',
    (tester) async {
      MediaItem? opened;
      await tester.pumpWidget(
        search('match', onOpenMedia: (item) => opened = item),
      );
      await tester.pump(const Duration(milliseconds: 800));
      repo.pending[(ContentKind.movie, 'match')]!.completeError(
        Exception('Unavailable'),
      );
      repo.pending[(ContentKind.series, 'match')]!.complete(const [
        MediaItem(
          id: 'series',
          title: 'Matching series',
          kind: ContentKind.series,
        ),
      ]);
      await tester.pump();
      expect(find.text('Live match'), findsOneWidget);
      expect(find.text('Matching series'), findsOneWidget);
      await tester.ensureVisible(find.text('Matching series'));
      await tester.pump();
      await tester.tap(find.text('Matching series'));
      expect(opened?.id, 'series');
      await tester.ensureVisible(find.text('Retry'));
      await tester.pump();
      await tester.tap(find.text('Retry'));
      await tester.pump();
      expect(repo.calls.length, 3);
      expect(repo.calls.last, (ContentKind.movie, 'match', null));
      repo.pending[(ContentKind.movie, 'match')]!.complete(const []);
      await tester.pump();
      expect(find.text('No movies found'), findsOneWidget);
      expect(find.text('Matching series'), findsOneWidget);
    },
  );

  for (final (size, textScale) in const [
    (Size(1280, 960), 1.0),
    (Size(390, 844), 1.0),
    (Size(667, 375), 1.0),
    (Size(390, 844), 2.0),
  ]) {
    testWidgets('search artwork and card actions fit $size at $textScale', (
      tester,
    ) async {
      useWindow(tester, size);
      final opened = <MediaItem>[];
      const movie = MediaItem(
        id: 'movie',
        title: 'Matching movie',
        kind: ContentKind.movie,
        poster: 'https://artwork.invalid/movie.jpg',
        year: '2025',
      );
      const series = MediaItem(
        id: 'series',
        title: 'Matching series',
        kind: ContentKind.series,
        poster: 'https://artwork.invalid/series.jpg',
        year: '2026',
      );
      await tester.pumpWidget(
        search('match', onOpenMedia: opened.add, textScale: textScale),
      );
      await tester.pump(const Duration(milliseconds: 800));
      repo.pending[(ContentKind.movie, 'match')]!.complete(const [movie]);
      repo.pending[(ContentKind.series, 'match')]!.complete(const [series]);
      await tester.pump();
      await tester.pump();

      final isGrid = size.width >= 600 && size.height >= 500;
      for (final item in const [movie, series]) {
        final route = 'search.${item.kind.name}.${item.id}';
        final card = find.byKey(ValueKey(route));
        await tester.ensureVisible(card);
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          find.descendant(
            of: card,
            matching: find.byType(isGrid ? MediaGridTile : MediaListTile),
            matchRoot: true,
          ),
          findsOneWidget,
        );
        final poster = find.descendant(
          of: card,
          matching: find.byType(CachedNetworkImage),
        );
        final image = tester.widget<CachedNetworkImage>(poster);
        expect(image.imageUrl, item.poster);
        expect(image.fit, BoxFit.cover);
        expect(image.memCacheWidth, isNotNull);
        expect(image.memCacheWidth, greaterThan(0));
        expect(image.memCacheHeight, isNull);
        final imageSize = tester.getSize(poster);
        if (isGrid) {
          expect(
            imageSize.aspectRatio,
            closeTo(MediaGridMetrics.posterAspectRatio, 0.001),
          );
        } else {
          expect(imageSize, const Size(58, 84));
        }

        await tester.tap(card);
        expect(opened.last, same(item));
        final action = tester.widget<FocusableActionDetector>(
          find.descendant(
            of: card,
            matching: find.byType(FocusableActionDetector),
          ),
        );
        action.focusNode!.requestFocus();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(focusRouteKey(FocusManager.instance.primaryFocus), route);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        expect(opened.last, same(item));
        expect(tester.takeException(), isNull);
      }
      expect(opened, [movie, movie, series, series]);
      expect(
        artworkCache.requested,
        containsAll([movie.poster, series.poster]),
      );
    });
  }

  testWidgets('missing movie and series artwork retains usable cards', (
    tester,
  ) async {
    useWindow(tester, const Size(1280, 960));
    await tester.pumpWidget(search('match'));
    await tester.pump(const Duration(milliseconds: 800));
    repo.pending[(ContentKind.movie, 'match')]!.complete(const [
      MediaItem(
        id: 'movie',
        title: 'No movie artwork',
        kind: ContentKind.movie,
      ),
    ]);
    repo.pending[(ContentKind.series, 'match')]!.complete(const [
      MediaItem(
        id: 'series',
        title: 'No series artwork',
        kind: ContentKind.series,
        poster: '',
      ),
    ]);
    await tester.pump();

    for (final (route, title, icon) in const [
      ('search.movie.movie', 'No movie artwork', Icons.movie_outlined),
      ('search.series.series', 'No series artwork', Icons.tv_outlined),
    ]) {
      final card = find.byKey(ValueKey(route));
      await tester.ensureVisible(card);
      expect(
        find.descendant(of: card, matching: find.text(title)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: card, matching: find.byIcon(icon)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: card, matching: find.byType(CachedNetworkImage)),
        findsNothing,
      );
    }
    expect(artworkCache.requested, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
