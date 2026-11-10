import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/l10n/app_localizations.dart';
import 'package:iptvs/player/player_overlay.dart';

void main() {
  String? message({
    bool opening = false,
    bool buffering = false,
    bool seeking = false,
    bool playing = true,
    bool completed = false,
    bool reconnecting = false,
    bool hasError = false,
  }) => playerLoadingMessage(
    opening: opening,
    buffering: buffering,
    seeking: seeking,
    playing: playing,
    completed: completed,
    reconnecting: reconnecting,
    hasError: hasError,
  );

  test('waiting explains startup, seeks and buffer underruns', () {
    expect(message(opening: true, playing: false), 'Loading stream…');
    expect(message(opening: true, seeking: true), 'Loading stream…');
    expect(message(buffering: true), 'Buffering…');
    expect(message(seeking: true, buffering: true), 'Loading after seeking…');
    expect(message(), isNull);
  });

  test('a paused seek can wait; ordinary pause and completion do not', () {
    expect(message(playing: false, buffering: true), isNull);
    expect(message(playing: false, seeking: true), 'Loading after seeking…');
    expect(message(completed: true, buffering: true, seeking: true), isNull);
    expect(message(hasError: true, opening: true), isNull);
  });

  test('reconnecting stays visible while a live EOF is re-resolved', () {
    expect(message(completed: true, reconnecting: true), 'Reconnecting…');
    expect(message(hasError: true, reconnecting: true), isNull);
  });

  test('loading statuses follow the selected Polish language', () {
    final languages = AppLanguageController.instance;
    final original = languages.language;
    addTearDown(() => languages.preview(original));
    languages.preview(AppLanguage.polish);
    expect(message(opening: true), 'Ładowanie strumienia…');
    expect(message(buffering: true), 'Buforowanie…');
    expect(message(seeking: true), 'Wczytywanie po przewinięciu…');
  });

  testWidgets('loader fits a small screen and allows player taps through', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 240);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaQuery.withClampedTextScaling(
            minScaleFactor: 2,
            maxScaleFactor: 2,
            child: Stack(
              fit: StackFit.expand,
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => taps++,
                ),
                const PlayerLoadingIndicator(
                  message: 'Wczytywanie po przewinięciu…',
                ),
              ],
            ),
          ),
        ),
      ),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Wczytywanie po przewinięciu…'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tapAt(const Offset(160, 120));
    expect(taps, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
