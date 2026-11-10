import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show RenderAbstractViewport, ScrollCacheExtent, ScrollDirection;
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/library_repository.dart';
import '../data/load_token.dart';
import '../data/media_info.dart';
import '../data/media_trailer.dart';
import '../data/series_watch_progress.dart';
import '../data/source_hint_parser.dart';
import '../player/episode_navigation.dart' show orderPlaybackEpisodes;
import '../sources/source.dart';
import '../l10n/app_localizations.dart';
import '../theme.dart';
import '../widgets/favorite_controls.dart';
import '../widgets/focusable_card.dart';
import '../widgets/image_utils.dart';
import '../widgets/routed_focus_node.dart';
import '../widgets/source_error_view.dart';
import '../data/app_database.dart' show PlaybackPosition;
import 'media_tab_controller.dart' show ContinueWatchingEntry;

/// `1:23:45` / `12:34` style label for a resume position.
String _positionLabel(Duration position) {
  final hours = position.inHours;
  final minutes = position.inMinutes % 60;
  final seconds = position.inSeconds % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return hours > 0
      ? '$hours:${two(minutes)}:${two(seconds)}'
      : '$minutes:${two(seconds)}';
}

/// Grid density for poster catalogues.
///
/// Short viewports need smaller posters so a TV can show more than one shelf.
/// The same height-aware ladder is used by the catalogue and category rails.
@immutable
class MediaGridMetrics {
  /// [MediaGridTile]'s own inner padding, each side.
  static const double tilePadding = 6;

  /// Border width [FocusableCard] reserves on each side.
  ///
  /// Taken from the widget itself rather than restated, because the number has
  /// to match exactly: it used to be 1 here while a focused card drew 2, on the
  /// reasoning that "the `Expanded` poster absorbs it" — true while the poster
  /// was flexible, false the moment it became a fixed [posterAspectRatio], and
  /// the focused tile overflowed by ~1.6 px. The card now reserves
  /// [kFocusableCardBorderWidth] in *every* state (the ring moved to a
  /// `foregroundDecoration`, so focus no longer resizes the poster and no
  /// longer re-decodes it), which is what makes one shared constant correct.
  static const double tileBorder = kFocusableCardBorderWidth;

  /// Gap between a tile's poster and its text block.
  static const double posterTextGap = 6;

  /// Posters are 2:3 — the shape TMDB and every provider panel ships, so a
  /// tile at this ratio crops nothing.
  static const double posterAspectRatio = 2 / 3;

  final int columns;
  final double spacing;
  final EdgeInsets padding;

  const MediaGridMetrics._({
    required this.columns,
    required this.spacing,
    required this.padding,
  });

  /// [viewport] is the **window** ([MediaQuery.sizeOf]), never a
  /// `LayoutBuilder`'s post-`SafeArea` constraints — see theme.dart's
  /// breakpoint note and docs/tv-navigation.md. [availableWidth] accounts for
  /// the category sidebar when choosing how many posters fit in the body.
  factory MediaGridMetrics.forSize(Size viewport, {double? availableWidth}) {
    final targetWidth = math.min(
      kMediaPosterTargetWidth,
      (viewport.height * 0.22).clamp(104.0, kMediaPosterTargetWidth),
    );
    final columns = ((availableWidth ?? viewport.width) / targetWidth)
        .round()
        .clamp(2, 20);
    // A dense viewport (TV render targets at 960x540, phones, small windows)
    // gets tighter gutters so the extra pixels go to the artwork. This is the
    // only thing left of the old `compact` platform fork.
    final dense = viewport.shortestSide < 1000;
    return MediaGridMetrics._(
      columns: columns,
      spacing: dense ? 6 : 8,
      padding: dense
          ? const EdgeInsets.fromLTRB(10, 4, 10, 12)
          : const EdgeInsets.fromLTRB(16, 6, 16, 20),
    );
  }

  double get crossAxisSpacing => spacing;

  /// [FocusableCard] pads itself vertically, so a naive
  /// `mainAxisSpacing == spacing` produced a `spacing + 8` vertical gutter
  /// against a `spacing` horizontal one — visibly lopsided. Subtract it back
  /// out so both gutters measure [spacing].
  double get mainAxisSpacing =>
      math.max(0.0, spacing - kFocusableCardVerticalPadding * 2);

  /// Width of one tile when the grid is laid out in [availableWidth] — the
  /// same arithmetic `SliverGridDelegateWithFixedCrossAxisCount` does, needed
  /// here because [childAspectRatio] depends on the absolute tile width.
  double tileWidth(double availableWidth) =>
      (availableWidth - padding.horizontal - crossAxisSpacing * (columns - 1)) /
      columns;

  /// Cell aspect that leaves the poster exactly [posterAspectRatio] once
  /// [textBudget] logical pixels are reserved for the title/year/hint block.
  ///
  /// The tile used to be `Expanded(poster)` over a text block that varied by
  /// up to ~58 px (1 vs 2 title lines, optional year, optional source hints),
  /// so `Expanded` handed every poster a different remainder and the box
  /// aspect ranged 0.70–0.92. With `memCacheWidth`-only decoding restoring real
  /// `BoxFit.cover` cropping, that showed up as neighbouring tiles cropping the
  /// *same* poster differently. Reserving the budget (rather than letting it
  /// float) also keeps a large accessibility text scale from eating the poster:
  /// the tile grows taller instead.
  double childAspectRatio({
    required double tileWidth,
    required double textBudget,
  }) {
    final posterWidth = tileWidth - (tilePadding + tileBorder) * 2;
    if (posterWidth <= 0) return 0.64;
    final tileHeight =
        posterWidth / posterAspectRatio +
        posterTextGap +
        textBudget +
        (tilePadding + tileBorder) * 2 +
        kFocusableCardVerticalPadding * 2;
    return (tileWidth / tileHeight).clamp(0.2, 2.0);
  }
}

/// Vertical space a grid tile reserves under its poster: two title lines, a
/// year line, and one row of source-hint chips, at the current text scale.
///
/// Deliberately reserves the *maximum* a tile can render rather than measuring
/// each item: the reservation has to be identical for every cell (the grid has
/// one `childAspectRatio`), and probing `sourceHintLabels` across the visible
/// list to find out whether any tile needs the chip row would re-run its regex
/// pass on every build. Text scaling is intentionally not overridden anywhere
/// in this app, so the budget is derived from `MediaQuery.textScalerOf`.
double mediaTileTextBudget(BuildContext context, {bool compact = false}) {
  final scaler = MediaQuery.textScalerOf(context);
  final titleStyle = Theme.of(context).textTheme.titleSmall;
  // 1.35 stands in for an unset `TextStyle.height` (the font's own metrics);
  // erring high only leaves slack at the bottom of the fixed text box, while
  // erring low would clip.
  final titleLine =
      scaler.scale(titleStyle?.fontSize ?? 14) * (titleStyle?.height ?? 1.35);
  if (compact) return titleLine * 2;
  final yearLine = scaler.scale(12) * 1.35;
  final hintRow =
      scaler.scale(10) * 1.35 +
      4 + // chip vertical padding
      2 + // chip border
      5; // gap above the chip row
  return titleLine * 2 + yearLine + hintRow;
}

KeyEventResult _focusTabsOnLeft(KeyEvent event, VoidCallback? onFocusTabs) {
  if (onFocusTabs == null ||
      event.logicalKey != LogicalKeyboardKey.arrowLeft ||
      event is KeyUpEvent) {
    return KeyEventResult.ignored;
  }
  if (event is KeyDownEvent) onFocusTabs();
  return KeyEventResult.handled;
}

// Isolate directional traversal without letting a newly loaded catalogue steal
// focus from the categories, toolbar or a dialog in the enclosing route.
class _MediaFocusScopeNode extends FocusScopeNode {
  @override
  void autofocus(FocusNode node) {
    if (hasFocus || enclosingScope?.focusedChild == null) super.autofocus(node);
  }
}

class _MediaFocusScope extends StatefulWidget {
  final Widget child;
  final FocusOnKeyEventCallback onKeyEvent;

  const _MediaFocusScope({required this.child, required this.onKeyEvent});

  @override
  State<_MediaFocusScope> createState() => _MediaFocusScopeState();
}

class _MediaFocusScopeState extends State<_MediaFocusScope> {
  final _node = _MediaFocusScopeNode();
  final _policy = ReadingOrderTraversalPolicy(
    requestFocusCallback: _requestFocus,
  );

  static void _requestFocus(
    FocusNode node, {
    ScrollPositionAlignmentPolicy? alignmentPolicy,
    double? alignment,
    Duration? duration,
    Curve? curve,
  }) {
    // Shelves reveal their heading and posters together. The default callback
    // would first jump both scroll axes to the poster, before that reveal runs.
    final rail = node.context?.findAncestorStateOfType<_MediaPosterRailState>();
    if (rail != null) {
      node.requestFocus();
      rail._reveal(node.context!, true, focusNode: node);
      return;
    }
    FocusTraversalPolicy.defaultTraversalRequestFocusCallback(
      node,
      alignmentPolicy: alignmentPolicy,
      alignment: alignment,
      duration: duration,
      curve: curve,
    );
  }

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FocusScope(
    node: _node,
    skipTraversal: true,
    onKeyEvent: widget.onKeyEvent,
    child: FocusTraversalGroup(policy: _policy, child: widget.child),
  );
}

/// The movies/series browsing body: the grid/list of [MediaItem]s with paging,
/// error/empty states, and D-pad focus. Extracted from `ChannelListScreen`'s
/// State as a widget with an explicit input contract so it rebuilds
/// independently of the rest of the (large) screen and so the media state can
/// later move behind a controller without touching this view. Live TV keeps its
/// own body; this handles [ContentKind.movie]/[ContentKind.series] only.
class MediaTabView extends StatelessWidget {
  // The screen replaces its filtered list after catalog, metadata or permission
  // changes. Weak keys reuse the projection on ordinary rebuilds without
  // retaining catalogs after their source/tab is disposed.
  static final _categoryPreviewCache =
      Expando<Map<String, List<MediaItem>>>('media.categoryPreviews');
  static const _categoryPreviewLimit = 14;

  final ContentKind kind;

  /// Filtered items to show (favorites/hidden/search already applied by the
  /// parent), and the underlying snapshot (drives "load more" / paging).
  final List<MediaItem> visible;
  final MediaLibrarySnapshot? snapshot;

  final bool loading;
  final bool loadingMore;
  final String? error;

  /// True when a live search query (>= 2 chars) is active — hides "load more"
  /// since search returns a flat, non-paged result set.
  final bool showingSearch;

  /// True when a category filter is active. Combined with [showingSearch] to
  /// pick the empty-state wording below: a genuinely unfiltered-empty source
  /// ("this provider returned nothing") reads very differently from a
  /// filtered-empty one ("nothing matches"). Defaults to false — category
  /// filtering lives in `ChannelListScreen`, which this view does not own;
  /// wire this through from the caller alongside the category selector.
  final bool categoryFilterActive;
  final List<MediaCategory> categories;
  final Future<List<MediaItem>> Function(MediaCategory)? loadCategory;
  final ValueChanged<MediaCategory>? onExpandCategory;

  /// Id of the last-played item in this kind, autofocused on return when still
  /// visible (else the first item is).
  final String? lastPlayedId;

  final ScrollController scrollController;
  final FocusNode? firstFocusNode;

  /// Moves to the content-kind tabs from the left edge of a browsing row.
  final VoidCallback? onFocusTabs;

  /// Up at the top of the catalogue returns to the section toolbar.
  final VoidCallback? onFocusToolbar;

  final bool Function(String id) isFavorite;
  final ValueChanged<MediaItem> onOpenMedia;
  final VoidCallback onLoadMore;
  final VoidCallback onRetry;

  /// In-progress items (saved playback positions) shown as a horizontal
  /// "Continue watching" rail above the grid; [onResume] plays one, resuming.
  final List<ContinueWatchingEntry> continueWatching;
  final ValueChanged<MediaItem> onResume;

  const MediaTabView({
    super.key,
    required this.kind,
    required this.visible,
    required this.snapshot,
    required this.loading,
    required this.loadingMore,
    required this.error,
    required this.showingSearch,
    this.categoryFilterActive = false,
    this.categories = const [],
    this.loadCategory,
    this.onExpandCategory,
    required this.lastPlayedId,
    required this.scrollController,
    required this.firstFocusNode,
    this.onFocusTabs,
    this.onFocusToolbar,
    required this.isFavorite,
    required this.onOpenMedia,
    required this.onLoadMore,
    required this.onRetry,
    this.continueWatching = const [],
    required this.onResume,
  });

  Map<String, List<MediaItem>>? _completeCategoryPreviews() {
    final catalog = snapshot;
    if (catalog == null ||
        catalog.kind != kind ||
        catalog.categoryId != null ||
        catalog.parentId != null ||
        catalog.hasMore) {
      return null;
    }
    final cached = _categoryPreviewCache[visible];
    if (cached != null) return cached;
    final previews = <String, List<MediaItem>>{};
    for (final item in visible) {
      final categoryId = item.categoryId;
      if (categoryId == null) continue;
      final items = previews.putIfAbsent(categoryId, () => <MediaItem>[]);
      if (items.length < _categoryPreviewLimit) items.add(item);
    }
    _categoryPreviewCache[visible] = previews;
    return previews;
  }

  @override
  Widget build(BuildContext context) => _MediaFocusScope(
    onKeyEvent: (_, event) {
      final direction = switch (event.logicalKey) {
        LogicalKeyboardKey.arrowUp => TraversalDirection.up,
        LogicalKeyboardKey.arrowDown => TraversalDirection.down,
        LogicalKeyboardKey.arrowLeft => TraversalDirection.left,
        LogicalKeyboardKey.arrowRight => TraversalDirection.right,
        _ => null,
      };
      if (direction == null) return KeyEventResult.ignored;
      if (event is KeyUpEvent) return KeyEventResult.handled;
      final moved =
          FocusManager.instance.primaryFocus?.focusInDirection(direction) ??
          false;
      if (!moved && event is KeyDownEvent) {
        if (direction == TraversalDirection.up) {
          (onFocusToolbar ?? onFocusTabs)?.call();
        } else if (direction == TraversalDirection.left) {
          onFocusTabs?.call();
        }
      }
      return KeyEventResult.handled;
    },
    child: _buildContent(context),
  );

  Widget _buildContent(BuildContext context) {
    // The rail rides in the *same* scroll view as the grid/list below (as a
    // leading sliver) rather than sitting above it in a fixed-height Column.
    // A fixed height there could exceed the whole available viewport on a
    // short screen (phone landscape, mainly) — Column+Expanded overflows in
    // that case, which broke the rail's own horizontal drag along with it.
    // As a sliver it just contributes to the (already scrollable) content
    // and never forces an overflow.
    final showRail =
        !showingSearch && !categoryFilterActive && continueWatching.isNotEmpty;
    final focusContinue =
        showRail &&
        !categoryFilterActive &&
        (loading || error != null || visible.isEmpty);
    final railSliver = showRail
        ? SliverToBoxAdapter(
            child: _MediaPosterRail(
              title: tr('Continue watching'),
              items: [for (final entry in continueWatching) entry.item],
              resumeEntries: {
                for (final entry in continueWatching) entry.item.id: entry,
              },
              isFavorite: isFavorite,
              onOpen: onResume,
              onFocusTabs: onFocusTabs,
              firstFocusNode: focusContinue ? firstFocusNode : null,
              focusedId: focusContinue ? continueWatching.first.item.id : null,
            ),
          )
        : null;

    if (loading || error != null || visible.isEmpty) {
      final status = _statusBody(context);
      if (railSliver == null) return status;
      return CustomScrollView(
        slivers: [
          railSliver,
          SliverFillRemaining(hasScrollBody: false, child: status),
        ],
      );
    }

    final showLoadMore =
        !showingSearch && (loadingMore || snapshot?.hasMore == true);
    // Two-dimensional, and measured against the **window** rather than this
    // body's own (SafeArea-shrunk) constraints — see theme.dart's breakpoint
    // note. Height matters as much as width: with a width-only rule an iPad in
    // portrait got the grid and in landscape the list, flipping layout on every
    // rotation; a 900x400 landscape phone has room for list rows but not for a
    // poster grid.
    final windowSize = MediaQuery.sizeOf(context);
    final useGrid =
        windowSize.width >= kMediaGridMinWidth &&
        windowSize.height >= kMediaGridMinHeight;
    final textBudget = mediaTileTextBudget(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final discovery = !showingSearch && !categoryFilterActive;
        final showCategories =
            discovery && categories.isNotEmpty && loadCategory != null;
        final categoryPreviews = showCategories
            ? _completeCategoryPreviews()
            : null;
        final showFeatured = discovery;
        final categorySliver = showCategories
            ? SliverList.builder(
                itemCount: categories.length,
                itemBuilder: (context, i) => _MediaCategoryRail(
                  key: ValueKey(categories[i].id),
                  category: categories[i],
                  load: loadCategory!,
                  previewItems: categoryPreviews == null
                      ? null
                      : categoryPreviews[categories[i].id] ?? const [],
                  isFavorite: isFavorite,
                  onOpen: onOpenMedia,
                  onExpand: () => onExpandCategory?.call(categories[i]),
                  onFocusTabs: onFocusTabs,
                ),
              )
            : null;
        final browseCount = visible.length;
        final browseLoadMore = showLoadMore && !showCategories;
        final hasLastVisible =
            lastPlayedId != null &&
            visible.any((media) => media.id == lastPlayedId);
        // Keep the banner visible on entry; returning from playback restores
        // the last-played catalogue item when it is still present.
        final focusFeatured = showFeatured && !hasLastVisible;
        FocusNode? focusNodeFor(int i) => focusFeatured
            ? null
            : hasLastVisible
            ? (visible[i].id == lastPlayedId ? firstFocusNode : null)
            : (i == 0 ? firstFocusNode : null);
        bool autofocusFor(int i) =>
            !focusFeatured &&
            (hasLastVisible ? visible[i].id == lastPlayedId : i == 0);
        final featuredSliver = showFeatured
            ? SliverToBoxAdapter(
                child: _FeaturedMedia(
                  item: visible.first,
                  focusNode: focusFeatured ? firstFocusNode : null,
                  autofocus: focusFeatured,
                  onFocusTabs: onFocusTabs,
                  onOpen: () => onOpenMedia(visible.first),
                  onPlay: kind == ContentKind.movie
                      ? () => onResume(visible.first)
                      : null,
                ),
              )
            : null;
        if (showCategories) {
          return CustomScrollView(
            controller: scrollController,
            scrollCacheExtent: const ScrollCacheExtent.pixels(400),
            slivers: [
              ?featuredSliver,
              ?railSliver,
              SliverToBoxAdapter(
                child: _MediaPosterRail(
                  title: kind == ContentKind.movie
                      ? tr('Browse movies')
                      : tr('Browse series'),
                  items: visible,
                  isFavorite: isFavorite,
                  onOpen: onOpenMedia,
                  onFocusTabs: onFocusTabs,
                  firstFocusNode: focusFeatured ? null : firstFocusNode,
                  focusedId: hasLastVisible ? lastPlayedId : null,
                  loadMore: showLoadMore
                      ? _MediaLoadMoreCard(
                          snapshot: snapshot,
                          loading: loadingMore,
                          onPressed: onLoadMore,
                          scrollOnFocus: false,
                        )
                      : null,
                ),
              ),
              categorySliver!,
            ],
          );
        }
        final catalogueHeading = SliverToBoxAdapter(
          child: _MediaSectionHeading(
            title: showingSearch
                ? tr('Search results')
                : categoryFilterActive
                ? tr('In this category')
                : kind == ContentKind.movie
                ? tr('Browse movies')
                : tr('Browse series'),
            detail: visible.length == 1
                ? tr('{count} title', {'count': visible.length})
                : tr('{count} titles', {'count': visible.length}),
          ),
        );
        if (!useGrid) {
          return CustomScrollView(
            controller: scrollController,
            scrollCacheExtent: const ScrollCacheExtent.pixels(800),
            slivers: [
              ?featuredSliver,
              ?railSliver,
              catalogueHeading,
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                sliver: SliverList.builder(
                  itemCount: browseCount + (browseLoadMore ? 1 : 0),
                  itemBuilder: (context, i) {
                    if (i == browseCount) {
                      return _MediaLoadMoreTile(
                        snapshot: snapshot,
                        loading: loadingMore,
                        onPressed: onLoadMore,
                        onFocusTabs: onFocusTabs,
                      );
                    }
                    return MediaListTile(
                      item: visible[i],
                      favorite: isFavorite(visible[i].id),
                      position: i + 1,
                      total: visible.length,
                      autofocus: autofocusFor(i),
                      focusNode: focusNodeFor(i),
                      onTap: () => onOpenMedia(visible[i]),
                      onFocusTabs: onFocusTabs,
                    );
                  },
                ),
              ),
              ?categorySliver,
            ],
          );
        }
        final grid = MediaGridMetrics.forSize(
          windowSize,
          availableWidth: constraints.maxWidth,
        );
        // Deliberately still a fixed-cross-axis-count lattice: Flutter's
        // directional traversal walks a regular grid predictably, and
        // `SliverGridDelegateWithMaxCrossAxisExtent` can't express the
        // per-width `childAspectRatio` the fixed poster/text split needs.
        final tileWidth = grid.tileWidth(constraints.maxWidth);
        return CustomScrollView(
          controller: scrollController,
          scrollCacheExtent: const ScrollCacheExtent.pixels(1000),
          slivers: [
            ?featuredSliver,
            ?railSliver,
            catalogueHeading,
            SliverPadding(
              padding: grid.padding,
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: grid.columns,
                  crossAxisSpacing: grid.crossAxisSpacing,
                  mainAxisSpacing: grid.mainAxisSpacing,
                  childAspectRatio: grid.childAspectRatio(
                    tileWidth: tileWidth,
                    textBudget: textBudget,
                  ),
                ),
                delegate: SliverChildBuilderDelegate((context, i) {
                  if (i == browseCount) {
                    return _MediaLoadMoreCard(
                      snapshot: snapshot,
                      loading: loadingMore,
                      onPressed: onLoadMore,
                      onFocusTabs: i % grid.columns == 0 ? onFocusTabs : null,
                    );
                  }
                  return MediaGridTile(
                    item: visible[i],
                    favorite: isFavorite(visible[i].id),
                    position: i + 1,
                    total: visible.length,
                    autofocus: autofocusFor(i),
                    focusNode: focusNodeFor(i),
                    textBudget: textBudget,
                    onTap: () => onOpenMedia(visible[i]),
                    onFocusTabs: i % grid.columns == 0 ? onFocusTabs : null,
                  );
                }, childCount: browseCount + (browseLoadMore ? 1 : 0)),
              ),
            ),
            ?categorySliver,
          ],
        );
      },
    );
  }

  Widget _statusBody(BuildContext context) {
    if (loading) return const Center(child: CircularProgressIndicator());
    if (error != null) {
      final what = kind == ContentKind.movie ? tr('movies') : tr('series');
      return SourceErrorView(
        message: tr('Couldn\'t load {kind}.\n{error}', {
          'kind': what,
          'error': error!,
        }),
        onRetry: onRetry,
      );
    }
    final label = kind == ContentKind.movie ? tr('movies') : tr('series');
    final filtered = showingSearch || categoryFilterActive;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          filtered
              ? tr('No {kind} match', {'kind': label})
              : tr(
                  'This source has no {kind} — try Reload from the toolbar or check the source.',
                  {'kind': label},
                ),
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppColors.textLo),
        ),
      ),
    );
  }
}

class _MediaCategoryRail extends StatefulWidget {
  final MediaCategory category;
  final Future<List<MediaItem>> Function(MediaCategory) load;
  final List<MediaItem>? previewItems;
  final bool Function(String) isFavorite;
  final ValueChanged<MediaItem> onOpen;
  final VoidCallback onExpand;
  final VoidCallback? onFocusTabs;

  const _MediaCategoryRail({
    super.key,
    required this.category,
    required this.load,
    this.previewItems,
    required this.isFavorite,
    required this.onOpen,
    required this.onExpand,
    this.onFocusTabs,
  });

  @override
  State<_MediaCategoryRail> createState() => _MediaCategoryRailState();
}

class _MediaCategoryRailState extends State<_MediaCategoryRail> {
  Future<List<MediaItem>>? _items;

  @override
  void initState() {
    super.initState();
    if (widget.previewItems == null) _items = widget.load(widget.category);
  }

  @override
  void didUpdateWidget(covariant _MediaCategoryRail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.previewItems != null) {
      _items = null;
    } else if (oldWidget.previewItems != null) {
      _items = widget.load(widget.category);
    }
  }

  Widget _rail(List<MediaItem> items, {Widget? status}) => _MediaPosterRail(
    key: ValueKey(
      '${widget.category.kind.name}.category.${widget.category.id}',
    ),
    title: widget.category.title,
    items: items,
    isFavorite: widget.isFavorite,
    onOpen: widget.onOpen,
    onExpand: widget.onExpand,
    onFocusTabs: widget.onFocusTabs,
    status: status,
  );

  Widget _emptyStatus() => Padding(
    padding: const EdgeInsets.all(18),
    child: Text(
      widget.category.kind == ContentKind.movie
          ? tr('No movies in this category')
          : tr('No series in this category'),
      style: const TextStyle(color: AppColors.textLo),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final previewItems = widget.previewItems;
    if (previewItems != null) {
      return _rail(
        previewItems,
        status: previewItems.isEmpty ? _emptyStatus() : null,
      );
    }
    return FutureBuilder<List<MediaItem>>(
      future: _items,
      builder: (context, snapshot) {
        final items =
            snapshot.data?.take(MediaTabView._categoryPreviewLimit).toList() ??
            const <MediaItem>[];
        Widget? status;
        if (snapshot.hasError) {
          status = Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: TextButton.icon(
              onPressed: () => setState(() {
                _items = widget.load(widget.category);
              }),
              icon: const Icon(Icons.refresh),
              label: Text(
                widget.category.kind == ContentKind.movie
                    ? tr('Could not load movies. Retry')
                    : tr('Could not load series. Retry'),
              ),
            ),
          );
        } else if (!snapshot.hasData) {
          status = const Padding(
            padding: EdgeInsets.all(18),
            child: LinearProgressIndicator(),
          );
        } else if (items.isEmpty) {
          status = _emptyStatus();
        }
        return _rail(items, status: status);
      },
    );
  }
}

/// A complete shelf is the vertical reveal target, keeping its category name
/// above the selected poster. Horizontal scrolling reveals only that poster.
class _MediaPosterRail extends StatefulWidget {
  final String title;
  final List<MediaItem> items;
  final bool Function(String) isFavorite;
  final ValueChanged<MediaItem> onOpen;
  final VoidCallback? onExpand;
  final Widget? status;
  final Widget? loadMore;
  final FocusNode? firstFocusNode;
  final String? focusedId;
  final VoidCallback? onFocusTabs;
  final Map<String, ContinueWatchingEntry> resumeEntries;

  const _MediaPosterRail({
    super.key,
    required this.title,
    required this.items,
    required this.isFavorite,
    required this.onOpen,
    this.onExpand,
    this.status,
    this.loadMore,
    this.firstFocusNode,
    this.focusedId,
    this.onFocusTabs,
    this.resumeEntries = const {},
  });

  @override
  State<_MediaPosterRail> createState() => _MediaPosterRailState();
}

class _MediaPosterRailState extends State<_MediaPosterRail> {
  ScrollController? _scrollController;
  double _itemStride = 0;
  Future<void>? _verticalReveal;
  double? _verticalTarget;

  @override
  void didUpdateWidget(covariant _MediaPosterRail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.focusedId == oldWidget.focusedId || widget.focusedId == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final controller = _scrollController;
      if (!mounted || controller == null || !controller.hasClients) return;
      final index = widget.items.indexWhere((item) => item.id == widget.focusedId);
      if (index < 0) return;
      controller.jumpTo((index * _itemStride).clamp(0, controller.position.maxScrollExtent));
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.firstFocusNode?.requestFocus();
      });
    });
  }

  @override
  void dispose() {
    _scrollController?.dispose();
    super.dispose();
  }

  void _reveal(BuildContext tileContext, bool focused, {FocusNode? focusNode}) {
    if (!focused) return;
    final tile = tileContext.findRenderObject();
    if (tile != null) {
      // Keep horizontal repeats responsive, including newly materialized cards.
      final position = Scrollable.maybeOf(
        tileContext,
        axis: Axis.horizontal,
      )?.position;
      for (final policy in [
        ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
        ScrollPositionAlignmentPolicy.keepVisibleAtStart,
      ]) {
        position?.ensureVisible(tile, alignmentPolicy: policy);
      }
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !tileContext.mounted ||
          !(focusNode?.hasFocus ?? Focus.of(tileContext).hasFocus)) {
        return;
      }
      final tile = tileContext.findRenderObject();
      final shelf = context.findRenderObject();
      if (shelf != null) {
        final position = Scrollable.maybeOf(
          context,
          axis: Axis.vertical,
        )?.position;
        if (position != null) {
          // At large accessibility scales a shelf can exceed the viewport;
          // reveal the card in that case instead of keeping its heading pinned.
          final target = shelf.paintBounds.height > position.viewportDimension
              ? tile ?? shelf
              : shelf;
          final viewport = RenderAbstractViewport.maybeOf(shelf);
          if (viewport == null) return;
          final start = viewport.getOffsetToReveal(target, 0).offset;
          final end = viewport.getOffsetToReveal(target, 1).offset;
          final offset = math
              .min(start, math.max(end, position.pixels))
              .clamp(position.minScrollExtent, position.maxScrollExtent);
          // Moving sideways must not restart a shelf transition in progress.
          if (_verticalReveal != null && _verticalTarget == offset) return;
          final duration = appMotion(context, const Duration(milliseconds: 220));
          if (duration == Duration.zero || offset == position.pixels) {
            position.jumpTo(offset);
          } else {
            final animation = position.animateTo(
              offset,
              duration: duration,
              curve: Curves.easeOutCubic,
            );
            _verticalTarget = offset;
            _verticalReveal = animation;
            animation.whenComplete(() {
              if (identical(_verticalReveal, animation)) _verticalReveal = null;
            });
          }
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final textBudget = mediaTileTextBudget(context, compact: true);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              if (widget.onExpand != null)
                TextButton.icon(
                  onPressed: widget.onExpand,
                  icon: const Icon(Icons.chevron_right),
                  label: Text(tr('Show all')),
                ),
            ],
          ),
        ),
        if (widget.status != null)
          widget.status!
        else
          LayoutBuilder(
            builder: (context, constraints) {
              final grid = MediaGridMetrics.forSize(
                MediaQuery.sizeOf(context),
                availableWidth: constraints.maxWidth,
              );
              final width = grid.tileWidth(constraints.maxWidth);
              final height =
                  width /
                  grid.childAspectRatio(
                    tileWidth: width,
                    textBudget: textBudget,
                  );
              final focusIndex = widget.items.indexWhere(
                (item) => item.id == widget.focusedId,
              );
              _itemStride = width + grid.spacing;
              final controller = _scrollController ??= ScrollController(
                initialScrollOffset: math.max(0, focusIndex) * _itemStride,
              );
              return SizedBox(
                height: height,
                child: ListView.separated(
                  key: PageStorageKey('media.shelf.${widget.key ?? widget.title}'),
                  controller: controller,
                  primary: false,
                  scrollDirection: Axis.horizontal,
                  padding: EdgeInsets.symmetric(horizontal: grid.padding.left),
                  scrollCacheExtent: const ScrollCacheExtent.pixels(200),
                  itemCount:
                      widget.items.length + (widget.loadMore == null ? 0 : 1),
                  separatorBuilder: (_, _) => SizedBox(width: grid.spacing),
                  itemBuilder: (context, i) => SizedBox(
                    width: width,
                    child: Focus(
                      canRequestFocus: false,
                      skipTraversal: true,
                      child: Builder(
                        builder: (tileContext) => Focus(
                          canRequestFocus: false,
                          skipTraversal: true,
                          onFocusChange: (focused) =>
                              _reveal(tileContext, focused),
                          child: i == widget.items.length
                              ? widget.loadMore!
                              : MediaGridTile(
                                  item: widget.items[i],
                                  resumeEntry:
                                      widget.resumeEntries[widget.items[i].id],
                                  favorite: widget.isFavorite(
                                    widget.items[i].id,
                                  ),
                                  position: i + 1,
                                  total: widget.items.length,
                                  autofocus:
                                      widget.items[i].id == widget.focusedId,
                                  focusNode:
                                      widget.items[i].id == widget.focusedId
                                      ? widget.firstFocusNode
                                      : null,
                                  textBudget: textBudget,
                                  compact: true,
                                  scrollOnFocus: false,
                                  onTap: () => widget.onOpen(widget.items[i]),
                                  onFocusTabs: i == 0
                                      ? widget.onFocusTabs
                                      : null,
                                ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}

class _MediaSectionHeading extends StatelessWidget {
  final String title;
  final String? detail;

  const _MediaSectionHeading({required this.title, this.detail});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 10),
      child: Wrap(
        spacing: 12,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.4,
            ),
          ),
          if (detail != null)
            Text(
              detail!,
              style: const TextStyle(color: AppColors.textLo, fontSize: 12),
            ),
        ],
      ),
    );
  }
}

/// Uses the provider's first title, without implying a popularity ranking.
/// Its content determines its height so larger accessibility text can reflow.
class _FeaturedMedia extends StatefulWidget {
  final MediaItem item;
  final FocusNode? focusNode;
  final bool autofocus;
  final VoidCallback onOpen;
  final VoidCallback? onPlay;
  final VoidCallback? onFocusTabs;

  const _FeaturedMedia({
    required this.item,
    required this.focusNode,
    required this.autofocus,
    required this.onOpen,
    required this.onPlay,
    this.onFocusTabs,
  });

  @override
  State<_FeaturedMedia> createState() => _FeaturedMediaState();
}

class _FeaturedMediaState extends State<_FeaturedMedia> {
  late final _primaryNode = RoutedFocusNode('media.featured.primary');
  late final _detailsNode = RoutedFocusNode('media.featured.details');

  void _revealAction(FocusNode node, bool focused) {
    if (!focused) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !node.hasFocus || node.context == null) return;
      Scrollable.ensureVisible(
        node.context!,
        alignment: 0.5,
        duration: appMotion(context, const Duration(milliseconds: 180)),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  void dispose() {
    _primaryNode.dispose();
    _detailsNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final primaryNode = widget.focusNode ?? _primaryNode;
    final art = item.backdrop?.isNotEmpty == true
        ? item.backdrop
        : item.poster?.isNotEmpty == true
        ? item.poster
        : null;
    final duration = _mediaDurationLabel(item.durationSeconds);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final short = MediaQuery.sizeOf(context).height <= 600;
          final compact = constraints.maxWidth < 680 || short;
          final inset = short
              ? 14.0
              : compact
              ? 16.0
              : 22.0;
          final fallback = DecoratedBox(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topRight,
                end: Alignment.bottomLeft,
                colors: [Color(0xFF462A36), AppColors.panel, AppColors.ink],
              ),
            ),
            child: Align(
              alignment: const Alignment(0.72, -0.2),
              child: Icon(
                item.kind == ContentKind.movie
                    ? Icons.movie_outlined
                    : Icons.video_library_outlined,
                size: compact ? 130 : 190,
                color: AppColors.textHi.withValues(alpha: 0.06),
              ),
            ),
          );
          return ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Stack(
              children: [
                Positioned.fill(
                  child: art == null
                      ? fallback
                      : CachedNetworkImage(
                          imageUrl: art,
                          fit: BoxFit.cover,
                          alignment: Alignment.centerRight,
                          memCacheWidth: imageCacheSize(
                            context,
                            constraints.maxWidth,
                          ),
                          placeholder: (_, _) => fallback,
                          errorWidget: (_, url, error) {
                            logImageFailure(error, url);
                            return fallback;
                          },
                        ),
                ),
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          AppColors.ink.withValues(alpha: 0.97),
                          AppColors.ink.withValues(alpha: compact ? 0.78 : 0.8),
                          AppColors.ink.withValues(alpha: compact ? 0.5 : 0.08),
                        ],
                        stops: const [0, 0.44, 1],
                      ),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          AppColors.ink.withValues(alpha: 0.9),
                        ],
                        stops: const [0.5, 1],
                      ),
                    ),
                  ),
                ),
                Container(
                  constraints: BoxConstraints(
                    minHeight: short
                        ? 180
                        : compact
                        ? 210
                        : 240,
                  ),
                  padding: EdgeInsets.all(inset),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: constraints.maxWidth < 680
                            ? constraints.maxWidth
                            : 600,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 3,
                                height: 15,
                                color: AppColors.accent,
                              ),
                              const SizedBox(width: 9),
                              Expanded(
                                child: Text(
                                  tr('FROM YOUR LIBRARY'),
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 2,
                                    color: AppColors.textLo,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          SizedBox(height: short ? 10 : 14),
                          Text(
                            item.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: short
                                  ? 23
                                  : compact
                                  ? 25
                                  : 32,
                              height: 1.1,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -1.1,
                            ),
                          ),
                          SizedBox(height: short ? 10 : 12),
                          Wrap(
                            spacing: 12,
                            runSpacing: 8,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text(
                                item.kind == ContentKind.movie
                                    ? tr('MOVIE')
                                    : tr('SERIES'),
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 1,
                                  color: AppColors.accent,
                                ),
                              ),
                              if (item.year?.isNotEmpty == true)
                                Text(item.year!),
                              if (duration != null) Text(duration),
                              if (_hasRating(item))
                                _RatingBadge(rating: item.rating),
                            ],
                          ),
                          if (item.description?.isNotEmpty == true) ...[
                            SizedBox(height: short ? 10 : 14),
                            Text(
                              item.description!,
                              maxLines: short
                                  ? 1
                                  : compact
                                  ? 2
                                  : 3,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 14,
                                height: 1.5,
                                color: Color(0xFFCED2DA),
                              ),
                            ),
                          ],
                          SizedBox(height: short ? 16 : 22),
                          Wrap(
                            spacing: 12,
                            runSpacing: 10,
                            children: [
                              Focus(
                                canRequestFocus: false,
                                skipTraversal: true,
                                onFocusChange: (value) =>
                                    _revealAction(primaryNode, value),
                                onKeyEvent: (_, event) =>
                                    _focusTabsOnLeft(event, widget.onFocusTabs),
                                child: FilledButton.icon(
                                  key: const ValueKey('media.featured.primary'),
                                  focusNode: primaryNode,
                                  autofocus: widget.autofocus,
                                  onPressed: widget.onPlay ?? widget.onOpen,
                                  icon: Icon(
                                    widget.onPlay != null
                                        ? Icons.play_arrow_rounded
                                        : Icons.video_library_outlined,
                                  ),
                                  label: Text(
                                    widget.onPlay != null
                                        ? tr('Play')
                                        : tr('View episodes'),
                                  ),
                                ),
                              ),
                              if (widget.onPlay != null)
                                Focus(
                                  canRequestFocus: false,
                                  skipTraversal: true,
                                  onFocusChange: (value) =>
                                      _revealAction(_detailsNode, value),
                                  child: OutlinedButton.icon(
                                    focusNode: _detailsNode,
                                    onPressed: widget.onOpen,
                                    icon: const Icon(
                                      Icons.info_outline_rounded,
                                    ),
                                    label: Text(tr('More info')),
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

String? _mediaDurationLabel(int? seconds) {
  if (seconds == null || seconds <= 0) return null;
  final minutes = (seconds / 60).ceil();
  if (minutes < 60) return tr('{minutes} min', {'minutes': minutes});
  final hours = minutes ~/ 60;
  final remainder = minutes % 60;
  return remainder == 0
      ? tr('{hours} hr', {'hours': hours})
      : tr('{hours} hr {minutes} min', {'hours': hours, 'minutes': remainder});
}

/// Remaining watch time as `23 min left` / `1 hr 12 min left`, or null when
/// the duration is unknown or the item is effectively finished.
String? _remainingLabel(PlaybackPosition position) {
  if (position.duration <= Duration.zero) return null;
  final remaining = position.duration - position.position;
  if (remaining.inSeconds < 30) return null;
  final minutes = remaining.inMinutes;
  if (minutes < 1) return tr('Less than a min left');
  if (minutes < 60) return tr('{minutes} min left', {'minutes': minutes});
  final hours = minutes ~/ 60;
  final mins = minutes % 60;
  return mins == 0
      ? tr('{hours} hr left', {'hours': hours})
      : tr('{hours} hr {minutes} min left', {'hours': hours, 'minutes': mins});
}

/// `S2 · E5 · 23 min left` style second line — season/episode (episodes
/// only) and remaining time, whichever of the two apply.
String? _continueWatchingSubtitle(ContinueWatchingEntry entry) {
  final item = entry.item;
  final parts = <String>[
    if (item.seasonNumber != null && item.episodeNumber != null)
      tr('S{season} · E{episode}', {
        'season': item.seasonNumber!,
        'episode': item.episodeNumber!,
      }),
    ?_remainingLabel(entry.position),
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

/// Everything the tile knows, for a screen reader: the series, the episode by
/// name, where it sits, and how much is left. The visible tile has room for a
/// series line and one meta line, so the episode title only survives here.
String _continueWatchingSemantics(ContinueWatchingEntry entry) {
  final item = entry.item;
  final parts = <String>[
    entry.displayTitle,
    // Only when it isn't already the line above — a movie would repeat itself.
    if (entry.seriesTitle != null) item.title,
    if (item.seasonNumber != null && item.episodeNumber != null)
      tr('season {season} episode {episode}', {
        'season': item.seasonNumber!,
        'episode': item.episodeNumber!,
      }),
    ?_remainingLabel(entry.position),
  ];
  return parts.join(', ');
}

/// A landscape (16:9) artwork tile for episode rows — prefers
/// [MediaItem.backdrop] (a proper cinematic still) and falls back to
/// [MediaItem.poster] (often a video-frame screenshot for episodes), since
/// either is landscape-shaped content, unlike [_Poster]'s portrait crop.
class _Thumb extends StatelessWidget {
  final MediaItem item;
  final double width;
  final double height;
  final bool preferPoster;

  const _Thumb({
    required this.item,
    required this.width,
    required this.height,
    this.preferPoster = false,
  });

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      width: width,
      height: height,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.panelHi,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(
        item.kind == ContentKind.movie
            ? Icons.movie_outlined
            : Icons.tv_outlined,
        color: AppColors.textLo,
      ),
    );
    final backdrop = item.backdrop;
    final poster = item.poster;
    final image = preferPoster && poster != null && poster.isNotEmpty
        ? poster
        : (backdrop != null && backdrop.isNotEmpty)
        ? backdrop
        : (poster != null && poster.isNotEmpty)
        ? poster
        : null;
    if (image == null) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: CachedNetworkImage(
        imageUrl: image,
        width: width,
        height: height,
        fit: BoxFit.cover,
        // Width only — see [imageCacheSize]. Passing both dimensions decodes
        // the bitmap pre-distorted to this box's 16:9, which matters most
        // here: when a title has no backdrop this falls back to the *poster*,
        // and squashing 2:3 into 16:9 makes the entry unrecognisable.
        memCacheWidth: imageCacheSize(context, width),
        // Same widget for both states by design; the log is what tells them
        // apart (see [logImageFailure]).
        errorWidget: (_, url, error) {
          logImageFailure(error, url);
          return fallback;
        },
        placeholder: (_, _) => fallback,
      ),
    );
  }
}

class MediaListTile extends StatelessWidget {
  final MediaItem item;
  final bool favorite;
  final int position;
  final int total;
  final bool autofocus;
  final FocusNode? focusNode;
  final String? debugLabel;
  final VoidCallback onTap;
  final VoidCallback? onFocusTabs;

  const MediaListTile({
    super.key,
    required this.item,
    required this.favorite,
    required this.position,
    required this.total,
    required this.autofocus,
    this.focusNode,
    this.debugLabel,
    required this.onTap,
    this.onFocusTabs,
  });

  @override
  Widget build(BuildContext context) {
    return FocusableCard(
      autofocus: autofocus,
      centerOnFocus: false,
      focusNode: focusNode,
      debugLabel: debugLabel ?? 'media.item.${item.id}',
      onKeyEvent: (_, event) => _focusTabsOnLeft(event, onFocusTabs),
      semanticsLabel: [
        item.title,
        if (item.year != null) item.year!,
        tr('{position} of {total}', {'position': position, 'total': total}),
        if (favorite) tr('Favorite'),
      ].join(', '),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            _Poster(item: item, width: 58, height: 84),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  if (item.year != null || _hasRating(item)) ...[
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        if (item.year != null)
                          Flexible(
                            child: Text(
                              item.year!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: AppColors.textLo,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        if (item.year != null && _hasRating(item))
                          const SizedBox(width: 10),
                        _RatingBadge(rating: item.rating),
                      ],
                    ),
                  ],
                  // Parsed once per tile build: the pattern binds the list so
                  // the emptiness test and the widget share one parse.
                  if (sourceHintLabels(item) case final hints
                      when hints.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    _SourceHints(hints: hints),
                  ],
                  if (item.description != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      item.description!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textLo,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (favorite) ...[const SizedBox(width: 8), const FavoriteBadge()],
            const SizedBox(width: 8),
            Icon(
              item.kind == ContentKind.movie
                  ? Icons.play_arrow_rounded
                  : Icons.chevron_right_rounded,
              color: AppColors.accent,
            ),
          ],
        ),
      ),
    );
  }
}

class MediaGridTile extends StatelessWidget {
  final MediaItem item;
  final ContinueWatchingEntry? resumeEntry;
  final bool favorite;
  final int position;
  final int total;
  final bool autofocus;
  final FocusNode? focusNode;
  final String? debugLabel;
  final bool compact;
  final bool scrollOnFocus;

  /// Fixed height reserved for the text under the poster
  /// ([mediaTileTextBudget]) — the same value the grid's `childAspectRatio`
  /// was computed from, so the `Expanded` poster above it lands on
  /// [MediaGridMetrics.posterAspectRatio] in *every* cell instead of varying
  /// with how much text each item happens to carry.
  final double textBudget;

  final VoidCallback onTap;
  final VoidCallback? onFocusTabs;

  const MediaGridTile({
    super.key,
    required this.item,
    this.resumeEntry,
    required this.favorite,
    required this.position,
    required this.total,
    required this.autofocus,
    this.focusNode,
    this.debugLabel,
    this.compact = false,
    this.scrollOnFocus = true,
    required this.textBudget,
    required this.onTap,
    this.onFocusTabs,
  });

  @override
  Widget build(BuildContext context) {
    final resume = resumeEntry;
    final subtitle = resume == null ? null : _continueWatchingSubtitle(resume);
    return FocusableCard(
      autofocus: autofocus,
      centerOnFocus: false,
      scrollOnFocus: scrollOnFocus,
      focusNode: focusNode,
      debugLabel:
          debugLabel ??
          (resume == null ? 'media.item.${item.id}' : 'media.continue.${item.id}'),
      onKeyEvent: (_, event) => _focusTabsOnLeft(event, onFocusTabs),
      semanticsLabel: [
        resume == null ? item.title : _continueWatchingSemantics(resume),
        if (item.year != null) item.year!,
        tr('{position} of {total}', {'position': position, 'total': total}),
        if (favorite) tr('Favorite'),
      ].join(', '),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(MediaGridMetrics.tilePadding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: SizedBox.expand(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _Poster(
                      item: item,
                      width: double.infinity,
                      height: double.infinity,
                    ),
                    if (resume != null)
                      const Center(
                        child: CircleAvatar(
                          radius: 18,
                          backgroundColor: Colors.black54,
                          child: Icon(
                            Icons.play_arrow_rounded,
                            color: Colors.white,
                            size: 22,
                          ),
                        ),
                      ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: IgnorePointer(
                        child: Container(
                          height: 58,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.transparent,
                                AppColors.ink.withValues(alpha: 0.8),
                              ],
                            ),
                          ),
                          alignment: Alignment.bottomLeft,
                          padding: const EdgeInsets.all(8),
                          child: Text(
                            item.kind == ContentKind.movie
                                ? tr('MOVIE')
                                : tr('SERIES'),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 9,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1.3,
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (_hasRating(item))
                      Positioned(
                        top: 6,
                        left: 6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.ink.withValues(alpha: 0.75),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: _RatingBadge(
                            rating: item.rating,
                            compact: true,
                          ),
                        ),
                      ),
                    if (favorite)
                      Positioned(
                        top: 6,
                        right: 6,
                        child: Container(
                          padding: const EdgeInsets.all(3),
                          decoration: BoxDecoration(
                            color: AppColors.ink.withValues(alpha: 0.75),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const FavoriteBadge(size: 16),
                        ),
                      ),
                    if (resume != null)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: LinearProgressIndicator(
                          value: resume.position.progress,
                          minHeight: 4,
                          backgroundColor: Colors.white.withValues(alpha: 0.3),
                          color: AppColors.accent,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: MediaGridMetrics.posterTextGap),
            // Fixed-height text block. `OverflowBox` + `ClipRect` rather than a
            // bare `SizedBox`: the budget is an estimate built from font
            // metrics, and a font whose real line height runs a hair taller
            // than the estimate must clip quietly instead of throwing a
            // RenderFlex overflow across every tile in the catalogue.
            SizedBox(
              width: double.infinity,
              height: textBudget,
              child: ClipRect(
                child: OverflowBox(
                  alignment: Alignment.topLeft,
                  minHeight: 0,
                  maxHeight: double.infinity,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        resume?.displayTitle ?? item.title,
                        maxLines: subtitle == null ? 2 : 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      if (subtitle != null)
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.textLo,
                            fontSize: 11,
                          ),
                        ),
                      if (!compact && item.year != null)
                        Text(
                          item.year!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.textLo,
                            fontSize: 12,
                          ),
                        ),
                      if (!compact)
                        if (sourceHintLabels(item) case final hints
                            when hints.isNotEmpty) ...[
                          const SizedBox(height: 5),
                          _SourceHints(hints: hints, compact: true),
                        ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Renders already-parsed hint labels. It deliberately takes the parsed list
/// rather than the `MediaItem`: `sourceHintLabels` is not cheap (regexes + the
/// language alias table) and every call site already has to test the result for
/// emptiness, so parsing here too would double the cost on every tile build.
class _SourceHints extends StatelessWidget {
  final List<String> hints;
  final bool compact;

  const _SourceHints({required this.hints, this.compact = false});

  @override
  Widget build(BuildContext context) {
    if (hints.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 5,
      runSpacing: 5,
      children: [
        for (final hint in hints.take(compact ? 2 : 4))
          Container(
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 5 : 6,
              vertical: compact ? 2 : 3,
            ),
            decoration: BoxDecoration(
              color: AppColors.panelHi,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: AppColors.line),
            ),
            child: Text(
              hint,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AppColors.textLo,
                fontSize: compact ? 10 : 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
      ],
    );
  }
}

/// Whether an item has a real (non-zero) score worth showing. Many items come
/// back with `rating == 0.0`, which means "unrated", not a literal zero.
bool _hasRating(MediaItem item) => (item.rating ?? 0) > 0;

/// A small `★ 8.5` rating chip, shown when an item carries a non-zero 0–10
/// score (TMDB or MDBList). Renders nothing otherwise.
class _RatingBadge extends StatelessWidget {
  final double? rating;
  final bool compact;

  const _RatingBadge({required this.rating, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final value = rating;
    if (value == null || value <= 0) return const SizedBox.shrink();
    final fontSize = compact ? 11.0 : 12.0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.star_rounded, size: fontSize + 3, color: AppColors.accent),
        const SizedBox(width: 3),
        Text(
          value.toStringAsFixed(1),
          style: TextStyle(
            color: AppColors.textHi,
            fontSize: fontSize,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _MediaLoadMoreTile extends StatefulWidget {
  final MediaLibrarySnapshot? snapshot;
  final bool loading;
  final VoidCallback onPressed;
  final VoidCallback? onFocusTabs;

  const _MediaLoadMoreTile({
    required this.snapshot,
    required this.loading,
    required this.onPressed,
    this.onFocusTabs,
  });

  @override
  State<_MediaLoadMoreTile> createState() => _MediaLoadMoreTileState();
}

class _MediaLoadMoreTileState extends State<_MediaLoadMoreTile> {
  // Stateful purely to own this node: a plain `FilledButton` focus node
  // carries no route key, so the root Back ladder read `''` from it and fell
  // through to the exit prompt instead of climbing to the tabs.
  late final FocusNode _focusNode = RoutedFocusNode('media.loadMore');

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = widget.snapshot;
    final loading = widget.loading;
    final canLoad = snapshot?.hasMore == true;
    final nextPage = snapshot == null ? null : snapshot.loadedPages + 1;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (_, event) => _focusTabsOnLeft(event, widget.onFocusTabs),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Center(
          child: FilledButton.icon(
            focusNode: _focusNode,
            onPressed: canLoad && !loading ? widget.onPressed : null,
            icon: loading
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.expand_more_rounded),
            label: Text(
              loading
                  ? tr('Loading')
                  : canLoad
                  ? nextPage == null
                        ? tr('Load more')
                        : tr('Load page {page}', {'page': nextPage})
                  : tr('All loaded'),
            ),
          ),
        ),
      ),
    );
  }
}

class _MediaLoadMoreCard extends StatelessWidget {
  final MediaLibrarySnapshot? snapshot;
  final bool loading;
  final VoidCallback onPressed;
  final bool scrollOnFocus;
  final VoidCallback? onFocusTabs;

  const _MediaLoadMoreCard({
    required this.snapshot,
    required this.loading,
    required this.onPressed,
    this.scrollOnFocus = true,
    this.onFocusTabs,
  });

  @override
  Widget build(BuildContext context) {
    final canLoad = snapshot?.hasMore == true;
    final nextPage = snapshot == null ? null : snapshot!.loadedPages + 1;
    return FocusableCard(
      autofocus: false,
      scrollOnFocus: scrollOnFocus,
      onKeyEvent: (_, event) => _focusTabsOnLeft(event, onFocusTabs),
      // Without an explicit label this minted the route key `FocusableCard`,
      // which is non-empty and not `media.`-prefixed — so the root Back ladder
      // matched neither its `media.` rung nor its empty-label recovery, and
      // Back from the end of the grid dropped straight to the exit prompt.
      debugLabel: 'media.loadMore',
      onTap: canLoad && !loading ? onPressed : () {},
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (loading)
              const SizedBox.square(
                dimension: 28,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Icon(
                canLoad ? Icons.expand_more_rounded : Icons.check_rounded,
                color: canLoad ? AppColors.accent : AppColors.textLo,
                size: 32,
              ),
            const SizedBox(height: 8),
            Text(
              loading
                  ? tr('Loading')
                  : canLoad
                  ? nextPage == null
                        ? tr('Load more')
                        : tr('Load page {page}', {'page': nextPage})
                  : tr('All loaded'),
              style: const TextStyle(color: AppColors.textLo),
            ),
          ],
        ),
      ),
    );
  }
}

class _Poster extends StatelessWidget {
  final MediaItem item;
  final double width;
  final double height;

  const _Poster({
    required this.item,
    required this.width,
    required this.height,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final renderedWidth = width.isFinite && width > 0
            ? width
            : constraints.maxWidth;
        final renderedHeight = height.isFinite && height > 0
            ? height
            : constraints.maxHeight;
        final fallback = Container(
          width: renderedWidth,
          height: renderedHeight,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppColors.panelHi,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            item.kind == ContentKind.movie
                ? Icons.movie_outlined
                : Icons.tv_outlined,
            color: AppColors.textLo,
          ),
        );
        final poster = item.poster;
        if (poster == null || poster.isEmpty) return fallback;
        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: CachedNetworkImage(
            imageUrl: poster,
            width: renderedWidth,
            height: renderedHeight,
            fit: BoxFit.cover,
            // Width only — see [imageCacheSize]. Decoding to both dimensions
            // selects `ResizeImagePolicy.exact`, which is `BoxFit.fill` at
            // decode time and leaves the `BoxFit.cover` below nothing to crop.
            // The tile's box aspect is fixed now (see
            // [MediaGridMetrics.childAspectRatio]), so the stretch would be
            // uniform rather than per-tile — still wrong, just less obviously.
            memCacheWidth: imageCacheSize(context, renderedWidth),
            // Same widget for both states by design; the log is what tells
            // them apart (see [logImageFailure]).
            errorWidget: (_, url, error) {
              logImageFailure(error, url);
              return fallback;
            },
            placeholder: (_, _) => fallback,
          ),
        );
      },
    );
  }
}

class MediaDetailsSheet extends StatefulWidget {
  final LibraryRepository repo;
  final MediaItem item;
  final bool favorite;
  final VoidCallback onToggleFavorite;
  final VoidCallback? onPlay;
  final ValueChanged<MediaItem>? onChanged;

  /// Plays one episode picked from the series browser. Routed back through the
  /// screen's own play path (rather than pushing a player here) so the
  /// "Continue watching" rail reloads on return, exactly like a movie does.
  final ValueChanged<MediaItem>? onPlayEpisode;

  const MediaDetailsSheet({
    super.key,
    required this.repo,
    required this.item,
    required this.favorite,
    required this.onToggleFavorite,
    required this.onPlay,
    this.onChanged,
    this.onPlayEpisode,
    this.resume,
    this.onPlayFromStart,
  });

  /// Saved resume point for this item, if any — turns the Play button into
  /// "Resume from h:mm:ss" and surfaces [onPlayFromStart] beside it.
  final PlaybackPosition? resume;
  final VoidCallback? onPlayFromStart;

  @override
  State<MediaDetailsSheet> createState() => _MediaDetailsSheetState();
}

class _MediaDetailsSheetState extends State<MediaDetailsSheet> {
  late MediaItem _item = widget.item;
  late bool _favorite = widget.favorite;
  late Future<ExternalMetadata?> _metadataFuture = _loadMetadata();
  late final Future<MediaLibrarySnapshot>? _seasonsFuture = _loadSeasonsIfNeeded();
  final Map<String, Future<MediaLibrarySnapshot>> _episodeFutures = {};
  bool _refreshingMetadata = false;
  bool _openingTrailer = false;
  final _scrollController = ScrollController();
  final _playFocusNode = RoutedFocusNode('media.details.play');
  final _browseEpisodesFocusNode = RoutedFocusNode('media.details.episodes');
  final _fromStartFocusNode = RoutedFocusNode('media.details.fromStart');
  final _trailerFocusNode = RoutedFocusNode('media.details.trailer');
  final _favoriteFocusNode = RoutedFocusNode('media.details.favorite');
  final _closeFocusNode = RoutedFocusNode('media.details.close');
  final _episodesKey = GlobalKey();
  SeriesWatchProgress? _seriesProgress;
  MediaItem? _seriesContinuation;
  bool _seriesComplete = false;
  bool _preparingContinuation = false;
  int _seriesProgressLoad = 0;
  StreamSubscription<void>? _seriesPlaybackChanged;
  StreamSubscription<void>? _seriesPlaybackReplaced;

  @override
  void initState() {
    super.initState();
    if (_item.kind == ContentKind.series) {
      unawaited(_loadSeriesProgress(prepareNext: true));
    }
  }

  Future<void> _loadSeriesProgress({bool prepareNext = false}) async {
    final load = ++_seriesProgressLoad;
    try {
      await _seasonsFuture;
      if (!mounted || load != _seriesProgressLoad) return;
      final db = widget.repo.db;
      _seriesPlaybackChanged ??= db.playbackPositionsChanged.listen(
        (_) => unawaited(_loadSeriesProgress(prepareNext: true)),
      );
      _seriesPlaybackReplaced ??= db.playbackPositionsReplaced.listen(
        (_) => unawaited(_loadSeriesProgress(prepareNext: true)),
      );
      final sourceId = widget.repo.source.id;
      final episodes = await db.readCachedSeriesEpisodes(sourceId, _item.id);
      final positions = await db.readEpisodePlaybackPositions(
        sourceId,
        episodes.map((episode) => episode.id).toList(),
      );
      final progress = SeriesWatchProgress.fromEpisodes(episodes, positions);
      if (progress.latestEpisode == null) {
        if (!mounted || load != _seriesProgressLoad) return;
        if (_seriesProgress?.latestEpisode != null) {
          if (_browseEpisodesFocusNode.hasFocus) _playFocusNode.requestFocus();
          setState(() {
            _seriesProgress = progress;
            _seriesContinuation = null;
            _seriesComplete = false;
          });
        } else {
          _seriesProgress = progress;
        }
        return;
      }
      final seasons = orderPlaybackEpisodes(
        await db.readMediaItems(
          sourceId,
          ContentKind.season,
          parentId: _item.id,
        ),
      );
      final seasonSync = await db.mediaSyncState(
        sourceId,
        ContentKind.season,
        parentId: _item.id,
      );
      var complete =
          seasonSync != null &&
          seasonSync.loadedPages >= seasonSync.totalPages &&
          episodes.isNotEmpty;
      final completeSeasons = <String>{};
      for (final season in seasons) {
        final sync = await db.mediaSyncState(
          sourceId,
          ContentKind.episode,
          parentId: season.id,
        );
        if (sync != null && sync.loadedPages >= sync.totalPages) {
          completeSeasons.add(season.id);
        } else {
          complete = false;
        }
      }
      var continuation = progress.nextEpisode;
      final latest = progress.latestEpisode;
      // A cached later season must not jump over an unloaded season/page.
      if (latest != null &&
          continuation != null &&
          continuation.parentId != latest.parentId) {
        final from = seasons.indexWhere((s) => s.id == latest.parentId);
        final to = seasons.indexWhere((s) => s.id == continuation!.parentId);
        if (from < 0 ||
            to <= from ||
            seasons
                .sublist(from, to)
                .any((s) => !completeSeasons.contains(s.id))) {
          continuation = null;
        }
      }
      if (!mounted || load != _seriesProgressLoad) return;
      if (continuation == null && _browseEpisodesFocusNode.hasFocus) {
        _playFocusNode.requestFocus();
      }
      setState(() {
        _seriesProgress = progress;
        _seriesContinuation = continuation;
        _seriesComplete = complete && progress.watchedCount == episodes.length;
      });
      if (prepareNext &&
          latest != null &&
          continuation == null &&
          !_seriesComplete) {
        unawaited(_prepareSeriesContinuation(progress, seasons));
      }
    } catch (_) {
      // History must never block the existing season browser or playback.
    }
  }

  Future<void> _prepareSeriesContinuation(
    SeriesWatchProgress progress,
    List<MediaItem> seasons,
  ) async {
    if (_preparingContinuation || !mounted) return;
    final latest = progress.latestEpisode;
    final index = seasons.indexWhere((s) => s.id == latest?.parentId);
    if (index < 0) return;
    _preparingContinuation = true;
    try {
      // Prepare only the watched season and its immediate successor. Unstarted
      // series and further provider pages retain explicit, lazy browsing.
      _clearInheritedLoadToken();
      final page = await widget.repo.loadMedia(
        ContentKind.episode,
        parent: seasons[index],
        enrichChildren: false,
      );
      final current = SeriesWatchProgress.fromEpisodes(
        page.items,
        progress.positions,
      );
      if (mounted &&
          current.nextEpisode == null &&
          !page.hasMore &&
          index + 1 < seasons.length) {
        _clearInheritedLoadToken();
        await widget.repo.loadMedia(
          ContentKind.episode,
          parent: seasons[index + 1],
          enrichChildren: false,
        );
      }
      if (mounted) await _loadSeriesProgress();
    } catch (_) {
      // The cached summary and View episodes remain usable offline.
    } finally {
      _preparingContinuation = false;
    }
  }

  /// Captured by `_SeriesBrowser.onFirstSeasonFocusNode` once the first
  /// season header builds — see that field's doc comment.
  FocusNode? _firstSeasonFocusNode;

  void _showEpisodes() {
    final node = _firstSeasonFocusNode;
    if (node != null && node.context != null && node.canRequestFocus) {
      node.requestFocus();
      _revealControl(node, true);
      return;
    }
    // Loading, empty and error states have no season focus target. Reveal
    // their section without moving focus to a control outside the viewport.
    final section = _episodesKey.currentContext;
    if (section != null) {
      Scrollable.ensureVisible(
        section,
        duration: appMotion(context, const Duration(milliseconds: 180)),
        curve: Curves.easeOutCubic,
      );
    }
    _closeFocusNode.requestFocus();
  }

  void _revealControl(FocusNode node, bool focused) {
    if (!focused) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !node.hasFocus || node.context == null) return;
      Scrollable.ensureVisible(
        node.context!,
        alignment: 0.5,
        duration: appMotion(context, const Duration(milliseconds: 180)),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  void dispose() {
    _seriesPlaybackChanged?.cancel();
    _seriesPlaybackReplaced?.cancel();
    _scrollController.dispose();
    _playFocusNode.dispose();
    _browseEpisodesFocusNode.dispose();
    _fromStartFocusNode.dispose();
    _trailerFocusNode.dispose();
    _favoriteFocusNode.dispose();
    _closeFocusNode.dispose();
    super.dispose();
  }

  /// Clears the repository's cancellation token for the drill-down about to
  /// run, in the synchronous prologue the field's contract requires.
  ///
  /// These loads are the sheet's own, and they are the only `loadMedia` callers
  /// that are not a [MediaTabController]. Every controller path sets
  /// `repo.loadToken` immediately before its own call; the sheet set nothing,
  /// so it inherited whatever was left on the shared repository — and it *is*
  /// shared: the movie and series controllers are built over one
  /// [LibraryRepository] and each cancels only its own token, while
  /// `MediaTabController.dispose` cancels one outright. So a season or episode
  /// fetch could begin already-cancelled, through no act of its own, and
  /// quietly decline to cache its result: a drill-down that re-hit the provider
  /// on every open.
  ///
  /// Null rather than a token of its own, deliberately. A token would only earn
  /// its keep if something could supersede these loads, and nothing can — they
  /// write to their own `(kind, parentId)` cache key, which no other caller
  /// touches, so there is no staler writer to lose a race to.
  void _clearInheritedLoadToken() => widget.repo.loadToken = null;

  Future<MediaLibrarySnapshot>? _loadSeasonsIfNeeded() {
    if (_item.kind != ContentKind.series) return null;
    _clearInheritedLoadToken();
    return widget.repo.loadMedia(ContentKind.season, parent: _item);
  }

  Future<MediaLibrarySnapshot> _episodes(MediaItem season) =>
      _episodeFutures.putIfAbsent(season.id, () {
        _clearInheritedLoadToken();
        return widget.repo.loadMedia(ContentKind.episode, parent: season);
      });

  bool get _hasMetadataProvider => widget.repo.metadataProviders.any(
    (provider) => !provider.ratingsOnly &&
        (provider.provider != 'tvmaze' || _item.kind == ContentKind.series),
  );

  Future<ExternalMetadata?> _loadMetadata() async {
    ExternalMetadata? latest;
    for (final provider in widget.repo.metadataProviders) {
      if (provider.ratingsOnly) continue;
      final metadata = await widget.repo.cachedExternalMetadata(
        _item,
        provider.provider,
      );
      if (metadata != null &&
          (latest == null || metadata.refreshedAt.isAfter(latest.refreshedAt))) {
        latest = metadata;
      }
    }
    return latest;
  }

  Future<void> _refreshMetadata() async {
    if (_refreshingMetadata || !_hasMetadataProvider) return;
    setState(() => _refreshingMetadata = true);
    try {
      final metadata = await widget.repo.refreshExternalMetadata(_item);
      if (!mounted) return;
      setState(() {
        if (metadata != null) {
          _item = widget.repo.mergeExternalMetadata(_item, metadata);
          widget.onChanged?.call(_item);
        }
        _metadataFuture = metadata == null
            ? _loadMetadata()
            : Future.value(metadata);
        _refreshingMetadata = false;
      });
      if (metadata == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('No matching metadata found.'))),
        );
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _refreshingMetadata = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            tr('Metadata refresh failed: {error}', {'error': error}),
          ),
        ),
      );
    }
  }

  void _play(MediaItem item) {
    // Keep the series browser beneath the player so Back restores its expanded
    // season, scroll position and focused episode. The screen's play path still
    // resolves playback and reloads "Continue watching" on return.
    widget.onPlayEpisode?.call(item);
  }

  Future<void> _openTrailer() async {
    if (_openingTrailer) return;
    _openingTrailer = true;
    try {
      if (await launchUrl(
        mediaTrailerUri(_item),
        mode: LaunchMode.externalApplication,
      )) {
        return;
      }
    } catch (_) {
      // Some devices have no app that can open web links. Keep the details
      // open and report the same failure without exposing provider URLs.
    } finally {
      _openingTrailer = false;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(tr('Could not open the trailer or YouTube.'))),
    );
  }

  @override
  Widget build(BuildContext context) {
    final window = MediaQuery.sizeOf(context);
    final fullScreen = window.width < kMediaSheetTwoColumnMinWidth;
    final short = window.height <= 600;
    final content = LayoutBuilder(
      builder: (context, constraints) {
        final seasonsFuture = _seasonsFuture;
        final inset = constraints.maxWidth < 680 ? 20.0 : 28.0;
        return Stack(
          children: [
            SingleChildScrollView(
              controller: _scrollController,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _cinematicHeader(context, constraints.maxWidth, short),
                  Padding(
                    padding: EdgeInsets.fromLTRB(inset, 14, inset, 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (seasonsFuture != null) ...[
                          Text(
                            tr('Episodes'),
                            key: _episodesKey,
                            style: Theme.of(context).textTheme.titleLarge
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 6),
                          _SeriesBrowser(
                            repo: widget.repo,
                            seasons: seasonsFuture,
                            episodesFor: _episodes,
                            artworkFallback: _item,
                            onPlayEpisode: _play,
                            onEpisodesChanged: (hasPlayback) {
                              if (hasPlayback ||
                                  _seriesProgress?.latestEpisode != null) {
                                unawaited(
                                  _loadSeriesProgress(prepareNext: true),
                                );
                              }
                            },
                            onFirstSeasonFocusNode: (node) =>
                                _firstSeasonFocusNode = node,
                            onExitAfterLastSeason: () {
                              if (mounted) {
                                final moved = FocusScope.of(context)
                                    .focusInDirection(TraversalDirection.down);
                                if (!moved) _closeFocusNode.requestFocus();
                              }
                            },
                          ),
                          const SizedBox(height: 20),
                        ],
                        if (_item.description?.isNotEmpty == true) ...[
                          _MediaInformationEntry(
                            key: const ValueKey('media.details.synopsis'),
                            routeKey: 'media.details.synopsis',
                            child: Text(
                              _item.description!,
                              style: const TextStyle(
                                color: Color(0xFFCED2DA),
                                fontSize: 14,
                                height: 1.5,
                              ),
                            ),
                          ),
                          const SizedBox(height: 20),
                        ],
                        _MediaInformation(info: MediaInfo.fromItem(_item)),
                        if (sourceHintLabels(_item) case final hints
                            when hints.isNotEmpty) ...[
                          _SourceHints(hints: hints),
                          const SizedBox(height: 14),
                        ],
                        if (providerSourceTitle(_item)
                            case final sourceTitle?) ...[
                          Text(
                            tr('Source title: {title}', {'title': sourceTitle}),
                            style: const TextStyle(
                              color: AppColors.textLo,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 14),
                        ],
                        _MetadataStatus(
                          metadata: _metadataFuture,
                          configured: _hasMetadataProvider,
                          refreshing: _refreshingMetadata,
                          onRefresh: _refreshMetadata,
                        ),
                        _MetadataAttribution(item: _item),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Positioned(
              top: 14,
              right: 14,
              child: IconButton(
                key: const ValueKey('media.details.close'),
                tooltip: tr('Close details'),
                focusNode: _closeFocusNode,
                autofocus: widget.onPlay == null && _seasonsFuture == null,
                onPressed: () => Navigator.of(context).maybePop(),
                style: ButtonStyle(
                  backgroundColor: const WidgetStatePropertyAll(AppColors.ink),
                  foregroundColor: const WidgetStatePropertyAll(Colors.white),
                  side: WidgetStateProperty.resolveWith(
                    (states) => BorderSide(
                      color: states.contains(WidgetState.focused)
                          ? Colors.white
                          : AppColors.line,
                      width: states.contains(WidgetState.focused) ? 2 : 1,
                    ),
                  ),
                  shape: const WidgetStatePropertyAll(CircleBorder()),
                ),
                icon: const Icon(Icons.close_rounded),
              ),
            ),
          ],
        );
      },
    );
    if (fullScreen) {
      return Material(
        key: const ValueKey('media.details.fullscreen'),
        color: AppColors.ink,
        child: SafeArea(child: content),
      );
    }
    final inset = EdgeInsets.symmetric(
      horizontal: window.width < 1000 ? 24 : 48,
      vertical: short ? 16 : 32,
    );
    return Dialog(
      key: const ValueKey('media.details.dialog'),
      backgroundColor: AppColors.ink,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      insetPadding: inset,
      constraints: const BoxConstraints(maxWidth: 1100, maxHeight: 900),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: AppColors.line),
      ),
      child: SizedBox(
        width: 1100,
        height: math.min(900, window.height - inset.vertical),
        child: content,
      ),
    );
  }

  Widget _cinematicHeader(BuildContext context, double width, bool short) {
    final compact = width < 680;
    final series = _item.kind == ContentKind.series;
    final inset = compact ? 22.0 : 32.0;
    final art = _item.backdrop?.isNotEmpty == true
        ? _item.backdrop
        : _item.poster?.isNotEmpty == true
        ? _item.poster
        : null;
    final duration = _mediaDurationLabel(_item.durationSeconds);
    final continuation = _seriesContinuation;
    final continuing = continuation != null && widget.onPlayEpisode != null;
    final fallback = DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
          colors: [Color(0xFF462A36), AppColors.panel, AppColors.ink],
        ),
      ),
      child: Align(
        alignment: const Alignment(0.65, -0.15),
        child: Icon(
          _item.kind == ContentKind.series
              ? Icons.video_library_outlined
              : Icons.movie_outlined,
          size: compact ? 140 : 200,
          color: AppColors.textHi.withValues(alpha: 0.06),
        ),
      ),
    );
    return Stack(
      children: [
        Positioned.fill(
          child: art == null
              ? fallback
              : CachedNetworkImage(
                  imageUrl: art,
                  fit: BoxFit.cover,
                  alignment: Alignment.centerRight,
                  memCacheWidth: imageCacheSize(context, width),
                  placeholder: (_, _) => fallback,
                  errorWidget: (_, url, error) {
                    logImageFailure(error, url);
                    return fallback;
                  },
                ),
        ),
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  AppColors.ink.withValues(alpha: 0.85),
                  AppColors.ink.withValues(alpha: 0.35),
                ],
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, AppColors.ink],
                stops: const [0.15, 1],
              ),
            ),
          ),
        ),
        Container(
          constraints: BoxConstraints(
            minHeight: series ? (short ? 210 : 270) : (short ? 250 : 340),
          ),
          padding: EdgeInsets.fromLTRB(inset, series ? 54 : 76, inset, 20),
          alignment: Alignment.bottomLeft,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _item.kind == ContentKind.series
                    ? tr('SERIES')
                    : _item.kind == ContentKind.episode
                    ? tr('EPISODE')
                    : tr('MOVIE'),
                style: const TextStyle(
                  color: AppColors.accent,
                  fontSize: 11,
                  letterSpacing: 2,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                _item.title,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: series
                      ? (compact || short ? 26 : 36)
                      : (compact || short ? 30 : 42),
                  height: 1.1,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.8,
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 14,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (_item.year?.isNotEmpty == true) Text(_item.year!),
                  if (duration != null) Text(duration),
                  if (_hasRating(_item)) _RatingBadge(rating: _item.rating),
                ],
              ),
              if (_seriesProgress case final progress?
                  when progress.latestEpisode != null) ...[
                const SizedBox(height: 14),
                Container(
                  key: const ValueKey('media.details.seriesProgress'),
                  constraints: const BoxConstraints(maxWidth: 660),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.ink.withValues(alpha: 0.8),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppColors.line),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        tr('Watched episodes: {count}', {
                          'count': progress.watchedCount,
                        }),
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        tr('Last watched: {episode}', {
                          'episode': _episodeSemanticsLabel(
                            progress.latestEpisode!,
                          ),
                        }),
                        style: const TextStyle(
                          color: AppColors.textLo,
                          fontSize: 13,
                        ),
                      ),
                      if (_seriesComplete) ...[
                        const SizedBox(height: 5),
                        Text(
                          tr('All available episodes watched'),
                          style: const TextStyle(
                            color: AppColors.accent,
                            fontSize: 13,
                          ),
                        ),
                      ] else if (continuation != null) ...[
                        const SizedBox(height: 5),
                        Text(
                          progress.latestPosition?.isFinished == false
                              ? _episodePlaybackLabel(progress.latestPosition!)
                              : tr('Next episode: {episode}', {
                                  'episode': _episodeSemanticsLabel(
                                    continuation,
                                  ),
                                }),
                          style: const TextStyle(
                            color: AppColors.accent,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
              SizedBox(height: series ? 14 : 20),
              Wrap(
                spacing: 12,
                runSpacing: 10,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (widget.onPlay != null || _seasonsFuture != null)
                    FilledButton.icon(
                      key: const ValueKey('media.details.play'),
                      focusNode: _playFocusNode,
                      autofocus: true,
                      onFocusChange: (value) =>
                          _revealControl(_playFocusNode, value),
                      onPressed: continuing
                          ? () => _play(continuation)
                          : widget.onPlay ?? _showEpisodes,
                      icon: Icon(
                        widget.onPlay == null && !continuing
                            ? Icons.video_library_outlined
                            : Icons.play_arrow_rounded,
                      ),
                      label: Text(
                        continuing
                            ? tr(
                                _seriesProgress!.latestPosition!.isFinished
                                    ? 'Play {episode}'
                                    : 'Resume {episode}',
                                {'episode': _episodeNumberLabel(continuation)},
                              )
                            : widget.onPlay == null
                            ? tr('View episodes')
                            : widget.resume != null
                            ? tr('Resume from {position}', {
                                'position': _positionLabel(
                                  widget.resume!.position,
                                ),
                              })
                            : tr('Play'),
                      ),
                    ),
                  if (continuing)
                    OutlinedButton.icon(
                      key: const ValueKey('media.details.episodes'),
                      focusNode: _browseEpisodesFocusNode,
                      onFocusChange: (value) =>
                          _revealControl(_browseEpisodesFocusNode, value),
                      onPressed: _showEpisodes,
                      icon: const Icon(Icons.video_library_outlined),
                      label: Text(tr('View episodes')),
                    ),
                  if (widget.resume != null && widget.onPlayFromStart != null)
                    OutlinedButton.icon(
                      focusNode: _fromStartFocusNode,
                      onFocusChange: (value) =>
                          _revealControl(_fromStartFocusNode, value),
                      onPressed: widget.onPlayFromStart,
                      icon: const Icon(Icons.replay_rounded),
                      label: Text(tr('From start')),
                    ),
                  if (_item.kind == ContentKind.movie ||
                      _item.kind == ContentKind.series)
                    OutlinedButton.icon(
                      key: const ValueKey('media.details.trailer'),
                      focusNode: _trailerFocusNode,
                      onFocusChange: (value) =>
                          _revealControl(_trailerFocusNode, value),
                      onPressed: _openTrailer,
                      icon: const Icon(Icons.ondemand_video_outlined),
                      label: Text(
                        mediaTrailerLink(_item) != null
                            ? tr('Watch trailer')
                            : tr('Find trailer on YouTube'),
                      ),
                    ),
                  OutlinedButton.icon(
                    key: const ValueKey('media.details.favorite'),
                    focusNode: _favoriteFocusNode,
                    onFocusChange: (value) =>
                        _revealControl(_favoriteFocusNode, value),
                    onPressed: () {
                      setState(() => _favorite = !_favorite);
                      widget.onToggleFavorite();
                    },
                    icon: Icon(
                      _favorite
                          ? Icons.star_rounded
                          : Icons.star_outline_rounded,
                      color: _favorite ? AppColors.accent : null,
                    ),
                    label: Text(
                      _favorite ? tr('In favorites') : tr('Add to favorites'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MediaInformation extends StatelessWidget {
  final MediaInfo info;

  const _MediaInformation({required this.info});

  @override
  Widget build(BuildContext context) {
    final duration = _mediaDurationLabel(info.durationSeconds);
    final rows = <(String, String, String)>[
      if (info.originalTitle case final title?)
        ('originalTitle', tr('Original title'), title),
      if (info.genres.isNotEmpty)
        ('genres', tr('Genres'), info.genres.join(', ')),
      if (info.directors.isNotEmpty)
        ('directors', tr('Director'), info.directors.join(', ')),
      if (info.creators.isNotEmpty)
        ('creators', tr('Creators'), info.creators.join(', ')),
      if (info.countries.isNotEmpty)
        ('countries', tr('Country'), info.countries.join(', ')),
      if (info.releaseDate case final date?)
        ('releaseDate', tr('Release date'), date),
      if (duration != null) ('duration', tr('Duration'), duration),
    ];
    if (rows.isEmpty && info.cast.isEmpty) return const SizedBox.shrink();
    return Padding(
      key: const ValueKey('media.details.information'),
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            tr('More info'),
            style: Theme.of(context).textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
          for (final row in rows)
            _MediaInformationEntry(
              key: ValueKey('media.details.info.${row.$1}'),
              routeKey: 'media.details.info.${row.$1}',
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final label = Text(
                    row.$2,
                    style: const TextStyle(
                      color: AppColors.textLo,
                      fontSize: 13,
                    ),
                  );
                  final value = Text(
                    row.$3,
                    style: const TextStyle(
                      color: AppColors.textHi,
                      fontSize: 15,
                      height: 1.4,
                    ),
                  );
                  if (constraints.maxWidth < 560 ||
                      MediaQuery.textScalerOf(context).scale(15) > 20) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [label, const SizedBox(height: 4), value],
                    );
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(width: 140, child: label),
                      Expanded(child: value),
                    ],
                  );
                },
              ),
            ),
          if (info.cast.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text(
              tr('Cast'),
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            LayoutBuilder(
              builder: (context, constraints) {
                final columns = math.max(
                  1,
                  (constraints.maxWidth / 260).floor(),
                );
                final width =
                    (constraints.maxWidth - (columns - 1) * 10) / columns;
                return Wrap(
                  spacing: 10,
                  runSpacing: 4,
                  children: [
                    for (var index = 0; index < info.cast.length; index++)
                      SizedBox(
                        width: width,
                        child: _MediaInformationEntry(
                          key: ValueKey('media.details.cast.$index'),
                          routeKey: 'media.details.cast.$index',
                          child: Row(
                            children: [
                              _castPhoto(context, info.cast[index]),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      info.cast[index].name,
                                      style: const TextStyle(
                                        color: AppColors.textHi,
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                        height: 1.3,
                                      ),
                                    ),
                                    if (info.cast[index].role
                                        case final role?) ...[
                                      const SizedBox(height: 3),
                                      Text(
                                        role,
                                        style: const TextStyle(
                                          color: AppColors.textLo,
                                          fontSize: 12,
                                          height: 1.3,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ],
        ],
      ),
    );
  }

  Widget _castPhoto(BuildContext context, MediaCastMember member) {
    const fallback = ColoredBox(
      color: AppColors.panelHi,
      child: Center(
        child: Icon(Icons.person_outline_rounded, color: AppColors.textLo),
      ),
    );
    return ExcludeSemantics(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.control),
        child: SizedBox(
          width: 48,
          height: 64,
          child: member.photoUrl == null
              ? fallback
              : CachedNetworkImage(
                  imageUrl: member.photoUrl!,
                  fit: BoxFit.cover,
                  memCacheWidth: imageCacheSize(context, 48),
                  placeholder: (_, _) => fallback,
                  errorWidget: (_, url, error) {
                    logImageFailure(error, url);
                    return fallback;
                  },
                ),
        ),
      ),
    );
  }
}

/// Each information row and actor can be revealed and read with a remote.
class _MediaInformationEntry extends StatefulWidget {
  final String routeKey;
  final Widget child;

  const _MediaInformationEntry({
    super.key,
    required this.routeKey,
    required this.child,
  });

  @override
  State<_MediaInformationEntry> createState() => _MediaInformationEntryState();
}

class _MediaInformationEntryState extends State<_MediaInformationEntry> {
  late final _focusNode = RoutedFocusNode(widget.routeKey);
  bool _focused = false;

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  void _focusChanged(bool focused) {
    setState(() => _focused = focused);
    if (!focused) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_focusNode.hasFocus) return;
      Scrollable.ensureVisible(
        context,
        alignment: 0.5,
        duration: appMotion(context, const Duration(milliseconds: 180)),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: _focusNode,
    onFocusChange: _focusChanged,
    child: Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: _focused ? AppColors.panelHi : Colors.transparent,
        borderRadius: BorderRadius.circular(AppRadius.control),
        border: Border.all(
          color: _focused ? AppColors.accent : Colors.transparent,
          width: 2,
        ),
      ),
      child: widget.child,
    ),
  );
}

class _MetadataAttribution extends StatelessWidget {
  const _MetadataAttribution({required this.item});

  final MediaItem item;

  @override
  Widget build(BuildContext context) {
    final metadata = item.extra['metadata'];
    if (metadata is! Map) return const SizedBox.shrink();
    final tvmaze = metadata['tvmaze'];
    final tvmazeId = tvmaze is Map ? int.tryParse('${tvmaze['id']}') : null;
    return Wrap(
      spacing: 8,
      children: [
        if (tvmaze is Map) ...[
          TextButton(
            onPressed: () => launchUrl(
              Uri.parse(tvmazeId != null && tvmazeId > 0
                  ? 'https://www.tvmaze.com/shows/$tvmazeId'
                  : 'https://www.tvmaze.com'),
              mode: LaunchMode.externalApplication,
            ),
            child: Text(tr('TVmaze metadata (formatting adapted)')),
          ),
          TextButton(
            onPressed: () => launchUrl(
              Uri.parse('https://creativecommons.org/licenses/by-sa/4.0/'),
              mode: LaunchMode.externalApplication,
            ),
            child: const Text('CC BY-SA 4.0'),
          ),
        ],
        if (metadata['tvdb'] is Map)
          TextButton(
            onPressed: () => launchUrl(
              Uri.parse('https://thetvdb.com'),
              mode: LaunchMode.externalApplication,
            ),
            child: Text(tr('Metadata provided by TheTVDB')),
          ),
      ],
    );
  }
}

class _MetadataStatus extends StatelessWidget {
  final Future<ExternalMetadata?> metadata;
  final bool configured;
  final bool refreshing;
  final VoidCallback onRefresh;

  const _MetadataStatus({
    required this.metadata,
    required this.configured,
    required this.refreshing,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ExternalMetadata?>(
      future: metadata,
      builder: (context, snapshot) {
        final value = snapshot.data;
        final loading =
            configured &&
            (refreshing || snapshot.connectionState != ConnectionState.done);
        final label = !configured
            ? tr(
                'Showing IPTV provider details. Add TMDB or TVDB in Settings → Metadata for more information.',
              )
            : loading
            ? tr('Loading metadata…')
            : snapshot.hasError
            ? tr(
                'Could not load additional metadata. Showing IPTV provider details.',
              )
            : value == null
            ? tr('No additional metadata. Showing IPTV provider details.')
            : '${value.provider.toUpperCase()} · ${_ago(value.refreshedAt)}';
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: AppColors.panelHi,
            borderRadius: BorderRadius.circular(AppRadius.control),
            border: Border.all(color: AppColors.line),
          ),
          child: Row(
            children: [
              if (loading)
                const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(
                  snapshot.hasError
                      ? Icons.error_outline
                      : value == null || !configured
                      ? Icons.info_outline
                      : Icons.check_circle_outline,
                  color: value == null || !configured || snapshot.hasError
                      ? AppColors.textLo
                      : AppColors.accent,
                  size: 18,
                ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(color: AppColors.textLo, fontSize: 12),
                ),
              ),
              if (configured)
                IconButton(
                  tooltip: tr('Refresh metadata'),
                  visualDensity: VisualDensity.compact,
                  onPressed: loading ? null : onRefresh,
                  icon: const Icon(Icons.refresh, size: 18),
                ),
            ],
          ),
        );
      },
    );
  }

  String _ago(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) return tr('just now');
    if (diff.inMinutes < 60) {
      return tr('{minutes}m ago', {'minutes': diff.inMinutes});
    }
    if (diff.inHours < 24) return tr('{hours}h ago', {'hours': diff.inHours});
    return tr('{days}d ago', {'days': diff.inDays});
  }
}

/// `S2E5, Episode Title` style concise label for an episode's D-pad focus
/// ring (`FocusableCard.semanticsLabel`) — season/episode number first so a
/// screen reader announces position before the (possibly long) title.
String _episodeSemanticsLabel(MediaItem episode) {
  final sxe = episode.seasonNumber != null && episode.episodeNumber != null
      ? tr('S{season}E{episode}', {
          'season': episode.seasonNumber!,
          'episode': episode.episodeNumber!,
        })
      : null;
  return sxe == null ? episode.title : '$sxe, ${episode.title}';
}

String _episodeNumberLabel(MediaItem episode) =>
    episode.seasonNumber != null && episode.episodeNumber != null
    ? tr('S{season}E{episode}', {
        'season': episode.seasonNumber!,
        'episode': episode.episodeNumber!,
      })
    : episode.title;

String _episodePlaybackLabel(PlaybackPosition position) => position.isFinished
    ? tr('Watched')
    : tr('Resume from {position}', {
        'position': _positionLabel(position.position),
      });

class _SeriesBrowser extends StatefulWidget {
  final LibraryRepository repo;
  final Future<MediaLibrarySnapshot> seasons;
  final Future<MediaLibrarySnapshot> Function(MediaItem season) episodesFor;
  final MediaItem artworkFallback;
  final ValueChanged<MediaItem> onPlayEpisode;
  final ValueChanged<bool> onEpisodesChanged;

  /// Called once, during build, with the first season header's own
  /// (ExpansionTile-internal) [FocusNode] as soon as it exists — so the
  /// details can [FocusNode.requestFocus] it when View episodes is activated,
  /// instead of `FocusScope.nextFocus()`, which lands on the title row's
  /// favorite star (the first focusable stop in the sheet when there's no
  /// top-level Play button). Null when there's nothing to capture yet.
  final ValueChanged<FocusNode>? onFirstSeasonFocusNode;
  final VoidCallback onExitAfterLastSeason;

  const _SeriesBrowser({
    required this.repo,
    required this.seasons,
    required this.episodesFor,
    required this.artworkFallback,
    required this.onPlayEpisode,
    required this.onEpisodesChanged,
    this.onFirstSeasonFocusNode,
    required this.onExitAfterLastSeason,
  });

  @override
  State<_SeriesBrowser> createState() => _SeriesBrowserState();
}

class _SeriesBrowserState extends State<_SeriesBrowser> {
  static const _expansionDuration = Duration(milliseconds: 220);
  final _seasonFocusNodes = <String, FocusNode>{};
  final _pages = <String, MediaLibrarySnapshot>{};
  final _pagingTokens = <String, LoadToken>{};
  final _pagingErrors = <String, Object>{};
  final _pageFocusNodes = <String, FocusNode>{};
  final _episodeRailKeys = <String, GlobalKey<_EpisodeRailState>>{};
  Timer? _expansionReveal;
  String? _seasonToReveal;
  String? _revealingSeason;
  FocusNode? _revealFocus;
  ScrollPosition? _outerPosition;
  bool _expansionFinished = false;

  String _pageKey(MediaItem parent) => '${parent.kind.name}:${parent.id}';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final position = Scrollable.maybeOf(context)?.position;
    if (identical(position, _outerPosition)) return;
    _outerPosition?.removeListener(_outerScrolled);
    _outerPosition = position;
    position?.addListener(_outerScrolled);
  }

  void _outerScrolled() {
    if (_outerPosition?.userScrollDirection != ScrollDirection.idle) {
      _cancelReveal();
    }
  }

  void _cancelReveal({bool stopScroll = false}) {
    _expansionReveal?.cancel();
    _seasonToReveal = null;
    if (stopScroll && _revealingSeason != null) {
      final position = _outerPosition;
      position?.jumpTo(position.pixels);
    }
    _revealingSeason = null;
  }

  @override
  void dispose() {
    _expansionReveal?.cancel();
    _outerPosition?.removeListener(_outerScrolled);
    for (final token in _pagingTokens.values) {
      token.cancel();
    }
    for (final node in _pageFocusNodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  void _seasonExpanded(MediaItem season, bool expanded) {
    final key = _pageKey(season);
    setState(() {
      for (final active in _pagingTokens.keys.toList()) {
        if (active.startsWith('${ContentKind.season.name}:') &&
            (expanded ? active != key : active == key)) {
          _pagingTokens.remove(active)?.cancel();
        }
      }
    });
    if (!expanded &&
        _seasonToReveal != season.id &&
        _revealingSeason != season.id) {
      return;
    }
    _cancelReveal(stopScroll: true);
    _seasonToReveal = expanded ? season.id : null;
    _expansionFinished = false;
    if (!expanded) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _seasonToReveal == season.id) {
        _revealFocus = FocusManager.instance.primaryFocus;
      }
    });
    // Use the tile's own duration: its children must finish expanding before
    // the outer scroll can reveal their full height, including cached loads.
    _expansionReveal = Timer(appMotion(context, _expansionDuration), () {
      _expansionFinished = true;
      _revealExpandedSeason(season.id);
    });
  }

  void _revealExpandedSeason(String id) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !_expansionFinished ||
          _seasonToReveal != id ||
          _episodeRailKeys[id]?.currentContext == null ||
          ModalRoute.of(context)?.isCurrent == false) {
        return;
      }
      if (_revealFocus != FocusManager.instance.primaryFocus) {
        _cancelReveal();
        return;
      }
      final target = _seasonFocusNodes[id]?.context;
      if (target == null) return;
      _seasonToReveal = null;
      _revealingSeason = id;
      unawaited(
        Scrollable.ensureVisible(
          target,
          alignment: 0,
          duration: appMotion(context, const Duration(milliseconds: 280)),
          curve: Curves.easeOutCubic,
        ).whenComplete(() {
          if (mounted && _revealingSeason == id) _revealingSeason = null;
        }),
      );
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _loadMore(
    MediaLibrarySnapshot snapshot,
    MediaItem parent,
  ) async {
    final key = _pageKey(parent);
    if (_pagingTokens.containsKey(key)) return;
    final token = LoadToken();
    setState(() {
      _pagingTokens[key] = token;
      _pagingErrors.remove(key);
    });
    try {
      widget.repo.loadToken = token;
      final loaded = await widget.repo.loadMoreMediaFromSnapshot(
        snapshot,
        parent: parent,
      );
      if (!mounted || !identical(_pagingTokens[key], token)) return;
      setState(() {
        _pages[key] = loaded;
        _pagingTokens.remove(key);
      });
      if (parent.kind == ContentKind.series) widget.onEpisodesChanged(false);
      if (!loaded.hasMore && _pageFocusNodes[key]?.hasFocus == true) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (parent.kind == ContentKind.series) {
            if (loaded.items.isNotEmpty) {
              _focusSeason(loaded.items.last.id);
            } else {
              widget.onExitAfterLastSeason();
            }
          } else {
            _focusSeason(parent.id);
          }
        });
      }
    } catch (error) {
      if (!mounted || !identical(_pagingTokens[key], token)) return;
      setState(() {
        _pagingErrors[key] = error;
        _pagingTokens.remove(key);
      });
    }
  }

  void _focusPage(MediaItem parent) {
    final node = _pageFocusNodes[_pageKey(parent)];
    if (node == null || node.context == null) return;
    node.requestFocus();
    Scrollable.ensureVisible(
      node.context!,
      alignment: 0.5,
      duration: appMotion(context, const Duration(milliseconds: 180)),
      curve: Curves.easeOutCubic,
    );
  }

  Widget _pageControl(
    MediaLibrarySnapshot snapshot,
    MediaItem parent, {
    required VoidCallback onUp,
    required VoidCallback onDown,
  }) {
    final key = _pageKey(parent);
    final loading = _pagingTokens.containsKey(key);
    final error = _pagingErrors[key];
    return Column(
      children: [
        if (error != null)
          Text(
            tr(
              parent.kind == ContentKind.series
                  ? 'Could not load seasons: {error}'
                  : 'Could not load episodes: {error}',
              {'error': error},
            ),
            style: const TextStyle(color: AppColors.textLo),
          ),
        Focus(
          onKeyEvent: (_, event) {
            if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
              return KeyEventResult.ignored;
            }
            if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
              onUp();
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
              onDown();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: FilledButton.icon(
            key: ValueKey('media.$key.loadMore'),
            focusNode: _pageFocusNodes.putIfAbsent(
              key,
              () => RoutedFocusNode('media.$key.loadMore'),
            ),
            onPressed: () => _loadMore(snapshot, parent),
            icon: loading
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.expand_more_rounded),
            label: Text(
              loading
                  ? tr('Loading')
                  : tr('Load page {page}', {'page': snapshot.loadedPages + 1}),
            ),
          ),
        ),
      ],
    );
  }

  void _focusSeason(String id) {
    if (!mounted) return;
    final node = _seasonFocusNodes[id];
    final target = node?.context;
    if (node == null || target == null || !node.canRequestFocus) return;
    node.requestFocus();
    Scrollable.ensureVisible(
      target,
      alignment: 0.5,
      duration: appMotion(context, const Duration(milliseconds: 180)),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<MediaLibrarySnapshot>(
      future: widget.seasons,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: CircularProgressIndicator(),
            ),
          );
        }
        if (snapshot.hasError) {
          return Text(
            tr('Could not load seasons: {error}', {'error': snapshot.error!}),
            style: const TextStyle(color: AppColors.textLo),
          );
        }
        final seasonSnapshot =
            _pages[_pageKey(widget.artworkFallback)] ?? snapshot.data!;
        final seasons = seasonSnapshot.items;
        if (seasons.isEmpty) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tr('Seasons: {count}', {'count': 0})),
              Text(
                tr('No seasons found'),
                style: const TextStyle(color: AppColors.textLo),
              ),
              if (seasonSnapshot.hasMore)
                _pageControl(
                  seasonSnapshot,
                  widget.artworkFallback,
                  onUp: widget.onExitAfterLastSeason,
                  onDown: widget.onExitAfterLastSeason,
                ),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              tr('Seasons: {count}', {'count': seasons.length}),
              style: const TextStyle(color: AppColors.textLo, fontSize: 12),
            ),
            const SizedBox(height: 4),
            for (var i = 0; i < seasons.length; i++)
              ExpansionTile(
                key: ValueKey('media.season.${seasons[i].id}'),
                expansionAnimationStyle: AnimationStyle(
                  duration: appMotion(context, _expansionDuration),
                  curve: Curves.easeOutCubic,
                ),
                onExpansionChanged: (expanded) =>
                    _seasonExpanded(seasons[i], expanded),
                tilePadding: EdgeInsets.zero,
                dense: true,
                visualDensity: VisualDensity.compact,
                childrenPadding: const EdgeInsets.only(bottom: 8),
                // Capture each header's real ExpansionTile focus target for
                // long-list edge navigation. View episodes also uses the first
                // one instead of traversing through the sheet's action buttons.
                title: Builder(
                  builder: (context) {
                    final node = Focus.of(context, createDependency: false);
                    _seasonFocusNodes[seasons[i].id] = node;
                    if (i == 0) widget.onFirstSeasonFocusNode?.call(node);
                    return Text(seasons[i].title);
                  },
                ),
                subtitle:
                    seasons[i].seasonNumber == null ||
                        seasons[i].title.trim().toLowerCase() ==
                            'season ${seasons[i].seasonNumber}'.toLowerCase()
                    ? null
                    : Text(
                        tr('Season {number}', {
                          'number': seasons[i].seasonNumber!,
                        }),
                        style: const TextStyle(color: AppColors.textLo),
                      ),
                children: [
                  // The future is created inside a `Builder` so it only fires
                  // when this season's subtree is actually mounted. A closed
                  // `ExpansionTile` drops its children (there is no
                  // `maintainState` here), but the `children:` *list* is still
                  // constructed on every build of the browser — so calling
                  // `episodesFor` directly at this point fired one provider
                  // catalog request per season the instant the sheet opened,
                  // which on a long-running series meant a dozen-plus
                  // concurrent requests nobody asked for.
                  Builder(
                    builder: (context) => FutureBuilder<MediaLibrarySnapshot>(
                      future: widget.episodesFor(seasons[i]),
                      builder: (context, episodeSnapshot) {
                        if (episodeSnapshot.connectionState !=
                            ConnectionState.done) {
                          return const Padding(
                            padding: EdgeInsets.all(12),
                            child: LinearProgressIndicator(minHeight: 2),
                          );
                        }
                        if (episodeSnapshot.hasError) {
                          return Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              tr('Could not load episodes: {error}', {
                                'error': episodeSnapshot.error!,
                              }),
                              style: const TextStyle(color: AppColors.textLo),
                            ),
                          );
                        }
                        final page =
                            _pages[_pageKey(seasons[i])] ??
                            episodeSnapshot.data!;
                        final episodes = page.items;
                        void exitDown() {
                          if (!mounted) return;
                          if (i + 1 < seasons.length) {
                            _focusSeason(seasons[i + 1].id);
                          } else if (seasonSnapshot.hasMore) {
                            _focusPage(widget.artworkFallback);
                          } else {
                            widget.onExitAfterLastSeason();
                          }
                        }

                        if (episodes.isEmpty) {
                          return Align(
                            alignment: Alignment.centerLeft,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(tr('Episodes: {count}', {'count': 0})),
                                Text(
                                  tr('No episodes found'),
                                  style: const TextStyle(
                                    color: AppColors.textLo,
                                  ),
                                ),
                                if (page.hasMore)
                                  _pageControl(
                                    page,
                                    seasons[i],
                                    onUp: () => _focusSeason(seasons[i].id),
                                    onDown: exitDown,
                                  ),
                              ],
                            ),
                          );
                        }
                        return Column(
                          children: [
                            _EpisodeRail(
                              key: _episodeRailKeys.putIfAbsent(
                                seasons[i].id,
                                () => GlobalKey<_EpisodeRailState>(),
                              ),
                              seasonId: seasons[i].id,
                              repo: widget.repo,
                              episodes: episodes,
                              artworkFallback: widget.artworkFallback,
                              onPlayEpisode: widget.onPlayEpisode,
                              onPlaybackLoaded: widget.onEpisodesChanged,
                              onReady: () =>
                                  _revealExpandedSeason(seasons[i].id),
                              onExitUp: () => _focusSeason(seasons[i].id),
                              onExitDown: () {
                                if (page.hasMore) {
                                  _focusPage(seasons[i]);
                                } else {
                                  exitDown();
                                }
                              },
                            ),
                            if (page.hasMore)
                              _pageControl(
                                page,
                                seasons[i],
                                onUp: () => _episodeRailKeys[seasons[i].id]
                                    ?.currentState
                                    ?._focusNode
                                    .requestFocus(),
                                onDown: exitDown,
                              ),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ),
            if (seasonSnapshot.hasMore)
              _pageControl(
                seasonSnapshot,
                widget.artworkFallback,
                onUp: () => _focusSeason(seasons.last.id),
                onDown: widget.onExitAfterLastSeason,
              ),
          ],
        );
      },
    );
  }
}

class _EpisodeCardContent extends StatelessWidget {
  final MediaItem episode;
  final MediaItem artworkFallback;
  final double imageWidth;
  final PlaybackPosition? playback;

  const _EpisodeCardContent({
    required this.episode,
    required this.artworkFallback,
    required this.imageWidth,
    this.playback,
  });

  @override
  Widget build(BuildContext context) {
    final hasArtwork =
        episode.poster?.isNotEmpty == true ||
        episode.backdrop?.isNotEmpty == true;
    final duration = episode.durationSeconds;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Stack(
          children: [
            _Thumb(
              item: hasArtwork ? episode : artworkFallback,
              width: imageWidth,
              height: imageWidth * 9 / 16,
              preferPoster: hasArtwork,
            ),
            Positioned(
              left: 10,
              bottom: 10,
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: const BoxDecoration(
                  color: Colors.black54,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.play_arrow_rounded, size: 26),
              ),
            ),
            if (duration != null && duration > 0)
              Positioned(
                right: 8,
                bottom: 10,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black87,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    _positionLabel(Duration(seconds: duration)),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
            if (playback case final position?)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: LinearProgressIndicator(
                  value: position.isFinished ? 1 : position.progress,
                  minHeight: 4,
                  color: AppColors.accent,
                  backgroundColor: Colors.black54,
                ),
              ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                episode.episodeNumber == null
                    ? episode.title
                    : '${episode.episodeNumber}. ${episode.title}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyLarge
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              if (playback case final position?) ...[
                const SizedBox(height: 6),
                Text(
                  _episodePlaybackLabel(position),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: AppColors.accent, fontSize: 12),
                ),
              ],
              if (episode.description?.isNotEmpty == true) ...[
                const SizedBox(height: 6),
                Text(
                  episode.description!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: AppColors.textLo, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// Each season has a lazy horizontal rail. The cursor's focus node
/// stays mounted while cards enter/leave the viewport and while a player route
/// covers the details, so D-pad navigation never depends on an off-screen row.
class _EpisodeRail extends StatefulWidget {
  final String seasonId;
  final LibraryRepository repo;
  final List<MediaItem> episodes;
  final MediaItem artworkFallback;
  final ValueChanged<MediaItem> onPlayEpisode;
  final ValueChanged<bool> onPlaybackLoaded;
  final VoidCallback onExitUp;
  final VoidCallback onExitDown;
  final VoidCallback onReady;

  const _EpisodeRail({
    super.key,
    required this.seasonId,
    required this.repo,
    required this.episodes,
    required this.artworkFallback,
    required this.onPlayEpisode,
    required this.onPlaybackLoaded,
    required this.onExitUp,
    required this.onExitDown,
    required this.onReady,
  });

  @override
  State<_EpisodeRail> createState() => _EpisodeRailState();
}

class _EpisodeRailState extends State<_EpisodeRail> {
  final _scrollController = ScrollController(keepScrollOffset: false);
  late final _focusNode = RoutedFocusNode(
    'media.episode.list.${widget.seasonId}',
  );
  int _selectedIndex = 0;
  static const _spacing = 12.0;
  double _itemExtent = 0;
  double _textHeight = 0;
  bool _coveredByRoute = false;
  Map<String, PlaybackPosition> _playback = const {};
  StreamSubscription<void>? _playbackChanged;
  StreamSubscription<void>? _playbackReplaced;
  int _playbackLoad = 0;

  @override
  void initState() {
    super.initState();
    _playbackChanged = widget.repo.db.playbackPositionsChanged.listen(
      (_) => _loadPlayback(),
    );
    _playbackReplaced = widget.repo.db.playbackPositionsReplaced.listen(
      (_) => _loadPlayback(),
    );
    unawaited(_loadPlayback());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onReady();
    });
  }

  Future<void> _loadPlayback() async {
    final load = ++_playbackLoad;
    try {
      final positions = await widget.repo.db.readEpisodePlaybackPositions(
        widget.repo.source.id,
        widget.episodes.map((episode) => episode.id).toList(),
      );
      if (!mounted || load != _playbackLoad) return;
      setState(() => _playback = positions);
      widget.onPlaybackLoaded(positions.isNotEmpty);
    } catch (_) {
      // A failed history read must not prevent browsing or playing episodes.
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final inherited = DefaultTextStyle.of(context).style;
    final scaler = MediaQuery.textScalerOf(context);
    double lineHeight(TextStyle style) {
      final painter = TextPainter(
        text: TextSpan(text: 'Ag', style: inherited.merge(style)),
        textDirection: Directionality.of(context),
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final height = painter.height;
      painter.dispose();
      return height;
    }

    final titleHeight = lineHeight(
      Theme.of(context).textTheme.bodyLarge ?? const TextStyle(fontSize: 16),
    );
    final descriptionHeight = lineHeight(const TextStyle(fontSize: 12));
    // Reserve two title and description lines even when the text is shorter.
    _textHeight =
        kFocusableCardVerticalPadding * 2 +
        kFocusableCardBorderWidth * 2 +
        24 +
        titleHeight * 2 +
        descriptionHeight * 3 +
        6;
  }

  @override
  void didUpdateWidget(_EpisodeRail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.episodes, widget.episodes)) {
      unawaited(_loadPlayback());
      _selectedIndex = _selectedIndex.clamp(0, widget.episodes.length - 1);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _revealSelected(animate: false);
      });
    }
  }

  @override
  void dispose() {
    unawaited(_playbackChanged?.cancel());
    unawaited(_playbackReplaced?.cancel());
    _focusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _revealSelected({required bool animate}) {
    if (!mounted || !_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (!position.hasContentDimensions || !position.hasViewportDimension) {
      return;
    }
    final start = _selectedIndex * _itemExtent;
    final end = start + _itemExtent - _spacing;
    var target = position.pixels;
    if (start < target) {
      target = start;
    } else if (end > target + position.viewportDimension) {
      target = end - position.viewportDimension;
    }
    target = target.clamp(position.minScrollExtent, position.maxScrollExtent);
    if (target == position.pixels) return;
    final duration = appMotion(context, const Duration(milliseconds: 120));
    if (!animate || duration == Duration.zero) {
      _scrollController.jumpTo(target);
    } else {
      _scrollController.animateTo(
        target,
        duration: duration,
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _focusChanged(bool focused) {
    if (!mounted) return;
    setState(() {});
    if (!focused) {
      _coveredByRoute = ModalRoute.of(context)?.isCurrent == false;
      return;
    }
    if (_coveredByRoute) {
      _coveredByRoute = false;
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_focusNode.hasFocus) return;
      _revealSelected(animate: false);
      // This context is outside the inner ListView. Reveal its finite region
      // in the details' outer scroll before navigating within the season. A
      // player route returning focus must not recenter an already visible list.
      final object = context.findRenderObject();
      final viewport = object == null
          ? null
          : RenderAbstractViewport.maybeOf(object);
      final scrollable = Scrollable.maybeOf(context);
      if (object == null || viewport == null || scrollable == null) return;
      final leading = viewport.getOffsetToReveal(object, 0).offset;
      final trailing = viewport.getOffsetToReveal(object, 1).offset;
      final offset = scrollable.position.pixels;
      if (offset >= trailing - 0.5 && offset <= leading + 0.5) return;
      Scrollable.ensureVisible(
        context,
        alignmentPolicy: offset < trailing
            ? ScrollPositionAlignmentPolicy.keepVisibleAtEnd
            : ScrollPositionAlignmentPolicy.keepVisibleAtStart,
        duration: appMotion(context, const Duration(milliseconds: 180)),
        curve: Curves.easeOutCubic,
      );
    });
  }

  void _activate(int index) {
    if (!mounted) return;
    setState(() => _selectedIndex = index);
    _focusNode.requestFocus();
    // Pointer activation must record the season's focus before playback
    // pushes a new route, just as an OK press already focused on the list does.
    FocusManager.instance.applyFocusChangesIfNeeded();
    widget.onPlayEpisode(widget.episodes[index]);
  }

  void _move(int delta, {bool animate = true}) {
    setState(() {
      _selectedIndex = (_selectedIndex + delta).clamp(
        0,
        widget.episodes.length - 1,
      );
    });
    _focusNode.requestFocus();
    _revealSelected(animate: animate);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight) {
      _move(
        key == LogicalKeyboardKey.arrowRight ? 1 : -1,
        animate: event is! KeyRepeatEvent,
      );
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      widget.onExitUp();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      widget.onExitDown();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.gameButtonA) {
      if (event is KeyDownEvent) _activate(_selectedIndex);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: _focusNode,
    onFocusChange: _focusChanged,
    onKeyEvent: _onKey,
    child: LayoutBuilder(
      builder: (context, constraints) {
        final cardWidth = math.min(
          constraints.maxWidth,
          (constraints.maxWidth * 0.72).clamp(180.0, 240.0),
        );
        final imageWidth = cardWidth - kFocusableCardBorderWidth * 2;
        final extent = cardWidth + _spacing;
        if (_itemExtent != extent) {
          _itemExtent = extent;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _revealSelected(animate: false);
          });
        }
        return Column(
          children: [
            Focus(
              descendantsAreFocusable: false,
              canRequestFocus: false,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      tr('Episodes: {count}', {
                        'count': widget.episodes.length,
                      }),
                      style: const TextStyle(
                        color: AppColors.textLo,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  Text(
                    '${_selectedIndex + 1} / ${widget.episodes.length}',
                    style: const TextStyle(
                      color: AppColors.textLo,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    key: ValueKey('media.episodes.${widget.seasonId}.previous'),
                    tooltip: tr('Previous episode'),
                    onPressed: _selectedIndex > 0 ? () => _move(-1) : null,
                    icon: const Icon(Icons.chevron_left_rounded),
                  ),
                  IconButton(
                    key: ValueKey('media.episodes.${widget.seasonId}.next'),
                    tooltip: tr('Next episode'),
                    onPressed: _selectedIndex < widget.episodes.length - 1
                        ? () => _move(1)
                        : null,
                    icon: const Icon(Icons.chevron_right_rounded),
                  ),
                ],
              ),
            ),
            SizedBox(
              height: imageWidth * 9 / 16 + _textHeight,
              child: ListView.builder(
                key: ValueKey('media.episodes.${widget.seasonId}.list'),
                controller: _scrollController,
                primary: false,
                scrollDirection: Axis.horizontal,
                itemExtent: _itemExtent,
                scrollCacheExtent: ScrollCacheExtent.pixels(_itemExtent * 2),
                itemCount: widget.episodes.length,
                itemBuilder: (context, index) {
                  final episode = widget.episodes[index];
                  final playback = _playback[episode.id];
                  final selected = index == _selectedIndex;
                  final highlighted = selected && _focusNode.hasFocus;
                  return Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: kFocusableCardVerticalPadding,
                    ).copyWith(right: _spacing),
                    child: Semantics(
                      button: true,
                      selected: selected,
                      label: [
                        _episodeSemanticsLabel(episode),
                        if (playback != null) _episodePlaybackLabel(playback),
                      ].join(', '),
                      onTap: () => _activate(index),
                      child: ExcludeSemantics(
                        child: Container(
                          padding: const EdgeInsets.all(
                            kFocusableCardBorderWidth,
                          ),
                          decoration: BoxDecoration(
                            color: highlighted
                                ? Color.alphaBlend(
                                    AppColors.accent.withValues(alpha: 0.22),
                                    AppColors.panel,
                                  )
                                : AppColors.panel,
                            borderRadius: BorderRadius.circular(
                              AppRadius.control,
                            ),
                          ),
                          foregroundDecoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(
                              AppRadius.control,
                            ),
                            border: Border.all(
                              color: highlighted
                                  ? AppColors.accent
                                  : AppColors.line,
                              width: highlighted ? 2 : 1,
                            ),
                          ),
                          child: Material(
                            type: MaterialType.transparency,
                            child: InkWell(
                              canRequestFocus: false,
                              borderRadius: BorderRadius.circular(
                                AppRadius.control,
                              ),
                              onTap: () => _activate(index),
                              child: _EpisodeCardContent(
                                episode: episode,
                                artworkFallback: widget.artworkFallback,
                                imageWidth: imageWidth,
                                playback: playback,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    ),
  );
}
