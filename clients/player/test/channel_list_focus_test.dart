// D-pad regression net for ChannelListScreen's live tab.
//
// The live channel list and category sidebar are **selection models**: each has
// a single focus node (`live.channels` / `live.categories`) and a selected index
// that drives the highlight and the scroll. Rows are not focus targets. These
// tests drive real key events through the focus system and pin the contract:
//
//   * **Down wraps** at the end of both lists — the only infinite motion.
//   * **Up never wraps**: at the first row it escapes upward (channels → the
//     preview controls, or the search box on a phone; categories → the search
//     box). The old per-row-focus design wrapped Up in the sidebar, which is
//     what left users "stuck in the categories".
//   * The Back ladder peels exactly one rung per press:
//     channel list → first channel → categories → first category → search →
//     Home button → exit confirmation → exit.
//
// Focus is asserted via RoutedFocusNode.routeKey (through focusRouteKey), the
// release-safe signal the screen routes off — debugLabel is null in release.
//
// Harness notes:
//  * repo.load runs through sqflite_common_ffi (a background isolate) whose
//    futures don't advance under the widget-test fake clock, so we drive the
//    real event loop with runAsync between pumps (`pumpUntil`).
//  * The screen holds a 1-minute periodic EPG timer, so we never pumpAndSettle;
//    tests unmount at the end so State.dispose cancels it. `unmount` also
//    drains the background guide refresh — see its doc comment.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride, TargetPlatform;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/device_class.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/data/source_store.dart';
import 'package:iptvs/player/player_screen.dart';
import 'package:iptvs/screens/channel_list_chrome.dart';
import 'package:iptvs/screens/channel_list_screen.dart';
import 'package:iptvs/screens/epg_grid_screen.dart';
import 'package:iptvs/screens/live_preview_controller.dart';
import 'package:iptvs/screens/live_tab_view.dart';
import 'package:iptvs/screens/media_tab_view.dart';
import 'package:iptvs/sources/demo_source.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/source_config.dart';
import 'package:iptvs/theme.dart';
import 'package:iptvs/widgets/focusable_card.dart';
import 'package:iptvs/widgets/routed_focus_node.dart';
import 'package:iptvs/widgets/tv_text_field.dart';

// Set to true in setUpAll when libmpv is available; tests skip otherwise.
bool _mediaKitAvailable = false;

void main() {
  late Directory tempDir;
  late AppDatabase db;

  setUpAll(() {
    // The demo/live channels carry network logo URLs, which render through
    // CachedNetworkImage/flutter_cache_manager — its path_provider calls and
    // cleanup Timer both break under `flutter test` (it aborts on Linux before
    // the Timer, so this only failed on Windows). Skip logo loading; these tests
    // assert channel names/focus, not images.
    debugDisableNetworkChannelLogos = true;
    // The wide live layout builds an inline preview player (media_kit); it must
    // be able to construct headless. libmpv is only present when running from a
    // full build directory, not in a plain `flutter test` run, so we catch the
    // failure and skip rather than hard-failing.
    try {
      MediaKit.ensureInitialized(libmpv: Platform.environment['TVBRO_AUDIT_LIBMPV']);
      _mediaKitAvailable = true;
    } catch (_) {
      // libmpv not in PATH — tests will be skipped.
    }
  });

  tearDownAll(() => debugDisableNetworkChannelLogos = false);

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('iptvs_focus_test');
    db = await AppDatabase.openAt('${tempDir.path}/iptv.db');
    // The screen reads the source list (for the cross-source Favorites view)
    // out of the keychain; without a mock the plugin channel is absent.
    FlutterSecureStorage.setMockInitialValues({});
  });

  tearDown(() async {
    await db.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  const config = SourceConfig(
    id: 'demo',
    kind: SourceKind.demo,
    label: 'Demo',
    fields: {},
  );

  // Only the cross-source Favorites view reads this, and these tests configure
  // a single source — so it stays empty and that view never appears.
  final store = SourceStore();

  // Channel names also appear in the preview. Membership, scrolling and row
  // action assertions must inspect the list owned by its routed focus node.
  Finder inChannelList(Finder matching) => find.descendant(
    of: find.byWidgetPredicate(
      (widget) =>
          widget is Focus && focusRouteKey(widget.focusNode) == 'live.channels',
    ),
    matching: matching,
  );
  Finder channelText(String label) => inChannelList(find.text(label));
  Finder liveCategoryList() => find.descendant(
    of: find.byKey(const ValueKey('live.categoryPane')),
    matching: find.byType(ListView),
  );
  Finder categoryText(String label) =>
      find.descendant(of: liveCategoryList(), matching: find.text(label));

  Future<void> pumpUntil(WidgetTester tester, Finder until) async {
    for (var i = 0; i < 60; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
      if (until.evaluate().isNotEmpty) break;
    }
    await tester.pump(const Duration(milliseconds: 50));
  }

  Future<void> openSection(WidgetTester tester, ContentKind kind) async {
    if (find.byTooltip('Home').evaluate().isNotEmpty) {
      await tester.tap(find.byTooltip('Home'));
      await tester.pump();
    }
    await tester.tap(find.byKey(ValueKey('home-${kind.name}')));
    await tester.pump();
  }

  Future<void> openHome(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Home'));
    await tester.pump();
  }

  Future<void> pumpWideScreenWith(
    WidgetTester tester,
    Source source, {
    Size size = const Size(1600, 900),
    bool rowMode = true,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repo = LibraryRepository(source: source, db: db);
    await tester.pumpWidget(
      MaterialApp(
        home: ChannelListScreen(repo: repo, config: config, store: store),
      ),
    );
    // "Channel groups" is the live category pane header — present once loaded.
    await openSection(tester, ContentKind.live);
    await pumpUntil(tester, find.text('Channel groups'));
    // These retain the channel-row navigation contract. The default integrated
    // timeline is covered separately by live_guide_test.dart.
    if (rowMode) {
      await tester.tap(find.byTooltip('Channel list'));
      await tester.pump();
    }
  }

  Future<void> pumpWideScreen(WidgetTester tester) =>
      pumpWideScreenWith(tester, _FocusDemoSource());

  Future<void> pumpNarrowScreenWith(
    WidgetTester tester,
    Source source, {
    VoidCallback? onManageSources,
    Future<void> Function()? onOpenRecordings,
  }) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repo = LibraryRepository(source: source, db: db);
    await tester.pumpWidget(
      MaterialApp(
        home: ChannelListScreen(
          repo: repo,
          config: config,
          store: store,
          onManageSources: onManageSources,
          onOpenRecordings: onOpenRecordings,
        ),
      ),
    );
    await openSection(tester, ContentKind.live);
    await pumpUntil(tester, channelText('Channel 0'));
  }

  /// Let the selection reveal's scroll animation (140ms) land.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  /// One D-pad press. Light pump — call [settle] before asserting on scroll.
  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pump(const Duration(milliseconds: 20));
  }

  Future<void> pressTimes(
    WidgetTester tester,
    LogicalKeyboardKey key,
    int times,
  ) async {
    for (var i = 0; i < times; i++) {
      await press(tester, key);
    }
    await settle(tester);
  }

  /// Tears the screen down **and drains the background EPG refresh**.
  ///
  /// `LibraryRepository.load` returns as soon as the channels are ready and
  /// refreshes the guide behind them, so an ingest is routinely still running
  /// when a test finishes — and `sqflite_common` arms a 10-second lock-warning
  /// `Timer` for the duration of every `transaction()`. Started under the
  /// widget-test fake clock, that is a `FakeTimer` nothing ever fires or
  /// cancels, and `!timersPending` fails the case with "A Timer is still
  /// pending even after the widget tree was disposed".
  ///
  /// It is a race, not a constant: which test loses depends on where the
  /// ingest's transaction happens to sit when the body ends, so it moved
  /// between cases run to run and read as CI flake. `tearDown`'s `db.close()`
  /// already waits for the ingest — but that runs *after* the invariant check,
  /// which is exactly one step too late. Wait here instead, and on the real
  /// event loop (`runAsync`): the ingest's futures come back through
  /// `sqflite_common_ffi`'s background isolate and never advance under the
  /// fake clock.
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    var epgDrained = false;
    unawaited(db.epgIngest.cancelAndWait().then((_) => epgDrained = true));
    // SQLite completes on the real loop, but the ingest's continuations may
    // belong to the fake zone. Awaiting only runAsync deadlocks that zone.
    for (var i = 0; i < 100 && !epgDrained; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(epgDrained, isTrue, reason: 'background guide must finish teardown');
    // A query issued under the fake clock while real-async work (a favorite
    // write, the background guide ingest) holds sqflite's lock arms sqflite's
    // 10 s lock-*warning* timer (`setLockWarningInfo`) in the fake zone, where
    // nothing ever fires or cancels it. The race — e.g. `epgChanged` →
    // `nowNext` landing while OK's favorite write is in flight — is
    // timing-dependent: lost, it failed "A Timer is still pending" on CI while
    // passing locally. Step the fake clock past it: the tree is gone, so
    // nothing else is scheduled, and at worst the warning prints once. Don't
    // drain with `runAsync` here instead — that lets a media tab's poster
    // loads run for real and hit the absent path_provider plugin.
    await tester.pump(const Duration(seconds: 11));
  }

  testWidgets('desktop hover and focus never resolve a provider stream', (tester) async {
    final source = _BrowsingOnlySource();
    try {
      await pumpWideScreenWith(tester, source);
      final row = inChannelList(find.text('Big Buck Bunny (H.264)'));
      final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await pointer.addPointer(location: tester.getCenter(row));
      await tester.pump(const Duration(seconds: 2));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump(const Duration(seconds: 2));
      expect(source.resolveCalls, 0);
      await pointer.removePointer();
    } finally {
      await unmount(tester);
    }
  });

  String focusLabel() => focusRouteKey(FocusManager.instance.primaryFocus);

  Future<void> back(WidgetTester tester) async {
    await tester.binding.handlePopRoute();
    await tester.pump();
    await settle(tester);
  }

  void focusTestWidgets(String description, WidgetTesterCallback callback) {
    testWidgets(description, (tester) async {
      if (!_mediaKitAvailable) {
        markTestSkipped('libmpv not available in this environment');
        return;
      }
      try {
        await callback(tester);
      } finally {
        // Dispose controllers and finish guide reads before tearDown closes
        // SQLite, including when an assertion interrupts the test body.
        await unmount(tester);
      }
    }, timeout: const Timeout(Duration(minutes: 2)));
  }

  Future<LivePreviewController> pumpIdleScreen(
    WidgetTester tester, {
    bool television = true,
  }) async {
    debugIsTelevision = television;
    await pumpWideScreenWith(tester, _GuideSelectionSource());
    // On desktop the real platform still enables the focus-preview debounce.
    // Let its pending provider request start, then clear it before seeding the
    // ready preview. No network stream is opened by this harness.
    await tester.pump(const Duration(milliseconds: 600));
    final tab = tester.widget<LiveTabView>(find.byType(LiveTabView));
    final preview = (tab.previewVideoBuilder() as PreviewVideo).preview;
    await preview.stop(clearSelection: true);
    await tester.pump();
    return preview;
  }

  void readyIdlePreview(LivePreviewController preview) {
    preview.channelId = 'ch0';
    preview.stream = const StreamInfo(url: 'https://example.test/live');
    preview.loading = false;
    // The engine stays unopened: only the browser's ready-state notification
    // and the existing fullscreen handoff are relevant to these tests.
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    preview.notifyListeners();
  }

  void idleTestWidgets(String description, WidgetTesterCallback callback) {
    focusTestWidgets(description, (tester) async {
      final previousPlatform = debugDefaultTargetPlatformOverride;
      final previousTelevision = isTelevision;
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        await callback(tester);
      } finally {
        debugDefaultTargetPlatformOverride = previousPlatform;
        debugIsTelevision = previousTelevision;
      }
    });
  }

  idleTestWidgets(
    'TV idle preview opens fullscreen after 30 seconds without notification resets',
    (tester) async {
      final preview = await pumpIdleScreen(tester);
      // The preview remains on Channel 0 even while browsing another row.
      await press(tester, LogicalKeyboardKey.arrowDown);
      await tester.pump(const Duration(milliseconds: 600));
      await preview.stop(clearSelection: true);
      readyIdlePreview(preview);
      await tester.pump();

      await tester.pump(const Duration(seconds: 20));
      // Playback notifications must not postpone an otherwise idle deadline.
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      preview.notifyListeners();
      await tester.pump(const Duration(seconds: 9));
      expect(find.byType(PlayerScreen), findsNothing);

      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(PlayerScreen), findsOneWidget);
      expect(
        tester.widget<PlayerScreen>(find.byType(PlayerScreen)).title,
        'Channel 0',
      );
    },
  );

  idleTestWidgets('TV idle preview timer restarts on key repeat and key up', (
    tester,
  ) async {
    final preview = await pumpIdleScreen(tester);
    readyIdlePreview(preview);
    await tester.pump();

    await tester.pump(const Duration(seconds: 20));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump(const Duration(seconds: 20));
    expect(find.byType(PlayerScreen), findsNothing);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump(const Duration(seconds: 20));
    expect(find.byType(PlayerScreen), findsNothing);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump(const Duration(seconds: 29));
    expect(find.byType(PlayerScreen), findsNothing);
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(PlayerScreen), findsOneWidget);
  });

  idleTestWidgets('TV idle preview timer restarts on system Back', (
    tester,
  ) async {
    final preview = await pumpIdleScreen(tester);
    await press(tester, LogicalKeyboardKey.arrowDown);
    await tester.pump(const Duration(milliseconds: 600));
    await preview.stop(clearSelection: true);
    readyIdlePreview(preview);
    await tester.pump();
    await tester.pump(const Duration(seconds: 20));

    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(focusLabel(), 'live.channels');
    await tester.pump(const Duration(seconds: 29));
    expect(find.byType(PlayerScreen), findsNothing);
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(PlayerScreen), findsOneWidget);
  });

  idleTestWidgets('TV idle preview timer restarts on pointer activity', (
    tester,
  ) async {
    final preview = await pumpIdleScreen(tester);
    readyIdlePreview(preview);
    await tester.pump();
    final position = tester.getCenter(
      find.byKey(const ValueKey('live.previewThumbnail')),
    );
    final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await pointer.addPointer(location: position);
    try {
      await tester.pump(const Duration(seconds: 20));
      await pointer.moveTo(position + const Offset(1, 0));
      await tester.pump(const Duration(seconds: 20));
      expect(find.byType(PlayerScreen), findsNothing);
      await pointer.down(position);
      await tester.pump(const Duration(seconds: 20));
      expect(find.byType(PlayerScreen), findsNothing);
      await pointer.moveTo(position + const Offset(2, 0));
      await tester.pump(const Duration(seconds: 20));
      expect(find.byType(PlayerScreen), findsNothing);
      await pointer.up();
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: position,
          scrollDelta: const Offset(0, 1),
        ),
      );
      await tester.pump(const Duration(seconds: 29));
      expect(find.byType(PlayerScreen), findsNothing);
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(PlayerScreen), findsOneWidget);
    } finally {
      await pointer.removePointer();
    }
  });

  idleTestWidgets('TV idle preview waits while a dialog covers the list', (
    tester,
  ) async {
    final preview = await pumpIdleScreen(tester);
    readyIdlePreview(preview);
    await tester.pump();
    await tester.pump(const Duration(seconds: 20));

    final context = tester.element(find.byType(ChannelListScreen));
    unawaited(
      showDialog<void>(
        context: context,
        builder: (_) => const AlertDialog(content: Text('Idle timer dialog')),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(seconds: 40));
    expect(find.text('Idle timer dialog'), findsOneWidget);
    expect(find.byType(PlayerScreen), findsNothing);

    Navigator.of(context).pop();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(seconds: 29));
    expect(find.byType(PlayerScreen), findsNothing);
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(PlayerScreen), findsOneWidget);
  });

  idleTestWidgets('TV idle preview does not open in the background', (
    tester,
  ) async {
    final preview = await pumpIdleScreen(tester);
    readyIdlePreview(preview);
    await tester.pump();
    await tester.pump(const Duration(seconds: 20));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    try {
      await tester.pump(const Duration(seconds: 40));
      expect(find.byType(PlayerScreen), findsNothing);
    } finally {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    }
  });

  for (final television in [false, true]) {
    idleTestWidgets(
      television
          ? 'TV idle list without a ready preview stays on the list'
          : 'non-TV idle preview stays on the list',
      (tester) async {
        final preview = await pumpIdleScreen(
          tester,
          television: television,
        );
        if (!television) readyIdlePreview(preview);
        await tester.pump(const Duration(seconds: 31));
        expect(find.byType(PlayerScreen), findsNothing);
      },
    );
  }

  // ── Entry ──────────────────────────────────────────────────────────────────

  focusTestWidgets(
    'wide entry embeds the guide and keeps selection, OK, Back and categories in sync',
    (tester) async {
      final source = _GuideSelectionSource();
      await pumpWideScreenWith(
        tester,
        source,
        size: const Size(960, 540),
        rowMode: false,
      );
      await settle(tester);
      EpgGridScreen guide() => tester.widget(find.byType(EpgGridScreen));
      expect(guide().embedded, isTrue);
      expect(guide().selectedChannelIndex, 0);
      expect(focusLabel(), 'live.channels');

      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(
        guide().selectedChannelIndex,
        1,
        reason: 'the grid cursor updates the browser coordinator',
      );
      await press(tester, LogicalKeyboardKey.select);
      final resolved = await tester.runAsync(
        () => source.selected.future.timeout(const Duration(seconds: 5)),
      );
      expect(
        resolved?.id,
        'ch1',
        reason: 'OK resolves the channel selected in the embedded guide',
      );

      await back(tester);
      expect(focusLabel(), 'live.categories');
      expect(
        guide().selectedChannelIndex,
        1,
        reason: 'Back leaves the guide while keeping its channel selection',
      );
      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.select);
      await settle(tester);
      expect(focusLabel(), 'live.channels');
      expect(guide().channels, hasLength(6));
      expect(guide().channels.every((c) => c.categoryId == 'cat0'), isTrue);
      expect(guide().selectedChannelIndex, 0);
      expect(tester.takeException(), isNull);
    },
  );

  focusTestWidgets('the channel list owns the D-pad on entry', (tester) async {
    // The list autofocuses so OK plays immediately — the tabs never autofocus.
    await pumpWideScreen(tester);
    await settle(tester);

    expect(focusLabel(), 'live.channels');
  });

  for (final rowMode in [false, true]) {
    for (final tapToPreview in [false, true]) {
      final mode = rowMode ? 'channel rows' : 'integrated guide';
      final activation = tapToPreview ? 'tap' : 'OK';
      focusTestWidgets(
        'TV $mode $activation preview keeps categories visible',
        (tester) async {
          debugDefaultTargetPlatformOverride = TargetPlatform.android;
          debugIsTelevision = true;
          try {
            final source = _GuideSelectionSource();
            await pumpWideScreenWith(
              tester,
              source,
              size: const Size(960, 540),
              rowMode: rowMode,
            );
            await settle(tester);
            final categoryPane = find.byKey(
              const ValueKey('live.categoryPane'),
            );
            final paneElement = categoryPane.evaluate().single;
            final guideState = rowMode
                ? null
                : tester.state(find.byType(EpgGridScreen));
            Finder previewChannelText(String name) => rowMode
                ? channelText(name)
                : find.descendant(
                    of: find.byType(EpgGridScreen),
                    matching: find.textContaining(name),
                  );
            final preview = find.byKey(const ValueKey('live.previewThumbnail'));
            final initialPreviewLeft = tester.getTopLeft(preview).dx;
            expect(categoryPane, findsOneWidget);
            expect(focusLabel(), 'live.channels');

            if (tapToPreview) {
              await tester.tap(previewChannelText('Channel 0'));
              await tester.pump();
            } else {
              await press(tester, LogicalKeyboardKey.select);
            }
            final selected = await tester.runAsync(
              () => source.selected.future.timeout(const Duration(seconds: 5)),
            );
            expect(selected?.id, 'ch0');
            await settle(tester);

            expect(categoryPane, findsOneWidget);
            expect(categoryPane.evaluate().single, same(paneElement));
            expect(
              tester.getTopLeft(preview).dx,
              initialPreviewLeft,
              reason: 'starting a preview keeps the sidebar and guide layout',
            );
            expect(focusLabel(), 'live.channels');
            if (!rowMode) {
              expect(
                tester.state(find.byType(EpgGridScreen)),
                same(guideState),
              );
            }

            await press(tester, LogicalKeyboardKey.arrowLeft);
            await settle(tester);
            expect(categoryPane, findsOneWidget);
            expect(focusLabel(), 'live.categories');

            await press(tester, LogicalKeyboardKey.arrowRight);
            await settle(tester);
            expect(focusLabel(), 'live.channels');
            expect(
              categoryPane,
              findsOneWidget,
              reason: 'returning to channels keeps the categories open',
            );

            // A second activation waits for fullscreen, but must not lock OK
            // on another channel behind this unresolved provider request.
            await tester.tap(previewChannelText('Channel 0'));
            await tester.pump();
            expect(source.requests, ['ch0']);
            await tester.tap(previewChannelText('Channel 1'));
            await settle(tester);
            expect(source.requests, ['ch0', 'ch1']);
            expect(categoryPane, findsOneWidget);
            expect(focusLabel(), 'live.channels');

            if (rowMode) {
              await back(tester);
              expect(categoryPane, findsOneWidget);
              expect(focusLabel(), 'live.channels');
            }
            await back(tester);
            expect(categoryPane, findsOneWidget);
            expect(focusLabel(), 'live.categories');
            expect(categoryPane.evaluate().single, same(paneElement));
            expect(tester.takeException(), isNull);
          } finally {
            debugDefaultTargetPlatformOverride = null;
            debugIsTelevision = false;
          }
        },
      );
    }
  }

  // ── Channel list: Down wraps, Up escapes ───────────────────────────────────

  focusTestWidgets('Down walks the channel list and wraps past the last row', (
    tester,
  ) async {
    // Keep this viewport short enough that revealing row 11 scrolls the first
    // two rows away even with the combined tabs/search row.
    await pumpWideScreenWith(
      tester,
      _ManySource(),
      size: const Size(1280, 720),
    );
    await settle(tester);
    expect(focusLabel(), 'live.channels');
    // NB: "Channel 0" also appears in the preview panel, so it can't mark the
    // list's scroll position — row 1 can.
    expect(channelText('Channel 1'), findsOneWidget);

    // Walk down far enough that the top of the list is scrolled away.
    await pressTimes(tester, LogicalKeyboardKey.arrowDown, 11);
    expect(
      channelText('Channel 1').hitTestable(),
      findsNothing,
      reason: 'the cursor drove the list past its first rows',
    );
    expect(focusLabel(), 'live.channels');

    // One more press takes the cursor past the last row (index 11) — it wraps
    // back to the top. This is the one infinite motion in the tab.
    await press(tester, LogicalKeyboardKey.arrowDown);
    await settle(tester);
    expect(
      channelText('Channel 1'),
      findsOneWidget,
      reason: 'Down past the last channel wraps to the first',
    );
    expect(
      focusLabel(),
      'live.channels',
      reason: 'the wrap must never leak focus into the categories',
    );
  });

  focusTestWidgets(
    'Up at the first channel escapes to the preview controls — it never wraps',
    (tester) async {
      await pumpWideScreenWith(tester, _ManySource());
      await settle(tester);
      expect(focusLabel(), 'live.channels');

      await press(tester, LogicalKeyboardKey.arrowUp);
      await settle(tester);

      expect(focusLabel(), 'live.preview.favorite');
      expect(
        channelText('Channel 1'),
        findsOneWidget,
        reason: 'Up must not fling the list to its bottom (no wrap-around)',
      );
    },
  );

  focusTestWidgets(
    'narrow layout: Up at the first channel escapes to the search box',
    (tester) async {
      // A phone has no sidebar and no preview panel, so the row above the list is
      // the search box. It still must not wrap to the last channel.
      await pumpNarrowScreenWith(tester, _ManySource());
      await settle(tester);
      expect(find.byType(EpgGridScreen), findsNothing);
      expect(focusLabel(), 'live.channels');

      await press(tester, LogicalKeyboardKey.arrowUp);
      await settle(tester);

      expect(focusLabel(), 'live.search.cell');
      expect(channelText('Channel 0'), findsOneWidget);
    },
  );

  focusTestWidgets(
    'phone menu keeps utility actions reachable and dismisses on Back',
    (tester) async {
      var sourcesOpened = 0;
      final recordingsOpened = Completer<void>();
      await pumpNarrowScreenWith(
        tester,
        _ManySource(),
        onManageSources: () => sourcesOpened++,
        onOpenRecordings: () async => recordingsOpened.complete(),
      );
      await settle(tester);

      await openHome(tester);
      expect(find.byType(AppBar), findsOneWidget);
      expect(find.byIcon(Icons.more_vert), findsOneWidget);
      for (final icon in [Icons.dns_outlined, Icons.video_library_outlined]) {
        expect(
          find.descendant(of: find.byType(AppBar), matching: find.byIcon(icon)),
          findsNothing,
        );
      }

      await tester.tap(find.byTooltip('Menu'));
      await settle(tester);
      for (final label in [
        'Settings',
        'Schedule recording',
        'Recordings',
        'Sources',
        'Help & about',
        'Refresh',
      ]) {
        expect(find.text(label), findsOneWidget);
      }
      for (final label in [
        'Channel settings',
        'Correct EPG / channel matching',
        'Diagnostics',
      ]) {
        expect(find.text(label), findsNothing);
      }
      expect(find.byIcon(Icons.bug_report_outlined), findsNothing);
      expect(tester.takeException(), isNull);

      await back(tester);
      expect(find.byType(PopupMenuItem<String>), findsNothing);
      expect(find.text('Press Back again to exit'), findsNothing);
      expect(find.byKey(const ValueKey('home-live')), findsOneWidget);

      await tester.tap(find.byTooltip('Menu'));
      await settle(tester);
      await tester.tap(find.text('Sources'));
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 100));
      expect(sourcesOpened, 1);
      expect(find.byType(PopupMenuItem<String>), findsNothing);

      await tester.tap(find.byTooltip('Menu'));
      await settle(tester);
      await tester.tap(find.text('Recordings'));
      await tester.runAsync(() => recordingsOpened.future);
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(PopupMenuItem<String>), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  focusTestWidgets(
    'wide Home shows Settings without diagnostics or an empty channel tools menu',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: ChannelListScreen(
            repo: LibraryRepository(source: _FocusDemoSource(), db: db),
            config: config,
            store: store,
          ),
        ),
      );
      await pumpUntil(tester, find.byKey(const ValueKey('home-live')));
      await settle(tester);

      expect(find.byTooltip('Settings'), findsOneWidget);
      expect(find.byTooltip('Diagnostics'), findsNothing);
      expect(find.byIcon(Icons.bug_report_outlined), findsNothing);
      expect(find.byTooltip('Channel tools'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  // ── Cross-pane ─────────────────────────────────────────────────────────────

  focusTestWidgets('Left crosses to the categories and Right crosses back', (
    tester,
  ) async {
    await pumpWideScreenWith(tester, _ManySource());
    await settle(tester);
    expect(focusLabel(), 'live.channels');

    await press(tester, LogicalKeyboardKey.arrowLeft);
    await settle(tester);
    expect(focusLabel(), 'live.categories');

    await press(tester, LogicalKeyboardKey.arrowRight);
    await settle(tester);
    expect(focusLabel(), 'live.channels');
  });

  focusTestWidgets(
    'Left reaches the menu and Down resumes the last TV channel',
    (tester) async {
      await pumpWideScreenWith(
        tester,
        _ManySource(),
        size: const Size(1280, 720),
      );
      await pressTimes(tester, LogicalKeyboardKey.arrowDown, 11);
      final view = tester.widget<LiveTabView>(find.byType(LiveTabView));
      final offset = view.scrollController.offset;
      expect(view.focus.selectedChannelIndex, 11);
      expect(offset, greaterThan(0));

      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(focusLabel(), 'live.categories');
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(focusLabel(), 'library.home');
      await press(tester, LogicalKeyboardKey.arrowDown);
      await settle(tester);
      expect(focusLabel(), 'live.channels');
      expect(view.focus.selectedChannelIndex, 11);
      expect(view.scrollController.offset, closeTo(offset, 1));

      await pressTimes(tester, LogicalKeyboardKey.arrowLeft, 2);
      await press(tester, LogicalKeyboardKey.select);
      expect(find.byKey(const ValueKey('home-live')), findsOneWidget);
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(focusLabel(), 'content.tab.movie');
      await press(tester, LogicalKeyboardKey.select);
      await pumpUntil(
        tester,
        find.byWidgetPredicate(
          (widget) => widget is MediaTabView && !widget.loading,
        ),
      );
      await settle(tester);
      expect(find.byType(LiveTabView), findsNothing);
      // This fixture has no movies; Back still reaches the section's Home control.
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(focusLabel(), 'library.home');
      await press(tester, LogicalKeyboardKey.select);
      await press(tester, LogicalKeyboardKey.arrowLeft);
      await press(tester, LogicalKeyboardKey.select);
      await settle(tester);
      final restored = tester.widget<LiveTabView>(find.byType(LiveTabView));
      expect(focusLabel(), 'live.channels');
      expect(restored.focus.selectedChannelIndex, 11);
      expect(restored.scrollController.offset, closeTo(offset, 1));
      expect(tester.takeException(), isNull);
    },
  );

  for (final kind in [ContentKind.movie, ContentKind.series]) {
    focusTestWidgets(
      '$kind resumes its last poster after Home and section changes',
      (tester) async {
        await pumpWideScreenWith(tester, _MenuMediaSource());
        await openSection(tester, kind);
        await pumpUntil(tester, find.text('${kind.name} 0'));
        final media = tester.widget<MediaTabView>(find.byType(MediaTabView));
        media.scrollController.jumpTo(
          media.scrollController.position.maxScrollExtent / 2,
        );
        await settle(tester);
        final columns = MediaGridMetrics.forSize(
          const Size(1600, 900),
          availableWidth: tester.getSize(find.byType(MediaTabView)).width,
        ).columns;
        final node = tester
            .widgetList<FocusableActionDetector>(
              find.byType(FocusableActionDetector),
            )
            .map((widget) => widget.focusNode)
            .whereType<RoutedFocusNode>()
            .firstWhere((node) {
              final prefix = 'media.item.${kind.name}';
              if (!node.routeKey.startsWith(prefix)) return false;
              return int.parse(node.routeKey.substring(prefix.length)) %
                      columns ==
                  0;
            });
        node.requestFocus();
        await settle(tester);
        final offset = media.scrollController.offset;
        expect(offset, greaterThan(0));
        await press(tester, LogicalKeyboardKey.arrowLeft);
        expect(focusLabel(), 'media.category.all');
        await press(tester, LogicalKeyboardKey.arrowLeft);
        expect(focusLabel(), 'library.home');
        await press(tester, LogicalKeyboardKey.arrowDown);
        expect(focusLabel(), 'media.category.all');
        await press(tester, LogicalKeyboardKey.arrowRight);
        await settle(tester);
        expect(FocusManager.instance.primaryFocus, same(node));
        expect(media.scrollController.offset, closeTo(offset, 2));

        await openSection(
          tester,
          kind == ContentKind.movie ? ContentKind.series : ContentKind.movie,
        );
        await pumpUntil(
          tester,
          find.byWidgetPredicate(
            (widget) =>
                widget is MediaTabView && widget.kind != kind && !widget.loading,
          ),
        );
        await settle(tester);
        expect(
          node.canRequestFocus,
          isFalse,
          reason: 'inactive content is excluded',
        );
        await openSection(tester, kind);
        await settle(tester);
        expect(FocusManager.instance.primaryFocus, same(node));
        expect(media.scrollController.offset, closeTo(offset, 2));
        expect(tester.takeException(), isNull);
      },
    );
  }

  // ── Category sidebar: Down wraps, Up escapes (the "stuck" fix) ─────────────

  focusTestWidgets(
    'Up at the first category escapes to the search box — the "stuck in the '
    'categories" fix',
    (tester) async {
      await pumpWideScreenWith(tester, _ManySource());
      await settle(tester);
      await press(tester, LogicalKeyboardKey.arrowLeft);
      await settle(tester);
      expect(focusLabel(), 'live.categories');
      expect(categoryText('All channels'), findsOneWidget);

      // The cursor starts on "All channels" (index 0). The old model wrapped Up
      // to the last category here, so the only ways out were Right or Back.
      await press(tester, LogicalKeyboardKey.arrowUp);
      await settle(tester);

      expect(focusLabel(), 'live.search.cell');
      expect(
        categoryText('All channels'),
        findsOneWidget,
        reason: 'Up must not wrap the sidebar to its bottom',
      );
    },
  );

  focusTestWidgets('Down wraps at the end of the category sidebar', (
    tester,
  ) async {
    // _ManySource has 30 categories + "All channels" = 31 rows.
    await pumpWideScreenWith(tester, _ManySource());
    await settle(tester);
    await press(tester, LogicalKeyboardKey.arrowLeft);
    await settle(tester);
    expect(focusLabel(), 'live.categories');
    expect(categoryText('All channels'), findsOneWidget);

    await pressTimes(tester, LogicalKeyboardKey.arrowDown, 20);
    expect(
      categoryText('All channels'),
      findsNothing,
      reason: 'the cursor scrolled the sidebar past its first row',
    );
    expect(
      focusLabel(),
      'live.categories',
      reason: 'Down must never spill out of the sidebar',
    );

    // 11 more presses take the cursor past the last category → wraps to the top.
    await pressTimes(tester, LogicalKeyboardKey.arrowDown, 11);
    expect(
      categoryText('All channels'),
      findsOneWidget,
      reason: 'Down past the last category wraps to the first',
    );
  });

  focusTestWidgets('OK filters a category and enters its first channel', (
    tester,
  ) async {
    await pumpWideScreenWith(tester, _ManySource());
    await settle(tester);
    await press(tester, LogicalKeyboardKey.arrowLeft);
    await settle(tester);
    expect(focusLabel(), 'live.categories');

    // cat29 is the final category and contains Channel 6–11. Walking there
    // proves OK changes the data set, not merely the sidebar highlight.
    await pressTimes(tester, LogicalKeyboardKey.arrowDown, 30);
    await press(tester, LogicalKeyboardKey.enter);
    await settle(tester);

    expect(focusLabel(), 'live.channels');
    expect(
      channelText('Channel 6'),
      findsOneWidget,
      reason: 'the first row belongs to the selected category',
    );
    expect(channelText('Channel 0'), findsNothing);
  });

  // ── Search box ─────────────────────────────────────────────────────────────

  focusTestWidgets(
    'the search box drops into the channels and climbs to Home',
    (tester) async {
      await pumpWideScreenWith(tester, _ManySource());
      await settle(tester);

      // Reach the search box from the sidebar (Up at the first category).
      await press(tester, LogicalKeyboardKey.arrowLeft);
      await press(tester, LogicalKeyboardKey.arrowUp);
      await settle(tester);
      expect(focusLabel(), 'live.search.cell');

      // Down goes back into the content.
      await press(tester, LogicalKeyboardKey.arrowDown);
      await settle(tester);
      expect(focusLabel(), 'live.channels');

      // Up from search reaches the Home button — the ceiling.
      await press(tester, LogicalKeyboardKey.arrowLeft);
      await press(tester, LogicalKeyboardKey.arrowUp);
      await settle(tester);
      expect(focusLabel(), 'live.search.cell');
      await press(tester, LogicalKeyboardKey.arrowUp);
      await settle(tester);
      expect(focusLabel(), 'library.home');
    },
  );

  // ── The Back ladder ────────────────────────────────────────────────────────

  focusTestWidgets('Back peels: channel -> first channel -> categories -> first category -> '
      'search -> Home -> landing -> exit', (tester) async {
    final popMethods = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        popMethods.add(call.method);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await pumpWideScreenWith(
      tester,
      _ManySource(),
      size: const Size(1280, 720),
    );
    await settle(tester);
    expect(focusLabel(), 'live.channels');

    // Walk the cursor down the list so the top of the list scrolls away.
    await pressTimes(tester, LogicalKeyboardKey.arrowDown, 11);
    expect(channelText('Channel 1').hitTestable(), findsNothing);

    // Rung 1: Back returns the cursor to the first channel (still in the list).
    await back(tester);
    expect(focusLabel(), 'live.channels');
    expect(
      channelText('Channel 1'),
      findsOneWidget,
      reason: 'the first Back resets the cursor to the first channel',
    );

    // Rung 2: from the first channel, Back leaves the list for the sidebar.
    await back(tester);
    expect(focusLabel(), 'live.categories');

    // Walk the category cursor down, then Rung 3: Back returns it to the first
    // category ("All channels") without leaving the sidebar.
    await pressTimes(tester, LogicalKeyboardKey.arrowDown, 20);
    expect(categoryText('All channels'), findsNothing);
    await back(tester);
    expect(focusLabel(), 'live.categories');
    expect(
      categoryText('All channels'),
      findsOneWidget,
      reason: 'Back resets the category cursor to the first row',
    );

    // Rung 4: from the first category, Back peels to the search box.
    await back(tester);
    expect(focusLabel(), 'live.search.cell');

    // Rung 5: search → the Home button.
    await back(tester);
    expect(focusLabel(), 'library.home');

    // The section's ceiling returns to the landing page.
    await back(tester);
    expect(find.byKey(const ValueKey('home-live')), findsOneWidget);
    expect(find.byType(AppBar), findsOneWidget);

    // The first Back on the landing page arms the exit confirmation.
    await back(tester);
    expect(find.text('Press Back again to exit'), findsOneWidget);
    expect(popMethods, isNot(contains('SystemNavigator.pop')));

    // A second Back inside the window exits.
    await back(tester);
    expect(popMethods, contains('SystemNavigator.pop'));
  });

  focusTestWidgets('the cursor visibly hands over between the panes', (
    tester,
  ) async {
    // The cursor is drawn from each list's `hasFocus`, but a focus change
    // rebuilds nothing on its own — so the accent used to stay stuck in the
    // channel list after Left/Back moved the D-pad to the categories, and the
    // user couldn't see where they were.
    await pumpWideScreenWith(tester, _ManySource());
    await settle(tester);

    // Row 0's name also appears in the preview panel, so drive the cursor to
    // row 1 to keep the finder unambiguous.
    await press(tester, LogicalKeyboardKey.arrowDown);
    await settle(tester);

    Color? borderOf(Finder text) {
      final container = tester.widget<AnimatedContainer>(
        find.ancestor(of: text, matching: find.byType(AnimatedContainer)).first,
      );
      final border = (container.decoration! as BoxDecoration).border;
      return (border! as Border).top.color;
    }

    // The channel list owns the D-pad: its cursor is accented, the sidebar's isn't.
    expect(borderOf(channelText('Channel 1')), AppColors.accent);
    expect(borderOf(categoryText('All channels')), isNot(AppColors.accent));

    // Left hands the D-pad to the categories — the accent must move with it.
    await press(tester, LogicalKeyboardKey.arrowLeft);
    await settle(tester);
    expect(focusLabel(), 'live.categories');
    expect(borderOf(categoryText('All channels')), AppColors.accent);
    expect(
      borderOf(channelText('Channel 1')),
      isNot(AppColors.accent),
      reason:
          'the channel list must not keep the accent once it loses the D-pad',
    );
  });

  focusTestWidgets(
    'Back from the top toolbar offers to exit, not the sections',
    (tester) async {
      // The AppBar/toolbar actions have no route key. They
      // sit *above* the ladder, so Back there should offer to exit rather than
      // dropping focus back down into the sections to be climbed out of again.
      final popMethods = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          popMethods.add(call.method);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      await pumpWideScreen(tester);
      await settle(tester);

      await openHome(tester);
      // Focus an AppBar action on the landing page.
      Focus.of(
        tester.element(
          find.descendant(
            of: find.byType(AppBar),
            matching: find.byIcon(Icons.settings_outlined),
          ),
        ),
      ).requestFocus();
      await tester.pump();
      expect(focusLabel(), '', reason: 'chrome buttons carry no route key');

      await back(tester);
      expect(
        find.text('Press Back again to exit'),
        findsOneWidget,
        reason: 'Back from the chrome goes straight to the exit prompt',
      );
      expect(popMethods, isNot(contains('SystemNavigator.pop')));

      await back(tester);
      expect(popMethods, contains('SystemNavigator.pop'));
    },
  );

  focusTestWidgets(
    'Back recovers to Home from unlabeled focus instead of exiting',
    (tester) async {
      // Arrowing onto an un-routed node (toolbar / AppBar action) leaves
      // focusRouteKey == '', which the ladder must treat as "recover to Home",
      // not "top of the ladder → exit".
      final popMethods = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          popMethods.add(call.method);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      await pumpWideScreen(tester);
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      expect(focusLabel(), '');

      await back(tester);
      expect(
        focusLabel(),
        'library.home',
        reason: 'Back from unlabeled focus should recover to Home',
      );
      expect(popMethods, isNot(contains('SystemNavigator.pop')));
    },
  );

  // ── The per-row favorite star (intra-row action cursor) ────────────────────

  focusTestWidgets(
    'Right highlights the row\'s favorite star and OK toggles it',
    (tester) async {
      await pumpWideScreenWith(tester, _ManySource());
      await settle(tester);
      expect(focusLabel(), 'live.channels');

      // Row 0's name also appears in the preview panel, so drive the cursor to
      // row 1 to keep the finders unambiguous.
      await press(tester, LogicalKeyboardKey.arrowDown);
      await settle(tester);

      Finder rowOf(String name) => find
          .ancestor(
            of: channelText(name),
            matching: find.byType(AnimatedContainer),
          )
          .first;
      Finder starIconIn(String name) => find.descendant(
        of: rowOf(name),
        matching: find.byWidgetPredicate(
          (w) =>
              w is Icon &&
              (w.icon == Icons.star_rounded ||
                  w.icon == Icons.star_outline_rounded),
        ),
      );
      // The star cell is the icon's nearest enclosing Container, and the
      // intra-row cursor's accent ring is its **foreground** decoration — a
      // `decoration` border is reserved as padding, which squeezed the cell
      // below the ten-foot hit target and pushed the glyph off its own centre
      // (see `live_tab_layout_test.dart`).
      Color? starBorderOf(String name) {
        final container = tester.widget<Container>(
          find
              .ancestor(of: starIconIn(name), matching: find.byType(Container))
              .first,
        );
        final border =
            (container.foregroundDecoration as BoxDecoration?)?.border;
        return (border as Border?)?.top.color;
      }

      // Every row carries a visible star; the cursor starts on the row body, so
      // no accent ring on the star yet.
      expect(starIconIn('Channel 1'), findsOneWidget);
      expect(starBorderOf('Channel 1'), isNull);

      // Right enters the row's favorite column — the star gets the accent ring
      // and the D-pad stays in the channel list (no pane change).
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(focusLabel(), 'live.channels');
      expect(starBorderOf('Channel 1'), AppColors.accent);

      // OK toggles the favorite in place: the outline star fills in.
      await press(tester, LogicalKeyboardKey.select);
      await pumpUntil(
        tester,
        find.descendant(
          of: rowOf('Channel 1'),
          matching: find.byIcon(Icons.star_rounded),
        ),
      );
      expect(
        tester.widget<Icon>(starIconIn('Channel 1')).icon,
        Icons.star_rounded,
      );
      expect(
        find.text('Add to favorites'),
        findsNothing,
        reason: 'no dialog: favoriting is in place now',
      );

      // Left peels the cursor back onto the row body before crossing panes.
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(starBorderOf('Channel 1'), isNull);
      expect(focusLabel(), 'live.channels');
      await press(tester, LogicalKeyboardKey.arrowLeft);
      await settle(tester);
      expect(focusLabel(), 'live.categories');
    },
  );

  focusTestWidgets(
    'channel and category rows expose selection, position, and actions',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpWideScreenWith(tester, _ManySource());
      await settle(tester);

      final firstChannel = find.bySemanticsLabel(
        'Channel 0, 1 of 12, Not favorite',
      );
      expect(firstChannel, findsOneWidget);
      expect(
        tester.getSemantics(firstChannel),
        matchesSemantics(
          label: 'Channel 0, 1 of 12, Not favorite',
          isButton: true,
          hasSelectedState: true,
          isSelected: true,
          hasEnabledState: true,
          isEnabled: true,
          hasTapAction: true,
        ),
      );

      const allChannelsLabel = 'All channels, 1 of 31';
      final allChannels = find.bySemanticsLabel(allChannelsLabel);
      expect(allChannels, findsOneWidget);
      expect(
        tester.getSemantics(allChannels),
        matchesSemantics(
          label: allChannelsLabel,
          isButton: true,
          hasSelectedState: true,
          isSelected: true,
          hasTapAction: true,
        ),
      );

      semantics.dispose();
    },
  );

  focusTestWidgets(
    'dismissing the phone preview sheet restores the channel-list focus',
    (tester) async {
      await pumpNarrowScreenWith(tester, _ManySource());
      await settle(tester);
      expect(focusLabel(), 'live.channels');

      await tester.longPress(channelText('Channel 0'));
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('Play fullscreen'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pump(const Duration(milliseconds: 350));
      await settle(tester);

      expect(find.text('Play fullscreen'), findsNothing);
      expect(focusLabel(), 'live.channels');
    },
  );

  focusTestWidgets(
    'Back mirrors Left: it peels the favorite column before the first-row rung',
    (tester) async {
      await pumpWideScreenWith(
        tester,
        _ManySource(),
        size: const Size(1280, 720),
      );
      await settle(tester);
      expect(focusLabel(), 'live.channels');

      // Walk the cursor down the list, then onto row 11's star, so both peels
      // are observable (the row cursor must survive the first Back).
      await pressTimes(tester, LogicalKeyboardKey.arrowDown, 11);
      expect(channelText('Channel 1').hitTestable(), findsNothing);
      await press(tester, LogicalKeyboardKey.arrowRight);
      await settle(tester);

      // Back #1: off the star, back onto the row body — the row cursor (and the
      // scroll position) must not move.
      await back(tester);
      expect(focusLabel(), 'live.channels');
      expect(
        channelText('Channel 1').hitTestable(),
        findsNothing,
        reason: 'peeling the star column must not reset the row cursor',
      );

      // Back #2: now the normal first-channel rung runs.
      await back(tester);
      expect(focusLabel(), 'live.channels');
      expect(channelText('Channel 1'), findsOneWidget);
    },
  );

  // ── Tabs / media (unchanged behaviour, still guarded) ──────────────────────

  for (final kind in [
    ContentKind.live,
    ContentKind.movie,
    ContentKind.series,
  ]) {
    idleTestWidgets('${kind.name} TV search Up reaches Home and OK returns', (
      tester,
    ) async {
      debugIsTelevision = true;
      await pumpWideScreenWith(
        tester,
        _CategoryMediaSource(),
        size: const Size(960, 540),
      );
      await press(tester, LogicalKeyboardKey.arrowLeft);
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(focusLabel(), 'library.home');
      await press(tester, LogicalKeyboardKey.select);
      expect(focusLabel(), 'content.tab.live');

      for (var step = 0; step < kind.index; step++) {
        await press(tester, LogicalKeyboardKey.arrowRight);
      }
      expect(focusLabel(), 'content.tab.${kind.name}');
      await press(tester, LogicalKeyboardKey.select);
      if (kind != ContentKind.live) {
        await pumpUntil(
          tester,
          find.byWidgetPredicate(
            (widget) => widget is MediaTabView && !widget.loading,
          ),
        );
      }
      await press(tester, LogicalKeyboardKey.arrowLeft);
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(focusLabel(), 'library.home');
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(focusLabel(), 'live.search.cell');
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(focusLabel(), 'library.home');
      await press(tester, LogicalKeyboardKey.select);
      expect(find.byKey(ValueKey('home-${kind.name}')), findsOneWidget);
      expect(focusLabel(), 'content.tab.${kind.name}');
    });
  }

  for (final kind in [ContentKind.movie, ContentKind.series]) {
    focusTestWidgets(
      '${kind.name} empty content returns to categories from the toolbar',
      (tester) async {
        await pumpWideScreenWith(tester, _ManySource(), rowMode: false);
        await openSection(tester, kind);
        await pumpUntil(
          tester,
          find.byWidgetPredicate(
            (widget) =>
                widget is MediaTabView &&
                widget.kind == kind &&
                !widget.loading,
          ),
        );
        await tester.binding.handlePopRoute();
        await tester.pump();
        expect(focusLabel(), 'library.home');
        await press(tester, LogicalKeyboardKey.arrowDown);
        expect(focusLabel(), 'media.category.all');
        await press(tester, LogicalKeyboardKey.arrowRight);
        expect(focusLabel(), 'media.category.all');
        await press(tester, LogicalKeyboardKey.arrowUp);
        expect(focusLabel(), 'library.home');
      },
    );

    for (final layout in ['phone', 'desktop', 'tv']) {
      final phone = layout == 'phone';
      final television = layout == 'tv';
      final categoryTestWidgets = television
          ? idleTestWidgets
          : focusTestWidgets;
      categoryTestWidgets(
        '${kind.name} categories use ${phone
            ? 'a phone dropdown'
            : television
            ? 'a TV sidebar'
            : 'a left sidebar'}',
        (tester) async {
          if (television) {
            debugIsTelevision = true;
          }
          if (phone) {
            await pumpNarrowScreenWith(tester, _CategoryMediaSource());
          } else {
            await pumpWideScreenWith(
              tester,
              _CategoryMediaSource(),
              size: television ? const Size(960, 540) : const Size(1600, 900),
              rowMode: false,
            );
          }
          await openSection(tester, kind);
          await pumpUntil(
            tester,
            find.byWidgetPredicate(
              (widget) =>
                  widget is MediaTabView &&
                  widget.kind == kind &&
                  !widget.loading &&
                  widget.visible.isNotEmpty,
            ),
          );

          if (!phone) {
            final pane = find.byKey(
              ValueKey('media.${kind.name}.categoryPane'),
            );
            final paneRect = tester.getRect(pane);
            final mediaRect = tester.getRect(find.byType(MediaTabView));
            expect(paneRect.right, lessThan(mediaRect.left));
            expect(paneRect.top, closeTo(mediaRect.top, 0.001));
            expect(paneRect.height, closeTo(mediaRect.height, 0.001));
            final allRect = tester.getRect(
              find.byKey(const ValueKey('media.category.all')),
            );
            final actionRect = tester.getRect(
              find.byKey(const ValueKey('media.category.action')),
            );
            final comedyRect = tester.getRect(
              find.byKey(const ValueKey('media.category.comedy')),
            );
            expect(allRect.bottom, lessThan(actionRect.top));
            expect(actionRect.bottom, lessThan(comedyRect.top));
            expect(allRect.left, actionRect.left);
            expect(actionRect.left, comedyRect.left);

            await settle(tester);
            final contentFocus = FocusManager.instance.primaryFocus;
            expect(focusLabel(), startsWith('media.'));
            expect(focusLabel(), isNot(startsWith('media.category.')));
            await press(tester, LogicalKeyboardKey.arrowLeft);
            expect(focusLabel(), 'media.category.all');
            await press(tester, LogicalKeyboardKey.arrowRight);
            expect(FocusManager.instance.primaryFocus, same(contentFocus));

            await press(tester, LogicalKeyboardKey.arrowUp);
            expect(focusLabel(), 'library.home');
            await press(tester, LogicalKeyboardKey.arrowDown);
            expect(FocusManager.instance.primaryFocus, same(contentFocus));

            await press(tester, LogicalKeyboardKey.arrowLeft);
            await press(tester, LogicalKeyboardKey.arrowDown);
            expect(focusLabel(), 'media.category.action');
            await press(tester, LogicalKeyboardKey.arrowLeft);
            expect(focusLabel(), 'library.home');
            await press(tester, LogicalKeyboardKey.arrowDown);
            expect(focusLabel(), 'media.category.action');
            await press(tester, LogicalKeyboardKey.arrowRight);
            expect(FocusManager.instance.primaryFocus, same(contentFocus));
            await press(tester, LogicalKeyboardKey.arrowLeft);
            expect(focusLabel(), 'media.category.action');
            await press(tester, LogicalKeyboardKey.arrowDown);
            expect(focusLabel(), 'media.category.comedy');
            await press(tester, LogicalKeyboardKey.arrowDown);
            expect(focusLabel(), 'media.category.comedy');
          }

          Future<void> selectCategory(String label) async {
            if (phone) {
              expect(find.byType(MediaCategoryDropdown), findsOneWidget);
              expect(find.byType(MediaCategoryBar), findsNothing);
              await tester.tap(find.byType(MediaCategoryDropdown));
              await tester.pump(const Duration(milliseconds: 300));
              await tester.tap(find.text(label).last);
              await tester.pump(const Duration(milliseconds: 300));
            } else {
              expect(find.byType(MediaCategoryBar), findsOneWidget);
              expect(find.byType(MediaCategoryDropdown), findsNothing);
              final category = tester.widget<FocusableActionDetector>(
                find.ancestor(
                  of: find.descendant(
                    of: find.byType(MediaCategoryBar),
                    matching: find.text(label),
                  ),
                  matching: find.byType(FocusableActionDetector),
                ),
              );
              category.focusNode!.requestFocus();
              await tester.pump();
              await press(tester, LogicalKeyboardKey.select);
            }
          }

          if (!phone) {
            final poster = find.byType(MediaGridTile).first;
            await tester.ensureVisible(poster);
            tester
                .widget<FocusableActionDetector>(
                  find.descendant(
                    of: poster,
                    matching: find.byType(FocusableActionDetector),
                  ),
                )
                .focusNode!
                .requestFocus();
            await settle(tester);
            expect(focusLabel(), 'media.item.${kind.name}-action');
            await press(tester, LogicalKeyboardKey.arrowLeft);
            expect(focusLabel(), 'media.category.comedy');
          }

          await selectCategory('Comedy');
          await pumpUntil(
            tester,
            find.byWidgetPredicate(
              (widget) =>
                  widget is MediaTabView &&
                  !widget.loading &&
                  widget.categoryFilterActive,
            ),
          );
          var media = tester.widget<MediaTabView>(find.byType(MediaTabView));
          expect(media.categoryFilterActive, isTrue);
          expect(media.visible.map((item) => item.title), [
            '${kind.name} comedy',
          ]);
          expect(find.text('FROM YOUR LIBRARY'), findsNothing);
          if (!phone) {
            expect(focusLabel(), 'media.category.comedy');
            await press(tester, LogicalKeyboardKey.arrowRight);
            expect(media.firstFocusNode!.hasFocus, isTrue);
            await press(tester, LogicalKeyboardKey.arrowLeft);
            expect(focusLabel(), 'media.category.comedy');
          }

          await selectCategory('All categories');
          await pumpUntil(
            tester,
            find.byWidgetPredicate(
              (widget) =>
                  widget is MediaTabView &&
                  !widget.loading &&
                  !widget.categoryFilterActive,
            ),
          );
          media = tester.widget<MediaTabView>(find.byType(MediaTabView));
          expect(media.categoryFilterActive, isFalse);
          expect(media.visible.map((item) => item.categoryId), [
            'action',
            'comedy',
          ]);
          expect(find.text('FROM YOUR LIBRARY'), findsOneWidget);
          if (!phone) {
            expect(focusLabel(), 'media.category.all');
            await press(tester, LogicalKeyboardKey.arrowRight);
            expect(media.firstFocusNode!.hasFocus, isTrue);
          }
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  focusTestWidgets('opening Series from Home swaps out the live pane', (
    tester,
  ) async {
    await pumpWideScreen(tester);
    expect(find.text('Channel groups'), findsOneWidget);
    // Identify the catalogue tile; the featured banner repeats its title.
    final seriesCard = find.descendant(
      of: find.byWidgetPredicate(
        (widget) =>
            widget is MediaGridTile && widget.item.id == 'demo-series-1',
      ),
      matching: find.widgetWithText(FocusableCard, 'Codec Test Series'),
    );

    await openSection(tester, ContentKind.series);
    await tester.pump();
    expect(
      find.text('Channel groups'),
      findsNothing,
      reason: 'live category pane should be gone on a media tab',
    );

    await pumpUntil(tester, seriesCard);
    expect(seriesCard, findsOneWidget);
  });

  focusTestWidgets('media content survives switching sections through Home', (
    tester,
  ) async {
    await pumpWideScreen(tester);
    final seriesCard = find.descendant(
      of: find.byWidgetPredicate(
        (widget) =>
            widget is MediaGridTile && widget.item.id == 'demo-series-1',
      ),
      matching: find.widgetWithText(FocusableCard, 'Codec Test Series'),
    );

    await openSection(tester, ContentKind.series);
    await tester.pump();
    await pumpUntil(tester, seriesCard);
    expect(seriesCard, findsOneWidget);

    await openSection(tester, ContentKind.movie);
    await tester.pump();
    // The Live tab is always present; wait for the movie load itself before
    // switching away, so its follow-up reads finish while the database is open.
    await pumpUntil(tester, find.text('Big Buck Bunny'));
    expect(find.text('Big Buck Bunny'), findsWidgets);
    await openSection(tester, ContentKind.live);
    await tester.pump();
    await pumpUntil(tester, find.text('Channel groups'));
    expect(find.text('Channel groups'), findsOneWidget);

    await openSection(tester, ContentKind.series);
    await tester.pump();
    await pumpUntil(tester, seriesCard);
    expect(
      seriesCard,
      findsOneWidget,
      reason: 'series content should return after round-tripping sections',
    );
  });

  // ── Row extent ─────────────────────────────────────────────────────────────

  focusTestWidgets('a channel row carrying EPG fits its fixed row extent', (
    tester,
  ) async {
    // The lists navigate by `index * itemExtent`, so rows are a FIXED height.
    // A channel with now/next + a progress bar is the tallest row there is — if
    // kChannelRowExtentWithEpg were too small it would overflow, and every other
    // test uses an EPG-less source, so this is the only thing guarding it.
    // Compact TV rows deliberately omit Next when their content cannot fit.
    // Exercise the full desktop row here so both EPG lines must be present.
    final previousPlatform = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await pumpWideScreenWith(tester, _EpgSource());
      await pumpUntil(tester, inChannelList(find.textContaining('Now · ')));
      await settle(tester);

      // A RenderFlex overflow throws, failing the test before we get here.
      expect(inChannelList(find.textContaining('Now · ')), findsWidgets);
      expect(inChannelList(find.textContaining('Next · ')), findsWidgets);
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = previousPlatform;
    }
  });

  focusTestWidgets('a 960x540 TV viewport shows at least three channel rows', (
    tester,
  ) async {
    await pumpWideScreenWith(
      tester,
      _FocusDemoSource(),
      size: const Size(960, 540),
    );

    final thirdRow = channelText('Tears of Steel (H.264)');
    expect(thirdRow, findsOneWidget);
    expect(
      tester.getRect(thirdRow).bottom,
      lessThanOrEqualTo(540),
      reason: 'the compact preview should leave three complete rows visible',
    );
    expect(tester.takeException(), isNull);
  });

  focusTestWidgets('search filters the media grid', (tester) async {
    await pumpWideScreen(tester);
    await openSection(tester, ContentKind.series);
    await tester.pump();
    await pumpUntil(tester, find.text('Codec Test Series'));

    await tester.tap(find.byType(TvTextField));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'zzzznomatch');
    await tester.pump(const Duration(milliseconds: 500));
    await pumpUntil(tester, find.text('No series match'));
    expect(find.text('Codec Test Series'), findsNothing);

    await tester.enterText(find.byType(TextField), 'Codec');
    await tester.pump(const Duration(milliseconds: 500));
    await pumpUntil(tester, find.text('Codec Test Series'));
    expect(find.text('Codec Test Series'), findsOneWidget);
  });

  testWidgets('search hints identify the source and active section', (
    tester,
  ) async {
    try {
      await pumpWideScreenWith(tester, _FocusDemoSource());

      String searchHint() =>
          tester.widget<TvTextField>(find.byType(TvTextField).first).hintText;

      expect(searchHint(), 'Search channels and programmes in this source');

      await openSection(tester, ContentKind.movie);
      await settle(tester);
      expect(searchHint(), 'Search movies in this source');

      await openSection(tester, ContentKind.series);
      await settle(tester);
      expect(searchHint(), 'Search series in this source');

      await openHome(tester);
      await tester.tap(find.byKey(const ValueKey('home-favorites')));
      await settle(tester);
      expect(searchHint(), 'Search favorites across all sources');
    } finally {
      await unmount(tester);
    }
  });

  testWidgets('repository replacement reloads controllers for the new source', (
    tester,
  ) async {
    try {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final firstRepo = LibraryRepository(source: _FocusDemoSource(), db: db);
      await tester.pumpWidget(
        MaterialApp(
          home: ChannelListScreen(
            repo: firstRepo,
            config: config,
            store: store,
          ),
        ),
      );
      await openSection(tester, ContentKind.live);
      await pumpUntil(tester, channelText('Big Buck Bunny (H.264)'));

      final replacementRepo = LibraryRepository(source: _ManySource(), db: db);
      await tester.pumpWidget(
        MaterialApp(
          home: ChannelListScreen(
            repo: replacementRepo,
            config: config,
            store: store,
          ),
        ),
      );
      await pumpUntil(tester, channelText('Channel 0'));

      expect(channelText('Channel 0'), findsOneWidget);
      expect(channelText('Big Buck Bunny (H.264)'), findsNothing);
      expect(find.text('Many'), findsNothing);
    } finally {
      await unmount(tester);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}

class _BrowsingOnlySource extends _FocusDemoSource {
  int resolveCalls = 0;
  @override
  Future<StreamInfo> resolve(Channel channel) async {
    resolveCalls++;
    throw StateError('Browsing must not resolve playback');
  }
}

class _FocusDemoSource extends DemoSource {
  @override
  Future<List<MediaItem>> mediaItems(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    int? maxPages,
  }) async => [
    for (final item in await super.mediaItems(
      kind,
      categoryId: categoryId,
      parent: parent,
      maxPages: maxPages,
    ))
      // These fixtures exercise names, selection and focus, not network artwork.
      item.copyWith(poster: '', backdrop: ''),
  ];
}

/// A live source that actually carries EPG, so the *tall* channel row (name +
/// "Now ·" + progress + "Next ·") gets rendered at its fixed extent. Every other
/// source here returns an empty EPG, which only exercises the compact row.
class _EpgSource implements Source {
  static final DateTime _now = DateTime.now();
  static final List<Channel> _chans = [
    for (var i = 0; i < 3; i++)
      Channel(
        id: 'e$i',
        name: 'Epg Channel $i',
        categoryId: 'c0',
        number: i + 1,
      ),
  ];

  @override
  String get id => 'epgsrc';

  @override
  String get name => 'Epg';

  @override
  Future<void> connect() async {}

  @override
  Future<List<Category>> categories() async => const [
    Category(id: 'c0', title: 'Cat 0'),
  ];

  @override
  Future<List<Channel>> channels({String? categoryId}) async => _chans;

  @override
  Future<StreamInfo> resolve(Channel channel) async =>
      const StreamInfo(url: 'http://stream');

  @override
  Future<StreamInfo> resolveArchive(
    Channel channel,
    Programme programme,
  ) async => throw UnsupportedError('no catch-up');

  @override
  Future<List<Programme>> epg(List<Channel> channels) async => [
    for (final c in _chans) ...[
      Programme(
        channelId: c.id,
        start: _now.subtract(const Duration(minutes: 20)),
        stop: _now.add(const Duration(minutes: 40)),
        title: 'A rather long current programme title for ${c.name}',
      ),
      Programme(
        channelId: c.id,
        start: _now.add(const Duration(minutes: 40)),
        stop: _now.add(const Duration(minutes: 100)),
        title: 'An equally long upcoming programme title',
      ),
    ],
  ];

  @override
  Future<List<MediaCategory>> mediaCategories(ContentKind kind) async =>
      const [];

  @override
  Future<List<MediaItem>> mediaItems(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    int? maxPages,
  }) async => const [];

  @override
  Future<MediaPage> mediaItemsPage(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    int page = 1,
  }) async => MediaPage(items: const [], page: page, totalPages: page);

  @override
  Future<List<MediaItem>> searchMedia(
    ContentKind kind,
    String query, {
    String? categoryId,
  }) async => const [];

  @override
  Future<MediaItem> mediaDetails(MediaItem item) async => item;

  @override
  Future<StreamInfo> resolveMedia(MediaItem item) async =>
      throw UnsupportedError('not playable');

  @override
  Future<SubscriptionExpiry> subscriptionExpiry() async =>
      const SubscriptionExpiry.unknown();

  @override
  Future<void> dispose() async {}
}

/// A live-only source with a sidebar long enough to scroll (30 categories) and
/// enough channels to navigate (12) — the conditions DemoSource can't create.
/// Channels are split between the first and last category so both are non-empty.
class _MenuMediaSource extends _ManySource {
  @override
  Future<List<MediaItem>> mediaItems(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    int? maxPages,
  }) async => [
    for (var i = 0; i < 60; i++)
      MediaItem(id: '${kind.name}$i', title: '${kind.name} $i', kind: kind),
  ];

  @override
  Future<MediaPage> mediaItemsPage(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    int page = 1,
  }) async => MediaPage(items: await mediaItems(kind), page: 1, totalPages: 1);
}

class _CategoryMediaSource extends _MenuMediaSource {
  @override
  Future<List<MediaCategory>> mediaCategories(ContentKind kind) async => [
    MediaCategory(id: 'action', title: 'Action', kind: kind),
    MediaCategory(id: 'comedy', title: 'Comedy', kind: kind),
  ];

  @override
  Future<List<MediaItem>> mediaItems(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    int? maxPages,
  }) async => [
    for (final id in ['action', 'comedy'])
      if (categoryId == null || categoryId == id)
        MediaItem(
          id: '${kind.name}-$id',
          title: '${kind.name} $id',
          kind: kind,
          categoryId: id,
        ),
  ];

  @override
  Future<MediaPage> mediaItemsPage(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    int page = 1,
  }) async => MediaPage(
    items: await mediaItems(kind, categoryId: categoryId),
    page: 1,
    totalPages: 1,
  );
}

class _GuideSelectionSource extends _ManySource {
  final Completer<Channel> selected = Completer<Channel>();
  final Completer<StreamInfo> _pendingStream = Completer<StreamInfo>();
  final requests = <String>[];

  @override
  Future<StreamInfo> resolve(Channel channel) {
    requests.add(channel.id);
    if (!selected.isCompleted) selected.complete(channel);
    // Resolution stays pending: this test observes the real browser playback
    // handoff without opening a network stream in the widget-test process.
    return _pendingStream.future;
  }
}

class _ManySource implements Source {
  static final List<Category> _cats = [
    for (var i = 0; i < 30; i++) Category(id: 'cat$i', title: 'Category $i'),
  ];
  static final List<Channel> _chans = [
    for (var i = 0; i < 12; i++)
      Channel(
        id: 'ch$i',
        name: 'Channel $i',
        categoryId: i < 6 ? 'cat0' : 'cat29',
        number: i + 1,
      ),
  ];

  @override
  String get id => 'many';

  @override
  String get name => 'Many';

  @override
  Future<void> connect() async {}

  @override
  Future<List<Category>> categories() async => _cats;

  @override
  Future<List<Channel>> channels({String? categoryId}) async => _chans;

  @override
  Future<StreamInfo> resolve(Channel channel) async =>
      const StreamInfo(url: 'http://stream');

  @override
  Future<StreamInfo> resolveArchive(
    Channel channel,
    Programme programme,
  ) async => throw UnsupportedError('no catch-up');

  @override
  Future<List<Programme>> epg(List<Channel> channels) async => const [];

  @override
  Future<List<MediaCategory>> mediaCategories(ContentKind kind) async =>
      const [];

  @override
  Future<List<MediaItem>> mediaItems(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    int? maxPages,
  }) async => const [];

  @override
  Future<MediaPage> mediaItemsPage(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    int page = 1,
  }) async => MediaPage(items: const [], page: page, totalPages: page);

  @override
  Future<List<MediaItem>> searchMedia(
    ContentKind kind,
    String query, {
    String? categoryId,
  }) async => const [];

  @override
  Future<MediaItem> mediaDetails(MediaItem item) async => item;

  @override
  Future<StreamInfo> resolveMedia(MediaItem item) async =>
      throw UnsupportedError('not playable');

  @override
  Future<SubscriptionExpiry> subscriptionExpiry() async =>
      const SubscriptionExpiry.unknown();

  @override
  Future<void> dispose() async {}
}
