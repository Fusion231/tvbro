import 'app_language.dart';
import 'messages_browsing.dart';
import 'messages_onboarding.dart';
import 'messages_player.dart';
import 'messages_settings.dart';

export 'app_language.dart';

final polishMessages = <String, String>{
  ...polishBrowsingMessages,
  ...polishSettingsMessages,
  ...polishPlayerMessages,
  ...polishOnboardingMessages,
};

String tr(String english, [Map<String, Object> parameters = const {}]) =>
    translate(english, AppLanguageController.instance.language, parameters);

String translate(
  String english,
  AppLanguage language, [
  Map<String, Object> parameters = const {},
]) {
  final message = language == AppLanguage.polish
      ? polishMessages[english] ?? english
      : english;
  return message.replaceAllMapped(RegExp(r'\{(\w+)\}'), (match) {
    final value = parameters[match[1]];
    return value?.toString() ?? match[0]!;
  });
}
