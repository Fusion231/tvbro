import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/sources/epg_mapping.dart';
import 'package:iptvs/sources/source.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlutterSecureStorage.setMockInitialValues({});
  late Directory temp;
  late AppDatabase db;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('tvbro_backup_db');
    db = await AppDatabase.openAt('${temp.path}/iptv.db');
  });

  tearDown(() async {
    await db.close();
    temp.deleteSync(recursive: true);
  });

  Map<String, dynamic> state() => {
    'favorites': [
      {
        'source_id': 'source',
        'kind': 'live',
        'item_id': 'channel',
        'created_at': 1234,
      },
    ],
    'playback_positions': [
      {
        'source_id': 'source',
        'kind': 'episode',
        'item_id': 'episode',
        'position_ms': 15000,
        'duration_ms': 120000,
        'updated_at': 5678,
      },
    ],
    'epg_channel_overrides': [
      <String, dynamic>{
        'source_id': 'source',
        'channel_id': 'channel',
        'guide_id': 'guide',
        'guide_channel_id': 'guide-channel',
        'offset_minutes': -60,
      },
    ],
  };

  test(
    'portable user state round trips without cache rows or locators',
    () async {
      await db.replaceLibrary('source', 'Provider', const [], const [
        Channel(
          id: 'channel',
          name: 'Channel',
          extra: {'url': 'https://provider.example/private-password'},
        ),
      ]);
      await db.restoreUserState(state());
      final exported = await db.exportUserState();
      expect(exported, state());
      expect(jsonEncode(exported), isNot(contains('private-password')));

      final fresh = await AppDatabase.openAt('${temp.path}/fresh.db');
      try {
        await fresh.restoreUserState(exported);
        expect(await fresh.exportUserState(), exported);
        expect(await fresh.readChannels('source'), isEmpty);
        expect(await fresh.readFavoriteIds('source', ContentKind.live), {
          'channel',
        });
        final position = await fresh.readPlaybackPosition(
          'source',
          ContentKind.episode,
          'episode',
        );
        expect(position!.position, const Duration(seconds: 15));
        expect(position.updatedAt.millisecondsSinceEpoch, 5678);
        expect(
          (await fresh.readEpgMappings('source')).single.offsetMinutes,
          -60,
        );
      } finally {
        await fresh.close();
      }
    },
  );

  test('restore replaces user rows and outbox, retaining catalogue', () async {
    await db.replaceLibrary('old', 'Old provider', const [], const [
      Channel(id: 'old-channel', name: 'Old channel'),
    ]);
    await db.setFavorite('old', ContentKind.movie, 'old-favorite', true);
    await db.setFavorite('old', ContentKind.movie, 'removed', false);
    await db.savePlaybackPosition(
      'old',
      ContentKind.movie,
      'old-position',
      position: const Duration(seconds: 20),
      duration: const Duration(minutes: 2),
    );
    await db.setEpgMapping(
      'old',
      const EpgChannelOverride(channelId: 'old-channel', offsetMinutes: 30),
    );
    await db.restoreUserState(state());

    expect(await db.exportUserState(), state());
    expect(await db.readChannels('old'), hasLength(1));
    expect(await db.readFavoritesOutbox(), [
      (
        sourceId: 'source',
        kind: ContentKind.live,
        itemId: 'channel',
        add: true,
      ),
    ]);
  });

  test(
    'invalid payloads are rejected before replacing existing state',
    () async {
      await db.restoreUserState(state());
      final before = await db.exportUserState();
      final corruptions = <void Function(Map<String, dynamic>)>[
        (data) => data['sources'] = [],
        (data) => data.remove('favorites'),
        (data) => data['favorites'][0]['unexpected'] = 'value',
        (data) => data['favorites'][0]['source_id'] = ' ',
        (data) => data['favorites'][0]['kind'] = 'episode',
        (data) => data['favorites'][0]['created_at'] = -1,
        (data) => data['favorites'].add(data['favorites'][0]),
        (data) => data['playback_positions'][0]['kind'] = 'live',
        (data) => data['playback_positions'][0]['position_ms'] = 1.5,
        (data) => data['playback_positions'][0]['duration_ms'] = -1,
        (data) => data['epg_channel_overrides'][0]['guide_id'] = null,
        (data) => data['epg_channel_overrides'][0]['offset_minutes'] = -1441,
        (data) => data['epg_channel_overrides'][0]['offset_minutes'] = true,
      ];
      for (final corrupt in corruptions) {
        final data = state();
        corrupt(data);
        expect(
          () => AppDatabase.validateUserState(data),
          throwsFormatException,
        );
        await expectLater(db.restoreUserState(data), throwsFormatException);
        expect(await db.exportUserState(), before);
      }
    },
  );

  test(
    'database failure rolls back every replaced user table and outbox',
    () async {
      await db.setFavorite('existing', ContentKind.movie, 'keep', true);
      final before = await db.exportUserState();
      final outbox = await db.readFavoritesOutbox();
      final raw = await databaseFactoryFfi.openDatabase('${temp.path}/iptv.db');
      await raw.execute(
        'CREATE TRIGGER reject_backup BEFORE INSERT ON playback_positions '
        "BEGIN SELECT RAISE(ABORT, 'test restore failure'); END",
      );

      await expectLater(
        db.restoreUserState(state()),
        throwsA(isA<DatabaseException>()),
      );
      expect(await db.exportUserState(), before);
      expect(await db.readFavoritesOutbox(), outbox);
    },
  );

  test(
    'empty user state clears rows and accepts offset-only mappings',
    () async {
      final offsetOnly = state();
      offsetOnly['epg_channel_overrides'][0]['guide_id'] = null;
      offsetOnly['epg_channel_overrides'][0]['guide_channel_id'] = null;
      await db.restoreUserState(offsetOnly);
      expect((await db.readEpgMappings('source')).single.hasBinding, isFalse);
      await db.restoreUserState({
        'favorites': [],
        'playback_positions': [],
        'epg_channel_overrides': [],
      });
      expect(await db.readFavoritesOutbox(), isEmpty);
      expect(await db.readEpgMappings('source'), isEmpty);
      expect(await db.readRecentPositions('source'), isEmpty);
    },
  );
}
