import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

enum AppLanguage {
  english('en', 'English'),
  polish('pl', 'Polski');

  const AppLanguage(this.code, this.name);

  final String code;
  final String name;

  Locale get locale => Locale(code);
}

class AppLanguageController extends ChangeNotifier {
  AppLanguageController({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static final instance = AppLanguageController();
  static const storageKey = 'app_language';
  static const supportedLocales = [Locale('en'), Locale('pl')];

  final FlutterSecureStorage _storage;
  AppLanguage _language = AppLanguage.english;
  bool _hasSelection = false;

  AppLanguage get language => _language;
  Locale get locale => _language.locale;
  bool get hasSelection => _hasSelection;

  Future<void> initialize() async {
    final code = await _storage.read(key: storageKey);
    _language = AppLanguage.values.firstWhere(
      (language) => language.code == code,
      orElse: () => AppLanguage.english,
    );
    _hasSelection = AppLanguage.values.any((language) => language.code == code);
    notifyListeners();
  }

  void preview(AppLanguage language) {
    if (_language == language) return;
    _language = language;
    notifyListeners();
  }

  Future<void> confirm() async {
    await _storage.write(key: storageKey, value: _language.code);
    _hasSelection = true;
    notifyListeners();
  }
}
