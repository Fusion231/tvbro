import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

enum AppLanguage {
  polish('pl', 'Polski'),
  english('en', 'English'),
  spanish('es', 'Español'),
  german('de', 'Deutsch'),
  french('fr', 'Français'),
  brazilianPortuguese('pt-br', 'Português (Brasil)'),
  italian('it', 'Italiano'),
  turkish('tr', 'Türkçe'),
  ukrainian('uk', 'Українська'),
  arabic('ar', 'العربية'),
  simplifiedChinese('zh-hans', '简体中文'),
  japanese('ja', '日本語'),
  russian('ru', 'Русский'),
  hindi('hi', 'हिन्दी'),
  bengali('bn', 'বাংলা'),
  indonesian('id', 'Bahasa Indonesia'),
  korean('ko', '한국어'),
  vietnamese('vi', 'Tiếng Việt');

  const AppLanguage(this.code, this.name);

  final String code;
  final String name;

  Locale get locale => switch (this) {
    brazilianPortuguese => const Locale.fromSubtags(
      languageCode: 'pt',
      countryCode: 'BR',
    ),
    simplifiedChinese => const Locale.fromSubtags(
      languageCode: 'zh',
      scriptCode: 'Hans',
    ),
    _ => Locale(code),
  };
}

class AppLanguageController extends ChangeNotifier {
  AppLanguageController({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static final instance = AppLanguageController();
  static const storageKey = 'app_language';
  static final supportedLocales = AppLanguage.values
      .map((language) => language.locale)
      .toList(growable: false);

  final FlutterSecureStorage _storage;
  AppLanguage _language = AppLanguage.english;
  AppLanguage? _deviceLanguage;
  bool _hasSelection = false;

  AppLanguage get language => _language;
  AppLanguage? get deviceLanguage => _deviceLanguage;
  Locale get locale => _language.locale;
  bool get hasSelection => _hasSelection;

  Future<void> initialize({Iterable<Locale>? deviceLocales}) async {
    final code = await _storage.read(key: storageKey);
    _deviceLanguage = null;
    for (final locale
        in deviceLocales ??
            WidgetsBinding.instance.platformDispatcher.locales) {
      final index = supportedLocales.indexWhere(
        (supported) => supported.languageCode == locale.languageCode,
      );
      if (index >= 0) {
        _deviceLanguage = AppLanguage.values[index];
        break;
      }
    }
    final index = AppLanguage.values.indexWhere(
      (language) => language.code == code,
    );
    _hasSelection = index >= 0;
    _language = _hasSelection
        ? AppLanguage.values[index]
        : _deviceLanguage ?? AppLanguage.english;
    notifyListeners();
  }

  void preview(AppLanguage language) {
    if (_language == language) return;
    _language = language;
    notifyListeners();
  }

  Future<void> confirm([AppLanguage? language]) async {
    final selected = language ?? _language;
    await _storage.write(key: storageKey, value: selected.code);
    _language = selected;
    _hasSelection = true;
    notifyListeners();
  }
}
