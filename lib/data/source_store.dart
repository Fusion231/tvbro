import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'metadata_config.dart';
import '../sources/source_config.dart';

/// Non-secret source preferences supported by automatic synchronization.
const syncedSourceSettingKeys = {
  'aspectMode',
  'bufferPreset',
  'catchupTimezone',
  'catchupOffsetMinutes',
  'catchupMaxDays',
  'expiryReminderDays',
  'streamExtension',
  'hiddenCategories',
  'channelOrganization',
};

class SourceSettingsChange {
  const SourceSettingsChange({
    required this.sourceId,
    required this.path,
    required this.value,
    required this.version,
  });

  final String sourceId;
  final List<String> path;
  final Object? value;
  final String version;
}

/// JSON Merge Patch: object members merge recursively, null deletes a member,
/// and arrays/scalars replace only the value explicitly named in the patch.
Map<String, dynamic> applySourceSettingsPatch(
  Map<String, dynamic> settings,
  Map<String, dynamic> patch,
) {
  final result = Map<String, dynamic>.from(settings);
  for (final entry in patch.entries) {
    if (entry.value == null) {
      result.remove(entry.key);
    } else if (entry.value is Map) {
      final previous = result[entry.key];
      result[entry.key] = applySourceSettingsPatch(
        previous is Map ? Map<String, dynamic>.from(previous) : {},
        Map<String, dynamic>.from(entry.value as Map),
      );
    } else {
      result[entry.key] = entry.value;
    }
  }
  return result;
}

Map<String, dynamic> sourceSettingsPatch(
  Iterable<SourceSettingsChange> changes,
) {
  final patch = <String, dynamic>{};
  for (final change in changes) {
    var target = patch;
    for (final key in change.path.take(change.path.length - 1)) {
      target = target.putIfAbsent(
        key,
        () => <String, dynamic>{},
      ) as Map<String, dynamic>;
    }
    target[change.path.last] = change.value;
  }
  return patch;
}

/// Persists provider configurations (credentials included) in the OS keychain
/// via flutter_secure_storage, plus which one is active.
class SourceStore {
  final FlutterSecureStorage _storage;

  static const _kSources = 'sources';
  static const _kActive = 'active_source';
  static const _kMetadata = 'metadata_config';
  static const _kSettingsOutbox = 'cloud_source_settings_outbox_v1';
  static const _kConfigDrafts = 'cloud_configuration_drafts_v1';
  final _settingsChanged = StreamController<void>.broadcast(sync: true);
  Future<void>? _pendingWrite;

  Stream<void> get settingsChanged => _settingsChanged.stream;

  // A pull and a user save must not overwrite each other's source/outbox read.
  Future<T> _serialize<T>(Future<T> Function() operation) {
    final previous = _pendingWrite;
    final result = previous == null
        ? Future<T>.sync(operation)
        : previous.then((_) => operation());
    final tail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _pendingWrite = tail;
    unawaited(
      tail.then((_) {
        if (identical(_pendingWrite, tail)) _pendingWrite = null;
      }),
    );
    return result;
  }

  SourceStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  Future<List<SourceConfig>> list() async {
    final raw = await _storage.read(key: _kSources);
    if (raw == null || raw.isEmpty) return const [];
    final arr = jsonDecode(raw) as List;
    return arr
        .map((e) => SourceConfig.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<void> save(SourceConfig config) => _serialize(() => _save(config));

  Future<void> _save(SourceConfig config) async {
    final all = List<SourceConfig>.of(await list());
    final i = all.indexWhere((c) => c.id == config.id);
    final previous = i < 0 ? null : all[i];
    if (i >= 0) {
      all[i] = config;
    } else {
      all.add(config);
    }
    // Persist intent first: an interruption before the source write is healed
    // by the next cloud pull overlaying this durable outbox.
    if (previous != null) await _queueSettingsChanges(previous, config);
    final profileId = await _activeCloudProfileId(sourceId: config.id);
    if (profileId != null) {
      final drafts = await _configurationDrafts();
      final existing = drafts[profileId] as Map?;
      final deletions = existing?['deletions'] as Map?;
      if (previous == null ||
          previous.kind != config.kind ||
          previous.label != config.label ||
          jsonEncode(previous.fields) != jsonEncode(config.fields) ||
          deletions?.containsKey(config.id) == true) {
        final profile =
            drafts.putIfAbsent(profileId, () => <String, dynamic>{}) as Map;
        final sources =
            profile.putIfAbsent('sources', () => <String, dynamic>{}) as Map;
        sources[config.id] = newSourceId();
        deletions?.remove(config.id);
        if (deletions?.isEmpty == true) profile.remove('deletions');
        await _storage.write(key: _kConfigDrafts, value: jsonEncode(drafts));
      }
    }
    await _writeAll(all);
    // First source added becomes the active one automatically.
    if (await activeId() == null) await setActive(config.id);
  }

  /// Playback can hold an older SourceConfig while remote settings change.
  /// Update its single preference against the latest saved source instead.
  Future<void> saveSetting(String sourceId, String key, Object? value) =>
      _serialize(() async {
        final source = (await list())
            .where((source) => source.id == sourceId)
            .firstOrNull;
        if (source == null) return;
        final settings = Map<String, dynamic>.from(source.settings);
        if (value == null) {
          settings.remove(key);
        } else {
          settings[key] = value;
        }
        await _save(source.copyWith(settings: settings));
      });

  Future<void> delete(String id) => _serialize(() async {
    final all = List<SourceConfig>.of(await list());
    all.removeWhere((c) => c.id == id);
    final profileId = await _activeCloudProfileId(sourceId: id);
    if (profileId != null) {
      final drafts = await _configurationDrafts();
      final profile =
          drafts.putIfAbsent(profileId, () => <String, dynamic>{}) as Map;
      final deletions =
          profile.putIfAbsent('deletions', () => <String, dynamic>{}) as Map;
      deletions[id] = newSourceId();
      final sources = profile['sources'] as Map?;
      sources?.remove(id);
      if (sources?.isEmpty == true) profile.remove('sources');
      await _storage.write(key: _kConfigDrafts, value: jsonEncode(drafts));
    }
    await _writeAll(all);
    if (await activeId() == id) {
      await setActive(all.isEmpty ? null : all.first.id);
    }
  });

  /// Replace the entire source list with [ordered], preserving its order. Used
  /// by cloud pull to mirror the panel's ordering on the device. The active
  /// selection is kept when it's still present; otherwise it falls back to the
  /// first source (or null when the list is empty).
  Future<void> setAll(List<SourceConfig> ordered) =>
      _serialize(() => _setAll(ordered));

  Future<void> _setAll(List<SourceConfig> ordered) async {
    await _writeAll(ordered);
    final active = await activeId();
    if (ordered.isEmpty) {
      await setActive(null);
    } else if (active == null || !ordered.any((c) => c.id == active)) {
      await setActive(ordered.first.id);
    }
  }

  /// A remote import is quiet and rebases pending local intent over the cloud
  /// baseline, including edits made while the network request was in flight.
  Future<void> applyCloudSources(
    List<SourceConfig> ordered,
    String profileId, {
    bool preserveLocalChanges = false,
  }) => _serialize(() async {
    final pending = await _readSettingsOutbox(profileId);
    final drafts = await _configurationDrafts();
    final profileDraft = drafts[profileId] as Map?;
    final dirtySources = profileDraft?['sources'] as Map? ?? const {};
    final deletedSources = profileDraft?['deletions'] as Map? ?? const {};
    final current = {for (final source in await list()) source.id: source};
    final incoming = List<SourceConfig>.of(ordered);
    final incomingIds = {for (final source in incoming) source.id};
    if (preserveLocalChanges) {
      for (final source in current.values) {
        if (dirtySources.containsKey(source.id) &&
            !deletedSources.containsKey(source.id) &&
            !incomingIds.contains(source.id)) {
          incoming.add(source);
        }
      }
    }
    await _setAll([
      for (final source in incoming)
        if (!preserveLocalChanges || !deletedSources.containsKey(source.id))
          source.copyWith(
            kind: preserveLocalChanges && dirtySources.containsKey(source.id)
                ? current[source.id]?.kind
                : null,
            label: preserveLocalChanges && dirtySources.containsKey(source.id)
                ? current[source.id]?.label
                : null,
            fields: preserveLocalChanges && dirtySources.containsKey(source.id)
                ? current[source.id]?.fields
                : null,
            settings: applySourceSettingsPatch(
              source.settings,
              sourceSettingsPatch(
                pending.where((entry) => entry.sourceId == source.id),
              ),
            ),
          ),
    ]);
    if (!preserveLocalChanges && profileDraft != null) {
      profileDraft.remove('sources');
      profileDraft.remove('deletions');
      if (profileDraft.isEmpty) drafts.remove(profileId);
      await _storage.write(key: _kConfigDrafts, value: jsonEncode(drafts));
    }
  });

  Future<Map<String, dynamic>> _configurationDrafts() async {
    final raw = await _storage.read(key: _kConfigDrafts);
    return raw == null || raw.isEmpty
        ? {}
        : Map<String, dynamic>.from(jsonDecode(raw) as Map);
  }

  Future<String?> _activeCloudProfileId({String? sourceId}) async {
    if (await _storage.read(key: 'active_local_profile_id') != null ||
        await _storage.read(key: 'profile_state_ownerless') == '1') {
      return null;
    }
    final profileId = await _storage.read(key: 'cloud_profile_id');
    if (profileId == null) return null;
    if (sourceId != null) {
      final managed = (await _storage.read(key: 'cloud_source_ids') ?? '')
          .split(',');
      if (!managed.contains(sourceId)) {
        final profile = (await _configurationDrafts())[profileId] as Map?;
        if (!(profile?['sources'] as Map? ?? const {}).containsKey(sourceId) &&
            !(profile?['deletions'] as Map? ?? const {}).containsKey(
              sourceId,
            )) {
          return null;
        }
      }
    }
    return profileId;
  }

  /// Capture data and acknowledgement versions together. A save during the
  /// network request must not be mistaken for the draft that was sent.
  Future<
    ({
      List<SourceConfig> sources,
      Map<String, String> versions,
      Map<String, String> deletions,
      List<SourceSettingsChange> settingsChanges,
    })
  >
  readSourceDraftState(String profileId) => _serialize(() async {
    final profile = (await _configurationDrafts())[profileId] as Map?;
    return (
      sources: await list(),
      versions: Map<String, String>.from(profile?['sources'] as Map? ?? {}),
      deletions: Map<String, String>.from(profile?['deletions'] as Map? ?? {}),
      settingsChanges: await _readSettingsOutbox(profileId),
    );
  });

  Future<void> acknowledgeSourceDrafts(
    String profileId,
    Map<String, String> sent, {
    Map<String, String> deletions = const {},
  }) => _serialize(() async {
    final drafts = await _configurationDrafts();
    final profile = drafts[profileId] as Map?;
    final sources = profile?['sources'] as Map?;
    if (profile == null) return;
    for (final entry in sent.entries) {
      if (sources?[entry.key] == entry.value) sources!.remove(entry.key);
    }
    if (sources?.isEmpty == true) profile.remove('sources');
    final removed = profile['deletions'] as Map?;
    for (final entry in deletions.entries) {
      if (removed?[entry.key] == entry.value) removed!.remove(entry.key);
    }
    if (removed?.isEmpty == true) profile.remove('deletions');
    if (profile.isEmpty) drafts.remove(profileId);
    await _storage.write(key: _kConfigDrafts, value: jsonEncode(drafts));
  });

  Future<({MetadataConfig config, String? version})> readMetadataDraftState(
    String profileId,
  ) => _serialize(() async {
    final profile = (await _configurationDrafts())[profileId] as Map?;
    return (
      config: await metadataConfig(),
      version: profile?['metadata'] as String?,
    );
  });

  Future<void> acknowledgeMetadataDraft(String profileId, String? sent) =>
      _serialize(() async {
        if (sent == null) return;
        final drafts = await _configurationDrafts();
        final profile = drafts[profileId] as Map?;
        if (profile?['metadata'] != sent) return;
        profile!.remove('metadata');
        if (profile.isEmpty) drafts.remove(profileId);
        await _storage.write(key: _kConfigDrafts, value: jsonEncode(drafts));
      });

  Future<void> applyCloudMetadataConfig(
    MetadataConfig config,
    String profileId, {
    bool preserveLocalChanges = false,
  }) => _serialize(() async {
    final drafts = await _configurationDrafts();
    final profile = drafts[profileId] as Map?;
    if (preserveLocalChanges && profile?['metadata'] != null) return;
    await _storage.write(key: _kMetadata, value: jsonEncode(config.toJson()));
    if (!preserveLocalChanges && profile != null) {
      profile.remove('metadata');
      if (profile.isEmpty) drafts.remove(profileId);
      await _storage.write(key: _kConfigDrafts, value: jsonEncode(drafts));
    }
  });

  Future<void> clearAllCloudDrafts() =>
      _serialize(() => _storage.delete(key: _kConfigDrafts));

  Future<List<SourceSettingsChange>> readSettingsOutbox(String profileId) =>
      _serialize(() => _readSettingsOutbox(profileId));

  Future<Map<String, dynamic>> _outbox() async {
    final raw = await _storage.read(key: _kSettingsOutbox);
    if (raw == null || raw.isEmpty) return {};
    return Map<String, dynamic>.from(jsonDecode(raw) as Map);
  }

  Future<List<SourceSettingsChange>> _readSettingsOutbox(
    String profileId,
  ) async {
    final profile = (await _outbox())[profileId] as Map?;
    if (profile == null) return [];
    return [
      for (final source in profile.entries)
        for (final entry in (source.value as Map).entries)
          SourceSettingsChange(
            sourceId: source.key as String,
            path: (jsonDecode(entry.key as String) as List).cast<String>(),
            value: (entry.value as Map)['value'],
            version: (entry.value as Map)['version'] as String,
          ),
    ];
  }

  /// Acknowledges only the exact intent sent. A newer edit at the same path
  /// has its own version and survives an older request completing afterwards.
  Future<void> clearSettingsOutbox(
    String profileId,
    List<SourceSettingsChange> sent,
  ) => _serialize(() async {
    final outbox = await _outbox();
    final profile = outbox[profileId] as Map?;
    if (profile == null) return;
    for (final change in sent) {
      final source = profile[change.sourceId] as Map?;
      final key = jsonEncode(change.path);
      if ((source?[key] as Map?)?['version'] == change.version) {
        source!.remove(key);
        if (source.isEmpty) profile.remove(change.sourceId);
      }
    }
    if (profile.isEmpty) outbox.remove(profileId);
    await _storage.write(key: _kSettingsOutbox, value: jsonEncode(outbox));
  });

  Future<void> clearAllSettingsOutbox() =>
      _serialize(() => _storage.delete(key: _kSettingsOutbox));

  Future<void> _queueSettingsChanges(
    SourceConfig previous,
    SourceConfig next,
  ) async {
    // A cached cloud selection remains stored while a local profile is active.
    // Neither that state nor the ownerless profile-switch baseline may enqueue
    // device-local preferences against the last cloud profile.
    final profileId = await _activeCloudProfileId(sourceId: next.id);
    if (profileId == null) return;
    final changes = <({List<String> path, Object? value})>[];
    void diff(Object? oldValue, Object? newValue, List<String> path) {
      if (jsonEncode(oldValue) == jsonEncode(newValue)) {
        return;
      }
      if ((oldValue is Map || oldValue == null) &&
          (newValue is Map || newValue == null) &&
          (oldValue is Map || newValue is Map)) {
        final before = oldValue is Map ? oldValue : const {};
        final after = newValue is Map ? newValue : const {};
        for (final key in {...before.keys, ...after.keys}) {
          diff(before[key], after[key], [...path, key.toString()]);
        }
      } else {
        changes.add((path: path, value: newValue));
      }
    }

    for (final key in syncedSourceSettingKeys) {
      diff(previous.settings[key], next.settings[key], [key]);
    }
    if (changes.isEmpty) return;
    final outbox = await _outbox();
    final profile =
        outbox.putIfAbsent(profileId, () => <String, dynamic>{}) as Map;
    final source =
        profile.putIfAbsent(next.id, () => <String, dynamic>{}) as Map;
    for (final change in changes) {
      // A parent replacement supersedes pending children; a child edit after a
      // pending deletion starts from the current local object instead.
      for (final key in source.keys.toList()) {
        final path = (jsonDecode(key as String) as List).cast<String>();
        if (listEquals(path.take(change.path.length).toList(), change.path) ||
            listEquals(change.path.take(path.length).toList(), path)) {
          source.remove(key);
        }
      }
      source[jsonEncode(change.path)] = {
        'value': change.value,
        'version': newSourceId(),
      };
    }
    await _storage.write(key: _kSettingsOutbox, value: jsonEncode(outbox));
    _settingsChanged.add(null);
  }

  Future<String?> activeId() => _storage.read(key: _kActive);

  Future<void> setActive(String? id) async {
    if (id == null) {
      await _storage.delete(key: _kActive);
    } else {
      await _storage.write(key: _kActive, value: id);
    }
  }

  Future<SourceConfig?> activeConfig() async {
    final id = await activeId();
    final all = await list();
    if (all.isEmpty) return null;
    return all.firstWhere((c) => c.id == id, orElse: () => all.first);
  }

  Future<MetadataConfig> metadataConfig() async {
    final raw = await _storage.read(key: _kMetadata);
    if (raw == null || raw.isEmpty) return const MetadataConfig();
    return MetadataConfig.fromJson(Map<String, dynamic>.from(jsonDecode(raw)));
  }

  Future<void> saveMetadataConfig(
    MetadataConfig config, {
    bool fromCloud = false,
  }) => _serialize(() async {
    if (!fromCloud &&
        jsonEncode((await metadataConfig()).toJson()) !=
            jsonEncode(config.toJson())) {
      final profileId = await _activeCloudProfileId();
      if (profileId != null) {
        final drafts = await _configurationDrafts();
        final profile =
            drafts.putIfAbsent(profileId, () => <String, dynamic>{}) as Map;
        profile['metadata'] = newSourceId();
        await _storage.write(key: _kConfigDrafts, value: jsonEncode(drafts));
      }
    }
    await _storage.write(key: _kMetadata, value: jsonEncode(config.toJson()));
  });

  Future<void> _writeAll(List<SourceConfig> all) => _storage.write(
    key: _kSources,
    value: jsonEncode(all.map((e) => e.toJson()).toList()),
  );
}
