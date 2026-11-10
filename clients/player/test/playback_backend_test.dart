import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

import 'package:iptvs/player/playback_backend.dart';
import 'package:iptvs/player/player_overlay.dart';

void main() {
  testWidgets(
    'registered player keeps the existing overlay and event streams',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const configuration = PlayerConfiguration(
        logLevel: MPVLogLevel.warn,
        iosManageAudioSession: false,
      );
      const videoKey = ValueKey('registered-video');
      final surfaceKey = GlobalKey<PlayerVideoSurfaceState>();
      var initializations = 0;
      var backCalls = 0;
      PlayerConfiguration? receivedConfiguration;
      BoxFit? receivedFit;
      Color? receivedFill;
      Player? renderedPlayer;
      late _TestPlatformPlayer platform;

      PlaybackBackend.register(
        initialize: () => initializations++,
        createPlayer: (configuration) {
          receivedConfiguration = configuration;
          platform = _TestPlatformPlayer(configuration: configuration);
          return Player(platformPlayer: platform);
        },
        ownsPlayer: (player) => identical(player.platform, platform),
        buildVideo: (player, fit, fill) {
          renderedPlayer = player;
          receivedFit = fit;
          receivedFill = fill;
          return const ColoredBox(key: videoKey, color: Colors.black);
        },
      );
      PlaybackBackend.initialize();
      final player = PlaybackBackend.createPlayer(configuration: configuration);
      addTearDown(player.dispose);
      final playingEvents = <bool>[];
      final subscription = player.stream.playing.listen(playingEvents.add);
      addTearDown(subscription.cancel);

      expect(initializations, 1);
      expect(PlaybackBackend.isCustom, isTrue);
      expect(receivedConfiguration, same(configuration));
      expect(platform.configuration, same(configuration));
      expect(player.platform, same(platform));
      expect(player.platform, isNot(isA<NativePlayer>()));
      expect(PlaybackBackend.usesCustomSurface(player), isTrue);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlayerVideoSurface(
              key: surfaceKey,
              player: player,
              controller: null,
              title: 'Tizen channel',
              sourceName: null,
              epgNow: null,
              epgNext: null,
              isLive: true,
              canFavorite: false,
              favorite: false,
              liveSynced: true,
              aspectLabel: 'Fill',
              videoFit: BoxFit.cover,
              dynamicRangeLabel: (_) => '',
              onBack: () => backCalls++,
              onToggleFavorite: () {},
              onPlayPause: player.playOrPause,
              onGoLive: () async {},
              onCycleAspect: () async {},
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byKey(videoKey), findsOneWidget);
      expect(renderedPlayer, same(player));
      expect(receivedFit, BoxFit.cover);
      expect(receivedFill, const Color(0xFF000000));
      final overlay = tester.widget<EmbeddedPlayerControls>(
        find.byType(EmbeddedPlayerControls),
      );
      expect(overlay.controls, isA<PlayerBackedEmbeddedControls>());
      expect(overlay.controls.stream, same(player.stream));
      expect(overlay.controls.state, same(player.state));
      expect(overlay.fullscreenToggle, isFalse);
      expect(find.byTooltip('Fullscreen (F)'), findsNothing);
      expect(find.byIcon(Icons.fullscreen), findsNothing);

      await tester.tap(find.byTooltip('Play'));
      await tester.pump();
      expect(platform.playPauseCalls, 1);
      expect(player.state.playing, isTrue);
      expect(playingEvents, [true]);
      expect(find.byTooltip('Pause'), findsOneWidget);

      platform.emitPlaying(false);
      await tester.pump();
      expect(playingEvents, [true, false]);
      expect(find.byTooltip('Play'), findsOneWidget);
      surfaceKey.currentState!.toggleMute();
      await tester.pump();
      expect(platform.lastVolume, 0);
      expect(player.state.volume, 0);
      await tester.tap(find.byTooltip('Back'));
      await tester.pump();
      expect(backCalls, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

class _TestPlatformPlayer extends PlatformPlayer {
  _TestPlatformPlayer({required super.configuration});

  var playPauseCalls = 0;
  double? lastVolume;

  void emitPlaying(bool playing) {
    state = state.copyWith(playing: playing);
    playingController.add(playing);
  }

  @override
  Future<void> playOrPause() async {
    playPauseCalls++;
    emitPlaying(!state.playing);
  }

  @override
  Future<void> setVolume(double volume) async {
    lastVolume = volume;
    state = state.copyWith(volume: volume);
    volumeController.add(volume);
  }
}
