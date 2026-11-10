import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/screens/channel_list_chrome.dart';
import 'package:iptvs/screens/media_tab_controller.dart';
import 'package:iptvs/screens/media_tab_view.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/theme.dart';
import 'package:iptvs/widgets/routed_focus_node.dart';

List<MediaItem> _items(
  ContentKind kind, {
  String prefix = 'item',
  int count = 18,
}) => [
  for (var i = 0; i < count; i++)
    MediaItem(id: '$prefix$i', title: 'Title $i', kind: kind),
];

Future<
  ({
    FocusNode first,
    FocusNode tabs,
    List<FocusNode?> origins,
    ValueChanged<bool> setLoading,
  })
>
_pumpMedia(
  WidgetTester tester, {
  ContentKind kind = ContentKind.movie,
  Size size = const Size(960, 540),
  bool filtered = true,
  bool withShelves = false,
  bool withContinueWatching = false,
  bool animations = false,
  int itemCount = 18,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  final first = RoutedFocusNode('media.${kind.name}.first');
  final tabs = RoutedFocusNode('tabs.${kind.name}');
  final scroll = ScrollController();
  final origins = <FocusNode?>[];
  var loading = false;
  late StateSetter rebuild;
  final items = _items(kind, count: itemCount);
  final category = MediaCategory(
    id: 'action',
    title: 'Action',
    kind: kind,
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    first.dispose();
    tabs.dispose();
    scroll.dispose();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.dark,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: !animations),
        child: child!,
      ),
      home: Scaffold(
        body: FocusTraversalGroup(
          child: Column(
            children: [
              TextButton(
                focusNode: tabs,
                onPressed: () {},
                child: const Text('Tabs'),
              ),
              Expanded(
                child: StatefulBuilder(
                  builder: (context, setState) {
                    rebuild = setState;
                    return MediaTabView(
                      kind: kind,
                      visible: items,
                      snapshot: null,
                      loading: loading,
                      loadingMore: false,
                      error: null,
                      showingSearch: false,
                      categoryFilterActive: filtered,
                      categories: withShelves ? [category] : const [],
                      loadCategory: withShelves
                          ? (_) async => _items(kind, prefix: 'category')
                          : null,
                      lastPlayedId: null,
                      scrollController: scroll,
                      firstFocusNode: first,
                      onFocusTabs: () {
                        origins.add(FocusManager.instance.primaryFocus);
                        tabs.requestFocus();
                      },
                      onFocusToolbar: tabs.requestFocus,
                      isFavorite: (_) => false,
                      onOpenMedia: (_) {},
                      onLoadMore: () {},
                      onRetry: () {},
                      continueWatching: withContinueWatching
                          ? [
                              for (final item in items.take(3))
                                ContinueWatchingEntry(
                                  item: item,
                                  position: PlaybackPosition(
                                    kind: kind,
                                    itemId: item.id,
                                    position: const Duration(minutes: 5),
                                    duration: const Duration(hours: 1),
                                    updatedAt: DateTime(2026),
                                  ),
                                ),
                            ]
                          : const [],
                      onResume: (_) {},
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (
    first: first,
    tabs: tabs,
    origins: origins,
    setLoading: (value) => rebuild(() => loading = value),
  );
}

String _focusedRoute() => focusRouteKey(FocusManager.instance.primaryFocus);

Future<void> _focusPoster(WidgetTester tester, String id) async {
  final tile = find.byWidgetPredicate(
    (widget) => widget is MediaGridTile && widget.item.id == id,
  );
  await tester.ensureVisible(tile);
  final detector = tester.widget<FocusableActionDetector>(
    find.descendant(of: tile, matching: find.byType(FocusableActionDetector)),
  );
  detector.focusNode!.requestFocus();
  await tester.pumpAndSettle();
}

Future<void> _pressLeft(WidgetTester tester) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('category arrows stay in the rail and Up exits at its start', (
    tester,
  ) async {
    final toolbar = FocusNode();
    final content = FocusNode();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      toolbar.dispose();
      content.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              TextButton(
                focusNode: toolbar,
                onPressed: () {},
                child: const Text('Toolbar'),
              ),
              Expanded(
                child: Row(
                  children: [
                    MediaCategoryBar(
                      categories: const [
                        MediaCategory(
                          id: 'action',
                          title: 'Action',
                          kind: ContentKind.movie,
                        ),
                      ],
                      value: null,
                      onChanged: (_) {},
                      onFocusTabs: toolbar.requestFocus,
                      onFocusContent: content.requestFocus,
                    ),
                    Expanded(
                      child: Align(
                        alignment: Alignment.bottomRight,
                        child: TextButton(
                          focusNode: content,
                          onPressed: () {},
                          child: const Text('Content'),
                        ),
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
    final all = tester
        .widget<FocusableActionDetector>(
          find.descendant(
            of: find.byKey(const ValueKey('media.category.all')),
            matching: find.byType(FocusableActionDetector),
          ),
        )
        .focusNode!;
    all.requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(_focusedRoute(), 'media.category.action');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(_focusedRoute(), 'media.category.action');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(all.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(toolbar.hasFocus, isTrue);
  });

  for (final kind in [ContentKind.movie, ContentKind.series]) {
    testWidgets('${kind.name} completed loading does not steal toolbar focus', (
      tester,
    ) async {
      final view = await _pumpMedia(tester, kind: kind);
      view.setLoading(true);
      await tester.pump();
      view.tabs.requestFocus();
      await tester.pump();
      view.setLoading(false);
      await tester.pumpAndSettle();
      expect(view.tabs.hasFocus, isTrue);
      view.first.requestFocus();
      await tester.pumpAndSettle();
      expect(view.first.hasFocus, isTrue);
    });

    testWidgets('${kind.name} Up from the first grid row reaches the toolbar', (
      tester,
    ) async {
      final view = await _pumpMedia(tester, kind: kind);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(view.tabs.hasFocus, isTrue);
    });

    testWidgets('${kind.name} held Right keeps a long shelf visible', (
      tester,
    ) async {
      await _pumpMedia(
        tester,
        kind: kind,
        filtered: false,
        withShelves: true,
        itemCount: 120,
        animations: true,
      );
      await _focusPoster(tester, 'item0');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 40));
      for (var step = 1; step < 40; step++) {
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump(const Duration(milliseconds: 40));
        expect(_focusedRoute(), 'media.item.item${step + 1}');
        final rect = FocusManager.instance.primaryFocus!.rect;
        expect(rect.right, lessThanOrEqualTo(960.01));
        expect(rect.left, greaterThanOrEqualTo(-0.01));
      }
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
    });

    testWidgets('${kind.name} held Down keeps a long grid visible', (
      tester,
    ) async {
      await _pumpMedia(tester, kind: kind, itemCount: 240, animations: true);
      final columns = MediaGridMetrics.forSize(const Size(960, 540)).columns;
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump(const Duration(milliseconds: 40));
      for (var step = 1; step < 20; step++) {
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump(const Duration(milliseconds: 40));
        expect(_focusedRoute(), 'media.item.item${(step + 1) * columns}');
        final rect = FocusManager.instance.primaryFocus!.rect;
        expect(rect.bottom, lessThanOrEqualTo(540.01));
        expect(rect.top, greaterThanOrEqualTo(47.99));
      }
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
    });
  }

  for (final kind in [ContentKind.movie, ContentKind.series]) {
    testWidgets('${kind.name} grid keeps Left local until the first column', (
      tester,
    ) async {
      final view = await _pumpMedia(tester, kind: kind);
      expect(view.first.hasFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(_focusedRoute(), 'media.item.item1');
      await _pressLeft(tester);
      expect(view.first.hasFocus, isTrue);
      expect(view.origins, isEmpty);

      await _pressLeft(tester);
      expect(view.tabs.hasFocus, isTrue);
      expect(view.origins, [view.first]);
      expect(tester.takeException(), isNull);
    });

    testWidgets('${kind.name} grid exits from the first column below row one', (
      tester,
    ) async {
      final view = await _pumpMedia(tester, kind: kind);
      final columns = MediaGridMetrics.forSize(const Size(960, 540)).columns;
      await _focusPoster(tester, 'item$columns');
      final origin = FocusManager.instance.primaryFocus;

      await _pressLeft(tester);
      expect(view.tabs.hasFocus, isTrue);
      expect(view.origins, [origin]);
      expect(tester.takeException(), isNull);
    });

    testWidgets('${kind.name} short list exits from a later row', (
      tester,
    ) async {
      final view = await _pumpMedia(
        tester,
        kind: kind,
        size: const Size(600, 400),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(_focusedRoute(), 'media.item.item1');
      final origin = FocusManager.instance.primaryFocus;

      await _pressLeft(tester);
      expect(view.tabs.hasFocus, isTrue);
      expect(view.origins, [origin]);
      expect(tester.takeException(), isNull);
    });
  }

  for (final kind in [ContentKind.movie, ContentKind.series]) {
    testWidgets('${kind.name} shelves exit only from their first poster', (
      tester,
    ) async {
      final view = await _pumpMedia(
        tester,
        kind: kind,
        filtered: false,
        withShelves: true,
      );
      await _focusPoster(tester, 'item0');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(_focusedRoute(), 'media.item.item1');
      await _pressLeft(tester);
      expect(_focusedRoute(), 'media.item.item0');
      expect(view.origins, isEmpty);

      await _focusPoster(tester, 'category0');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(_focusedRoute(), 'media.item.category1');
      await _pressLeft(tester);
      expect(_focusedRoute(), 'media.item.category0');
      expect(view.origins, isEmpty);
      final origin = FocusManager.instance.primaryFocus;

      await _pressLeft(tester);
      expect(view.tabs.hasFocus, isTrue);
      expect(view.origins, [origin]);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Continue watching exits only from its first card', (
    tester,
  ) async {
    final view = await _pumpMedia(
      tester,
      filtered: false,
      withContinueWatching: true,
    );
    final firstContinue = find.byWidgetPredicate(
      (widget) =>
          widget is FocusableActionDetector &&
          widget.focusNode?.debugLabel == 'media.continue.item0',
    );
    await tester.ensureVisible(firstContinue);
    tester
        .widget<FocusableActionDetector>(firstContinue)
        .focusNode!
        .requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(_focusedRoute(), 'media.continue.item1');

    await _pressLeft(tester);
    expect(_focusedRoute(), 'media.continue.item0');
    expect(view.origins, isEmpty);
    final origin = FocusManager.instance.primaryFocus;
    await _pressLeft(tester);
    expect(view.tabs.hasFocus, isTrue);
    expect(view.origins, [origin]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('feature details moves left locally before the primary exits', (
    tester,
  ) async {
    final view = await _pumpMedia(tester, filtered: false);
    expect(view.first.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(_focusedRoute(), 'media.featured.details');

    await _pressLeft(tester);
    expect(view.first.hasFocus, isTrue);
    expect(view.origins, isEmpty);
    await _pressLeft(tester);
    expect(view.tabs.hasFocus, isTrue);
    expect(view.origins, [view.first]);
    expect(tester.takeException(), isNull);
  });
}
