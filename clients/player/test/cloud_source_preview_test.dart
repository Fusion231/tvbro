import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/cloud_sync.dart';
import 'package:iptvs/data/source_store.dart';
import 'package:iptvs/sources/source_config.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'preview decrypts sources without replacing local setup or managed ids',
    () async {
      final httpOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = httpOverrides);
      FlutterSecureStorage.setMockInitialValues({});
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final reads = <String, int>{};
      var sourceCount = 1;
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        reads.update(request.uri.path, (value) => value + 1, ifAbsent: () => 1);
        request.response.headers.contentType = ContentType.json;
        final Object response;
        switch (request.uri.path) {
          case '/rest/v1/rpc/get_crypto_state':
            response = {'enabled': false};
          case '/rest/v1/rpc/get_secrets':
            response = {
              'sources': {
                'cloud-source': {
                  'format': 0,
                  'payload': {
                    'playlistUrl': 'https://example.invalid/list.m3u',
                  },
                },
              },
            };
          case '/rest/v1/sources':
            final offset = int.parse(
              request.uri.queryParameters['offset'] ?? '0',
            );
            response = [
              for (var i = offset; i < sourceCount && i < offset + 250; i++)
                {
                  'id': i == 0 ? 'cloud-source' : 'cloud-source-$i',
                  'kind': 'm3u',
                  'label': 'From panel',
                  'fields': {},
                },
            ];
          case '/rest/v1/metadata_configs':
            response = {
              'config': {'provider': 'tmdb'},
            };
          default:
            request.response.statusCode = 404;
            response = {};
        }
        request.response.write(jsonEncode(response));
        await request.response.close();
      });
      final client = SupabaseClient(
        'http://127.0.0.1:${server.port}',
        'test-key',
      );
      addTearDown(client.dispose);
      final sync = CloudSync(client: client);
      final store = SourceStore();
      await store.save(
        const SourceConfig(
          id: 'local',
          kind: SourceKind.demo,
          label: 'Local',
          fields: {},
        ),
      );
      await sync.setManagedSourceIds({'old-cloud-source'});

      final preview = await sync.previewSources(store, 'profile');
      expect(
        preview.single.fields['playlistUrl'],
        'https://example.invalid/list.m3u',
      );
      expect((await store.list()).single.id, 'local');
      expect(await store.activeId(), 'local');
      expect(await sync.managedSourceIds(), {'old-cloud-source'});

      expect(await sync.pullSources(store, 'profile'), 1);
      expect((await store.list()).map((source) => source.id), [
        'cloud-source',
        'local',
      ]);
      expect(await sync.managedSourceIds(), {'cloud-source'});
      final cryptoBefore = reads['/rest/v1/rpc/get_crypto_state']!;
      final secretsBefore = reads['/rest/v1/rpc/get_secrets']!;
      await sync.withProfileReadSnapshot('profile', () async {
        await sync.previewSources(store, 'profile');
        await sync.pullMetadata(store, 'profile');
      });
      expect(reads['/rest/v1/rpc/get_crypto_state'], cryptoBefore + 1);
      expect(reads['/rest/v1/rpc/get_secrets'], secretsBefore + 1);
      await sync.previewSources(store, 'profile');
      expect(reads['/rest/v1/rpc/get_crypto_state'], cryptoBefore + 2);
      expect(reads['/rest/v1/rpc/get_secrets'], secretsBefore + 2);
      sourceCount = 1001;
      final sourceReads = reads['/rest/v1/sources']!;
      final complete = await sync.previewSources(store, 'profile');
      expect(complete, hasLength(1001));
      expect(complete.map((source) => source.id).toSet(), hasLength(1001));
      expect(reads['/rest/v1/sources'], sourceReads + 5);
    },
  );
}
