import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';

import 'package:iptvs/l10n/app_localizations.dart';
import 'package:iptvs/data/net.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('first launch uses English and requires a language choice', () async {
    final controller = AppLanguageController();
    addTearDown(controller.dispose);
    await controller.initialize(deviceLocales: const [Locale('xx')]);

    expect(controller.language, AppLanguage.english);
    expect(controller.hasSelection, isFalse);
  });

  for (final language in AppLanguage.values) {
    test('${language.name} is restored after restarting the app', () async {
      final controller = AppLanguageController();
      addTearDown(controller.dispose);
      await controller.initialize();
      controller.preview(language);
      expect(controller.hasSelection, isFalse);
      await controller.confirm();

      final restored = AppLanguageController();
      addTearDown(restored.dispose);
      await restored.initialize();

      expect(restored.language, language);
      expect(restored.locale, language.locale);
      expect(restored.hasSelection, isTrue);
    });
  }

  test('unsupported saved language requires a new choice', () async {
    FlutterSecureStorage.setMockInitialValues({
      AppLanguageController.storageKey: 'xx',
    });
    final controller = AppLanguageController();
    addTearDown(controller.dispose);
    await controller.initialize(deviceLocales: const [Locale('xx')]);

    expect(controller.language, AppLanguage.english);
    expect(controller.hasSelection, isFalse);
  });

  test('first launch suggests the first supported device language', () async {
    final controller = AppLanguageController();
    addTearDown(controller.dispose);
    await controller.initialize(
      deviceLocales: const [Locale('xx'), Locale('pt', 'BR')],
    );
    expect(controller.language, AppLanguage.brazilianPortuguese);
    expect(controller.deviceLanguage, AppLanguage.brazilianPortuguese);
    expect(controller.hasSelection, isFalse);
    await controller.confirm(AppLanguage.arabic);
    await controller.initialize(deviceLocales: const [Locale('zh', 'CN')]);
    expect(controller.language, AppLanguage.arabic);
    expect(controller.deviceLanguage, AppLanguage.simplifiedChinese);
  });

  test('Polish translations preserve content template parameters', () {
    Set<String> parameters(String message) =>
        RegExp(r'\{(\w+)\}')
            .allMatches(message)
            .map((match) => match[1]!)
            .toSet();

    for (final entry in polishMessages.entries) {
      expect(entry.value.trim(), isNotEmpty, reason: entry.key);
      expect(
        parameters(entry.value)..remove('suffix'),
        parameters(entry.key)..remove('suffix'),
        reason: entry.key,
      );
    }
    expect(
      translate('Set up {name}', AppLanguage.polish, {'name': 'Salon'}),
      'Skonfiguruj profil Salon',
    );
    expect(
      translate('Set up {name}', AppLanguage.english, {'name': 'Living room'}),
      'Set up Living room',
    );
    expect(translate('Provider title', AppLanguage.polish), 'Provider title');
  });

  test('Polish source errors retain the provider HTTP status', () {
    final controller = AppLanguageController.instance;
    controller.preview(AppLanguage.polish);
    addTearDown(() => controller.preview(AppLanguage.english));

    final message = sourceLoadErrorMessage(StateError('HTTP 401'));
    expect(message, contains('HTTP 401'));
    expect(message, contains('Dostawca'));
    expect(message, isNot(contains('The provider')));

    final missing = sourceLoadErrorMessage(StateError('HTTP 404'));
    expect(missing, contains('HTTP 404'));
    expect(missing, contains('Spróbuj ponownie'));
    expect(missing, contains('jeśli błąd się powtarza'));
    expect(missing, isNot(contains('The provider')));
  });
}
