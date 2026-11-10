import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';
import '../widgets/app_logo.dart';

class LanguageSelectionScreen extends StatefulWidget {
  const LanguageSelectionScreen({super.key});

  @override
  State<LanguageSelectionScreen> createState() =>
      _LanguageSelectionScreenState();
}

class _LanguageSelectionScreenState extends State<LanguageSelectionScreen> {
  bool _saving = false;
  bool _failed = false;

  Future<void> _continue({AppLanguage? language}) async {
    if (_saving) return;
    if (language != null) {
      AppLanguageController.instance.preview(language);
    }
    setState(() {
      _saving = true;
      _failed = false;
    });
    try {
      await AppLanguageController.instance.confirm();
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _failed = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppLanguageController.instance;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: ListenableBuilder(
                listenable: controller,
                builder: (context, child) => Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Center(child: AppLogo()),
                    const SizedBox(height: 32),
                    Text(
                      tr('Choose your language'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      tr('Select the language used throughout the app.'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: AppColors.textLo),
                    ),
                    const SizedBox(height: 24),
                    for (final language in AppLanguage.values)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Semantics(
                          selected: language == controller.language,
                          child: OutlinedButton.icon(
                            autofocus: language == controller.language,
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size.fromHeight(60),
                            ),
                            onPressed: _saving
                                ? null
                                : () => _continue(language: language),
                            icon: Icon(
                              language == controller.language
                                  ? Icons.radio_button_checked
                                  : Icons.radio_button_unchecked,
                            ),
                            label: Text(language.name),
                          ),
                        ),
                      ),
                    if (_failed) ...[
                      Text(
                        tr('Could not save the language. Please try again.'),
                        style: const TextStyle(color: AppColors.danger),
                      ),
                      const SizedBox(height: 12),
                    ],
                    FilledButton(
                      onPressed: _saving ? null : _continue,
                      child: Text(tr('Continue')),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
