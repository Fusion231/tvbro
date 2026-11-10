import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../sources/source.dart';
import 'diagnostics_log.dart';

typedef RecentlyWatchedEntry = ({
  ContentKind kind,
  String itemId,
  DateTime watchedAt,
});

/// Device-local history, separate from resume points (which discard completed
/// movies). Only identifiers are stored; playback locators stay in the vault.
class RecentlyWatchedStore extends ChangeNotifier {
  static const limit = 20;
  static const _storage = FlutterSecureStorage();
  final Future<String> _scope = _readScope();
  Future<void> _pending = Future.value();
  bool _disposed = false;

  static Future<String> _readScope() async {
    final local = await _storage.read(key: 'active_local_profile_id');
    if (local != null) return 'local:$local';
    if (await _storage.read(key: 'profile_state_ownerless') == '1') {
      return 'ownerless';
    }
    final cloud = await _storage.read(key: 'cloud_profile_id');
    return cloud == null ? 'device' : 'cloud:$cloud';
  }

  Future<String> _key(String sourceId) async =>
      'recently_watched_v1:${jsonEncode([await _scope, sourceId])}';

  Future<List<RecentlyWatchedEntry>> _read(String sourceId) async {
    final raw = await _storage.read(key: await _key(sourceId));
    if (raw == null) return [];
    try {
      return [
        for (final row in jsonDecode(raw) as List)
          (
            kind: ContentKind.values.byName(row['kind'] as String),
            itemId: row['id'] as String,
            watchedAt: DateTime.fromMillisecondsSinceEpoch(row['at'] as int),
          ),
      ];
    } on FormatException {
      return [];
    } on ArgumentError {
      return [];
    } on TypeError {
      return [];
    }
  }

  Future<List<RecentlyWatchedEntry>> read(String sourceId) async {
    await _pending;
    return _read(sourceId);
  }

  void refresh() {
    if (!_disposed) notifyListeners();
  }

  Future<void> record(String sourceId, ContentKind kind, String itemId) {
    final watchedAt = DateTime.now();
    _pending = _pending
        .then((_) async {
          final previous = await _read(sourceId);
          final entries = [
            (kind: kind, itemId: itemId, watchedAt: watchedAt),
            ...previous.where((e) => e.kind != kind || e.itemId != itemId),
          ].take(limit);
          await _storage.write(
            key: await _key(sourceId),
            value: jsonEncode([
              for (final entry in entries)
                {
                  'kind': entry.kind.name,
                  'id': entry.itemId,
                  'at': entry.watchedAt.millisecondsSinceEpoch,
                },
            ]),
          );
          if (!_disposed) notifyListeners();
        })
        .catchError((Object error) {
          DiagnosticsLog.instance.add(
            'history',
            'Could not save recently watched',
          );
        });
    return _pending;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
