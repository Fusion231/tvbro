import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/l10n/app_localizations.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/theme.dart';
import 'package:iptvs/widgets/library_preload_progress.dart';

const _savedCatalogs = {
  ContentKind.live: true,
  ContentKind.movie: true,
  ContentKind.series: true,
};

void main() {
  tearDown(() {
    AppLanguageController.instance.preview(AppLanguage.english);
  });

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

  testWidgets('connection check precedes the three download stages', (
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
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

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
    variant: TargetPlatformVariant.only(TargetPlatform.android),
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
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  Future<void> showProgress(
    WidgetTester tester, {
    Size size = const Size(1280, 720),
    double textScale = 1,
    bool reduceMotion = false,
    Map<ContentKind, bool?> stages = _savedCatalogs,
    bool includeEpg = false,
    bool? epgReady,
    String? epgMessage,
    String? error,
    VoidCallback? onEditSource,
    VoidCallback? onRetry,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            disableAnimations: reduceMotion,
            padding: const EdgeInsets.all(24),
          ),
          child: child!,
        ),
        home: Scaffold(
          body: LibraryPreloadProgress(
            stages: stages,
            includeEpg: includeEpg,
            epgReady: epgReady,
            epgMessage: epgMessage,
            error: error,
            onEditSource: onEditSource,
            onRetry: onRetry,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
  }

  for (final size in const [
    Size(1280, 720),
    Size(960, 540),
    Size(1920, 1080),
  ]) {
    testWidgets(
      'Polish catalog setup fits ${size.width.toInt()}x${size.height.toInt()} with large text',
      (tester) async {
        AppLanguageController.instance.preview(AppLanguage.polish);
        await showProgress(
          tester,
          size: size,
          textScale: 2,
          reduceMotion: true,
        );

        expect(find.text('Ukończono 3 z 3'), findsOneWidget);
        expect(find.text('Program TV (EPG)'), findsNothing);
        expect(
          find.text('Przejdź dalej — EPG pobiera się w tle'),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(
          tester
              .widget<LinearProgressIndicator>(
                find.byType(LinearProgressIndicator),
              )
              .value,
          1,
        );

        await tester.ensureVisible(find.text('Seriale'));
        await tester.pump();
        expect(find.text('Seriale').hitTestable(), findsOneWidget);
        expect(
          find.text('Pobieranie i zapisywanie programu TV…'),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }

  testWidgets('three saved catalogs complete setup without EPG or a button', (
    tester,
  ) async {
    await showProgress(tester);
    expect(find.text('Finished 3 of 3'), findsOneWidget);
    expect(find.text('Your library is ready.'), findsOneWidget);
    expect(find.text('Program guide (EPG)'), findsNothing);
    expect(find.text('Continue while EPG downloads'), findsNothing);
    expect(find.byType(FilledButton), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      1,
    );
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('failed catalog settles progress without claiming it was saved', (
    tester,
  ) async {
    await showProgress(
      tester,
      stages: {
        ContentKind.live: true,
        ContentKind.movie: false,
        ContentKind.series: true,
      },
      reduceMotion: true,
    );

    expect(find.text('Finished 3 of 3'), findsOneWidget);
    expect(find.text('Saved on this device'), findsNWidgets(2));
    expect(find.text('Could not load. Retry after setup.'), findsOneWidget);
    expect(
      find.text('Unavailable content can be retried after setup.'),
      findsOneWidget,
    );
    expect(find.text('Your library is ready.'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('three saved catalogs wait for the fourth EPG stage', (
    tester,
  ) async {
    await showProgress(tester, includeEpg: true, reduceMotion: true);

    expect(find.text('Finished 3 of 4'), findsOneWidget);
    expect(find.text('Program guide (EPG)'), findsOneWidget);
    expect(
      find.text('Downloading and saving the program guide…'),
      findsOneWidget,
    );
    expect(find.text('Your library is ready.'), findsNothing);
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      0.75,
    );
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('a failed EPG stage shows its reason without claiming success', (
    tester,
  ) async {
    const reason = 'The guide returned HTTP 404. Check its URL.';
    await showProgress(
      tester,
      includeEpg: true,
      epgReady: false,
      epgMessage: reason,
      reduceMotion: true,
    );

    expect(find.text('Finished 4 of 4'), findsOneWidget);
    expect(find.text(reason), findsOneWidget);
    expect(find.text('Saved on this device'), findsNWidgets(3));
    expect(find.text('Your library is ready.'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets(
    'Polish EPG progress stays reachable on a short TV with large text',
    (tester) async {
      AppLanguageController.instance.preview(AppLanguage.polish);
      await showProgress(
        tester,
        size: const Size(960, 540),
        textScale: 2,
        includeEpg: true,
        reduceMotion: true,
      );

      expect(find.text('Ukończono 3 z 4'), findsOneWidget);
      await tester.ensureVisible(find.text('Program TV (EPG)'));
      await tester.pump();
      expect(find.text('Program TV (EPG)').hitTestable(), findsOneWidget);
      expect(
        find.text('Pobieranie i zapisywanie programu TV…'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets('a short TV can reach connection retry with its remote', (
    tester,
  ) async {
    var edits = 0;
    var retries = 0;
    await showProgress(
      tester,
      size: const Size(960, 540),
      textScale: 2,
      reduceMotion: true,
      error: 'Connection failed',
      onEditSource: () => edits++,
      onRetry: () => retries++,
    );
    await tester.pumpAndSettle();
    expect(find.text('Back and edit source').hitTestable(), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(find.text('Try again').hitTestable(), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(retries, 1);
    expect(edits, 0);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
