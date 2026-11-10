import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/dvr/dvr_scheduler.dart';
import 'package:iptvs/data/supporter_access.dart';
import 'package:iptvs/dvr/dvr_service.dart';
import 'package:iptvs/screens/recording_schedule_dialog.dart';
import 'package:iptvs/screens/recordings_screen.dart';
import 'package:iptvs/sources/source.dart';

void main() {
  testWidgets(
    'EPG scheduling carries programme time, padding, weekdays and profile',
    (tester) async {
      final scheduler = _UiScheduler();
      final start = DateTime.now().add(const Duration(hours: 2));
      final programme = Programme(
        channelId: 'channel',
        start: start,
        stop: start.add(const Duration(hours: 1)),
        title: 'Evening programme',
      );
      DvrSchedule? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                onPressed: () async {
                  result = await showRecordingScheduleDialog(
                    context,
                    sourceId: 'source',
                    profileId: 'profile',
                    channel: const Channel(id: 'channel', name: 'Channel'),
                    programme: programme,
                    scheduler: scheduler,
                    supporterAccess: _SupporterFixture(true),
                  );
                },
                child: const Text('Open schedule'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open schedule'));
      await tester.pumpAndSettle();
      expect(find.textContaining('TVBro must remain running'), findsOneWidget);
      await tester.tap(find.byType(DropdownButtonFormField<int>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('5 minutes').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Mon'));
      await tester.tap(find.text('Mon'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Schedule'));
      await tester.pumpAndSettle();
      expect(result?.startsAt, programme.start);
      expect(result?.endsAt, programme.stop);
      expect(result?.programmeTitle, programme.title);
      expect(result?.sourceId, 'source');
      expect(result?.profileId, 'profile');
      expect(result?.startPadding, const Duration(minutes: 5));
      expect(result?.repeatWeekdays, {DateTime.monday});
    },
  );

  testWidgets('free one-off schedule never checks supporter access', (
    tester,
  ) async {
    final scheduler = _UiScheduler();
    final access = _SupporterFixture(false);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showRecordingScheduleDialog(
                context,
                sourceId: 'source',
                channel: const Channel(id: 'channel', name: 'Channel'),
                scheduler: scheduler,
                supporterAccess: access,
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Schedule'));
    await tester.pumpAndSettle();
    expect(access.checks, 0);
    expect(scheduler.items.single.repeatWeekdays, isEmpty);
  });

  testWidgets('free weekday selection offers neutral free path', (
    tester,
  ) async {
    final scheduler = _UiScheduler();
    final access = _SupporterFixture(false);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showRecordingScheduleDialog(
                context,
                sourceId: 'source',
                channel: const Channel(id: 'channel', name: 'Channel'),
                scheduler: scheduler,
                supporterAccess: access,
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Mon'));
    await tester.tap(find.text('Mon'));
    await tester.pumpAndSettle();
    expect(find.text('Supporter features'), findsOneWidget);
    expect(find.text('Subscription options'), findsNothing);
    await tester.tap(find.text('Continue with free features'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilterChip>(find.widgetWithText(FilterChip, 'Mon'))
          .selected,
      isFalse,
    );
    await tester.tap(find.text('Schedule'));
    await tester.pumpAndSettle();
    expect(scheduler.items.single.repeatWeekdays, isEmpty);
  });

  testWidgets('recurring access is checked again before saving', (
    tester,
  ) async {
    final scheduler = _UiScheduler();
    final access = _SupporterFixture(true);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showRecordingScheduleDialog(
                context,
                sourceId: 'source',
                channel: const Channel(id: 'channel', name: 'Channel'),
                scheduler: scheduler,
                supporterAccess: access,
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Mon'));
    await tester.tap(find.text('Mon'));
    await tester.pumpAndSettle();
    access.active = false;
    await tester.tap(find.text('Schedule'));
    await tester.pumpAndSettle();
    expect(find.text('Supporter features'), findsOneWidget);
    expect(scheduler.items, isEmpty);
    expect(access.checks, 2);
    await tester.tap(find.text('Continue with free features'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'library cancels a schedule by remote and removes only its history',
    (tester) async {
      final scheduler = _UiScheduler();
      await scheduler.schedule(
        sourceId: 'source',
        channelId: 'channel',
        channelName: 'Channel',
        programmeTitle: 'Scheduled programme',
        startsAt: DateTime.now().add(const Duration(hours: 1)),
        endsAt: DateTime.now().add(const Duration(hours: 2)),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: RecordingsScreen(
            service: scheduler.fakeService,
            scheduler: scheduler,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Scheduled programme'), findsOneWidget);
      expect(
        find.textContaining('requires TVBro to remain running'),
        findsOneWidget,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(scheduler.cancelled, 1);
      expect(find.textContaining('CANCELLED'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(scheduler.removed, 1);
      expect(find.text('No recordings yet'), findsOneWidget);
    },
  );
}

class _SupporterFixture extends SupporterAccess {
  _SupporterFixture(this.active) : super(configured: false);
  bool active;
  int checks = 0;
  @override
  Future<bool> allows(SupporterFeature feature) async {
    checks++;
    return active;
  }
}

class _UiScheduler extends DvrScheduler {
  _UiScheduler._(this.fakeService)
    : super(service: fakeService, directory: Directory('unused'));
  factory _UiScheduler() => _UiScheduler._(_UiDvrService());
  final _UiDvrService fakeService;
  final List<DvrSchedule> items = [];
  int cancelled = 0;
  int removed = 0;
  @override
  Future<void> ensureInitialized() async {}
  @override
  List<DvrSchedule> get schedules => List.unmodifiable(items);
  @override
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
  }) async {
    final value = DvrSchedule(
      id: 'schedule',
      sourceId: sourceId,
      channelId: channelId,
      channelName: channelName,
      startsAt: startsAt,
      endsAt: endsAt,
      programmeTitle: programmeTitle,
      startPadding: startPadding,
      endPadding: endPadding,
      repeatWeekdays: Set.of(repeatWeekdays),
      profileId: profileId,
    );
    items.add(value);
    return value;
  }

  @override
  Future<void> cancelSchedule(String id) async {
    cancelled++;
    final index = items.indexWhere((item) => item.id == id);
    items[index] = items[index].copyWith(status: DvrScheduleStatus.cancelled);
    notifyListeners();
  }

  @override
  Future<void> removeSchedule(String id) async {
    removed++;
    items.removeWhere((item) => item.id == id);
    notifyListeners();
  }
}

class _UiDvrService extends DvrService {
  _UiDvrService() : super(directory: Directory('unused'));
  @override
  Future<void> ensureInitialized() async {}
}
