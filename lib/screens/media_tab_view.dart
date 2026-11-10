import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/library_repository.dart';
import '../data/media_trailer.dart';
import '../data/source_hint_parser.dart';
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
  static const double tilePadding = 10;

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
  static const double posterTextGap = 8;

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
  /// breakpoint note and docs/tv-navigation.md.
  factory MediaGridMetrics.forSize(Size viewport) {
    final targetWidth = math.min(
      kMediaPosterTargetWidth,
      (viewport.height * 0.28).clamp(120.0, kMediaPosterTargetWidth),
    );
    final columns = (viewport.width / targetWidth).round().clamp(3, 16);
    // A dense viewport (TV render targets at 960x540, phones, small windows)
    // gets tighter gutters so the extra pixels go to the artwork. This is the
    // only thing left of the old `compact` platform fork.
    final dense = viewport.shortestSide < 1000;
    return MediaGridMetrics._(
      columns: columns,
      spacing: dense ? 8 : 12,
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

/// The movies/series browsing body: the grid/list of [MediaItem]s with paging,
/// error/empty states, and D-pad focus. Extracted from `ChannelListScreen`'s
/// State as a widget with an explicit input contract so it rebuilds
/// independently of the rest of the (large) screen and so the media state can
/// later move behind a controller without touching this view. Live TV keeps its
/// own body; this handles [ContentKind.movie]/[ContentKind.series] only.
class MediaTabView extends StatelessWidget {
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

  final bool Function(String id) isFavorite;
  final ValueChanged<MediaItem> onOpenMedia;
  final VoidCallback onLoadMore;
  final VoidCallback onRetry;

  /// In-progress items (saved playback positions) shown as a horizontal
  /// "Continue watching" rail above the grid; [onResume] plays one, resuming.
  /// [onRemoveContinueWatching] drops one entry (clears its saved position).
  final List<ContinueWatchingEntry> continueWatching;
  final ValueChanged<MediaItem> onResume;
  final ValueChanged<ContinueWatchingEntry> onRemoveContinueWatching;

  /// Puts back an entry [onRemoveContinueWatching] just dropped — the Undo
  /// action of the confirmation snackbar. **Optional on purpose:** when it is
  /// null the snackbar still reports the removal, just without an Undo, so the
  /// view stays usable before the callback is wired up by the owning screen
  /// (`MediaTabController.restoreContinueWatching`).
  final ValueChanged<ContinueWatchingEntry>? onRestoreContinueWatching;

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
    required this.isFavorite,
    required this.onOpenMedia,
    required this.onLoadMore,
    required this.onRetry,
    this.continueWatching = const [],
    required this.onResume,
    required this.onRemoveContinueWatching,
    this.onRestoreContinueWatching,
  });

  /// Removes an entry and offers an Undo. The removal itself is destructive
  /// (it deletes the saved resume position), the control sits directly under a
  /// tile whose tap starts playback, and the entry object is already in hand —
  /// so re-writing the position costs nothing and the confirmation is worth
  /// the snackbar.
  void _removeContinueWatching(
    BuildContext context,
    ContinueWatchingEntry entry,
  ) {
    onRemoveContinueWatching(entry);
    final restore = onRestoreContinueWatching;
    const visible = Duration(seconds: 6);
    final messenger = ScaffoldMessenger.of(context)..hideCurrentSnackBar();
    final shown = messenger.showSnackBar(
      SnackBar(
        content: Text(
          tr('Removed “{title}” from Continue watching', {
            'title': entry.item.title,
          }),
        ),
        duration: visible,
        action: restore == null
            ? null
            : SnackBarAction(
                label: tr('Undo'),
                onPressed: () => restore(entry),
              ),
      ),
    );
    // **Close it ourselves rather than trusting `duration`.**
    // `ScaffoldMessengerState` only arms the auto-dismiss timer inside its
    // own `build`, and only while `ModalRoute.of(context)!.isCurrent` — so a
    // snackbar shown just before a route push (tap Remove, then open a
    // channel) can miss its one chance to schedule and then never leave. It
    // was seen sitting over fullscreen live TV for minutes, still offering to
    // undo something no longer on screen. `close()` is idempotent: if the
    // framework's timer did fire, this is a no-op on an already-gone bar.
    Timer(visible + const Duration(milliseconds: 250), shown.close);
  }

  @override
  Widget build(BuildContext context) {
    // The rail rides in the *same* scroll view as the grid/list below (as a
    // leading sliver) rather than sitting above it in a fixed-height Column.
    // A fixed height there could exceed the whole available viewport on a
    // short screen (phone landscape, mainly) — Column+Expanded overflows in
    // that case, which broke the rail's own horizontal drag along with it.
    // As a sliver it just contributes to the (already scrollable) content
    // and never forces an overflow.
    final showRail = !showingSearch && continueWatching.isNotEmpty;
    final railSliver = showRail
        ? SliverToBoxAdapter(
            child: _ContinueWatchingRail(
              entries: continueWatching,
              onResume: onResume,
              onRemove: (entry) => _removeContinueWatching(context, entry),
              onFocusTabs: onFocusTabs,
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
        final showFeatured = discovery;
        final categorySliver = showCategories
            ? SliverList.builder(
                itemCount: categories.length,
                itemBuilder: (context, i) => _MediaCategoryRail(
                  key: ValueKey(categories[i].id),
                  category: categories[i],
                  load: loadCategory!,
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
        // Initial focus belongs to the feature, otherwise a poster's
        // ensureVisible immediately scrolls this new discovery area away.
        // Returning from playback keeps the existing per-item focus contract.
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
              ?railSliver,
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
        final grid = MediaGridMetrics.forSize(windowSize);
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
  final bool Function(String) isFavorite;
  final ValueChanged<MediaItem> onOpen;
  final VoidCallback onExpand;
  final VoidCallback? onFocusTabs;

  const _MediaCategoryRail({
    super.key,
    required this.category,
    required this.load,
    required this.isFavorite,
    required this.onOpen,
    required this.onExpand,
    this.onFocusTabs,
  });

  @override
  State<_MediaCategoryRail> createState() => _MediaCategoryRailState();
}

class _MediaCategoryRailState extends State<_MediaCategoryRail> {
  late Future<List<MediaItem>> _items;

  @override
  void initState() {
    super.initState();
    _items = widget.load(widget.category);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<MediaItem>>(
      future: _items,
      builder: (context, snapshot) {
        final items = snapshot.data?.take(14).toList() ?? const <MediaItem>[];
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
          status = Padding(
            padding: EdgeInsets.all(18),
            child: Text(
              widget.category.kind == ContentKind.movie
                  ? tr('No movies in this category')
                  : tr('No series in this category'),
              style: TextStyle(color: AppColors.textLo),
            ),
          );
        }
        return _MediaPosterRail(
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
  });

  @override
  State<_MediaPosterRail> createState() => _MediaPosterRailState();
}

class _MediaPosterRailState extends State<_MediaPosterRail> {
  ScrollController? _scrollController;
  double _itemStride = 0;

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

  void _reveal(BuildContext tileContext, bool focused) {
    if (!focused) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !tileContext.mounted || !Focus.of(tileContext).hasFocus) {
        return;
      }
      final tile = tileContext.findRenderObject();
      final shelf = context.findRenderObject();
      final duration = appMotion(context, const Duration(milliseconds: 180));
      if (tile != null) {
        Scrollable.maybeOf(
          tileContext,
          axis: Axis.horizontal,
        )?.position.ensureVisible(tile, alignment: 0.5, duration: duration);
      }
      if (shelf != null) {
        final position = Scrollable.maybeOf(
          context,
          axis: Axis.vertical,
        )?.position;
        if (position != null) {
          // At large accessibility scales a shelf can exceed the viewport;
          // reveal the card in that case instead of keeping its heading pinned.
          position.ensureVisible(
            shelf,
            targetRenderObject: shelf.paintBounds.height > position.viewportDimension
                ? tile
                : null,
            alignment: 0,
            duration: duration,
          );
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final grid = MediaGridMetrics.forSize(MediaQuery.sizeOf(context));
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
              ? 18.0
              : compact
              ? 22.0
              : 32.0;
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
                        ? 230
                        : compact
                        ? 280
                        : 330,
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
                                  ? 28
                                  : compact
                                  ? 30
                                  : 42,
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

/// Horizontal "Continue watching" strip: poster tiles with a progress bar,
/// newest first. One `FocusTraversalGroup` so the D-pad walks the rail as a
/// row between the toolbar and the grid. Sized noticeably larger than the
/// other rails so the title and remaining-time text stay legible on phones.
class _ContinueWatchingRail extends StatelessWidget {
  final List<ContinueWatchingEntry> entries;
  final ValueChanged<MediaItem> onResume;
  final ValueChanged<ContinueWatchingEntry> onRemove;
  final VoidCallback? onFocusTabs;

  const _ContinueWatchingRail({
    required this.entries,
    required this.onResume,
    required this.onRemove,
    this.onFocusTabs,
  });

  @override
  Widget build(BuildContext context) {
    return FocusTraversalGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _MediaSectionHeading(title: tr('Continue watching')),
          SizedBox(
            // Only tall enough for the tile's own content (16:9 thumbnail +
            // title + subtitle + the Remove row below the card) — not sized
            // against the screen, so it can never itself overflow a short
            // viewport (phone landscape). It scrolls away with the rest of
            // the tab content.
            //
            // Derived from the text scale rather than hard-coded: the three
            // text runs grow ~13 px at Android's "Large" (1.3x) and more at the
            // accessibility sizes above it, which a fixed 224 could not absorb.
            height: _ContinueWatchingTile.height(context),
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: entries.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (context, i) => Focus(
                canRequestFocus: false,
                skipTraversal: true,
                onKeyEvent: (_, event) =>
                    _focusTabsOnLeft(event, i == 0 ? onFocusTabs : null),
                child: _ContinueWatchingTile(
                  entry: entries[i],
                  onTap: () => onResume(entries[i].item),
                  onRemove: () => onRemove(entries[i]),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ContinueWatchingTile extends StatelessWidget {
  // 16:9 — these thumbnails are usually a video-frame screenshot or a
  // backdrop still, both landscape; cropping them into a portrait poster
  // box (the old design) zoomed in hard and made compression noise obvious.
  static const double _width = 224.0;
  static const double _thumbHeight = 126.0;

  static const double _titleFontSize = 13.0;
  static const double _titleHeight = 1.2;
  static const double _subtitleFontSize = 11.0;

  /// Natural height of one rail tile: the thumbnail, the two text runs, and
  /// the Remove row below the card, at the current text scale. The rail's
  /// `ListView` hands its children a *tight* cross-axis extent, so this is what
  /// the tile has to live inside.
  ///
  /// **It is a hint, not a guarantee** — [build] lays the tile out unconstrained
  /// inside a `ClipRect`, so being wrong here costs at most a sub-pixel trim off
  /// the bottom of the Remove row's (transparent) tap padding. It used to be
  /// load-bearing, and it was wrong: this rail was the source of the persistent
  /// `BOTTOM OVERFLOWED BY 1.6 PIXELS` on a windowed desktop layout, not the
  /// poster grid it sits above.
  ///
  /// Two corrections came out of measuring the real font (see
  /// `test/layout_overflow_test.dart`, which loads Inter rather than the
  /// widget-test font): the engine **rounds each laid-out line up to a whole
  /// logical pixel**, so a predicted run has to be ceiled; and Inter's real
  /// line-height ratio for a run with no explicit `TextStyle.height` is ~1.41,
  /// not the 1.35 assumed here. The border term is the **focused** width
  /// ([FocusableCard] draws 2 px a side when focused, 1 at rest) because unlike
  /// the poster grid nothing in this tile is flexible enough to absorb it.
  static double height(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final title = (scaler.scale(_titleFontSize) * _titleHeight).ceilToDouble();
    final subtitle = (scaler.scale(_subtitleFontSize) * 1.45).ceilToDouble();
    return _thumbHeight +
        6 + // thumbnail → title
        title +
        2 + // title → subtitle
        subtitle +
        10 + // breathing room above the card's bottom border
        kFocusableCardVerticalPadding * 2 +
        2 * 2 + // focused card border, both sides
        4 + // card → Remove row
        _RemoveButton.height(context);
  }

  final ContinueWatchingEntry entry;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  const _ContinueWatchingTile({
    required this.entry,
    required this.onTap,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final item = entry.item;
    final subtitle = _continueWatchingSubtitle(entry);
    // The series name for an episode, the item's own title otherwise. The
    // episode name is not lost — it moves into the semantics label below,
    // because the tile has exactly two single-line text runs and its rail
    // height is derived from that (see [height]); a third line would have to be
    // paid for by every tile including the movie tab's.
    final title = entry.displayTitle;
    return SizedBox(
      width: _width,
      // **Laid out unconstrained, then clipped.** The rail's `ListView` hands
      // this tile a *tight* height derived from [height] — a prediction built
      // from font metrics, which is exactly the kind of thing that is quietly
      // 1–2 px short on a real font. Giving the `Column` an unbounded main axis
      // makes the tile structurally incapable of reporting an overflow, and the
      // `ClipRect` turns any residual into a trim off the bottom of the Remove
      // row's transparent tap padding rather than a striped bar under every
      // card in the rail. `topLeft` keeps the thumbnail pinned to the top, which
      // is where the alignment matters.
      child: ClipRect(
        child: OverflowBox(
          alignment: Alignment.topLeft,
          minHeight: 0,
          maxHeight: double.infinity,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FocusableCard(
                onTap: onTap,
                debugLabel: 'media.continue.${item.id}',
                // Spells out what the two visible runs compress: the series,
                // then the episode by name, then position and time left. This
                // is where the episode title stays readable once the visible
                // title leads with the series.
                semanticsLabel: _continueWatchingSemantics(entry),
                child: SizedBox(
                  width: _width,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: SizedBox(
                          width: _width,
                          height: _thumbHeight,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              _Thumb(
                                item: item,
                                width: _width,
                                height: _thumbHeight,
                              ),
                              // Resume affordance — makes it obvious at a glance
                              // that these tiles play mid-way through, not from
                              // the start.
                              Center(
                                child: Container(
                                  width: 36,
                                  height: 36,
                                  decoration: BoxDecoration(
                                    color: Colors.black.withValues(alpha: 0.45),
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(
                                    Icons.play_arrow_rounded,
                                    color: Colors.white,
                                    size: 22,
                                  ),
                                ),
                              ),
                              // Progress bar overlaid on the thumbnail (with a
                              // scrim behind it for contrast on bright artwork)
                              // rather than a separate row, so the freed-up
                              // space goes to the title.
                              Positioned(
                                left: 0,
                                right: 0,
                                bottom: 0,
                                child: Container(
                                  padding: const EdgeInsets.fromLTRB(
                                    6,
                                    14,
                                    6,
                                    6,
                                  ),
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [
                                        Colors.black.withValues(alpha: 0.0),
                                        Colors.black.withValues(alpha: 0.7),
                                      ],
                                    ),
                                  ),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(3),
                                    child: LinearProgressIndicator(
                                      value: entry.position.progress,
                                      minHeight: 4,
                                      backgroundColor: Colors.white.withValues(
                                        alpha: 0.3,
                                      ),
                                      color: AppColors.accent,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.textHi,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            height: 1.2,
                          ),
                        ),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          child: Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppColors.textLo,
                              fontSize: 11,
                            ),
                          ),
                        ),
                      ],
                      // Breathing room between the text and the card's bottom
                      // border — the card itself adds no internal padding.
                      const SizedBox(height: 10),
                    ],
                  ),
                ),
              ),
              // A genuine sibling *below* the card, not overlaid on top of it.
              // An overlaid corner badge is unreachable by D-pad: Flutter's
              // directional focus search matches against candidates' screen
              // rects, and a badge nested inside the card's own rect never reads
              // as "up/down/left/right" of it — confirmed by testing an
              // overlaid version, where arrow keys skipped straight over it to
              // the next card. A non-overlapping rect below it works exactly
              // like moving between adjacent cards in the row.
              Padding(
                padding: const EdgeInsets.only(top: 4, left: 2),
                child: _RemoveButton(
                  onPressed: onRemove,
                  // Names what leaves the rail — the series, as displayed.
                  itemTitle: title,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Clears one continue-watching entry — a genuine sibling stop below its
/// card (see [_ContinueWatchingTile]'s doc comment on why it can't overlay
/// the card instead).
class _RemoveButton extends StatefulWidget {
  final VoidCallback onPressed;

  /// Title of the entry this removes, so the control announces what it acts
  /// on instead of a bare "Remove".
  final String itemTitle;

  /// Font size of the "Remove" label, shared with [height].
  static const double _labelFontSize = 11;

  /// Minimum tap target. The visible chip is deliberately much smaller — it
  /// sits under a poster thumb — but this is a destructive control directly
  /// below a tile whose tap starts playback, so the *hit* area is padded out.
  static const double _minTapTarget = 44;

  /// Height one of these occupies, for [_ContinueWatchingTile.height]'s rail
  /// sizing. Normally the flat [_minTapTarget], but the chip's own content is
  /// measured too so an extreme accessibility text scale grows the rail
  /// instead of overflowing it.
  static double height(BuildContext context) {
    final label = MediaQuery.textScalerOf(context).scale(_labelFontSize) * 1.35;
    final chip =
        label +
        3 * 2 + // vertical padding
        2; // focus border
    return math.max(_minTapTarget, chip);
  }

  const _RemoveButton({required this.onPressed, required this.itemTitle});

  @override
  State<_RemoveButton> createState() => _RemoveButtonState();
}

class _RemoveButtonState extends State<_RemoveButton> {
  bool _focused = false;

  // A plain `FocusableActionDetector` node carries no route key, so the root
  // Back ladder read `''` here and fell through to the exit prompt.
  late final FocusNode _focusNode = RoutedFocusNode('media.continue.remove');

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: tr('Remove {title} from Continue watching', {
        'title': widget.itemTitle,
      }),
      child: FocusableActionDetector(
        focusNode: _focusNode,
        mouseCursor: SystemMouseCursors.click,
        onShowFocusHighlight: (v) {
          if (mounted) setState(() => _focused = v);
        },
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onPressed();
              return null;
            },
          ),
        },
        child: GestureDetector(
          onTap: widget.onPressed,
          // The visual chip stays small (it sits under a poster thumb), but
          // the *hit* area is padded out to the 44px minimum — this is a
          // destructive control immediately below a tile whose tap starts
          // playback, so a mis-tap here is expensive. `behavior: opaque`
          // makes the transparent padding hit-testable. This adds no focus
          // stop: the SizedBox is inside the existing detector.
          behavior: HitTestBehavior.opaque,
          child: SizedBox(
            height: _RemoveButton._minTapTarget,
            child: Align(
              alignment: Alignment.centerLeft,
              child: AnimatedContainer(
                duration: appMotion(context, const Duration(milliseconds: 120)),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(
                  color: _focused ? AppColors.panelHi : Colors.transparent,
                  borderRadius: BorderRadius.circular(6),
                  border: _focused ? Border.all(color: AppColors.accent) : null,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.close_rounded,
                      size: 13,
                      color: _focused ? AppColors.accent : AppColors.textLo,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      tr('Remove'),
                      style: TextStyle(
                        fontSize: _RemoveButton._labelFontSize,
                        fontWeight: FontWeight.w600,
                        color: _focused ? AppColors.accent : AppColors.textLo,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A landscape (16:9) artwork tile for the continue-watching rail — prefers
/// [MediaItem.backdrop] (a proper cinematic still) and falls back to
/// [MediaItem.poster] (often a video-frame screenshot for episodes), since
/// either is landscape-shaped content, unlike [_Poster]'s portrait crop.
class _Thumb extends StatelessWidget {
  final MediaItem item;
  final double width;
  final double height;

  const _Thumb({required this.item, required this.width, required this.height});

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
    final image = (backdrop != null && backdrop.isNotEmpty)
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
    return FocusableCard(
      autofocus: autofocus,
      scrollOnFocus: scrollOnFocus,
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
                        item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
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
  late final Future<List<MediaItem>>? _seasonsFuture = _loadSeasonsIfNeeded();
  final Map<String, Future<List<MediaItem>>> _episodeFutures = {};
  bool _refreshingMetadata = false;
  bool _openingTrailer = false;
  final _scrollController = ScrollController();
  final _playFocusNode = RoutedFocusNode('media.details.play');
  final _fromStartFocusNode = RoutedFocusNode('media.details.fromStart');
  final _trailerFocusNode = RoutedFocusNode('media.details.trailer');
  final _favoriteFocusNode = RoutedFocusNode('media.details.favorite');
  final _closeFocusNode = RoutedFocusNode('media.details.close');
  final _episodesKey = GlobalKey();

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
    _scrollController.dispose();
    _playFocusNode.dispose();
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

  Future<List<MediaItem>>? _loadSeasonsIfNeeded() {
    if (_item.kind != ContentKind.series) return null;
    _clearInheritedLoadToken();
    return widget.repo
        .loadMedia(ContentKind.season, parent: _item)
        .then((snapshot) => snapshot.items);
  }

  Future<List<MediaItem>> _episodes(MediaItem season) =>
      _episodeFutures.putIfAbsent(season.id, () {
        _clearInheritedLoadToken();
        return widget.repo
            .loadMedia(ContentKind.episode, parent: season)
            .then((snapshot) => snapshot.items);
      });

  Future<ExternalMetadata?> _loadMetadata() =>
      widget.repo.cachedExternalMetadata(_item, 'tmdb');

  Future<void> _refreshMetadata() async {
    if (_refreshingMetadata) return;
    setState(() => _refreshingMetadata = true);
    try {
      final metadata = await widget.repo.refreshExternalMetadata(_item);
      if (!mounted) return;
      setState(() {
        if (metadata != null) {
          _item = widget.repo.mergeExternalMetadata(_item, metadata);
          widget.onChanged?.call(_item);
        }
        _metadataFuture = _loadMetadata();
        _refreshingMetadata = false;
      });
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
        final inset = constraints.maxWidth < 680 ? 22.0 : 32.0;
        final seasonsFuture = _seasonsFuture;
        return Stack(
          children: [
            SingleChildScrollView(
              controller: _scrollController,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _cinematicHeader(context, constraints.maxWidth, short),
                  Padding(
                    padding: EdgeInsets.fromLTRB(inset, 20, inset, 28),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (_item.description?.isNotEmpty == true) ...[
                          Text(
                            _item.description!,
                            style: const TextStyle(
                              color: Color(0xFFCED2DA),
                              fontSize: 15,
                              height: 1.6,
                            ),
                          ),
                          const SizedBox(height: 20),
                        ],
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
                          refreshing: _refreshingMetadata,
                          onRefresh: _refreshMetadata,
                        ),
                        if (seasonsFuture != null) ...[
                          const SizedBox(height: 26),
                          Text(
                            tr('Episodes'),
                            key: _episodesKey,
                            style: Theme.of(context).textTheme.titleLarge
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 8),
                          _SeriesBrowser(
                            seasons: seasonsFuture,
                            episodesFor: _episodes,
                            onPlayEpisode: _play,
                            onFirstSeasonFocusNode: (node) =>
                                _firstSeasonFocusNode = node,
                          ),
                        ],
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
    final inset = compact ? 22.0 : 32.0;
    final art = _item.backdrop?.isNotEmpty == true
        ? _item.backdrop
        : _item.poster?.isNotEmpty == true
        ? _item.poster
        : null;
    final duration = _mediaDurationLabel(_item.durationSeconds);
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
          constraints: BoxConstraints(minHeight: short ? 250 : 340),
          padding: EdgeInsets.fromLTRB(inset, 76, inset, 24),
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
                  fontSize: compact || short ? 30 : 42,
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
              const SizedBox(height: 20),
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
                      onPressed: widget.onPlay ?? _showEpisodes,
                      icon: Icon(
                        widget.onPlay == null
                            ? Icons.video_library_outlined
                            : Icons.play_arrow_rounded,
                      ),
                      label: Text(
                        widget.onPlay == null
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

class _MetadataStatus extends StatelessWidget {
  final Future<ExternalMetadata?> metadata;
  final bool refreshing;
  final VoidCallback onRefresh;

  const _MetadataStatus({
    required this.metadata,
    required this.refreshing,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ExternalMetadata?>(
      future: metadata,
      builder: (context, snapshot) {
        final value = snapshot.data;
        final label = value == null
            ? tr('Provider metadata')
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
              Icon(
                value == null
                    ? Icons.auto_awesome_outlined
                    : Icons.check_circle_outline,
                color: value == null ? AppColors.textLo : AppColors.accent,
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: AppColors.textLo, fontSize: 12),
                ),
              ),
              IconButton(
                tooltip: tr('Refresh metadata'),
                visualDensity: VisualDensity.compact,
                onPressed: refreshing ? null : onRefresh,
                icon: refreshing
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh, size: 18),
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

class _SeriesBrowser extends StatelessWidget {
  final Future<List<MediaItem>> seasons;
  final Future<List<MediaItem>> Function(MediaItem season) episodesFor;
  final ValueChanged<MediaItem> onPlayEpisode;

  /// Called once, during build, with the first season header's own
  /// (ExpansionTile-internal) [FocusNode] as soon as it exists — so the
  /// details can [FocusNode.requestFocus] it when View episodes is activated,
  /// instead of `FocusScope.nextFocus()`, which lands on the title row's
  /// favorite star (the first focusable stop in the sheet when there's no
  /// top-level Play button). Null when there's nothing to capture yet.
  final ValueChanged<FocusNode>? onFirstSeasonFocusNode;

  const _SeriesBrowser({
    required this.seasons,
    required this.episodesFor,
    required this.onPlayEpisode,
    this.onFirstSeasonFocusNode,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<MediaItem>>(
      future: seasons,
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
        final seasons = snapshot.data ?? const <MediaItem>[];
        if (seasons.isEmpty) {
          return Text(
            tr('No seasons found'),
            style: TextStyle(color: AppColors.textLo),
          );
        }
        return Column(
          children: [
            for (var i = 0; i < seasons.length; i++)
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(bottom: 8),
                // The first season's title carries a `Builder` so it can hand
                // its own (ExpansionTile-internal) focus node back up to the
                // sheet — see `onFirstSeasonFocusNode`'s doc comment for why:
                // the sheet needs to request focus on this exact node rather
                // than `FocusScope.nextFocus()`, which currently lands on the
                // title row's favorite star instead of the season list.
                title: i == 0 && onFirstSeasonFocusNode != null
                    ? Builder(
                        builder: (context) {
                          onFirstSeasonFocusNode!(
                            Focus.of(context, createDependency: false),
                          );
                          return Text(seasons[i].title);
                        },
                      )
                    : Text(seasons[i].title),
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
                    builder: (context) => FutureBuilder<List<MediaItem>>(
                      future: episodesFor(seasons[i]),
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
                        final episodes =
                            episodeSnapshot.data ?? const <MediaItem>[];
                        if (episodes.isEmpty) {
                          return Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              tr('No episodes found'),
                              style: TextStyle(color: AppColors.textLo),
                            ),
                          );
                        }
                        return Column(
                          children: [
                            // FocusableCard (not ListTile) — the series browser
                            // was the only browsing surface without the app's
                            // accent D-pad focus ring; season headers stay
                            // ExpansionTile (see the doc comment above on why
                            // that one isn't wrapped).
                            for (final episode in episodes)
                              FocusableCard(
                                debugLabel: 'media.episode.${episode.id}',
                                semanticsLabel: _episodeSemanticsLabel(episode),
                                onTap: () => onPlayEpisode(episode),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 4,
                                  ),
                                  child: Row(
                                    children: [
                                      const Icon(
                                        Icons.play_arrow_rounded,
                                        color: AppColors.accent,
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              episode.episodeNumber == null
                                                  ? episode.title
                                                  : '${episode.episodeNumber}. ${episode.title}',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .bodyLarge,
                                            ),
                                            if (episode.description !=
                                                null) ...[
                                              const SizedBox(height: 2),
                                              Text(
                                                episode.description!,
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  color: AppColors.textLo,
                                                  fontSize: 12,
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
                  ),
                ],
              ),
          ],
        );
      },
    );
  }
}
