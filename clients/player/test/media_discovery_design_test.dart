import 'dart:async';
import 'dart:collection';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/screens/channel_list_chrome.dart';
import 'package:iptvs/screens/media_tab_controller.dart';
import 'package:iptvs/screens/media_tab_view.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/theme.dart';
import 'package:iptvs/widgets/routed_focus_node.dart';

const _movie = MediaItem(
  id: 'featured',
  title: 'The River at Midnight',
  kind: ContentKind.movie,
  year: '2025',
  rating: 8.3,
  durationSeconds: 7320,
  description:
      'A journey along the river brings an unexpected discovery. '
      'One night changes the course of a small town.',
);

List<MediaItem> _items({ContentKind kind = ContentKind.movie}) => [
  _movie.copyWith(kind: kind),
  for (var i = 1; i < 30; i++)
    MediaItem(
      id: 'item$i',
      title: 'Library title $i',
      kind: kind,
      year: '2024',
    ),
];

const _categories = [
  MediaCategory(
    id: 'action',
    title: 'Action & adventure',
    kind: ContentKind.movie,
  ),
  MediaCategory(id: 'comedy', title: 'Comedy', kind: ContentKind.movie),
  MediaCategory(id: 'drama', title: 'Drama', kind: ContentKind.movie),
];

List<MediaCategory> _categoriesFor(ContentKind kind) => [
  for (final category in _categories)
    MediaCategory(id: category.id, title: category.title, kind: kind),
];

List<MediaItem> _categoryItems(MediaCategory category) => [
  for (var i = 0; i < 12; i++)
    MediaItem(
      id: '${category.id}-$i',
      title: '${category.title} title $i',
      kind: category.kind,
      year: '2025',
    ),
];

Finder _inMedia(Finder matching) =>
    find.descendant(of: find.byType(MediaTabView), matching: matching);

MediaItem? _focusedMedia() => FocusManager.instance.primaryFocus?.context
    ?.findAncestorWidgetOfExactType<MediaGridTile>()
    ?.item;

class _ObservedMediaList extends ListBase<MediaItem> {
  final List<MediaItem> _items;
  int iterations = 0;

  _ObservedMediaList(this._items);

  @override
  Iterator<MediaItem> get iterator {
    iterations++;
    return _items.iterator;
  }

  @override
  int get length => _items.length;
  @override
  set length(int value) => throw UnsupportedError('read only');
  @override
  MediaItem operator [](int index) => _items[index];
  @override
  void operator []=(int index, MediaItem value) =>
      throw UnsupportedError('read only');
}

Future<
  ({
    ScrollController scroll,
    FocusNode first,
    ValueChanged<List<MediaItem>> updateVisible,
  })
>
_pumpMedia(
  WidgetTester tester, {
  Size size = const Size(1280, 720),
  double textScale = 1,
  ContentKind kind = ContentKind.movie,
  bool searching = false,
  bool category = false,
  String? lastPlayed,
  bool withContinueWatching = false,
  bool withChrome = false,
  bool animations = false,
  List<MediaCategory> categories = const [],
  Future<List<MediaItem>> Function(MediaCategory)? loadCategory,
  ValueChanged<MediaCategory>? onExpandCategory,
  ValueChanged<MediaItem>? onOpen,
  ValueChanged<MediaItem>? onPlay,
  MediaLibrarySnapshot? snapshot,
  List<MediaItem>? visible,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  final scroll = ScrollController();
  final first = RoutedFocusNode('media.${kind.name}.first');
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    scroll.dispose();
    first.dispose();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  var items = visible ?? _items(kind: kind);
  late StateSetter rebuild;
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.dark,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          disableAnimations: !animations,
        ),
        child: child!,
      ),
      home: Scaffold(
        appBar: withChrome
            ? AppBar(toolbarHeight: 64, title: const Text('TVBro'))
            : null,
        body: StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            final media = MediaTabView(
              kind: kind,
              visible: items,
              snapshot: snapshot,
              loading: false,
              loadingMore: false,
              error: null,
              showingSearch: searching,
              categoryFilterActive: category,
              categories: categories,
              loadCategory: loadCategory,
              onExpandCategory: onExpandCategory,
              lastPlayedId: lastPlayed,
              scrollController: scroll,
              firstFocusNode: first,
              isFavorite: (_) => false,
              onOpenMedia: onOpen ?? (_) {},
              onLoadMore: () {},
              onRetry: () {},
              continueWatching: withContinueWatching
                  ? [
                      ContinueWatchingEntry(
                        item: kind == ContentKind.series
                            ? const MediaItem(
                                id: 'episode',
                                title: 'The first episode',
                                kind: ContentKind.episode,
                                seasonNumber: 1,
                                episodeNumber: 1,
                              )
                            : items.first,
                        seriesTitle: kind == ContentKind.series
                            ? items.first.title
                            : null,
                        position: PlaybackPosition(
                          kind: kind == ContentKind.series
                              ? ContentKind.episode
                              : kind,
                          itemId: kind == ContentKind.series
                              ? 'episode'
                              : items.first.id,
                          position: const Duration(minutes: 12),
                          duration: const Duration(hours: 2),
                          updatedAt: DateTime(2026, 1, 1),
                        ),
                      ),
                    ]
                  : const [],
              onResume: onPlay ?? (_) {},
            );
            if (!withChrome) return media;
            return Column(
              children: [
                const SizedBox(height: 56),
                Expanded(
                  child: Row(
                    children: [
                      MediaCategoryBar(
                        categories: categories,
                        value: null,
                        onChanged: (_) {},
                      ),
                      Expanded(child: media),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return (
    scroll: scroll,
    first: first,
    updateVisible: (value) => rebuild(() => items = value),
  );
}

void main() {
  for (final kind in [ContentKind.movie, ContentKind.series]) {
    final categories = _categoriesFor(kind);
    testWidgets('${kind.name} shelves reuse the complete filtered catalog', (
      tester,
    ) async {
      final catalog = [
        for (var i = 0; i < 1000; i++)
          for (final category in categories)
            MediaItem(
              id: '${category.id}-$i',
              title: '${category.title} title $i',
              kind: kind,
              categoryId: category.id,
            ),
      ];
      final visible = _ObservedMediaList([
        for (final item in catalog)
          if (!item.id.endsWith('-0')) item,
      ]);
      var loads = 0;
      var reloadedItems = 0;
      final view = await _pumpMedia(
        tester,
        kind: kind,
        categories: categories,
        visible: visible,
        snapshot: MediaLibrarySnapshot(
          kind: kind,
          categories: categories,
          items: catalog,
          fromCache: true,
          syncedAt: null,
        ),
        loadCategory: (category) async {
          loads++;
          final items = <MediaItem>[];
          for (final item in catalog) {
            if (item.categoryId != category.id) continue;
            reloadedItems++;
            items.add(item.copyWith());
          }
          return items.where((item) => !item.id.endsWith('-0')).toList();
        },
      );

      final firstTiles = <MediaGridTile>[];
      for (final category in categories) {
        final shelf = _inMedia(find.byKey(ValueKey(category.id)));
        await tester.scrollUntilVisible(
          find.descendant(of: shelf, matching: find.text(category.title)),
          200,
          scrollable: _inMedia(find.byType(Scrollable)).first,
        );
        await tester.pump();
        final first = tester.widget<MediaGridTile>(
          find
              .descendant(of: shelf, matching: find.byType(MediaGridTile))
              .first,
        );
        firstTiles.add(first);
      }
      // Counts model the category rows materialized by the existing callback;
      // the full 3,000-item root catalog is already available before scrolling.
      // ignore: avoid_print
      print(
        'MEDIA_SHELF_WORK kind=${kind.name} categoryLoads=$loads reloadedItems=$reloadedItems',
      );
      expect(loads, 0);
      expect(reloadedItems, 0);
      expect(visible.iterations, 1);
      for (var i = 0; i < categories.length; i++) {
        final first = firstTiles[i];
        expect(first.item.id, '${categories[i].id}-1');
        expect(
          first.item,
          same(catalog.firstWhere((item) => item.id == first.item.id)),
        );
        expect(first.total, 14);
      }

      final lastShelf = _inMedia(find.byKey(ValueKey(categories.last.id)));
      final firstTile = find
          .descendant(of: lastShelf, matching: find.byType(MediaGridTile))
          .first;
      final focusedNode = tester
          .widget<Focus>(
            find.descendant(
              of: firstTile,
              matching: find.byWidgetPredicate(
                (widget) =>
                    widget is Focus &&
                    focusRouteKey(widget.focusNode) ==
                        'media.item.${categories.last.id}-1',
              ),
            ),
          )
          .focusNode!;
      focusedNode.requestFocus();
      await tester.pump();
      view.updateVisible(visible);
      await tester.pump();
      expect(
        visible.iterations,
        1,
        reason: 'stable-list rebuilds reuse previews',
      );
      expect(loads, 0);
      expect(FocusManager.instance.primaryFocus, same(focusedNode));

      final replacement = _ObservedMediaList([
        for (final item in catalog)
          if (!item.id.endsWith('-0') && !item.id.endsWith('-1'))
            item.copyWith(title: 'Updated ${item.title}'),
      ]);
      view.updateVisible(replacement);
      await tester.pump();
      final shelf = _inMedia(find.byKey(ValueKey(categories.last.id)));
      final updated = tester.widget<MediaGridTile>(
        find.descendant(of: shelf, matching: find.byType(MediaGridTile)).first,
      );
      expect(updated.item.id, '${categories.last.id}-2');
      expect(updated.item.title, startsWith('Updated '));
      expect(updated.total, 14);
      expect(replacement.iterations, 1);
      expect(loads, 0);
      expect(tester.takeException(), isNull);
    });

    for (final incomplete in ['paged', 'category', 'parent', 'other kind']) {
      testWidgets('${kind.name} shelves load $incomplete snapshots normally', (
        tester,
      ) async {
        final loaded = <String>[];
        final category = categories.first;
        await _pumpMedia(
          tester,
          kind: kind,
          categories: [category],
          snapshot: MediaLibrarySnapshot(
            kind: incomplete == 'other kind'
                ? (kind == ContentKind.movie
                      ? ContentKind.series
                      : ContentKind.movie)
                : kind,
            categoryId: incomplete == 'category' ? category.id : null,
            parentId: incomplete == 'parent' ? 'parent' : null,
            categories: [category],
            items: _items(kind: kind),
            fromCache: true,
            syncedAt: null,
            totalPages: incomplete == 'paged' ? 2 : 1,
          ),
          loadCategory: (category) async {
            loaded.add(category.id);
            return _categoryItems(category);
          },
        );
        final shelf = _inMedia(find.byKey(ValueKey(category.id)));
        await tester.scrollUntilVisible(
          find.descendant(of: shelf, matching: find.text(category.title)),
          200,
          scrollable: _inMedia(find.byType(Scrollable)).first,
        );
        await tester.pump();
        expect(loaded, contains(category.id));
        expect(
          tester
              .widget<MediaGridTile>(
                find
                    .descendant(of: shelf, matching: find.byType(MediaGridTile))
                    .first,
              )
              .item
              .id,
          '${category.id}-0',
        );
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('${kind.name} complete catalog keeps empty category state', (
      tester,
    ) async {
      final category = categories.first;
      var loads = 0;
      await _pumpMedia(
        tester,
        kind: kind,
        categories: [category],
        snapshot: MediaLibrarySnapshot(
          kind: kind,
          categories: [category],
          items: _items(kind: kind),
          fromCache: true,
          syncedAt: null,
        ),
        loadCategory: (_) async {
          loads++;
          return const [];
        },
      );
      final empty = find.text(
        kind == ContentKind.movie
            ? 'No movies in this category'
            : 'No series in this category',
      );
      await tester.scrollUntilVisible(
        empty,
        200,
        scrollable: _inMedia(find.byType(Scrollable)).first,
      );
      expect(loads, 0);
      expect(empty, findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('${kind.name} home has banner, posters and categories', (
      tester,
    ) async {
      final loaded = <String>[];
      final view = await _pumpMedia(
        tester,
        kind: kind,
        size: const Size(960, 540),
        withChrome: true,
        categories: categories,
        loadCategory: (category) async {
          loaded.add(category.id);
          return _categoryItems(category);
        },
      );

      expect(find.text('FROM YOUR LIBRARY'), findsOneWidget);
      expect(view.first.hasFocus, isTrue);
      expect(view.scroll.offset, lessThanOrEqualTo(10));
      expect(_focusedMedia(), isNull);
      final body = tester.getRect(find.byType(MediaTabView));
      final feature = tester.getRect(
        find.byKey(const ValueKey('media.featured.primary')),
      );
      expect(feature.top, greaterThanOrEqualTo(body.top));
      expect(feature.bottom, lessThanOrEqualTo(body.bottom));
      final browse = tester.getRect(
        _inMedia(
          find.text(
            kind == ContentKind.movie ? 'Browse movies' : 'Browse series',
          ),
        ),
      );
      final firstCard = tester.getRect(
        _inMedia(
          find.byWidgetPredicate(
            (widget) => widget is MediaGridTile && widget.item.id == _movie.id,
          ),
        ),
      );
      expect(browse.top, greaterThan(feature.bottom));
      expect(firstCard.width, inInclusiveRange(105, 140));
      expect(firstCard.height, lessThan(280));
      expect(firstCard.top, greaterThan(browse.bottom));

      final heading = _inMedia(find.text(categories.first.title));
      await tester.scrollUntilVisible(
        heading,
        200,
        scrollable: _inMedia(find.byType(Scrollable)).first,
      );
      await tester.pump();
      final headingRect = tester.getRect(heading);
      expect(loaded, contains(categories.first.id));
      expect(headingRect.top, greaterThanOrEqualTo(body.top));
      expect(headingRect.bottom, lessThanOrEqualTo(body.bottom));
      expect(tester.takeException(), isNull);
    });

    testWidgets('D-pad crosses ${kind.name} shelves with visible headings', (
      tester,
    ) async {
      final opened = <MediaItem>[];
      final view = await _pumpMedia(
        tester,
        kind: kind,
        size: const Size(960, 540),
        withChrome: true,
        categories: categories,
        loadCategory: (category) async => _categoryItems(category),
        onOpen: opened.add,
      );

      expect(view.first.hasFocus, isTrue);
      for (final category in categories.take(2)) {
        for (var step = 0; step < 6; step++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
          await tester.pump();
          await tester.pump();
          if (_focusedMedia()?.id.startsWith('${category.id}-') == true) break;
        }
        final focused = _focusedMedia();
        expect(focused?.id, startsWith('${category.id}-'));
        expect(focused?.kind, kind);
        final body = tester.getRect(find.byType(MediaTabView));
        final heading = tester.getRect(_inMedia(find.text(category.title)));
        final card = tester.getRect(
          _inMedia(
            find.byWidgetPredicate(
              (widget) =>
                  widget is MediaGridTile && widget.item.id == focused!.id,
            ),
          ),
        );
        expect(heading.top, greaterThanOrEqualTo(body.top));
        expect(heading.bottom, lessThanOrEqualTo(card.top));
        expect(card.bottom, lessThanOrEqualTo(body.bottom));

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
        await tester.pump();
        expect(_focusedMedia()?.id, startsWith('${category.id}-'));
        expect(_focusedMedia()?.id, isNot(focused!.id));
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(opened.single.id, _focusedMedia()!.id);
      expect(tester.takeException(), isNull);
    });

    testWidgets('${kind.name} shelf transitions animate without an initial jump', (
      tester,
    ) async {
      final view = await _pumpMedia(
        tester,
        kind: kind,
        size: const Size(960, 540),
        withChrome: true,
        animations: true,
        categories: categories,
        loadCategory: (category) async => _categoryItems(category),
      );
      final browsePoster = _inMedia(
        find.byWidgetPredicate(
          (widget) => widget is MediaGridTile && widget.item.id == 'item1',
        ),
      );
      tester
          .widget<FocusableActionDetector>(
            find.descendant(
              of: browsePoster,
              matching: find.byType(FocusableActionDetector),
            ),
          )
          .focusNode!
          .requestFocus();
      await tester.pumpAndSettle();
      final before = view.scroll.offset;

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(_focusedMedia()?.id, startsWith('${categories.first.id}-'));
      expect(view.scroll.offset, closeTo(before, 0.01));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 70));
      final intermediate = view.scroll.offset;
      expect(intermediate, greaterThan(before));
      await tester.pumpAndSettle();
      expect(view.scroll.offset, greaterThan(intermediate));

      final focused = _focusedMedia()!;
      final body = tester.getRect(find.byType(MediaTabView));
      final heading = tester.getRect(_inMedia(find.text(categories.first.title)));
      final card = tester.getRect(
        _inMedia(
          find.byWidgetPredicate(
            (widget) => widget is MediaGridTile && widget.item.id == focused.id,
          ),
        ),
      );
      expect(heading.top, greaterThanOrEqualTo(body.top - 0.01));
      expect(heading.bottom, lessThanOrEqualTo(card.top));
      expect(card.bottom, lessThanOrEqualTo(body.bottom + 0.01));

      final settled = view.scroll.offset;
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(_focusedMedia()?.id, startsWith('${categories.first.id}-'));
      expect(_focusedMedia()?.id, isNot(focused.id));
      expect(view.scroll.offset, closeTo(settled, 0.01));

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(_focusedMedia()?.id, startsWith('${categories[1].id}-'));
      await tester.pump(const Duration(milliseconds: 40));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(_focusedMedia()?.id, startsWith('${categories.first.id}-'));
      final returnedCard = tester.getRect(
        _inMedia(
          find.byWidgetPredicate(
            (widget) =>
                widget is MediaGridTile && widget.item.id == _focusedMedia()!.id,
          ),
        ),
      );
      expect(returnedCard.top, greaterThanOrEqualTo(body.top - 0.01));
      expect(returnedCard.bottom, lessThanOrEqualTo(body.bottom + 0.01));
      expect(tester.takeException(), isNull);
    });

    testWidgets('${kind.name} shelf loads its category and Show all selects it', (
      tester,
    ) async {
      final loaded = <String>[];
      final expanded = <MediaCategory>[];
      await _pumpMedia(
        tester,
        kind: kind,
        size: const Size(960, 540),
        withChrome: true,
        categories: categories,
        loadCategory: (category) async {
          loaded.add(category.id);
          return _categoryItems(category);
        },
        onExpandCategory: expanded.add,
      );

      final showAll = find.descendant(
        of: _inMedia(find.byKey(ValueKey(categories.first.id))),
        matching: find.text('Show all'),
      );
      await tester.scrollUntilVisible(
        showAll,
        200,
        scrollable: _inMedia(find.byType(Scrollable)).first,
      );
      await tester.pump();
      expect(loaded.where((id) => id == 'action'), hasLength(1));
      await tester.tap(showAll);
      expect(expanded.single.id, 'action');
      expect(expanded.single.kind, kind);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('large-text D-pad shelf transitions reveal the selected poster', (
    tester,
  ) async {
    await _pumpMedia(
      tester,
      size: const Size(960, 540),
      textScale: 2,
      withChrome: true,
      categories: _categories,
      loadCategory: (category) async => _categoryItems(category),
    );

    for (var step = 0; step < 3; step++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      await tester.pump();
    }
    for (final category in _categories.take(2)) {
      for (var step = 0; step < 6; step++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        await tester.pump();
        if (_focusedMedia()?.id.startsWith('${category.id}-') == true) break;
      }
      expect(_focusedMedia()?.id, startsWith('${category.id}-'));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      await tester.pump();
      final focused = _focusedMedia();
      expect(focused?.id, startsWith('${category.id}-'));
      expect(focused?.id, isNot('${category.id}-0'));
      final card = tester.getRect(
        _inMedia(
          find.byWidgetPredicate(
            (widget) =>
                widget is MediaGridTile && widget.item.id == focused!.id,
          ),
        ),
      );
      final body = tester.getRect(find.byType(MediaTabView));
      expect(card.top, greaterThanOrEqualTo(body.top));
      expect(card.bottom, lessThanOrEqualTo(body.bottom + 0.01));
      expect(card.left, greaterThanOrEqualTo(body.left));
      expect(card.right, lessThanOrEqualTo(body.right));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('movie home restores a played title beyond the initial shelf', (
    tester,
  ) async {
    final opened = <MediaItem>[];
    final view = await _pumpMedia(
      tester,
      size: const Size(960, 540),
      withChrome: true,
      categories: _categories,
      loadCategory: (category) async => _categoryItems(category),
      lastPlayed: 'item20',
      onOpen: opened.add,
    );

    expect(view.first.hasFocus, isTrue);
    expect(_focusedMedia()?.id, 'item20');
    final card = tester.getRect(
      _inMedia(
        find.byWidgetPredicate(
          (widget) => widget is MediaGridTile && widget.item.id == 'item20',
        ),
      ),
    );
    final body = tester.getRect(find.byType(MediaTabView));
    expect(card.left, greaterThanOrEqualTo(body.left));
    expect(card.right, lessThanOrEqualTo(body.right));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(opened.single.id, 'item20');
    expect(tester.takeException(), isNull);
  });

  for (final kind in [ContentKind.movie, ContentKind.series]) {
    for (final layout in [
      (size: const Size(960, 540), shelves: true),
      (size: const Size(1280, 720), shelves: false),
      (size: const Size(390, 844), shelves: false),
      (size: const Size(667, 375), shelves: false),
    ]) {
      testWidgets(
        '${kind.name} has matching resume posters below the banner at ${layout.size}',
        (tester) async {
          final played = <MediaItem>[];
          final view = await _pumpMedia(
            tester,
            kind: kind,
            size: layout.size,
            withChrome: layout.shelves,
            withContinueWatching: true,
            categories: layout.shelves ? _categoriesFor(kind) : const [],
            loadCategory: (category) async => _categoryItems(category),
            onPlay: played.add,
          );

          final heading = tester.getRect(find.text('Continue watching'));
          expect(
            heading.top,
            greaterThan(tester.getBottomLeft(find.text('FROM YOUR LIBRARY')).dy),
          );
          final resumeTile = find.byWidgetPredicate(
            (widget) => widget is MediaGridTile && widget.resumeEntry != null,
          );
          final resumeSize = tester.getSize(resumeTile);
          expect(resumeSize.height, greaterThan(resumeSize.width));
          expect(find.text('Remove'), findsNothing);
          expect(
            tester.widget<LinearProgressIndicator>(find.descendant(
              of: resumeTile,
              matching: find.byType(LinearProgressIndicator),
            )).value,
            0.1,
          );
          expect(view.first.hasFocus, isTrue);
          expect(
            find.byKey(const ValueKey('media.featured.primary')).hitTestable(),
            findsOneWidget,
          );
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
          await tester.pump();
          await tester.pump();
          expect(
            focusRouteKey(FocusManager.instance.primaryFocus),
            startsWith('media.continue.'),
          );
          final browseHeading = find.text(
            kind == ContentKind.movie ? 'Browse movies' : 'Browse series',
            skipOffstage: false,
          );
          expect(
            tester.getBottomLeft(find.text('Continue watching')).dy,
            lessThan(tester.getTopLeft(browseHeading).dy),
          );
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          expect(
            played.single.id,
            kind == ContentKind.movie ? _movie.id : 'episode',
          );
          expect(
            played.single.kind,
            kind == ContentKind.movie ? ContentKind.movie : ContentKind.episode,
          );
          if (layout.shelves) {
            await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
            await tester.pump();
            await tester.pump();
            expect(
              focusRouteKey(FocusManager.instance.primaryFocus),
              startsWith('media.item.'),
            );
            final catalogTile = find.byWidgetPredicate(
              (widget) => widget is MediaGridTile && widget.resumeEntry == null,
            ).first;
            expect(resumeSize, tester.getSize(catalogTile));
          }
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('movie category sidebar selects and clears filters', (tester) async {
    String? selected;
    final changes = <String?>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => MediaCategoryBar(
              categories: _categories,
              value: selected,
              onChanged: (value) => setState(() {
                selected = value;
                changes.add(value);
              }),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Comedy'));
    await tester.pump();
    expect(selected, 'comedy');
    await tester.tap(find.text('All categories'));
    await tester.pump();
    expect(changes, ['comedy', null]);
    expect(tester.takeException(), isNull);
  });

  for (final kind in [ContentKind.movie, ContentKind.series]) {
    testWidgets('${kind.name} categories scroll with the mouse wheel', (
      tester,
    ) async {
      final changes = <String?>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 240,
                height: 240,
                child: MediaCategoryBar(
                  categories: [
                    for (var i = 0; i < 20; i++)
                      MediaCategory(
                        id: 'category$i',
                        title: 'Category $i',
                        kind: kind,
                      ),
                  ],
                  value: null,
                  onChanged: changes.add,
                ),
              ),
            ),
          ),
        ),
      );

      final scrollable = find.descendant(
        of: find.byType(MediaCategoryBar),
        matching: find.byType(Scrollable),
      );
      final position = tester.state<ScrollableState>(scrollable).position;
      expect(position.maxScrollExtent, greaterThan(100));
      final overCategories = tester.getCenter(scrollable);
      var mousePosition = overCategories;
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: mousePosition);
      addTearDown(mouse.removePointer);

      Future<void> wheel(Offset delta) async {
        await tester.sendEventToBinding(
          PointerScrollEvent(
            kind: PointerDeviceKind.mouse,
            position: mousePosition,
            scrollDelta: delta,
          ),
        );
        await tester.pump();
      }

      await wheel(const Offset(0, 80));
      expect(position.pixels, 80);
      await wheel(const Offset(0, -30));
      expect(position.pixels, 50);

      mousePosition = overCategories + const Offset(300, 0);
      await mouse.moveTo(mousePosition);
      await wheel(const Offset(0, 40));
      expect(position.pixels, 50);

      mousePosition = overCategories;
      await mouse.moveTo(mousePosition);
      await wheel(const Offset(0, 50));
      expect(position.pixels, 100);

      await wheel(const Offset(0, 100000));
      expect(position.pixels, position.maxScrollExtent);
      await wheel(const Offset(0, 100000));
      expect(position.pixels, position.maxScrollExtent);
      await wheel(const Offset(0, -100000));
      expect(position.pixels, position.minScrollExtent);
      await wheel(const Offset(0, -100000));
      expect(position.pixels, position.minScrollExtent);
      expect(changes, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('series category shelf shows loading, retry and empty states', (
    tester,
  ) async {
    final pending = Completer<List<MediaItem>>();
    final category = _categoriesFor(ContentKind.series).first;
    var loads = 0;
    await _pumpMedia(
      tester,
      kind: ContentKind.series,
      categories: [category],
      loadCategory: (_) {
        loads++;
        return loads == 1 ? pending.future : Future.value([]);
      },
    );

    await tester.scrollUntilVisible(
      _inMedia(find.text(category.title)),
      200,
      scrollable: _inMedia(find.byType(Scrollable)).first,
    );
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    pending.completeError(StateError('Unavailable'));
    await tester.pump();
    await tester.pump();
    final retry = find.text('Could not load series. Retry');
    expect(retry, findsOneWidget);
    expect(find.text('Could not load movies. Retry'), findsNothing);
    await tester.ensureVisible(retry);
    await tester.tap(retry);
    await tester.pump();
    await tester.pump();
    expect(loads, 2);
    expect(find.text('No series in this category'), findsOneWidget);
    expect(find.text('No movies in this category'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('movie categories scroll with long labels and enlarged text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    const longCategory = MediaCategory(
      id: 'long',
      title: 'International science fiction and fantasy adventures',
      kind: ContentKind.movie,
    );
    final selected = <String?>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: MediaCategoryBar(
              categories: const [longCategory, ..._categories],
              value: null,
              onChanged: selected.add,
            ),
          ),
        ),
      ),
    );

    final label = find.text(longCategory.title);
    await tester.ensureVisible(label);
    await tester.pumpAndSettle();
    final visibleLabel = tester
        .getRect(label)
        .intersect(tester.getRect(find.byType(MediaCategoryBar)));
    expect(visibleLabel.width, greaterThan(40));
    await tester.tapAt(visibleLabel.center);
    expect(selected, ['long']);
    final comedy = find.text('Comedy');
    await tester.ensureVisible(comedy);
    await tester.pumpAndSettle();
    await tester.tap(comedy);
    expect(selected, ['long', 'comedy']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('movie discovery retains its feature and offers real actions', (
    tester,
  ) async {
    final opened = <MediaItem>[];
    final played = <MediaItem>[];
    final view = await _pumpMedia(
      tester,
      onOpen: opened.add,
      onPlay: played.add,
    );

    expect(find.text('FROM YOUR LIBRARY'), findsOneWidget);
    expect(find.text('2 hr 2 min'), findsOneWidget);
    expect(find.text(_movie.description!), findsOneWidget);
    expect(view.first.hasFocus, isTrue);
    expect(view.scroll.offset, 0);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(played.single.id, _movie.id);
    await tester.tap(find.text('More info'));
    expect(opened.single.id, _movie.id);
    expect(tester.takeException(), isNull);
  });

  for (final filter in ['search', 'category']) {
    testWidgets('$filter focuses its results without the discovery feature', (
      tester,
    ) async {
      final opened = <MediaItem>[];
      final view = await _pumpMedia(
        tester,
        searching: filter == 'search',
        category: filter == 'category',
        withContinueWatching: true,
        categories: _categories,
        loadCategory: (category) async => _categoryItems(category),
        onOpen: opened.add,
      );

      expect(find.text('FROM YOUR LIBRARY'), findsNothing);
      expect(find.text('Continue watching'), findsNothing);
      expect(_inMedia(find.text(_categories.first.title)), findsNothing);
      expect(view.first.hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(opened.single.id, _movie.id);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('returning from playback restores the last catalogue item', (
    tester,
  ) async {
    final opened = <MediaItem>[];
    final view = await _pumpMedia(
      tester,
      lastPlayed: 'item3',
      onOpen: opened.add,
    );

    expect(view.first.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(opened.single.id, 'item3');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'series feature opens episodes instead of trying to play a series',
    (tester) async {
      final opened = <MediaItem>[];
      final played = <MediaItem>[];
      await _pumpMedia(
        tester,
        kind: ContentKind.series,
        categories: _categoriesFor(ContentKind.series),
        loadCategory: (category) async => _categoryItems(category),
        onOpen: opened.add,
        onPlay: played.add,
      );

      expect(find.text('View episodes'), findsOneWidget);
      expect(find.text('Play'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(opened.single.kind, ContentKind.series);
      expect(played, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('D-pad can reach resume posters below the banner and catalogue', (
    tester,
  ) async {
    final opened = <MediaItem>[];
    final played = <MediaItem>[];
    final view = await _pumpMedia(
      tester,
      size: const Size(960, 540),
      withContinueWatching: true,
      onOpen: opened.add,
      onPlay: played.add,
    );

    expect(view.first.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.pump();
    expect(
      focusRouteKey(FocusManager.instance.primaryFocus),
      'media.continue.featured',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(played.single.id, _movie.id);
    expect(find.text('1 hr 48 min left'), findsOneWidget);

    for (var step = 0; step < 6; step++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.pump();
      if (focusRouteKey(FocusManager.instance.primaryFocus)
          .startsWith('media.item.')) {
        break;
      }
    }
    expect(
      focusRouteKey(FocusManager.instance.primaryFocus),
      startsWith('media.item.'),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(opened, hasLength(1));

    view.first.requestFocus();
    await tester.pump();
    await tester.pump();
    expect(view.first.hasFocus, isTrue);
    expect(view.scroll.offset, 0);
    expect(
      find.byKey(const ValueKey('media.featured.primary')).hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  for (final size in const [
    Size(390, 844),
    Size(667, 375),
    Size(960, 540),
    Size(1920, 1080),
  ]) {
    for (final scale in const [1.3, 2.0]) {
      testWidgets('discovery reflows at $size with text scale $scale', (
        tester,
      ) async {
        await _pumpMedia(
          tester,
          size: size,
          textScale: scale,
          withContinueWatching: true,
        );
        expect(find.text('Play'), findsOneWidget);
        expect(find.text('More info'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
