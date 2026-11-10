import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/supporter_access.dart';
import 'package:iptvs/widgets/supporter_gate.dart';

void main() {
  Future<void> open(
    WidgetTester tester,
    _GateAccess access,
    ValueChanged<SupporterGateResult> result,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
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

  testWidgets('free action and cancellation remain distinct', (tester) async {
    SupporterGateResult? result;
    await open(tester, _GateAccess(false), (value) => result = value);
    expect(find.text('Subscription options'), findsNothing);
    expect(
      find.text('Recurring recordings on selected weekdays'),
      findsOneWidget,
    );
    expect(
      find.text('Automatic settings and favorites sync between devices'),
      findsOneWidget,
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
}

class _GateAccess extends SupporterAccess {
  _GateAccess(this.active) : super(configured: false);
  bool active;
  @override
  Future<bool> allows(SupporterFeature feature) async => active;
}
