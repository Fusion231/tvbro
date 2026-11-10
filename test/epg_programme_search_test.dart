import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/programme_search.dart';
import 'package:iptvs/sources/epg_mapping.dart';
import 'package:iptvs/sources/source.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/historical_database_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlutterSecureStorage.setMockInitialValues({});
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('iptvs_epg_search'));
  tearDown(() => temp.deleteSync(recursive: true));

  Programme programme(
    String channel,
    String title, {
    String? description,
    int start = 1000,
  }) => Programme(
    channelId: channel,
    start: DateTime.fromMillisecondsSinceEpoch(start, isUtc: true),
    stop: DateTime.fromMillisecondsSinceEpoch(start + 1000, isUtc: true),
    title: title,
    description: description,
  );

  Future<void> seed(AppDatabase db) async {
    await db.replaceLibrary('s', 'Source', const [], const [
      Channel(id: 'a', name: 'Public channel'),
      Channel(id: 'b', name: 'Hidden channel'),
    ]);
    await db.replaceLibrary('other', 'Other source', const [], const [
      Channel(id: 'a', name: 'Other channel'),
    ]);
  }

  for (final engine in ProgrammeSearchEngine.values) {
    test(
      '$engine indexes titles/descriptions and replaces atomically',
      () async {
        final db = await AppDatabase.openAt(
          '${temp.path}/db',
          searchEngine: engine,
        );
        addTearDown(db.close);
        expect(
          db.programmeSearchEngine.index,
          greaterThanOrEqualTo(engine.index),
        );
        await seed(db);
        await db.replaceEpg('s', [
          programme(
            'a',
            'Space News',
            description: 'A telescope discovers Mars',
          ),
          programme('b', 'Space History', description: 'Mars exploration'),
        ]);
        await db.replaceEpg('other', [programme('a', 'Space News')]);

        final found = await db.searchProgrammes('telescope mar', sourceId: 's');
        expect(found.single.programme.title, 'Space News');
        expect(found.single.channel.name, 'Public channel');
        expect(found.single.sourceName, 'Source');
        expect((await db.searchProgrammes('space')).length, 3);
        expect(
          await db.searchProgrammes(
            'space',
            sourceId: 's',
            allowedChannelIds: {},
          ),
          isEmpty,
        );
        expect(
          (await db.searchProgrammes(
            'SPACE',
            sourceId: 's',
            allowedChannelIds: {'a'},
          )).length,
          1,
        );
        expect(
          await db.searchProgrammes(
            'space',
            from: DateTime.fromMillisecondsSinceEpoch(5000),
          ),
          isEmpty,
        );
        for (final query in [
          '"',
          '*) : (',
          'news" OR title:* - (',
          'NEAR(news)',
          "' ; DROP TABLE programmes; --",
        ]) {
          await db.searchProgrammes(query, sourceId: 's');
        }
        expect((await db.readChannels('s')).length, 2);

        Stream<List<Programme>> broken() async* {
          yield [programme('a', 'Should Roll Back')];
          throw StateError('provider disconnected');
        }

        await expectLater(db.replaceEpgStream('s', broken()), throwsStateError);
        expect((await db.searchProgrammes('space', sourceId: 's')).length, 2);
        expect(await db.searchProgrammes('roll', sourceId: 's'), isEmpty);
        await db.replaceEpgStream(
          's',
          Stream.value([programme('a', 'Fresh Documentary')]),
        );
        expect(await db.searchProgrammes('space', sourceId: 's'), isEmpty);
        expect(
          (await db.searchProgrammes('document', sourceId: 's')).length,
          1,
        );
        await db.replaceEpg('s', []);
        expect(await db.searchProgrammes('fresh', sourceId: 's'), isEmpty);
        expect((await db.searchProgrammes('space')).length, 1);
      },
    );
  }

  test(
    'channel policy is applied before the result limit across search pages',
    () async {
      final db = await AppDatabase.openAt('${temp.path}/db');
      addTearDown(db.close);
      await seed(db);
      await db.replaceEpg('s', [
        for (var i = 0; i < 260; i++) programme('b', 'Daily News', start: i),
        programme('a', 'Daily News', start: 500),
      ]);
      final results = await db.searchProgrammes(
        'news',
        sourceId: 's',
        allowedChannelIds: {'a'},
        limit: 1,
      );
      expect(results.single.channel.id, 'a');
    },
  );

  test(
    'released v12 guide is searchable after migration and repeated upgrade',
    () async {
      final path = '${temp.path}/legacy';
      await createReleasedDatabaseFixture(path, 12);
      var db = await AppDatabase.openAt(path);
      expect(
        (await db.searchProgrammes('fixture programme')).single.channel.id,
        'channel-1',
      );
      await db.setEpgMapping(
        'released-source',
        const EpgChannelOverride(channelId: 'channel-1', offsetMinutes: 60),
      );
      await db.close();
      final raw = await databaseFactoryFfi.openDatabase(path);
      await raw.setVersion(14);
      await raw.close();
      db = await AppDatabase.openAt(path);
      expect(
        (await db.readEpgMappings('released-source')).single.offsetMinutes,
        60,
      );
      expect(
        (await db.searchProgrammes('fixture')).single.programme.title,
        'Fixture Programme',
      );
      await db.close();
    },
  );

  test('FTS update/delete triggers remove old terms', () async {
    for (final engine in [
      ProgrammeSearchEngine.fts5,
      ProgrammeSearchEngine.fts4,
    ]) {
      final path = '${temp.path}/${engine.name}';
      var db = await AppDatabase.openAt(path, searchEngine: engine);
      if (db.programmeSearchEngine != engine) {
        // This Windows DLL ships FTS5 without FTS4. The indexed fallback is
        // covered above; do not assume a module just because FTS5 is present.
        await db.close();
        continue;
      }
      await seed(db);
      await db.replaceEpg('s', [programme('a', 'Old Term')]);
      await db.close();
      final raw = await databaseFactoryFfi.openDatabase(path);
      await raw.update(
        'programmes',
        {'title': 'New Story'},
        where: 'source_id = ?',
        whereArgs: ['s'],
      );
      await raw.close();
      db = await AppDatabase.openAt(path);
      expect(await db.searchProgrammes('old'), isEmpty);
      expect((await db.searchProgrammes('story')).length, 1);
      await db.close();
    }
  });

  test(
    'token fallback rebuilds after an older writer replaces the guide',
    () async {
      final path = '${temp.path}/older-writer';
      var db = await AppDatabase.openAt(
        path,
        searchEngine: ProgrammeSearchEngine.tokens,
      );
      await seed(db);
      await db.replaceEpg('s', [programme('a', 'Original Schedule')]);
      await db.close();
      final older = await databaseFactoryFfi.openDatabase(path);
      await older.delete(
        'programmes',
        where: 'source_id = ?',
        whereArgs: ['s'],
      );
      await older.insert('programmes', {
        'source_id': 's',
        'channel_id': 'a',
        'start': 1000,
        'stop': 2000,
        'title': 'Older Build Update',
        'description': 'Replacement without the newer Dart tokenizer',
      });
      await older.setVersion(14);
      await older.close();
      db = await AppDatabase.openAt(path);
      addTearDown(db.close);
      expect(db.programmeSearchEngine, ProgrammeSearchEngine.tokens);
      expect(await db.searchProgrammes('original'), isEmpty);
      expect(
        (await db.searchProgrammes('older update')).single.programme.title,
        'Older Build Update',
      );
    },
  );
}
