import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/data/device_class.dart';
import 'package:iptvs/l10n/app_localizations.dart';
import 'package:iptvs/screens/profile_setup_screen.dart';
import 'package:iptvs/widgets/boot_autostart_setting.dart';

void main() {
  const channel = MethodChannel('iptvs/device');
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  var enabled = true;
  var permissionRequired = false;
  var failSave = false;
  var failLoad = false;
  var failSettings = false;
  final calls = <MethodCall>[];

  setUp(() {
    debugIsTelevision = true;
    enabled = true;
    permissionRequired = false;
    failSave = false;
    failLoad = false;
    failSettings = false;
    calls.clear();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      switch (call.method) {
        case 'getBootAutostart':
          if (failLoad) throw PlatformException(code: 'unavailable');
          return {'enabled': enabled, 'permissionRequired': permissionRequired};
        case 'setBootAutostart':
          if (failSave) throw PlatformException(code: 'save_failed');
          enabled = call.arguments as bool;
          return null;
        case 'openBootAutostartPermission':
          if (failSettings) throw PlatformException(code: 'unavailable');
          return true;
        default:
          throw MissingPluginException();
      }
    });
  });

  tearDown(() {
    debugIsTelevision = false;
    AppLanguageController.instance.preview(AppLanguage.english);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  Widget app() =>
      const MaterialApp(home: Scaffold(body: BootAutostartSetting()));

  testWidgets('onboarding shows enabled autostart and remembers disabling it', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProfileSetupChoices(cloudAvailable: false, onChoose: (_) {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isTrue,
    );
    await tester.tap(find.text('Start with the TV'));
    await tester.pumpAndSettle();
    expect(enabled, isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isFalse,
    );
    await tester.tap(find.text('Start with the TV'));
    await tester.pumpAndSettle();
    expect(enabled, isTrue);
  });

  testWidgets('phones and desktop do not show or configure autostart', (
    tester,
  ) async {
    debugIsTelevision = false;
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.byType(SwitchListTile), findsNothing);
    expect(calls, isEmpty);
  });

  testWidgets(
    'non-Android TV does not call Android autostart',
    (tester) async {
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.byType(SwitchListTile), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      expect(calls, isEmpty);
    },
    variant: TargetPlatformVariant({TargetPlatform.linux, TargetPlatform.windows}),
  );

  testWidgets(
    'autostart receives remote focus after a delayed native status response',
    (tester) async {
      final initialStatus = Completer<Map<String, dynamic>>();
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        switch (call.method) {
          case 'getBootAutostart':
            return initialStatus.future;
          case 'setBootAutostart':
            enabled = call.arguments as bool;
            return null;
          default:
            throw MissingPluginException();
        }
      });
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: BootAutostartSetting(autofocus: true)),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).onChanged,
        isNull,
      );

      initialStatus.complete({'enabled': true, 'permissionRequired': false});
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(enabled, isFalse);
      expect(
        calls.where((call) => call.method == 'setBootAutostart'),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets('TV remote can focus and toggle autostart', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProfileSetupChoices(
            cloudAvailable: false,
            onChoose: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(enabled, isFalse);
  });

  testWidgets('failed save preserves the persisted value and offers retry', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    failSave = true;
    await tester.tap(find.text('Start with the TV'));
    await tester.pumpAndSettle();
    expect(enabled, isTrue);
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isTrue,
    );
    expect(
      find.text('Could not save autostart settings. Try again.'),
      findsOneWidget,
    );
    failSave = false;
    await tester.tap(find.text('Start with the TV'));
    await tester.pumpAndSettle();
    expect(enabled, isFalse);
    expect(
      find.text('Could not save autostart settings. Try again.'),
      findsNothing,
    );
  });

  testWidgets('failed load can be retried without changing the preference', (
    tester,
  ) async {
    enabled = false;
    failLoad = true;
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).onChanged,
      isNull,
    );
    failLoad = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isFalse,
    );
    expect(calls.where((call) => call.method == 'setBootAutostart'), isEmpty);
  });

  testWidgets(
    'missing permission displays the consent action only when enabled',
    (tester) async {
      permissionRequired = true;
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      final warning = find.text(
        'Permission required: allow TVBro to display over other apps so autostart can work.',
      );
      expect(warning, findsOneWidget);
      expect(find.text('Allow autostart'), findsOneWidget);
      expect(find.text('Autostart is ready.'), findsNothing);
      await tester.tap(find.text('Start with the TV'));
      await tester.pumpAndSettle();
      expect(warning, findsNothing);
      expect(find.text('Allow autostart'), findsNothing);
    },
  );

  Future<void> openPermission(WidgetTester tester) async {
    await tester.tap(find.text('Allow autostart'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(
      calls.where((call) => call.method == 'openBootAutostartPermission'),
      isEmpty,
    );
    await tester.tap(find.text('Open Android settings'));
    await tester.pumpAndSettle();
  }

  Future<void> returnFromSettings(WidgetTester tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'granting permission updates readiness when returning from Android',
    (tester) async {
      permissionRequired = true;
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await openPermission(tester);
      expect(
        calls.where((call) => call.method == 'openBootAutostartPermission'),
        hasLength(1),
      );
      expect(find.text('Autostart is ready.'), findsNothing);

      permissionRequired = false;
      await returnFromSettings(tester);
      expect(find.text('Autostart is ready.'), findsOneWidget);
      expect(find.text('Allow autostart'), findsNothing);
      expect(enabled, isTrue);
    },
  );

  testWidgets(
    'returning without granting permission keeps the request visible',
    (tester) async {
      permissionRequired = true;
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await openPermission(tester);
      await returnFromSettings(tester);
      expect(find.text('Allow autostart'), findsOneWidget);
      expect(find.text('Autostart is ready.'), findsNothing);
      expect(enabled, isTrue);
    },
  );

  testWidgets('declining consent does not open Android settings', (
    tester,
  ) async {
    permissionRequired = true;
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Allow autostart'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(
      calls.where((call) => call.method == 'openBootAutostartPermission'),
      isEmpty,
    );
    expect(find.text('Allow autostart'), findsOneWidget);
  });

  testWidgets('unavailable system screen shows manual instructions', (
    tester,
  ) async {
    permissionRequired = true;
    failSettings = true;
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await openPermission(tester);
    expect(
      find.text(
        'Open Android settings, then Apps > Special app access > Display over other apps, and allow TVBro.',
      ),
      findsOneWidget,
    );
    expect(find.text('Autostart is ready.'), findsNothing);
  });

  testWidgets(
    'permission revocation and failed refresh never show stale readiness',
    (tester) async {
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(find.text('Autostart is ready.'), findsOneWidget);
      permissionRequired = true;
      failLoad = true;
      await returnFromSettings(tester);
      expect(find.text('Autostart is ready.'), findsNothing);
      failLoad = false;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('Allow autostart'), findsOneWidget);
    },
  );

  testWidgets('consent is reachable and accepted using only the TV remote', (
    tester,
  ) async {
    permissionRequired = true;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProfileSetupChoices(cloudAvailable: false, onChoose: (_) {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(
      calls.where((call) => call.method == 'openBootAutostartPermission'),
      hasLength(1),
    );
  });

  testWidgets('Polish TV onboarding fits a short screen with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(640, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    AppLanguageController.instance.preview(AppLanguage.polish);
    permissionRequired = true;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: ProfileSetupChoices(cloudAvailable: true, onChoose: (_) {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Uruchamiaj razem z telewizorem'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Zezwól na autostart'));
    await tester.tap(find.text('Zezwól na autostart'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Nie teraz'), findsOneWidget);
    expect(find.text('Otwórz ustawienia Androida'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
