import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/load_token.dart';
import 'package:iptvs/data/secret_locator_vault.dart';
import 'package:iptvs/sources/source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlutterSecureStorage.setMockInitialValues({});
  late Directory temp;
  late AppDatabase db;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('tvbro_import_test');
    db = await AppDatabase.openAt('${temp.path}/cache.db');
  });
  tearDown(() async {
    await db.close();
    await temp.delete(recursive: true);
  });

  test(
    'large library batches remain sealed and reveal the original locators',
    () async {
      final channels = List.generate(
        1201,
        (i) => Channel(
          id: 'channel-$i',
          name: 'Channel $i',
          number: i,
          extra: {
            'url': 'https://example.invalid/private/$i',
            'tvgId': 'epg.$i',
          },
        ),
      );
      await db.replaceLibrary('s', 'Source', const [], channels);
      final cached = await db.readChannels('s');
      expect(cached, hasLength(channels.length));
      expect(db.vault.decryptCount, 0);
      for (final i in [0, 499, 500, 1200]) {
        expect(hasSealedLocator(cached[i].extra), isTrue);
        expect(cached[i].extra.containsKey('url'), isFalse);
        final revealed = await db.revealChannel(cached[i]);
        expect(revealed.extra['url'], channels[i].extra['url']);
        expect(revealed.extra['tvgId'], 'epg.$i');
      }
    },
  );

  test(
    'worker preparation failure retains the old library and EPG freshness',
    () async {
      await db.replaceLibrary('s', 'Original', const [], const [
        Channel(id: 'old', name: 'Old'),
      ]);
      await db.replaceEpg('s', const []);
      final synced = await db.lastEpgSynced('s');
      final channels = List.generate(
        1001,
        (i) => Channel(
          id: '$i',
          name: 'New $i',
          extra: i == 1000
              ? {'invalid': Object()}
              : {'url': 'https://example.invalid/$i'},
        ),
      );
      await expectLater(
        db.replaceLibrary('s', 'Replacement', const [], channels),
        throwsStateError,
      );
      expect((await db.readChannels('s')).single.id, 'old');
      expect(await db.lastEpgSynced('s'), synced);
    },
  );

  test(
    'cancellation during preparation cannot overwrite a ready catalog',
    () async {
      await db.replaceLibrary('s', 'Original', const [], const [
        Channel(id: 'old', name: 'Old'),
      ]);
      final token = LoadToken();
      final replacement = db.replaceLibrary('s', 'Stale', const [], [
        for (var i = 0; i < 1001; i++)
          Channel(
            id: '$i',
            name: 'Stale $i',
            extra: {'url': 'https://example.invalid/$i'},
          ),
      ], token: token);
      token.cancel();
      expect(await replacement, isFalse);
      expect((await db.readChannels('s')).single.id, 'old');
    },
  );

  test(
    'cancelled EPG write rolls back committed batches and closes its feed',
    () async {
      final original = Programme(
        channelId: 'old',
        start: DateTime(2026),
        stop: DateTime(2027),
        title: 'Old',
      );
      await db.replaceLibrary('s', 'Source', const [], const [
        Channel(id: 'old', name: 'Old'),
      ]);
      await db.replaceEpg('s', [original]);
      final synced = await db.lastEpgSynced('s');
      final token = LoadToken();
      var closed = false;
      Stream<List<Programme>> batches() async* {
        try {
          yield List.generate(
            1001,
            (i) => Programme(
              channelId: '$i',
              start: DateTime(2026),
              stop: DateTime(2027),
              title: 'New $i',
            ),
          );
          token.cancel();
          yield [original];
        } finally {
          closed = true;
        }
      }

      await expectLater(
        db.replaceEpgStream('s', batches(), token: token),
        throwsA(isA<LoadCancelledException>()),
      );
      expect(closed, isTrue);
      expect((await db.nowNext('s', DateTime(2026, 6))).now.keys, ['old']);
      expect(await db.lastEpgSynced('s'), synced);
    },
  );

  test('concurrent large search allowlists stay isolated and obey the result limit', () async {
    final channels = List.generate(
      1001,
      (i) => Channel(id: 'c$i', name: 'Channel $i'),
    );
    await db.replaceLibrary('s', 'Source', const [], channels);
    await db.replaceEpg('s', [
      for (var i = 0; i < channels.length; i++)
        Programme(
          channelId: channels[i].id,
          start: DateTime(2026).add(Duration(minutes: i)),
          stop: DateTime(2027),
          title: 'News',
        ),
    ]);
    final even = {for (var i = 0; i < 1001; i += 2) 'c$i'};
    final odd = {for (var i = 1; i < 1001; i += 2) 'c$i'};
    final results = await Future.wait([
      db.searchProgrammes(
        'News',
        sourceId: 's',
        allowedChannelIds: even,
        limit: 5,
      ),
      db.searchProgrammes(
        'News',
        sourceId: 's',
        allowedChannelIds: odd,
        limit: 5,
      ),
    ]);
    expect(results[0].map((r) => r.channel.id), ['c0', 'c2', 'c4', 'c6', 'c8']);
    expect(results[1].map((r) => r.channel.id), ['c1', 'c3', 'c5', 'c7', 'c9']);
    expect(
      await db.searchProgrammes(
        'News',
        sourceId: 's',
        allowedChannelIds: const {},
      ),
      isEmpty,
    );
  });
}
