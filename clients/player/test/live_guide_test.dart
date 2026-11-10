import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/screens/epg_grid_screen.dart';
import 'package:iptvs/sources/demo_source.dart';
import 'package:iptvs/sources/epg_mapping.dart';
import 'package:iptvs/sources/source.dart';

void main() {
  late _GuideDatabase db;
  late LibraryRepository repo;
  late FocusNode gridFocus;
  late FocusNode groupsFocus;
  late FocusNode detailsFocus;
  late EpgGridSelection selection;
  late List<String> played;
  Completer<void>? loaded;
  String? expectedTitle;

  const channels = [
    Channel(id: 'a', name: 'News', number: 1),
    Channel(id: 'b', name: 'Sport', number: 2),
  ];
  final now = DateTime.now();
  final current = Programme(
    channelId: 'a',
    start: now.subtract(const Duration(minutes: 20)),
    stop: now.add(const Duration(minutes: 20)),
    title: 'News now',
  );
  final future = Programme(
    channelId: 'a',
    start: now.add(const Duration(minutes: 20)),
    stop: now.add(const Duration(minutes: 50)),
    title: 'News later',
  );

  setUp(() async {
    db = _GuideDatabase();
    repo = LibraryRepository(
      source: DemoSource(sourceId: 'guide'),
      db: db,
    );
    await db.replaceEpg('guide', [
      current,
      future,
      Programme(
        channelId: 'a',
        start: future.stop,
        stop: future.stop.add(const Duration(minutes: 30)),
        title: 'News after',
      ),
      Programme(
        channelId: 'b',
        start: now.subtract(const Duration(minutes: 10)),
        stop: now.add(const Duration(minutes: 40)),
        title: 'Sport now',
      ),
    ]);
    gridFocus = FocusNode(debugLabel: 'browser.guide');
    groupsFocus = FocusNode(debugLabel: 'browser.groups');
    detailsFocus = FocusNode(debugLabel: 'browser.details');
    played = [];
    loaded = null;
    expectedTitle = null;
  });

  tearDown(() async {
    gridFocus.dispose();
    groupsFocus.dispose();
    detailsFocus.dispose();
    await db.close();
  });

  Future<void> pumpGuide(
    WidgetTester tester, {
    List<Channel> visible = channels,
    int selected = 0,
    LibraryRepository? repository,
    String? waitForTitle = 'News now',
    bool awaitSelection = true,
    bool embedded = true,
    DateTime Function()? clock,
    bool Function(Channel channel)? isPlayingChannel,
    void Function(Channel channel, Programme programme)? onScheduleRecording,
  }) async {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    expectedTitle = waitForTitle;
    loaded = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              TextButton(
                focusNode: groupsFocus,
                onPressed: gridFocus.requestFocus,
                child: const Text('Groups'),
              ),
              Expanded(
                child: Column(
                  children: [
                    TextButton(
                      focusNode: detailsFocus,
                      onPressed: gridFocus.requestFocus,
                      child: const Text('Favorite'),
                    ),
                    Expanded(
                      child: EpgGridScreen(
                        repo: repository ?? repo,
                        channels: visible,
                        isPlayingChannel: isPlayingChannel,
                        embedded: embedded,
                        focusNode: gridFocus,
                        selectedChannelIndex: selected,
                        now: clock ?? () => now,
                        onExitLeft: embedded ? groupsFocus.requestFocus : null,
                        onExitUp: embedded ? detailsFocus.requestFocus : null,
                        onSelectionChanged: (value) {
                          selection = value;
                          if (value.programme?.title == expectedTitle &&
                              !loaded!.isCompleted) {
                            loaded!.complete();
                          }
                        },
                        onPlayChannel: (channel) => played.add(channel.id),
                        onPlayArchive: (_, _) {},
                        onScheduleRecording: onScheduleRecording,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    // The in-memory query resolves during the pump; the controlled race below
    // explicitly completes each request. Neither needs frame polling.
    if (awaitSelection) {
      await tester.runAsync(
        () => loaded!.future.timeout(const Duration(seconds: 5)),
      );
    }
    await tester.pump();
  }

  for (final embedded in [true, false]) {
    testWidgets(
      'playing channel marker follows playback instead of the cursor '
      '(embedded: $embedded)',
      (tester) async {
        final marker = find.byIcon(Icons.play_circle_fill_rounded);
        await pumpGuide(tester, embedded: embedded);
        expect(marker, findsNothing);

        await pumpGuide(
          tester,
          embedded: embedded,
          awaitSelection: false,
          isPlayingChannel: (channel) => channel.id == 'a',
        );
        expect(marker, findsOneWidget);
        expect(tester.widget<Icon>(marker).semanticLabel, 'Now playing');
        expect(
          tester.getCenter(marker).dy,
          closeTo(tester.getCenter(find.text('1 News')).dy, 0.01),
        );

        gridFocus.requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        expect(selection.channel.id, 'b');
        expect(marker, findsOneWidget);
        expect(
          tester.getCenter(marker).dy,
          closeTo(tester.getCenter(find.text('1 News')).dy, 0.01),
        );

        await pumpGuide(
          tester,
          embedded: embedded,
          selected: 1,
          awaitSelection: false,
          isPlayingChannel: (channel) => channel.id == 'b',
        );
        expect(marker, findsOneWidget);
        expect(
          tester.getCenter(marker).dy,
          closeTo(tester.getCenter(find.text('2 Sport')).dy, 0.01),
        );

        await pumpGuide(
          tester,
          embedded: embedded,
          selected: 1,
          awaitSelection: false,
        );
        expect(marker, findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets('live time marker spans the guide (embedded: $embedded)', (
      tester,
    ) async {
      await pumpGuide(tester, embedded: embedded);
      final line = find.byKey(const ValueKey('epg.nowLine'));
      final label = find.byKey(const ValueKey('epg.nowTime'));
      final rows = find.byType(ListView);
      expect(line, findsOneWidget);
      expect(
        tester.widget<Text>(label).data,
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}',
      );
      expect(
        tester.getTopLeft(line).dy,
        closeTo(tester.getTopLeft(rows).dy - 29, 0.01),
      );
      expect(
        tester.getBottomLeft(line).dy,
        closeTo(tester.getBottomLeft(rows).dy, 0.01),
      );
      expect(
        tester.getCenter(line).dx - tester.getTopLeft(rows).dx,
        closeTo(168 + (embedded ? now.minute % 30 * 4 : 120), 0.01),
      );

      // The overlay must let a tap reach the programme under the live line.
      await tester.tapAt(
        Offset(tester.getCenter(line).dx, tester.getTopLeft(rows).dy + 26),
      );
      await tester.pump();
      if (embedded) {
        expect(played, ['a']);
      } else {
        expect(find.byType(AlertDialog), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('live marker updates each minute while browsing future times', (
    tester,
  ) async {
    var time = now;
    await pumpGuide(tester, embedded: false, clock: () => time);
    final line = find.byKey(const ValueKey('epg.nowLine'));
    final label = find.byKey(const ValueKey('epg.nowTime'));
    final originalX = tester.getCenter(line).dx;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(selection.programme?.title, 'News later');
    final beforeMinute = tester.getCenter(line).dx;
    time = now.add(const Duration(minutes: 1));
    await tester.pump(const Duration(minutes: 1));
    expect(
      tester.widget<Text>(label).data,
      '${time.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}',
    );
    expect(tester.getCenter(line).dx, closeTo(beforeMinute + 4, 0.01));
    expect(selection.programme?.title, 'News later');

    // Panning moves the marker on the same axis and clips it out of view.
    final grid = find.byType(EpgGridScreen);
    final pan = await tester.startGesture(tester.getCenter(grid));
    await pan.moveBy(const Offset(-30, 0));
    await tester.pump();
    final beforePan = tester.getCenter(line).dx;
    await pan.moveBy(const Offset(-40, 0));
    await tester.pump();
    expect(tester.getCenter(line).dx, closeTo(beforePan - 40, 0.01));
    await pan.moveBy(const Offset(-300, 0));
    await tester.pump();
    expect(line, findsNothing);
    expect(label, findsNothing);
    await pan.up();

    await tester.tap(find.byTooltip('Jump to now'));
    await tester.pump();
    expect(line, findsOneWidget);
    expect(tester.getCenter(line).dx, greaterThanOrEqualTo(originalX));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final embedded in [true, false]) {
    testWidgets('live guide follows 08:00 to 09:30 without a programme change '
        '(embedded: $embedded)', (tester) async {
      var time = DateTime(2026, 10, 25, 8);
      final morning = [
        for (final channel in channels) ...[
          Programme(
            channelId: channel.id,
            start: time.subtract(const Duration(hours: 1)),
            stop: time.add(const Duration(hours: 2, minutes: 30)),
            title: '${channel.name} morning',
          ),
          Programme(
            channelId: channel.id,
            start: time.add(const Duration(hours: 2, minutes: 30)),
            stop: time.add(const Duration(hours: 3)),
            title: '${channel.name} later',
          ),
        ],
      ];
      await db.replaceEpg('guide', morning);
      await pumpGuide(
        tester,
        embedded: embedded,
        clock: () => time,
        waitForTitle: 'News morning',
      );

      time = time.add(const Duration(minutes: 90));
      await tester.pump(const Duration(minutes: 90));
      final line = find.byKey(const ValueKey('epg.nowLine'));
      final label = find.byKey(const ValueKey('epg.nowTime'));
      final rows = find.byType(ListView);
      final liveX = tester.getTopLeft(rows).dx + 168 + 120;
      expect(tester.widget<Text>(label).data, '09:30');
      expect(tester.getCenter(line).dx, closeTo(liveX, 0.01));
      expect(find.text('08:00').hitTestable(), findsNothing);
      expect(selection.programme?.title, 'News morning');
      final programmeTitle = find.byWidgetPredicate(
        (widget) =>
            widget is Text &&
            widget.data == 'News morning' &&
            widget.style?.fontSize == (embedded ? 14 : 12),
      );
      expect(
        tester.getTopLeft(programmeTitle).dx,
        greaterThanOrEqualTo(tester.getTopLeft(rows).dx + 168),
      );

      // Changing rows or returning from a future programme must not reveal
      // the old start of a long programme instead of the current live time.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(selection.programme?.title, 'Sport morning');
      expect(tester.getCenter(line).dx, closeTo(liveX, 0.01));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(selection.programme?.title, 'Sport later');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(selection.programme?.title, 'Sport morning');
      expect(tester.getCenter(line).dx, closeTo(liveX, 0.01));

      // A resumed TV catches up immediately, before the next minute timer.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      time = time.add(const Duration(minutes: 30));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(tester.widget<Text>(label).data, '10:00');
      expect(tester.getCenter(line).dx, closeTo(liveX, 0.01));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final embedded in [true, false]) {
    for (final trigger in ['resume', 'minute', 'guide replacement', 'Now']) {
      testWidgets('retained guide catches up after 26 hours on $trigger '
          '(embedded: $embedded)', (tester) async {
        await db.close();
        final windowed = _WindowedGuideDatabase();
        db = windowed;
        repo = LibraryRepository(
          source: DemoSource(sourceId: 'guide'),
          db: db,
        );
        var time = DateTime(2026, 10, 25, 8);
        Programme programme(String title) => Programme(
          channelId: 'a',
          start: time.subtract(const Duration(minutes: 10)),
          stop: time.add(const Duration(hours: 1)),
          title: title,
        );
        await db.replaceEpg('guide', [
          programme('First day'),
          Programme(
            channelId: 'a',
            start: time.add(const Duration(hours: 1)),
            stop: time.add(const Duration(hours: 2)),
            title: 'First day later',
          ),
        ]);
        await pumpGuide(
          tester,
          embedded: embedded,
          clock: () => time,
          waitForTitle: 'First day',
        );
        final originalState = tester.state(find.byType(EpgGridScreen));
        final originalWindow = windowed.windows.last;
        if (trigger == 'Now') {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
          await tester.pump();
          expect(selection.programme?.title, 'First day later');
        }

        if (trigger == 'resume' || trigger == 'Now') {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.paused,
          );
        }
        time = time.add(const Duration(hours: 26));
        await db.replaceEpg('guide', [programme('Next day')]);
        if (trigger == 'resume' || trigger == 'Now') {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
        } else if (trigger == 'minute') {
          await tester.pump(const Duration(minutes: 1));
        } else {
          windowed.changed.add('guide');
        }
        await tester.pump();
        await tester.pump();
        if (trigger == 'Now') {
          windowed.changed.add('guide');
          await tester.pump();
          await tester.pump();
          expect(windowed.windows.last, originalWindow);
          await tester.tap(
            embedded
                ? find.widgetWithText(TextButton, 'Now')
                : find.byTooltip('Jump to now'),
          );
          await tester.pump();
          await tester.pump();
        }

        expect(tester.state(find.byType(EpgGridScreen)), same(originalState));
        expect(windowed.windows.last.from.isAfter(time), isFalse);
        expect(windowed.windows.last.to.isAfter(time), isTrue);
        expect(selection.programme?.title, 'Next day');
        expect(find.text('Next day').hitTestable(), findsWidgets);
        expect(find.byKey(const ValueKey('epg.nowLine')), findsOneWidget);
        expect(
          tester.widget<Text>(find.byKey(const ValueKey('epg.nowTime'))).data,
          '10:00',
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }

  testWidgets('manual drag stays in place until Now resumes live following', (
    tester,
  ) async {
    var time = now;
    await pumpGuide(tester, embedded: false, clock: () => time);
    final line = find.byKey(const ValueKey('epg.nowLine'));
    final originalX = tester.getCenter(line).dx;
    final pan = await tester.startGesture(
      tester.getCenter(find.byType(EpgGridScreen)),
    );
    await pan.moveBy(const Offset(-30, 0));
    await tester.pump();
    await pan.moveBy(const Offset(-40, 0));
    await pan.up();
    await tester.pump();
    final manuallyPannedX = tester.getCenter(line).dx;
    expect(manuallyPannedX, lessThan(originalX));

    time = time.add(const Duration(minutes: 1));
    await tester.pump(const Duration(minutes: 1));
    expect(tester.getCenter(line).dx, closeTo(manuallyPannedX + 4, 0.01));

    await tester.tap(find.byTooltip('Jump to now'));
    await tester.pump();
    expect(tester.getCenter(line).dx, closeTo(originalX, 0.01));
    time = time.add(const Duration(minutes: 1));
    await tester.pump(const Duration(minutes: 1));
    expect(tester.getCenter(line).dx, closeTo(originalX, 0.01));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('embedded guide shares browser focus and exits Left and Up', (
    tester,
  ) async {
    await pumpGuide(tester);
    expect(FocusManager.instance.primaryFocus, gridFocus);
    expect(find.byType(AppBar), findsNothing);
    expect(find.text('TV guide'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus, groupsFocus);

    gridFocus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus, detailsFocus);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('held arrows keep the guide cursor visible between frames', (
    tester,
  ) async {
    final many = [
      ...channels,
      for (var i = 2; i < 40; i++)
        Channel(id: 'ch$i', name: 'Channel $i', number: i + 1),
    ];
    await pumpGuide(tester, visible: many);
    final position = tester
        .stateList<ScrollableState>(find.byType(Scrollable))
        .map((state) => state.position)
        .singleWhere((position) => position.axis == Axis.vertical);
    double offsetFor(int row) =>
        (row * 52 - (position.viewportDimension - 52) / 2).clamp(
          0.0,
          position.maxScrollExtent,
        );

    try {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump(const Duration(milliseconds: 300));
      // Repeat delivery can outrun painting on a TV. Assert while the key is
      // still held, without waiting for a final reveal animation to settle.
      for (var i = 0; i < 24; i++) {
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
      }
      await tester.pump();
      expect(selection.channel.id, 'ch25');
      expect(selection.channelIndex, 25);
      expect(position.pixels, closeTo(offsetFor(25), 0.5));
      expect(find.text('26 Channel 25').hitTestable(), findsOneWidget);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowUp);
      for (var i = 0; i < 19; i++) {
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowUp);
      }
      await tester.pump();
      expect(selection.channel.id, 'ch5');
      expect(selection.channelIndex, 5);
      expect(position.pixels, closeTo(offsetFor(5), 0.5));
      expect(find.text('6 Channel 5').hitTestable(), findsOneWidget);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowUp);
      expect(FocusManager.instance.primaryFocus, gridFocus);
    } finally {
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('OK plays current programme once and future OK opens details', (
    tester,
  ) async {
    await pumpGuide(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.select);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(played, ['a']);
    expect(find.byType(AlertDialog), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(selection.programme?.title, 'News later');
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Play live'), findsNothing);
    expect(played, ['a']);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('live selection follows programme boundaries and OK plays TV', (
    tester,
  ) async {
    var time = now;
    await pumpGuide(tester, clock: () => time);
    time = current.stop;
    await tester.pump(const Duration(minutes: 20));
    expect(selection.programme, same(future));

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(played, ['a']);
    expect(find.byType(AlertDialog), findsNothing);

    time = future.stop;
    await tester.pump(const Duration(minutes: 30));
    expect(selection.programme?.title, 'News after');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('OK catches up to wall time before a delayed boundary timer', (
    tester,
  ) async {
    var time = now;
    await pumpGuide(tester, clock: () => time);
    // Wall time can jump while the application is suspended.
    time = future.stop.add(const Duration(minutes: 1));
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(selection.programme?.title, 'News after');
    expect(played, ['a']);
    expect(find.byType(AlertDialog), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('future browsing holds its column and Now restores tracking', (
    tester,
  ) async {
    var time = now;
    await pumpGuide(tester, clock: () => time);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    time = future.stop;
    await tester.pump(const Duration(minutes: 50));
    expect(selection.programme, same(future));

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(selection.programme?.title, 'Sport now');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(selection.programme, same(future));

    await tester.tap(find.widgetWithText(TextButton, 'Now'));
    await tester.pump();
    expect(selection.programme?.title, 'News after');
    time = future.stop.add(const Duration(minutes: 30));
    await tester.pump(const Duration(minutes: 30));
    expect(selection.programme, isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(played, ['a']);
    expect(find.byType(AlertDialog), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('live selection follows starts overlapping an overlong entry', (
    tester,
  ) async {
    var time = now;
    await db.replaceEpg('guide', [
      Programme(
        channelId: 'a',
        start: current.start,
        stop: future.stop,
        title: 'News now',
      ),
      future,
    ]);
    await pumpGuide(tester, clock: () => time);
    time = future.start;
    await tester.pump(const Duration(minutes: 20));
    expect(selection.programme, same(future));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('manual overlapping selection keeps its own details on OK', (
    tester,
  ) async {
    final earlier = Programme(
      channelId: 'a',
      start: current.start.subtract(const Duration(minutes: 10)),
      stop: future.stop,
      title: 'Earlier overlap',
    );
    await db.replaceEpg('guide', [earlier, current, future]);
    await pumpGuide(tester, embedded: false);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(selection.programme, same(earlier));
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Earlier overlap'),
      ),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('guide replacement reschedules the live programme boundary', (
    tester,
  ) async {
    var time = now;
    await pumpGuide(tester, clock: () => time);
    final revised = Programme(
      channelId: 'a',
      start: now.add(const Duration(minutes: 5)),
      stop: future.stop,
      title: 'Revised news',
    );
    await db.replaceEpg('guide', [current, revised]);
    db.changed.add('guide');
    await tester.pump();
    time = revised.start;
    await tester.pump(const Duration(minutes: 5));
    expect(selection.programme, same(revised));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('live selection clears expired details across a guide gap', (
    tester,
  ) async {
    var time = now;
    final afterGap = Programme(
      channelId: 'a',
      start: current.stop.add(const Duration(minutes: 5)),
      stop: future.stop,
      title: 'After gap',
    );
    await db.replaceEpg('guide', [current, afterGap]);
    await pumpGuide(tester, clock: () => time);
    time = current.stop;
    await tester.pump(const Duration(minutes: 20));
    expect(selection.programme, isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(played, ['a']);
    expect(find.byType(AlertDialog), findsNothing);
    time = afterGap.start;
    await tester.pump(const Duration(minutes: 5));
    expect(selection.programme, same(afterGap));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('future programme details schedule the selected occurrence', (
    tester,
  ) async {
    Channel? scheduledChannel;
    Programme? scheduledProgramme;
    await pumpGuide(tester, onScheduleRecording: (channel, programme) {
      scheduledChannel = channel;
      scheduledProgramme = programme;
    });
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.text('Schedule recording'), findsOneWidget);
    await tester.tap(find.text('Schedule recording'));
    await tester.pumpAndSettle();
    expect(scheduledChannel?.id, channels.first.id);
    expect(scheduledProgramme, same(future));
    expect(played, isEmpty);
    expect(find.byType(AlertDialog), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Now hands remote focus back to the guide before playing', (
    tester,
  ) async {
    await pumpGuide(tester);
    final nowButton = tester.widget<TextButton>(
      find.widgetWithText(TextButton, 'Now'),
    );
    nowButton.focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus, gridFocus);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(selection.programme?.title, 'News later');

    nowButton.focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus, gridFocus);
    expect(selection.programme?.title, 'News now');
    expect(played, isEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(played, ['a']);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('category replacement clamps the selected channel safely', (
    tester,
  ) async {
    await pumpGuide(tester, selected: 1, waitForTitle: 'Sport now');
    expect(selection.channel.id, 'b');
    expect(selection.channelIndex, 1);
    await pumpGuide(tester, visible: [channels.first], selected: 1);
    expect(selection.channel.id, 'a');
    expect(selection.channelIndex, 0);
    expect(selection.programme?.title, 'News now');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'source replacement rebinds the guide for colliding channel ids',
    (tester) async {
      await pumpGuide(tester);
      await tester.runAsync(
        () => db.replaceEpg('other', [
          Programme(
            channelId: 'a',
            start: current.start,
            stop: current.stop,
            title: 'Other source programme',
          ),
        ]),
      );
      final other = LibraryRepository(
        source: DemoSource(sourceId: 'other'),
        db: db,
      );
      await pumpGuide(
        tester,
        repository: other,
        waitForTitle: 'Other source programme',
      );
      expect(selection.programme?.title, 'Other source programme');
      expect(selection.channelIndex, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(played, ['a']);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('a channel without EPG remains playable by remote and touch', (
    tester,
  ) async {
    await pumpGuide(
      tester,
      visible: const [Channel(id: 'unknown', name: 'No guide')],
      waitForTitle: null,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    await tester.tap(find.text('No programme information'));
    await tester.pump();
    expect(played, ['unknown', 'unknown']);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a refreshed guide wins over the first in-flight empty query', (
    tester,
  ) async {
    final controlled = _RacingGuideDatabase();
    addTearDown(controlled.changed.close);
    final racingRepo = LibraryRepository(
      source: DemoSource(sourceId: 'guide'),
      db: controlled,
    );
    await pumpGuide(
      tester,
      repository: racingRepo,
      waitForTitle: 'Refreshed programme',
      awaitSelection: false,
    );
    await tester.runAsync(
      () => controlled.firstStarted.future.timeout(const Duration(seconds: 5)),
    );
    controlled.changed.add('guide');
    await tester.pump();
    await tester.runAsync(
      () =>
          controlled.refreshStarted.future.timeout(const Duration(seconds: 5)),
    );
    expect(controlled.refreshedIds, contains('a'));
    controlled.fresh.complete({
      'a': [
        Programme(
          channelId: 'a',
          start: current.start,
          stop: current.stop,
          title: 'Refreshed programme',
        ),
      ],
    });
    await tester.pump();
    await tester.runAsync(
      () => loaded!.future.timeout(const Duration(seconds: 5)),
    );
    await tester.pump();
    expect(selection.programme?.title, 'Refreshed programme');

    await tester.runAsync(() async {
      controlled.stale.complete({});
      await controlled.stale.future;
    });
    await tester.pump();
    expect(
      selection.programme?.title,
      'Refreshed programme',
      reason: 'the pre-refresh empty result must not replace the new guide',
    );
    await tester.pumpWidget(const SizedBox());
  });
}

class _GuideDatabase implements AppDatabase {
  final changed = StreamController<String>.broadcast(sync: true);
  final Map<String, Map<String, List<Programme>>> _guides = {};

  @override
  Stream<String> get epgChanged => changed.stream;

  @override
  Future<void> replaceEpg(
    String sourceId,
    Iterable<Programme> programmes, {
    Iterable<EpgGuideChannel>? guideChannels,
    String? expectedCacheIdentity,
  }) async {
    final guide = <String, List<Programme>>{};
    for (final programme in programmes) {
      (guide[programme.channelId] ??= []).add(programme);
    }
    _guides[sourceId] = guide;
  }

  @override
  Future<Map<String, List<Programme>>> programmesForChannels(
    String sourceId,
    List<String> channelIds, {
    required DateTime from,
    required DateTime to,
  }) async => _guides[sourceId] ?? {};

  @override
  Future<void> close() => changed.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _WindowedGuideDatabase extends _GuideDatabase {
  final windows = <({DateTime from, DateTime to})>[];

  @override
  Future<Map<String, List<Programme>>> programmesForChannels(
    String sourceId,
    List<String> channelIds, {
    required DateTime from,
    required DateTime to,
  }) async {
    windows.add((from: from, to: to));
    final guide = await super.programmesForChannels(
      sourceId,
      channelIds,
      from: from,
      to: to,
    );
    return {
      for (final id in channelIds)
        id: [
          for (final programme in guide[id] ?? const <Programme>[])
            if (programme.start.isBefore(to) && programme.stop.isAfter(from))
              programme,
        ],
    };
  }
}

class _RacingGuideDatabase implements AppDatabase {
  final changed = StreamController<String>.broadcast(sync: true);
  final firstStarted = Completer<void>();
  final refreshStarted = Completer<void>();
  final stale = Completer<Map<String, List<Programme>>>();
  final fresh = Completer<Map<String, List<Programme>>>();
  List<String> refreshedIds = [];

  @override
  Stream<String> get epgChanged => changed.stream;

  @override
  Future<Map<String, List<Programme>>> programmesForChannels(
    String sourceId,
    List<String> channelIds, {
    required DateTime from,
    required DateTime to,
  }) {
    if (!firstStarted.isCompleted) {
      firstStarted.complete();
      return stale.future;
    }
    refreshedIds = channelIds;
    if (!refreshStarted.isCompleted) refreshStarted.complete();
    return fresh.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
