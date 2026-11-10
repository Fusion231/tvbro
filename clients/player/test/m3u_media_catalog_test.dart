import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/data/load_token.dart';
import 'package:iptvs/data/net.dart';
import 'package:iptvs/data/secret_locator_vault.dart';
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
#EXTINF:-1 group-title="Series",Show S01 E01
https://example.invalid/series/101.mp4
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
    'catalog batches share one download; cached playback keeps headers and makes no request',
    () => HttpOverrides.runWithHttpOverrides(() async {
      ProviderRequestGate.instance.debugReset();
      FlutterSecureStorage.setMockInitialValues({});
      final directory = Directory.systemTemp.createTempSync('m3u_media');
      final db = await AppDatabase.openAt('${directory.path}/library.db');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requests = 0, status = 200;
      var playlist = _mixed;
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
      addTearDown(() async {
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
      final series = (await repo.loadMedia(ContentKind.series)).items.single;
      final seasons = (await repo.loadMedia(
        ContentKind.season,
        parent: series,
        enrichChildren: false,
      )).items;
      final episodes = (await repo.loadMedia(
        ContentKind.episode,
        parent: seasons.first,
        enrichChildren: false,
      )).items;
      expect(episodes.map((e) => e.episodeNumber), [1, 2]);
      expect(requests, 1);
      await source.dispose();
      source = buildSource();
      repo = LibraryRepository(source: source, db: db);
      final movieStream = await repo.resolveMedia(movies.items.single);
      final episodeStream = await repo.resolveMedia(episodes.first);
      expect(movieStream.isLive, isFalse);
      expect(episodeStream.isLive, isFalse);
      expect(movieStream.headers, {
        'User-Agent': 'Fixture Agent',
        'Referer': 'https://example.invalid/',
      });
      expect(movieStream.providerAccount!.maximumStreams, 1);
      expect(requests, 1);

      playlist = _mixed.replaceAll('Movie (2024)', 'Changed movie');
      await repo.synchronizeCatalog(forceRefresh: true);
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
