import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/screens/profile_setup_screen.dart';

void main() {
  testWidgets('phone setup is optional and returns its own choice', (
    tester,
  ) async {
    ProfileSetupChoice? choice;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProfileSetupChoices(
            cloudAvailable: true,
            onChoose: (value) => choice = value,
          ),
        ),
      ),
    );
    await tester.tap(find.text('Add using your phone'));
    expect(choice, ProfileSetupChoice.cloud);
    expect(find.text('Add an IPTV source'), findsOneWidget);
    expect(find.text('Try Demo streams'), findsOneWidget);
  });

  testWidgets('setup choice is reachable with a D-pad', (tester) async {
    ProfileSetupChoice? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              autofocus: true,
              onPressed: () async {
                result = await Navigator.of(context).push<ProfileSetupChoice>(
                  MaterialPageRoute(
                    builder: (_) =>
                        const ProfileSetupScreen(profileName: 'Living room'),
                  ),
                );
              },
              child: const Text('Open setup'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open setup'));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(result, ProfileSetupChoice.demo);
  });

  for (final size in const [
    Size(320, 568),
    Size(360, 800),
    Size(640, 360),
    Size(960, 540),
    Size(1920, 1080),
  ]) {
    for (final textScale in const [1.0, 1.5, 2.0]) {
      testWidgets(
        'setup choices fit or scroll at ${size.width}x${size.height} with text scale $textScale',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);

          await tester.pumpWidget(
            MaterialApp(
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(textScale)),
                child: child!,
              ),
              home: Scaffold(
                body: SafeArea(
                  child: ProfileSetupChoices(
                    profileName: 'Test profile',
                    cloudAvailable: true,
                    onChoose: (_) {},
                  ),
                ),
              ),
            ),
          );
          await tester.pump();

          expect(find.text('Set up Test profile'), findsOneWidget);
          expect(find.text('Add an IPTV source'), findsOneWidget);
          expect(find.text('Try Demo streams'), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
