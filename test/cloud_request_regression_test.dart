import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/cloud_auto_sync.dart';
import 'package:iptvs/data/cloud_sync.dart';
import 'package:iptvs/data/source_store.dart';
import 'package:iptvs/data/supporter_access.dart';
import 'package:iptvs/screens/cloud_sync_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class AuditSync extends CloudSync {
  AuditSync()
    : super(client: SupabaseClient('https://example.invalid', 'test'));
  int checks = 0;
  int codes = 0;
  int grants = 0;
  bool expired = false;
  bool failChecks = false;
  bool failRenewal = true;
  final pending = <Completer<bool>>[];
  @override
  bool get hasSession => true;
  @override
  String get deviceId => 'audit-device';
  @override
  Future<void> ensureAnonSession() async {}
  @override
  Future<bool> isPaired() async => false;
  @override
  Future<PairingCode> requestPairingCode({String? label}) async {
    codes++;
    if (codes > 1 && failRenewal) throw const SocketException('offline');
    return PairingCode(
      'ABCD2345',
      DateTime.now().add(Duration(minutes: expired ? -1 : 10)),
    );
  }

  @override
  Future<bool> pairingStatus(String code) {
    checks++;
    if (failChecks) return Future.error(const SocketException('offline'));
    final result = Completer<bool>();
    pending.add(result);
    return result.future;
  }

  @override
  Future<SupporterStatus> supporterStatus() async {
    grants++;
    return SupporterStatus(
      supported: true,
      validUntil: DateTime.now().add(const Duration(days: 1)),
    );
  }
}

void main() {
  late Directory directory;
  late AppDatabase db;
  late AuditSync sync;
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    directory = Directory.systemTemp.createTempSync(
      'tvbro_cloud_request_audit_',
    );
    db = await AppDatabase.openAt('${directory.path}/test.db');
    sync = AuditSync();
  });
  tearDown(() async {
    for (final pending in sync.pending) {
      if (!pending.isCompleted) pending.complete(false);
    }
    await db.close();
    directory.deleteSync(recursive: true);
  });
  Future<void> show(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: CloudSyncScreen(
          store: SourceStore(),
          db: db,
          sync: sync,
          onboarding: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('slow pairing has only one in-flight request', (tester) async {
    await show(tester);
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(seconds: 3));
    }
    expect(sync.checks, 1);
    expect(sync.pending.where((p) => !p.isCompleted).length, 1);
    await tester.ensureVisible(find.text('New code'));
    await tester.tap(find.text('New code').hitTestable());
    await tester.pump();
    expect(
      sync.codes,
      1,
      reason: 'manual renewal cannot overlap a status request',
    );
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'pairing errors back off instead of polling every three seconds',
    (tester) async {
      sync.failChecks = true;
      await show(tester);
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(seconds: 3));
      }
      expect(sync.checks, inInclusiveRange(3, 5));
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('failed expired-code renewal schedules a retry', (tester) async {
    sync.expired = true;
    await show(tester);
    await tester.pump(const Duration(seconds: 3));
    expect(sync.codes, 2);
    await tester.pump(const Duration(seconds: 6));
    expect(sync.codes, 3);
    expect(sync.checks, 0);
    sync.failRenewal = false;
    sync.expired = false;
    await tester.pump(const Duration(seconds: 12));
    expect(sync.codes, 4);
    await tester.pump(const Duration(seconds: 3));
    expect(
      sync.checks,
      1,
      reason: 'successful renewal restores status polling',
    );
    await tester.pumpWidget(const SizedBox());
  });
  test('supporter checks share one online result', () async {
    final access = SupporterAccess(sync: sync, configured: true);
    await Future.wait(
      List.generate(
        10,
        (_) => access.allows(SupporterFeature.automaticFavorites),
      ),
    );
    expect(sync.grants, 1);
    await access.allows(SupporterFeature.automaticFavorites);
    expect(sync.grants, 1);
  });
  test('simultaneous full pulls share one operation', () async {
    final changes = StreamController<void>.broadcast();
    final gate = Completer<void>();
    var pulls = 0;
    final automatic = CloudAutoSync(
      changes: changes.stream,
      push: () async => false,
      pull: () async {
        pulls++;
        await gate.future;
      },
    );
    final pending = List.generate(10, (_) => automatic.pullNow());
    gate.complete();
    await Future.wait(pending);
    expect(pulls, 1);
    await automatic.dispose();
    await changes.close();
  });
  test(
    'short resumes reuse a full pull but explicit and later pulls run',
    () async {
      final changes = StreamController<void>.broadcast();
      var now = DateTime.utc(2026, 10, 26);
      var pulls = 0;
      final automatic = CloudAutoSync(
        changes: changes.stream,
        push: () async => false,
        pull: () async {
          pulls++;
        },
        now: () => now,
      );
      await automatic.pullNow();
      for (var i = 0; i < 3; i++) {
        now = now.add(const Duration(seconds: 1));
        await automatic.pullNow(onResume: true);
      }
      expect(pulls, 1);
      await automatic.pullNow();
      expect(pulls, 2);
      now = now.add(const Duration(seconds: 31));
      await automatic.pullNow(onResume: true);
      expect(pulls, 3);
      await automatic.dispose();
      await changes.close();
    },
  );
}
