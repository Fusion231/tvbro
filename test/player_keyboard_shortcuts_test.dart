import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/player/player_screen.dart';
import 'package:iptvs/sources/source.dart';
import 'package:media_kit/media_kit.dart';

// Exercise the real route and native-control channel without opening media or
// constructing a video output. Windows uses this same Player for its HWND.
void main() {
  const native = MethodChannel('iptvs/native_hdr_player');
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(native, (
      call,
    ) async {
      if (call.method == 'createSurface') return 42;
      return true;
    });
  });

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(native, null);
  });

  Future<_TransportPlayer> openPlayer(
    WidgetTester tester, {
    PlaybackContext? playback,
    List<MediaItem> episodes = const [],
    Future<PlayerEpisode?> Function(BuildContext, MediaItem)? resolveEpisode,
  }) async {
    final platform = _TransportPlayer();
    final player = Player(platformPlayer: platform);
    addTearDown(player.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerScreen(
          title: 'Movie',
          stream: const StreamInfo(
            url: 'https://example.test/movie.mp4',
            isLive: false,
          ),
          existingPlayer: player,
          playback: playback,
          episodes: episodes,
          resolveEpisode: resolveEpisode,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
    platform.commands.clear();
    return platform;
  }

  Future<void> closePlayer(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  }

  Future<void> sendNativeControl(String command) async {
    await binding.defaultBinaryMessenger.handlePlatformMessage(
      native.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('nativeControl', command),
      ),
      (_) {},
    );
  }

  testWidgets('cancelled episode resolution preserves the current media', (
    tester,
  ) async {
    final db = _NoIoPlaybackDatabase();
    var resolutions = 0;
    final platform = await openPlayer(
      tester,
      playback: PlaybackContext(
        db: db,
        sourceId: 'synthetic',
        kind: ContentKind.episode,
        itemId: 'e1',
      ),
      episodes: const [
        MediaItem(id: 'e1', title: 'One', kind: ContentKind.episode),
        MediaItem(id: 'e2', title: 'Two', kind: ContentKind.episode),
      ],
      resolveEpisode: (_, _) async {
        resolutions++;
        return null;
      },
    );
    await sendNativeControl('nextEpisode');
    await tester.pump();
    await tester.pump();
    expect(resolutions, 1);
    expect(platform.commands, isEmpty);
    expect(platform.state.playing, isTrue);
    expect(platform.state.position, const Duration(seconds: 5));
    expect(find.byType(PlayerScreen), findsOneWidget);
    await closePlayer(tester);
  }, skip: !Platform.isWindows);

  testWidgets('Space and media keys control playback once per press', (
    tester,
  ) async {
    final platform = await openPlayer(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(platform.commands, ['toggle']);
    expect(platform.state.playing, isFalse);

    await tester.sendKeyEvent(LogicalKeyboardKey.mediaPlayPause);
    await tester.pump();
    expect(platform.commands, ['toggle', 'toggle']);
    expect(platform.state.playing, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.mediaPause);
    await tester.pump();
    expect(platform.commands, ['toggle', 'toggle', 'pause']);
    expect(platform.state.playing, isFalse);

    await tester.sendKeyEvent(LogicalKeyboardKey.mediaPlay);
    await tester.pump();
    expect(platform.commands, ['toggle', 'toggle', 'pause', 'play']);
    expect(platform.state.playing, isTrue);
    await closePlayer(tester);
  }, skip: !Platform.isWindows);

  testWidgets('Left and Right seek ten seconds and clamp at the beginning', (
    tester,
  ) async {
    final platform = await openPlayer(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump(const Duration(milliseconds: 80));
    expect(platform.seeks, [const Duration(seconds: 15)]);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump(const Duration(milliseconds: 80));
    expect(platform.seeks, [const Duration(seconds: 15), Duration.zero]);
    expect(platform.commands, isEmpty);
    await closePlayer(tester);
  }, skip: !Platform.isWindows);

  testWidgets('native picture and keyboard commands reach the same transport', (
    tester,
  ) async {
    final platform = await openPlayer(tester);
    await sendNativeControl('playPause');
    await tester.pump();
    expect(platform.commands, ['toggle']);
    expect(platform.state.playing, isFalse);

    await sendNativeControl('seekForward');
    await tester.pump();
    await sendNativeControl('seekBack');
    await tester.pump(const Duration(milliseconds: 80));
    expect(platform.seeks, [const Duration(seconds: 5)]);
    expect(platform.state.playing, isFalse);
    await closePlayer(tester);
  }, skip: !Platform.isWindows);
}

class _TransportPlayer extends PlatformPlayer {
  _TransportPlayer() : super(configuration: const PlayerConfiguration()) {
    state = const PlayerState(
      playing: true,
      position: Duration(seconds: 5),
      duration: Duration(minutes: 2),
    );
  }

  final commands = <String>[];
  final seeks = <Duration>[];

  @override
  Future<void> play() async {
    commands.add('play');
    state = state.copyWith(playing: true);
  }

  @override
  Future<void> pause() async {
    commands.add('pause');
    state = state.copyWith(playing: false);
  }

  @override
  Future<void> stop() async {
    commands.add('stop');
    state = state.copyWith(playing: false, position: Duration.zero);
  }

  @override
  Future<void> playOrPause() async {
    commands.add('toggle');
    state = state.copyWith(playing: !state.playing);
  }

  @override
  Future<void> seek(Duration position) async {
    seeks.add(position);
    state = state.copyWith(position: position);
  }

  @override
  Future<void> setVolume(double volume) async {
    state = state.copyWith(volume: volume);
  }
}

class _NoIoPlaybackDatabase implements AppDatabase {
  @override
  Future<void> savePlaybackPosition(
    String sourceId,
    ContentKind kind,
    String itemId, {
    required Duration position,
    required Duration duration,
  }) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected database access in transport test');
}
