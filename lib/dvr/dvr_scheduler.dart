import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/diagnostics_log.dart';
import '../data/distribution_channel.dart';
import '../data/supporter_access.dart';
import '../sources/source.dart';
import 'dvr_schedule.dart';
import 'dvr_service.dart';

export 'dvr_schedule.dart';

typedef DvrStreamResolver = Future<StreamInfo> Function(DvrSchedule schedule);
typedef DvrRecordingAuthorization = Future<bool> Function(DvrSchedule schedule);

/// Persisted device-local scheduling. A single timer observes the next boundary;
/// provider lookup and capture starts run outside the metadata mutation queue so
/// cancelling a stalled start is immediate. The app must remain running.
class DvrScheduler extends ChangeNotifier {
  DvrScheduler({
    required DvrService service,
    required Directory directory,
    DvrStreamResolver? resolveStream,
    DvrRecordingAuthorization? authorize,
    Future<bool> Function()? recurringAccess,
    DateTime Function()? now,
    Timer Function(Duration, void Function())? createTimer,
    // Public injectable parameter names deliberately differ from backing fields.
    // ignore: prefer_initializing_formals
  }) : _service = service,
       // ignore: prefer_initializing_formals
       _directory = directory,
       _resolver = resolveStream,
       // ignore: prefer_initializing_formals
       _authorize = authorize,
       _recurringAccess = recurringAccess ?? _supporterRecurringAccess,
       _now = now ?? DateTime.now,
       _createTimer = createTimer ?? Timer.new;

  DvrScheduler._()
    : _service = DvrService.instance,
      _directory = null,
      _recurringAccess = _supporterRecurringAccess,
      _now = DateTime.now,
      _createTimer = Timer.new;

  static final DvrScheduler instance = DvrScheduler._();
  final DvrService _service;
  Directory? _directory;
  final DateTime Function() _now;
  final Timer Function(Duration, void Function()) _createTimer;
  DvrStreamResolver? _resolver;
  DvrRecordingAuthorization? _authorize;
  final Future<bool> Function() _recurringAccess;

  static Future<bool> _supporterRecurringAccess() =>
      SupporterAccess.instance.allows(SupporterFeature.recurringRecordings);
  final Map<String, DvrSchedule> _schedules = {};
  final Set<Future<void>> _starts = {};
  final Set<String> _stoppingIds = {};
  Future<void>? _initializing;
  Future<void> _operations = Future.value();
  Timer? _timer;
  bool _closed = false;

  List<DvrSchedule> get schedules => List.unmodifiable(
    _schedules.values.toList()..sort((a, b) {
      if (a.isPending != b.isPending) return a.isPending ? -1 : 1;
      return a.isPending
          ? a.captureStart.compareTo(b.captureStart)
          : b.captureStart.compareTo(a.captureStart);
    }),
  );

  bool get canResolve => _resolver != null;

  void configureResolver(
    DvrStreamResolver resolver, {
    DvrRecordingAuthorization? authorize,
  }) {
    _resolver = resolver;
    _authorize = authorize;
    if (_initializing != null && !_closed) {
      _observe(refreshDue());
    }
  }

  Future<void> ensureInitialized() {
    if (_closed) throw const DvrException('The recording scheduler is closed.');
    return _initializing ??= _initialize();
  }

  Future<void> _initialize() async {
    await _service.ensureInitialized();
    _directory ??= Directory(
      p.join((await getApplicationSupportDirectory()).path, 'tvbro_dvr'),
    );
    await _directory!.create(recursive: true);
    final file = File(p.join(_directory!.path, 'schedules.json'));
    for (final candidate in [file, File('${file.path}.old')]) {
      if (!await candidate.exists()) continue;
      try {
        if (await candidate.length() > 8 * 1024 * 1024) continue;
        final json = jsonDecode(await candidate.readAsString()) as Map;
        if (json['version'] != 1) continue;
        for (final row in json['schedules'] as List) {
          try {
            final schedule = DvrSchedule.fromJson(
              Map<String, dynamic>.from(row as Map),
            );
            _schedules[schedule.id] = schedule;
          } catch (_) {
            DiagnosticsLog.instance.add('dvr', 'schedule_recovery_invalid_row');
          }
        }
        break;
      } catch (_) {
        DiagnosticsLog.instance.add('dvr', 'schedule_recovery_backup');
      }
    }
    // Service recovery has already validated saved media and marked any
    // process-death capture interrupted. Never silently restart that capture.
    for (final schedule in _schedules.values.toList()) {
      if (!schedule.isActive) continue;
      final recording = _recordingFor(schedule);
      if (recording?.status == DvrRecordingStatus.recording) continue;
      _finish(
        schedule,
        recording == null
            ? DvrScheduleStatus.interrupted
            : _statusFor(recording, schedule),
        recordingId: recording?.id,
        error:
            recording?.error ??
            'The app stopped while this scheduled recording was running.',
      );
    }
    if (_closed) return;
    _service.addListener(_onCaptureChanged);
    await _reconcile();
  }

  Future<DvrSchedule> schedule({
    required String sourceId,
    required String channelId,
    required String channelName,
    required DateTime startsAt,
    required DateTime endsAt,
    String? programmeTitle,
    Duration startPadding = Duration.zero,
    Duration endPadding = Duration.zero,
    Set<int> repeatWeekdays = const {},
    String? profileId,
  }) => _queue(() async {
    await ensureInitialized();
    final value = DvrSchedule(
      id: _id(),
      sourceId: sourceId,
      channelId: channelId,
      channelName: channelName,
      programmeTitle: programmeTitle,
      startsAt: startsAt,
      endsAt: endsAt,
      startPadding: startPadding,
      endPadding: endPadding,
      repeatWeekdays: Set.unmodifiable(repeatWeekdays),
      profileId: profileId,
    );
    value.validate();
    if (!value.captureEnd.isAfter(_now())) {
      throw const DvrException('This recording time has already ended.');
    }
    if (!value.captureStart.isAfter(_now()) &&
        _service.activeRecording != null) {
      throw const DvrException(
        'Another recording is already running. Stop it before scheduling an immediate start.',
      );
    }
    if (_overlapsOwnRecurrence(value)) {
      throw const DvrException(
        'The recording and its padding overlap the next repeating occurrence.',
      );
    }
    if (conflictsFor(value).isNotEmpty) {
      throw const DvrException(
        'This time overlaps another recording, including its padding. Only one recording can run at a time.',
      );
    }
    _schedules[value.id] = value;
    try {
      await _persist();
    } catch (_) {
      _schedules.remove(value.id);
      throw const DvrException('The recording schedule could not be saved.');
    }
    await _reconcile();
    return _schedules[value.id]!;
  });

  List<DvrSchedule> conflictsFor(DvrSchedule candidate) => _schedules.values
      .where(
        (other) =>
            other.id != candidate.id &&
            other.isPending &&
            _recurrenceOverlaps(candidate, other),
      )
      .toList();

  Future<void> cancelSchedule(String id) => _queue(() async {
    await ensureInitialized();
    final schedule = _schedules[id];
    if (schedule == null || !schedule.isPending) return;
    _schedules[id] = schedule.copyWith(status: DvrScheduleStatus.cancelled);
    await _persist();
    final recording = _recordingFor(schedule);
    if (recording?.status == DvrRecordingStatus.recording) {
      await _service.stopRecording(recording!.id);
    }
    _armTimer();
    _publish();
  });

  Future<void> removeSchedule(String id) => _queue(() async {
    await ensureInitialized();
    if (_schedules[id]?.isPending == true) {
      throw const DvrException('Cancel this schedule before removing it.');
    }
    _schedules.remove(id);
    await _persist();
    _publish();
  });

  /// Re-evaluate wall-clock boundaries after resume, time changes, or startup.
  Future<void> refreshDue() => _queue(() async {
    await ensureInitialized();
    await _reconcile();
  });

  Future<void> _reconcile() async {
    if (_closed) return;
    final now = _now();
    final starts = <DvrSchedule>[];
    for (final schedule in schedules) {
      if (schedule.isActive) {
        final recording = _recordingFor(schedule);
        if (recording != null &&
            recording.status != DvrRecordingStatus.recording) {
          _finish(
            schedule,
            _statusFor(recording, schedule),
            recordingId: recording.id,
            error: recording.error,
          );
        } else if (!schedule.captureEnd.isAfter(now)) {
          // Set the boundary result before stopping: the service notification
          // cannot race this into a successful whole programme after a late start.
          if (recording != null) {
            await _service.stopRecording(recording.id);
          }
          final finishedRecording = _recordingFor(schedule);
          _finish(
            schedule,
            finishedRecording == null
                ? DvrScheduleStatus.missed
                : _statusFor(finishedRecording, schedule),
            recordingId: finishedRecording?.id,
            error: finishedRecording == null
                ? 'Capture did not become ready before the recording ended.'
                : null,
          );
        }
      } else if (schedule.status == DvrScheduleStatus.scheduled) {
        if (!schedule.captureEnd.isAfter(now)) {
          _finish(
            schedule,
            DvrScheduleStatus.missed,
            error: 'TVBro was not running in time to record this programme.',
          );
        } else if (!schedule.captureStart.isAfter(now) && _resolver != null) {
          final busy =
              _service.activeRecording != null ||
              _schedules.values.any((other) => other.isActive);
          if (busy) {
            _finish(
              schedule,
              DvrScheduleStatus.conflict,
              error: 'Another recording was already running at the start time.',
            );
          } else {
            final starting = schedule.copyWith(
              status: DvrScheduleStatus.starting,
              startedLate:
                  now.difference(schedule.captureStart) >
                  const Duration(seconds: 30),
            );
            _schedules[schedule.id] = starting;
            starts.add(starting);
          }
        }
      }
    }
    await _persist();
    _armTimer();
    _publish();
    for (final schedule in starts) {
      late final Future<void> task;
      task = _start(schedule).whenComplete(() => _starts.remove(task));
      _starts.add(task);
      _observe(task);
    }
  }

  Future<void> _start(DvrSchedule schedule) async {
    var supporterDenied = false;
    try {
      if (schedule.isRecurring && !await _recurringAccess()) {
        supporterDenied = true;
        throw DvrException(
          DistributionConfig.channel.isConsumptionOnly
              ? 'Recurring recordings require an active supporter place. The schedule was kept; refresh access and schedule it again.'
              : 'Recurring recordings require an active supporter place. The schedule was kept; renew access and schedule it again.',
        );
      }
      if (_authorize != null && !await _authorize!(schedule)) {
        throw const DvrException(
          'This scheduled recording is blocked by the current content lock.',
        );
      }
      if (!_mayStart(schedule.id)) return;
      final stream = await _resolver!(schedule)
          .timeout(const Duration(seconds: 30));
      if (!_mayStart(schedule.id)) return;
      final recording = await _service.startRecording(
        stream,
        sourceId: schedule.sourceId,
        channelId: schedule.channelId,
        channelName: schedule.channelName,
        programmeTitle: schedule.programmeTitle,
        scheduleId: schedule.id,
        resolveAgain: () async {
          if (_authorize != null && !await _authorize!(schedule)) {
            throw const DvrException(
              'This scheduled recording is blocked by the current content lock.',
            );
          }
          return _resolver!(schedule);
        },
      );
      if (!_mayStart(schedule.id)) {
        await _service.stopRecording(recording.id);
        return;
      }
      await _queue(() async {
        final current = _schedules[schedule.id];
        if (current == null || !current.isActive) return;
        _schedules[schedule.id] = current.copyWith(
          status: DvrScheduleStatus.recording,
          recordingId: recording.id,
        );
        await _reconcile();
      });
    } catch (error) {
      if (_closed) return;
      await _queue(() async {
        final current = _schedules[schedule.id];
        if (current == null || !current.isActive) return;
        final recording = _recordingFor(current);
        _finish(
          current,
          recording != null && recording.hasMedia
              ? DvrScheduleStatus.interrupted
              : DvrScheduleStatus.failed,
          recordingId: recording?.id,
          error: error is DvrException
              ? error.message
              : 'The source or channel could not be opened for this recording.',
          advanceRecurring: !supporterDenied,
        );
        await _reconcile();
      });
    }
  }

  bool _mayStart(String id) =>
      !_closed &&
      _schedules[id]?.isActive == true &&
      _schedules[id]!.captureEnd.isAfter(_now());

  DvrRecording? _recordingFor(DvrSchedule schedule) {
    for (final recording in _service.recordings) {
      if (recording.id == schedule.recordingId ||
          recording.scheduleId == schedule.id) {
        return recording;
      }
    }
    return null;
  }

  DvrScheduleStatus _statusFor(DvrRecording recording, DvrSchedule schedule) =>
      switch (recording.status) {
        DvrRecordingStatus.recording => DvrScheduleStatus.interrupted,
        DvrRecordingStatus.completed =>
          _now().isBefore(schedule.captureEnd)
              ? DvrScheduleStatus.interrupted
              : DvrScheduleStatus.completed,
        DvrRecordingStatus.interrupted => DvrScheduleStatus.interrupted,
        DvrRecordingStatus.failed => DvrScheduleStatus.failed,
      };

  void _finish(
    DvrSchedule value,
    DvrScheduleStatus status, {
    String? recordingId,
    String? error,
    bool advanceRecurring = true,
  }) {
    final updated = value.copyWith(
      status: status,
      recordingId: recordingId,
      error:
          error ??
          (status == DvrScheduleStatus.interrupted
              ? 'Capture ended before the scheduled finish. Any saved media was kept.'
              : null),
    );
    _schedules[value.id] = updated;
    if (!advanceRecurring ||
        !value.isRecurring ||
        status == DvrScheduleStatus.cancelled) {
      return;
    }
    final series = value.seriesId ?? value.id;
    if (_schedules.values.any(
      (item) => item.isPending && (item.seriesId ?? item.id) == series,
    )) {
      return;
    }
    final next = value.nextOccurrence(_id(), _now());
    if (next != null) _schedules[next.id] = next;
  }

  void _onCaptureChanged() {
    if (_closed) return;
    // A cancellation can land while startRecording is still creating its sink.
    // Stop by safe schedule identity as soon as that sink is announced.
    for (final recording in _service.recordings) {
      if (recording.status == DvrRecordingStatus.recording &&
          recording.scheduleId != null &&
          _schedules[recording.scheduleId]?.isPending == false &&
          _stoppingIds.add(recording.id)) {
        _observe(
          _service
              .stopRecording(recording.id)
              .whenComplete(() => _stoppingIds.remove(recording.id)),
        );
      }
    }
    _observe(
      _queue(() async {
        var changed = false;
        for (final schedule in _schedules.values.toList()) {
          if (!schedule.isActive) continue;
          final recording = _recordingFor(schedule);
          if (recording == null) continue;
          if (recording.status != DvrRecordingStatus.recording) {
            _finish(
              schedule,
              _statusFor(recording, schedule),
              recordingId: recording.id,
              error: recording.error,
            );
            changed = true;
          } else if (schedule.recordingId != recording.id) {
            _schedules[schedule.id] = schedule.copyWith(
              recordingId: recording.id,
            );
            changed = true;
          }
        }
        if (changed) await _reconcile();
      }),
    );
  }

  void _armTimer() {
    _timer?.cancel();
    _timer = null;
    if (_closed) return;
    DateTime? next;
    final now = _now();
    for (final schedule in _schedules.values) {
      if (!schedule.isPending) continue;
      final boundary =
          schedule.isActive ||
              (_resolver == null && !schedule.captureStart.isAfter(now))
          ? schedule.captureEnd
          : schedule.captureStart;
      if (next == null || boundary.isBefore(next)) next = boundary;
    }
    if (next != null) {
      final delay = next.difference(now);
      _timer = _createTimer(delay.isNegative ? Duration.zero : delay, () {
        _timer = null;
        _observe(refreshDue());
      });
    }
  }

  Future<void> _persist() async {
    final file = File(p.join(_directory!.path, 'schedules.json'));
    final temporary = File('${file.path}.new');
    final backup = File('${file.path}.old');
    await temporary.writeAsString(
      jsonEncode({
        'version': 1,
        'schedules': _schedules.values.map((value) => value.toJson()).toList(),
      }),
      flush: true,
    );
    if (await backup.exists()) await backup.delete();
    if (await file.exists()) await file.rename(backup.path);
    await temporary.rename(file.path);
    if (await backup.exists()) await backup.delete();
  }

  Future<T> _queue<T>(Future<T> Function() action) {
    final result = _operations.then((_) {
      if (_closed) {
        throw const DvrException('The recording scheduler is closed.');
      }
      return action();
    });
    _operations = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  void _observe(Future<void> task) {
    unawaited(
      task.then<void>(
        (_) {},
        onError: (Object _) {
          if (!_closed) {
            DiagnosticsLog.instance.add('dvr', 'schedule_operation_failed');
          }
        },
      ),
    );
  }

  void _publish() {
    if (!_closed) notifyListeners();
  }

  Future<void> close() async {
    if (_closed) return;
    _timer?.cancel();
    _timer = null;
    _closed = true;
    _service.removeListener(_onCaptureChanged);
    try {
      await _initializing;
    } catch (_) {}
    await _operations;
    // Pending future occurrences stay persisted. An active occurrence remains
    // active on disk so the next launch honestly reconciles it as interrupted.
    super.dispose();
  }
}

bool _recurrenceOverlaps(DvrSchedule a, DvrSchedule b) {
  final anchor =
      (a.captureStart.isAfter(b.captureStart) ? a.captureStart : b.captureStart)
          .subtract(const Duration(days: 2));
  final limit = anchor.add(const Duration(days: 16));
  List<DvrSchedule> occurrences(DvrSchedule value) {
    final items = <DvrSchedule>[];
    if (value.captureEnd.isAfter(anchor)) items.add(value);
    var next = value.nextOccurrence('check', anchor);
    while (next != null && next.captureStart.isBefore(limit)) {
      items.add(next);
      next = next.nextOccurrence('check', next.captureStart);
    }
    return items;
  }

  final aItems = occurrences(a);
  final bItems = occurrences(b);
  return aItems.any((left) => bItems.any(left.overlaps));
}

bool _overlapsOwnRecurrence(DvrSchedule value) {
  var previous = value;
  // Eight consecutive occurrences cover every adjacent pair of a weekly rule,
  // including an initial one-off day outside the selected repeating weekdays.
  for (var occurrence = 0; occurrence < 8; occurrence++) {
    final next = previous.nextOccurrence('check', previous.captureStart);
    if (next == null) return false;
    if (previous.overlaps(next)) return true;
    previous = next;
  }
  return false;
}

String _id() {
  final random = Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}
