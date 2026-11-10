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
  String? _onlineDevice;
  SupporterStatus? _onlineValue;
  Object? _onlineError;
  DateTime? _onlineUntil;
  Future<SupporterStatus>? _onlinePending;

  bool get isConfigured => _configured ?? CloudConfig.isConfigured;

  Future<bool> allows(SupporterFeature feature) async =>
      (await status()).isActiveAt(_now());

  /// Explicit refresh reports failures instead of presenting them as no access.
  Future<bool> refresh(SupporterFeature feature) async =>
      (await status(reportErrors: true)).isActiveAt(_now());

  Future<SupporterStatus> status({bool reportErrors = false}) async {
    if (!isConfigured) return SupporterStatus.free;
    final sync = _sync ?? CloudSync();
    final device = sync.deviceId;
    if (!sync.hasSession || device == null) {
      _resetOnline(null);
      return SupporterStatus.free;
    }
    final key = 'supporter_access_$device';
    try {
      final current = await _readOnline(sync, device, force: reportErrors);
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
        if (reportErrors) rethrow;
        return SupporterStatus.free;
      }
      if (reportErrors) rethrow;
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

  void _resetOnline(String? device) {
    _onlineDevice = device;
    _onlineValue = null;
    _onlineError = null;
    _onlineUntil = null;
    _onlinePending = null;
  }

  Future<SupporterStatus> _readOnline(
    CloudSync sync,
    String device, {
    required bool force,
  }) {
    if (_onlineDevice != device) _resetOnline(device);
    final pending = _onlinePending;
    if (pending != null) return pending;
    if (!force && _onlineUntil != null && _now().isBefore(_onlineUntil!)) {
      if (_onlineError case final error?) return Future.error(error);
      return Future.value(_onlineValue ?? SupporterStatus.free);
    }
    late final Future<SupporterStatus> operation;
    operation = sync.supporterStatus().timeout(const Duration(seconds: 8)).then(
      (value) {
        if (identical(_onlinePending, operation)) {
          _onlineValue = value;
          _onlineError = null;
          _onlineUntil = _now().add(const Duration(seconds: 60));
        }
        return value;
      },
      onError: (Object error, StackTrace stack) {
        if (identical(_onlinePending, operation)) {
          _onlineValue = null;
          _onlineError = error;
          _onlineUntil = _now().add(const Duration(seconds: 15));
        }
        Error.throwWithStackTrace(error, stack);
      },
    ).whenComplete(() {
      if (identical(_onlinePending, operation)) _onlinePending = null;
    });
    return _onlinePending = operation;
  }

  Future<void> _clear(String key) async {
    try {
      await _storage.delete(key: key);
    } catch (_) {
      // Explicit denial is also retained in memory when storage is unavailable.
    }
  }
}
