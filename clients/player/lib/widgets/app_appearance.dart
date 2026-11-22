import 'package:flutter/material.dart';

import '../theme.dart';

/// The TVBro palette used by the home, setup, settings and player views.
/// Opt in per view because the library routes still use [AppTheme.dark].
class AppAppearance extends StatelessWidget {
  const AppAppearance({super.key, required this.child});

  final Widget child;

  static const background = Color(0xFF090E19);
  static const surface = Color(0xFF151E2E);
  static const raised = Color(0xFF212E43);
  static const line = Color(0xFF374459);
  static const focusFill = Color(0xFF392333);
  static const radius = 12.0;

  static const backdrop = BoxDecoration(
    gradient: RadialGradient(
      center: Alignment(-0.65, -0.85),
      radius: 1.18,
      colors: [Color(0xFF211625), background],
    ),
  );

  static bool isApplied(BuildContext context) =>
      Theme.of(context).extension<_AppearanceMarker>() != null;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (isApplied(context)) return child;

    const shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(radius)),
    );
    const border = OutlineInputBorder(
      borderRadius: BorderRadius.all(Radius.circular(radius)),
      borderSide: BorderSide(color: line),
    );

    ButtonStyle button(ButtonStyle? base, {Color? fill}) =>
        (base ?? const ButtonStyle()).copyWith(
          shape: const WidgetStatePropertyAll(shape),
          side: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.focused)
                ? const BorderSide(color: Colors.white, width: 2)
                : BorderSide(
                    color: fill == surface ? line : Colors.transparent,
                  ),
          ),
          backgroundColor: fill == null
              ? base?.backgroundColor
              : WidgetStateProperty.resolveWith((states) {
                  if (states.contains(WidgetState.disabled)) return null;
                  if (fill == surface && states.contains(WidgetState.focused)) {
                    return focusFill;
                  }
                  return fill;
                }),
        );

    return Theme(
      data: theme.copyWith(
        extensions: [...theme.extensions.values, const _AppearanceMarker()],
        colorScheme: theme.colorScheme.copyWith(
          surface: background,
          surfaceContainerLowest: background,
          surfaceContainerLow: surface,
          surfaceContainer: surface,
          surfaceContainerHigh: raised,
          surfaceContainerHighest: raised,
          outline: line,
          outlineVariant: line,
        ),
        scaffoldBackgroundColor: background,
        appBarTheme: theme.appBarTheme.copyWith(
          backgroundColor: background,
          surfaceTintColor: Colors.transparent,
        ),
        dialogTheme: theme.dialogTheme.copyWith(
          backgroundColor: surface,
          surfaceTintColor: Colors.transparent,
          shape: shape,
        ),
        popupMenuTheme: theme.popupMenuTheme.copyWith(
          color: raised,
          shape: shape,
        ),
        dividerTheme: theme.dividerTheme.copyWith(color: line),
        inputDecorationTheme: theme.inputDecorationTheme.copyWith(
          fillColor: surface,
          border: border,
          enabledBorder: border,
          focusedBorder: border.copyWith(
            borderSide: const BorderSide(color: Colors.white, width: 2),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: button(theme.textButtonTheme.style),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: button(theme.outlinedButtonTheme.style, fill: surface),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: button(
            theme.filledButtonTheme.style,
            fill: AppColors.accentFill,
          ),
        ),
      ),
      child: child,
    );
  }
}

// Captured with Theme by dialogs and popup menus opened from a styled view.
class _AppearanceMarker extends ThemeExtension<_AppearanceMarker> {
  const _AppearanceMarker();

  @override
  _AppearanceMarker copyWith() => this;

  @override
  _AppearanceMarker lerp(_AppearanceMarker? other, double t) => this;
}
