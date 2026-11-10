import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'cloud_config.dart';
import 'cloud_sync.dart';

enum SupporterFeature { recurringRecordings, automaticFavorites, vodResume }

/// Device-bound, server-issued access. Basic player operations do not call it.
class SupporterAccess {
  SupporterAccess({
    CloudSync? sync,
    FlutterSecureStorage? storage,
    bool? configured,
    DateTime Function()? now,
    // Public injection names remain independent of the private backing fields.
    // ignore: prefer_initializing_formals
  }) : _sync = sync,
       _storage = storage ?? const FlutterSecureStorage(),
       // ignore: prefer_initializing_formals
       _configured = configured,
       _now = now ?? DateTime.now;

  static final instance = SupporterAccess();
  final CloudSync? _sync;
  final FlutterSecureStorage _storage;
  final bool? _configured;
  final DateTime Function() _now;
  final Set<String> _deniedDevices = {};

  bool get isConfigured => _configured ?? CloudConfig.isConfigured;

  Future<bool> allows(SupporterFeature feature) async =>
      (await status()).isActiveAt(_now());

  Future<SupporterStatus> status() async {
    if (!isConfigured) return SupporterStatus.free;
    final sync = _sync ?? CloudSync();
    final device = sync.deviceId;
    if (!sync.hasSession || device == null) return SupporterStatus.free;
    final key = 'supporter_access_$device';
    try {
      final current = await sync.supporterStatus().timeout(
        const Duration(seconds: 8),
      );
      if (!sync.hasSession || sync.deviceId != device) {
        return SupporterStatus.free;
      }
      if (current.isActiveAt(_now())) {
        _deniedDevices.remove(device);
        try {
          await _storage.write(
            key: key,
            value: jsonEncode({
              'device_id': device,
              'status': current.status,
              'supported': current.supported,
              'device_limit': current.deviceLimit,
              'valid_until': current.validUntil!.toUtc().toIso8601String(),
            }),
          );
        } catch (_) {
          // A verified server grant does not require a working offline cache.
        }
        return sync.hasSession && sync.deviceId == device
            ? current
            : SupporterStatus.free;
      }
      _deniedDevices.add(device);
      await _clear(key);
      return SupporterStatus.free;
    } catch (error) {
      if (!sync.hasSession || sync.deviceId != device) {
        return SupporterStatus.free;
      }
      if (error is! SocketException &&
          error is! HttpException &&
          error is! TimeoutException) {
        _deniedDevices.add(device);
        await _clear(key);
        return SupporterStatus.free;
      }
      if (_deniedDevices.contains(device)) return SupporterStatus.free;
      try {
        final value = jsonDecode(await _storage.read(key: key) ?? 'null');
        if (value is! Map || value['device_id'] != device) {
          return SupporterStatus.free;
        }
        final cached = SupporterStatus.fromJson(
          Map<String, dynamic>.from(value),
        );
        if (cached.isActiveAt(_now()) &&
            sync.hasSession &&
            sync.deviceId == device) {
          return cached;
        }
      } catch (_) {
        // An unreadable cache cannot grant access.
      }
      await _clear(key);
      return SupporterStatus.free;
    }
  }

  Future<void> _clear(String key) async {
    try {
      await _storage.delete(key: key);
    } catch (_) {
      // Explicit denial is also retained in memory when storage is unavailable.
    }
  }
}
