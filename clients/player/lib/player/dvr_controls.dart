/// The locally saved live window shown by all fullscreen player surfaces.
/// Positions are absolute offsets from the start of this capture, never the
/// player's moving HLS window or its in-memory network cache.
class DvrControls {
  final bool available;
  final bool active;
  final bool busy;
  final bool recording;
  final Duration start;
  final Duration end;
  final Duration position;
  final String message;

  const DvrControls({
    this.available = false,
    this.active = false,
    this.busy = false,
    this.recording = false,
    this.start = Duration.zero,
    this.end = Duration.zero,
    this.position = Duration.zero,
    this.message = '',
  });

  Duration get length => end > start ? end - start : Duration.zero;

  Duration positionFromPlayback(
    Duration relative, {
    required Duration origin,
    required bool paused,
  }) => paused ? position : clamp(origin + relative);

  Duration clamp(Duration value) => value < start
      ? start
      : value > end
      ? end
      : value;

  double get fraction => length.inMilliseconds == 0
      ? 0
      : ((clamp(position) - start).inMilliseconds / length.inMilliseconds)
            .clamp(0.0, 1.0);

  Duration positionAt(double fraction) =>
      start +
      Duration(
        milliseconds: (length.inMilliseconds * fraction.clamp(0.0, 1.0))
            .round(),
      );

  Map<String, Object> toPayload() => {
    'dvrAvailable': available,
    'dvrActive': active,
    'dvrBusy': busy,
    'dvrRecording': recording,
    'dvrStartMs': start.inMilliseconds,
    'dvrEndMs': end.inMilliseconds,
    'dvrPositionMs': clamp(position).inMilliseconds,
    'dvrMessage': message,
  };
}
