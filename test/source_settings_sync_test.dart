import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/cloud_sync.dart';
import 'package:iptvs/data/metadata_config.dart';
import 'package:iptvs/data/source_store.dart';
import 'package:iptvs/sources/source_config.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _sourceId = '00000000-0000-4000-8000-000000000001';
const _profileId = '00000000-0000-4000-8000-000000000002';

SourceConfig _source(Map<String, dynamic> settings) => SourceConfig(
  id: _sourceId,
  kind: SourceKind.demo,
  label: 'Provider',
  fields: const {},
  settings: settings,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SourceStore store;
  const storage = FlutterSecureStorage();

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({
      'cloud_profile_id': _profileId,
      'cloud_source_ids': _sourceId,
    });
    store = SourceStore();
    await store.setAll([
      _source({'bufferPreset': 'normal'}),
    ]);
  });

  test(
    'offline edits persist and a pull overlays only locally touched keys',
    () async {
      await store.save(_source({'bufferPreset': 'high'}));
      final reopened = SourceStore();
      expect(
        (await reopened.readSettingsOutbox(_profileId)).single.value,
        'high',
      );
      await reopened.applyCloudSources([
        _source({'bufferPreset': 'low', 'aspectMode': 'Fill'}),
      ], _profileId);
      expect((await reopened.list()).single.settings, {
        'bufferPreset': 'high',
        'aspectMode': 'Fill',
      });
      expect(await reopened.readSettingsOutbox('another-profile'), isEmpty);
    },
  );

  test(
    'unpair clears drafts created while removing cloud-managed sources',
    () async {
      await store.save(
        _source({'bufferPreset': 'high'}).copyWith(label: 'Local edit'),
      );
      await store.saveMetadataConfig(const MetadataConfig(provider: 'tvdb'));
      final client = SupabaseClient('https://example.invalid', 'test');
      addTearDown(client.dispose);
      await CloudSync(client: client).unpair(store);
      final drafts = await store.readSourceDraftState(_profileId);
      expect(drafts.versions, isEmpty);
      expect(drafts.deletions, isEmpty);
      expect((await store.readMetadataDraftState(_profileId)).version, isNull);
      expect(await store.readSettingsOutbox(_profileId), isEmpty);
      expect(await store.list(), isEmpty);
    },
  );

  test(
    'cloud imports and local-only profiles never enqueue settings',
    () async {
      var events = 0;
      final listener = store.settingsChanged.listen((_) => events++);
      addTearDown(listener.cancel);
      await store.applyCloudSources([
        _source({'bufferPreset': 'max'}),
      ], _profileId);
      expect(events, 0);
      await storage.write(key: 'active_local_profile_id', value: 'local');
      await store.save(_source({'bufferPreset': 'high'}));
      expect(await store.readSettingsOutbox(_profileId), isEmpty);
      await storage.delete(key: 'active_local_profile_id');
      await storage.write(key: 'profile_state_ownerless', value: '1');
      await store.save(_source({'bufferPreset': 'low'}));
      expect(await store.readSettingsOutbox(_profileId), isEmpty);
      expect(events, 0);
    },
  );

  test('local sources, credentials and unknown preferences stay out of automatic push', () async {
    await store.save(
      _source({'bufferPreset': 'normal', 'hardwareChoice': true}),
    );
    await store.save(
      _source({'bufferPreset': 'normal'})
          .copyWith(fields: {'password': 'private'}),
    );
    await store.save(
      _source({'bufferPreset': 'normal'}).copyWith(id: 'local-only'),
    );
    await store.save(
      _source({'bufferPreset': 'high'}).copyWith(id: 'local-only'),
    );
    expect(await store.readSettingsOutbox(_profileId), isEmpty);
  });

  test(
    'acknowledging a sent value never clears a newer in-flight edit',
    () async {
      await store.save(_source({'bufferPreset': 'high'}));
      final sent = await store.readSettingsOutbox(_profileId);
      await store.save(_source({'bufferPreset': 'low', 'aspectMode': 'Fill'}));
      await store.clearSettingsOutbox(_profileId, sent);
      final pending = await store.readSettingsOutbox(_profileId);
      expect(pending, hasLength(2));
      expect(
        pending
            .firstWhere((entry) => entry.path.single == 'bufferPreset')
            .value,
        'low',
      );
      await store.clearSettingsOutbox(_profileId, pending);
      expect(await store.readSettingsOutbox(_profileId), isEmpty);
    },
  );

  test(
    'nested deltas preserve edits to other kinds and channel names',
    () async {
      await store.setAll([
        _source({
          'hiddenCategories': {
            'live': ['old'],
            'movie': ['movie-old'],
          },
          'channelOrganization': {
            'names': {'a': 'A', 'b': 'B'},
          },
        }),
      ]);
      await store.save(
        _source({
          'hiddenCategories': {
            'live': ['local'],
            'movie': ['movie-old'],
          },
          'channelOrganization': {
            'names': {'a': 'My A', 'b': 'B'},
          },
        }),
      );
      await store.applyCloudSources([
        _source({
          'hiddenCategories': {
            'live': ['old'],
            'movie': ['remote'],
          },
          'channelOrganization': {
            'names': {'a': 'A', 'b': 'Remote B'},
          },
        }),
      ], _profileId);
      expect((await store.list()).single.settings, {
        'hiddenCategories': {
          'live': ['local'],
          'movie': ['remote'],
        },
        'channelOrganization': {
          'names': {'a': 'My A', 'b': 'Remote B'},
        },
      });
    },
  );

  test(
    'removal is explicit and a new object does not replace remote siblings',
    () async {
      await store.save(
        _source({
          'channelOrganization': {
            'names': {'a': 'My A'},
          },
        }),
      );
      final patch = sourceSettingsPatch(
        await store.readSettingsOutbox(_profileId),
      );
      expect(patch['bufferPreset'], isNull);
      expect(patch.containsKey('bufferPreset'), isTrue);
      expect(
        applySourceSettingsPatch({
          'bufferPreset': 'normal',
          'channelOrganization': {
            'names': {'b': 'Remote B'},
          },
        }, patch),
        {
          'channelOrganization': {
            'names': {'a': 'My A', 'b': 'Remote B'},
          },
        },
      );
    },
  );

  test(
    'a user edit queued during a cloud request survives the incoming snapshot',
    () async {
      final remoteReady = Completer<List<SourceConfig>>();
      final pulling = () async {
        final remote = await remoteReady.future;
        await store.applyCloudSources(remote, _profileId);
      }();
      await store.save(_source({'bufferPreset': 'high'}));
      remoteReady.complete([
        _source({'bufferPreset': 'low'}),
      ]);
      await pulling;
      expect((await store.list()).single.bufferPresetName, 'high');
    },
  );

  test('a rejected settings RPC retains outbox and successful retry sends only changes', () async {
    final previousOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = previousOverrides);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var reject = true;
    Map<String, dynamic>? payload;
    server.listen((request) async {
      payload = Map<String, dynamic>.from(
        jsonDecode(await utf8.decoder.bind(request).join()) as Map,
      );
      request.response.headers.contentType = ContentType.json;
      if (reject) {
        request.response.statusCode = 503;
        request.response.write(
          jsonEncode({'message': 'Unavailable', 'code': '503'}),
        );
      } else {
        request.response.write('null');
      }
      await request.response.close();
    });
    final client = SupabaseClient(
      'http://127.0.0.1:${server.port}',
      'public-test-key',
    );
    addTearDown(client.dispose);
    final sync = CloudSync(client: client);
    await store.save(_source({'bufferPreset': 'high'}));
    await expectLater(
      sync.pushSourceSettingsDelta(store, _profileId),
      throwsA(isA<PostgrestException>()),
    );
    expect(await store.readSettingsOutbox(_profileId), isNotEmpty);
    reject = false;
    expect(await sync.pushSourceSettingsDelta(store, _profileId), isTrue);
    expect(payload, {
      'p_profile_id': _profileId,
      'p_changes': [
        {
          'source_id': _sourceId,
          'changes': {'bufferPreset': 'high'},
        },
      ],
    });
    expect(await store.readSettingsOutbox(_profileId), isEmpty);
  });

  test(
    'single-setting save uses the current source after a remote update',
    () async {
      await store.applyCloudSources(
        [
          _source({'bufferPreset': 'max'}).copyWith(
            label: 'Renamed remotely',
            fields: {'providerChoice': 'remote'},
          ),
        ],
        _profileId,
        preserveLocalChanges: true,
      );
      await store.saveSetting(_sourceId, 'aspectMode', 'Fill');
      final current = (await store.list()).single;
      expect(current.label, 'Renamed remotely');
      expect(current.fields, {'providerChoice': 'remote'});
      expect(current.settings, {'bufferPreset': 'max', 'aspectMode': 'Fill'});
      expect((await store.readSourceDraftState(_profileId)).versions, isEmpty);
    },
  );

  test(
    'snapshot metadata restores and local-profile edits are quiet',
    () async {
      await store.saveMetadataConfig(
        const MetadataConfig(tmdbApiKey: 'snapshot-key'),
        fromCloud: true,
      );
      expect((await store.readMetadataDraftState(_profileId)).version, isNull);
      await storage.write(key: 'active_local_profile_id', value: 'local');
      await store.saveMetadataConfig(
        const MetadataConfig(tmdbApiKey: 'local-key'),
      );
      expect((await store.readMetadataDraftState(_profileId)).version, isNull);
    },
  );

  test('automatic imports preserve unsent provider and metadata drafts until a manual pull', () async {
    final previousOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = previousOverrides);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      final Object? response = switch (request.uri.path) {
        '/rest/v1/rpc/get_crypto_state' => {'enabled': false},
        '/rest/v1/rpc/get_secrets' => {
          'sources': {},
          'metadata': {
            'format': 0,
            'payload': {'tmdbApiKey': 'remote-key'},
          },
        },
        '/rest/v1/sources' => [
          {
            'id': _sourceId,
            'kind': 'demo',
            'label': 'Remote provider',
            'fields': {'providerChoice': 'remote'},
            'settings': {'bufferPreset': 'low'},
          },
        ],
        '/rest/v1/metadata_configs' => {
          'config': {'provider': 'tmdb', 'autoEnrich': true},
        },
        _ => null,
      };
      request.response.write(jsonEncode(response));
      await request.response.close();
    });
    final client = SupabaseClient(
      'http://127.0.0.1:${server.port}',
      'test-key',
    );
    addTearDown(client.dispose);
    final sync = CloudSync(client: client);
    await store.save(
      _source({
        'bufferPreset': 'normal',
      }).copyWith(label: 'Local provider', fields: {'providerChoice': 'local'}),
    );
    await store.saveMetadataConfig(
      const MetadataConfig(
        provider: 'tvdb',
        tmdbApiKey: 'local-key',
        autoEnrich: false,
      ),
    );
    await sync.pullSources(store, _profileId, preserveLocalChanges: true);
    await sync.pullMetadata(store, _profileId, preserveLocalChanges: true);
    final source = (await store.list()).single;
    expect(source.label, 'Local provider');
    expect(source.fields, {'providerChoice': 'local'});
    expect(
      source.bufferPresetName,
      'low',
      reason: 'remote settings still synchronize',
    );
    expect((await store.metadataConfig()).tmdbApiKey, 'local-key');
    expect((await store.metadataConfig()).provider, 'tvdb');
    expect(
      (await SourceStore().readSourceDraftState(_profileId)).versions,
      isNotEmpty,
    );
    expect(
      (await store.readMetadataDraftState('another-profile')).version,
      isNull,
    );
    await sync.pullSources(store, _profileId);
    await sync.pullMetadata(store, _profileId);
    expect((await store.list()).single.label, 'Remote provider');
    expect((await store.metadataConfig()).tmdbApiKey, 'remote-key');
    expect((await store.readSourceDraftState(_profileId)).versions, isEmpty);
    expect((await store.readMetadataDraftState(_profileId)).version, isNull);
  });

  test(
    'manual pushes acknowledge only delivered draft and settings versions',
    () async {
      final previousOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = previousOverrides);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      Future<void> Function()? duringSourcePush;
      Future<void> Function()? duringMetadataPush;
      server.listen((request) async {
        request.response.headers.contentType = ContentType.json;
        Object? response;
        if (request.uri.path == '/rest/v1/rpc/get_crypto_state') {
          response = {'enabled': false};
        } else if (request.uri.path == '/rest/v1/rpc/push_sources') {
          await duringSourcePush?.call();
        } else if (request.uri.path == '/rest/v1/rpc/push_metadata') {
          await duringMetadataPush?.call();
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
      await store.save(
        _source({'bufferPreset': 'high'}).copyWith(label: 'First edit'),
      );
      await store.saveMetadataConfig(
        const MetadataConfig(tmdbApiKey: 'first-key'),
      );
      duringSourcePush = () => store.save(
        _source({'bufferPreset': 'max'}).copyWith(label: 'Newer edit'),
      );
      duringMetadataPush = () => store.saveMetadataConfig(
        const MetadataConfig(tmdbApiKey: 'newer-key'),
      );
      await sync.pushSources(store, _profileId);
      await sync.pushMetadata(store, _profileId);
      expect(
        (await store.readSourceDraftState(_profileId)).versions,
        isNotEmpty,
      );
      expect(
        (await store.readMetadataDraftState(_profileId)).version,
        isNotNull,
      );
      expect((await store.readSettingsOutbox(_profileId)).single.value, 'max');
      duringSourcePush = null;
      duringMetadataPush = null;
      await sync.pushSources(store, _profileId);
      await sync.pushMetadata(store, _profileId);
      expect((await store.readSourceDraftState(_profileId)).versions, isEmpty);
      expect((await store.readMetadataDraftState(_profileId)).version, isNull);
      expect(await store.readSettingsOutbox(_profileId), isEmpty);

      await store.saveSetting(_sourceId, 'bufferPreset', 'high');
      await store.delete(_sourceId);
      await sync.pushSources(store, _profileId);
      expect((await store.readSourceDraftState(_profileId)).deletions, isEmpty);
      expect(
        await store.readSettingsOutbox(_profileId),
        isEmpty,
        reason: 'a delivered deletion also consumes its old setting intent',
      );

      await sync.setManagedSourceIds({_sourceId});
      await store.setAll([
        _source({'bufferPreset': 'normal'}),
      ]);
      await store.saveSetting(_sourceId, 'bufferPreset', 'high');
      await store.delete(_sourceId);
      duringSourcePush = () async {
        await store.save(
          _source({'bufferPreset': 'high'}).copyWith(label: 'Re-added'),
        );
        await store.saveSetting(_sourceId, 'bufferPreset', 'max');
      };
      await sync.pushSources(store, _profileId);
      expect(
        (await store.readSourceDraftState(_profileId)).versions,
        isNotEmpty,
      );
      expect(
        (await store.readSettingsOutbox(_profileId)).single.value,
        'max',
        reason: 'a re-add and newer preference during deletion push survive its acknowledgement',
      );
    },
  );

  test(
    'automatic import retains local deletion until explicit pull or re-add',
    () async {
      await store.delete(_sourceId);
      final deleted = await SourceStore().readSourceDraftState(_profileId);
      expect(deleted.deletions.keys, [_sourceId]);
      await store.applyCloudSources(
        [
          _source({'bufferPreset': 'low'}),
        ],
        _profileId,
        preserveLocalChanges: true,
      );
      expect(await store.list(), isEmpty);
      await store.save(
        _source({'bufferPreset': 'high'}).copyWith(label: 'Re-added locally'),
      );
      expect((await store.readSourceDraftState(_profileId)).deletions, isEmpty);
      expect(
        (await store.readSourceDraftState(_profileId)).versions,
        isNotEmpty,
      );
      await store.acknowledgeSourceDrafts(
        _profileId,
        {},
        deletions: deleted.deletions,
      );
      await store.applyCloudSources(
        [
          _source({'bufferPreset': 'low'}),
        ],
        _profileId,
        preserveLocalChanges: true,
      );
      expect((await store.list()).single.label, 'Re-added locally');
      await store.delete(_sourceId);
      await store.applyCloudSources([
        _source({'bufferPreset': 'low'}),
      ], _profileId);
      expect((await store.list()).single.label, 'Provider');
      expect((await store.readSourceDraftState(_profileId)).deletions, isEmpty);
      expect((await store.readSourceDraftState(_profileId)).versions, isEmpty);
    },
  );

  test(
    'a remote deletion cannot discard an unsent local provider draft',
    () async {
      await store.save(
        _source({
          'bufferPreset': 'normal',
        }).copyWith(label: 'Unsent edit', fields: {'providerChoice': 'local'}),
      );
      await store.applyCloudSources([], _profileId, preserveLocalChanges: true);
      expect((await store.list()).single.fields, {'providerChoice': 'local'});
      await store.applyCloudSources([], _profileId);
      expect(await store.list(), isEmpty);
      expect((await store.readSourceDraftState(_profileId)).versions, isEmpty);
    },
  );
}
