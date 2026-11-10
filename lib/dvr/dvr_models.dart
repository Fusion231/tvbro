import 'package:flutter/foundation.dart';

enum DvrCaptureState { starting, buffering, stopped, failed }

enum DvrRecordingStatus { recording, completed, interrupted, failed }

/// Local limits. Saved recordings are never automatically deleted for space.
@immutable
class DvrSettings {
  const DvrSettings({
    this.maxBufferDuration = const Duration(minutes: 30),
    this.maxBufferBytes = 1024 * 1024 * 1024,
    this.maxRecordingsBytes = 10 * 1024 * 1024 * 1024,
  });

  final Duration maxBufferDuration;
  final int maxBufferBytes;
  final int maxRecordingsBytes;

  DvrSettings copyWith({
    Duration? maxBufferDuration,
    int? maxBufferBytes,
    int? maxRecordingsBytes,
  }) => DvrSettings(
    maxBufferDuration: maxBufferDuration ?? this.maxBufferDuration,
    maxBufferBytes: maxBufferBytes ?? this.maxBufferBytes,
    maxRecordingsBytes: maxRecordingsBytes ?? this.maxRecordingsBytes,
  );

  Map<String, Object> toJson() => {
    'maxBufferMilliseconds': maxBufferDuration.inMilliseconds,
    'maxBufferBytes': maxBufferBytes,
    'maxRecordingsBytes': maxRecordingsBytes,
  };

  factory DvrSettings.fromJson(Map<String, dynamic> json) => DvrSettings(
    maxBufferDuration: Duration(
      milliseconds: (json['maxBufferMilliseconds'] as num?)?.toInt() ?? 1800000,
    ),
    maxBufferBytes:
        (json['maxBufferBytes'] as num?)?.toInt() ?? 1024 * 1024 * 1024,
    maxRecordingsBytes:
        (json['maxRecordingsBytes'] as num?)?.toInt() ??
        10 * 1024 * 1024 * 1024,
  );

  void validate() {
    if (maxBufferDuration < const Duration(seconds: 10) ||
        maxBufferDuration > const Duration(hours: 24) ||
        maxBufferBytes < 1024 * 1024 ||
        maxRecordingsBytes < 1024 * 1024) {
      throw const DvrException('Choose a valid local storage limit.');
    }
  }
}

@immutable
class DvrSnapshot {
  const DvrSnapshot({
    this.bufferStart = Duration.zero,
    this.bufferEnd = Duration.zero,
    this.bytes = 0,
    this.state = DvrCaptureState.starting,
    this.error,
    this.reconnecting = false,
    this.retryAttempt = 0,
  });

  /// Absolute capture time, retained across moving HLS windows.
  final Duration bufferStart;
  final Duration bufferEnd;
  final int bytes;
  final DvrCaptureState state;
  final String? error;
  final bool reconnecting;
  final int retryAttempt;

  Duration get bufferedDuration => bufferEnd - bufferStart;
}

/// Metadata deliberately contains neither provider URLs nor HTTP headers.
@immutable
class DvrRecording {
  const DvrRecording({
    required this.id,
    required this.channelName,
    required this.startedAt,
    required this.status,
    this.programmeTitle,
    this.sourceId,
    this.channelId,
    this.endedAt,
    this.duration = Duration.zero,
    this.bytes = 0,
    this.error,
    this.scheduleId,
    this.hasGaps = false,
  });

  final String id;
  final String channelName;
  final String? programmeTitle;
  final String? sourceId;
  final String? channelId;
  final DateTime startedAt;
  final DateTime? endedAt;
  final Duration duration;
  final int bytes;
  final DvrRecordingStatus status;
  final String? error;
  final String? scheduleId;
  final bool hasGaps;

  bool get hasMedia => bytes > 0 && duration > Duration.zero;

  DvrRecording copyWith({
    DateTime? endedAt,
    Duration? duration,
    int? bytes,
    DvrRecordingStatus? status,
    String? error,
    bool? hasGaps,
  }) => DvrRecording(
    id: id,
    channelName: channelName,
    programmeTitle: programmeTitle,
    sourceId: sourceId,
    channelId: channelId,
    startedAt: startedAt,
    endedAt: endedAt ?? this.endedAt,
    duration: duration ?? this.duration,
    bytes: bytes ?? this.bytes,
    status: status ?? this.status,
    error: error ?? this.error,
    scheduleId: scheduleId,
    hasGaps: hasGaps ?? this.hasGaps,
  );

  Map<String, Object?> toJson() => {
    'version': 1,
    'id': id,
    'channelName': channelName,
    'programmeTitle': programmeTitle,
    'sourceId': sourceId,
    'channelId': channelId,
    'startedAt': startedAt.toUtc().toIso8601String(),
    'endedAt': endedAt?.toUtc().toIso8601String(),
    'durationMilliseconds': duration.inMilliseconds,
    'bytes': bytes,
    'status': status.name,
    'error': error,
    'scheduleId': scheduleId,
    'hasGaps': hasGaps,
  };

  factory DvrRecording.fromJson(Map<String, dynamic> json) => DvrRecording(
    id: json['id'] as String,
    channelName: json['channelName'] as String,
    programmeTitle: json['programmeTitle'] as String?,
    sourceId: json['sourceId'] as String?,
    channelId: json['channelId'] as String?,
    startedAt: DateTime.parse(json['startedAt'] as String).toLocal(),
    endedAt: json['endedAt'] == null
        ? null
        : DateTime.parse(json['endedAt'] as String).toLocal(),
    duration: Duration(
      milliseconds: (json['durationMilliseconds'] as num?)?.toInt() ?? 0,
    ),
    bytes: (json['bytes'] as num?)?.toInt() ?? 0,
    status: DvrRecordingStatus.values.byName(json['status'] as String),
    error: json['error'] as String?,
    scheduleId: json['scheduleId'] as String?,
    hasGaps: json['hasGaps'] == true,
  );
}

/// Safe, fixed user-facing messages only; underlying socket/URL errors may
/// contain provider credentials and must not be interpolated here.
class DvrException implements Exception {
  const DvrException(this.message);
  final String message;

  @override
  String toString() => message;
}
