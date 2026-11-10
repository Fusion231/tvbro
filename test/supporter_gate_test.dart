import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/cloud_config.dart';
import 'package:iptvs/data/distribution_channel.dart';
import 'package:iptvs/data/supporter_access.dart';
import 'package:iptvs/l10n/app_language.dart';
import 'package:iptvs/theme.dart';
import 'package:iptvs/widgets/supporter_gate.dart';

void main() {
  final consumptionOnly = DistributionConfig.channel.isConsumptionOnly;

  setUpAll(() async {
    final loader = FontLoader('Inter');
    for (final name in [
      'inter_regular.ttf',
      'inter_semibold.ttf',
      'inter_bold.ttf',
    ]) {
      final bytes = await File('android/app/src/main/res/font/$name')
          .readAsBytes();
      loader.addFont(Future.value(bytes.buffer.asByteData()));
    }
    await loader.load();
  });

  Future<void> open(
    WidgetTester tester,
    _GateAccess access,
    ValueChanged<SupporterGateResult> result,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async => result(
                await requireSupporterFeature(
                  context,
                  SupporterFeature.vodResume,
                  access: access,
                  freeActionLabel: 'Watch from beginning',
                ),
              ),
              child: const Text('Resume'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Resume'));
    await tester.pumpAndSettle();
  }

  testWidgets('paid access proceeds without a paywall', (tester) async {
    SupporterGateResult? result;
    await open(tester, _GateAccess(true), (value) => result = value);
    expect(result, SupporterGateResult.allowed);
    expect(find.byType(AlertDialog), findsNothing);
  });

  if (consumptionOnly) {
    testWidgets(
      'store builds keep existing access and free playback without web sales',
      (tester) async {
        SupporterGateResult? result;
        await open(
          tester,
          _GateAccess(false, configured: true),
          (value) => result = value,
        );
        expect(find.text('5 devices · PLN 24.99/year'), findsNothing);
        expect(find.text('Plus applicable tax'), findsNothing);
        expect(find.text('Open panel'), findsNothing);
        expect(
          find.text(
            'This feature requires existing Supporter access. Pair your account and assign an existing place to this device, then refresh access.',
          ),
          findsOneWidget,
        );
        expect(find.text('Refresh access'), findsOneWidget);
        expect(find.text('Manage existing access'), findsOneWidget);
        await tester.tap(find.text('Watch from beginning'));
        await tester.pumpAndSettle();
        expect(result, SupporterGateResult.free);
      },
    );
  } else {
    testWidgets('other channels retain the configured web purchase entry', (
      tester,
    ) async {
      await open(tester, _GateAccess(false, configured: true), (_) {});
      expect(find.text('5 devices · PLN 24.99/year'), findsOneWidget);
      expect(find.text('Open panel'), findsOneWidget);
    });
  }

  testWidgets('free action and cancellation remain distinct', (tester) async {
    SupporterGateResult? result;
    await open(tester, _GateAccess(false), (value) => result = value);
    expect(find.text('Open panel'), findsNothing);
    expect(
      find.text('Recurring recordings'),
      consumptionOnly ? findsNothing : findsOneWidget,
    );
    expect(
      find.text('Settings and favorites sync'),
      consumptionOnly ? findsNothing : findsOneWidget,
    );
    await tester.tap(find.text('Watch from beginning'));
    await tester.pumpAndSettle();
    expect(result, SupporterGateResult.free);
    await tester.tap(find.text('Resume'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(result, SupporterGateResult.cancelled);
  });

  testWidgets('account actions respect the distribution purchase policy', (
    tester,
  ) async {
    const channel = MethodChannel('plugins.flutter.io/url_launcher');
    Uri? opened;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'launch') {
        opened = Uri.parse((call.arguments as Map)['url'] as String);
      }
      return true;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    await open(tester, _GateAccess(false, configured: true), (_) {});
    expect(
      find.text('5 devices · PLN 24.99/year'),
      consumptionOnly ? findsNothing : findsOneWidget,
    );
    expect(
      find.text('Plus applicable tax'),
      consumptionOnly ? findsNothing : findsOneWidget,
    );
    expect(
      find.textContaining('This feature requires existing Supporter access.'),
      consumptionOnly ? findsOneWidget : findsNothing,
    );
    await tester.tap(
      find.text(consumptionOnly ? 'Manage existing access' : 'Open panel'),
    );
    await tester.pumpAndSettle();
    expect(opened?.origin, Uri.parse(CloudConfig.panelUrl).origin);
    expect(
      opened?.queryParameters['billing'],
      consumptionOnly ? isNull : 'plans',
    );
    if (consumptionOnly) {
      expect(opened, Uri.parse(CloudConfig.accountPanelUrl));
      expect(opened?.queryParameters['channel'], 'googlePlay');
    }
  });

  testWidgets(
    'refresh returns to the selected feature when access becomes active',
    (tester) async {
      final access = _GateAccess(false);
      SupporterGateResult? result;
      await open(tester, access, (value) => result = value);
      access.active = true;
      await tester.tap(find.text('Refresh access'));
      await tester.pumpAndSettle();
      expect(result, SupporterGateResult.allowed);
    },
  );

  testWidgets('refresh distinguishes a server failure from unassigned access', (
    tester,
  ) async {
    final access = _GateAccess(false);
    await open(tester, access, (_) {});
    access.error = const SocketException('offline');
    await tester.tap(find.text('Refresh access'));
    await tester.pumpAndSettle();
    expect(
      find.text('Could not check access. Check your connection and try again.'),
      findsOneWidget,
    );
    expect(
      find.text(
        consumptionOnly
            ? 'Assign an existing Supporter place to this device in the panel, then refresh access.'
            : 'Enable Supporter for this device in the panel under Devices.',
      ),
      findsNothing,
    );
    access.error = null;
    await tester.tap(find.text('Refresh access'));
    await tester.pumpAndSettle();
    expect(
      find.text('Could not check access. Check your connection and try again.'),
      findsNothing,
    );
    expect(
      find.text(
        consumptionOnly
            ? 'Assign an existing Supporter place to this device in the panel, then refresh access.'
            : 'Enable Supporter for this device in the panel under Devices.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('remote can refresh, retry after failure and continue free', (
    tester,
  ) async {
    final access = _GateAccess(false);
    SupporterGateResult? result;
    await open(tester, access, (value) => result = value);
    access.pending = Completer<bool>();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    access.pending!.completeError(const SocketException('offline'));
    await tester.pumpAndSettle();
    expect(access.refreshes, 1);
    access.pending = null;
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(access.refreshes, 2);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(result, SupporterGateResult.free);
  });

  testWidgets('refresh stays single-flight and can finish after closing', (
    tester,
  ) async {
    final access = _GateAccess(false)..pending = Completer<bool>();
    SupporterGateResult? result;
    await open(tester, access, (value) => result = value);
    await tester.tap(find.text('Refresh access'));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(access.refreshes, 1);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(result, SupporterGateResult.cancelled);
    access.pending!.complete(true);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(result, SupporterGateResult.cancelled);
  });

  testWidgets('Polish dialog fits TV and compact screens with enlarged text', (
    tester,
  ) async {
    final language = AppLanguageController.instance.language;
    AppLanguageController.instance.preview(AppLanguage.polish);
    addTearDown(() => AppLanguageController.instance.preview(language));
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    tester.view.devicePixelRatio = 1;
    for (final size in [
      const Size(960, 540),
      const Size(640, 360),
      const Size(360, 640),
    ]) {
      tester.view.physicalSize = size;
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      await open(tester, _GateAccess(false, configured: true), (_) {});
      await tester.tap(find.text('Odśwież dostęp'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        find.text(
          consumptionOnly ? 'Zarządzaj posiadanym dostępem' : 'Otwórz panel',
        ),
        findsOneWidget,
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
    }
  });
}

class _GateAccess extends SupporterAccess {
  _GateAccess(this.active, {bool configured = false})
    : super(configured: configured);
  bool active;
  Object? error;
  int refreshes = 0;
  Completer<bool>? pending;
  @override
  Future<bool> allows(SupporterFeature feature) async => active;

  @override
  Future<bool> refresh(SupporterFeature feature) async {
    refreshes++;
    if (error case final error?) throw error;
    return pending == null ? active : await pending!.future;
  }
}
