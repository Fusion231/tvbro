import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:tvbro_tizen_player/tvbro_tizen_player.dart';
import 'package:video_player_avplay/video_player.dart' as av;
import 'package:video_player_avplay/video_player_platform_interface.dart'
    as api;

void main() {
  test(
    'actual SDK constructor preserves Cookie/UA streaming properties',
    () async {
      final controller = TizenAvplayPlatformPlayer.controllerForMedia(
        Media(
          'https://example.invalid/video.mpd?token=test',
          httpHeaders: {'cookie': 'session=test', 'user-agent': 'TVBro-test'},
        ),
      );
      expect(controller.streamingProperty, {
        api.StreamingPropertyType.cookie: 'session=test',
        api.StreamingPropertyType.userAgent: 'TVBro-test',
      });
      expect(controller.formatHint, api.VideoFormat.dash);
      expect(
        controller.dataSource,
        'https://example.invalid/video.mpd?token=test',
      );
      await controller.dispose();
    },
  );

  test(
    'public factory injects a platform backend without creating mpv',
    () async {
      final player = createTizenPlayer();
      expect(isTizenPlayer(player), isTrue);
      expect(player.platform, isNot(isA<NativePlayer>()));
      await player.dispose();
    },
  );

  test(
    'real SDK values and controls are mapped to MediaKit contracts',
    () async {
      final events = <String>[];
      final backend = TizenAvplayPlatformPlayer(
        controllerFactory: (media) => FakeController(media.uri, events),
      );
      final player = Player(platformPlayer: backend);
      await player.open(Media('https://example.invalid/stream.m3u8'));
      final controller = backend.videoController.value! as FakeController;
      expect(player.state.playing, isTrue);
      expect(
        events.indexOf('volume:https://example.invalid/stream.m3u8'),
        lessThan(
          events.indexOf('initialize:https://example.invalid/stream.m3u8'),
        ),
      );
      expect(
        events.indexOf('initialize:https://example.invalid/stream.m3u8'),
        lessThan(events.indexOf('play:https://example.invalid/stream.m3u8')),
      );
      expect(player.state.width, 1920);
      expect(player.state.videoParams.dh, 1080);
      expect(player.state.tracks.audio.single.id, '2');
      expect(player.state.tracks.subtitle.map((track) => track.id), [
        'no',
        '5',
      ]);

      final position = player.stream.position.first;
      controller.value = controller.value.copyWith(
        position: const Duration(seconds: 12),
        buffered: 37,
        isBuffering: true,
      );
      expect(await position, const Duration(seconds: 12));
      expect(player.state.buffering, isTrue);
      expect(player.state.bufferingPercentage, 37);
      await player.setVolume(35);
      expect(controller.value.volume, 0.35);
      expect(player.state.volume, 35);
      await player.setRate(1.25);
      expect(player.state.rate, 1.25);
      await player.setAudioTrack(player.state.tracks.audio.single);
      expect(controller.selected?.trackId, 2);
      await player.setSubtitleTrack(player.state.tracks.subtitle.last);
      expect(controller.selected?.trackId, 5);
      await player.setSubtitleTrack(SubtitleTrack.no());
      expect(player.state.track.subtitle.id, 'no');
      expect(player.state.subtitle, isEmpty);
      await player.pause();
      expect(player.state.playing, isFalse);
      await player.seek(const Duration(seconds: 8));
      expect(player.state.position, const Duration(seconds: 8));
      await player.dispose();
      expect(controller.disposeCalls, 1);
    },
  );

  test(
    'a superseded open never plays and releases before the next initialize',
    () async {
      final events = <String>[];
      final gate = Completer<void>();
      late FakeController first;
      final backend = TizenAvplayPlatformPlayer(
        controllerFactory: (media) {
          if (media.uri.endsWith('/first')) {
            return first = FakeController(media.uri, events, gate: gate);
          }
          return FakeController(media.uri, events);
        },
      );
      final firstOpen = backend.open(Media('https://example.invalid/first'));
      await Future<void>.delayed(Duration.zero);
      await first.started.future;
      final secondOpen = backend.open(Media('https://example.invalid/second'));
      first.value = first.value.copyWith(position: const Duration(seconds: 99));
      expect(backend.state.position, Duration.zero);
      gate.complete();
      await Future.wait([firstOpen, secondOpen]);
      expect(first.playCalls, 0);
      expect(first.disposeCalls, 1);
      expect(
        events.indexOf('dispose:https://example.invalid/first'),
        lessThan(events.indexOf('initialize:https://example.invalid/second')),
      );
      expect(
        backend.state.playlist.medias.single.uri,
        'https://example.invalid/second',
      );
      expect(backend.state.playing, isTrue);
      await backend.dispose();
    },
  );

  test('dispose during initialize prevents playback and closes once', () async {
    final gate = Completer<void>();
    final controller = FakeController(
      'https://example.invalid/video',
      [],
      gate: gate,
    );
    final backend = TizenAvplayPlatformPlayer(
      controllerFactory: (_) => controller,
    );
    final opening = backend.open(Media(controller.dataSource));
    await controller.started.future;
    final disposing = backend.dispose();
    gate.complete();
    await opening;
    await disposing;
    await backend.dispose();
    expect(controller.playCalls, 0);
    expect(controller.disposeCalls, 1);
  });

  test(
    'credential headers fail explicitly instead of being silently dropped',
    () async {
      var factoryCalls = 0;
      final backend = TizenAvplayPlatformPlayer(
        controllerFactory: (media) {
          factoryCalls++;
          return FakeController(media.uri, []);
        },
      );
      final reported = backend.stream.error.first;
      await expectLater(
        backend.open(
          Media(
            'https://example.invalid/video',
            httpHeaders: {'Authorization': 'must-not-be-ignored'},
          ),
        ),
        throwsA(isA<UnsupportedError>()),
      );
      expect(await reported, contains('Authorization'));
      expect(factoryCalls, 0);
      await backend.dispose();
    },
  );
  test(
    'SDK initialize error is emitted once and releases the controller',
    () async {
      final controller = FakeController(
        'https://example.invalid/fail',
        [],
        initializationError: 'SDK init failed',
      );
      final backend = TizenAvplayPlatformPlayer(
        controllerFactory: (_) => controller,
      );
      final errors = backend.stream.error.toList();
      await expectLater(
        backend.open(Media(controller.dataSource)),
        throwsA(isA<PlatformException>()),
      );
      await backend.dispose();
      expect(await errors, ['SDK init failed']);
      expect(controller.disposeCalls, 1);
    },
  );
}

// An SDK-controller double for CPU contract/lifecycle tests, never a product
// player. It performs no media/network/native playback.
class FakeController extends av.VideoPlayerController {
  FakeController(String url, this.events, {this.gate, this.initializationError})
    : super.network(url);
  final List<String> events;
  final Completer<void>? gate;
  final String? initializationError;
  final Completer<void> started = Completer();
  int disposeCalls = 0;
  int playCalls = 0;
  av.Track? selected;

  @override
  Future<void> initialize() async {
    events.add('initialize:$dataSource');
    started.complete();
    await gate?.future;
    if (initializationError != null) {
      value = av.VideoPlayerValue.erroneous(initializationError!);
      throw PlatformException(
        code: 'native-error',
        message: initializationError,
      );
    }
    value = value.copyWith(
      isInitialized: true,
      size: const Size(1920, 1080),
      duration: api.DurationRange(Duration.zero, const Duration(minutes: 3)),
    );
  }

  @override
  Future<void> play() async {
    events.add('play:$dataSource');
    playCalls++;
    value = value.copyWith(isPlaying: true);
  }

  @override
  Future<void> pause() async => value = value.copyWith(isPlaying: false);
  @override
  Future<void> seekTo(Duration position) async =>
      value = value.copyWith(position: position);
  @override
  Future<void> setVolume(double volume) async {
    events.add('volume:$dataSource');
    value = value.copyWith(volume: volume);
  }

  @override
  Future<void> setPlaybackSpeed(double speed) async =>
      value = value.copyWith(playbackSpeed: speed);
  @override
  Future<bool> setDisplayMode(api.DisplayMode mode) async => true;
  @override
  Future<List<av.VideoTrack>?> get videoTracks async => [
    av.VideoTrack(
      trackId: 0,
      mimetype: 'video/h264',
      width: 1920,
      height: 1080,
      bitrate: 4000000,
    ),
  ];
  @override
  Future<List<av.AudioTrack>?> get audioTracks async => [
    av.AudioTrack(
      trackId: 2,
      mimetype: 'audio/aac',
      language: 'en',
      channel: 2,
      bitrate: 128000,
    ),
  ];
  @override
  Future<List<av.TextTrack>?> get textTracks async => [
    av.TextTrack(trackId: 5, mimetype: 'text/vtt', language: 'pl'),
  ];
  @override
  Future<List<av.Track>> getActiveTrackInfo() async => [
    (await videoTracks)!.single,
    (await audioTracks)!.single,
  ];
  @override
  Future<bool> setTrackSelection(av.Track track) async {
    selected = track;
    return true;
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    events.add('dispose:$dataSource');
    await super.dispose();
  }
}
