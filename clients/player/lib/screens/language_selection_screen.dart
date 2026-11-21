import 'package:flutter/material.dart';

import '../data/device_class.dart';
import '../l10n/app_localizations.dart';
import '../theme.dart';
import '../widgets/app_logo.dart';

class LanguageSelectionScreen extends StatefulWidget {
  const LanguageSelectionScreen({super.key, this.onConfirmed});

  final VoidCallback? onConfirmed;

  @override
  State<LanguageSelectionScreen> createState() =>
      _LanguageSelectionScreenState();
}

class _LanguageSelectionScreenState extends State<LanguageSelectionScreen> {
  final _controller = AppLanguageController.instance;
  final _continueFocus = FocusNode();
  late AppLanguage _selected = _controller.language;
  bool _saving = false;
  bool _failed = false;

  String _text(String message) => translate(message, _selected);

  @override
  void dispose() {
    _continueFocus.dispose();
    super.dispose();
  }

  Future<void> _continue() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _failed = false;
    });
    try {
      await _controller.confirm(_selected);
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _failed = true;
        });
      }
      return;
    }
    if (mounted) widget.onConfirmed?.call();
  }

  @override
  Widget build(BuildContext context) {
    final deviceLanguage = _controller.deviceLanguage;
    final languages = [
      ?deviceLanguage,
      ...AppLanguage.values.where((language) => language != deviceLanguage),
    ];
    final direction = _selected == AppLanguage.arabic
        ? TextDirection.rtl
        : TextDirection.ltr;
    return Directionality(
      textDirection: direction,
      child: Scaffold(
        appBar: widget.onConfirmed == null
            ? null
            : AppBar(backgroundColor: AppColors.ink),
        body: SafeArea(
          minimum: EdgeInsets.all(isTelevision ? 28 : 16),
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: isTelevision ? 1280 : 500),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  const gap = 10.0;
                  final columns = isTelevision && constraints.maxWidth >= 600
                      ? 3
                      : 1;
                  final tileWidth =
                      (constraints.maxWidth - (columns - 1) * gap) / columns;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: AppLogo(height: isTelevision ? 40 : 30),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _text('Choose your language'),
                        style: TextStyle(
                          fontSize: isTelevision ? 34 : 28,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        _text('Select the language used throughout the app.'),
                        style: const TextStyle(color: AppColors.textLo),
                      ),
                      const SizedBox(height: 16),
                      Expanded(
                        child: Scrollbar(
                          child: SingleChildScrollView(
                            primary: true,
                            padding: const EdgeInsetsDirectional.only(end: 8),
                            child: Wrap(
                              spacing: gap,
                              runSpacing: gap,
                              children: [
                                for (final language in languages)
                                  SizedBox(
                                    width: tileWidth - 8 / columns,
                                    child: _choice(language, deviceLanguage),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      if (_failed)
                        Text(
                          _text(
                            'Could not save the language. Please try again.',
                          ),
                          style: const TextStyle(color: AppColors.danger),
                        ),
                      const SizedBox(height: 12),
                      Align(
                        alignment: AlignmentDirectional.centerEnd,
                        child: SizedBox(
                          width: isTelevision ? 184 : double.infinity,
                          child: FilledButton(
                            focusNode: _continueFocus,
                            onPressed: _saving ? null : _continue,
                            style: FilledButton.styleFrom(
                              minimumSize: const Size(0, 48),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Flexible(child: Text(_text('Continue'))),
                                const SizedBox(width: 12),
                                const Icon(Icons.arrow_forward),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _choice(AppLanguage language, AppLanguage? deviceLanguage) {
    final selected = language == _selected;
    return Semantics(
      selected: selected,
      child: OutlinedButton(
        key: ValueKey(language),
        autofocus: language == _controller.language,
        onPressed: _saving
            ? null
            : () {
                setState(() => _selected = language);
                if (isTelevision) _continueFocus.requestFocus();
              },
        style:
            OutlinedButton.styleFrom(
              minimumSize: Size.fromHeight(isTelevision ? 62 : 52),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              foregroundColor: AppColors.textHi,
              backgroundColor: AppColors.panel,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadius.tile),
              ),
            ).copyWith(
              side: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.focused)) {
                  return const BorderSide(color: AppColors.accent, width: 3);
                }
                return BorderSide(
                  color: selected ? AppColors.accent : AppColors.line,
                  width: selected ? 2 : 1,
                );
              }),
            ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    language.name,
                    textDirection: language == AppLanguage.arabic
                        ? TextDirection.rtl
                        : TextDirection.ltr,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: isTelevision ? 20 : 17,
                    ),
                  ),
                  if (language == deviceLanguage)
                    Text(
                      _text('Device language'),
                      style: const TextStyle(color: AppColors.textLo),
                    ),
                ],
              ),
            ),
            if (selected) const Icon(Icons.check, color: AppColors.accent),
          ],
        ),
      ),
    );
  }
}
