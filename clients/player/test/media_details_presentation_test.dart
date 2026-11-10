import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/data/source_store.dart';
import 'package:iptvs/screens/channel_list_screen.dart';
import 'package:iptvs/screens/live_tab_view.dart';
import 'package:iptvs/screens/media_tab_view.dart';
import 'package:iptvs/sources/demo_source.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/source_config.dart';
import 'package:iptvs/theme.dart';
import 'package:iptvs/widgets/routed_focus_node.dart';

const _movie = MediaItem(
  id: 'details-demo-movie',
  title: 'Demo cinematic movie',
  kind: ContentKind.movie,
  year: '2025',
  durationSeconds: 6120,
  rating: 8.2,
  description:
      'A demo synopsis used to verify the cinematic details view and its '
      'playback controls. It comes from the selected media item.',
);

void main() {
  late Directory tempDir;
  late AppDatabase db;
  var mediaKitAvailable = false;

  setUpAll(() async {
    debugDisableNetworkChannelLogos = true;
    final font = FontLoader('Inter');
    for (final face in ['regular', 'semibold', 'bold']) {
      final bytes = File('android/app/src/main/res/font/inter_$face.ttf')
          .readAsBytesSync();
      font.addFont(Future.value(bytes.buffer.asByteData()));
    }
    await font.load();
    try {
      MediaKit.ensureInitialized();
      mediaKitAvailable = true;
    } catch (_) {
      // Only the integrated browsing tests need its headless live preview.
    }
  });

  tearDownAll(() => debugDisableNetworkChannelLogos = false);

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('iptvs_details_presentation');
    db = await AppDatabase.openAt('${tempDir.path}/iptv.db');
    FlutterSecureStorage.setMockInitialValues({});
  });

  tearDown(() async {
    await db.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  void useWindow(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> pumpUntil(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 80; i++) {
      if (finder.evaluate().isNotEmpty) return;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(finder, findsWidgets);
  }

  Future<void> finishMotion(WidgetTester tester) async {
    // maybePop and post-frame focus reveal can start their ticker after the
    // first pump. Give it a start frame before advancing the animation clock.
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
  }

  Future<void> waitForMetadata(WidgetTester tester) async {
    final status = find.descendant(
      of: find.byType(MediaDetailsSheet),
      matching: find.byWidgetPredicate(
        (widget) => widget is FutureBuilder<ExternalMetadata?>,
      ),
    );
    final future = tester
        .widget<FutureBuilder<ExternalMetadata?>>(status)
        .future!;
    // Observe the actual metadata future before dismissing the sheet.
    var completed = false;
    Object? failure;
    future.then<void>(
      (_) {
        completed = true;
      },
      onError: (Object error, StackTrace _) {
        failure = error;
        completed = true;
      },
    );
    // Its completion also queues microtasks in the widget-test zone, so give
    // both the real SQLite isolate and the fake clock a turn, as pumpUntil does.
    for (var i = 0; i < 80 && !completed; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(completed, isTrue, reason: 'metadata read must finish before close');
    expect(failure, isNull);
  }

  Future<FocusNode> openFromBrowser(WidgetTester tester, Size size) async {
    useWindow(tester, size);
    await tester.runAsync(
      () => db.savePlaybackPosition(
        'demo',
        ContentKind.movie,
        _movie.id,
        position: const Duration(minutes: 12, seconds: 34),
        duration: const Duration(minutes: 102),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: ChannelListScreen(
          repo: LibraryRepository(source: _DetailsSource(), db: db),
          config: const SourceConfig(
            id: 'demo',
            kind: SourceKind.demo,
            label: 'Demo',
            fields: {},
          ),
          store: SourceStore(),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('home-movie')));
    await pumpUntil(tester, find.text('More info'));
    final opener = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'More info'),
    );
    final previousFocus = opener.focusNode!;
    previousFocus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await pumpUntil(tester, find.byType(MediaDetailsSheet));
    await finishMotion(tester);
    await waitForMetadata(tester);
    return previousFocus;
  }

  Future<void> unmountBrowser(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => db.epgIngest.cancelAndWait());
    await tester.pump(const Duration(seconds: 11));
  }

  testWidgets('browser opens a dialog and Close or Escape restores focus', (
    tester,
  ) async {
    if (!mediaKitAvailable) {
      markTestSkipped('libmpv not available');
      return;
    }
    try {
      final previousFocus = await openFromBrowser(
        tester,
        const Size(1266, 714),
      );
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byType(Dialog), findsOneWidget);
      expect(
        ModalRoute.of(tester.element(find.byType(MediaDetailsSheet))),
        isA<DialogRoute<void>>(),
      );
      expect(find.text('Resume from 12:34'), findsOneWidget);
      expect(
        focusRouteKey(FocusManager.instance.primaryFocus),
        'media.details.play',
      );

      await tester.tap(find.byTooltip('Close details'));
      await finishMotion(tester);
      expect(find.byType(MediaDetailsSheet), findsNothing);
      expect(FocusManager.instance.primaryFocus, same(previousFocus));

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await pumpUntil(tester, find.byType(MediaDetailsSheet));
      await finishMotion(tester);
      await waitForMetadata(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await finishMotion(tester);
      expect(find.byType(MediaDetailsSheet), findsNothing);
      expect(FocusManager.instance.primaryFocus, same(previousFocus));
      expect(tester.takeException(), isNull);
    } finally {
      await unmountBrowser(tester);
    }
  });

  testWidgets('narrow browser opens full-screen details with a visible Close', (
    tester,
  ) async {
    if (!mediaKitAvailable) {
      markTestSkipped('libmpv not available');
      return;
    }
    try {
      await openFromBrowser(tester, const Size(390, 844));
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byType(Dialog), findsNothing);
      expect(
        tester.getSize(find.byKey(const ValueKey('media.details.fullscreen'))),
        const Size(390, 844),
      );
      final close = tester.getRect(find.byTooltip('Close details'));
      expect(close.top, greaterThanOrEqualTo(0));
      expect(close.bottom, lessThanOrEqualTo(844));
      await tester.tap(find.byTooltip('Close details'));
      await finishMotion(tester);
      expect(find.byType(MediaDetailsSheet), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await unmountBrowser(tester);
    }
  });

  testWidgets(
    'movie details preserve resume, from-start and favorite actions',
    (tester) async {
      useWindow(tester, const Size(960, 540));
      final actions = <String>[];
      final repo = LibraryRepository(source: _DetailsSource(), db: db);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  useSafeArea: false,
                  builder: (dialogContext) => MediaDetailsSheet(
                    repo: repo,
                    item: _movie,
                    favorite: false,
                    resume: PlaybackPosition(
                      kind: ContentKind.movie,
                      itemId: _movie.id,
                      position: const Duration(minutes: 12, seconds: 34),
                      duration: const Duration(minutes: 102),
                      updatedAt: DateTime(2026, 1, 1),
                    ),
                    onToggleFavorite: () => actions.add('favorite'),
                    onPlay: () {
                      Navigator.of(dialogContext).pop();
                      actions.add('resume');
                    },
                    onPlayFromStart: () {
                      Navigator.of(dialogContext).pop();
                      actions.add('fromStart');
                    },
                  ),
                ),
                child: const Text('Open details'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open details'));
      await finishMotion(tester);
      await waitForMetadata(tester);
      expect(find.text(_movie.description!), findsOneWidget);
      await tester.tap(find.text('Add to favorites'));
      await tester.pump();
      expect(find.text('In favorites'), findsOneWidget);
      expect(actions, ['favorite']);

      await tester.tap(find.text('Resume from 12:34'));
      await finishMotion(tester);
      expect(actions, ['favorite', 'resume']);
      expect(find.byType(MediaDetailsSheet), findsNothing);

      await tester.tap(find.text('Open details'));
      await finishMotion(tester);
      await waitForMetadata(tester);
      await tester.tap(find.text('From start'));
      await finishMotion(tester);
      expect(actions, ['favorite', 'resume', 'fromStart']);
      expect(find.byType(MediaDetailsSheet), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final size in const [Size(390, 844), Size(960, 540)]) {
    testWidgets('details reflow at $size with 2x text and keep Close fixed', (
      tester,
    ) async {
      useWindow(tester, size);
      final repo = LibraryRepository(source: _DetailsSource(), db: db);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(2),
              disableAnimations: true,
            ),
            child: child!,
          ),
          home: Scaffold(
            body: MediaDetailsSheet(
              repo: repo,
              item: _movie.copyWith(
                title: 'A very long demo movie title that must wrap clearly',
                description: List.filled(8, _movie.description!).join(' '),
              ),
              favorite: false,
              onToggleFavorite: () {},
              onPlay: () {},
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await waitForMetadata(tester);
      final close = find.byTooltip('Close details');
      final before = tester.getRect(close);
      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(0, -400),
      );
      await tester.pump();
      expect(tester.getRect(close), before);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}

class _DetailsSource extends DemoSource {
  @override
  Future<List<MediaCategory>> mediaCategories(ContentKind kind) async =>
      const [];

  @override
  Future<List<MediaItem>> mediaItems(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    int? maxPages,
  }) async => kind == ContentKind.movie ? const [_movie] : const [];

  @override
  Future<MediaPage> mediaItemsPage(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    int page = 1,
  }) async =>
      MediaPage(items: await mediaItems(kind), page: page, totalPages: 1);
}
