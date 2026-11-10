import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

import 'package:iptvs/player/playback_backend.dart';
import 'package:iptvs/player/player_overlay.dart';

void main() {
  testWidgets('TV arrows and OK operate the existing controls', (tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final platform = _TvPlatformPlayer();
    PlaybackBackend.register(
      initialize: () {},
      createPlayer: (_) => Player(platformPlayer: platform),
      ownsPlayer: (player) => identical(player.platform, platform),
      buildVideo: (_, _, _) => const ColoredBox(color: Colors.black),
    );
    final player = PlaybackBackend.createPlayer();
    addTearDown(player.dispose);
    final key = GlobalKey<PlayerVideoSurfaceState>();
    var plays = 0;
    var backs = 0;
    var live = 0;
    var fallbacks = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CallbackShortcuts(
            bindings: {
              for (final button in [
                LogicalKeyboardKey.arrowLeft,
                LogicalKeyboardKey.arrowRight,
                LogicalKeyboardKey.arrowUp,
                LogicalKeyboardKey.arrowDown,
                LogicalKeyboardKey.select,
                LogicalKeyboardKey.enter,
              ])
                SingleActivator(button): () {
                  if (!key.currentState!.handleTvKey(button)) fallbacks++;
                },
            },
            child: Focus(
              autofocus: true,
              child: PlayerVideoSurface(
                key: key,
                player: player,
                controller: null,
                title: 'TV channel',
                sourceName: null,
                epgNow: null,
                epgNext: null,
                isLive: true,
                canFavorite: false,
                favorite: false,
                liveSynced: false,
                aspectLabel: 'Fit',
                videoFit: BoxFit.contain,
                dynamicRangeLabel: (_) => '',
                onBack: () => backs++,
                onToggleFavorite: () {},
                onPlayPause: () async => plays++,
                onGoLive: () async => live++,
                onCycleAspect: () async {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(plays, 0);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'TV play pause');
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(plays, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(backs, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    for (var index = 0; index < 5; index++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(SimpleDialog), findsOneWidget);
    expect(find.text('Playback settings'), findsOneWidget);
    expect(plays, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(SimpleDialog), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(live, 1);
    expect(fallbacks, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

class _TvPlatformPlayer extends PlatformPlayer {
  _TvPlatformPlayer() : super(configuration: const PlayerConfiguration());
}
