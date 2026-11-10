import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/cloud_sync.dart';
import 'package:iptvs/data/source_identity_migration.dart';
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
    fields: {'host': 'https://provider.invalid', 'username': 'user'},
  );
  late Directory directory;
  late AppDatabase db;
  late SourceStore store;
  late HttpServer server;
  late SupabaseClient client;
  late CloudSync sync;
  late Object favorites;
  late bool missingProfile;
  late bool failSourcePush;
  late List<Map<String, dynamic>> sourceUploads;
  Completer<void>? received;
  Completer<void>? release;
  String? blockedPath;

  setUp(() async {
    final previousOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = previousOverrides);
    FlutterSecureStorage.setMockInitialValues({});
    directory = Directory.systemTemp.createTempSync('tvbro_favorites_cloud');
    db = await AppDatabase.openAt('${directory.path}/test.db');
    store = SourceStore();
    await store.setAll([source]);
    favorites = [];
    missingProfile = false;
    failSourcePush = false;
    sourceUploads = [];
    received = null;
    release = null;
    blockedPath = null;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final bodyText = await utf8.decoder.bind(request).join();
      final body = bodyText.isEmpty ? null : jsonDecode(bodyText);
      request.response.headers.contentType = ContentType.json;
      if (request.uri.path == blockedPath) {
        received!.complete();
        await release!.future;
      }
      switch (request.uri.path) {
        case '/rest/v1/profiles':
          request.response.write(
            jsonEncode(
              missingProfile
                  ? []
                  : [
                      {'favorites': favorites},
                    ],
            ),
          );
        case '/rest/v1/rpc/get_crypto_state':
          request.response.write('{"enabled":false}');
        case '/rest/v1/rpc/push_sources':
          sourceUploads.add(Map<String, dynamic>.from(body as Map));
          if (failSourcePush) {
            request.response.statusCode = 503;
            request.response.write('{"message":"offline"}');
          } else {
            request.response.write('null');
          }
        case '/rest/v1/rpc/push_favorites_delta':
          request.response.write('null');
        default:
          fail('Unexpected cloud request: ${request.uri.path}');
      }
      await request.response.close();
    });
    client = SupabaseClient('http://127.0.0.1:${server.port}', 'test-key');
    sync = CloudSync(client: client, db: db);
    await sync.setManagedSourceIds({source.id});
  });

  tearDown(() async {
    await client.dispose();
    await server.close(force: true);
    await db.close();
    directory.deleteSync(recursive: true);
  });

  test('normalizing a source preserves cached favorites, progress and pending uploads after retry', () async {
    final legacy = source.copyWith(id: 'local-source');
    await db.migrateSourceCacheIdentity(
      legacy.id,
      legacy.label,
      sourceCacheIdentityForConfig(legacy),
    );
    await store.setAll([legacy]);
    await store.setActive(legacy.id);
    await db.setFavorite(legacy.id, ContentKind.movie, 'movie', true);
    await db.setFavorite(
      legacy.legacyCacheId,
      ContentKind.series,
      'series',
      true,
    );
    await db.replaceMediaLibrary(
      legacy.id,
      ContentKind.series,
      const [],
      const [
        MediaItem(
          id: 'series',
          title: 'Saved series',
          kind: ContentKind.series,
        ),
      ],
    );
    await db.savePlaybackPosition(
      legacy.id,
      ContentKind.episode,
      'episode',
      position: const Duration(minutes: 3),
      duration: const Duration(minutes: 40),
    );
    await db.savePlaybackPosition(
      legacy.legacyCacheId,
      ContentKind.movie,
      'movie',
      position: const Duration(minutes: 4),
      duration: const Duration(minutes: 90),
    );
    failSourcePush = true;
    await expectLater(
      sync.pushSources(store, 'profile'),
      throwsA(isA<PostgrestException>()),
    );
    final normalized = (await store.list()).single;
    expect(isUuid(normalized.id), isTrue);
    expect(await store.activeId(), normalized.id);
    expect(await db.readFavoriteIds(normalized.id, ContentKind.series), {
      'series',
    });
    expect(await db.readFavoriteIds(normalized.id, ContentKind.movie), {
      'movie',
    });
    expect(
      (await db.readRecentPositions(normalized.id))
          .map((row) => row.itemId)
          .toSet(),
      {'movie', 'episode'},
    );
    expect(await db.countMediaItems(normalized.id, ContentKind.series), 1);
    expect(
      (await db.readFavoritesOutbox()).map((row) => row.sourceId).toSet(),
      {normalized.id},
    );
    expect((await db.readPlaybackOutbox()).map((row) => row.sourceId).toSet(), {
      normalized.id,
    });
    failSourcePush = false;
    expect(await sync.pushSources(store, 'profile'), 1);
    expect((await store.list()).single.id, normalized.id);
    expect(
      sourceUploads.map(
        (upload) => ((upload['p_sources'] as List).single as Map)['id'],
      ),
      [normalized.id, normalized.id],
    );
    await sync.pullFavorites(store, 'profile');
    expect(await db.readFavoriteIds(normalized.id, ContentKind.series), {
      'series',
    });
    expect(await db.readFavoriteIds(normalized.id, ContentKind.movie), {
      'movie',
    });
  });

  test(
    'malformed and missing snapshots leave existing favorites intact',
    () async {
      await db.setFavorites(source.id, ContentKind.series, ['original']);
      favorites = ['malformed favorite'];
      await expectLater(
        sync.pullFavorites(store, 'profile'),
        throwsA(isA<TypeError>()),
      );
      expect(await db.readFavoriteIds(source.id, ContentKind.series), {
        'original',
      });
      missingProfile = true;
      await expectLater(
        sync.pullFavorites(store, 'profile'),
        throwsA(isA<StateError>()),
      );
      expect(await db.readFavoriteIds(source.id, ContentKind.series), {
        'original',
      });
    },
  );

  test(
    'edits made during a snapshot download survive its application',
    () async {
      favorites = [
        {'source_id': source.id, 'kind': 'series', 'item_id': 'removed'},
      ];
      blockedPath = '/rest/v1/profiles';
      received = Completer<void>();
      release = Completer<void>();
      final pull = sync.pullFavorites(store, 'profile');
      await received!.future;
      await db.setFavorite(source.id, ContentKind.series, 'added', true);
      await db.setFavorite(source.id, ContentKind.series, 'removed', false);
      release!.complete();
      await pull;
      expect(await db.readFavoriteIds(source.id, ContentKind.series), {
        'added',
      });
      expect(await db.readFavoritesOutbox(), hasLength(2));
    },
  );

  test(
    'upload acknowledgement cannot erase an add repeated while sending',
    () async {
      await db.setFavorite(source.id, ContentKind.series, 'series', true);
      blockedPath = '/rest/v1/rpc/push_favorites_delta';
      received = Completer<void>();
      release = Completer<void>();
      final push = sync.pushFavoritesDelta(store, 'profile');
      await received!.future;
      await db.setFavorite(source.id, ContentKind.series, 'series', false);
      await db.setFavorite(source.id, ContentKind.series, 'series', true);
      final pending = await db.readFavoritesOutbox();
      release!.complete();
      expect(await push, isTrue);
      expect(await db.readFavoritesOutbox(), pending);
      await sync.pullFavorites(store, 'profile');
      expect(await db.readFavoriteIds(source.id, ContentKind.series), {
        'series',
      });
    },
  );
}
