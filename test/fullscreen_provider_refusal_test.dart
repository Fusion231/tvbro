import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:iptvs/data/net.dart';
import 'package:iptvs/player/player_screen.dart';
import 'package:iptvs/sources/source.dart';

class _RefusingPlayer extends PlatformPlayer {
  _RefusingPlayer() : super(configuration: const PlayerConfiguration());
  int stops = 0, opens = 0;
  Object? playFailure;
  void failOpen(String message) => errorController.add(message);
  void refuse(String prefix) => logController.add(
    PlayerLog(prefix: prefix, level: 'error', text: 'HTTP error 403'),
  );
  void finishWithGenericError() {
    errorController.add('Failed to open stream.');
    completedController.add(true);
  }
  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    opens++;
  }

  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> play() async {
    final failure = playFailure;
    if (failure != null) throw failure;
  }
  @override
  Future<void> pause() async {}
}

void main() {
  const native = MethodChannel('iptvs/native_hdr_player');
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    ProviderRequestGate.instance.debugReset();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(native, (
      call,
    ) async {
      if (call.method == 'createSurface') return 42;
      return true;
    });
  });
  tearDown(() {
    ProviderRequestGate.instance.debugReset();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(native, null);
  });
  testWidgets('a thrown startup connection error becomes a visible retry error', (tester) async {
    final failure = TimeoutException('https://user:secret@private.test/live');
    final engine = _RefusingPlayer()..playFailure = failure;
    final player = Player(platformPlayer: engine);
    addTearDown(player.dispose);
    await tester.pumpWidget(MaterialApp(
      home: PlayerScreen(
        title: 'Fixture',
        stream: const StreamInfo(url: 'https://private.test/live', isLive: false),
        existingPlayer: player,
      ),
    ));
    await tester.pump();
    await tester.pump();
    expect(find.text(sourceLoadErrorMessage(failure)), findsOneWidget);
    expect(find.textContaining('private.test'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }, skip: !Platform.isWindows);
  testWidgets('VOD open error hides credentials without claiming an HTTP status', (
    tester,
  ) async {
    final engine = _RefusingPlayer();
    final player = Player(platformPlayer: engine);
    addTearDown(player.dispose);
    const url = 'https://vod-error.test/movie/fixture-user/fixture-secret/one.mkv';
    await tester.pumpWidget(MaterialApp(
      home: PlayerScreen(
        title: 'Fixture',
        stream: const StreamInfo(url: url, isLive: false),
        existingPlayer: player,
      ),
    ));
    await tester.pump();
    await tester.pump();
    final opens = engine.opens;
    engine.failOpen('Failed to open $url.');
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('The stream could not be started.'), findsOneWidget);
    expect(find.textContaining('fixture-user'), findsNothing);
    expect(find.textContaining('fixture-secret'), findsNothing);
    expect(find.textContaining('403'), findsNothing);
    await tester.pump(const Duration(seconds: 35));
    expect(engine.opens, opens);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  }, skip: !Platform.isWindows);
  for (final live in [true, false]) {
    for (final prefix in ['curl', 'ffmpeg']) {
      testWidgets('fullscreen $prefix 403 stops recovery and permits Retry for live=$live', (
        tester,
      ) async {
        final engine = _RefusingPlayer();
        final player = Player(platformPlayer: engine);
        addTearDown(player.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: PlayerScreen(
              title: 'Fixture',
              stream: StreamInfo(
                url: 'https://fullscreen-refusal.test/one.ts',
                isLive: live,
              ),
              existingPlayer: player,
            ),
          ),
        );
        await tester.pump();
        await tester.pump();
        final opens = engine.opens;
        engine.refuse(prefix);
        await tester.pump();
        engine.finishWithGenericError();
        await tester.pump(const Duration(seconds: 35));
        expect(engine.stops, greaterThan(0));
        expect(engine.opens, opens);
        expect(
          () => ProviderRequestGate.instance.check(
            Uri.parse('https://fullscreen-refusal.test/two.ts'),
          ),
          returnsNormally,
        );
        await tester.tap(find.text('Retry'));
        await tester.pump();
        await tester.pump();
        expect(engine.opens, opens + 1);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        expect(tester.takeException(), isNull);
      }, skip: !Platform.isWindows);
    }
  }
}
