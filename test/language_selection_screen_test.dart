import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/source_store.dart';
import 'package:iptvs/l10n/app_localizations.dart';
import 'package:iptvs/main.dart';
import 'package:iptvs/screens/language_selection_screen.dart';
import 'package:iptvs/screens/profile_setup_screen.dart';

void main() {
  final controller = AppLanguageController.instance;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    await controller.initialize();
  });

  tearDown(() => controller.preview(AppLanguage.english));

  Widget languageApp() => ListenableBuilder(
    listenable: controller,
    builder: (context, child) => MaterialApp(
      locale: controller.locale,
      supportedLocales: AppLanguageController.supportedLocales,
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: const LanguageSelectionScreen(),
    ),
  );

  testWidgets('language can be selected and saved with a TV remote', (
    tester,
  ) async {
    await tester.pumpWidget(languageApp());
    await tester.pumpAndSettle();
    expect(find.text('Choose your language'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('Wybierz język'), findsOneWidget);
    expect(controller.hasSelection, isFalse);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(controller.hasSelection, isTrue);
    final restored = AppLanguageController();
    addTearDown(restored.dispose);
    await restored.initialize();
    expect(restored.language, AppLanguage.polish);
    expect(tester.takeException(), isNull);
  });

  testWidgets('app shows language before onboarding and remembers the choice', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync('tvbro_language');
    final db = (await tester.runAsync(
      () => AppDatabase.openAt('${directory.path}/iptv.db'),
    ))!;
    addTearDown(() async {
      await db.close();
      directory.deleteSync(recursive: true);
    });
    await tester.pumpWidget(IptvApp(db: db, store: SourceStore()));
    await tester.pumpAndSettle();
    expect(find.byType(LanguageSelectionScreen), findsOneWidget);
    await tester.tap(find.text('Polski'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dalej'));
    await tester.pumpAndSettle();

    expect(find.byType(LanguageSelectionScreen), findsNothing);
    expect(find.text('Kto ogląda?'), findsOneWidget);
    await tester.tap(find.text('Pomiń'));
    await tester.pumpAndSettle();
    expect(find.text('Witaj w TVBro'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await controller.initialize();
    await tester.pumpWidget(IptvApp(db: db, store: SourceStore()));
    await tester.pumpAndSettle();

    expect(find.byType(LanguageSelectionScreen), findsNothing);
    expect(find.text('Kto ogląda?'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final language in AppLanguage.values) {
    testWidgets('${language.name} onboarding fits a small screen', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      controller.preview(language);
      await tester.pumpWidget(languageApp());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ProfileSetupChoices(profileName: 'Salon', onChoose: (_) {}),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(translate('Set up {name}', language, {'name': 'Salon'})),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
