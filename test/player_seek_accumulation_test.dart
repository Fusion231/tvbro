import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/player/player_overlay.dart';
import 'package:media_kit/media_kit.dart';

void main() {
  Future<_StubControls> open(WidgetTester tester, bool playing) async {
    final controls = _StubControls(
      state: PlayerState(
        position: const Duration(seconds: 100),
        duration: const Duration(seconds: 600),
        playing: playing,
      ),
    );
    addTearDown(controls.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EmbeddedPlayerControls(
            controls: controls,
            title: 'Series',
            sourceName: null,
            epgNow: null,
            epgNext: null,
            isLive: false,
            canFavorite: false,
            favorite: false,
            liveSynced: false,
            aspectLabel: 'Fit',
            dynamicRangeLabel: (_) => '',
            onBack: () {},
            onToggleFavorite: () {},
            onPlayPause: () async {},
            onGoLive: () async {},
            onCycleAspect: () async {},
            onToggleFullscreen: () {},
          ),
        ),
      ),
    );
    await tester.pump();
    return controls;
  }

  for (final playing in [false, true]) {
    testWidgets(
      'overlay accumulates twenty +10 inputs with delayed confirmation playing=$playing',
      (tester) async {
        final controls = await open(tester, playing);
        for (var i = 0; i < 20; i++) {
          await tester.tap(find.byTooltip('Forward 10 seconds'));
          await tester.pump(const Duration(milliseconds: 50));
        }
        await tester.pump(const Duration(milliseconds: 80));
        expect(controls.auditSeeks, [const Duration(seconds: 300)]);
        expect(controls.state.playing, playing);
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      },
    );
  }
  testWidgets('opposite overlay inputs cancel against the pending target', (
    tester,
  ) async {
    final controls = await open(tester, false);
    await tester.tap(find.byTooltip('Forward 10 seconds'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byTooltip('Back 10 seconds'));
    await tester.pump(const Duration(milliseconds: 80));
    expect(controls.auditSeeks, [const Duration(seconds: 100)]);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}

class _StubControls implements EmbeddedControls {
  _StubControls({this.state = const PlayerState()});

  @override
  final PlayerState state;

  final _playing = StreamController<bool>.broadcast();
  final _tracks = StreamController<Tracks>.broadcast();
  final _track = StreamController<Track>.broadcast();
  final _videoParams = StreamController<VideoParams>.broadcast();
  final _volume = StreamController<double>.broadcast();
  final _position = StreamController<Duration>.broadcast();

  @override
  late final PlayerStream stream = PlayerStream(
    const Stream<Never>.empty(), // playlist
    _playing.stream,
    const Stream<Never>.empty(), // completed
    _position.stream,
    const Stream<Never>.empty(), // duration
    _volume.stream,
    const Stream<Never>.empty(), // rate
    const Stream<Never>.empty(), // pitch
    const Stream<Never>.empty(), // buffering
    const Stream<Never>.empty(), // bufferingPercentage
    const Stream<Never>.empty(), // buffer
    const Stream<Never>.empty(), // playlistMode
    const Stream<Never>.empty(), // shuffle
    const Stream<Never>.empty(), // audioParams
    _videoParams.stream,
    const Stream<Never>.empty(), // audioBitrate
    const Stream<Never>.empty(), // audioDevice
    const Stream<Never>.empty(), // audioDevices
    _track.stream,
    _tracks.stream,
    const Stream<Never>.empty(), // width
    const Stream<Never>.empty(), // height
    const Stream<Never>.empty(), // subtitle
    const Stream<Never>.empty(), // log
    const Stream<Never>.empty(), // error
  );

  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> seek(Duration to) {
    auditSeeks.add(to);
    final pending = Completer<void>();
    auditPending.add(pending);
    return pending.future;
  }

  final auditSeeks = <Duration>[];
  final auditPending = <Completer<void>>[];
  @override
  Future<void> setRate(double rate) async {}
  @override
  Future<void> setAudioTrack(AudioTrack track) async {}
  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {}

  Future<void> dispose() async {
    for (final pending in auditPending) {
      if (!pending.isCompleted) pending.complete();
    }
    await _playing.close();
    await _tracks.close();
    await _track.close();
    await _videoParams.close();
    await _volume.close();
    await _position.close();
  }
}
