import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/l10n/app_localizations.dart';
import 'package:iptvs/widgets/media_loading_dialog.dart';

void main() {
  late Completer<String> request;
  String? result;
  Object? error;
  var finished = false;

  setUp(() {
    result = null;
    error = null;
    finished = false;
  });

  Future<void> open(
    WidgetTester tester, {
    bool synchronousFailure = false,
  }) async {
    request = Completer<String>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                try {
                  result = await showMediaLoading(
                    context,
                    message: tr('Loading details…'),
                    load: () {
                      if (synchronousFailure) throw StateError('failed');
                      return request.future;
                    },
                  );
                } catch (failure) {
                  error = failure;
                }
                finished = true;
              },
              child: const Text('Open series'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open series'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
  }

  testWidgets('shows progress until the request completes', (tester) async {
    await open(tester);
    expect(find.text('Loading details…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(finished, isFalse);
    request.complete('series');
    await tester.pumpAndSettle();
    expect(result, 'series');
    expect(finished, isTrue);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Open series'), findsOneWidget);
  });

  testWidgets('failure closes progress and reaches the caller', (tester) async {
    await open(tester);
    request.completeError(StateError('failed'));
    await tester.pumpAndSettle();
    expect(error, isStateError);
    expect(finished, isTrue);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('synchronous failure is handled after the first frame', (
    tester,
  ) async {
    await open(tester, synchronousFailure: true);
    await tester.pumpAndSettle();
    expect(error, isStateError);
    expect(finished, isTrue);
    expect(tester.takeException(), isNull);
  });

  for (final fail in [false, true]) {
    testWidgets('Cancel ignores a late ${fail ? 'error' : 'result'}', (
      tester,
    ) async {
      await open(tester);
      await tester.tap(find.text('Cancel'));
      // Complete during the reverse transition, while the dialog is mounted.
      if (fail) {
        request.completeError(StateError('late failure'));
      } else {
        request.complete('late series');
      }
      await tester.pumpAndSettle();
      expect(result, isNull);
      expect(error, isNull);
      expect(finished, isTrue);
      expect(find.text('Open series'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Back abandons loading and leaves the underlying page', (
    tester,
  ) async {
    await open(tester);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(finished, isTrue);
    expect(result, isNull);
    request.complete('late series');
    await tester.pumpAndSettle();
    expect(find.text('Open series'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a notice above loading does not block completion', (
    tester,
  ) async {
    await open(tester);
    final context = tester.element(find.byType(AlertDialog));
    final navigator = Navigator.of(context);
    unawaited(
      showDialog<void>(
        context: context,
        builder: (_) => const AlertDialog(content: Text('Source notice')),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    request.complete('series');
    await tester.pumpAndSettle();
    expect(result, 'series');
    expect(finished, isTrue);
    expect(find.text('Source notice'), findsOneWidget);
    navigator.pop();
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Open series'), findsOneWidget);
  });

  testWidgets('the loading dialog fits a phone and uses Polish', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final languages = AppLanguageController.instance;
    final original = languages.language;
    addTearDown(() => languages.preview(original));
    languages.preview(AppLanguage.polish);
    await open(tester);
    expect(find.text('Ładowanie szczegółów…'), findsOneWidget);
    expect(find.text('Anuluj').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    request.complete('series');
    await tester.pumpAndSettle();
  });
}
