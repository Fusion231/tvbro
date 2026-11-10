import 'package:flutter/foundation.dart';

import 'dvr_models.dart';

enum DvrScheduleStatus {
  scheduled,
  starting,
  recording,
  completed,
  interrupted,
  missed,
  failed,
  cancelled,
  conflict,
}

/// A device-local occurrence. It never contains a provider locator or headers.
@immutable
class DvrSchedule {
  const DvrSchedule({
    required this.id,
    required this.sourceId,
    required this.channelId,
    required this.channelName,
    required this.startsAt,
    required this.endsAt,
    this.programmeTitle,
    this.startPadding = Duration.zero,
    this.endPadding = Duration.zero,
    this.repeatWeekdays = const {},
    this.seriesId,
    this.status = DvrScheduleStatus.scheduled,
    this.recordingId,
    this.error,
    this.startedLate = false,
    this.profileId,
  });

  final String id;
  final String sourceId;
  final String channelId;
  final String channelName;
  final String? programmeTitle;
  final DateTime startsAt;
  final DateTime endsAt;
  final Duration startPadding;
  final Duration endPadding;

  /// Local calendar weekdays (Monday = 1), preserving wall time across DST.
  final Set<int> repeatWeekdays;
  final String? seriesId;
  final DvrScheduleStatus status;
  final String? recordingId;
  final String? error;
  final bool startedLate;
  final String? profileId;

  DateTime get captureStart => startsAt.subtract(startPadding);
  DateTime get captureEnd => endsAt.add(endPadding);
  bool get isRecurring => repeatWeekdays.isNotEmpty;
  bool get isActive =>
      status == DvrScheduleStatus.starting ||
      status == DvrScheduleStatus.recording;
  bool get isPending => status == DvrScheduleStatus.scheduled || isActive;
  String get title =>
      programmeTitle?.trim().isNotEmpty == true ? programmeTitle! : channelName;

  bool overlaps(DvrSchedule other) =>
      captureStart.isBefore(other.captureEnd) &&
      other.captureStart.isBefore(captureEnd);

  void validate() {
    if (id.isEmpty ||
        sourceId.isEmpty ||
        channelId.isEmpty ||
        channelName.trim().isEmpty ||
        !startsAt.isBefore(endsAt) ||
        endsAt.difference(startsAt) > const Duration(hours: 24) ||
        startPadding < Duration.zero ||
        startPadding > const Duration(hours: 2) ||
        endPadding < Duration.zero ||
        endPadding > const Duration(hours: 2) ||
        repeatWeekdays.any((day) => day < 1 || day > 7)) {
      throw const DvrException('Choose a valid recording time and padding.');
    }
  }

  DvrSchedule copyWith({
    DvrScheduleStatus? status,
    String? recordingId,
    String? error,
    bool? startedLate,
  }) => DvrSchedule(
    id: id,
    sourceId: sourceId,
    channelId: channelId,
    channelName: channelName,
    programmeTitle: programmeTitle,
    startsAt: startsAt,
    endsAt: endsAt,
    startPadding: startPadding,
    endPadding: endPadding,
    repeatWeekdays: repeatWeekdays,
    seriesId: seriesId,
    status: status ?? this.status,
    recordingId: recordingId ?? this.recordingId,
    error: error ?? this.error,
    startedLate: startedLate ?? this.startedLate,
    profileId: profileId,
  );

  /// Finds the next occurrence after [after], skipping fully missed days. The
  /// end is rebuilt from local calendar fields rather than adding 24h at DST.
  DvrSchedule? nextOccurrence(String nextId, DateTime after) {
    if (!isRecurring) return null;
    final start = startsAt.toLocal();
    final end = endsAt.toLocal();
    final endDayOffset = DateTime.utc(
      end.year,
      end.month,
      end.day,
    ).difference(DateTime.utc(start.year, start.month, start.day)).inDays;
    final localAfter = after.toLocal();
    for (var day = 0; day <= 7; day++) {
      final nextStart = DateTime(
        localAfter.year,
        localAfter.month,
        localAfter.day + day,
        start.hour,
        start.minute,
        start.second,
        start.millisecond,
        start.microsecond,
      );
      if (!repeatWeekdays.contains(nextStart.weekday) ||
          !nextStart.isAfter(startsAt) ||
          !nextStart.subtract(startPadding).isAfter(after)) {
        continue;
      }
      return DvrSchedule(
        id: nextId,
        seriesId: seriesId ?? id,
        sourceId: sourceId,
        channelId: channelId,
        channelName: channelName,
        programmeTitle: programmeTitle,
        startsAt: nextStart,
        endsAt: DateTime(
          nextStart.year,
          nextStart.month,
          nextStart.day + endDayOffset,
          end.hour,
          end.minute,
          end.second,
          end.millisecond,
          end.microsecond,
        ),
        startPadding: startPadding,
        endPadding: endPadding,
        repeatWeekdays: repeatWeekdays,
        profileId: profileId,
      );
    }
    return null;
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'sourceId': sourceId,
    'channelId': channelId,
    'channelName': channelName,
    'programmeTitle': programmeTitle,
    'startsAt': startsAt.toUtc().toIso8601String(),
    'endsAt': endsAt.toUtc().toIso8601String(),
    'startPaddingMs': startPadding.inMilliseconds,
    'endPaddingMs': endPadding.inMilliseconds,
    'repeatWeekdays': repeatWeekdays.toList()..sort(),
    'seriesId': seriesId,
    'status': status.name,
    'recordingId': recordingId,
    'error': error,
    'startedLate': startedLate,
    'profileId': profileId,
  };

  factory DvrSchedule.fromJson(Map<String, dynamic> json) {
    final result = DvrSchedule(
      id: json['id'] as String,
      sourceId: json['sourceId'] as String,
      channelId: json['channelId'] as String,
      channelName: json['channelName'] as String,
      programmeTitle: json['programmeTitle'] as String?,
      startsAt: DateTime.parse(json['startsAt'] as String).toLocal(),
      endsAt: DateTime.parse(json['endsAt'] as String).toLocal(),
      startPadding: Duration(
        milliseconds: (json['startPaddingMs'] as num?)?.toInt() ?? 0,
      ),
      endPadding: Duration(
        milliseconds: (json['endPaddingMs'] as num?)?.toInt() ?? 0,
      ),
      repeatWeekdays: Set.unmodifiable(
        (json['repeatWeekdays'] as List? ?? const []).map(
          (value) => (value as num).toInt(),
        ),
      ),
      seriesId: json['seriesId'] as String?,
      status: DvrScheduleStatus.values.byName(json['status'] as String),
      recordingId: json['recordingId'] as String?,
      error: json['error'] as String?,
      startedLate: json['startedLate'] == true,
      profileId: json['profileId'] as String?,
    );
    result.validate();
    return result;
  }
}
