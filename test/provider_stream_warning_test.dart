import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/provider_stream_gate.dart';
import 'package:iptvs/l10n/app_localizations.dart';
import 'package:iptvs/theme.dart';
import 'package:iptvs/widgets/provider_stream_warning.dart';

void main() {
  tearDown(() => AppLanguageController.instance.preview(AppLanguage.english));

  Future<void> open(
    WidgetTester tester,
    ValueChanged<bool> result, {
    bool native = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async => result(
                await showProviderStreamWarning(
                  context,
                  const ProviderStreamLimitReached(2),
                  native: native,
                ),
              ),
              child: const Text('Open warning'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open warning'));
    await tester.pumpAndSettle();
  }

  testWidgets('Polish warning explains possible effects and permits watching', (
    tester,
  ) async {
    AppLanguageController.instance.preview(AppLanguage.polish);
    bool? accepted;
    await open(tester, (value) => accepted = value);

    expect(find.text('Limit strumieni dostawcy'), findsOneWidget);
    expect(find.textContaining('na tym koncie (2)'), findsOneWidget);
    expect(find.textContaining('mogą być nieaktualne'), findsOneWidget);
    expect(
      find.textContaining('TVBro przyjmuje jeden strumień'),
      findsOneWidget,
    );
    expect(
      find.textContaining('zacinanie obrazu lub brak odtwarzania'),
      findsOneWidget,
    );
    expect(
      find.textContaining('przerwać inny strumień lub nagrywanie'),
      findsOneWidget,
    );
    expect(
      find.textContaining('odmawiać połączeń lub je ograniczać'),
      findsOneWidget,
    );
    expect(accepted, isNull);

    await tester.tap(find.text('Oglądaj dalej'));
    await tester.pumpAndSettle();
    expect(accepted, isTrue);
  });

  testWidgets('Cancel and Back do not permit watching', (tester) async {
    bool? accepted;
    await open(tester, (value) => accepted = value);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(accepted, isFalse);

    accepted = null;
    await tester.tap(find.text('Open warning'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(accepted, isFalse);
  });

  testWidgets(
    'native warning receives the same Polish choice and consequences',
    (tester) async {
      const channel = MethodChannel('iptvs/native_hdr_player');
      MethodCall? request;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        request = call;
        return true;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      AppLanguageController.instance.preview(AppLanguage.polish);
      bool? accepted;
      await open(tester, (value) => accepted = value, native: true);
      expect(request!.method, 'confirmProviderStreamWarning');
      final arguments = request!.arguments as Map;
      expect(arguments['continueLabel'], 'Oglądaj dalej');
      expect(arguments['cancelLabel'], 'Anuluj');
      expect(
        arguments['message'],
        contains('przerwać inny strumień lub nagrywanie'),
      );
      expect(accepted, isTrue);
      expect(find.byType(AlertDialog), findsNothing);
    },
  );

  testWidgets('TV remote can select Watch anyway', (tester) async {
    bool? accepted;
    await open(tester, (value) => accepted = value);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(accepted, isTrue);
  });

  testWidgets('warning remains usable on a short phone viewport', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(640, 320));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    AppLanguageController.instance.preview(AppLanguage.polish);
    bool? accepted;
    await open(tester, (value) => accepted = value);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Oglądaj dalej'));
    await tester.pumpAndSettle();
    expect(accepted, isTrue);
  });
}
