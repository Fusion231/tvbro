import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/dvr/dvr_scheduler.dart';
import 'package:iptvs/dvr/dvr_service.dart';
import 'package:iptvs/sources/source.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory directory;
  late _RecordingService service;
  late DvrScheduler scheduler;
  late DateTime now;
  late List<_BoundaryTimer> timers;
  late int resolves;
  late bool recurringAllowed;
  late int accessChecks;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('tvbro-schedule-test-');
    service = _RecordingService();
    now = DateTime(2026, 10, 22, 12);
    timers = [];
    resolves = 0;
    recurringAllowed = true;
    accessChecks = 0;
    scheduler = DvrScheduler(
      service: service,
      directory: directory,
      now: () => now,
      recurringAccess: () async {
        accessChecks++;
        return recurringAllowed;
      },
      createTimer: (delay, callback) {
        final timer = _BoundaryTimer(delay, callback);
        timers.add(timer);
        return timer;
      },
      resolveStream: (schedule) async {
        resolves++;
        return const StreamInfo(url: 'https://fixture.invalid/transient-token');
      },
    );
  });

  tearDown(() async {
    await scheduler.close();
    await service.close();
    await directory.delete(recursive: true);
  });

  Future<DvrSchedule> add({
    DateTime? start,
    DateTime? end,
    Duration before = Duration.zero,
    Duration after = Duration.zero,
    Set<int> repeat = const {},
  }) => scheduler.schedule(
    sourceId: 'source-id',
    channelId: 'channel-id',
    channelName: 'A channel',
    programmeTitle: 'A programme',
    startsAt: start ?? now.add(const Duration(hours: 1)),
    endsAt: end ?? now.add(const Duration(hours: 2)),
    startPadding: before,
    endPadding: after,
    repeatWeekdays: repeat,
    profileId: 'profile-id',
  );

  test(
    'expired recurring access preserves failed rule and leaves one-off free',
    () async {
      final recurring = await add(repeat: {DateTime.thursday});
      final once = await add(
        start: now.add(const Duration(hours: 2)),
        end: now.add(const Duration(hours: 3)),
      );
      recurringAllowed = false;
      now = recurring.captureStart;
      await scheduler.refreshDue();
      await _until(
        scheduler,
        () => scheduler.schedules.any(
          (s) => s.id == recurring.id && s.status == DvrScheduleStatus.failed,
        ),
      );
      final failed = scheduler.schedules.firstWhere(
        (s) => s.id == recurring.id,
      );
      expect(failed.error, contains('active supporter place'));
      expect(failed.repeatWeekdays, {DateTime.thursday});
      expect(
        scheduler.schedules.where((s) => s.seriesId == recurring.id),
        isEmpty,
      );
      expect(accessChecks, 1);
      expect(resolves, 0);
      now = once.captureStart;
      await scheduler.refreshDue();
      await _until(
        scheduler,
        () => scheduler.schedules.any(
          (s) => s.id == once.id && s.status == DvrScheduleStatus.recording,
        ),
      );
      expect(resolves, 1);
      expect(accessChecks, 1);
    },
  );

  test(
    'persists schedules without locators and restores one nearest boundary',
    () async {
      final schedule = await add(before: const Duration(minutes: 2));
      expect(resolves, 0);
      expect(timers.where((timer) => timer.isActive), hasLength(1));
      expect(timers.last.delay, const Duration(minutes: 58));
      final saved = await File(p.join(directory.path, 'schedules.json'))
          .readAsString();
      expect(saved, isNot(contains('transient-token')));
      expect(saved, isNot(contains('https://')));
      await scheduler.close();
      scheduler = DvrScheduler(
        service: service,
        directory: directory,
        now: () => now,
      );
      await scheduler.ensureInitialized();
      expect(scheduler.schedules.single.id, schedule.id);
      expect(
        scheduler.schedules.single.startPadding,
        const Duration(minutes: 2),
      );
      expect(scheduler.schedules.single.status, DvrScheduleStatus.scheduled);
      expect(scheduler.schedules.single.profileId, 'profile-id');
    },
  );

  test(
    'padded half-open intervals reject overlap and allow adjacent boundaries',
    () async {
      await add(after: const Duration(minutes: 5));
      await expectLater(
        add(
          start: now.add(const Duration(hours: 2)),
          end: now.add(const Duration(hours: 3)),
        ),
        throwsA(isA<DvrException>()),
      );
      await add(
        start: now.add(const Duration(hours: 2, minutes: 5)),
        end: now.add(const Duration(hours: 3)),
      );
      expect(scheduler.schedules, hasLength(2));
    },
  );

  test(
    'starts at padded boundary, resolves at start, and stops at padded end',
    () async {
      final item = await add(
        before: const Duration(minutes: 2),
        after: const Duration(minutes: 3),
      );
      now = item.captureStart;
      timers.last.fire();
      await _until(
        scheduler,
        () => scheduler.schedules.single.status == DvrScheduleStatus.recording,
      );
      expect(resolves, 1);
      expect(service.starts, 1);
      expect(service.activeRecording!.scheduleId, item.id);
      expect(timers.where((timer) => timer.isActive), hasLength(1));
      expect(timers.last.delay, const Duration(hours: 1, minutes: 5));
      now = item.captureEnd;
      await scheduler.refreshDue();
      expect(service.stops, 1);
      expect(scheduler.schedules.single.status, DvrScheduleStatus.completed);
    },
  );

  test(
    'late resume starts only inside the window and exposes missing beginning',
    () async {
      final item = await add();
      now = item.startsAt.add(const Duration(minutes: 5));
      await scheduler.refreshDue();
      await _until(
        scheduler,
        () => scheduler.schedules.single.status == DvrScheduleStatus.recording,
      );
      expect(scheduler.schedules.single.startedLate, isTrue);
      await scheduler.cancelSchedule(item.id);
      expect(service.activeRecording, isNull);
      expect(scheduler.schedules.single.status, DvrScheduleStatus.cancelled);
    },
  );

  test(
    'fully elapsed persisted job is missed and never resolves a provider',
    () async {
      final item = await add();
      await scheduler.close();
      now = item.captureEnd;
      scheduler = DvrScheduler(
        service: service,
        directory: directory,
        now: () => now,
        resolveStream: (_) async {
          resolves++;
          return const StreamInfo(url: 'https://fixture.invalid');
        },
      );
      await scheduler.ensureInitialized();
      expect(scheduler.schedules.single.status, DvrScheduleStatus.missed);
      expect(resolves, 0);
      expect(service.starts, 0);
    },
  );

  test('interrupted persisted job links recovered partial recording', () async {
    final item = await add();
    final file = File(p.join(directory.path, 'schedules.json'));
    await scheduler.close();
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    (json['schedules'] as List).single['status'] = 'recording';
    await file.writeAsString(jsonEncode(json));
    service.items.add(
      DvrRecording(
        id: 'partial',
        channelName: 'A channel',
        scheduleId: item.id,
        startedAt: item.captureStart,
        status: DvrRecordingStatus.interrupted,
        bytes: 100,
        duration: const Duration(seconds: 2),
      ),
    );
    scheduler = DvrScheduler(
      service: service,
      directory: directory,
      now: () => now,
    );
    await scheduler.ensureInitialized();
    expect(scheduler.schedules.single.status, DvrScheduleStatus.interrupted);
    expect(scheduler.schedules.single.recordingId, 'partial');
  });

  test(
    'manual recording at scheduled start is retained and conflict is visible',
    () async {
      final item = await add();
      service.items.add(
        DvrRecording(
          id: 'manual',
          channelName: 'Manual',
          startedAt: now,
          status: DvrRecordingStatus.recording,
        ),
      );
      now = item.captureStart;
      await scheduler.refreshDue();
      expect(scheduler.schedules.single.status, DvrScheduleStatus.conflict);
      expect(service.activeRecording!.id, 'manual');
      expect(service.stops, 0);
      expect(resolves, 0);
    },
  );

  test(
    'cancelling during provider lookup prevents a later orphan recording',
    () async {
      final lookup = Completer<StreamInfo>();
      scheduler.configureResolver((_) => lookup.future);
      final item = await add();
      now = item.captureStart;
      await scheduler.refreshDue();
      await scheduler
          .cancelSchedule(item.id)
          .timeout(const Duration(seconds: 1));
      lookup.complete(const StreamInfo(url: 'https://fixture.invalid'));
      await Future<void>.delayed(Duration.zero);
      expect(service.starts, 0);
      expect(scheduler.schedules.single.status, DvrScheduleStatus.cancelled);
    },
  );

  test(
    'content authorization is rechecked before lookup or recording',
    () async {
      scheduler.configureResolver((_) async {
        resolves++;
        return const StreamInfo(url: 'https://fixture.invalid');
      }, authorize: (_) async => false);
      final item = await add();
      now = item.captureStart;
      await scheduler.refreshDue();
      await _until(
        scheduler,
        () => scheduler.schedules.single.status == DvrScheduleStatus.failed,
      );
      expect(resolves, 0);
      expect(service.starts, 0);
    },
  );

  test(
    'cancelling a capture that is still starting leaves no active recording',
    () async {
      service.startGate = Completer<void>();
      final item = await add();
      now = item.captureStart;
      await scheduler.refreshDue();
      await _until(
        scheduler,
        () => scheduler.schedules.single.recordingId != null,
      );
      await scheduler
          .cancelSchedule(item.id)
          .timeout(const Duration(seconds: 1));
      expect(service.activeRecording, isNull);
      service.startGate!.complete();
      await Future<void>.delayed(Duration.zero);
      expect(scheduler.schedules.single.status, DvrScheduleStatus.cancelled);
      expect(service.stops, 1);
    },
  );

  test(
    'an upstream end before the planned finish reports an interrupted schedule',
    () async {
      final item = await add();
      now = item.captureStart;
      await scheduler.refreshDue();
      await _until(
        scheduler,
        () => scheduler.schedules.single.status == DvrScheduleStatus.recording,
      );
      await service.stopRecording(service.activeRecording!.id);
      await _until(
        scheduler,
        () =>
            scheduler.schedules.single.status == DvrScheduleStatus.interrupted,
      );
      expect(
        scheduler.schedules.single.error,
        contains('before the scheduled finish'),
      );
    },
  );

  test(
    'padding cannot make a weekly rule overlap its own next occurrence',
    () async {
      await expectLater(
        add(
          start: now.add(const Duration(hours: 1)),
          end: now.add(const Duration(hours: 24)),
          before: const Duration(hours: 1),
          after: const Duration(hours: 1),
          repeat: {DateTime.thursday, DateTime.friday},
        ),
        throwsA(isA<DvrException>()),
      );
      expect(scheduler.schedules, isEmpty);
    },
  );

  test('recurrence keeps local wall time, detects future conflict, and advances after a miss', () async {
    final item = await add(repeat: {DateTime.thursday});
    expect(item.repeatWeekdays, {DateTime.thursday});
    final nextStart = DateTime(
      item.startsAt.year,
      item.startsAt.month,
      item.startsAt.day + 7,
      item.startsAt.hour,
      item.startsAt.minute,
    );
    final nextEnd = DateTime(
      item.endsAt.year,
      item.endsAt.month,
      item.endsAt.day + 7,
      item.endsAt.hour,
      item.endsAt.minute,
    );
    expect(
      item
          .nextOccurrence('next', item.startsAt.add(const Duration(days: 5)))
          ?.startsAt,
      nextStart,
    );
    await expectLater(
      add(start: nextStart, end: nextEnd),
      throwsA(isA<DvrException>()),
    );
    now = item.captureEnd.add(const Duration(days: 15));
    await scheduler.refreshDue();
    final next = scheduler.schedules.firstWhere((value) => value.isPending);
    expect(
      scheduler.schedules.firstWhere((value) => value.id == item.id).status,
      DvrScheduleStatus.missed,
    );
    expect(next.startsAt.weekday, DateTime.thursday);
    expect(next.startsAt.hour, item.startsAt.hour);
    expect(next.captureStart.isAfter(now), isTrue);
    expect(next.seriesId, item.id);
    await scheduler.cancelSchedule(next.id);
    expect(scheduler.schedules.where((value) => value.isPending), isEmpty);
  });
}

Future<void> _until(DvrScheduler scheduler, bool Function() condition) async {
  if (condition()) return;
  final done = Completer<void>();
  void listener() {
    if (condition() && !done.isCompleted) done.complete();
  }

  scheduler.addListener(listener);
  try {
    listener();
    await done.future.timeout(const Duration(seconds: 3));
  } finally {
    scheduler.removeListener(listener);
  }
}

class _BoundaryTimer implements Timer {
  _BoundaryTimer(this.delay, this.callback);
  final Duration delay;
  final void Function() callback;
  bool _active = true;
  void fire() {
    if (!_active) return;
    _active = false;
    callback();
  }

  @override
  bool get isActive => _active;
  @override
  int get tick => _active ? 0 : 1;
  @override
  void cancel() => _active = false;
}

class _RecordingService extends DvrService {
  _RecordingService() : super(directory: Directory('unused'));
  final List<DvrRecording> items = [];
  int starts = 0;
  int stops = 0;
  Completer<void>? startGate;
  @override
  Future<void> ensureInitialized() async {}
  @override
  List<DvrRecording> get recordings => List.unmodifiable(items);
  @override
  DvrRecording? get activeRecording {
    for (final item in items) {
      if (item.status == DvrRecordingStatus.recording) return item;
    }
    return null;
  }

  @override
  Future<DvrRecording> startRecording(
    StreamInfo stream, {
    required String channelName,
    String? sourceId,
    String? channelId,
    String? programmeTitle,
    bool includeBuffered = false,
    String? scheduleId,
    Future<StreamInfo> Function()? resolveAgain,
  }) async {
    final value = DvrRecording(
      id: 'recording-${++starts}',
      channelName: channelName,
      startedAt: DateTime.now(),
      status: DvrRecordingStatus.recording,
      scheduleId: scheduleId,
      sourceId: sourceId,
      channelId: channelId,
    );
    items.add(value);
    notifyListeners();
    await startGate?.future;
    return value;
  }

  @override
  Future<void> stopRecording(String id) async {
    final index = items.indexWhere((item) => item.id == id);
    if (index < 0 || items[index].status != DvrRecordingStatus.recording) {
      return;
    }
    stops++;
    items[index] = items[index].copyWith(status: DvrRecordingStatus.completed);
    notifyListeners();
  }
}
