import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../sources/demo_source.dart';
import '../sources/m3u_source.dart';
import '../sources/source.dart';
import '../sources/source_config.dart';
import '../sources/stalker_source.dart';
import '../sources/xtream_source.dart';
import 'app_database.dart';

/// Opaque identity of the settings that determine a source's imported data.
/// Labels and local settings do not affect the provider catalog.
String sourceCacheIdentityForConfig(SourceConfig config) =>
    _sourceCacheIdentity(config.kind.name, _configCacheFields(config));

/// The same identity from a built-in source, so an old repository cannot write
/// data after the saved config has changed under the same public source id.
String? sourceCacheIdentityForSource(Source source) => switch (source) {
  M3uSource source => _sourceCacheIdentity('m3u', {
    'playlistUrl': source.playlistUrl,
    'epgUrl': ?source.epgUrl,
    'userAgent': ?source.userAgent,
    if (source.extraEpgUrls.isNotEmpty)
      'epgUrls': source.extraEpgUrls.join('\n'),
  }),
  XtreamSource source => _sourceCacheIdentity('xtream', {
    'host': source.host,
    'username': source.username,
    'password': source.password,
    'playlistExpiryHint': ?source.playlistExpiryHint,
    if (source.extraEpgUrls.isNotEmpty)
      'epgUrls': source.extraEpgUrls.join('\n'),
  }),
  StalkerSource source => _sourceCacheIdentity('stalker', {
    'portal': source.portal,
    'mac': source.mac,
    if (source.extraEpgUrls.isNotEmpty)
      'epgUrls': source.extraEpgUrls.join('\n'),
  }),
  DemoSource _ => _sourceCacheIdentity('demo', const {}),
  _ => null,
};

Map<String, String> _configCacheFields(SourceConfig config) =>
    switch (config.kind) {
      SourceKind.m3u => {
        'playlistUrl': config.fields['playlistUrl'] ?? '',
        if (config.fields['epgUrl']?.isNotEmpty == true)
          'epgUrl': config.fields['epgUrl']!,
        if (config.fields['userAgent']?.isNotEmpty == true)
          'userAgent': config.fields['userAgent']!,
        if (config.extraEpgUrls.isNotEmpty)
          'epgUrls': config.extraEpgUrls.join('\n'),
      },
      SourceKind.xtream => {
        'host': config.fields['host'] ?? '',
        'username': config.fields['username'] ?? '',
        'password': config.fields['password'] ?? '',
        if (config.fields.containsKey('playlistExpiryHint'))
          'playlistExpiryHint': config.fields['playlistExpiryHint']!,
        if (config.extraEpgUrls.isNotEmpty)
          'epgUrls': config.extraEpgUrls.join('\n'),
      },
      SourceKind.stalker => {
        'portal': config.fields['portal'] ?? '',
        'mac': config.fields['mac'] ?? '',
        if (config.extraEpgUrls.isNotEmpty)
          'epgUrls': config.extraEpgUrls.join('\n'),
      },
      SourceKind.demo => const {},
    };

String _sourceCacheIdentity(String kind, Map<String, String> fields) {
  final keys = fields.keys.toList()..sort();
  final material = [
    kind,
    for (final key in keys) ...[key, fields[key]!],
  ];
  return sha256.convert(utf8.encode(jsonEncode(material))).toString();
}

/// Moves pre-PR4 cache/user-state keys to the stable source and channel
/// identities before a [Source] can publish rows under those identities.
Future<void> migrateSourceIdentity(AppDatabase db, SourceConfig config) async {
  await db.migrateSourceNamespace(config.legacyCacheId, config.id);
  if (config.kind == SourceKind.m3u) {
    await db.migrateM3uChannelIds(config.id);
  }
  await db.migrateSourceCacheIdentity(
    config.id,
    config.label.trim().isEmpty ? config.id : config.label.trim(),
    sourceCacheIdentityForConfig(config),
  );
}

Future<void> migrateAllSourceIdentities(
  AppDatabase db,
  Iterable<SourceConfig> configs,
) async {
  for (final config in configs) {
    await migrateSourceIdentity(db, config);
  }
}
