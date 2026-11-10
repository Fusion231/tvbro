import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/provider_stream_gate.dart';
import '../l10n/app_localizations.dart';
import 'focusable_card.dart';

Future<bool> showProviderStreamWarning(
  BuildContext context,
  ProviderStreamLimitReached limit, {
  bool native = false,
}) async {
  if (!context.mounted) return false;
  final title = tr('Provider stream limit');
  final quota = tr(
    'Starting another stream may exceed the account\'s simultaneous stream limit ({limit}).',
    {'limit': limit.limit},
  );
  final estimate = tr(
    'The detected usage may be out of date. If the provider limit is unknown, TVBro assumes one stream.',
  );
  final consequences = tr(
    'Continuing may cause buffering or prevent playback, and may interrupt another stream or recording on this account. The provider may still refuse or restrict connections.',
  );
  if (native) {
    return await const MethodChannel('iptvs/native_hdr_player')
            .invokeMethod<bool>('confirmProviderStreamWarning', {
              'title': title,
              'message': '$quota\n\n$estimate\n\n$consequences',
              'cancelLabel': tr('Cancel'),
              'continueLabel': tr('Watch anyway'),
            }) ??
        false;
  }
  return await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          scrollable: true,
          title: Text(title),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(quota),
                const SizedBox(height: 12),
                Text(estimate),
                const SizedBox(height: 12),
                Text(consequences),
              ],
            ),
          ),
          actions: [
            FocusableCard(
              autofocus: true,
              scrollOnFocus: false,
              onTap: () => Navigator.of(context).pop(false),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                child: Text(tr('Cancel')),
              ),
            ),
            FocusableCard(
              scrollOnFocus: false,
              onTap: () => Navigator.of(context).pop(true),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                child: Text(tr('Watch anyway')),
              ),
            ),
          ],
        ),
      ) ??
      false;
}
