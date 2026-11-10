import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../dvr/dvr_service.dart';
import '../l10n/app_language.dart';
import '../player/playback_preferences.dart';
import '../sources/source_config.dart';
import 'app_database.dart';
import 'diagnostics_log.dart';
import 'local_profile_store.dart';
import 'metadata_config.dart';
import 'parental_controls.dart';
import 'profile_pin.dart';

class AppBackupSnapshot {
  AppBackupSnapshot._(
    this.createdAt,
    this._settings,
    this._userState,
    this._dvr,
  );

  final DateTime createdAt;
  final Map<String, String> _settings;
  final Map<String, dynamic> _userState;
  final DvrSettings _dvr;

  int get sourceCount => (jsonDecode(_settings['sources']!) as List).length;
  int get profileCount =>
      (jsonDecode(_settings['local_profiles_v1']!) as List).length;
  int get favoriteCount => (_userState['favorites'] as List).length;
}

/// Portable user data, deliberately independent of the installation's cache,
/// secret-locator key, cloud authentication session and device identity.
/// Callers must quiesce cloud sync and rebuild the library after restoring.
class AppBackupService {
  AppBackupService({
    required this.db,
    FlutterSecureStorage? storage,
    DvrService? dvr,
  }) : _storage = storage ?? const FlutterSecureStorage(),
       _dvr = dvr ?? DvrService.instance;

  final AppDatabase db;
  final FlutterSecureStorage _storage;
  final DvrService _dvr;
  static const maxFileBytes = 32 * 1024 * 1024;
  static const _iterations = 600000;
  static const _keys = {
    'sources',
    'active_source',
    'metadata_config',
    'local_profiles_v1',
    'active_local_profile_id',
    'profile_picker_startup',
    'profile_state_ownerless',
    'app_language',
    ParentalControlService.storageKey,
    'update_track',
  };
  static const _cloudLocalKeys = {
    'cloud_source_ids',
    'cloud_profile_id',
    'cloud_profile_snapshots_v1',
    'cloud_profile_pins_v1',
    'cloud_source_settings_outbox_v1',
    'cloud_configuration_drafts_v1',
  };

  static bool _userKey(String key) =>
      _keys.contains(key) || key.startsWith('playback_v1_');

  Future<Uint8List> exportBackup(String password) async {
    _checkPassword(password);
    await _dvr.ensureInitialized();
    final settings = _portableSettings(await _storage.readAll());
    final payload = {
      'version': 1,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'settings': settings,
      'userState': await db.exportUserState(),
      'dvrSettings': _dvr.settings.toJson(),
    };
    _snapshot(payload);
    return Isolate.run(() async {
      final cleartext = utf8.encode(jsonEncode(payload));
      if (cleartext.length > maxFileBytes * 3 ~/ 4 - 1024) {
        throw const FormatException('Backup is too large.');
      }
      final random = Random.secure();
      final salt = List<int>.generate(16, (_) => random.nextInt(256));
      final key = await _deriveKey(password, salt);
      final box = await AesGcm.with256bits().encrypt(
        cleartext,
        secretKey: key,
        aad: _aad,
      );
      return Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'format': 'tvbro-backup',
            'version': 1,
            'algorithm': 'AES-256-GCM',
            'kdf': 'PBKDF2-SHA256',
            'iterations': _iterations,
            'salt': base64Encode(salt),
            'nonce': base64Encode(box.nonce),
            'ciphertext': base64Encode(box.cipherText),
            'tag': base64Encode(box.mac.bytes),
          }),
        ),
      );
    });
  }

  Future<AppBackupSnapshot> readBackup(Uint8List bytes, String password) async {
    _checkPassword(password);
    if (bytes.isEmpty || bytes.length > maxFileBytes) {
      throw const FormatException('Invalid backup size.');
    }
    try {
      final payload = await Isolate.run(() async {
        final envelope = jsonDecode(utf8.decode(bytes));
        if (envelope is! Map ||
            envelope['format'] != 'tvbro-backup' ||
            envelope['version'] != 1 ||
            envelope['algorithm'] != 'AES-256-GCM' ||
            envelope['kdf'] != 'PBKDF2-SHA256' ||
            envelope['iterations'] != _iterations) {
          throw const FormatException('Unsupported backup format.');
        }
        final salt = base64Decode(envelope['salt'] as String);
        final nonce = base64Decode(envelope['nonce'] as String);
        final tag = base64Decode(envelope['tag'] as String);
        if (salt.length != 16 || nonce.length != 12 || tag.length != 16) {
          throw const FormatException('Invalid encryption envelope.');
        }
        final cleartext = await AesGcm.with256bits().decrypt(
          SecretBox(
            base64Decode(envelope['ciphertext'] as String),
            nonce: nonce,
            mac: Mac(tag),
          ),
          secretKey: await _deriveKey(password, salt),
          aad: _aad,
        );
        return Map<String, dynamic>.from(
          jsonDecode(utf8.decode(cleartext)) as Map,
        );
      });
      return _snapshot(payload);
    } catch (_) {
      // Never include decrypted values or underlying parser exceptions in UI
      // messages/diagnostics: they can contain provider credentials.
      throw const FormatException('Incorrect password or damaged backup.');
    }
  }

  Future<void> restoreBackup(AppBackupSnapshot snapshot) async {
    await _dvr.ensureInitialized();
    if (_dvr.activeSession != null || _dvr.activeRecording != null) {
      throw StateError(
        'Stop playback and recording before restoring a backup.',
      );
    }
    final before = Map<String, String>.from(await _storage.readAll());
    final previousDvr = _dvr.settings;
    try {
      await _replaceSettings(before, snapshot._settings);
      await _dvr.updateSettings(snapshot._dvr);
      // This is the last fallible persistent operation. It validates first and
      // replaces the complete SQLite user state in one transaction.
      await db.restoreUserState(snapshot._userState);
    } catch (_) {
      await _replaceSettings(await _storage.readAll(), {
        for (final entry in before.entries)
          if (_userKey(entry.key) || _cloudLocalKeys.contains(entry.key))
            entry.key: entry.value,
      });
      await _dvr.updateSettings(previousDvr);
      rethrow;
    }
    // The archive is already committed. A transient keychain read failure must
    // still discard the old shell, and must not skip reloading parental rules
    // (reload revokes its old unlock and fails closed).
    await Future.wait([
      AppLanguageController.instance.initialize().catchError((Object _) {
        DiagnosticsLog.instance.add('backup', 'language_reload_unavailable');
      }),
      ParentalControlService.instance.reload().catchError((Object _) {
        DiagnosticsLog.instance.add('backup', 'parental_reload_unavailable');
      }),
    ]);
  }

  Future<void> _replaceSettings(
    Map<String, String> current,
    Map<String, String> next,
  ) async {
    for (final key in current.keys.toList()) {
      if ((_userKey(key) || _cloudLocalKeys.contains(key)) &&
          !next.containsKey(key)) {
        await _storage.delete(key: key);
      }
    }
    for (final entry in next.entries) {
      await _storage.write(key: entry.key, value: entry.value);
    }
  }

  static List<int> get _aad =>
      utf8.encode('tvbro.backup|1|AES-256-GCM|PBKDF2-SHA256|$_iterations');

  static Future<SecretKey> _deriveKey(String password, List<int> salt) =>
      Pbkdf2(
        macAlgorithm: Hmac.sha256(),
        iterations: _iterations,
        bits: 256,
      ).deriveKey(secretKey: SecretKey(utf8.encode(password)), nonce: salt);

  static void _checkPassword(String password) {
    if (password.length < 8) {
      throw const FormatException('Use a password with at least 8 characters.');
    }
  }

  /// Capture the live local profile, whose stored snapshot can be stale until
  /// the next profile switch. Cloud snapshots become local recovery profiles;
  /// restoring an archive must never impersonate the old device's pairing.
  static Map<String, String> _portableSettings(Map<String, String> all) {
    final settings = {
      for (final entry in all.entries)
        if (_userKey(entry.key)) entry.key: entry.value,
    };
    final current = ProfileSnapshot(
      sourcesJson: _sources(settings['sources'] ?? '[]'),
      activeSourceId: settings['active_source'],
      metadataJson: settings['metadata_config'] == null
          ? const MetadataConfig().toJson()
          : Map<String, dynamic>.from(
              jsonDecode(settings['metadata_config']!) as Map,
            ),
    );
    final profiles = [
      for (final row
          in jsonDecode(settings['local_profiles_v1'] ?? '[]') as List)
        LocalProfile.fromJson(Map<String, dynamic>.from(row as Map)),
    ];
    String? active = settings['active_local_profile_id'];
    for (var i = 0; i < profiles.length; i++) {
      if (profiles[i].id == active) {
        profiles[i] = profiles[i].withSnapshot(current);
      }
    }
    final cloud = Map<String, dynamic>.from(
      jsonDecode(all['cloud_profile_snapshots_v1'] ?? '{}') as Map,
    );
    final locks = Map<String, dynamic>.from(
      jsonDecode(all['cloud_profile_pins_v1'] ?? '{}') as Map,
    );
    final cloudActive = active == null ? all['cloud_profile_id'] : null;
    if (cloudActive != null) cloud[cloudActive] = current.toJson();
    for (final entry in cloud.entries) {
      final saved = ProfileSnapshot.fromJson(
        Map<String, dynamic>.from(entry.value as Map),
      );
      final lock = locks[entry.key] as Map?;
      var id = 'restored-cloud-${entry.key}';
      if (profiles.any((profile) => profile.id == id)) id = newSourceId();
      profiles.add(
        LocalProfile(
          id: id,
          name: lock?['name'] as String? ?? 'Restored cloud profile',
          colorIndex: 0,
          pin: lock?['pin'] as String?,
          snapshot: ProfileSnapshot(
            sourcesJson: saved.sourcesJson,
            activeSourceId: saved.activeSourceId,
            metadataJson: saved.metadataJson,
          ),
        ),
      );
      if (entry.key == cloudActive) active = id;
    }
    if (active == null && current.sourcesJson.isNotEmpty) {
      active = newSourceId();
      profiles.add(
        LocalProfile(
          id: active,
          name: 'Restored profile',
          colorIndex: 0,
          snapshot: current,
        ),
      );
    }
    settings['sources'] = jsonEncode(current.sourcesJson);
    settings['local_profiles_v1'] = jsonEncode(
      profiles.map((p) => p.toJson()).toList(),
    );
    if (active != null) {
      settings['active_local_profile_id'] = active;
      settings.remove('profile_state_ownerless');
    }
    return settings;
  }

  static List<Map<String, dynamic>> _sources(String raw) {
    final rows = jsonDecode(raw) as List;
    final ids = <String>{};
    return [
      for (final value in rows)
        (() {
          final row = Map<String, dynamic>.from(value as Map);
          final source = SourceConfig.fromJson(row);
          if (source.id.isEmpty || !ids.add(source.id)) {
            throw const FormatException('Invalid source identity.');
          }
          return row;
        })(),
    ];
  }

  static AppBackupSnapshot _snapshot(Map<String, dynamic> payload) {
    if (payload['version'] != 1) {
      throw const FormatException('Unsupported backup version.');
    }
    final created = DateTime.parse(payload['createdAt'] as String);
    final settings = Map<String, String>.from(payload['settings'] as Map);
    if (settings.keys.any((key) => !_userKey(key))) {
      throw const FormatException('Unexpected backup setting.');
    }
    final sources = _sources(settings['sources']!);
    void checkActive(List<Map<String, dynamic>> rows, String? active) {
      if (active != null && !rows.any((row) => row['id'] == active)) {
        throw const FormatException('Invalid active source.');
      }
    }

    checkActive(sources, settings['active_source']);
    final profiles = jsonDecode(settings['local_profiles_v1']!) as List;
    final profileIds = <String>{};
    for (final value in profiles) {
      final profile = LocalProfile.fromJson(
        Map<String, dynamic>.from(value as Map),
      );
      if (profile.id.isEmpty ||
          !profileIds.add(profile.id) ||
          (profile.pin != null && !isProfilePinVerifier(profile.pin!))) {
        throw const FormatException('Invalid profile.');
      }
      final rows = _sources(jsonEncode(profile.snapshot.sourcesJson));
      checkActive(rows, profile.snapshot.activeSourceId);
      if (profile.snapshot.metadataJson case final metadata?) {
        MetadataConfig.fromJson(metadata);
      }
    }
    final active = settings['active_local_profile_id'];
    if (active != null && !profileIds.contains(active)) {
      throw const FormatException('Invalid active profile.');
    }
    if (settings['metadata_config'] case final raw?) {
      MetadataConfig.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
    }
    if (settings[ParentalControlService.storageKey] case final raw?) {
      ParentalRules.fromJson(jsonDecode(raw));
    }
    if (settings['app_language'] case final language?) {
      if (!AppLanguage.values.any((value) => value.code == language)) {
        throw const FormatException('Unsupported backup language.');
      }
    }
    if (settings['profile_picker_startup'] case final startup?) {
      ProfilePickerStartup.values.byName(startup);
    }
    for (final entry in settings.entries) {
      if (!entry.key.startsWith('playback_v1_')) continue;
      final identity = jsonDecode(
        utf8.decode(base64Url.decode(entry.key.substring(12))),
      );
      if (identity is! List ||
          identity.length != 2 ||
          identity.any((value) => value is! String || value.isEmpty)) {
        throw const FormatException('Invalid playback identity.');
      }
      PlaybackPreferences.fromJson(
        Map<String, dynamic>.from(jsonDecode(entry.value) as Map),
      );
    }
    final userState = Map<String, dynamic>.from(payload['userState'] as Map);
    AppDatabase.validateUserState(userState);
    final dvr = DvrSettings.fromJson(
      Map<String, dynamic>.from(payload['dvrSettings'] as Map),
    );
    dvr.validate();
    return AppBackupSnapshot._(created, settings, userState, dvr);
  }
}
