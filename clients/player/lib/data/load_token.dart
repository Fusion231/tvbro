import 'dart:async';

/// Cooperative cancellation for a repository load.
///
/// Two independent users, and they cancel for different reasons:
///
///  * `LibraryRepository.loadToken`, set by `LiveController`/
///    `MediaTabController` and additive to their generation guards. The
///    generation guard stops a stale result from being *published* to the UI;
///    this token stops a stale call from **overwriting a populated cache** —
///    note *overwriting*, not writing: a superseded load may still seed an
///    empty cache, because refusing to write at all left a slow device unable
///    to ever obtain a first one. See `LibraryRepository._loadChannels`.
///  * `EpgIngestCoordinator`'s own tokens, which it mints and cancels to hold
///    one guide refresh at a time app-wide. Those are what stop a superseded
///    refresh feeding more EPG batches. `loadToken` never reaches that path.
///
/// Most consumers only check the flag; queued HTTP work can also await the
/// lazily allocated cancellation signal instead of waiting for a free slot.
class LoadToken {
  bool _cancelled = false;
  Completer<void>? _cancellation;

  /// True until [cancel] is called.
  bool get isLive => !_cancelled;

  /// True once [cancel] has been called.
  bool get isCancelled => _cancelled;

  Future<void> get whenCancelled {
    final signal = _cancellation ??= Completer<void>();
    if (_cancelled && !signal.isCompleted) signal.complete();
    return signal.future;
  }

  /// Marks this token cancelled. Idempotent.
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _cancellation?.complete();
  }
}

/// Thrown by a cancellable batch stream (see `parseXmltvBatched`) when its
/// [LoadToken] is cancelled mid-stream, so an `await for` consumer — notably
/// `AppDatabase.replaceEpgStream` — sees an error and rolls back its
/// transaction, rather than silently ending the stream as if it had
/// completed the full guide. Not a real failure: callers should log this at
/// info level ("superseded"), never as a scary error.
class LoadCancelledException implements Exception {
  const LoadCancelledException();

  @override
  String toString() => 'LoadCancelledException: load superseded';
}
