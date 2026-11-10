import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/cloud_sync.dart';
import 'package:iptvs/data/local_profile_store.dart';
import 'package:iptvs/data/source_store.dart';
import 'package:iptvs/screens/cloud_sync_screen.dart';
import 'package:iptvs/sources/source.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  testWidgets(
    'free onboarding imports settings, favorites and progress before finishing',
    (tester) async {
      await tester.runAsync(() async {
        final previousOverrides = HttpOverrides.current;
        HttpOverrides.global = null;
        FlutterSecureStorage.setMockInitialValues({});
        final directory = Directory.systemTemp.createTempSync(
          'tvbro_setup_import',
        );
        final db = await AppDatabase.openAt(
          '${directory.path}/test.db',
        ).timeout(const Duration(seconds: 10));
        final store = SourceStore();
        final server = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          0,
        ).timeout(const Duration(seconds: 10));
        final favoritesRequested = Completer<void>();
        final releaseFavorites = Completer<void>();
        final playbackRequested = Completer<void>();
        final releasePlayback = Completer<void>();
        final completed = Completer<void>();
        final client = SupabaseClient(
          'http://127.0.0.1:${server.port}',
          'test-key',
        );
        final sync = _PairedSync(client: client, db: db);
        addTearDown(() async {
          if (!releaseFavorites.isCompleted) releaseFavorites.complete();
          if (!releasePlayback.isCompleted) releasePlayback.complete();
          await client.dispose();
          await server.close(force: true);
          await db.close();
          directory.deleteSync(recursive: true);
          HttpOverrides.global = previousOverrides;
        });

        server.listen((request) async {
          await request.drain<void>();
          request.response.headers.contentType = ContentType.json;
          Object? response;
          switch (request.uri.path) {
            case '/rest/v1/profiles':
              final favoritesOnly =
                  request.uri.queryParameters['select'] == 'favorites';
              if (favoritesOnly) {
                favoritesRequested.complete();
                await releaseFavorites.future;
              }
              response = [
                {
                  'id': _profileId,
                  'name': 'Saved profile',
                  'position': 0,
                  'favorites': [
                    for (final kind in ['live', 'movie', 'series'])
                      {
                        'source_id': _sourceId,
                        'kind': kind,
                        'item_id': 'saved-$kind',
                      },
                  ],
                },
              ];
            case '/rest/v1/sources':
              response = [
                {
                  'id': _sourceId,
                  'profile_id': _profileId,
                  'kind': 'xtream',
                  'label': 'Saved playlist',
                  'position': 0,
                  'fields': {'host': 'https://provider.invalid'},
                  'settings': {
                    'aspectMode': 'Fill',
                    'hiddenLiveCategories': ['7'],
                  },
                },
              ];
            case '/rest/v1/metadata_configs':
              response = [
                {
                  'config': {'provider': 'tvdb', 'autoEnrich': false},
                },
              ];
            case '/rest/v1/rpc/get_crypto_state':
              response = {'enabled': false};
            case '/rest/v1/rpc/get_secrets':
              response = {
                'sources': {
                  _sourceId: {
                    'format': 0,
                    'payload': {
                      'username': 'viewer',
                      'password': 'test-secret',
                    },
                  },
                },
                'metadata': {
                  'format': 0,
                  'payload': {'tvdbApiKey': 'saved-metadata-key'},
                },
              };
            case '/rest/v1/rpc/set_device_profile':
              response = null;
            case '/rest/v1/rpc/get_playback_delta':
              playbackRequested.complete();
              await releasePlayback.future;
              response = {
                'positions': [
                  {
                    'source_id': _sourceId,
                    'kind': 'movie',
                    'item_id': 'saved-movie',
                    'position_ms': 120000,
                    'duration_ms': 3600000,
                    'updated_at': 1700000000000,
                    'removed': false,
                  },
                ],
                'next_cursor': '1',
                'has_more': false,
              };
            default:
              fail('Unexpected onboarding request: ${request.uri.path}');
          }
          request.response.write(jsonEncode(response));
          await request.response.close();
        });

        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  final result = await Navigator.of(context).push<bool>(
                    MaterialPageRoute(
                      builder: (_) => CloudSyncScreen(
                        store: store,
                        db: db,
                        sync: sync,
                        onboarding: true,
                      ),
                    ),
                  );
                  if (result == true) completed.complete();
                },
                child: const Text('Setup'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Setup'));
        await tester.pump();
        await favoritesRequested.future.timeout(const Duration(seconds: 10));
        await tester.pump();
        expect(find.byType(CloudSyncScreen), findsOneWidget);
        expect(completed.isCompleted, isFalse);
        final imported = (await store.list()).single;
        expect(imported.id, _sourceId);
        expect(imported.settings, {
          'aspectMode': 'Fill',
          'hiddenLiveCategories': ['7'],
        });
        expect(imported.fields['password'], 'test-secret');
        final metadata = await store.metadataConfig();
        expect(metadata.provider, 'tvdb');
        expect(metadata.autoEnrich, isFalse);
        expect(metadata.tvdbApiKey, 'saved-metadata-key');

        releaseFavorites.complete();
        await playbackRequested.future.timeout(const Duration(seconds: 10));
        for (final kind in [
          ContentKind.live,
          ContentKind.movie,
          ContentKind.series,
        ]) {
          expect(await db.readFavoriteIds(_sourceId, kind), {
            'saved-${kind.name}',
          });
        }
        expect(completed.isCompleted, isFalse);
        expect(await db.readFavoritesOutbox(), isEmpty);

        releasePlayback.complete();
        await completed.future.timeout(const Duration(seconds: 10));
        await tester.pumpAndSettle();
        expect(find.byType(CloudSyncScreen), findsNothing);
        expect(await store.activeId(), _sourceId);
        expect(await sync.cachedProfileId(), _profileId);
        expect(await const LocalProfileStore().ownerless(), isFalse);
        final progress = await db.readPlaybackPosition(
          _sourceId,
          ContentKind.movie,
          'saved-movie',
        );
        expect(progress?.position, const Duration(minutes: 2));
        expect(await db.readPlaybackOutbox(), isEmpty);
        await tester.pumpWidget(const SizedBox());
      });
    },
  );
}

const _profileId = '11111111-1111-4111-8111-111111111111';
const _sourceId = '22222222-2222-4222-8222-222222222222';

/// Only the account/session boundary is replaced. Transfers use the real HTTP
/// client, source storage, secret merging and SQLite import implementations.
class _PairedSync extends CloudSync {
  _PairedSync({required super.client, required super.db});

  @override
  bool get hasSession => true;
  @override
  String get deviceId => 'test-device';
  @override
  Future<void> ensureAnonSession() async {}
  @override
  Future<bool> isPaired() async => true;
  @override
  Stream<void> observeProfileChanges(String profileId) => const Stream.empty();
}
