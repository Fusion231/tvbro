import 'dart:async';

/// Relative input is accumulated against the user's pending target, rather
/// than the last (possibly delayed) decoder position. Only one seek is sent at
/// a time; inputs arriving during it replace the queued target.
class PlaybackSeekController {
  PlaybackSeekController({
    required this.position,
    required this.duration,
    required this.seek,
    this.onError,
    this.settleDelay = const Duration(milliseconds: 80),
    this.confirmTimeout = const Duration(seconds: 2),
  });

  final Duration Function() position;
  final Duration Function() duration;
  final Future<void> Function(Duration) seek;
  final void Function(Object)? onError;
  final Duration settleDelay;
  final Duration confirmTimeout;
  Duration? _target;
  Duration? _sentTarget;
  Timer? _timer;
  Completer<void>? _confirmation;
  Timer? _deadline;
  bool _running = false;
  bool _disposed = false;
  int _revision = 0;

  Duration? get pendingTarget => _target;

  void relative(Duration delta) => absolute((_target ?? position()) + delta);

  void absolute(Duration value) {
    if (_disposed) return;
    final end = duration();
    _target = value < Duration.zero
        ? Duration.zero
        : end > Duration.zero && value > end
        ? end
        : value;
    _revision++;
    _timer?.cancel();
    _timer = Timer(settleDelay, _drain);
  }

  /// A command future can complete before the decoder/network seek does.
  /// Wait for its position acknowledgement before issuing another command.
  void confirm(Duration value) {
    final sent = _sentTarget;
    if (sent != null && (value - sent).abs() <= const Duration(seconds: 1)) {
      final confirmation = _confirmation;
      if (confirmation != null && !confirmation.isCompleted) {
        confirmation.complete();
      }
    }
  }

  Future<void> _drain() async {
    _timer = null;
    if (_disposed || _running || _target == null) return;
    _running = true;
    final revision = _revision;
    final target = _target!;
    _sentTarget = target;
    final confirmation = _confirmation = Completer<void>();
    final deadline = _deadline = Timer(confirmTimeout, () {
      if (!confirmation.isCompleted) confirmation.complete();
    });
    try {
      await Future.any([seek(target), confirmation.future]);
      confirm(position());
      await confirmation.future;
    } catch (error) {
      onError?.call(error);
    } finally {
      deadline.cancel();
      if (identical(_deadline, deadline)) _deadline = null;
      _running = false;
      _sentTarget = null;
      if (identical(_confirmation, confirmation)) _confirmation = null;
      if (!_disposed && revision != _revision) {
        // A still-armed timer preserves the last input's debounce interval.
        _timer ??= Timer(Duration.zero, _drain);
      } else if (revision == _revision) {
        _target = null;
      }
    }
  }

  void reset() {
    _revision++;
    _timer?.cancel();
    _timer = null;
    _deadline?.cancel();
    _deadline = null;
    _target = null;
    _sentTarget = null;
    final confirmation = _confirmation;
    if (confirmation != null && !confirmation.isCompleted) {
      confirmation.complete();
    }
    _confirmation = null;
  }

  void dispose() {
    _disposed = true;
    reset();
  }
}
