import 'dart:async';

import 'diagnostics_log.dart';
import 'cloud_profile_change.dart';
import 'net.dart';

/// Keeps the paired profile in step with the cloud without manual syncing.
///
/// **Pull is safe, push is a delta.** A pull only ever mirrors the profile, so
/// it runs on app start and on profile switch. A push carries only what changed
/// locally (`push_favorites_delta`), which is what makes running it
/// automatically safe at all: the whole-set `push_favorites` would let two
/// devices on their own schedules erase each other's additions, because a
/// missing element and a deletion look identical in a full set.
///
/// **No revision guard, deliberately.** An earlier design pushed the whole set
/// and compared `profiles.updated_at` to detect an intervening change. The
/// delta merge makes that unnecessary rather than merely cheaper: the server
/// applies each row under the profile's row lock, so concurrent pushes
/// serialise and two devices can only conflict on the *same* favorite — where
/// "whichever arrived last" is the answer a revision check would have given
/// anyway.
///
/// Pushes are debounced: favoriting five channels in a row is one round trip,
/// not five. The debounce also keeps this well inside the server's 30-per-minute
/// push budget, which auto-pushing shares with manual pushes rather than
/// getting a budget of its own.
/// Playback changes use a separate two-minute timer and flush after a durable
/// sleep/exit checkpoint. They share the same serialized operation queue.
class CloudAutoSync {
  /// Mirrors the profile into the local cache. Failures are logged and retried
  /// after [retryDelay], without holding up launch or resume.
  final Future<void> Function() pull;

  /// Sends pending local changes as deltas. Returns true when it sent anything.
  final Future<bool> Function() push;

  /// User changes only; applying a cloud pull must not emit into this stream.
  final Stream<void> changes;

  /// Additional local settings streams share the same push debounce.
  final Iterable<Stream<void>> additionalChanges;

  /// Remote changes and reconnects trigger a pull, independently of local writes.
  final Stream<void>? remoteChanges;

  /// Progress uses its own upload cadence and remote invalidations.
  final Future<bool> Function()? pushPlayback;
  final Future<void> Function()? pullPlayback;
  final Stream<void>? playbackChanges;
  final Stream<void>? urgentPlaybackChanges;
  final Stream<CloudProfileChange>? profileChanges;
  final Duration playbackInterval;

  final Duration debounce;
  final Duration remoteDebounce;

  /// Flush ordinary favorites/settings edits completed after backgrounding.
  /// Playback checkpoints use their separate interval and urgent stream.
  final bool Function()? shouldFlushImmediately;

  /// Backoff after a failed push. A failure is usually the network or a rate
  /// limit, and the change is still in the outbox, so retrying soon is both
  /// safe and pointless to hurry.
  final Duration retryDelay;
  final DateTime Function() _now;

  CloudAutoSync({
    required this.pull,
    required this.push,
    required this.changes,
    this.additionalChanges = const [],
    this.remoteChanges,
    this.pushPlayback,
    this.pullPlayback,
    this.playbackChanges,
    this.urgentPlaybackChanges,
    this.profileChanges,
    this.playbackInterval = const Duration(minutes: 2),
    this.shouldFlushImmediately,
    this.debounce = const Duration(seconds: 5),
    Duration? remoteDebounce,
    this.retryDelay = const Duration(seconds: 30),
    DateTime Function()? now,
  }) : remoteDebounce = remoteDebounce ?? debounce,
       _now = now ?? DateTime.now;

  StreamSubscription<void>? _sub;
  List<StreamSubscription<void>>? _additionalSubs;
  StreamSubscription<void>? _remoteSub;
  StreamSubscription<void>? _playbackSub;
  StreamSubscription<void>? _urgentPlaybackSub;
  StreamSubscription<CloudProfileChange>? _profileSub;
  Timer? _playbackTimer;
  Timer? _urgentPlaybackTimer;
  bool _playbackPending = false;
  bool _playbackQueued = false;
  Timer? _pushTimer;
  Timer? _pushRetryTimer;
  Timer? _pullTimer;
  Timer? _pullRetryTimer;
  int _pushOperations = 0;
  int _queuedOperations = 0;
  bool _pendingWhilePushing = false;
  bool _remotePullQueued = false;
  bool _remotePullAgain = false;
  bool _remotePullFull = false;
  bool _disposed = false;
  Future<void> _operations = Future<void>.value();
  Future<void>? _immediatePull;
  DateTime? _lastFullPullAt;

  /// True while cloud work is scheduled, queued or running.
  bool get busy =>
      _pushTimer != null ||
      _pushRetryTimer != null ||
      _pullTimer != null ||
      _pullRetryTimer != null ||
      _urgentPlaybackTimer != null ||
      _queuedOperations > 0;

  /// Begins listening for local changes. [pullFirst] mirrors the profile once
  /// before doing so, which is what makes a fresh install or a device that has
  /// been away pick up the other devices' favorites.
  Future<void> start({bool pullFirst = true}) async {
    if (_disposed) return;
    _sub ??= changes.listen((_) => _schedule());
    _additionalSubs ??= [
      for (final stream in additionalChanges) stream.listen((_) => _schedule()),
    ];
    // Listen before the initial read so an edit made while it is in flight
    // schedules a fresh read rather than falling into a subscription gap.
    _remoteSub ??= remoteChanges?.listen((_) => _schedulePull());
    _profileSub ??= profileChanges?.listen(
      (change) =>
          _schedulePull(playbackOnly: change == CloudProfileChange.playback),
    );
    _playbackSub ??= playbackChanges?.listen((_) => _playbackPending = true);
    _urgentPlaybackSub ??= urgentPlaybackChanges?.listen(
      (_) => _scheduleUrgentPlayback(),
    );
    if (pushPlayback != null) {
      _playbackPending = true;
      _playbackTimer ??= Timer.periodic(
        playbackInterval,
        (_) => unawaited(_flushPlayback()),
      );
    }
    if (pullFirst) await pullNow();
    // A device that was offline when the user last toggled something still has
    // it queued; send it once the pull has established a baseline.
    _schedule();
  }

  Future<void> pullNow({bool onResume = false}) {
    if (_disposed) return Future<void>.value();
    final pending = _immediatePull;
    if (pending != null) return pending;
    if (onResume && _pullRetryTimer != null) return Future<void>.value();
    // Short Activity transitions and repeated foreground notifications do not
    // need another full snapshot. Explicit pulls and remote events stay fresh.
    if (onResume &&
        _lastFullPullAt != null &&
        _now().difference(_lastFullPullAt!) < const Duration(seconds: 30)) {
      return Future<void>.value();
    }
    _pullTimer?.cancel();
    _pullTimer = null;
    _pullRetryTimer?.cancel();
    _pullRetryTimer = null;
    _remotePullFull = false;
    late final Future<void> operation;
    operation = _enqueue(_pull).whenComplete(() {
      if (identical(_immediatePull, operation)) _immediatePull = null;
    });
    return _immediatePull = operation;
  }

  /// A pull replaces local state, so it must not race a push reading that state
  /// or acknowledging its outbox. Accepted operations also drain on dispose.
  Future<void> _enqueue(Future<void> Function() operation) {
    _queuedOperations++;
    return _operations = _operations.then((_) async {
      try {
        await operation();
      } finally {
        _queuedOperations--;
      }
    });
  }

  Future<void> _pull({bool playbackOnly = false}) async {
    try {
      if (playbackOnly && pullPlayback != null) {
        await pullPlayback!();
      } else {
        await pull();
        _lastFullPullAt = _now();
      }
      _pullRetryTimer?.cancel();
      _pullRetryTimer = null;
    } catch (error) {
      // Never rethrow into whatever triggered the sync (app start, a profile
      // switch): the app works offline, and a failed mirror is not a failed
      // launch.
      DiagnosticsLog.instance.add(
        'cloud',
        'auto-sync pull failed, will retry: ${redactText('$error')}',
      );
      if (!_disposed) {
        _remotePullFull = _remotePullFull || !playbackOnly;
        _pullRetryTimer?.cancel();
        _pullRetryTimer = Timer(retryDelay, _pullRemote);
      }
    }
  }

  void _schedulePull({bool playbackOnly = false}) {
    if (_disposed) return;
    _remotePullFull = _remotePullFull || !playbackOnly;
    _pullRetryTimer?.cancel();
    _pullRetryTimer = null;
    if (_remotePullQueued) {
      _remotePullAgain = true;
      return;
    }
    _pullTimer?.cancel();
    _pullTimer = Timer(remoteDebounce, _pullRemote);
  }

  Future<void> _pullRemote() async {
    _pullTimer?.cancel();
    _pullTimer = null;
    _pullRetryTimer?.cancel();
    _pullRetryTimer = null;
    if (_disposed) return;
    if (_remotePullQueued) {
      _remotePullAgain = true;
      return;
    }
    _remotePullQueued = true;
    final playbackOnly = !_remotePullFull;
    _remotePullFull = false;
    try {
      await _enqueue(() => _pull(playbackOnly: playbackOnly));
    } finally {
      _remotePullQueued = false;
      if (_remotePullAgain && !_disposed) {
        _remotePullAgain = false;
        _schedulePull(playbackOnly: !_remotePullFull);
      }
    }
  }

  void _scheduleUrgentPlayback() {
    if (_disposed || pushPlayback == null) return;
    _playbackPending = true;
    _urgentPlaybackTimer?.cancel();
    _urgentPlaybackTimer = Timer(Duration.zero, () {
      _urgentPlaybackTimer = null;
      unawaited(_flushPlayback(urgent: true));
    });
  }

  Future<void> _flushPlayback({bool urgent = false}) async {
    if (_disposed || pushPlayback == null || !_playbackPending) return;
    if (_playbackQueued) {
      if (urgent) {
        await _operations;
        await _flushPlayback(urgent: true);
      }
      return;
    }
    _playbackQueued = true;
    _playbackPending = false;
    try {
      await _enqueue(() async {
        try {
          await pushPlayback!();
        } catch (error) {
          _playbackPending = true;
          DiagnosticsLog.instance.add(
            'cloud',
            'auto-sync playback push failed, will retry: ${redactText('$error')}',
          );
        }
      });
    } finally {
      _playbackQueued = false;
    }
  }

  void _schedule() {
    if (_disposed) return;
    if (_pushOperations > 0) {
      // Coalesce into one follow-up rather than stacking timers behind the
      // in-flight push.
      _pendingWhilePushing = true;
      return;
    }
    _pushTimer?.cancel();
    _pushRetryTimer?.cancel();
    _pushRetryTimer = null;
    _pushTimer = Timer(
      shouldFlushImmediately?.call() == true ? Duration.zero : debounce,
      _flush,
    );
  }

  Future<void> _flush() async {
    _pushTimer = null;
    _pushRetryTimer = null;
    if (_disposed) return;
    _pendingWhilePushing = false;
    _pushOperations++;
    try {
      await _enqueue(_push);
    } finally {
      _pushOperations--;
      if (_pushOperations == 0 && _pendingWhilePushing && !_disposed) {
        _pendingWhilePushing = false;
        _schedule();
      }
    }
  }

  Future<void> _push() async {
    try {
      await push();
      _pushRetryTimer?.cancel();
      _pushRetryTimer = null;
    } catch (error) {
      DiagnosticsLog.instance.add(
        'cloud',
        'auto-sync push failed, will retry: ${redactText('$error')}',
      );
      // The change is still in the outbox; a later trigger or this retry sends
      // it. Nothing is lost by failing here.
      if (!_disposed) {
        _pushRetryTimer?.cancel();
        _pushRetryTimer = Timer(retryDelay, _flush);
      }
    }
  }

  /// Sends anything pending right now, bypassing the debounce — for app
  /// backgrounding or a profile switch, where waiting out the timer would mean
  /// the change is still sitting in the outbox when the profile changes under
  /// it.
  Future<void> flush() async {
    _pushTimer?.cancel();
    _pushTimer = null;
    _pushRetryTimer?.cancel();
    _pushRetryTimer = null;
    await _flush();
    await _flushPlayback(urgent: true);
  }

  /// Stops scheduling work and waits for ongoing cloud reads/writes before the
  /// caller replaces local state or closes its database.
  Future<void> dispose() async {
    _disposed = true;
    _pushTimer?.cancel();
    _pushTimer = null;
    _pushRetryTimer?.cancel();
    _pushRetryTimer = null;
    _pullTimer?.cancel();
    _pullTimer = null;
    _pullRetryTimer?.cancel();
    _pullRetryTimer = null;
    _playbackTimer?.cancel();
    _playbackTimer = null;
    _urgentPlaybackTimer?.cancel();
    _urgentPlaybackTimer = null;
    final cancellations = <Future<void>>[
      if (_sub case final sub?) sub.cancel(),
      for (final sub in _additionalSubs ?? <StreamSubscription<void>>[])
        sub.cancel(),
      if (_remoteSub case final sub?) sub.cancel(),
      if (_playbackSub case final sub?) sub.cancel(),
      if (_urgentPlaybackSub case final sub?) sub.cancel(),
      if (_profileSub case final sub?) sub.cancel(),
    ];
    _sub = null;
    _additionalSubs = null;
    _remoteSub = null;
    _playbackSub = null;
    _urgentPlaybackSub = null;
    _profileSub = null;
    await Future.wait(cancellations);
    await _operations;
  }
}
