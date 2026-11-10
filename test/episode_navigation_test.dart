import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/data/load_token.dart';
import 'package:iptvs/player/episode_navigation.dart';
import 'package:iptvs/sources/demo_source.dart';
import 'package:iptvs/sources/source.dart';

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
