import 'dart:async';

import 'diagnostics_log.dart';
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

  final Duration debounce;
  final Duration remoteDebounce;

  /// Backoff after a failed push. A failure is usually the network or a rate
  /// limit, and the change is still in the outbox, so retrying soon is both
  /// safe and pointless to hurry.
  final Duration retryDelay;

  CloudAutoSync({
    required this.pull,
    required this.push,
    required this.changes,
    this.additionalChanges = const [],
    this.remoteChanges,
    this.debounce = const Duration(seconds: 5),
    Duration? remoteDebounce,
    this.retryDelay = const Duration(seconds: 30),
  }) : remoteDebounce = remoteDebounce ?? debounce;

  StreamSubscription<void>? _sub;
  List<StreamSubscription<void>>? _additionalSubs;
  StreamSubscription<void>? _remoteSub;
  Timer? _pushTimer;
  Timer? _pushRetryTimer;
  Timer? _pullTimer;
  Timer? _pullRetryTimer;
  int _pushOperations = 0;
  int _queuedOperations = 0;
  bool _pendingWhilePushing = false;
  bool _remotePullQueued = false;
  bool _remotePullAgain = false;
  bool _disposed = false;
  Future<void> _operations = Future<void>.value();

  /// True while cloud work is scheduled, queued or running.
  bool get busy =>
      _pushTimer != null ||
      _pushRetryTimer != null ||
      _pullTimer != null ||
      _pullRetryTimer != null ||
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
    if (pullFirst) await pullNow();
    // A device that was offline when the user last toggled something still has
    // it queued; send it once the pull has established a baseline.
    _schedule();
  }

  Future<void> pullNow() async {
    if (_disposed) return;
    _pullTimer?.cancel();
    _pullTimer = null;
    _pullRetryTimer?.cancel();
    _pullRetryTimer = null;
    await _enqueue(_pull);
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

  Future<void> _pull() async {
    try {
      await pull();
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
        _pullRetryTimer?.cancel();
        _pullRetryTimer = Timer(retryDelay, _pullRemote);
      }
    }
  }

  void _schedulePull() {
    if (_disposed) return;
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
    try {
      await pullNow();
    } finally {
      _remotePullQueued = false;
      if (_remotePullAgain && !_disposed) {
        _remotePullAgain = false;
        _schedulePull();
      }
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
    _pushTimer = Timer(debounce, _flush);
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
    final cancellations = <Future<void>>[
      if (_sub case final sub?) sub.cancel(),
      for (final sub in _additionalSubs ?? <StreamSubscription<void>>[])
        sub.cancel(),
      if (_remoteSub case final sub?) sub.cancel(),
    ];
    _sub = null;
    _additionalSubs = null;
    _remoteSub = null;
    await Future.wait(cancellations);
    await _operations;
  }
}
