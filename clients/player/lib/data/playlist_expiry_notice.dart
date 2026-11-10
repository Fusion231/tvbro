import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../sources/source.dart';
import '../sources/source_config.dart';
import 'expiry_cache.dart';

const kExpiryReminderDays = [0, 1, 7, 30];

int expiryReminderDays(SourceConfig config) {
  final value = config.settings['expiryReminderDays'];
  return value is int && kExpiryReminderDays.contains(value) ? value : 0;
}

enum PlaylistExpiryNoticeKind { reminder, expired }

PlaylistExpiryNoticeKind? duePlaylistExpiryNotice(
  SubscriptionExpiry expiry, {
  required int reminderDays,
  required DateTime now,
}) {
  final date = expiry.date;
  if (date == null) return null;
  if (!now.isBefore(date)) return PlaylistExpiryNoticeKind.expired;
  if (reminderDays > 0 &&
      !now.isBefore(date.subtract(Duration(days: reminderDays)))) {
    return PlaylistExpiryNoticeKind.reminder;
  }
  return null;
}

/// Acknowledgments belong to this device and account, never the cloud settings.
/// Keeping only the latest expiry per source also makes a renewal eligible again.
class PlaylistExpiryNoticeStore {
  const PlaylistExpiryNoticeStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  String _key(SourceConfig config) => 'playlist_expiry_notice_${config.id}';

  Future<Map<String, dynamic>> _read(SourceConfig config, DateTime date) async {
    final raw = await _storage.read(key: _key(config));
    if (raw == null) return {};
    try {
      final value = jsonDecode(raw);
      if (value is Map<String, dynamic> &&
          value['fingerprint'] == expiryConfigFingerprint(config) &&
          value['date'] == date.toUtc().toIso8601String()) {
        return value;
      }
    } on FormatException {
      // A damaged acknowledgment must not suppress a real expiry notice.
    }
    return {};
  }

  Future<bool> isAcknowledged(
    SourceConfig config,
    DateTime date,
    PlaylistExpiryNoticeKind kind,
  ) async => (await _read(config, date))[kind.name] == true;

  Future<void> acknowledge(
    SourceConfig config,
    DateTime date,
    PlaylistExpiryNoticeKind kind,
  ) async {
    final value = await _read(config, date);
    await _storage.write(
      key: _key(config),
      value: jsonEncode({
        ...value,
        'fingerprint': expiryConfigFingerprint(config),
        'date': date.toUtc().toIso8601String(),
        kind.name: true,
      }),
    );
  }
}
