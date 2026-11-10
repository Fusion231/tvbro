import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/data/load_token.dart';
import 'package:iptvs/data/metadata_provider.dart';
import 'package:iptvs/data/source_identity_migration.dart';
import 'package:iptvs/player/episode_navigation.dart';
import 'package:iptvs/sources/demo_source.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/stalker_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late AppDatabase db;
  late LibraryRepository repo;

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('tvbro_episode_navigation');
    db = await AppDatabase.openAt('${directory.path}/library.db');
    repo = LibraryRepository(source: DemoSource(), db: db);
  });

  tearDown(() async {
    await db.close();
    directory.deleteSync(recursive: true);
  });

  test('movie playback has no episode navigation', () async {
    expect(
      await loadPlaybackEpisodes(
        repo,
        const MediaItem(id: 'movie', title: 'Film', kind: ContentKind.movie),
      ),
      isEmpty,
    );
  });

  test('loads the whole series in season and episode order', () async {
    final series = await repo.loadMedia(ContentKind.series);
    final selectedSeries = series.items.firstWhere(
      (item) => item.id == 'demo-series-1',
    );
    final seasons = await repo.loadMedia(
      ContentKind.season,
      parent: selectedSeries,
    );
    final secondSeason = seasons.items.firstWhere(
      (item) => item.seasonNumber == 2,
    );
    final episodes = await repo.loadMedia(
      ContentKind.episode,
      parent: secondSeason,
    );
    final playlist = await loadPlaybackEpisodes(repo, episodes.items.first);

    expect(playlist, hasLength(6));
    expect(playlist.map((episode) => episode.seasonNumber), [1, 1, 1, 2, 2, 2]);
    expect(playlist.map((episode) => episode.episodeNumber), [
      1,
      2,
      3,
      1,
      2,
      3,
    ]);
    expect(playlist.map((episode) => episode.id).toSet(), hasLength(6));
    expect(
      playlist.any((episode) => episode.parentId == secondSeason.id),
      isTrue,
    );
    final withArtwork = playlist.firstWhere((episode) => episode.id == 'bbb');
    expect(withArtwork.poster, isNotEmpty);
    expect(withArtwork.description, isNotEmpty);
    expect(withArtwork.durationSeconds, 634);
    final withoutArtwork = playlist.firstWhere(
      (episode) => episode.id == 'bipbop',
    );
    expect(withoutArtwork.backdrop, selectedSeries.backdrop);
    final cached = await repo.db.readMediaItemsByIds(
      repo.source.id,
      ContentKind.episode,
      ['bipbop'],
    );
    expect(cached.single.backdrop, isNull);
  });

  test('an episode without cached parents still remains playable', () async {
    const orphan = MediaItem(
      id: 'orphan',
      title: 'Odcinek',
      kind: ContentKind.episode,
      parentId: 'uncached-season',
    );
    expect(await loadPlaybackEpisodes(repo, orphan), [orphan]);
  });

  test(
    'Stalker fetches only the requested season and reuses its episode cache',
    () async {
      final series = await repo.loadMedia(ContentKind.series);
      final seasons = await repo.loadMedia(
        ContentKind.season,
        parent: series.items.firstWhere((item) => item.id == 'demo-series-1'),
      );
      final first = seasons.items.firstWhere((item) => item.seasonNumber == 1);
      final second = seasons.items.firstWhere((item) => item.seasonNumber == 2);
      final portal = _OnDemandStalkerSource();
      addTearDown(portal.dispose);
      await db.migrateSourceCacheIdentity(
        portal.id,
        portal.name,
        sourceCacheIdentityForSource(portal)!,
      );
      await db.replaceMediaLibrary(
        portal.id,
        ContentKind.series,
        series.categories,
        series.items,
      );
      await db.replaceMediaLibrary(
        portal.id,
        ContentKind.season,
        seasons.categories,
        seasons.items,
        parentId: seasons.parentId,
      );
      repo = LibraryRepository(source: portal, db: db);

      final opened = await repo.loadMedia(ContentKind.episode, parent: first);
      final current = opened.items.first;
      final playlist = await loadPlaybackEpisodes(repo, current);
      expect(playlist.map((item) => item.episodeNumber), [1, 2, 3, 4, 5]);
      expect(playlist.every((item) => item.parentId == first.id), isTrue);
      expect(portal.pages, [
        for (var page = 1; page <= 5; page++) '${first.id}:$page',
      ]);
      expect(
        await db.readMediaItems(
          portal.id,
          ContentKind.episode,
          parentId: second.id,
        ),
        isEmpty,
      );

      portal.pages.clear();
      final repeated = await loadPlaybackEpisodes(repo, current);
      expect(repeated.map((item) => item.id), playlist.map((item) => item.id));
      expect(portal.pages, isEmpty);

      // Visiting another season is the demand that may fetch its own pages.
      final nextSeason = await repo.loadMedia(
        ContentKind.episode,
        parent: second,
      );
      final nextPlaylist = await loadPlaybackEpisodes(
        repo,
        nextSeason.items.first,
      );
      expect(nextPlaylist.every((item) => item.parentId == second.id), isTrue);
      expect(portal.pages, [
        for (var page = 1; page <= 5; page++) '${second.id}:$page',
      ]);
    },
  );

  for (final paginated in [false, true]) {
    test('playback skips external metadata, including paging=$paginated', () async {
      repo = LibraryRepository(
        source: paginated ? _PagedDemoSource() : DemoSource(),
        db: db,
      );
      final series = await repo.loadMedia(ContentKind.series);
      final seasons = await repo.loadMedia(
        ContentKind.season,
        parent: series.items.firstWhere((item) => item.id == 'demo-series-1'),
      );
      final season = seasons.items.firstWhere((item) => item.seasonNumber == 1);
      final episodes = await repo.loadMedia(
        ContentKind.episode,
        parent: season,
      );
      final current = episodes.items.first;
      await db.cacheExternalMetadata(
        repo.source.id,
        current,
        ExternalMetadata(
          provider: 'test',
          providerKey: current.id,
          overview: 'Already cached synopsis',
          refreshedAt: DateTime(2026),
        ),
      );
      final metadata = _CountingMetadataProvider();
      repo = LibraryRepository(
        source: repo.source,
        db: db,
        metadataProvider: metadata,
      );

      final playlist = await loadPlaybackEpisodes(repo, current);
      expect(metadata.lookups, 0);
      expect(playlist, hasLength(paginated ? 8 : 6));
      expect(
        playlist.firstWhere((item) => item.id == current.id).description,
        'Already cached synopsis',
      );
      // Browsing still enriches items after playback seeded the provider cache.
      await repo.loadMedia(ContentKind.episode, parent: season);
      expect(metadata.lookups, greaterThan(0));
    });
  }

  test(
    'finishes paginated episodes after a sibling load was cancelled',
    () async {
      repo = LibraryRepository(source: _PagedDemoSource(), db: db);
      final series = await repo.loadMedia(ContentKind.series);
      final seasons = await repo.loadMedia(
        ContentKind.season,
        parent: series.items.firstWhere((item) => item.id == 'demo-series-1'),
      );
      final season = seasons.items.firstWhere((item) => item.seasonNumber == 1);
      final firstPage = await repo.loadMedia(
        ContentKind.episode,
        parent: season,
      );
      repo.loadToken = LoadToken()..cancel();

      final playlist = await loadPlaybackEpisodes(repo, firstPage.items.first);
      expect(
        playlist
            .where((episode) => episode.parentId == season.id)
            .map((episode) => episode.episodeNumber),
        [1, 2, 3, 4, 5],
      );
      expect(repo.loadToken, isNull);
    },
  );
}

class _CountingMetadataProvider extends MetadataProvider {
  int lookups = 0;

  @override
  String get provider => 'test';

  @override
  String get authMode => 'none';

  @override
  Future<ExternalMetadata?> search(MediaItem item) async {
    lookups++;
    return null;
  }

  @override
  Future<ExternalMetadata?> seasonMetadata(
    MediaItem series,
    MediaItem season,
  ) => search(season);

  @override
  Future<ExternalMetadata?> episodeMetadata(
    MediaItem season,
    MediaItem episode,
  ) => search(episode);

  @override
  void close() {}
}

class _PagedDemoSource extends DemoSource {
  @override
  Future<MediaPage> mediaItemsPage(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    int page = 1,
  }) async {
    if (kind == ContentKind.episode && parent?.seasonNumber == 1) {
      return MediaPage(
        items: [
          MediaItem(
            id: 'paged-$page',
            title: 'Episode $page',
            kind: ContentKind.episode,
            parentId: parent!.id,
            seasonNumber: 1,
            episodeNumber: page,
          ),
        ],
        page: page,
        totalPages: 5,
      );
    }
    return super.mediaItemsPage(
      kind,
      categoryId: categoryId,
      parent: parent,
      page: page,
    );
  }
}

class _OnDemandStalkerSource extends StalkerSource {
  _OnDemandStalkerSource()
    : super(
        sourceId: 'stalker-on-demand',
        portal: 'https://provider.test',
        mac: '00:00:00:00:00:00',
      );

  final pages = <String>[];

  @override
  Future<void> connect() async {}

  @override
  Future<List<MediaCategory>> mediaCategories(ContentKind kind) async => [];

  @override
  Future<MediaPage> mediaItemsPage(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    int page = 1,
  }) async {
    expect(kind, ContentKind.episode);
    pages.add('${parent!.id}:$page');
    return MediaPage(
      items: [
        MediaItem(
          id: '${parent.id}:episode:$page',
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
