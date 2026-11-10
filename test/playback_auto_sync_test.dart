import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/cloud_auto_sync.dart';
import 'package:iptvs/data/cloud_profile_change.dart';

void main() {
  late StreamController<void> local;
  late StreamController<void> progress;
  late StreamController<void> checkpoints;
  late StreamController<CloudProfileChange> remote;
  late int uploads;
  late int ordinaryUploads;
  late int fullReads;
  late int progressReads;

  setUp(() {
    local = StreamController<void>.broadcast();
    progress = StreamController<void>.broadcast();
    checkpoints = StreamController<void>.broadcast();
    remote = StreamController<CloudProfileChange>.broadcast();
    uploads = ordinaryUploads = fullReads = progressReads = 0;
  });

  tearDown(() async {
    await local.close();
    await progress.close();
    await checkpoints.close();
    await remote.close();
  });

  CloudAutoSync build({
    Future<bool> Function()? upload,
    Future<void> Function()? readProgress,
  }) => CloudAutoSync(
    changes: local.stream,
    playbackChanges: progress.stream,
    urgentPlaybackChanges: checkpoints.stream,
    profileChanges: remote.stream,
    pull: () async {
      fullReads++;
    },
    pullPlayback:
        readProgress ??
        () async {
          progressReads++;
        },
    push: () async {
      ordinaryUploads++;
      return true;
    },
    pushPlayback:
        upload ??
        () async {
          uploads++;
          return true;
        },
    shouldFlushImmediately: () => true,
  );

  test('continuous thirty-second checkpoints upload latest progress every two minutes', () {
    fakeAsync((async) {
      var latest = 0;
      final sent = <int>[];
      final sync = build(
        upload: () async {
          sent.add(latest);
          return true;
        },
      );
      sync.start();
      async.flushMicrotasks();
      for (final seconds in [30, 60, 90]) {
        async.elapse(const Duration(seconds: 30));
        latest = seconds;
        progress.add(null);
        async.flushMicrotasks();
        expect(sent, isEmpty);
      }
      async.elapse(const Duration(seconds: 30));
      async.flushMicrotasks();
      expect(sent, [90]);
      for (final seconds in [120, 150, 180, 210]) {
        latest = seconds;
        progress.add(null);
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 30));
      }
      async.flushMicrotasks();
      expect(sent, [90, 210]);
      async.elapse(const Duration(minutes: 2));
      async.flushMicrotasks();
      expect(sent, [90, 210], reason: 'unchanged playback sends nothing');
      sync.dispose();
    });
  });

  test('favorites do not flush progress, but a sleep checkpoint does', () {
    fakeAsync((async) {
      final sync = build();
      sync.start(pullFirst: false);
      async.flushMicrotasks();
      progress.add(null);
      local.add(null);
      async.elapse(const Duration(seconds: 5));
      async.flushMicrotasks();
      expect(ordinaryUploads, greaterThan(0));
      expect(uploads, 0);
      checkpoints.add(null);
      checkpoints.add(null);
      async.elapse(Duration.zero);
      async.flushMicrotasks();
      expect(uploads, 1);
      async.elapse(const Duration(minutes: 2));
      async.flushMicrotasks();
      expect(uploads, 1);
      sync.dispose();
    });
  });

  test('progress notifications download only progress; mixed changes retain full refresh', () {
    fakeAsync((async) {
      final sync = build();
      sync.start();
      async.flushMicrotasks();
      expect(fullReads, 1);
      remote.add(CloudProfileChange.playback);
      async.elapse(const Duration(seconds: 5));
      async.flushMicrotasks();
      expect((fullReads, progressReads), (1, 1));
      remote.add(CloudProfileChange.profile);
      remote.add(CloudProfileChange.playback);
      async.elapse(const Duration(seconds: 5));
      async.flushMicrotasks();
      expect((fullReads, progressReads), (2, 1));
      remote.add(CloudProfileChange.playback);
      remote.add(CloudProfileChange.profile);
      async.elapse(const Duration(seconds: 5));
      async.flushMicrotasks();
      expect((fullReads, progressReads), (3, 1));
      sync.dispose();
    });
  });

  test(
    'failed progress upload retries on next interval without another edit',
    () {
      fakeAsync((async) {
        final sync = build(
          upload: () async {
            uploads++;
            if (uploads == 1) throw StateError('offline');
            return true;
          },
        );
        sync.start(pullFirst: false);
        async.elapse(const Duration(minutes: 2));
        async.flushMicrotasks();
        expect(uploads, 1);
        async.elapse(const Duration(seconds: 119));
        async.flushMicrotasks();
        expect(uploads, 1);
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(uploads, 2);
        sync.dispose();
      });
    },
  );

  test(
    'progress pull failure retries progress without downloading configuration',
    () {
      fakeAsync((async) {
        final sync = build(
          readProgress: () async {
            progressReads++;
            if (progressReads == 1) throw StateError('offline');
          },
        );
        sync.start(pullFirst: false);
        remote.add(CloudProfileChange.playback);
        async.elapse(const Duration(seconds: 5));
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 30));
        async.flushMicrotasks();
        expect((fullReads, progressReads), (0, 2));
        sync.dispose();
      });
    },
  );

  test('sleep flush waits for in-flight progress and uploads later edits before returning', () async {
    final started = Completer<void>();
    final release = Completer<bool>();
    final sync = build(
      upload: () {
        uploads++;
        if (uploads == 1) {
          started.complete();
          return release.future;
        }
        return Future.value(true);
      },
    );
    await sync.start(pullFirst: false);
    checkpoints.add(null);
    await started.future;
    progress.add(null);
    await Future<void>.delayed(Duration.zero);
    var flushed = false;
    final flushing = sync.flush().then((_) => flushed = true);
    await Future<void>.delayed(Duration.zero);
    expect(flushed, isFalse);
    release.complete(true);
    await flushing;
    expect(uploads, 2);
    await sync.dispose();
  });

  test('disposal cancels the progress timer and urgent listener', () {
    fakeAsync((async) {
      final sync = build();
      sync.start(pullFirst: false);
      async.flushMicrotasks();
      sync.dispose();
      async.flushMicrotasks();
      progress.add(null);
      checkpoints.add(null);
      remote.add(CloudProfileChange.playback);
      async.elapse(const Duration(minutes: 5));
      async.flushMicrotasks();
      expect((uploads, progressReads), (0, 0));
      expect(progress.hasListener, isFalse);
      expect(checkpoints.hasListener, isFalse);
      expect(remote.hasListener, isFalse);
      expect(sync.busy, isFalse);
    });
  });
}
