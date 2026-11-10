import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/expiry_cache.dart';
import 'package:iptvs/data/playlist_expiry_notice.dart';
import 'package:iptvs/l10n/app_localizations.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/source_config.dart';
import 'package:iptvs/widgets/playlist_expiry_notice.dart';

SourceConfig _config({int days = 0}) => SourceConfig(
  id: 'expiry-source',
  kind: SourceKind.xtream,
  label: 'Living room',
  fields: const {
    'host': 'http://provider.example',
    'username': 'account',
    'password': 'secret',
  },
  settings: {if (days > 0) 'expiryReminderDays': days},
);

Future<void> _mount(
  WidgetTester tester, {
  required SourceConfig config,
  required Future<SubscriptionExpiry> Function() load,
  required DateTime Function() now,
  GlobalKey<NavigatorState>? navigatorKey,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigatorKey,
      home: PlaylistExpiryNotice(
        config: config,
        loadExpiry: load,
        now: now,
        child: const Scaffold(body: Text('Library')),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
}

Future<void> _seedStaleExpiry(SourceConfig config, SubscriptionExpiry expiry) =>
    const FlutterSecureStorage().write(
      key: 'source_expiry_cache',
      value: jsonEncode({config.id: CachedExpiry(
        expiry: expiry,
        fetchedAt: DateTime.now().subtract(const Duration(hours: 13)),
        fingerprint: expiryConfigFingerprint(config),
      ).toJson()}),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    AppLanguageController.instance.preview(AppLanguage.english);
  });

  test('reminder settings accept supported day counts only', () {
    for (final days in kExpiryReminderDays) {
      expect(expiryReminderDays(_config(days: days)), days);
    }
    for (final value in ['30', 2, -1, null]) {
      expect(
        expiryReminderDays(
          _config().copyWith(settings: {'expiryReminderDays': value}),
        ),
        0,
      );
    }
  });

  test('notices become due at the reminder and expiry boundaries', () {
    final date = DateTime.utc(2026, 12, 1, 12);
    final expiry = SubscriptionExpiry.dated(date);
    final reminderAt = date.subtract(const Duration(days: 30));
    expect(
      duePlaylistExpiryNotice(
        expiry,
        reminderDays: 30,
        now: reminderAt.subtract(const Duration(microseconds: 1)),
      ),
      isNull,
    );
    expect(
      duePlaylistExpiryNotice(expiry, reminderDays: 30, now: reminderAt),
      PlaylistExpiryNoticeKind.reminder,
    );
    expect(
      duePlaylistExpiryNotice(
        expiry,
        reminderDays: 0,
        now: date.subtract(const Duration(microseconds: 1)),
      ),
      isNull,
    );
    expect(
      duePlaylistExpiryNotice(expiry, reminderDays: 0, now: date),
      PlaylistExpiryNoticeKind.expired,
    );
    for (final undated in const [
      SubscriptionExpiry.unknown(),
      SubscriptionExpiry.unlimited(),
    ]) {
      expect(
        duePlaylistExpiryNotice(undated, reminderDays: 30, now: date),
        isNull,
      );
    }
  });

  test(
    'acknowledgments are scoped to source, account, date and notice kind',
    () async {
      const store = PlaylistExpiryNoticeStore();
      final config = _config(days: 30);
      final date = DateTime.utc(2026, 12, 1);
      await store.acknowledge(config, date, PlaylistExpiryNoticeKind.reminder);

      expect(
        await store.isAcknowledged(
          config.copyWith(label: 'Renamed'),
          date,
          PlaylistExpiryNoticeKind.reminder,
        ),
        isTrue,
      );
      expect(
        await store.isAcknowledged(
          config,
          date,
          PlaylistExpiryNoticeKind.expired,
        ),
        isFalse,
      );
      expect(
        await store.isAcknowledged(
          config.copyWith(id: 'other-source'),
          date,
          PlaylistExpiryNoticeKind.reminder,
        ),
        isFalse,
      );
      expect(
        await store.isAcknowledged(
          config.copyWith(fields: {...config.fields, 'password': 'new-secret'}),
          date,
          PlaylistExpiryNoticeKind.reminder,
        ),
        isFalse,
      );
      expect(
        await store.isAcknowledged(
          config,
          date.add(const Duration(days: 30)),
          PlaylistExpiryNoticeKind.reminder,
        ),
        isFalse,
      );
      await store.acknowledge(config, date, PlaylistExpiryNoticeKind.expired);
      expect(
        await store.isAcknowledged(
          config,
          date,
          PlaylistExpiryNoticeKind.reminder,
        ),
        isTrue,
      );
      expect(
        await store.isAcknowledged(
          config,
          date,
          PlaylistExpiryNoticeKind.expired,
        ),
        isTrue,
      );
    },
  );

  testWidgets(
    'expired popup works with reminders off and only OK acknowledges',
    (tester) async {
      final now = DateTime.now();
      final config = _config();
      final expiry = SubscriptionExpiry.dated(
        now.subtract(const Duration(days: 1)),
      );
      Future<void> mount() => _mount(
        tester,
        config: config,
        load: () async => expiry,
        now: () => now,
      );

      await mount();
      expect(find.text('Playlist expired'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      await _unmount(tester);
      await mount();
      expect(find.text('Playlist expired'), findsOneWidget);
      final focus = FocusManager.instance.primaryFocus;
      expect(focus, isNotNull);
      expect(
        focus!.context!.findAncestorWidgetOfExactType<FilledButton>(),
        isNotNull,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);

      await _unmount(tester);
      await mount();
      expect(find.byType(AlertDialog), findsNothing);
      await _unmount(tester);
    },
  );

  testWidgets('unknown and unlimited subscriptions do not show a popup', (
    tester,
  ) async {
    final now = DateTime.now();
    for (final expiry in const [
      SubscriptionExpiry.unknown(),
      SubscriptionExpiry.unlimited(),
    ]) {
      await _mount(
        tester,
        config: _config(days: 30).copyWith(id: expiry.kind.name),
        load: () async => expiry,
        now: () => now,
      );
      expect(find.byType(AlertDialog), findsNothing);
      await _unmount(tester);
    }
  });

  testWidgets('acknowledging a reminder still permits the expired popup', (
    tester,
  ) async {
    var now = DateTime.now();
    final expires = now.add(const Duration(minutes: 1));
    final config = _config(days: 30);
    await _mount(
      tester,
      config: config,
      load: () async => SubscriptionExpiry.dated(expires),
      now: () => now,
    );
    expect(find.text('Playlist expires soon'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(
      await const PlaylistExpiryNoticeStore().isAcknowledged(
        config,
        expires,
        PlaylistExpiryNoticeKind.reminder,
      ),
      isTrue,
    );

    now = expires;
    await tester.pump(const Duration(minutes: 1));
    await tester.pumpAndSettle();
    expect(find.text('Playlist expired'), findsOneWidget);
    expect(
      await const PlaylistExpiryNoticeStore().isAcknowledged(
        config,
        expires,
        PlaylistExpiryNoticeKind.expired,
      ),
      isFalse,
    );
    await _unmount(tester);
  });

  testWidgets('an unknown provider answer retains the cached expired date', (
    tester,
  ) async {
    final now = DateTime.now();
    final expires = now.subtract(const Duration(days: 1));
    final config = _config();
    await _seedStaleExpiry(config, SubscriptionExpiry.dated(expires));
    var loads = 0;
    await _mount(
      tester,
      config: config,
      load: () async {
        loads++;
        return const SubscriptionExpiry.unknown();
      },
      now: () => now,
    );

    expect(loads, 1);
    expect(find.text('Playlist expired'), findsOneWidget);
    expect((await const ExpiryCache().readAny(config))!.expiry.date, expires);
    await _unmount(tester);
  });

  testWidgets('a provider renewal replaces a stale expired cached date', (
    tester,
  ) async {
    final now = DateTime.now();
    final config = _config();
    final renewed = now.add(const Duration(days: 60));
    await _seedStaleExpiry(
      config,
      SubscriptionExpiry.dated(now.subtract(const Duration(days: 1))),
    );
    var loads = 0;
    await _mount(
      tester,
      config: config,
      load: () async {
        loads++;
        return SubscriptionExpiry.dated(renewed);
      },
      now: () => now,
    );

    expect(loads, 1);
    expect(find.byType(AlertDialog), findsNothing);
    expect((await const ExpiryCache().readAny(config))!.expiry.date, renewed);
    await _unmount(tester);
  });

  testWidgets('expiry deadline fires while the library remains open', (
    tester,
  ) async {
    var now = DateTime.now();
    final expires = now.add(const Duration(minutes: 1));
    var loads = 0;
    await _mount(
      tester,
      config: _config(),
      load: () async {
        loads++;
        return SubscriptionExpiry.dated(expires);
      },
      now: () => now,
    );
    expect(find.byType(AlertDialog), findsNothing);

    now = expires;
    await tester.pump(const Duration(minutes: 1));
    await tester.pumpAndSettle();
    expect(find.text('Playlist expired'), findsOneWidget);
    expect(loads, 1, reason: 'the local deadline does not need an account request');
    await tester.pump(const Duration(seconds: 5));
    expect(loads, 1, reason: 'an expired cache must not cause a timer loop');
    await _unmount(tester);
  });

  testWidgets('a notice waits for a covering route to close', (tester) async {
    final now = DateTime.now();
    final navigator = GlobalKey<NavigatorState>();
    final result = Completer<SubscriptionExpiry>();
    await _mount(
      tester,
      config: _config(),
      load: () => result.future,
      now: () => now,
      navigatorKey: navigator,
    );
    unawaited(
      navigator.currentState!.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Settings route')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    result.complete(
      SubscriptionExpiry.dated(now.subtract(const Duration(days: 1))),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);

    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('Playlist expired'), findsOneWidget);
    await _unmount(tester);
  });

  testWidgets(
    'an old account response cannot notify or overwrite its replacement',
    (tester) async {
      final now = DateTime.now();
      final first = _config();
      final second = first.copyWith(
        fields: {...first.fields, 'password': 'replacement-account'},
      );
      final oldResult = Completer<SubscriptionExpiry>();
      await _mount(
        tester,
        config: first,
        load: () => oldResult.future,
        now: () => now,
      );
      await _mount(
        tester,
        config: second,
        load: () async => const SubscriptionExpiry.unlimited(),
        now: () => now,
      );
      oldResult.complete(
        SubscriptionExpiry.dated(now.subtract(const Duration(days: 1))),
      );
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(await const ExpiryCache().readAny(first), isNull);
      expect(
        (await const ExpiryCache().readAny(second))!.expiry.kind,
        SubscriptionExpiryKind.unlimited,
      );
      await _unmount(tester);
    },
  );

  testWidgets('resuming after the expiry deadline shows the notice', (
    tester,
  ) async {
    var now = DateTime.now();
    final expires = now.add(const Duration(hours: 1));
    await _mount(
      tester,
      config: _config(),
      load: () async => SubscriptionExpiry.dated(expires),
      now: () => now,
    );
    expect(find.byType(AlertDialog), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    now = expires.add(const Duration(minutes: 1));
    await tester.pump(const Duration(hours: 2));
    expect(find.byType(AlertDialog), findsNothing);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('Playlist expired'), findsOneWidget);
    await _unmount(tester);
  });
}
