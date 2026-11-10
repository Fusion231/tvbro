import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/screens/live_preview_controller.dart';
import 'package:media_kit_video/media_kit_video.dart';

void main() {
  testWidgets(
    'first preview open waits for the video output before loading HLS',
    (tester) async {
      final video = _PendingVideoController();
      var opens = 0;
      final opening = openEmbeddedPreview(
        controller: video,
        isCurrent: () => true,
        open: () async => opens++,
      );
      expect(tester.binding.hasScheduledFrame, isTrue);
      await tester.pump();
      expect(opens, 0);
      video.platform.complete(_ReadyVideoOutput());
      expect(await opening, isTrue);
      expect(opens, 1);
    },
  );

  testWidgets('a selection replaced during video initialization never opens', (
    tester,
  ) async {
    final video = _PendingVideoController();
    var current = true;
    var opens = 0;
    final opening = openEmbeddedPreview(
      controller: video,
      isCurrent: () => current,
      open: () async => opens++,
    );
    current = false;
    video.platform.complete(_ReadyVideoOutput());
    expect(await opening, isFalse);
    expect(opens, 0);
    await tester.pump();
  });

  testWidgets('video output failure does not start an audio-only stream', (
    tester,
  ) async {
    final video = _PendingVideoController();
    var opens = 0;
    final opening = openEmbeddedPreview(
      controller: video,
      isCurrent: () => true,
      open: () async => opens++,
    );
    final failed = expectLater(opening, throwsStateError);
    video.platform.completeError(StateError('Video output unavailable'));
    await failed;
    expect(opens, 0);
    await tester.pump();
  });
}

class _PendingVideoController implements VideoController {
  @override
  final platform = Completer<PlatformVideoController>();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ReadyVideoOutput implements PlatformVideoController {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
