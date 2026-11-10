import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/sources/epg_guides.dart';
import 'package:iptvs/sources/epg_mapping.dart';
import 'package:iptvs/sources/m3u_source.dart';
import 'package:iptvs/sources/source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlutterSecureStorage.setMockInitialValues({});
  HttpOverrides.global = null;
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('iptvs_epg_mapping'));
  tearDown(() => temp.deleteSync(recursive: true));

  const channel = Channel(
    id: 'stable-channel',
    name: 'Discovery HD',
    extra: {'tvgId': 'a'},
  );
  const body =
      '<tv>'
      '<channel id="a"><display-name>Discovery</display-name></channel>'
      '<channel id="b"><display-name>Unmatched Documentary</display-name></channel>'
      '<programme channel="a" start="20261022120000 +0000" stop="20261022130000 +0000"><title>Automatic schedule</title></programme>'
      '<programme channel="b" start="20261022140000 +0000" stop="20261022150000 +0000"><title>Manual schedule</title></programme>'
      '</tv>';

  test('explicit binding wins across guides; catalogue retains unmatched declarations', () async {
    final session = EpgMappingSession()
      ..begin([
        const EpgChannelOverride(
          channelId: 'stable-channel',
          guideId: 'second',
          guideChannelId: 'b',
        ),
      ]);
    EpgGuideFeed feed(String id) => xmltvGuideFeed(
      url: 'https://guide.example/$id',
      guideId: id,
      guideLabel: id,
      mapping: session,
      tempDirectory: temp,
      download: (_, file) => file.writeAsString(body),
      tvgIdToChannelIds: {
        'a': ['stable-channel'],
      },
      nameToChannelIds: {
        'discovery': ['stable-channel'],
      },
    );
    final programmes = (await mergeEpgGuides([
      feed('first'),
      feed('second'),
    ]).toList()).expand((batch) => batch).toList();
    expect(programmes.single.title, 'Manual schedule');
    expect(programmes.single.channelId, channel.id);
    expect(session.catalogue, hasLength(4));
    expect(
      session.catalogue.where((candidate) => candidate.channelId == 'b'),
      hasLength(2),
    );
    expect(temp.listSync(), isEmpty);
  });

  test(
    'suggestions are bounded choices and never mutate session overrides',
    () {
      final catalogue = [
        const EpgGuideChannel(
          guideId: 'one',
          guideLabel: 'One',
          channelId: 'discov',
          displayNames: ['Discoveri HD'],
        ),
        const EpgGuideChannel(
          guideId: 'two',
          guideLabel: 'Two',
          channelId: 'same',
          displayNames: ['Discovery FHD'],
        ),
        const EpgGuideChannel(
          guideId: 'one',
          guideLabel: 'One',
          channelId: 'news',
          displayNames: ['Daily News'],
        ),
      ];
      final suggestions = suggestEpgMappings(channel, catalogue, limit: 1);
      expect(suggestions, hasLength(1));
      expect(suggestions.single.candidate.guideId, 'two');
      final session = EpgMappingSession()..begin([]);
      final index = {
        'a': ['stable-channel'],
      };
      expect(identical(session.indexFor(index, 'one'), index), isTrue);
    },
  );

  test('saved mapping and actual schedule correction survive restart and failed refresh', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var fail = false;
    server.listen((request) async {
      if (fail && request.uri.path == '/extra') {
        request.response.statusCode = 503;
      } else if (request.uri.path == '/playlist') {
        request.response.write(
          '#EXTM3U\n#EXTINF:-1 tvg-id="a" catchup-days="7" '
          'catchup-source="http://stream.example/archive?start={start}&end={end}",'
          'Discovery HD\nhttp://stream.example/live\n',
        );
      } else {
        request.response.write(body);
      }
      await request.response.close();
    });
    addTearDown(() => server.close(force: true));
    final base = 'http://127.0.0.1:${server.port}';
    final source = M3uSource(
      sourceId: 's',
      playlistUrl: '$base/playlist',
      epgUrl: '$base/guide',
      extraEpgUrls: ['$base/extra'],
    );
    addTearDown(source.dispose);
    final path = '${temp.path}/db';
    var db = await AppDatabase.openAt(path);
    addTearDown(db.close);
    var repo = LibraryRepository(source: source, db: db);
    final snapshot = await repo.load();
    await repo.pendingEpgRefresh;
    final channelId = snapshot.channels.single.id;
    expect((await repo.readEpgGuideChannels()).length, 4);
    await repo.setEpgMapping(
      EpgChannelOverride(
        channelId: channelId,
        guideId: epgGuideId('s', '$base/extra'),
        guideChannelId: 'b',
        offsetMinutes: -30,
      ),
      channels: snapshot.channels,
    );
    await repo.pendingEpgRefresh;
    var results = await repo.searchProgrammes('manual');
    expect(
      results.single.programme.start.toUtc(),
      DateTime.utc(2026, 10, 22, 13, 30),
    );
    expect(
      results.single.programme.stop.toUtc(),
      DateTime.utc(2026, 10, 22, 14, 30),
    );
    expect(results.single.channel.id, channelId);
    final archive = await repo.resolveArchive(
      results.single.channel,
      results.single.programme,
    );
    final archiveUri = Uri.parse(archive.url);
    expect(
      archiveUri.queryParameters['start'],
      '${DateTime.utc(2026, 10, 22, 13, 30).millisecondsSinceEpoch ~/ 1000}',
    );
    expect(
      archiveUri.queryParameters['end'],
      '${DateTime.utc(2026, 10, 22, 14, 30).millisecondsSinceEpoch ~/ 1000}',
    );
    await db.close();
    db = await AppDatabase.openAt(path);
    addTearDown(db.close);
    repo = LibraryRepository(source: source, db: db);
    expect((await repo.readEpgMappings()).single.offsetMinutes, -30);
    results = await repo.searchProgrammes('manual');
    expect(
      results.single.programme.start.toUtc(),
      DateTime.utc(2026, 10, 22, 13, 30),
    );
    fail = true;
    await repo.setEpgMapping(
      EpgChannelOverride(
        channelId: channelId,
        guideId: epgGuideId('s', '$base/extra'),
        guideChannelId: 'b',
        offsetMinutes: 10,
      ),
      channels: snapshot.channels,
    );
    await repo.pendingEpgRefresh;
    expect(repo.lastEpgRefreshFailed, isTrue);
    expect(
      (await repo.searchProgrammes('manual')).single.programme.start.toUtc(),
      DateTime.utc(2026, 10, 22, 13, 30),
    );
    expect(await db.lastEpgSynced('s'), isNull);
    final missingGuide = EpgMappingSession()
      ..begin([
        EpgChannelOverride(
          channelId: channelId,
          guideId: 'removed',
          guideChannelId: 'b',
        ),
      ]);
    expect(() => missingGuide.validateGuides(['remaining']), throwsStateError);
    expect(
      () => missingGuide.addCatalogue('removed', 'Removed guide', {'a': []}),
      throwsStateError,
    );
    await db.close();
  });
}
