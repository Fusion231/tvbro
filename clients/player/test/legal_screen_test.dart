import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_links.dart';
import 'package:iptvs/data/cloud_config.dart';
import 'package:iptvs/screens/legal_screen.dart';
import 'package:iptvs/widgets/focusable_card.dart';

void main() {
  testWidgets('exposes TVBro help and only configured panel pages', (
    tester,
  ) async {
    const channel = MethodChannel('plugins.flutter.io/url_launcher');
    String? opened;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'launch') {
        opened = (call.arguments as Map)['url'] as String;
      }
      return true;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    await tester.pumpWidget(const MaterialApp(home: LegalScreen()));
    await tester.pump();

    expect(find.text('Help & about'), findsOneWidget);

    // Every link is a D-pad-navigable FocusableCard with a real handler, so a
    // TV remote can reach and activate it.
    for (final link in {
      'Support': AppLinks.support,
      'Knowledge base': AppLinks.website,
      'Source code & contributors': AppLinks.repository,
      'Privacy policy': AppLinks.privacyPolicy,
      'Delete cloud account': AppLinks.deleteCloudAccount,
    }.entries) {
      if (link.value == null) {
        expect(find.text(link.key), findsNothing);
        continue;
      }
      expect(find.text(link.key), findsOneWidget);
      final card = tester.widget<FocusableCard>(
        find.ancestor(
          of: find.text(link.key),
          matching: find.byType(FocusableCard),
        ),
      );
      expect(card.onTap, isNotNull);
      opened = null;
      card.onTap();
      await tester.pumpAndSettle();
      expect(opened, link.value);
    }
    if (!CloudConfig.hasPanel) {
      expect(find.text('Privacy policy'), findsNothing);
      expect(find.text('Delete cloud account'), findsNothing);
    }
  });

  testWidgets('first link autofocuses so a D-pad user lands on a focus ring', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: LegalScreen()));
    await tester.pump();

    if (AppLinks.support == null) {
      expect(find.byType(FocusableCard), findsNothing);
      return;
    }
    final firstCard = tester.widget<FocusableCard>(
      find.ancestor(
        of: find.text('Support'),
        matching: find.byType(FocusableCard),
      ),
    );
    expect(firstCard.autofocus, isTrue);
  });
}
