import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/dvr/dvr_models.dart';
import 'package:iptvs/player/dvr_controls.dart';
import 'package:iptvs/player/mpv_options.dart';
import 'package:iptvs/player/player_screen.dart';

void main() {
  test(
    'local mpv replay opens the selected segment and restores provider options',
    () {
      final local = mpvLiveDemuxerOptions(localDvr: true);
      expect(local, contains('live_start_index=0'));
      expect(local, contains('prefer_x_start=1'));
      expect(mpvLiveDemuxerOptions(), kLiveMpvOptions['demuxer-lavf-o']);
    },
  );

  test(
    'paused playback keeps its saved frame while live telemetry advances',
    () {
      const saved = Duration(milliseconds: 43320);
      const controls = DvrControls(
        active: true,
        position: saved,
        end: Duration(minutes: 2),
      );
      expect(
        controls.positionFromPlayback(
          const Duration(milliseconds: 87320),
          origin: Duration.zero,
          paused: true,
        ),
        saved,
      );
      expect(
        controls.positionFromPlayback(
          const Duration(milliseconds: 47320),
          origin: Duration.zero,
          paused: false,
        ),
        const Duration(milliseconds: 47320),
      );
    },
  );

  test('a stopped capture keeps playable disk media for offline rewind', () {
    for (final state in [DvrCaptureState.stopped, DvrCaptureState.failed]) {
      expect(
        shouldRecoverEmptyDvrBuffer(
          DvrSnapshot(
            state: state,
            bufferStart: const Duration(minutes: 2),
            bufferEnd: const Duration(minutes: 5),
            bytes: 1024,
          ),
        ),
        isFalse,
      );
    }
    expect(
      shouldRecoverEmptyDvrBuffer(
        const DvrSnapshot(
          state: DvrCaptureState.failed,
          error: 'No complete media was captured.',
        ),
      ),
      isTrue,
    );
  });

  test(
    'a zap during native header preparation cannot load the old capture',
    () async {
      final prepared = Completer<void>();
      var current = true;
      var opened = false;
      final transport = runCurrentDvrTransport(
        isCurrent: () => current,
        prepare: () => prepared.future,
        load: () async => opened = true,
      );
      current = false;
      prepared.complete();
      expect(await transport, isFalse);
      expect(opened, isFalse);
    },
  );

  test('disposing during open cannot seek the replacement player', () async {
    final opened = Completer<void>();
    var current = true;
    var sought = false;
    final transport = runCurrentDvrTransport(
      isCurrent: () => current,
      load: () => opened.future,
      afterLoad: () async => sought = true,
    );
    current = false;
    opened.complete();
    expect(await transport, isFalse);
    expect(sought, isFalse);
  });

  test('scrubbing maps into the retained disk window after eviction', () {
    const controls = DvrControls(
      active: true,
      start: Duration(minutes: 12),
      end: Duration(minutes: 22),
      position: Duration(minutes: 15),
    );
    expect(controls.fraction, closeTo(0.3, 0.001));
    expect(controls.positionAt(0.5), const Duration(minutes: 17));
    expect(controls.clamp(const Duration(minutes: 2)), controls.start);
    expect(controls.positionAt(2), controls.end);
  });
}
