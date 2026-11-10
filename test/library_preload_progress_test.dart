import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/sources/source.dart';
import 'package:iptvs/theme.dart';
import 'package:iptvs/widgets/library_preload_progress.dart';

void main() {
  const pending = <ContentKind, bool?>{
    ContentKind.live: null,
    ContentKind.movie: null,
    ContentKind.series: null,
  };

  Future<void> show(
    WidgetTester tester,
    LibraryPreloadProgress progress, {
    bool reduceMotion = false,
  }) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(disableAnimations: reduceMotion),
          child: child!,
        ),
        home: Scaffold(body: progress),
      ),
    );
    await tester.pump();
  }

  testWidgets('connection check precedes the three catalog stages', (
    tester,
  ) async {
    await show(
      tester,
      const LibraryPreloadProgress(stages: pending, connecting: true),
    );

    expect(find.text('Checking source connection…'), findsOneWidget);
    expect(find.text('Waiting for connection'), findsNWidgets(3));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'progress reflects completed stages and respects reduced motion',
    (tester) async {
      await show(
        tester,
        const LibraryPreloadProgress(
          stages: {
            ContentKind.live: true,
            ContentKind.movie: null,
            ContentKind.series: false,
          },
        ),
        reduceMotion: true,
      );

      expect(find.text('Finished 2 of 3'), findsOneWidget);
      expect(find.text('Saved on this device'), findsOneWidget);
      expect(find.text('Loading movies and categories…'), findsOneWidget);
      expect(find.text('Could not load. Retry after setup.'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        closeTo(2 / 3, 0.001),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('connection failure allows editing the source and trying again', (
    tester,
  ) async {
    var edited = false;
    var retried = false;
    await show(
      tester,
      LibraryPreloadProgress(
        stages: pending,
        error: 'Connection failed',
        onEditSource: () => edited = true,
        onRetry: () => retried = true,
      ),
    );

    expect(find.text('Connection failed'), findsOneWidget);
    expect(find.text('Waiting for connection'), findsNWidgets(3));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.ensureVisible(find.text('Back and edit source'));
    await tester.tap(find.text('Back and edit source'));
    await tester.ensureVisible(find.text('Try again'));
    await tester.tap(find.text('Try again'));
    expect(edited, isTrue);
    expect(retried, isTrue);
    expect(tester.takeException(), isNull);
  });
}
