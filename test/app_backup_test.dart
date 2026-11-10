@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_backup.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/local_profile_store.dart';
import 'package:iptvs/data/metadata_config.dart';
import 'package:iptvs/data/parental_controls.dart';
import 'package:iptvs/data/profile_pin.dart';
import 'package:iptvs/data/secret_locator_vault.dart';
import 'package:iptvs/dvr/dvr_service.dart';
import 'package:iptvs/l10n/app_language.dart';
import 'package:iptvs/player/buffer_preset.dart';
import 'package:iptvs/player/playback_preferences.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/source_config.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _password = 'portable-backup-password';
const _source = SourceConfig(
  id: 'provider',
  kind: SourceKind.xtream,
  label: 'Living room',
  fields: {
    'host': 'https://provider.invalid',
    'username': 'backup-user',
    'password': 'provider-password-must-be-encrypted',
    'epgUrls': 'https://provider.invalid/guide?token=private-guide-token',
  },
  settings: {
    'hiddenCategories': {
      'live': ['hidden-news'],
    },
    'bufferPreset': 'high',
    'aspectMode': '4:3',
    'catchupOffsetMinutes': -60,
  },
);
const _otherSource = SourceConfig(
  id: 'other-provider',
  kind: SourceKind.m3u,
  label: 'Bedroom',
  fields: {'playlistUrl': 'https://playlist.invalid/private-token'},
);
const _metadata = MetadataConfig(
  provider: 'tvdb',
  tmdbApiKey: 'private-tmdb-key',
  tvdbApiKey: 'private-tvdb-key',
  tvdbPin: 'private-tvdb-pin',
  autoEnrich: false,
);
const _dvrSettings = DvrSettings(
  maxBufferDuration: Duration(minutes: 45),
  maxBufferBytes: 64 * 1024 * 1024,
  maxRecordingsBytes: 512 * 1024 * 1024,
);
const _cloudKeys = {
  'cloud_profile_id',
  'cloud_source_ids',
  'cloud_profile_snapshots_v1',
  'cloud_profile_pins_v1',
  'cloud_source_settings_outbox_v1',
  'cloud_configuration_drafts_v1',
};

Map<String, dynamic> _userState({String sourceId = 'provider'}) => {
  'favorites': [
    {
      'source_id': sourceId,
      'kind': 'live',
      'item_id': 'news',
      'created_at': 1234,
    },
  ],
  'playback_positions': [
    {
      'source_id': sourceId,
      'kind': 'episode',
      'item_id': 'episode-1',
      'position_ms': 45000,
      'duration_ms': 180000,
      'updated_at': 5678,
    },
  ],
  'epg_channel_overrides': [
    {
      'source_id': sourceId,
      'channel_id': 'news',
      'guide_id': 'extra-guide',
      'guide_channel_id': 'news.xmltv',
      'offset_minutes': -60,
    },
  ],
};

List<LocalProfile> _profiles(Map<String, String> settings) => [
  for (final row in jsonDecode(settings['local_profiles_v1']!) as List)
    LocalProfile.fromJson(Map<String, dynamic>.from(row as Map)),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const storage = FlutterSecureStorage();
  final playbackKey = PlaybackPreferencesStore.key('provider', 'episode-1');
  final obsoletePlaybackKey = PlaybackPreferencesStore.key('old', 'old-item');
  final pin = hashProfilePin('4821', salt: List.filled(16, 7));
  final parental = ParentalRules(
    verifier: pin,
    channels: {ParentalRules.channelKey('provider', 'news')},
    categories: {
      ParentalRules.categoryKey('provider', ContentKind.movie, 'adult'),
    },
  );
  const playback = PlaybackPreferences(
    quality: '1080:6000000',
    buffer: BufferPreset.high,
    adaptiveBuffer: true,
    matchRefreshRate: true,
    aspect: '4:3',
  );
  final originalVaultKey = base64UrlEncode(List.filled(32, 19));
  final sourceSettings = <String, String>{
    'sources': jsonEncode([_source.toJson()]),
    'active_source': _source.id,
    'metadata_config': jsonEncode(_metadata.toJson()),
    'active_local_profile_id': 'local-main',
    'local_profiles_v1': jsonEncode([
      LocalProfile(
        id: 'local-main',
        name: 'Main',
        colorIndex: 3,
        pin: pin,
        snapshot: ProfileSnapshot(
          sourcesJson: [_otherSource.toJson()],
          activeSourceId: _otherSource.id,
        ),
      ).toJson(),
      LocalProfile(
        id: 'local-other',
        name: 'Guest',
        colorIndex: 5,
        snapshot: ProfileSnapshot(
          sourcesJson: [_otherSource.toJson()],
          activeSourceId: _otherSource.id,
        ),
      ).toJson(),
    ]),
    'profile_picker_startup': 'always',
    'app_language': 'pl',
    'update_track': 'beta',
    ParentalControlService.storageKey: jsonEncode(parental.toJson()),
    playbackKey: jsonEncode(playback.toJson()),
    SecretLocatorVault.keyName: originalVaultKey,
    'supabase.auth.token': 'original-installation-session',
    'cloud_device_priv_key': 'original-installation-private-key',
    'cloud_device_pub_key': 'original-installation-public-key',
    'cloud_content_key_cloud-main': 'original-installation-content-key',
  };

  group('AppBackupService', () {
    late Uint8List archive;
    late AppBackupSnapshot snapshot;
    late AppBackupSnapshot cloudSnapshot;
    late Directory directory;
    late AppDatabase db;
    late DvrService dvr;
    late AppBackupService service;

    setUpAll(() async {
      final fixture = Directory.systemTemp.createTempSync(
        'tvbro_backup_source_',
      );
      FlutterSecureStorage.setMockInitialValues(sourceSettings);
      final sourceDb = await AppDatabase.openAt('${fixture.path}/source.db');
      final sourceDvr = DvrService(directory: Directory('${fixture.path}/dvr'));
      try {
        await sourceDvr.updateSettings(_dvrSettings);
        await sourceDb.replaceLibrary('provider', 'Provider', const [], const [
          Channel(
            id: 'news',
            name: 'News',
            extra: {'url': 'https://provider.invalid/cache-only-locator'},
          ),
        ]);
        await sourceDb.restoreUserState(_userState());
        final sourceService = AppBackupService(db: sourceDb, dvr: sourceDvr);
        final before = await storage.readAll();
        archive = await sourceService.exportBackup(_password);
        snapshot = await sourceService.readBackup(archive, _password);
        expect(await storage.readAll(), before);

        final cloudSettings = <String, String>{
          ...sourceSettings,
          'local_profiles_v1': '[]',
          'cloud_profile_id': 'cloud-main',
          'cloud_source_ids': jsonEncode([_source.id]),
          'cloud_e2ee_marks': '{"cloud-main":{"seen":true,"ckv":1}}',
          'cloud_profile_snapshots_v1': jsonEncode({
            'cloud-main': ProfileSnapshot(
              sourcesJson: [_otherSource.toJson()],
              activeSourceId: _otherSource.id,
              managedIds: [_otherSource.id],
            ).toJson(),
            'cloud-other': ProfileSnapshot(
              sourcesJson: [_otherSource.toJson()],
              activeSourceId: _otherSource.id,
              managedIds: [_otherSource.id],
            ).toJson(),
          }),
          'cloud_profile_pins_v1': jsonEncode({
            'cloud-main': {'name': 'Cloud main', 'pin': pin},
            'cloud-other': {'name': 'Cloud guest', 'pin': pin},
          }),
        }..remove('active_local_profile_id');
        FlutterSecureStorage.setMockInitialValues(cloudSettings);
        final cloudArchive = await sourceService.exportBackup(_password);
        cloudSnapshot = await sourceService.readBackup(cloudArchive, _password);
      } finally {
        await sourceDvr.close();
        await sourceDb.close();
        fixture.deleteSync(recursive: true);
      }
    });

    setUp(() async {
      directory = Directory.systemTemp.createTempSync('tvbro_backup_target_');
      FlutterSecureStorage.setMockInitialValues({
        'sources': '[]',
        'local_profiles_v1': '[]',
        'profile_picker_startup': 'off',
        'profile_state_ownerless': 'true',
        obsoletePlaybackKey: jsonEncode(const PlaybackPreferences().toJson()),
        'app_language': 'en',
        'cloud_profile_id': 'existing-cloud-profile',
        'cloud_source_ids': '["existing-provider"]',
        'cloud_profile_snapshots_v1': '{}',
        'cloud_profile_pins_v1': '{}',
        'cloud_source_settings_outbox_v1': '{"existing-cloud-profile":{}}',
        'cloud_configuration_drafts_v1': '{"existing-cloud-profile":{}}',
        'cloud_e2ee_marks': '{"existing-cloud-profile":{"seen":true,"ckv":7}}',
        'supabase.auth.token': 'target-installation-session',
        'cloud_device_priv_key': 'target-installation-private-key',
        'cloud_device_pub_key': 'target-installation-public-key',
        'cloud_content_key_cloud-main': 'target-installation-content-key',
        'unrelated-setting': 'preserve-me',
      });
      db = await AppDatabase.openAt('${directory.path}/target.db');
      dvr = DvrService(directory: Directory('${directory.path}/dvr'));
      await dvr.updateSettings(const DvrSettings());
      service = AppBackupService(db: db, dvr: dvr);
      AppLanguageController.instance.preview(AppLanguage.english);
      await ParentalControlService.instance.reload();
    });

    tearDown(() async {
      await dvr.close();
      await db.close();
      directory.deleteSync(recursive: true);
    });

    test(
      'encrypted archive restores portable state into a fresh installation',
      () async {
        final encoded = utf8.decode(archive);
        final envelope = jsonDecode(encoded) as Map;
        expect(envelope['format'], 'tvbro-backup');
        expect(envelope['algorithm'], 'AES-256-GCM');
        expect(envelope['iterations'], 600000);
        for (final secret in [
          _password,
          _source.fields['password']!,
          _metadata.tvdbApiKey,
          originalVaultKey,
          'cache-only-locator',
        ]) {
          expect(encoded, isNot(contains(secret)));
        }
        expect(snapshot.sourceCount, 1);
        expect(snapshot.profileCount, 2);
        expect(snapshot.favoriteCount, 1);
        expect(snapshot.createdAt.isUtc, isTrue);
        final before = await storage.readAll();

        await service.restoreBackup(snapshot);

        final restored = await storage.readAll();
        expect(jsonDecode(restored['sources']!), [_source.toJson()]);
        expect(restored['active_source'], _source.id);
        expect(jsonDecode(restored['metadata_config']!), _metadata.toJson());
        expect(restored['active_local_profile_id'], 'local-main');
        final profiles = _profiles(restored);
        final main = profiles.first;
        expect(main.name, 'Main');
        expect(main.colorIndex, 3);
        expect(verifyProfilePin('4821', main.pin!), isTrue);
        expect(main.snapshot.sourcesJson, [_source.toJson()]);
        expect(main.snapshot.activeSourceId, _source.id);
        expect(main.snapshot.metadataJson, _metadata.toJson());
        expect(
          profiles.last.toJson(),
          (jsonDecode(sourceSettings['local_profiles_v1']!) as List).last,
        );
        expect(restored['profile_picker_startup'], 'always');
        expect(restored['update_track'], 'beta');
        expect(jsonDecode(restored[playbackKey]!), playback.toJson());
        expect(restored, isNot(contains(obsoletePlaybackKey)));
        expect(restored, isNot(contains('profile_state_ownerless')));
        expect(AppLanguageController.instance.language, AppLanguage.polish);
        expect(
          ParentalControlService.instance.rules.toJson(),
          parental.toJson(),
        );
        expect(ParentalControlService.instance.unlocked, isFalse);
        expect(dvr.settings.toJson(), _dvrSettings.toJson());
        expect(await db.exportUserState(), _userState());
        expect(await db.readFavoriteIds('provider', ContentKind.live), {
          'news',
        });
        final position = await db.readPlaybackPosition(
          'provider',
          ContentKind.episode,
          'episode-1',
        );
        expect(position!.position, const Duration(seconds: 45));
        expect(
          (await db.readEpgMappings('provider')).single.guideChannelId,
          'news.xmltv',
        );
        expect(await db.readChannels('provider'), isEmpty);
        expect(
          restored[SecretLocatorVault.keyName],
          before[SecretLocatorVault.keyName],
        );
        expect(restored[SecretLocatorVault.keyName], isNot(originalVaultKey));
        for (final key in [
          'supabase.auth.token',
          'cloud_device_priv_key',
          'cloud_device_pub_key',
          'cloud_content_key_cloud-main',
          'cloud_e2ee_marks',
          'unrelated-setting',
        ]) {
          expect(restored[key], before[key], reason: key);
        }
        for (final key in _cloudKeys) {
          expect(restored, isNot(contains(key)), reason: key);
        }
      },
    );

    test(
      'cloud snapshots become local profiles with their PINs and live state',
      () async {
        await service.restoreBackup(cloudSnapshot);
        final restored = await storage.readAll();
        final profiles = _profiles(restored);
        expect(profiles, hasLength(2));
        expect(
          restored['active_local_profile_id'],
          'restored-cloud-cloud-main',
        );
        final main = profiles.first;
        expect(main.id, 'restored-cloud-cloud-main');
        expect(main.name, 'Cloud main');
        expect(main.snapshot.sourcesJson, [_source.toJson()]);
        expect(main.snapshot.activeSourceId, _source.id);
        expect(main.snapshot.metadataJson, _metadata.toJson());
        expect(profiles.last.name, 'Cloud guest');
        expect(profiles.last.snapshot.sourcesJson, [_otherSource.toJson()]);
        for (final profile in profiles) {
          expect(profile.snapshot.managedIds, isEmpty);
          expect(verifyProfilePin('4821', profile.pin!), isTrue);
        }
        for (final key in _cloudKeys) {
          expect(restored, isNot(contains(key)), reason: key);
        }
        expect(restored['supabase.auth.token'], 'target-installation-session');
        expect(
          restored['cloud_device_priv_key'],
          'target-installation-private-key',
        );
      },
    );

    test(
      'wrong password, tampering and future versions leave all state intact',
      () async {
        await db.restoreUserState(_userState(sourceId: 'existing-provider'));
        final before = await storage.readAll();
        final beforeRows = await db.exportUserState();
        final beforeDvr = dvr.settings.toJson();
        final tampered = Map<String, dynamic>.from(
          jsonDecode(utf8.decode(archive)) as Map,
        );
        final ciphertext = base64Decode(tampered['ciphertext'] as String);
        ciphertext[0] ^= 1;
        tampered['ciphertext'] = base64Encode(ciphertext);
        final future = Map<String, dynamic>.from(
          jsonDecode(utf8.decode(archive)) as Map,
        )..['version'] = 2;
        final cases = [
          (archive, 'wrong-backup-password'),
          (Uint8List.fromList(utf8.encode(jsonEncode(tampered))), _password),
          (Uint8List.fromList(utf8.encode(jsonEncode(future))), _password),
          (Uint8List(0), _password),
        ];
        for (final (bytes, password) in cases) {
          await expectLater(
            service.readBackup(bytes, password),
            throwsFormatException,
          );
          expect(await storage.readAll(), before);
          expect(await db.exportUserState(), beforeRows);
          expect(dvr.settings.toJson(), beforeDvr);
        }
        await expectLater(service.exportBackup('short'), throwsFormatException);
        expect(await storage.readAll(), before);
      },
    );

    test(
      'database failure rolls back settings, cloud bookkeeping and DVR limits',
      () async {
        await db.restoreUserState(_userState(sourceId: 'existing-provider'));
        final before = await storage.readAll();
        final beforeRows = await db.exportUserState();
        final beforeOutbox = await db.readFavoritesOutbox();
        final beforeDvr = dvr.settings.toJson();
        final dvrFile = File('${directory.path}/dvr/settings.json');
        final beforeDvrFile = await dvrFile.readAsString();
        final raw = await databaseFactoryFfi.openDatabase(
          '${directory.path}/target.db',
          options: OpenDatabaseOptions(singleInstance: false),
        );
        try {
          await raw.execute(
            'CREATE TRIGGER reject_backup BEFORE INSERT ON playback_positions '
            "BEGIN SELECT RAISE(ABORT, 'test restore failure'); END",
          );
          await expectLater(
            service.restoreBackup(snapshot),
            throwsA(isA<DatabaseException>()),
          );
          expect(await storage.readAll(), before);
          expect(await db.exportUserState(), beforeRows);
          expect(await db.readFavoritesOutbox(), beforeOutbox);
          expect(dvr.settings.toJson(), beforeDvr);
          expect(await dvrFile.readAsString(), beforeDvrFile);
        } finally {
          await raw.close();
        }
      },
    );
  });
}
