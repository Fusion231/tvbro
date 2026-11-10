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
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
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
            response = [
              {
                'id': 'cloud-source',
                'kind': 'm3u',
                'label': 'From panel',
                'fields': {},
              },
            ];
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
    },
  );
}
