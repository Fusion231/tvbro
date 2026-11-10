import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show
        TargetPlatform,
        debugDefaultTargetPlatformOverride,
        defaultTargetPlatform;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_secure_storage_windows/flutter_secure_storage_windows.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/data/local_profile_store.dart';
import 'package:iptvs/data/metadata_config.dart';
import 'package:iptvs/data/secret_locator_vault.dart';
import 'package:iptvs/data/secure_local_storage.dart';
import 'package:iptvs/data/source_store.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/source_config.dart';
import 'package:iptvs/sources/source_identity.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'support/isolated_host_paths.dart';

// Host qualification only: the existing Windows plugin owns DPAPI and its
// encrypted file format. Only path lookup is adapted, into a fresh TV output
// directory. No storage mock or replacement crypto/storage implementation.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final phase = Platform.environment['TVBRO_STORAGE_PROBE_PHASE'];

  test('original storage bootstrap survives process restart ($phase)', () async {
    expect(Platform.isWindows, isTrue, reason: 'This proof uses host DPAPI.');
    expect(phase, isIn(['write', 'read']));
    final directory = await isolatedHostDirectory(
      'TVBRO_STORAGE_PROBE_DIRECTORY',
      'storage',
    );
    final oldPaths = PathProviderPlatform.instance;
    final oldStorage = FlutterSecureStoragePlatform.instance;
    final oldTarget = debugDefaultTargetPlatformOverride;
    addTearDown(() {
      PathProviderPlatform.instance = oldPaths;
      FlutterSecureStoragePlatform.instance = oldStorage;
      debugDefaultTargetPlatformOverride = oldTarget;
    });

    PathProviderPlatform.instance = IsolatedHostPaths(directory.path);
    // FLUTTER_TEST normally forces Android options even on a Windows VM.
    // Match the actual host, not a simulated Tizen or television identity.
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    FlutterSecureStorageWindows.registerWith();
    expect(
      FlutterSecureStoragePlatform.instance,
      isA<FlutterSecureStorageWindows>(),
    );
    expect((await getApplicationSupportDirectory()).path, directory.path);
    expect((await getTemporaryDirectory()).path, directory.path);

    const secure = FlutterSecureStorage();
    final store = SourceStore();
    const profiles = LocalProfileStore();
    final session = SecureLocalStorage();
    await session.initialize();
    final dbFile = File(p.join(directory.path, 'iptv.db'));
    final writerEvidence = File(
      p.join(directory.path, 'storage-write-evidence.json'),
    );
    int? writerPid;
    if (phase == 'write') {
      expect(await directory.list().isEmpty, isTrue);
      expect(await store.list(), isEmpty);
      expect(await profiles.loadAll(), isEmpty);
      expect(await session.hasAccessToken(), isFalse);
      expect(await secure.read(key: SecretLocatorVault.keyName), isNull);
    } else {
      final writer = jsonDecode(await writerEvidence.readAsString()) as Map;
      writerPid = writer['processId'] as int;
      expect(pid, isNot(writerPid), reason: 'Read must use a fresh process.');
      expect(await dbFile.exists(), isTrue);
      // Read the real plugin directly before open(): a fallback in the vault
      // cannot silently turn an absent or unavailable key into a passing proof.
      final key = await secure.read(key: SecretLocatorVault.keyName);
      expect(key, isNotNull);
      expect(base64Url.decode(key!), hasLength(32));
    }

    final db = await AppDatabase.open();
    try {
      expect(db.vault.generatedNewKey, phase == 'write');
      final key = await secure.read(key: SecretLocatorVault.keyName);
      expect(key, isNotNull);
      expect(base64Url.decode(key!), hasLength(32));
      if (phase == 'write') {
        await store.save(_config);
        await store.saveMetadataConfig(_metadata);
        final profile = await profiles.createProfile(
          'Storage reuse fixture',
          3,
          snapshot: ProfileSnapshot(
            sourcesJson: [_config.toJson()],
            activeSourceId: _config.id,
            metadataJson: _metadata.toJson(),
          ),
        );
        await profiles.setActive(profile.id);
        await profiles.setPickerStartup(ProfilePickerStartup.always);
        await session.persistSession(_session);
        await db.replaceLibrary(
          _config.id,
          _config.label,
          const [Category(id: 'fixture', title: 'Storage fixture')],
          [
            Channel(
              id: stableM3uChannelId(_locator),
              name: 'Stored fixture channel',
              categoryId: 'fixture',
              extra: const {'url': _locator, 'tvgId': 'storage.fixture'},
            ),
          ],
          completeCatalog: true,
        );
      }

      expect((await store.list()).single.toJson(), _config.toJson());
      expect(await store.activeId(), _config.id);
      expect((await store.metadataConfig()).toJson(), _metadata.toJson());
      final profile = (await profiles.loadAll()).single;
      expect(isUuid(profile.id), isTrue);
      expect(profile.name, 'Storage reuse fixture');
      expect(profile.colorIndex, 3);
      expect(await profiles.activeId(), profile.id);
      expect(await profiles.pickerStartup(), ProfilePickerStartup.always);
      expect(profile.snapshot.sourcesJson, [_config.toJson()]);
      expect(profile.snapshot.activeSourceId, _config.id);
      expect(profile.snapshot.metadataJson, _metadata.toJson());
      expect(await session.hasAccessToken(), isTrue);
      expect(await session.accessToken(), _session);

      final cached = (await db.readChannels(_config.id)).single;
      expect(cached.id, stableM3uChannelId(_locator));
      expect(hasSealedLocator(cached.extra), isTrue);
      expect(cached.extra['url'], isNull);
      expect(db.vault.decryptCount, 0);
      final source = (await store.activeConfig())!.build();
      try {
        // M3U connect/resolve makes no HTTP request; the existing repository
        // reveals precisely the cached locator through the persisted OS key.
        final resolved = await LibraryRepository(
          source: source,
          db: db,
        ).resolve(cached);
        expect(resolved.url, _locator);
        expect(resolved.headers, {'User-Agent': 'TVBro-storage-probe'});
        expect(db.vault.decryptCount, 1);
      } finally {
        await source.dispose();
      }
      if (phase == 'read') {
        await session.removePersistedSession();
        expect(await session.hasAccessToken(), isFalse);
        expect(await session.accessToken(), isNull);
      }
    } finally {
      await db.close();
    }

    final encryptedFile = File(
      p.join(directory.path, 'flutter_secure_storage.dat'),
    );
    final encryptedBytes = await encryptedFile.readAsBytes();
    expect(encryptedBytes, isNotEmpty);
    final fileText = utf8.decode(encryptedBytes, allowMalformed: true);
    expect(fileText, isNot(contains(_config.label)));
    expect(fileText, isNot(contains(_metadata.tmdbApiKey)));
    expect(await dbFile.exists(), isTrue);
    await File(p.join(directory.path, 'storage-$phase-evidence.json'))
        .writeAsString(
          jsonEncode({
            'phase': phase,
            'scope': 'Windows host DPAPI; no native TV or cloud qualification',
            'processId': pid,
            if (writerPid != null) 'writerProcessId': writerPid,
            'operatingSystem': Platform.operatingSystem,
            'flutterTargetPlatform': defaultTargetPlatform.name,
            'storageImplementation': FlutterSecureStoragePlatform
                .instance
                .runtimeType
                .toString(),
            'applicationSupportDirectory': directory.path,
            'databaseFile': dbFile.path,
            'encryptedStorageFile': encryptedFile.path,
            'encryptedStorageBytes': encryptedBytes.length,
            'canonicalStoresRestored': true,
            'sealedCacheResolved': true,
            'sessionRemovalVerified': phase == 'read',
          }),
          flush: true,
        );
  });
}

const _config = SourceConfig(
  id: '44444444-4444-4444-8444-444444444444',
  kind: SourceKind.m3u,
  label: 'Native storage fixture',
  fields: {
    'playlistUrl': 'https://fixture.invalid/storage.m3u',
    'userAgent': 'TVBro-storage-probe',
  },
  settings: {
    'hiddenCategories': {
      'live': ['hidden-fixture'],
    },
    'futureFixtureSetting': {'preserved': true},
  },
);
const _metadata = MetadataConfig(
  tmdbApiKey: 'synthetic-storage-metadata-key',
  autoEnrich: false,
);
const _locator =
    'https://streams.invalid/storage-fixture.ts?token=synthetic-storage-token';
const _session =
    '{"access_token":"synthetic-storage-session",'
    '"refresh_token":"synthetic-storage-refresh"}';
