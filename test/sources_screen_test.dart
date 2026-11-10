// SourcesScreen / EditSourceScreen behaviour.
//
// This is the app's highest-stakes path — every new install goes through it —
// and it had no widget coverage at all. Two regressions are pinned here:
//
//   * **A confirmation dialog must land with something focused.** On a D-pad an
//     unfocused dialog swallows the first OK press entirely: nothing responds,
//     and the user has to blind-hunt with arrows to discover a button exists.
//     Focus goes on the *non*-destructive action, so the reflexive first press
//     cancels rather than deletes.
//   * **The username field is not obscured.** `TvTextField`'s show/hide toggle
//     exists precisely because you cannot spot a typo without a physical
//     keyboard — so defaulting a non-secret field to hidden costs a toggle
//     press per source on the exact input method where verifying text is
//     hardest.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dart:io';

import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/diagnostics_log.dart';
import 'package:iptvs/data/device_class.dart';
import 'package:iptvs/data/expiry_cache.dart';
import 'package:iptvs/data/source_store.dart';
import 'package:iptvs/screens/sources_screen.dart';
import 'package:iptvs/sources/source_config.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/widgets/focusable_card.dart';
import 'package:iptvs/widgets/tv_text_field.dart';

void main() {
  late Directory tempDir;
  late AppDatabase db;

  setUpAll(() async {
    FlutterSecureStorage.setMockInitialValues({});
    tempDir = Directory.systemTemp.createTempSync('iptvs_sources_test');
    db = await AppDatabase.openAt('${tempDir.path}/iptv.db');
  });

  tearDownAll(() async {
    await db.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  SourceConfig xtream(String id) => SourceConfig(
    id: id,
    kind: SourceKind.xtream,
    label: id,
    fields: const {
      'host': 'http://example.test:8080',
      'username': 'someone',
      'password': 'secret',
    },
  );

  // Source layout/actions use a fresh local expiry answer instead of starting
  // provider traffic whose pacing timers can outlive the widget test.
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    for (final id in ['one', 'two']) {
      await const ExpiryCache().write(
        xtream(id),
        const SubscriptionExpiry.unlimited(),
      );
    }
  });

  /// Pumps until the screen's async `_reload` has settled. `pumpAndSettle` is
  /// avoided: the list cards autofocus, and a focus highlight animation can
  /// keep the frame loop busy.
  Future<void> settle(WidgetTester tester, {int frames = 30}) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  Future<void> openSourceOptions(WidgetTester tester, {int index = 0}) async {
    await tester.tap(find.byTooltip('Source options').at(index));
    await settle(tester);
  }

  Future<void> openDiagnostics(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SourcesScreen(store: SourceStore(), db: db),
      ),
    );
    await settle(tester);
    await tester.tap(find.byTooltip('Settings'));
    await settle(tester);
    final diagnostics = find.text('Diagnostics');
    if (diagnostics.evaluate().isEmpty) {
      expect(diagnostics, findsOneWidget);
      return;
    }
    await tester.ensureVisible(diagnostics);
    await settle(tester);
    await tester.tap(diagnostics);
    await settle(tester);
    expect(find.byType(SelectableText), findsOneWidget);
  }

  group('simple sources layout', () {
    testWidgets('shows source essentials and keeps secondary controls hidden', (
      tester,
    ) async {
      final store = SourceStore();
      await store.setAll([xtream('one')]);
      await store.setActive('one');

      await tester.pumpWidget(
        MaterialApp(
          home: SourcesScreen(store: store, db: db),
        ),
      );
      await settle(tester);

      expect(find.text('one'), findsOneWidget);
      expect(find.text('ACTIVE'), findsOneWidget);
      expect(find.text('Add source'), findsOneWidget);
      expect(find.byTooltip('Settings'), findsOneWidget);
      expect(find.byTooltip('Source options'), findsOneWidget);
      for (final label in [
        'Profiles',
        'Cloud sync',
        'Metadata',
        'Privacy & support',
        'Backup & restore',
        'Profile picker at startup',
        'GitHub update track',
        'Check for updates',
        'Move up',
        'Move down',
        'Edit',
        'Delete',
      ]) {
        expect(find.text(label), findsNothing, reason: label);
      }
      expect(find.textContaining('example.test'), findsNothing);
      expect(find.textContaining('EPG supported'), findsNothing);
      expect(find.textContaining('Catch-up'), findsNothing);
      expect(find.textContaining('Resolution'), findsNothing);
    });

    testWidgets('settings keeps advanced controls collapsed but accessible', (
      tester,
    ) async {
      final store = SourceStore();
      await tester.pumpWidget(
        MaterialApp(
          home: SourcesScreen(store: store, db: db),
        ),
      );
      await settle(tester);

      await tester.tap(find.byTooltip('Settings'));
      await settle(tester);

      expect(find.text('Profiles'), findsOneWidget);
      expect(find.text('Backup & restore'), findsOneWidget);
      expect(find.text('Privacy & support'), findsOneWidget);
      expect(find.text('Metadata'), findsNothing);
      expect(find.text('Profile picker at startup'), findsNothing);

      await tester.scrollUntilVisible(
        find.text('Advanced settings'),
        180,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(find.text('Advanced settings'));
      await settle(tester);

      expect(find.text('Metadata'), findsOneWidget);
      expect(find.text('Profile picker at startup'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Diagnostics is reachable from Settings and Back returns', (
      tester,
    ) async {
      await openDiagnostics(tester);
      expect(find.text('Copy'), findsOneWidget);

      await tester.pageBack();
      await settle(tester);
      expect(find.text('Help & updates'), findsOneWidget);
      expect(find.text('Diagnostics'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('diagnostics screen shows and copies the redacted log', (
      tester,
    ) async {
      final log = DiagnosticsLog.instance;
      log.clear();
      addTearDown(log.clear);
      log.add(
        'diagnostics-test',
        'fixture failure at https://fixture-user:fixture-pass@example.invalid/live',
      );
      final clipboardCalls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') clipboardCalls.add(call);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      await openDiagnostics(tester);
      final visibleLog = tester.widget<SelectableText>(
        find.byType(SelectableText),
      );
      expect(visibleLog.data, contains('entries=1'));
      expect(visibleLog.data, isNot(contains('fixture-user')));
      expect(visibleLog.data, isNot(contains('fixture-pass')));

      expect(
        tester
            .widget<FocusableCard>(
              find.ancestor(
                of: find.text('Copy'),
                matching: find.byType(FocusableCard),
              ),
            )
            .autofocus,
        isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(clipboardCalls, hasLength(1));
      final copied =
          Map<String, Object?>.from(
                clipboardCalls.single.arguments as Map,
              )['text']!
              as String;
      expect(copied, contains('entries=1'));
      expect(copied, isNot(contains('fixture-user')));
      expect(copied, isNot(contains('fixture-pass')));
      expect(find.text('Diagnostics copied.'), findsOneWidget);
    });

    testWidgets('clipboard failure reports failure without success', (
      tester,
    ) async {
      final log = DiagnosticsLog.instance;
      log.clear();
      addTearDown(log.clear);
      log.add('diagnostics-test', 'synthetic log entry');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            throw PlatformException(code: 'clipboard_unavailable');
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      await openDiagnostics(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(find.text('Could not copy diagnostics.'), findsOneWidget);
      expect(find.text('Diagnostics copied.'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('diagnostic entries remain scrollable on a short screen', (
      tester,
    ) async {
      final log = DiagnosticsLog.instance;
      log.clear();
      addTearDown(log.clear);
      final filler = List.filled(12, 'line').join(' ');
      for (var i = 0; i < 40; i++) {
        log.add('diagnostics-test', 'synthetic entry $i $filler');
      }

      await openDiagnostics(tester);
      final scrollable = find.byType(Scrollable).first;
      final position = tester.state<ScrollableState>(scrollable).position;
      expect(position.maxScrollExtent, greaterThan(0));
      final before = position.pixels;
      for (var i = 0; i < 12; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
      }
      expect(position.pixels, greaterThan(before));

      await tester.pageBack();
      await settle(tester);
      expect(find.text('Help & updates'), findsOneWidget);
    });

    testWidgets(
      'TV settings opens at the side with autostart ready for the remote',
      (tester) async {
        const deviceChannel = MethodChannel('iptvs/device');
        var autostartEnabled = true;
        debugIsTelevision = true;
        await tester.binding.setSurfaceSize(const Size(1280, 720));
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          deviceChannel,
          (call) async {
            switch (call.method) {
              case 'getBootAutostart':
                return {
                  'enabled': autostartEnabled,
                  'permissionRequired': false,
                };
              case 'setBootAutostart':
                autostartEnabled = call.arguments as bool;
                return null;
              default:
                throw MissingPluginException();
            }
          },
        );
        addTearDown(() async {
          debugIsTelevision = false;
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            deviceChannel,
            null,
          );
          await tester.binding.setSurfaceSize(null);
        });

        await tester.pumpWidget(
          MaterialApp(home: SourcesScreen(store: SourceStore(), db: db)),
        );
        await settle(tester);

        final settingsTrigger = find.text('Settings');
        Focus.of(tester.element(settingsTrigger)).requestFocus();
        await settle(tester);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await settle(tester);

        final autostart = find.text('Start with the TV');
        expect(autostart.hitTestable(), findsOneWidget);
        expect(find.text('Metadata'), findsNothing);
        expect(
          find.ancestor(of: autostart, matching: find.byType(ExpansionTile)),
          findsNothing,
        );
        final panelBounds = tester.getRect(
          find.ancestor(of: autostart, matching: find.byType(Scaffold)),
        );
        expect(panelBounds.right, 1280);
        expect(panelBounds.left, greaterThan(0));

        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await settle(tester);
        expect(autostartEnabled, isFalse);

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await settle(tester);
        final profilesFocus = tester.widget<FocusableActionDetector>(
          find.descendant(
            of: find.widgetWithText(FocusableCard, 'Profiles'),
            matching: find.byType(FocusableActionDetector),
          ),
        );
        expect(profilesFocus.focusNode!.hasFocus, isTrue);

        await tester.binding.handlePopRoute();
        await settle(tester);
        expect(autostart, findsNothing);
        expect(Focus.of(tester.element(settingsTrigger)).hasFocus, isTrue);

        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await settle(tester);
        expect(autostart.hitTestable(), findsOneWidget);
        expect(
          tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
          isFalse,
        );
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets('narrow settings stays readable and scrolls to advanced options', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(360, 740));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(1.3),
            ),
            child: child!,
          ),
          home: SourcesScreen(store: SourceStore(), db: db),
        ),
      );
      await settle(tester);
      await tester.tap(find.byTooltip('Settings'));
      await settle(tester);

      expect(find.text('Profiles').hitTestable(), findsOneWidget);
      expect(find.text('Profiles & data'), findsOneWidget);
      final settingsBounds = tester.getRect(
        find.ancestor(
          of: find.text('Profiles'),
          matching: find.byType(Scaffold),
        ),
      );
      expect(settingsBounds.left, 0);
      expect(settingsBounds.right, 360);
      expect(find.text('Start with the TV'), findsNothing);

      await tester.scrollUntilVisible(
        find.text('Advanced settings'),
        180,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(find.text('Advanced settings'));
      await settle(tester);
      await tester.scrollUntilVisible(
        find.text('Profile picker at startup'),
        180,
        scrollable: find.byType(Scrollable).last,
      );
      await settle(tester);
      expect(find.text('Profile picker at startup').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('single source offers only actions that can be used', (
      tester,
    ) async {
      final store = SourceStore();
      await store.setAll([xtream('one')]);
      await tester.pumpWidget(
        MaterialApp(
          home: SourcesScreen(store: store, db: db),
        ),
      );
      await settle(tester);
      await openSourceOptions(tester);

      expect(find.text('Settings'), findsOneWidget);
      expect(find.text('Edit'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
      expect(find.text('Move up'), findsNothing);
      expect(find.text('Move down'), findsNothing);
    });

    testWidgets(
      'reordering offers the valid direction and preserves selection',
      (tester) async {
        final store = SourceStore();
        await store.setAll([xtream('one'), xtream('two')]);
        await store.setActive('one');
        await tester.pumpWidget(
          MaterialApp(
            home: SourcesScreen(store: store, db: db),
          ),
        );
        await settle(tester);
        await openSourceOptions(tester);

        expect(find.text('Move up'), findsNothing);
        expect(find.text('Move down'), findsOneWidget);
        await tester.tap(find.text('Move down'));
        await settle(tester);
        expect((await store.list()).map((s) => s.id), ['two', 'one']);
        expect(await store.activeId(), 'one');

        await openSourceOptions(tester, index: 1);
        expect(find.text('Move up'), findsOneWidget);
        expect(find.text('Move down'), findsNothing);
        await tester.tap(find.text('Move up'));
        await settle(tester);
        expect((await store.list()).map((s) => s.id), ['one', 'two']);
        expect(await store.activeId(), 'one');
      },
    );

    testWidgets('system Back closes source options and allows reopening', (
      tester,
    ) async {
      final store = SourceStore();
      await store.setAll([xtream('one')]);
      await tester.pumpWidget(
        MaterialApp(
          home: SourcesScreen(store: store, db: db),
        ),
      );
      await settle(tester);
      await openSourceOptions(tester);
      expect(find.text('Edit'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await settle(tester);
      expect(find.text('Edit'), findsNothing);
      expect(find.text('Sources'), findsOneWidget);
      expect(find.text('one'), findsOneWidget);

      await openSourceOptions(tester);
      expect(find.text('Edit'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'remote activates a source and reaches its options with Right',
      (tester) async {
        final store = SourceStore();
        await store.setAll([xtream('one')]);
        await tester.pumpWidget(
          MaterialApp(
            home: SourcesScreen(store: store, db: db),
          ),
        );
        await settle(tester);

        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await settle(tester);
        expect(await store.activeId(), 'one');

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await settle(tester);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await settle(tester);
        expect(find.text('Edit'), findsOneWidget);
        expect(find.text('Delete'), findsOneWidget);
        final settingsItem = find.widgetWithText(MenuItemButton, 'Settings');
        expect(
          Focus.of(tester.element(find.text('Settings'))).hasFocus,
          isTrue,
          reason: 'a remote must land inside the menu when it opens',
        );
        expect(settingsItem, findsOneWidget);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await settle(tester);
        expect(find.text('Edit'), findsNothing);
        expect((await store.list()).single.id, 'one');
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('delete confirmation', () {
    testWidgets('lands focused on Cancel, so the first OK press is safe', (
      tester,
    ) async {
      final store = SourceStore();
      await store.setAll([xtream('one')]);

      await tester.pumpWidget(
        MaterialApp(
          home: SourcesScreen(store: store, db: db),
        ),
      );
      await settle(tester);

      await openSourceOptions(tester);
      await tester.tap(find.text('Delete'));
      await settle(tester);
      expect(find.text('Delete source?'), findsOneWidget);

      // The reflexive first press on a remote. If nothing were focused this
      // would do nothing at all; because Cancel holds focus it dismisses.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);

      expect(
        find.text('Delete source?'),
        findsNothing,
        reason: 'the first OK press must reach a focused action',
      );
      expect((await store.list()).map((s) => s.id), [
        'one',
      ], reason: 'and that action must be the non-destructive one');
    });

    testWidgets('the destructive action still works when chosen', (
      tester,
    ) async {
      final store = SourceStore();
      await store.setAll([xtream('one')]);

      await tester.pumpWidget(
        MaterialApp(
          home: SourcesScreen(store: store, db: db),
        ),
      );
      await settle(tester);

      await openSourceOptions(tester);
      await tester.tap(find.text('Delete'));
      await settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await settle(tester);

      expect(await store.list(), isEmpty);
    });
  });

  group('credential fields', () {
    testWidgets('username is readable; password is masked', (tester) async {
      final store = SourceStore();

      // Editing an existing Xtream source renders that kind's field spec
      // directly — no dropdown choreography, so this stays green regardless of
      // how the Type selector is built.
      await tester.pumpWidget(
        MaterialApp(
          home: EditSourceScreen(store: store, existing: xtream('one')),
        ),
      );
      await settle(tester);

      TvTextField fieldFor(String label) => tester.widget<TvTextField>(
        find.byWidgetPredicate((w) => w is TvTextField && w.label == label),
      );

      expect(
        fieldFor('Username').obscureText,
        isFalse,
        reason:
            'a username is not shoulder-surfing sensitive, and hiding it '
            'makes typos undetectable on a remote',
      );
      expect(fieldFor('Password').obscureText, isTrue);
    });
  });

  group('editing a source preserves fields the form does not render', () {
    testWidgets('an unrendered field survives an unrelated edit', (
      tester,
    ) async {
      // `EditSourceScreen._save` rebuilds `fields` from its own controllers, so
      // a key with no `_FieldSpec` is destroyed by any edit — change the label,
      // press Save, and it is gone. `epgUrls` (extra EPG guides, edited in
      // SourceSettingsScreen) is exactly such a key: it lives in `fields`
      // rather than `settings` because it is credential-bearing and travels to
      // the cloud as a secret.
      final store = SourceStore();
      final existing = xtream('one').copyWith(
        fields: {
          ...xtream('one').fields,
          'epgUrls': 'http://a/g.xml\nhttp://b/g.xml',
        },
      );
      await store.setAll([existing]);

      await tester.pumpWidget(
        MaterialApp(
          home: EditSourceScreen(store: store, existing: existing),
        ),
      );
      await settle(tester);

      await tester.tap(find.text('Save source'));
      await settle(tester);

      final saved = (await store.list()).single;
      expect(saved.extraEpgUrls, ['http://a/g.xml', 'http://b/g.xml']);
      // The rendered fields still come from the form.
      expect(saved.fields['username'], 'someone');
    });
  });
}
