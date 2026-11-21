import 'dart:async';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/data/load_token.dart';
import 'package:iptvs/data/metadata_provider.dart';
import 'package:iptvs/data/net.dart';
import 'package:iptvs/data/secret_locator_vault.dart';
import 'package:iptvs/data/source_identity_migration.dart';
import 'package:iptvs/sources/m3u_source.dart';
import 'package:iptvs/sources/source.dart';

const _mixed = '''#EXTM3U
#EXTINF:-1 group-title="Filmowe",Cinema TV
https://example.invalid/live/10.ts
#EXTINF:-1 group-title="Movies" tvg-logo="https://example.invalid/poster.png",Movie (2024)
#EXTVLCOPT:http-user-agent=Fixture Agent
#EXTVLCOPT:http-referrer=https://example.invalid/
https://example.invalid/movie/11.mkv
#EXTINF:-1 group-title="Series",Show S02 E10
https://example.invalid/series/210.mp4
#EXTINF:-1 group-title="Series",Show S01 E02
https://example.invalid/series/102.mp4
#EXTINF:-1 group-title="Series" catchup-source="https://example.invalid/private-catchup",Show S01 E01
#EXTVLCOPT:http-user-agent=Episode Agent
https://example.invalid/series/101.mp4
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a fresh legacy catalog shares its background upgrade with a series opened during it',
    () => HttpOverrides.runWithHttpOverrides(() async {
      ProviderRequestGate.instance.debugReset();
      FlutterSecureStorage.setMockInitialValues({});
      final directory = Directory.systemTemp.createTempSync('m3u_upgrade_');
      final db = await AppDatabase.openAt('${directory.path}/library.db');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final started = Completer<void>();
      final release = Completer<void>();
      final retryStarted = Completer<void>();
      final releaseRetry = Completer<void>();
      final metadata = _DelayedEpisodeMetadata();
      var requests = 0, status = 884;
      server.listen((request) async {
        requests++;
        if (requests == 1) {
          started.complete();
          await release.future;
        }
        if (requests == 2) {
          retryStarted.complete();
          await releaseRetry.future;
        }
        try {
          request.response.statusCode = status;
          if (status == 200) request.response.write(_mixed);
          await request.response.close();
        } on SocketException {
          // The test cancels an in-flight response.
        } on HttpException {
          // The test cancels an in-flight response.
        }
      });
      M3uSource buildSource() => M3uSource(
        sourceId: 'upgrade',
        playlistUrl: 'http://127.0.0.1:${server.port}/get.php',
      );
      final source = buildSource();
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        if (!releaseRetry.isCompleted) releaseRetry.complete();
        if (!metadata.release.isCompleted) metadata.release.complete();
        await source.dispose();
        await server.close(force: true);
        await db.close();
        directory.deleteSync(recursive: true);
      });
      final parsed = parseM3uPlaylist(_mixed);
      final catalog = parsed.media;
      final series = catalog.roots[ContentKind.series]!.single;
      const oldSeries = MediaItem(
        id: 'old-title', title: 'Old title', kind: ContentKind.series,
      );
      const oldSeason = MediaItem(
        id: 'old-season', parentId: 'old-title',
        title: 'Old season', kind: ContentKind.season,
      );
      await db.migrateSourceCacheIdentity(
        source.id, source.name, sourceCacheIdentityForSource(source)!,
      );
      await db.replaceLibrary(source.id, source.name, parsed.categories,
          parsed.channels, completeCatalog: true);
      for (final kind in [ContentKind.movie, ContentKind.series]) {
        await db.replaceMediaLibrary(
          source.id, kind, catalog.categories[kind]!, [
            ...catalog.roots[kind]!,
            if (kind == ContentKind.series) oldSeries,
          ],
          completeCatalog: true,
        );
      }
      await db.replaceMediaLibrary(
        source.id, ContentKind.season, [], [oldSeason], parentId: oldSeries.id,
      );
      final oldStamp = await db.lastCatalogSynced(source.id, ContentKind.series);
      final repo = LibraryRepository(
        source: source, db: db, metadataProviders: [metadata],
      );
      final cancelled = expectLater(
        repo.backfillM3uSeriesCache(), throwsA(isA<LoadCancelledException>()),
      );
      repo.cancelCatalogSync();
      await cancelled;
      expect(requests, 0);
      final background = repo.synchronizeCatalog().then<Object?>(
        (_) => null, onError: (Object error) => error,
      );
      await Future.any([started.future, background]);
      expect(requests, 1);
      final opened = repo.loadMedia(ContentKind.season, parent: series);
      final failure = expectLater(opened, throwsA(isA<StateError>()));
      release.complete();
      await failure;
      expect(await background, isA<StateError>());
      expect(await db.lastCatalogSynced(source.id, ContentKind.series), oldStamp);
      final cached = await repo.loadMedia(
        ContentKind.season, parent: oldSeries, enrichChildren: false,
      );
      expect(cached.items.single.id, oldSeason.id);
      await expectLater(
        repo.loadMedia(ContentKind.season, parent: series),
        throwsA(isA<StateError>()),
      );
      expect(repo.m3uSeriesBackfill.value, M3uSeriesBackfillStatus.failed);
      expect(requests, 1);

      status = 200;
      final stopped = expectLater(
        repo.backfillM3uSeriesCache(retry: true),
        throwsA(isA<LoadCancelledException>()),
      );
      await retryStarted.future;
      repo.cancelCatalogSync();
      releaseRetry.complete();
      await stopped;
      expect(await db.m3uSeriesCacheComplete(source.id), isFalse);
      expect(await db.lastCatalogSynced(source.id, ContentKind.series), oldStamp);
      expect(repo.m3uSeriesBackfill.value, isNull);

      final staleRead = repo.loadMedia(ContentKind.season, parent: oldSeries);
      await metadata.started.future;
      expect(await Future.wait([
        repo.backfillM3uSeriesCache(retry: true),
        repo.backfillM3uSeriesCache(retry: true),
      ]), [true, true]);
      final refreshed = await repo
          .loadMedia(ContentKind.season, parent: oldSeries)
          .timeout(const Duration(seconds: 5));
      expect(refreshed.items, isEmpty);
      metadata.release.complete();
      await staleRead;
      expect(requests, 3);
      final restartedSource = buildSource();
      addTearDown(restartedSource.dispose);
      final restarted = LibraryRepository(source: restartedSource, db: db);
      await restarted.synchronizeCatalog();
      final seasons = await restarted.loadMedia(ContentKind.season, parent: series);
      expect(seasons.items.map((season) => season.seasonNumber), [1, 2]);
      expect(
        (await restarted.loadMedia(ContentKind.season, parent: oldSeries)).items,
        isEmpty,
      );
      expect(requests, 3);
    }, _RealHttpOverrides()),
  );

  test(
    'classifies mixed M3U and groups numerically ordered seasons and episodes',
    () {
      final parsed = parseM3uPlaylist(_mixed);
      expect(parsed.channels.map((c) => c.name), ['Cinema TV']);
      expect(parsed.categories.map((c) => c.title), ['Filmowe']);
      expect(
        parsed.media.roots[ContentKind.movie]!.single.title,
        'Movie (2024)',
      );
      final series = parsed.media.roots[ContentKind.series]!.single;
      expect(series.title, 'Show');
      final seasons = parsed.media.children[series.id]!;
      expect(seasons.map((s) => s.seasonNumber), [1, 2]);
      expect(
        parsed.media.children[seasons.first.id]!.map((e) => e.episodeNumber),
        [1, 2],
      );
      expect(parsed.media.children[seasons.last.id]!.single.episodeNumber, 10);
    },
  );

  test(
    'explicit live and radio plus live paths override movie/episode guesses',
    () {
      final parsed = parseM3uPlaylist('''#EXTM3U
#EXTINF:-1 group-title="Movies",Film TV
https://example.invalid/1
#EXTINF:-1 stream-type="live",Show S01E01
https://example.invalid/live.mp4
#EXTINF:-1 radio="true",Radio
https://example.invalid/radio.mp4
#EXTINF:-1,Show S01E01
https://example.invalid/live/2.mkv
#EXTINF:-1,Plain HLS
https://example.invalid/playlist.m3u8
#EXTINF:-1,Plain DASH
https://example.invalid/stream.mpd
''');
      expect(parsed.channels, hasLength(6));
      expect(parsed.media.roots[ContentKind.movie], isEmpty);
      expect(parsed.media.roots[ContentKind.series], isEmpty);
    },
  );

  test(
    'recognizes local VOD hints without probing HLS or extensionless URLs',
    () {
      final parsed = parseM3uPlaylist('''#EXTM3U
#EXTINF:-1 media="true",Explicit media
https://example.invalid/live/one.ts
#EXTINF:-1,Playlist property
#EXT-X-PLAYLIST-TYPE:VOD
https://example.invalid/two.m3u8
#EXTINF:-1 media-type="movie",Explicit type
https://example.invalid/three
#EXTINF:-1 media-dir="/films",Media directory
https://example.invalid/four
#EXTINF:-1,File extension
#EXTGRP:Films
https://example.invalid/five.MP4?signature=fixture
#EXTINF:-1,Movie S01E02
https://example.invalid/movie/six.mkv
''');
      expect(parsed.channels, isEmpty);
      expect(parsed.media.roots[ContentKind.movie], hasLength(6));
      expect(parsed.media.roots[ContentKind.series], isEmpty);
      expect(parsed.media.roots[ContentKind.movie]![4].categoryId, 'Films');
    },
  );

  test('series identities survive reordering and separate language categories', () {
    String entry(String title, String group, String id) =>
        '#EXTINF:-1 group-title="$group",$title\nhttps://example.invalid/series/$id.mp4\n';
    final rows = [
      entry('Show 1x02', 'PL', '1'),
      entry('Show Season 1 Episode 1', 'PL', '2'),
      entry('Show Sezon 2 Odcinek 1', 'PL', '3'),
      entry('Show S01E01', 'EN', '4'),
      entry('Unnumbered special', 'PL', '5'),
    ];
    final first = parseM3uPlaylist('#EXTM3U\n${rows.join()}');
    final second = parseM3uPlaylist('#EXTM3U\n${rows.reversed.join()}');
    expect(first.media.roots[ContentKind.series], hasLength(3));
    expect(
      first.media.roots[ContentKind.series]!.map((s) => s.id).toSet(),
      second.media.roots[ContentKind.series]!.map((s) => s.id).toSet(),
    );
    expect(
      first.media.children.values
          .expand((v) => v)
          .where((v) => v.kind == ContentKind.episode),
      hasLength(5),
    );
  });

  test(
    'pagination and searching use the whole already downloaded catalog',
    () => HttpOverrides.runWithHttpOverrides(() async {
      ProviderRequestGate.instance.debugReset();
      FlutterSecureStorage.setMockInitialValues({});
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requests = 0;
      server.listen((request) async {
        requests++;
        request.response.write('#EXTM3U\n');
        for (var i = 1; i <= 205; i++) {
          request.response.write(
            '#EXTINF:-1 group-title="Movies",Movie $i\nhttps://example.invalid/movie/$i.mp4\n',
          );
        }
        await request.response.close();
      });
      final source = M3uSource(
        sourceId: 'pages',
        playlistUrl: 'http://127.0.0.1:${server.port}/list',
      );
      addTearDown(() async {
        await source.dispose();
        await server.close(force: true);
      });
      final one = await source.mediaItemsPage(ContentKind.movie);
      final three = await source.mediaItemsPage(ContentKind.movie, page: 3);
      expect(one.items, hasLength(100));
      expect(one.totalPages, 3);
      expect(three.items, hasLength(5));
      expect(three.hasMore, isFalse);
      expect(
        (await source.searchMedia(ContentKind.movie, 'Movie 205')).single.title,
        'Movie 205',
      );
      expect(await source.allMediaItems(ContentKind.movie), hasLength(205));
      expect(requests, 1);
    }, _RealHttpOverrides()),
  );

  test(
    'M3U import saves the full series tree for offline browsing after restart',
    () => HttpOverrides.runWithHttpOverrides(() async {
      ProviderRequestGate.instance.debugReset();
      FlutterSecureStorage.setMockInitialValues({});
      final directory = Directory.systemTemp.createTempSync('m3u_media');
      final path = '${directory.path}/library.db';
      var db = await AppDatabase.openAt(path);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requests = 0, status = 200;
      var playlist = '$_mixed'
          '#EXTINF:-1 group-title="Mirrors",Show S01 E01\n'
          'https://example.invalid/series/101.mp4\n';
      server.listen((request) async {
        requests++;
        request.response.statusCode = status;
        request.response.write(playlist);
        await request.response.close();
      });
      M3uSource buildSource() => M3uSource(
        sourceId: 'mixed',
        playlistUrl: 'http://127.0.0.1:${server.port}/list',
      );
      var source = buildSource();
      var repo = LibraryRepository(source: source, db: db);
      final metadata = _DelayedEpisodeMetadata();
      addTearDown(() async {
        if (!metadata.release.isCompleted) metadata.release.complete();
        await source.dispose();
        await server.close(force: true);
        await db.epgIngest.cancelAndWait();
        await db.close();
        directory.deleteSync(recursive: true);
      });
      final token = LoadToken();
      repo.loadToken = token;
      await Future.wait([
        repo.load(forceRefresh: true),
        repo.synchronizeMediaCatalog(
          ContentKind.movie,
          forceRefresh: true,
          token: token,
        ),
        repo.synchronizeMediaCatalog(
          ContentKind.series,
          forceRefresh: true,
          token: token,
        ),
      ]);
      repo.loadToken = null;
      expect(requests, 1);
      final movies = await repo.loadMedia(ContentKind.movie);
      expect(movies.items, hasLength(1));
      expect(hasSealedLocator(movies.items.single.extra), isTrue);
      status = 884;
      await source.dispose();
      await db.epgIngest.cancelAndWait();
      await db.close();
      db = await AppDatabase.openAt(path);
      source = buildSource();
      repo = LibraryRepository(source: source, db: db);
      final roots = (await repo.loadMedia(ContentKind.series)).items;
      final series = roots.singleWhere((item) => item.categoryId == 'Series');
      final mirror = roots.singleWhere((item) => item.categoryId == 'Mirrors');
      final seasons = (await repo.loadMedia(
        ContentKind.season,
        parent: series,
        enrichChildren: false,
      )).items;
      expect(seasons.map((s) => s.seasonNumber), [1, 2]);
      final episodes = (await repo.loadMedia(
        ContentKind.episode,
        parent: seasons.first,
        enrichChildren: false,
      )).items;
      expect(episodes.map((e) => e.episodeNumber), [1, 2]);
      expect(
        episodes.every((episode) => hasSealedLocator(episode.extra)),
        isTrue,
      );
      expect(episodes.first.extra, isNot(contains('catchupSource')));
      final mirrorSeason = (await repo.loadMedia(
        ContentKind.season,
        parent: mirror,
      )).items.single;
      final mirrorEpisode = (await repo.loadMedia(
        ContentKind.episode,
        parent: mirrorSeason,
      )).items.single;
      expect(mirrorEpisode.id, episodes.first.id);
      expect(requests, 1);
      final movieStream = await repo.resolveMedia(movies.items.single);
      final episodeStream = await repo.resolveMedia(episodes.first);
      expect(movieStream.isLive, isFalse);
      expect(episodeStream.isLive, isFalse);
      expect(episodeStream.url, 'https://example.invalid/series/101.mp4');
      expect(movieStream.headers, {
        'User-Agent': 'Fixture Agent',
        'Referer': 'https://example.invalid/',
      });
      expect(movieStream.providerAccount!.maximumStreams, 1);
      expect(requests, 1);

      final pendingMetadata = LibraryRepository(
        source: source,
        db: db,
        metadataProviders: [metadata],
      ).loadMedia(ContentKind.episode, parent: seasons.first);
      await metadata.started.future;
      status = 200;
      playlist = _mixed
          .replaceAll('Movie (2024)', 'Changed movie')
          .replaceAll('Show S02 E10', 'Show S03 E10')
          .replaceAll('Episode Agent', 'Updated Episode Agent');
      await repo.synchronizeCatalog(forceRefresh: true);
      metadata.release.complete();
      await pendingMetadata;
      final updated = (await repo.loadMedia(
        ContentKind.episode,
        parent: seasons.first,
        enrichChildren: false,
      )).items.first;
      expect(updated.id, episodes.first.id);
      expect((await repo.resolveMedia(updated)).headers['User-Agent'],
          'Updated Episode Agent');
      expect(requests, 2);
      expect(
        (await repo.loadMedia(ContentKind.movie)).items.single.title,
        'Changed movie',
      );
      status = 500;
      await expectLater(
        repo.synchronizeCatalog(forceRefresh: true),
        throwsA(isA<StateError>()),
      );
      // The bounded retry is shared by all three sections, not repeated per tab.
      expect(requests, 4);
      status = 403;
      await expectLater(
        repo.synchronizeCatalog(forceRefresh: true),
        throwsA(isA<StateError>()),
      );
      final currentSeasons = await repo.loadMedia(
        ContentKind.season,
        parent: series,
        enrichChildren: false,
      );
      expect(currentSeasons.fromCache, isTrue);
      expect(currentSeasons.items.map((season) => season.seasonNumber), [1, 3]);
      expect(
        await db.readMediaItems(
          source.id,
          ContentKind.episode,
          parentId: seasons.last.id,
        ),
        isEmpty,
      );
      final lastSeason = await repo.loadMedia(
        ContentKind.episode,
        parent: currentSeasons.items.last,
        enrichChildren: false,
      );
      expect(lastSeason.fromCache, isTrue);
      expect(lastSeason.items.single.episodeNumber, 10);
      expect(requests, 5);
      expect(
        (await repo.loadMedia(ContentKind.movie)).items.single.title,
        'Changed movie',
      );
    }, _RealHttpOverrides()),
  );

  final localFile = Platform.environment['TVBRO_LOCAL_M3U'];
  test(
    'private full playlist has the expected live, movie and episode counts',
    () async {
      final parsed = parseM3uPlaylist(await File(localFile!).readAsString());
      expect(parsed.channels.length, 803);
      expect(parsed.media.roots[ContentKind.movie]!.length, 16195);
      final episodes = parsed.media.children.values
          .expand((v) => v)
          .where((v) => v.kind == ContentKind.episode);
      expect(episodes.length, 48012);
      expect(parsed.rejectedRows, 0);
      // Counts only: never print private locators or copy this input to the repo.
      // ignore: avoid_print -- private validation emits aggregate counts only.
      print(
        'M3U local validation: live=${parsed.channels.length}, movies=${parsed.media.roots[ContentKind.movie]!.length}, series=${parsed.media.roots[ContentKind.series]!.length}, episodes=${episodes.length}',
      );
    },
    skip: localFile == null
        ? 'Set TVBRO_LOCAL_M3U for the private offline fixture'
        : false,
  );
}

class _RealHttpOverrides extends HttpOverrides {}

class _DelayedEpisodeMetadata extends MetadataProvider {
  final started = Completer<void>();
  final release = Completer<void>();

  @override
  String get provider => 'fixture';

  @override
  String get authMode => 'none';

  @override
  Future<ExternalMetadata?> search(MediaItem item) async => null;

  @override
  Future<ExternalMetadata?> episodeMetadata(
    MediaItem season,
    MediaItem episode,
  ) async {
    if (episode.episodeNumber != 1) return null;
    return _holdMetadata();
  }

  @override
  Future<ExternalMetadata?> seasonMetadata(
    MediaItem series,
    MediaItem season,
  ) async {
    if (season.id != 'old-season') return null;
    return _holdMetadata();
  }

  Future<ExternalMetadata> _holdMetadata() async {
    started.complete();
    await release.future;
    return ExternalMetadata(
      provider: provider,
      providerKey: 'episode',
      overview: 'Episode description',
      refreshedAt: DateTime(2026),
    );
  }

  @override
  void close() {}
}
