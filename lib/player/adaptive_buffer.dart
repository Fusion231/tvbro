import 'buffer_preset.dart';

/// Bounded feedback policy for the per-channel Auto buffer choice.
///
/// It reacts only to playback stalls and observed buffered media. It does not
/// estimate network bandwidth or select a video rendition. One confirmed
/// stall or a burst of three short stalls raises the preset one step; healthy playback
/// with a usable cushion lowers it one step. The effective range is therefore
/// always Small through Extra large, whose largest buffer is already bounded
/// by each engine.
class AdaptiveBufferPolicy {
  AdaptiveBufferPolicy({BufferPreset initial = BufferPreset.normal}) {
    reset(initial: initial);
  }

  static const int stallPromotionDelayMs = 1000;
  static const int shortStallWindowMs = 30000;
  static const int shortStallCount = 3;
  static const int adjustmentCooldownMs = 15000;
  static const int stablePlaybackBeforeReductionMs = 90000;
  static const int minimumHealthyBufferAheadMs = 10000;

  BufferPreset _effectivePreset = BufferPreset.normal;
  final List<int> _recentStalls = [];
  bool _started = false;
  bool _stallAdjusted = false;
  int? _stallSinceMs;
  int? _lastAdjustmentMs;
  int? _healthySinceMs;

  BufferPreset get effectivePreset => _effectivePreset;

  /// Starts a new stream's adaptation window at [initial].
  ///
  /// Reconnects should keep the current preset and call [observe] as usual;
  /// channel changes should reset to Normal so one provider/channel does not
  /// inherit another's network history.
  void reset({BufferPreset initial = BufferPreset.normal}) {
    _effectivePreset = initial;
    _recentStalls.clear();
    _started = false;
    _stallAdjusted = false;
    _stallSinceMs = null;
    _lastAdjustmentMs = null;
    _healthySinceMs = null;
  }

  /// Clears elapsed observations while preserving the selected tier.
  ///
  /// Use this when playback temporarily moves to a local/non-network source,
  /// such as DVR. The next live sample starts a fresh healthy window, so time
  /// spent outside live playback cannot trigger a reduction.
  void resetObservationWindow() {
    _recentStalls.clear();
    _started = false;
    _stallAdjusted = false;
    _stallSinceMs = null;
    _healthySinceMs = null;
  }

  /// Samples engine state and returns a changed effective preset, if any.
  ///
  /// Startup buffering is ignored until playback has begun. A single stall can
  /// promote at most one level, and a stable window can demote at most one
  /// level, so polling cadence and long buffering episodes cannot create a
  /// preset-change storm alongside the reconnect watchdog.
  BufferPreset? observe({
    required int nowMs,
    required bool playing,
    required bool buffering,
    required bool ended,
    required int bufferAheadMs,
  }) {
    if (ended) {
      _recentStalls.clear();
      _started = false;
      _stallAdjusted = false;
      _stallSinceMs = null;
      _healthySinceMs = null;
      return null;
    }

    if (!_started) {
      if (playing && !buffering) {
        _started = true;
        if (bufferAheadMs >= minimumHealthyBufferAheadMs) {
          _healthySinceMs = nowMs;
        }
      }
      return null;
    }

    if (buffering) {
      _healthySinceMs = null;
      _recentStalls.removeWhere((at) => nowMs - at > shortStallWindowMs);
      if (_stallSinceMs == null) {
        _stallSinceMs = nowMs;
        _recentStalls.add(nowMs);
      }
      if (!_stallAdjusted &&
          (nowMs - _stallSinceMs! >= stallPromotionDelayMs ||
              _recentStalls.length >= shortStallCount) &&
          _cooldownElapsed(nowMs)) {
        final promoted = _stepUp();
        if (promoted != null) {
          _recentStalls.clear();
          _stallAdjusted = true;
          _lastAdjustmentMs = nowMs;
          return promoted;
        }
      }
      return null;
    }

    _stallSinceMs = null;
    _stallAdjusted = false;
    if (!playing || bufferAheadMs < minimumHealthyBufferAheadMs) {
      _healthySinceMs = null;
      return null;
    }

    _healthySinceMs ??= nowMs;
    if (nowMs - _healthySinceMs! < stablePlaybackBeforeReductionMs ||
        !_cooldownElapsed(nowMs)) {
      return null;
    }
    final reduced = _stepDown();
    if (reduced == null) return null;
    _healthySinceMs = nowMs;
    _lastAdjustmentMs = nowMs;
    return reduced;
  }

  bool _cooldownElapsed(int nowMs) =>
      _lastAdjustmentMs == null ||
      nowMs - _lastAdjustmentMs! >= adjustmentCooldownMs;

  BufferPreset? _stepUp() {
    final nextIndex = _effectivePreset.index + 1;
    if (nextIndex >= BufferPreset.values.length) return null;
    _effectivePreset = BufferPreset.values[nextIndex];
    return _effectivePreset;
  }

  BufferPreset? _stepDown() {
    final nextIndex = _effectivePreset.index - 1;
    if (nextIndex < 0) return null;
    _effectivePreset = BufferPreset.values[nextIndex];
    return _effectivePreset;
  }
}
