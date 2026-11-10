// CloudAutoSync: the debounce/coalesce/retry behaviour that decides how often
// an auto-pushing device talks to the server, and whether a change can be lost.

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/data/cloud_auto_sync.dart';

void main() {
  late StreamController<void> changes;
  late StreamController<void> remoteChanges;
  late StreamController<void> settingsChanges;
  late int pulls;
  late int pushes;

  setUp(() {
    changes = StreamController<void>.broadcast();
    remoteChanges = StreamController<void>.broadcast();
    settingsChanges = StreamController<void>.broadcast();
    pulls = 0;
    pushes = 0;
  });

  tearDown(() async {
    await changes.close();
    await remoteChanges.close();
    await settingsChanges.close();
  });

  CloudAutoSync build({
    Future<void> Function()? pull,
    Future<bool> Function()? push,
    Duration debounce = const Duration(seconds: 5),
    Duration retryDelay = const Duration(seconds: 30),
    bool Function()? shouldFlushImmediately,
  }) => CloudAutoSync(
    pull: pull ?? () async => pulls++,
    push:
        push ??
        () async {
          pushes++;
          return true;
        },
    changes: changes.stream,
    additionalChanges: [settingsChanges.stream],
    remoteChanges: remoteChanges.stream,
    debounce: debounce,
    retryDelay: retryDelay,
    shouldFlushImmediately: shouldFlushImmediately,
  );

  test('start pulls once, then pushes anything already queued', () {
    fakeAsync((async) {
      final sync = build();
      sync.start();
      async.flushMicrotasks();
      expect(pulls, 1);

      // The trailing push is debounced, not immediate.
      expect(pushes, 0);
      async.elapse(const Duration(seconds: 5));
      async.flushMicrotasks();
      expect(pushes, 1);
      sync.dispose();
    });
  });

  test('several rapid changes coalesce into one push', () {
    fakeAsync((async) {
      final sync = build();
      sync.start(pullFirst: false);
      async.flushMicrotasks();
      pushes = 0;

      for (var i = 0; i < 5; i++) {
        changes.add(null);
        async.elapse(const Duration(milliseconds: 200));
      }
      async.flushMicrotasks();
      // Still inside the debounce window: nothing sent yet.
      expect(pushes, 0);

      async.elapse(const Duration(seconds: 5));
      async.flushMicrotasks();
      expect(pushes, 1, reason: 'five toggles is one round trip, not five');
      sync.dispose();
    });
  });

  test(
    'background settings bypass debounce and keep failed changes queued',
    () {
      fakeAsync((async) {
        var backgrounded = false;
        var offline = false;
        final sync = build(
          shouldFlushImmediately: () => backgrounded,
          push: () async {
            pushes++;
            if (offline) throw StateError('offline');
            return true;
          },
        );
        sync.start(pullFirst: false);
        async.elapse(const Duration(seconds: 5));
        async.flushMicrotasks();
        pushes = 0;

        backgrounded = true;
        settingsChanges.add(null);
        async.elapse(Duration.zero);
        async.flushMicrotasks();
        expect(pushes, 1);

        offline = true;
        settingsChanges.add(null);
        async.elapse(Duration.zero);
        async.flushMicrotasks();
        expect(pushes, 2);
        offline = false;
        async.elapse(const Duration(seconds: 30));
        async.flushMicrotasks();
        expect(pushes, 3);
        sync.dispose();
      });
    },
  );

  test('settings and favorites share one debounced push', () {
    fakeAsync((async) {
      final sync = build();
      sync.start(pullFirst: false);
      async.flushMicrotasks();
      sync.flush();
      async.flushMicrotasks();
      pushes = 0;

      changes.add(null);
      async.elapse(const Duration(seconds: 1));
      settingsChanges.add(null);
      async.elapse(const Duration(seconds: 4));
      async.flushMicrotasks();
      expect(pushes, 0);
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      expect(pushes, 1);
      sync.dispose();
    });
  });

  test('remote edits and reconnect bursts pull without echoing a push', () {
    fakeAsync((async) {
      final sync = build();
      sync.start();
      async.flushMicrotasks();
      sync.flush();
      async.flushMicrotasks();
      pulls = 0;
      pushes = 0;

      for (var i = 0; i < 4; i++) {
        remoteChanges.add(null);
        async.elapse(const Duration(milliseconds: 200));
      }
      expect(pulls, 0);
      async.elapse(const Duration(seconds: 5));
      async.flushMicrotasks();
      expect(pulls, 1);
      expect(pushes, 0);

      async.elapse(const Duration(minutes: 1));
      async.flushMicrotasks();
      expect(pulls, 1, reason: 'unchanged profiles are not polled');
      expect(pushes, 0, reason: 'a cloud pull is not local user intent');
      sync.dispose();
    });
  });

  test('remote edits during a pull share one trailing pull', () {
    fakeAsync((async) {
      final finished = <Completer<void>>[];
      final sync = build(
        pull: () {
          pulls++;
          final operation = Completer<void>();
          finished.add(operation);
          return operation.future;
        },
      );
      sync.start(pullFirst: false);
      async.flushMicrotasks();
      sync.flush();
      async.flushMicrotasks();
      pushes = 0;

      remoteChanges.add(null);
      async.elapse(const Duration(seconds: 5));
      async.flushMicrotasks();
      expect(pulls, 1);
      for (var i = 0; i < 4; i++) {
        remoteChanges.add(null);
      }
      async.elapse(const Duration(seconds: 10));
      async.flushMicrotasks();
      expect(pulls, 1, reason: 'an in-flight pull is never overlapped');

      finished.first.complete();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 5));
      async.flushMicrotasks();
      expect(pulls, 2);
      finished.last.complete();
      async.flushMicrotasks();
      async.elapse(const Duration(minutes: 1));
      async.flushMicrotasks();
      expect(pulls, 2, reason: 'the four events need only one follow-up');
      expect(pushes, 0);
      sync.dispose();
    });
  });

  test('remote changes are observed during the startup pull', () {
    fakeAsync((async) {
      final startupFinished = Completer<void>();
      final sync = build(
        pull: () async {
          pulls++;
          if (pulls == 1) await startupFinished.future;
        },
      );
      sync.start();
      async.flushMicrotasks();
      expect(pulls, 1);
      remoteChanges.add(null);
      async.elapse(const Duration(seconds: 5));
      async.flushMicrotasks();
      expect(pulls, 1);

      startupFinished.complete();
      async.flushMicrotasks();
      expect(pulls, 2, reason: 'the queued event rereads after startup');
      sync.dispose();
    });
  });

  test('a failed pull retries after backoff and stops after recovery', () {
    fakeAsync((async) {
      final sync = build(
        pull: () async {
          pulls++;
          if (pulls == 1) throw StateError('offline');
        },
      );
      sync.start();
      async.flushMicrotasks();
      expect(pulls, 1);
      async.elapse(const Duration(seconds: 29));
      async.flushMicrotasks();
      expect(pulls, 1);
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      expect(pulls, 2);
      async.elapse(const Duration(minutes: 2));
      async.flushMicrotasks();
      expect(pulls, 2);
      expect(sync.busy, isFalse);
      sync.dispose();
    });
  });

  test('a change during an in-flight push is not lost', () {
    fakeAsync((async) {
      final completers = <Completer<bool>>[];
      final sync = build(
        push: () {
          pushes++;
          final c = Completer<bool>();
          completers.add(c);
          return c.future;
        },
      );
      sync.start(pullFirst: false);
      async.flushMicrotasks();

      changes.add(null);
      async.elapse(const Duration(seconds: 5));
      async.flushMicrotasks();
      expect(pushes, 1);

      // Toggled while the first push is still in flight.
      changes.add(null);
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      expect(pushes, 1, reason: 'no second push stacked behind the first');

      completers.first.complete(true);
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 5));
      async.flushMicrotasks();
      expect(pushes, 2, reason: 'the change made mid-push is sent afterwards');
      sync.dispose();
    });
  });

  test('a failed push retries and does not throw', () {
    fakeAsync((async) {
      var attempts = 0;
      final sync = build(
        push: () async {
          attempts++;
          if (attempts == 1) throw StateError('offline');
          return true;
        },
        retryDelay: const Duration(seconds: 30),
      );
      sync.start(pullFirst: false);
      async.flushMicrotasks();

      changes.add(null);
      async.elapse(const Duration(seconds: 5));
      async.flushMicrotasks();
      expect(attempts, 1);

      async.elapse(const Duration(seconds: 30));
      async.flushMicrotasks();
      expect(attempts, 2, reason: 'the queued change is retried');
      sync.dispose();
    });
  });

  test('a failing pull never propagates to the caller', () {
    fakeAsync((async) {
      final sync = build(pull: () async => throw StateError('no network'));
      // start() awaits pullNow(); an unswallowed throw here would take the app
      // launch (or a profile switch) down with it.
      var completed = false;
      sync.start().then((_) => completed = true);
      async.flushMicrotasks();
      expect(completed, isTrue);
      sync.dispose();
    });
  });

  test('flush bypasses the debounce', () {
    fakeAsync((async) {
      final sync = build();
      sync.start(pullFirst: false);
      async.flushMicrotasks();
      pushes = 0;

      changes.add(null);
      async.elapse(const Duration(milliseconds: 100));
      sync.flush();
      async.flushMicrotasks();
      expect(pushes, 1, reason: 'backgrounding must not wait out the timer');
      sync.dispose();
    });
  });

  test('nothing fires after dispose', () {
    fakeAsync((async) {
      final sync = build();
      sync.start(pullFirst: false);
      async.flushMicrotasks();
      pushes = 0;

      changes.add(null);
      settingsChanges.add(null);
      remoteChanges.add(null);
      sync.dispose();
      async.elapse(const Duration(minutes: 5));
      async.flushMicrotasks();
      expect(pushes, 0);
      expect(pulls, 0);
      expect(changes.hasListener, isFalse);
      expect(settingsChanges.hasListener, isFalse);
      expect(remoteChanges.hasListener, isFalse);
    });
  });

  test('dispose cancels pull and push retries', () {
    fakeAsync((async) {
      final sync = build(
        pull: () async {
          pulls++;
          throw StateError('offline');
        },
        push: () async {
          pushes++;
          throw StateError('offline');
        },
      );
      sync.start();
      async.flushMicrotasks();
      sync.flush();
      async.flushMicrotasks();
      expect((pulls, pushes), (1, 1));
      sync.dispose();
      async.flushMicrotasks();
      async.elapse(const Duration(minutes: 5));
      async.flushMicrotasks();
      expect((pulls, pushes), (1, 1));
      expect(sync.busy, isFalse);
    });
  });

  test(
    'dispose drains startup pull without scheduling its trailing push',
    () async {
      final pullFinished = Completer<void>();
      final sync = build(
        pull: () => pullFinished.future,
        debounce: Duration.zero,
      );
      final starting = sync.start();

      var disposed = false;
      final disposing = sync.dispose().then((_) => disposed = true);
      await Future<void>.delayed(Duration.zero);
      expect(disposed, isFalse);

      pullFinished.complete();
      await Future.wait([starting, disposing]);
      expect(disposed, isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(pushes, 0);
    },
  );

  for (final fail in [false, true]) {
    test(
      'dispose drains push without a follow-up or retry (fail=$fail)',
      () async {
        final pushStarted = Completer<void>();
        final pushFinished = Completer<bool>();
        final sync = build(
          push: () {
            pushes++;
            pushStarted.complete();
            return pushFinished.future;
          },
          debounce: Duration.zero,
          retryDelay: Duration.zero,
        );
        await sync.start(pullFirst: false);
        await pushStarted.future;
        expect(pushes, 1);
        changes.add(null);
        await Future<void>.delayed(Duration.zero);

        var disposed = false;
        final disposing = sync.dispose().then((_) => disposed = true);
        await Future<void>.delayed(Duration.zero);
        expect(disposed, isFalse);

        if (fail) {
          pushFinished.completeError(StateError('offline'));
        } else {
          pushFinished.complete(true);
        }
        await disposing;
        expect(disposed, isTrue);
        expect(sync.busy, isFalse);
        await Future<void>.delayed(Duration.zero);
        expect(pushes, 1);
      },
    );
  }

  test(
    'coalesced pulls wait for pushes and dispose drains accepted work',
    () async {
      final pushStarted = Completer<void>();
      final pullStarted = Completer<void>();
      final pullFinished = Completer<void>();
      final pushFinished = Completer<bool>();
      final sync = build(
        pull: () {
          pulls++;
          pullStarted.complete();
          return pullFinished.future;
        },
        push: () {
          pushes++;
          pushStarted.complete();
          return pushFinished.future;
        },
      );
      await sync.start(pullFirst: false);
      final pushing = sync.flush();
      final firstPull = sync.pullNow();
      final secondPull = sync.pullNow();
      await pushStarted.future;

      var disposed = false;
      final disposing = sync.dispose().then((_) => disposed = true);
      await Future<void>.delayed(Duration.zero);
      expect(disposed, isFalse);
      expect(pushes, 1);
      expect(
        pulls,
        0,
        reason: 'a pull cannot replace an in-flight push baseline',
      );
      pushFinished.complete(true);
      await Future.wait([pushing, pullStarted.future]);
      expect(pulls, 1);
      expect(disposed, isFalse);
      pullFinished.complete();
      await Future.wait([firstPull, secondPull, disposing]);
      expect(disposed, isTrue);

      await sync.start();
      await sync.pullNow();
      await sync.flush();
      changes.add(null);
      settingsChanges.add(null);
      remoteChanges.add(null);
      await Future<void>.delayed(Duration.zero);
      expect(pulls, 1);
      expect(pushes, 1);
    },
  );

  test('flush waits for an earlier push and sends its later local changes', () {
    fakeAsync((async) {
      final finished = <Completer<bool>>[];
      final sync = build(
        push: () {
          pushes++;
          final operation = Completer<bool>();
          finished.add(operation);
          return operation.future;
        },
      );
      sync.start(pullFirst: false);
      async.flushMicrotasks();
      sync.flush();
      async.flushMicrotasks();
      expect(pushes, 1);
      changes.add(null);
      async.flushMicrotasks();
      var flushed = false;
      sync.flush().then((_) => flushed = true);
      async.flushMicrotasks();
      expect(pushes, 1);
      expect(flushed, isFalse);

      finished.first.complete(true);
      async.flushMicrotasks();
      expect(pushes, 2);
      expect(flushed, isFalse);
      finished.last.complete(true);
      async.flushMicrotasks();
      expect(flushed, isTrue);
      sync.dispose();
    });
  });
}
