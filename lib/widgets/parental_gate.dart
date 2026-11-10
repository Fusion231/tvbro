import 'package:flutter/material.dart';

import '../data/parental_controls.dart';
import '../l10n/app_localizations.dart';
import 'pin_entry.dart';

Future<bool> unlockParentalContent(
  BuildContext context, {
  ParentalControlService? service,
}) async {
  final controls = service ?? ParentalControlService.instance;
  try {
    await controls.ensureInitialized();
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            tr('Parental controls are unavailable. Access remains locked.'),
          ),
        ),
      );
    }
    return false;
  }
  if (!controls.rules.enabled || controls.unlocked) return true;
  if (!context.mounted) return false;
  final verifier = controls.rules.verifier!;
  final accepted = await promptUnlockProfile(
    context,
    profileName: tr('protected content'),
    verifier: verifier,
  );
  if (accepted) controls.unlock(verifier);
  return controls.unlocked;
}

Future<bool> authorizeParentalSettings(
  BuildContext context, {
  ParentalControlService? service,
  bool always = false,
}) async {
  final controls = service ?? ParentalControlService.instance;
  try {
    await controls.ensureInitialized();
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            tr('Parental controls are unavailable. Settings remain locked.'),
          ),
        ),
      );
    }
    return false;
  }
  if (!controls.rules.enabled || (!always && !controls.rules.lockSettings)) {
    return true;
  }
  if (!context.mounted) return false;
  return promptUnlockProfile(
    context,
    profileName: tr('settings'),
    verifier: controls.rules.verifier!,
  );
}
