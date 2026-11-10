// LiveTabView's *layout* contract, independent of ChannelListScreen.
//
// Two things are pinned here, both of which decide whether the wide preview
// panel is reachable at all on a touch device:
//
//   * **One width authority.** Everything that branches on "wide" — the screen's
//     `_isWide()` (which the focus coordinator takes as its `isWide` callback,
//     so it governs where Up escapes and whether Left/Back can reach the
//     sidebar), `_play`'s preview-first-vs-fullscreen split, the long-press
//     gate, and `LiveLayoutMetrics` — reads the *window* width from
//     `MediaQuery`. The body's own constraints are narrower whenever the
//     screen's `SafeArea` eats a left/right system-bar or cutout inset (Android
//     landscape, edge-to-edge). A `LayoutBuilder` here therefore used to render
//     the *phone* layout for a window that every other branch treated as wide,
//     and that band was a dead zone: no preview panel and no long-press sheet,
//     a tap starting an audible preview with nothing on screen showing it, and
//     the Back ladder stalling at rung 2 forever because `focusCategories()`
//     focused a sidebar node that had never been built.
//   * **The hint never names an input the device lacks.** A `deliberate`
//     preview starts on OK *or* on a pointer — tapping a row runs the same
//     `onPlayChannel` path. The wording must say so, or a tablet in landscape
//     reads "Press OK/Select to preview" as an instruction it cannot follow.
//
// These build `LiveTabView` directly with stub callbacks, so they need no
// libmpv and run everywhere (unlike the screen-level tests in
// `channel_list_focus_test.dart`, which construct a real preview player).

import 'dart:collection';

import 'package:flutter/foundation.dart'
    show
        debugDefaultTargetPlatformOverride,
        defaultTargetPlatform,
        TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/data/device_class.dart';
import 'package:iptvs/screens/epg_grid_screen.dart';
import 'package:iptvs/screens/live_focus_coordinator.dart';
import 'package:iptvs/screens/live_tab_view.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/theme.dart' show AppColors, AppTheme, isWideLayout;

void main() {
  setUpAll(() => debugDisableNetworkChannelLogos = true);
  tearDownAll(() => debugDisableNetworkChannelLogos = false);

  // `debugDefaultTargetPlatformOverride` must be cleared *inside* the test body:
  // the framework verifies the foundation debug vars are unset before any
  // `addTearDown` callback runs.
  Future<void> asAndroid(Future<void> Function() body) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await body();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  List<Channel> channels(int count) => [
    for (var i = 0; i < count; i++)
      Channel(id: 'c$i', name: 'Channel $i', number: i + 1),
  ];

  /// Pump a bare `LiveTabView` inside the same `SafeArea` shape the screen uses.
  ///
  /// [size] and [sideInset] are pushed onto the **real test view**, not injected
  /// as a `MediaQueryData` — a widget test's render surface stays 800x600 when
  /// you only override the `MediaQuery`, so an injected size would make the
  /// layout branch and the actual constraints disagree for a reason production
  /// never has. Driving the view reproduces Android landscape under
  /// edge-to-edge exactly: the window is [size] wide, and the screen's SafeArea
  /// hands the body `size.width - sideInset`.
  Future<List<String>> pumpLiveTab(
    WidgetTester tester, {
    required Size size,
    double sideInset = 0,
    bool loading = false,
    bool deliberate = true,
    String? previewChannelId,
    List<Channel>? visible,
    List<Category>? categoryData,
    String? selectedCategoryId,
    double textScale = 1,
    Widget Function()? guideBuilder,
    ValueNotifier<EpgGridSelection?>? guideSelection,
    Widget? header,
    Map<String, Programme> now = const {},
    Map<String, Programme> next = const {},
    void Function(LiveFocusCoordinator)? expose,
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
    tester.view.padding = FakeViewPadding(right: sideInset);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.view.resetPadding();
    });
    final played = <String>[];
    final list = visible ?? channels(6);
    final categoryItems =
        categoryData ?? const [Category(id: 'news', title: 'News')];
    final scroll = ScrollController();
    final categoryScroll = ScrollController();
    // Derive the extents from the *same* metrics the view builds, exactly as
    // `ChannelListScreen._liveChannelRowExtent` does. Hard-coding the base
    // constants here made the harness disagree with the view under any
    // density scaling (Android's compact wide layout drops the plain row to
    // 56 and the category row to 40), which the view now asserts against —
    // the selection model scrolls by `index * extent`, so a harness that
    // pinned one value while the view laid out another was not modelling
    // production at all.
    final metrics = LiveLayoutMetrics.forSize(
      size,
      compactWideLayout: defaultTargetPlatform == TargetPlatform.android,
      textScale: textScale,
    );
    // `now`/`next` are empty below, so rows render without the EPG lines.
    final rowExtent = metrics.channelRowExtent(now.isNotEmpty);
    final focus = LiveFocusCoordinator(
      scrollController: scroll,
      categoryScrollController: categoryScroll,
      visibleChannels: () => list,
      orderedCategoryIds: () => [null, ...categoryItems.map((c) => c.id)],
      channelRowExtent: () => rowExtent,
      categoryRowExtent: () => metrics.categoryRowExtent,
      isWide: () => isWideLayout(size),
      isMounted: () => true,
      onChannelSelectionChanged: (_, _) {},
      onCategoryActivated: (_) {},
      onPlayChannel: (c) => played.add(c.id),
      onToggleFavorite: (_) {},
      onFocusTabs: () {},
    );
    addTearDown(() {
      focus.dispose();
      scroll.dispose();
      categoryScroll.dispose();
    });
    expose?.call(focus);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          body: SafeArea(
            top: false,
            child: Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(textScale)),
                child: LiveTabView(
                  header: header,
                  loading: loading,
                  error: null,
                  onRetry: () {},
                  visible: list,
                  // Mirrors `ChannelListScreen._resolvePreviewChannel`, which
                  // returns null for an empty list rather than throwing.
                  resolvePreviewChannel: () => list.isEmpty
                      ? null
                      : previewChannelId == null
                      ? list.first
                      : list.firstWhere(
                          (channel) => channel.id == previewChannelId,
                          orElse: () => list.first,
                        ),
                  now: now,
                  next: next,
                  showsEpg: now.isNotEmpty,
                  deliberate: deliberate,
                  resolving: false,
                  scrollController: scroll,
                  categoryScrollController: categoryScroll,
                  focus: focus,
                  channelRowExtent: rowExtent,
                  categoryRowExtent: metrics.categoryRowExtent,
                  lastPlayedChannelId: null,
                  previewChannelId: previewChannelId,
                  isFavorite: (_) => false,
                  onToggleFavorite: (_) {},
                  onPlayChannel: (c) => played.add(c.id),
                  onPreviewChannel: (_) {},
                  onCatchup: (_) {},
                  categories: categoryItems,
                  selectedCategoryId: selectedCategoryId,
                  onCategorySelected: (_) {},
                  previewVideoBuilder: () => const SizedBox.shrink(),
                  previewLoading: false,
                  previewError: null,
                  guideBuilder: guideBuilder,
                  guideSelection: guideSelection,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return played;
  }

  // "Channel groups" is the category sidebar's header — it exists only in the wide
  // two-pane layout, alongside the preview panel.
  final sidebar = find.text('Channel groups');

  testWidgets('a refresh keeps the cached guide mounted', (tester) async {
    final at = DateTime.now();
    final current = Programme(
      channelId: 'c0',
      title: 'Cached programme',
      start: at.subtract(const Duration(minutes: 20)),
      stop: at.add(const Duration(minutes: 40)),
    );
    await pumpLiveTab(
      tester,
      size: const Size(1280, 720),
      loading: true,
      now: {'c0': current},
      guideBuilder: () => Text(current.title),
    );
    expect(find.text('Cached programme'), findsWidgets);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('playing preview keeps its details until another activation', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final visible = channels(2);
      final at = DateTime.now();
      final current = {
        for (final channel in visible)
          channel.id: Programme(
            channelId: channel.id,
            title: '${channel.name} current programme',
            description: '${channel.name} current description',
            start: at.subtract(const Duration(minutes: 20)),
            stop: at.add(const Duration(minutes: 40)),
          ),
      };
      final upcoming = {
        for (final channel in visible)
          channel.id: Programme(
            channelId: channel.id,
            title: '${channel.name} next programme',
            description: '${channel.name} next description',
            start: at.add(const Duration(minutes: 40)),
            stop: at.add(const Duration(hours: 2)),
          ),
      };
      final selection = ValueNotifier<EpgGridSelection?>((
        channel: visible.first,
        channelIndex: 0,
        programme: current['c0'],
      ));
      addTearDown(selection.dispose);
      late LiveFocusCoordinator focus;
      await pumpLiveTab(
        tester,
        size: const Size(1280, 800),
        visible: visible,
        previewChannelId: 'c0',
        now: current,
        next: upcoming,
        guideBuilder: () => const SizedBox.expand(),
        guideSelection: selection,
        expose: (value) => focus = value,
      );

      // Moving down to another channel and right to a future programme must
      // leave the channel name, current programme, description and next intact.
      for (final index in [1, 0]) {
        focus.selectChannel(index, reveal: false);
        selection.value = (
          channel: visible[index],
          channelIndex: index,
          programme: upcoming['c$index'],
        );
        await tester.pump();
        expect(find.text('Channel 0'), findsNWidgets(2));
        expect(find.text('Channel 1'), findsNothing);
        expect(
          find.textContaining('Channel 0 current programme'),
          findsOneWidget,
        );
        expect(find.text('Channel 0 current description'), findsOneWidget);
        expect(find.textContaining('Channel 0 next programme'), findsOneWidget);
        expect(
          find.textContaining('Channel 1 current programme'),
          findsNothing,
        );
        expect(find.text('Channel 1 current description'), findsNothing);
        expect(find.textContaining('Channel 1 next programme'), findsNothing);
        expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('live.previewHint')))
              .data,
          index == 0
              ? 'OK or click again for fullscreen'
              : 'OK or click to preview',
        );
      }

      // OK starts the new preview through the controller; its next snapshot
      // supplies the newly active channel even if the guide cursor is elsewhere.
      await pumpLiveTab(
        tester,
        size: const Size(1280, 800),
        visible: visible,
        previewChannelId: 'c1',
        now: current,
        next: upcoming,
        guideBuilder: () => const SizedBox.expand(),
        guideSelection: selection,
      );
      expect(find.text('Channel 1'), findsNWidgets(2));
      expect(find.text('Channel 0'), findsNothing);
      expect(
        find.textContaining('Channel 1 current programme'),
        findsOneWidget,
      );
      expect(find.text('Channel 1 current description'), findsOneWidget);
      expect(find.textContaining('Channel 1 next programme'), findsOneWidget);
      expect(find.textContaining('Channel 0 current programme'), findsNothing);
      expect(find.text('Channel 0 current description'), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('deep guide details avoid walking the channel catalog', (
    tester,
  ) async {
    final visible = _CountedChannels(channels(50000));
    final at = DateTime.now();
    final selection = ValueNotifier<EpgGridSelection?>((
      channel: visible[49999],
      channelIndex: 49999,
      programme: Programme(
        channelId: 'c49999',
        title: 'Last channel guide',
        start: at,
        stop: at.add(const Duration(hours: 1)),
      ),
    ));
    addTearDown(selection.dispose);
    await pumpLiveTab(
      tester,
      size: const Size(1280, 720),
      visible: visible,
      guideBuilder: () => const SizedBox.expand(),
      guideSelection: selection,
    );
    final channel = visible[49998];
    visible.reads = 0;
    selection.value = (
      channel: channel,
      channelIndex: 49998,
      programme: Programme(
        channelId: channel.id,
        title: 'Previous channel guide',
        start: at,
        stop: at.add(const Duration(hours: 1)),
      ),
    );
    await tester.pump();
    expect(find.textContaining('Previous channel guide'), findsOneWidget);
    expect(
      visible.reads,
      lessThan(16),
      reason: 'a guide cursor move must not scan 50,000 channels',
    );
  });

  for (final change in ['reordered', 'removed', 'source replaced']) {
    testWidgets('guide details reject a $change channel snapshot', (
      tester,
    ) async {
      final original = channels(3);
      final at = DateTime.now();
      final selection = ValueNotifier<EpgGridSelection?>((
        channel: original[2],
        channelIndex: 2,
        programme: Programme(
          channelId: original[2].id,
          title: 'Previous snapshot programme',
          start: at,
          stop: at.add(const Duration(hours: 1)),
        ),
      ));
      addTearDown(selection.dispose);
      await pumpLiveTab(
        tester,
        size: const Size(1280, 720),
        visible: original,
        guideBuilder: () => const SizedBox.expand(),
        guideSelection: selection,
      );
      expect(
        find.textContaining('Previous snapshot programme'),
        findsOneWidget,
      );

      final replacement = switch (change) {
        'reordered' => [original[0], original[2], original[1]],
        'removed' => [original[0]],
        _ => channels(3),
      };
      await pumpLiveTab(
        tester,
        size: const Size(1280, 720),
        visible: replacement,
        guideBuilder: () => const SizedBox.expand(),
        guideSelection: selection,
      );
      expect(find.textContaining('Previous snapshot programme'), findsNothing);
      expect(find.text('No programme information'), findsOneWidget);
      expect(tester.takeException(), isNull);

      selection.value = (
        channel: replacement.last,
        channelIndex: replacement.length - 1,
        programme: Programme(
          channelId: replacement.last.id,
          title: 'Current snapshot programme',
          start: at,
          stop: at.add(const Duration(hours: 1)),
        ),
      );
      await tester.pump();
      expect(find.textContaining('Current snapshot programme'), findsOneWidget);
    });
  }

  for (final (size, television) in const [
    (Size(1280, 720), false),
    (Size(873, 491), true),
    (Size(960, 540), true),
  ]) {
    testWidgets('section controls leave categories at the top at $size', (
      tester,
    ) async {
      debugIsTelevision = television;
      addTearDown(() => debugIsTelevision = false);
      const headerKey = ValueKey('live.sectionControls');
      var activated = false;
      await pumpLiveTab(
        tester,
        size: size,
        header: SizedBox(
          key: headerKey,
          height: 56,
          child: TextButton(
            onPressed: () => activated = true,
            child: const Text('Section controls'),
          ),
        ),
      );
      final rail = tester.getRect(
        find.byKey(const ValueKey('live.categoryPane')),
      );
      final controls = tester.getRect(find.byKey(headerKey));
      expect(rail.top, controls.top);
      expect(rail.bottom, greaterThan(controls.bottom));
      expect(controls.top, greaterThanOrEqualTo(0));
      expect(controls.bottom, lessThanOrEqualTo(size.height));
      await tester.tap(find.text('Section controls'));
      expect(activated, isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  group('television layout', () {
    for (final size in const [
      Size(873, 491),
      Size(960, 540),
      Size(1280, 720),
    ]) {
      testWidgets('keeps groups compact and preview hints readable at $size', (
        tester,
      ) async {
        debugIsTelevision = true;
        addTearDown(() => debugIsTelevision = false);
        await asAndroid(() async {
          await pumpLiveTab(
            tester,
            size: size,
            categoryData: const [
              Category(id: 'general', title: 'PL| OGÓLNOTEMATYCZNE'),
              Category(id: 'tvn', title: 'PL| KANAŁY TVN PLAYER'),
            ],
            guideBuilder: () =>
                const SizedBox.expand(key: ValueKey('test.guide')),
          );
          final rail = tester.getRect(
            find.byKey(const ValueKey('live.categoryPane')),
          );
          expect(rail.width, lessThanOrEqualTo(size.width * 0.24));
          expect(
            tester.getTopLeft(find.text('All channels')).dy - rail.top,
            lessThan(70),
          );
          expect(find.text('OK · Preview'), findsOneWidget);
          final thumbnail = tester.getSize(
            find.byKey(const ValueKey('live.previewThumbnail')),
          );
          expect(thumbnail.aspectRatio, closeTo(16 / 9, 0.01));
          expect(tester.takeException(), isNull);
        });
      });
    }

    testWidgets('programme details fit enlarged TV text', (tester) async {
      debugIsTelevision = true;
      addTearDown(() => debugIsTelevision = false);
      final moment = DateTime.now();
      await asAndroid(() async {
        await pumpLiveTab(
          tester,
          size: const Size(960, 540),
          textScale: 1.4,
          visible: const [
            Channel(id: 'c0', name: 'PL-VIP| TVN24 BIS RAW', archiveDays: 7),
          ],
          now: {
            'c0': Programme(
              channelId: 'c0',
              title: 'A long programme title on a television',
              start: moment.subtract(const Duration(minutes: 20)),
              stop: moment.add(const Duration(minutes: 40)),
            ),
          },
          next: {
            'c0': Programme(
              channelId: 'c0',
              title: 'The next programme on this channel',
              start: moment.add(const Duration(minutes: 40)),
              stop: moment.add(const Duration(minutes: 80)),
            ),
          },
          guideBuilder: () => const SizedBox.expand(),
        );
        expect(find.text('OK · Preview'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    });
  });

  group('wide layout width authority', () {
    testWidgets('a window over the threshold is wide', (tester) async {
      await pumpLiveTab(tester, size: const Size(960, 600));
      expect(sidebar, findsOneWidget);
    });

    testWidgets(
      'stays wide when SafeArea insets make the body narrower than the '
      'threshold',
      (tester) async {
        // 960 logical px window, 48 px landscape navigation bar on one side:
        // the body is 912 px. The screen's `_isWide()`, the coordinator's
        // `isWide`, `_play` and the long-press gate all still say wide, so the
        // layout must agree — otherwise the preview panel is gone while a tap
        // still starts a preview only the panel could show.
        await pumpLiveTab(tester, size: const Size(960, 600), sideInset: 48);
        expect(sidebar, findsOneWidget);
      },
    );

    testWidgets('a genuinely narrow window is the phone layout', (
      tester,
    ) async {
      await pumpLiveTab(tester, size: const Size(400, 800));
      expect(sidebar, findsNothing);
    });

    testWidgets('a phone retains touch rows when the wide guide is available', (
      tester,
    ) async {
      var builtGuide = false;
      final played = await pumpLiveTab(
        tester,
        size: const Size(400, 800),
        guideBuilder: () {
          builtGuide = true;
          return const Text('Wide guide');
        },
      );
      expect(builtGuide, isFalse);
      await tester.tap(find.text('Channel 2'));
      await tester.pump();
      expect(played, ['c2']);
      expect(find.text('Wide guide'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('live category rail hierarchy', () {
    const sourceCategories = [
      Category(id: 'general', title: 'PL| OGÓLNOTEMATYCZNE'),
      Category(id: 'tvn', title: 'PL| KANAŁY TVN PLAYER'),
      Category(id: 'documentary', title: 'PL| DOKUMENTALNE'),
    ];

    testWidgets('keeps full source names and widens at desktop size', (
      tester,
    ) async {
      final previousPlatformOverride = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        for (final size in const [Size(960, 540), Size(1266, 714)]) {
          await pumpLiveTab(
            tester,
            size: size,
            categoryData: sourceCategories,
            selectedCategoryId: 'tvn',
          );

          expect(find.text('TV'), findsOneWidget);
          expect(find.text('Live'), findsOneWidget);
          expect(find.text('Channel groups'), findsOneWidget);
          expect(
            tester
                .widget<Text>(
                  find.byKey(const ValueKey('live.activeCategoryLabel')),
                )
                .data,
            'PL| KANAŁY TVN PLAYER',
          );
          for (final category in sourceCategories) {
            expect(
              find.text(category.title),
              findsNWidgets(category.id == 'tvn' ? 2 : 1),
            );
          }

          final railWidth = tester
              .getSize(find.byKey(const ValueKey('live.categoryPane')))
              .width;
          if (size.width == 960) {
            expect(railWidth, 240);
          } else {
            expect(railWidth, greaterThan(280));
          }
          expect(tester.takeException(), isNull);
        }
      } finally {
        debugDefaultTargetPlatformOverride = previousPlatformOverride;
      }
    });

    testWidgets('keeps category focus and index scrolling at 2× text scale', (
      tester,
    ) async {
      final manyCategories = [
        for (var i = 0; i < 24; i++)
          Category(
            id: 'group-$i',
            title: i == 23
                ? 'PL| DŁUGA NAZWA KATEGORII DOKUMENTALNEJ'
                : 'PL| KANAŁY TEMATYCZNE $i',
          ),
      ];
      late LiveFocusCoordinator focus;
      await pumpLiveTab(
        tester,
        size: const Size(960, 540),
        categoryData: manyCategories,
        selectedCategoryId: 'group-23',
        textScale: 2,
        expose: (value) => focus = value,
      );

      final expectedExtent = LiveLayoutMetrics.forSize(
        const Size(960, 540),
        textScale: 2,
      ).categoryRowExtent;
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('live.activeCategoryLabel')),
            )
            .data,
        manyCategories.last.title,
      );
      final listFinder = find.descendant(
        of: find.byKey(const ValueKey('live.categoryPane')),
        matching: find.byType(ListView),
      );
      final categoryList = tester.widget<ListView>(listFinder);
      expect(categoryList.itemExtent, expectedExtent);

      focus.selectCategory(1);
      focus.focusCategories();
      await tester.pumpAndSettle();

      final focusedRow = find.ancestor(
        of: find.text(manyCategories.first.title),
        matching: find.byType(AnimatedContainer),
      );
      final focusedDecoration =
          tester.widget<AnimatedContainer>(focusedRow.first).decoration
              as BoxDecoration;
      expect(focusedDecoration.color, AppColors.accent.withValues(alpha: 0.12));
      expect(focusedDecoration.border!.top.color, AppColors.accent);
      expect(focus.categoriesFocusNode.hasFocus, isTrue);

      focus.selectCategory(24);
      await tester.pumpAndSettle();

      final listHeight = tester.getSize(listFinder).height;
      expect(
        focus.categoryScrollController.offset,
        closeTo(25 * expectedExtent - listHeight, 0.1),
      );
      expect(focus.categoriesFocusNode.hasFocus, isTrue);
      expect(
        find.descendant(
          of: listFinder,
          matching: find.text(manyCategories.last.title),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('preview hint', () {
    testWidgets(
      'guide details fit long programme text at TV and desktop sizes',
      (tester) async {
        final moment = DateTime.now();
        final programme = Programme(
          channelId: 'c0',
          start: moment.subtract(const Duration(minutes: 20)),
          stop: moment.add(const Duration(minutes: 40)),
          title:
              'A very long programme title with enough words to wrap across '
              'both lines in the selected channel details',
          description:
              'A longer programme description with enough context to '
              'fill two lines and exercise the space next to the live preview. '
              'The programme title, favorite control and playback hint stay visible.',
        );
        await asAndroid(() async {
          await pumpLiveTab(
            tester,
            size: const Size(950, 540),
            now: {'c0': programme},
            guideBuilder: () => const Center(child: Text('Timeline')),
          );
          expect(tester.takeException(), isNull);
        });
        await pumpLiveTab(
          tester,
          size: const Size(1280, 800),
          now: {'c0': programme},
          guideBuilder: () => const Center(child: Text('Timeline')),
        );
        expect(tester.takeException(), isNull);
        expect(find.text('Timeline'), findsOneWidget);
      },
    );

    testWidgets('a deliberate preview names the pointer, not only OK', (
      tester,
    ) async {
      await asAndroid(() async {
        await pumpLiveTab(tester, size: const Size(1280, 800));

        // The panel must not instruct a touch-only tablet to press a key it
        // has no way to send.
        expect(find.text('Press OK/Select to preview'), findsNothing);
        expect(find.text('OK or tap to preview'), findsOneWidget);
      });
    });

    testWidgets('tapping a channel row runs the play/preview path', (
      tester,
    ) async {
      await asAndroid(() async {
        // The rows are not focus targets (selection model), but they stay
        // tappable — that tap is what makes the hint above satisfiable without
        // a remote, because it runs the same `onPlayChannel` → `_play` path OK
        // does: preview first, fullscreen on the second activation.
        final played = await pumpLiveTab(tester, size: const Size(1280, 800));
        await tester.tap(find.text('Channel 2'));
        await tester.pump();
        expect(played, ['c2']);
      });
    });
  });

  group('the favorite star cell', () {
    // Regression: the accent ring was a `decoration` border, which *adds* its
    // width to the cell — 20 (icon) + 12 (padding) + 4 (border) = 36. That
    // fits the 44 px pointer target but not the ten-foot 32 px one, so the
    // `Center` above squeezed the cell back to 32, the `Icon` collapsed 20 →
    // 16, and a 20 px glyph paints from the *top-left* of the box it
    // overflows: on a TV the star sat ~2 px down and right of the ring drawn
    // around it. The ring is a `foregroundDecoration` now, which costs no
    // layout.
    final rowStar = find
        .descendant(
          of: find.byType(IndexedSemantics),
          matching: find.byIcon(Icons.star_outline_rounded),
        )
        .first;

    testWidgets('the ring does not move or shrink the glyph', (tester) async {
      await asAndroid(() async {
        late final LiveFocusCoordinator focus;
        await pumpLiveTab(
          tester,
          size: const Size(960, 540),
          expose: (f) => focus = f,
        );

        final size = tester.getSize(rowStar);
        final center = tester.getCenter(rowStar);
        expect(size, const Size(20, 20), reason: 'the icon is not squeezed');

        // Right enters the row's favorite column, which draws the ring.
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
        expect(focus.channelColumn, ChannelRowColumn.favorite);

        expect(tester.getSize(rowStar), size);
        expect(tester.getCenter(rowStar), center);
      });
    });

    // The same property `channel_list_focus_test.dart` asserts — but that file
    // builds a real preview player, so 22 of its 23 tests skip on any machine
    // without libmpv and the whole thing runs only on CI. Reading the ring here
    // too means a change that moves it back onto `decoration` fails on a
    // developer's own `flutter test`, not two pushes later.
    testWidgets('the ring is painted, not laid out', (tester) async {
      await asAndroid(() async {
        late final LiveFocusCoordinator focus;
        await pumpLiveTab(
          tester,
          size: const Size(960, 540),
          expose: (f) => focus = f,
        );

        Border? ring() {
          final cell = tester.widget<Container>(
            find.ancestor(of: rowStar, matching: find.byType(Container)).first,
          );
          expect(
            (cell.decoration as BoxDecoration?)?.border,
            isNull,
            reason: 'a decoration border would inset the glyph',
          );
          return (cell.foregroundDecoration as BoxDecoration?)?.border
              as Border?;
        }

        expect(ring(), isNull, reason: 'the cursor starts on the row body');

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
        expect(focus.channelColumn, ChannelRowColumn.favorite);
        expect(ring()?.top.color, AppColors.accent);
      });
    });

    testWidgets('the cell fits the ten-foot hit target', (tester) async {
      await asAndroid(() async {
        await pumpLiveTab(tester, size: const Size(960, 540));
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();

        final target = LiveLayoutMetrics.forSize(
          const Size(960, 540),
          compactWideLayout: true,
        ).favoriteTargetSize;
        final cell = tester
            .renderObjectList<RenderBox>(
              find.ancestor(of: rowStar, matching: find.byType(Container)),
            )
            .first;
        expect(cell.size.width, lessThanOrEqualTo(target));
        expect(cell.size.height, lessThanOrEqualTo(target));
      });
    });
  });

  group('an empty channel list keeps the category sidebar', () {
    // Regression: the empty-state `Center` used to be returned *before* the
    // width branch, so on a wide layout it replaced the whole tab — sidebar
    // included. `ChannelListScreen` nulls the toolbar's category dropdown
    // whenever live && wide, so with the sidebar gone there was no remaining
    // caller of `_selectCategory` at all: picking a provider category that
    // happens to have zero channels (common on portals) stranded the user
    // there until the app was restarted.
    testWidgets('wide keeps the sidebar and shows the message beside it', (
      tester,
    ) async {
      await pumpLiveTab(tester, size: const Size(1280, 800), visible: const []);
      expect(sidebar, findsOneWidget, reason: 'the way back must survive');
      expect(find.textContaining('has no channels'), findsOneWidget);
    });

    testWidgets(
      'narrow still replaces the body (the dropdown is the way back)',
      (tester) async {
        await pumpLiveTab(
          tester,
          size: const Size(500, 800),
          visible: const [],
        );
        expect(sidebar, findsNothing);
        expect(find.textContaining('has no channels'), findsOneWidget);
      },
    );
  });
}

class _CountedChannels extends ListBase<Channel> {
  _CountedChannels(this._channels);

  final List<Channel> _channels;
  int reads = 0;

  @override
  int get length => _channels.length;

  @override
  set length(int value) => throw UnsupportedError('Read-only catalog');

  @override
  Channel operator [](int index) {
    reads++;
    return _channels[index];
  }

  @override
  void operator []=(int index, Channel value) =>
      throw UnsupportedError('Read-only catalog');
}
