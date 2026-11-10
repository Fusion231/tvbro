import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/playlist_expiry_notice.dart';
import 'package:iptvs/data/source_store.dart';
import 'package:iptvs/screens/source_settings_screen.dart';
import 'package:iptvs/sources/source_config.dart';
import 'package:iptvs/widgets/focusable_card.dart';

const _profileId = '00000000-0000-4000-8000-000000000002';
const _config = SourceConfig(
  id: '00000000-0000-4000-8000-000000000001',
  kind: SourceKind.m3u,
  label: 'Provider',
  fields: {'playlistUrl': 'http://example.test/list.m3u'},
  settings: {'bufferPreset': 'low', 'hardwareChoice': true},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late AppDatabase db;
  late SourceStore store;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('tvbro_expiry_settings');
    db = await AppDatabase.openAt('${tempDir.path}/iptv.db');
    store = SourceStore();
  });

  tearDown(() async {
    await db.close();
    await tempDir.delete(recursive: true);
  });

  Future<void> mount(WidgetTester tester, SourceConfig initial) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 3000);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      await db.replaceLibrary(initial.id, 'Provider', const [], const []);
      await store.setAll([initial]);
      await tester.pumpWidget(
        MaterialApp(
          home: SourceSettingsScreen(store: store, db: db, config: initial),
        ),
      );
      // Category reads started by initState need real database I/O to finish.
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
  }

  Finder reminderText(String value) => find.text('Expiry reminder: $value');

  Future<void> tapReminder(WidgetTester tester, String value) async {
    await tester.runAsync(() async {
      await tester.tap(reminderText(value));
      // This serialized operation waits for the setting save to finish.
      await store.readSettingsOutbox(_profileId);
    });
    await tester.pump();
  }

  testWidgets('cycles all reminder choices and preserves unrelated settings', (
    tester,
  ) async {
    await mount(tester, _config);
    expect(reminderText('Off'), findsOneWidget);

    for (final choice in [
      (before: 'Off', after: '1 day before', days: 1),
      (before: '1 day before', after: '1 week before', days: 7),
      (before: '1 week before', after: '1 month (30 days) before', days: 30),
      (before: '1 month (30 days) before', after: 'Off', days: 0),
    ]) {
      await tapReminder(tester, choice.before);
      expect(reminderText(choice.after), findsOneWidget);
      final saved = (await SourceStore().list()).single;
      expect(expiryReminderDays(saved), choice.days);
      expect(saved.settings, {
        ..._config.settings,
        if (choice.days != 0) 'expiryReminderDays': choice.days,
      });
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'stored reminder is displayed and Enter activates its focus target',
    (tester) async {
      await mount(
        tester,
        _config.copyWith(
          settings: {..._config.settings, 'expiryReminderDays': 7},
        ),
      );
      final card = find.ancestor(
        of: reminderText('1 week before'),
        matching: find.byType(FocusableCard),
      );
      expect(card, findsOneWidget);
      final detector = find.descendant(
        of: card,
        matching: find.byType(FocusableActionDetector),
      );
      tester
          .widget<FocusableActionDetector>(detector)
          .focusNode!
          .requestFocus();
      await tester.pump();
      expect(
        tester.widget<FocusableActionDetector>(detector).focusNode!.hasFocus,
        isTrue,
      );

      await tester.runAsync(() async {
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await store.readSettingsOutbox(_profileId);
      });
      await tester.pump();

      expect(reminderText('1 month (30 days) before'), findsOneWidget);
      expect(expiryReminderDays((await SourceStore().list()).single), 30);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'reminder changes and removal join the automatic settings outbox',
    () async {
      const storage = FlutterSecureStorage();
      await storage.write(key: 'cloud_profile_id', value: _profileId);
      await storage.write(key: 'cloud_source_ids', value: _config.id);
      await store.setAll([_config]);
      final enabled = _config.copyWith(
        settings: {..._config.settings, 'expiryReminderDays': 30},
      );
      await store.save(enabled);

      final reopened = SourceStore();
      final queued = await reopened.readSettingsOutbox(_profileId);
      expect(queued, hasLength(1));
      expect(queued.single.sourceId, _config.id);
      expect(queued.single.path, ['expiryReminderDays']);
      expect(queued.single.value, 30);
      await reopened.applyCloudSources([
        _config.copyWith(
          settings: {..._config.settings, 'expiryReminderDays': 1},
        ),
      ], _profileId);
      expect(expiryReminderDays((await reopened.list()).single), 30);

      await reopened.clearSettingsOutbox(_profileId, queued);
      await reopened.save(_config);
      final removed = await reopened.readSettingsOutbox(_profileId);
      expect(removed, hasLength(1));
      expect(removed.single.path, ['expiryReminderDays']);
      expect(removed.single.value, isNull);
      expect((await SourceStore().list()).single.settings, _config.settings);
    },
  );
}
