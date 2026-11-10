import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/cloud_sync.dart';
import 'package:iptvs/data/supporter_access.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  late _AccessSync sync;
  late DateTime now;
  late SupporterAccess access;
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    sync = _AccessSync();
    now = DateTime.utc(2026, 10, 23);
    access = SupporterAccess(sync: sync, configured: true, now: () => now);
    sync.result = SupporterStatus(
      status: 'active',
      supported: true,
      deviceLimit: 10,
      validUntil: now.add(const Duration(days: 1)),
    );
  });

  test('successful access is cached only until exact server expiry', () async {
    expect(await access.allows(SupporterFeature.recurringRecordings), isTrue);
    sync.error = const SocketException('offline');
    now = now.add(const Duration(hours: 23));
    expect(await access.allows(SupporterFeature.automaticFavorites), isTrue);
    now = now.add(const Duration(hours: 1));
    expect(await access.allows(SupporterFeature.vodResume), isFalse);
  });

  test('current server denial clears previously cached grant', () async {
    expect(await access.allows(SupporterFeature.recurringRecordings), isTrue);
    sync.result = SupporterStatus.free;
    expect(await access.allows(SupporterFeature.automaticFavorites), isFalse);
    sync.error = const SocketException('offline');
    expect(await access.allows(SupporterFeature.vodResume), isFalse);
  });

  test('cached access cannot transfer to another device identity', () async {
    expect(await access.allows(SupporterFeature.vodResume), isTrue);
    sync.identity = 'different-device';
    sync.error = const SocketException('offline');
    expect(await access.allows(SupporterFeature.vodResume), isFalse);
  });

  test('auth errors clear cache instead of granting offline access', () async {
    expect(await access.allows(SupporterFeature.vodResume), isTrue);
    sync.error = const PostgrestException(
      message: 'invalid token',
      code: '401',
    );
    expect(await access.allows(SupporterFeature.vodResume), isFalse);
    sync.error = const SocketException('offline');
    expect(await access.allows(SupporterFeature.vodResume), isFalse);
  });

  test('unconfigured build and missing session never call backend or create identity', () async {
    final unavailable = SupporterAccess(sync: sync, configured: false);
    expect(await unavailable.allows(SupporterFeature.vodResume), isFalse);
    sync.session = false;
    expect(await access.allows(SupporterFeature.recurringRecordings), isFalse);
    expect(sync.checks, 0);
    expect(sync.signIns, 0);
  });

  test('verified access survives unavailable offline-cache writes', () async {
    final uncached = SupporterAccess(
      sync: sync,
      configured: true,
      storage: _BrokenWriteStorage(),
      now: () => now,
    );
    expect(await uncached.allows(SupporterFeature.vodResume), isTrue);
    sync.error = const SocketException('offline');
    expect(await uncached.allows(SupporterFeature.vodResume), isFalse);
  });
}

class _BrokenWriteStorage extends FlutterSecureStorage {
  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => throw const FileSystemException('cache unavailable');
}

class _AccessSync extends CloudSync {
  _AccessSync()
    : super(client: SupabaseClient('https://example.invalid', 'test'));
  String identity = 'device';
  bool session = true;
  int checks = 0;
  int signIns = 0;
  Object? error;
  SupporterStatus result = SupporterStatus.free;
  @override
  String? get deviceId => identity;
  @override
  bool get hasSession => session;
  @override
  Future<SupporterStatus> supporterStatus() async {
    checks++;
    if (error case final error?) throw error;
    return result;
  }

  @override
  Future<void> ensureAnonSession() async {
    signIns++;
  }
}
