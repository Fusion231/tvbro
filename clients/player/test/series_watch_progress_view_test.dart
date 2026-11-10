import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
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

const _series = MediaItem(
  id: 'demo-series-1',
  title: 'Codec Test Series',
  kind: ContentKind.series,
  categoryId: 'demo-series',
);
const _otherSeries = MediaItem(
  id: 'caminandes',
  title: 'Caminandes',
  kind: ContentKind.series,
);

class _ArtworkCache implements BaseCacheManager {
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

class _TrackingDemoSource extends DemoSource {
  final episodeLoads = <String?>[];
  final episodePages = <(String, int), MediaPage>{};

  @override
  Future<MediaPage> mediaItemsPage(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    int page = 1,
  }) {
    if (kind == ContentKind.episode) {
      episodeLoads.add(parent?.id);
      final response = episodePages[(parent?.id ?? '', page)];
      if (response != null) return Future.value(response);
    }
    return super.mediaItemsPage(
      kind,
      categoryId: categoryId,
      parent: parent,
      page: page,
    );
  }
}

void main() {
  late Directory directory;
  late AppDatabase db;
  late _TrackingDemoSource source;
  late LibraryRepository repo;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    CachedNetworkImageProvider.defaultCacheManager = _ArtworkCache();
    directory = Directory.systemTemp.createTempSync('tvbro_series_summary');
    db = await AppDatabase.openAt('${directory.path}/test.db');
    source = _TrackingDemoSource();
    repo = LibraryRepository(source: source, db: db);
  });

  tearDown(() async {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    await db.close();
    directory.deleteSync(recursive: true);
  });

  // SQLite FFI replies from its isolate need the real event loop, as in the
  // existing media-details tests. Each wait is bounded and asserts its target.
  Future<void> pumpUntil(WidgetTester tester, Finder finder) async {
    for (var attempt = 0; attempt < 80; attempt++) {
      if (finder.evaluate().isNotEmpty) break;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(finder, findsWidgets);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
  }

  Future<List<MediaItem>> seedSeason(
    WidgetTester tester, {
    int index = 0,
    MediaItem series = _series,
  }) async {
    return (await tester.runAsync(() async {
      final seasons = await repo.loadMedia(ContentKind.season, parent: series);
      final episodes = await repo.loadMedia(
        ContentKind.episode,
        parent: seasons.items[index],
      );
      return episodes.items;
    }))!;
  }

  Future<void> save(
    WidgetTester tester,
    String episodeId, {
    bool finished = true,
    String sourceId = 'demo',
  }) async {
    await tester.runAsync(
      () => db.savePlaybackPosition(
        sourceId,
        ContentKind.episode,
        episodeId,
        position: Duration(minutes: finished ? 19 : 3),
        duration: const Duration(minutes: 20),
      ),
    );
  }

  Future<void> seedPartialFirstSeason(WidgetTester tester) async {
    final firstSeason = await seedSeason(tester);
    await seedSeason(tester, index: 1);
    await tester.runAsync(
      () => db.replaceMediaLibrary(
        'demo',
        ContentKind.episode,
        const [],
        firstSeason,
        parentId: firstSeason.first.parentId,
        loadedPages: 1,
        totalPages: 2,
      ),
    );
    for (final episode in firstSeason) {
      await save(tester, episode.id);
    }
    source.episodeLoads.clear();
  }

  Future<void> open(
    WidgetTester tester, {
    ValueChanged<MediaItem>? onPlayEpisode,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          body: MediaDetailsSheet(
            repo: repo,
            item: _series,
            favorite: false,
            onToggleFavorite: () {},
            onPlay: null,
            onPlayEpisode: onPlayEpisode ?? (_) {},
          ),
        ),
      ),
    );
    await pumpUntil(tester, find.text('Season 1'));
  }

  Finder primary() => find.byKey(const ValueKey('media.details.play'));
  Finder summary() =>
      find.byKey(const ValueKey('media.details.seriesProgress'));

  testWidgets('collapsed series shows watched history and the next episode', (
    tester,
  ) async {
    await seedSeason(tester);
    await save(tester, 'bbb');
    MediaItem? played;
    await open(tester, onPlayEpisode: (episode) => played = episode);
    await pumpUntil(tester, find.text('Next episode: S1E2, Apple BipBop'));

    expect(summary(), findsOneWidget);
    expect(find.text('Watched episodes: 1'), findsOneWidget);
    expect(find.text('Last watched: S1E1, Big Buck Bunny'), findsOneWidget);
    expect(find.text('1. Big Buck Bunny'), findsNothing);
    expect(find.text('View episodes'), findsOneWidget);
    expect(
      find.descendant(of: primary(), matching: find.text('Play S1E2')),
      findsOneWidget,
    );

    await tester.ensureVisible(primary());
    await tester.tap(primary());
    await tester.pump();
    expect(played?.id, 'bipbop');
    expect(played?.kind, ContentKind.episode);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'resume hands off the episode and checkpoint advances the summary',
    (tester) async {
      await seedSeason(tester);
      await save(tester, 'bbb', finished: false);
      MediaItem? played;
      await open(tester, onPlayEpisode: (episode) => played = episode);
      await pumpUntil(tester, find.text('Resume S1E1'));
      final detailsState = tester.state(find.byType(MediaDetailsSheet));
      expect(find.text('Watched episodes: 0'), findsOneWidget);

      await tester.ensureVisible(primary());
      await tester.tap(primary());
      await tester.pump();
      expect(played?.id, 'bbb');

      await save(tester, 'bbb');
      await pumpUntil(tester, find.text('Play S1E2'));
      expect(tester.state(find.byType(MediaDetailsSheet)), same(detailsState));
      expect(find.text('Watched episodes: 1'), findsOneWidget);
      expect(find.text('Next episode: S1E2, Apple BipBop'), findsOneWidget);
      expect(find.text('Resume S1E1'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('finished season prepares its successor without expanding it', (
    tester,
  ) async {
    final firstSeason = await seedSeason(tester);
    for (final episode in firstSeason) {
      await save(tester, episode.id);
    }
    source.episodeLoads.clear();
    await open(tester);
    await pumpUntil(
      tester,
      find.text('Next episode: S2E1, Apple BipBop · HEVC'),
    );

    expect(find.text('Watched episodes: 3'), findsOneWidget);
    expect(find.text('Last watched: S1E3, Tears of Steel'), findsOneWidget);
    expect(find.text('Play S2E1'), findsOneWidget);
    expect(source.episodeLoads, ['demo-series-1:season:2']);
    expect(find.text('1. Apple BipBop · HEVC'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('complete series reports completion and keeps episode browsing', (
    tester,
  ) async {
    final episodes = [
      ...await seedSeason(tester),
      ...await seedSeason(tester, index: 1),
    ];
    for (final episode in episodes) {
      await save(tester, episode.id);
    }
    await open(tester);
    await pumpUntil(tester, find.text('All available episodes watched'));

    expect(find.text('Watched episodes: 6'), findsOneWidget);
    expect(find.text('View episodes'), findsOneWidget);
    expect(find.textContaining('Next episode:'), findsNothing);
    expect(
      find.descendant(of: primary(), matching: find.text('View episodes')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'unrelated series and another source do not create watch history',
    (tester) async {
      await seedSeason(tester);
      final unrelated = await seedSeason(tester, series: _otherSeries);
      await save(tester, unrelated.first.id);
      await save(tester, 'bbb', sourceId: 'another-source');
      source.episodeLoads.clear();
      await open(tester);
      // Allow the same SQLite read path used by a populated summary to finish.
      await tester.runAsync(() async {
        await db.readCachedSeriesEpisodes('demo', _series.id);
      });
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pump();

      expect(summary(), findsNothing);
      expect(find.text('View episodes'), findsOneWidget);
      expect(source.episodeLoads, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('history and continuation controls fit phone and TV widths', (
    tester,
  ) async {
    await seedSeason(tester);
    await save(tester, 'bbb');
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final size in const [Size(390, 844), Size(960, 540)]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      await open(tester);
      await pumpUntil(tester, find.text('Play S1E2'));
      await tester.ensureVisible(summary());
      await tester.pumpAndSettle();
      expect(summary().hitTestable(), findsOneWidget);
      await tester.ensureVisible(primary());
      await tester.pumpAndSettle();
      expect(primary().hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull, reason: 'window $size');
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('an incomplete episode cache neither skips ahead nor completes', (
    tester,
  ) async {
    await seedPartialFirstSeason(tester);
    await open(tester);
    await pumpUntil(tester, find.text('Last watched: S1E3, Tears of Steel'));

    expect(find.text('Watched episodes: 3'), findsOneWidget);
    expect(find.textContaining('Next episode:'), findsNothing);
    expect(find.text('Play S2E1'), findsNothing);
    expect(find.text('View episodes'), findsOneWidget);
    expect(source.episodeLoads, isEmpty);

    // Even all known episodes watched cannot establish completion while the
    // provider still advertises an unloaded page in the preceding season.
    for (final id in [
      'bipbop_hevc_episode',
      'sintel_trailer_episode',
      'peertube_hls_episode',
    ]) {
      await save(tester, id);
    }
    await pumpUntil(tester, find.text('Watched episodes: 6'));
    expect(find.text('All available episodes watched'), findsNothing);
    expect(find.text('View episodes'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('loading the final episode page updates the next season action', (
    tester,
  ) async {
    await seedPartialFirstSeason(tester);
    const finalEpisode = MediaItem(
      id: 'codec-final-episode',
      title: 'Final codec fixture',
      kind: ContentKind.episode,
      parentId: 'demo-series-1:season:1',
      seasonNumber: 1,
      episodeNumber: 4,
    );
    // A checkpoint can predate the current partial provider cache, for
    // example after a cache refresh or history restored from another device.
    await save(tester, finalEpisode.id);
    source.episodePages[('demo-series-1:season:1', 2)] = const MediaPage(
      items: [finalEpisode],
      page: 2,
      totalPages: 2,
    );
    await open(tester);
    await pumpUntil(tester, find.text('Watched episodes: 3'));
    expect(find.text('Play S2E1'), findsNothing);

    await tester.ensureVisible(find.text('Season 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Season 1'));
    await pumpUntil(tester, find.text('Load page 2'));
    expect(source.episodeLoads, isEmpty);
    await tester.ensureVisible(find.text('Load page 2'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Load page 2'));
    // Completion of paging and the rail's history reread are separate async
    // steps. Wait for the newly exposed episode's history in the summary.
    await pumpUntil(
      tester,
      find.text('Last watched: S1E4, Final codec fixture'),
    );

    expect(find.text('Watched episodes: 4'), findsOneWidget);
    expect(find.text('Play S2E1'), findsOneWidget);
    expect(
      find.text('Next episode: S2E1, Apple BipBop · HEVC'),
      findsOneWidget,
    );
    expect(source.episodeLoads, ['demo-series-1:season:1']);
    expect(find.text('Load page 2'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
