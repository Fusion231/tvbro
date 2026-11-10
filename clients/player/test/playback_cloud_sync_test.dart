import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/cloud_sync.dart';
import 'package:iptvs/data/source_store.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/source_config.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const source = SourceConfig(
    id: '11111111-1111-4111-8111-111111111111',
    kind: SourceKind.xtream,
    label: 'Shared source',
    fields: {},
  );
  late Directory directory;
  late AppDatabase first;
  late AppDatabase second;
  late SourceStore store;
  late HttpServer server;
  late SupabaseClient client;
  late CloudSync firstSync;
  late CloudSync secondSync;
  late Map<String, Map<String, dynamic>> cloud;
  late List<Map<String, dynamic>> requests;
  late bool failPush;
  late int revision;
  late bool failSecondPage;
  String? pullErrorCode;
  Completer<void>? received;
  Completer<void>? release;

  setUp(() async {
    final previousOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = previousOverrides);
    FlutterSecureStorage.setMockInitialValues({});
    directory = Directory.systemTemp.createTempSync('tvbro_playback_cloud');
    first = await AppDatabase.openAt('${directory.path}/first.db');
    second = await AppDatabase.openAt('${directory.path}/second.db');
    store = SourceStore();
    await store.setAll([source]);
    cloud = {};
    requests = [];
    failPush = false;
    revision = 0;
    failSecondPage = false;
    pullErrorCode = null;
    received = null;
    release = null;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final body = jsonDecode(
        await utf8.decoder.bind(request).join(),
      ) as Map<String, dynamic>;
      requests.add(body);
      request.response.headers.contentType = ContentType.json;
      if (request.uri.path.endsWith('/get_playback_delta')) {
        final after = int.parse(body['p_after'].toString());
        if (pullErrorCode != null) {
          request.response.statusCode = pullErrorCode == 'PGRST202' ? 404 : 503;
          request.response.write(jsonEncode({
            'code': pullErrorCode,
            'message': 'Function not available',
          }));
        } else if (failSecondPage && after > 0) {
          request.response.statusCode = 503;
          request.response.write(jsonEncode({'message': 'offline'}));
        } else {
          final rows =
              cloud.values
                  .where((row) => (row['_cursor'] as int) > after)
                  .toList()
                ..sort(
                  (a, b) =>
                      (a['_cursor'] as int).compareTo(b['_cursor'] as int),
                );
          final page = rows.take(body['p_limit'] as int).toList();
          request.response.write(
            jsonEncode({
              'positions': page,
              'next_cursor': (page.isEmpty ? after : page.last['_cursor'])
                  .toString(),
              'has_more': rows.length > page.length,
            }),
          );
        }
      } else {
        expect(request.uri.path, '/rest/v1/rpc/push_playback_positions');
        if (received case final signal?) signal.complete();
        if (release case final signal?) await signal.future;
        if (failPush) {
          request.response.statusCode = 503;
          request.response.write(jsonEncode({'message': 'offline'}));
        } else {
          for (final value in body['p_changes'] as List) {
            final row = Map<String, dynamic>.from(value as Map);
            row['_cursor'] = ++revision;
            cloud['${row['source_id']}/${row['kind']}/${row['item_id']}'] = row;
          }
          request.response.write('null');
        }
      }
      await request.response.close();
    });
    client = SupabaseClient('http://127.0.0.1:${server.port}', 'test-key');
    firstSync = CloudSync(client: client, db: first);
    secondSync = CloudSync(client: client, db: second);
    await firstSync.setManagedSourceIds({source.id});
  });

  tearDown(() async {
    await client.dispose();
    await server.close(force: true);
    await first.close();
    await second.close();
    directory.deleteSync(recursive: true);
  });

  Future<void> save(AppDatabase db, String item, int seconds) =>
      db.savePlaybackPosition(
        source.id,
        ContentKind.movie,
        item,
        position: Duration(seconds: seconds),
        duration: const Duration(minutes: 10),
      );

  test('missing playback RPC does not block profile download or erase local progress', () async {
    await save(second, 'offline', 90);
    final pending = await second.readPlaybackOutbox();
    pullErrorCode = 'PGRST202';
    await secondSync.pullPlaybackPositions(store, 'profile-a');
    expect(await second.readPlaybackOutbox(), pending);
    expect(
      (await second.readPlaybackPosition(source.id, ContentKind.movie, 'offline'))?.position,
      const Duration(seconds: 90),
    );

    // Once the API is upgraded, the initial page still starts at zero.
    pullErrorCode = null;
    await save(first, 'remote', 120);
    await firstSync.pushPlaybackPositions(store, 'profile-a');
    requests.clear();
    await secondSync.pullPlaybackPositions(store, 'profile-a');
    expect(requests.single['p_after'], '0');
    expect(await second.readPlaybackPositionsForSync(), hasLength(2));

    // A missing RPC during a later deployment preserves the committed cursor.
    pullErrorCode = 'PGRST202';
    await secondSync.pullPlaybackPositions(store, 'profile-a');
    expect(await second.readPlaybackPositionsForSync(), hasLength(2));
    expect(await second.readPlaybackOutbox(), pending);
    pullErrorCode = null;
    requests.clear();
    await secondSync.pullPlaybackPositions(store, 'profile-a');
    expect(requests.single['p_after'], '1');
  });

  test('other playback errors still fail the download without changing local progress', () async {
    await save(second, 'offline', 90);
    final pending = await second.readPlaybackOutbox();
    pullErrorCode = 'database_unavailable';
    await expectLater(
      secondSync.pullPlaybackPositions(store, 'profile-a'),
      throwsA(isA<PostgrestException>()),
    );
    expect(await second.readPlaybackOutbox(), pending);
    expect(await second.readPlaybackPositionsForSync(), hasLength(1));
  });

  test('paged pull resumes after failure and unchanged pull does not erase earlier pages', () async {
    for (var i = 0; i < 201; i++) {
      await save(first, 'movie-$i', 120);
    }
    await firstSync.pushPlaybackPositions(store, 'profile-a');
    failSecondPage = true;
    await expectLater(
      secondSync.pullPlaybackPositions(store, 'profile-a'),
      throwsA(isA<PostgrestException>()),
    );
    expect(await second.readPlaybackPositionsForSync(), hasLength(100));
    failSecondPage = false;
    requests.clear();
    await secondSync.pullPlaybackPositions(store, 'profile-a');
    expect(requests.first['p_after'], '100');
    expect(await second.readPlaybackPositionsForSync(), hasLength(201));
    await secondSync.pullPlaybackPositions(store, 'profile-a');
    expect(await second.readPlaybackPositionsForSync(), hasLength(201));
    await secondSync.setManagedSourceIds({'another-source'});
    await secondSync.setManagedSourceIds({source.id});
    requests.clear();
    await secondSync.pullPlaybackPositions(store, 'profile-a');
    expect(requests.first['p_after'], '0');
  });

  test('long UTF-8 title ids are batched within the SQL byte limit', () async {
    for (var i = 0; i < 150; i++) {
      await save(first, '${'ą'.padRight(4000, 'ą')}$i', 120);
    }
    await firstSync.pushPlaybackPositions(store, 'profile-a');
    expect(requests.length, greaterThan(1));
    for (final body in requests) {
      expect(
        utf8.encode(jsonEncode(body['p_changes'])).length,
        lessThan(900000),
      );
    }
    expect(await first.readPlaybackOutbox(), isEmpty);
  });

  test(
    'another device receives progress and completion removes its resume',
    () async {
      await save(first, 'movie', 120);
      expect(await firstSync.pushPlaybackPositions(store, 'profile-a'), isTrue);
      expect(await first.readPlaybackOutbox(), isEmpty);
      await secondSync.pullPlaybackPositions(store, 'profile-a');
      expect(
        (await second.readPlaybackPosition(
          source.id,
          ContentKind.movie,
          'movie',
        ))?.position,
        const Duration(minutes: 2),
      );
      expect(await second.readPlaybackOutbox(), isEmpty);
      await save(first, 'movie', 590);
      await firstSync.pushPlaybackPositions(store, 'profile-a');
      await secondSync.pullPlaybackPositions(store, 'profile-a');
      expect(await second.readRecentPositions(source.id), isEmpty);
      expect(
        requests.every((body) => body['p_profile_id'] == 'profile-a'),
        isTrue,
      );
    },
  );

  test(
    'episode progress and watched state reach another device and full uploads',
    () async {
      Future<void> saveEpisode(int seconds) => first.savePlaybackPosition(
        source.id,
        ContentKind.episode,
        'episode',
        position: Duration(seconds: seconds),
        duration: const Duration(minutes: 10),
      );

      await saveEpisode(120);
      await firstSync.pushPlaybackPositions(store, 'profile-a');
      await secondSync.pullPlaybackPositions(store, 'profile-a');
      var received = await second.readEpisodePlaybackPositions(source.id, [
        'episode',
      ]);
      expect(received['episode']!.position, const Duration(minutes: 2));
      expect(received['episode']!.isFinished, isFalse);

      await saveEpisode(570);
      expect((await first.readPlaybackOutbox()).single.removed, isFalse);
      await firstSync.pushPlaybackPositions(store, 'profile-a');
      expect(await first.readPlaybackOutbox(), isEmpty);
      await secondSync.pullPlaybackPositions(store, 'profile-a');
      received = await second.readEpisodePlaybackPositions(source.id, [
        'episode',
      ]);
      expect(received['episode']!.isFinished, isTrue);
      expect(await second.readRecentPositions(source.id), isEmpty);
      expect(
        await second.readPlaybackPosition(
          source.id,
          ContentKind.episode,
          'episode',
        ),
        isNull,
      );
      expect(await second.readPlaybackOutbox(), isEmpty);

      await firstSync.pushPlaybackPositions(
        store,
        'profile-b',
        includeAll: true,
      );
      final fullUpload = (requests.last['p_changes'] as List).single as Map;
      expect(fullUpload['kind'], 'episode');
      expect(fullUpload['position_ms'], 570000);
      expect(fullUpload['removed'], isFalse);
    },
  );

  test(
    'offline edits survive pulls and local-only sources stay on device',
    () async {
      await save(first, 'remote', 120);
      await firstSync.pushPlaybackPositions(store, 'profile-a');
      await save(second, 'offline', 180);
      await second.savePlaybackPosition(
        'local-only',
        ContentKind.movie,
        'private',
        position: const Duration(minutes: 1),
        duration: const Duration(minutes: 10),
      );
      await secondSync.pullPlaybackPositions(store, 'profile-a');
      expect(
        (await second.readRecentPositions(source.id)).map((p) => p.itemId),
        containsAll(['remote', 'offline']),
      );
      await secondSync.pushPlaybackPositions(store, 'profile-a');
      expect(cloud.values.map((row) => row['item_id']), contains('offline'));
      expect(
        cloud.values.map((row) => row['item_id']),
        isNot(contains('private')),
      );
      expect((await second.readPlaybackOutbox()).single.sourceId, 'local-only');
    },
  );

  test(
    'failed upload retries and acknowledgement keeps a newer local save',
    () async {
      await save(first, 'movie', 120);
      failPush = true;
      await expectLater(
        firstSync.pushPlaybackPositions(store, 'profile-a'),
        throwsA(isA<PostgrestException>()),
      );
      expect(await first.readPlaybackOutbox(), hasLength(1));
      failPush = false;
      received = Completer<void>();
      release = Completer<void>();
      final uploading = firstSync.pushPlaybackPositions(store, 'profile-a');
      await received!.future.timeout(const Duration(seconds: 10));
      await save(first, 'movie', 180);
      release!.complete();
      await uploading;
      expect((await first.readPlaybackOutbox()).single.positionMs, 180000);
      received = null;
      release = null;
      await firstSync.pushPlaybackPositions(store, 'profile-a');
      expect(cloud.values.single['position_ms'], 180000);
      expect(await first.readPlaybackOutbox(), isEmpty);
    },
  );

  test(
    'manual upload includes progress already acknowledged by another profile',
    () async {
      await save(first, 'movie', 120);
      await firstSync.pushPlaybackPositions(store, 'profile-a');
      expect(
        await firstSync.pushPlaybackPositions(store, 'profile-a'),
        isFalse,
      );
      expect(
        await firstSync.pushPlaybackPositions(
          store,
          'profile-b',
          includeAll: true,
        ),
        isTrue,
      );
      expect(requests.last['p_profile_id'], 'profile-b');
      expect(requests.last['p_changes'], hasLength(1));
    },
  );
}
