import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/dvr/dvr_service.dart';
import 'package:iptvs/screens/recordings_screen.dart';

void main() {
  testWidgets('empty library shows local limits and a useful empty state', (
    tester,
  ) async {
    final service = _FakeDvrService(
      settings: const DvrSettings(
        maxBufferDuration: Duration(minutes: 15),
        maxBufferBytes: 128 * 1024 * 1024,
        maxRecordingsBytes: 2 * 1024 * 1024 * 1024,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(home: RecordingsScreen(service: service)),
    );
    await tester.pumpAndSettle();

    expect(find.text('No recordings yet'), findsOneWidget);
    expect(find.textContaining('2.0 GB'), findsOneWidget);
    expect(find.textContaining('15:00'), findsOneWidget);
    expect(find.textContaining('128.0 MB'), findsOneWidget);
    expect(find.textContaining('Saved on this device'), findsOneWidget);
    expect(find.textContaining('complete stream segments'), findsOneWidget);
  });

  testWidgets('storage initialization failure is safe and actionable', (
    tester,
  ) async {
    final service = _FakeDvrService(
      failInitialization: true,
      settings: const DvrSettings(),
    );

    await tester.pumpWidget(
      MaterialApp(home: RecordingsScreen(service: service)),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Local recording storage is unavailable.'),
      findsOneWidget,
    );
    expect(find.textContaining('could not be opened'), findsOneWidget);
  });

  testWidgets('library stays within a short landscape viewport at large text', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(640, 360);
    tester.platformDispatcher.textScaleFactorTestValue = 1.6;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final service = _FakeDvrService(
      settings: const DvrSettings(),
      recordingItems: [
        DvrRecording(
          id: 'layout-fixture',
          channelName: 'A long channel name used by the landscape layout check',
          programmeTitle: 'A long programme title used by the layout check',
          startedAt: DateTime.utc(2026, 10, 22, 12),
          endedAt: DateTime.utc(2026, 10, 22, 12, 5),
          duration: const Duration(minutes: 5),
          bytes: 1024 * 1024,
          status: DvrRecordingStatus.completed,
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(home: RecordingsScreen(service: service)),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      find.text('A long programme title used by the layout check'),
      findsOneWidget,
    );
  });
}

class _FakeDvrService extends DvrService {
  _FakeDvrService({
    required this.settings,
    this.recordingItems = const [],
    this.failInitialization = false,
  }) : super(directory: Directory('unused'));

  @override
  final DvrSettings settings;
  final List<DvrRecording> recordingItems;
  final bool failInitialization;

  @override
  Future<void> ensureInitialized() async {
    if (failInitialization) {
      throw const DvrException(
        'The local recording storage could not be opened.',
      );
    }
  }

  @override
  List<DvrRecording> get recordings => recordingItems;

  @override
  DvrRecording? get activeRecording => null;

  @override
  DvrSession? get activeSession => null;

  @override
  int get recordingBytes => 0;

  @override
  int get recordingQuotaBytes => settings.maxRecordingsBytes;
}
