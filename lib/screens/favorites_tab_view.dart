import 'dart:async';

import 'package:flutter/material.dart';

import '../data/app_database.dart';
import '../data/source_store.dart';
import '../l10n/app_localizations.dart';
import '../sources/source.dart';
import '../sources/source_config.dart';
import '../theme.dart';
import '../widgets/focusable_card.dart';
import '../widgets/source_error_view.dart';
import 'global_favorites_controller.dart';
import 'media_tab_view.dart';

typedef _FavoriteMedia = ({MediaItem item, SourceConfig config});

/// The saved channels, movies and series from every configured provider.
class FavoritesTabView extends StatefulWidget {
  final bool active;
  final AppDatabase db;
  final SourceStore store;
  final List<GlobalFavoriteChannel> channels;
  final bool channelsLoading;
  final bool Function(MediaItem, SourceConfig) isMediaAllowed;
  final ValueChanged<GlobalFavoriteChannel> onPlayChannel;
  final void Function(MediaItem, SourceConfig) onOpenMedia;
  final ScrollController scrollController;
  final FocusNode firstFocusNode;

  const FavoritesTabView({
    super.key,
    this.active = true,
    required this.db,
    required this.store,
    required this.channels,
    required this.channelsLoading,
    required this.isMediaAllowed,
    required this.onPlayChannel,
    required this.onOpenMedia,
    required this.scrollController,
    required this.firstFocusNode,
  });

  @override
  State<FavoritesTabView> createState() => _FavoritesTabViewState();
}

class _FavoritesTabViewState extends State<FavoritesTabView> {
  StreamSubscription<void>? _changed;
  StreamSubscription<void>? _replaced;
  List<_FavoriteMedia> _movies = const [];
  List<_FavoriteMedia> _series = const [];
  int _sourceCount = 0;
  int _generation = 0;
  bool _loading = true;
  bool _failed = false;
  bool _dirty = true;
  bool _loadRunning = false;
  Widget? _lastBody;

  @override
  void initState() {
    super.initState();
    _listen();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant FavoritesTabView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.db != widget.db || oldWidget.store != widget.store) {
      _generation++;
      unawaited(_changed?.cancel() ?? Future<void>.value());
      unawaited(_replaced?.cancel() ?? Future<void>.value());
      _listen();
      unawaited(_load());
    } else if (!oldWidget.active && widget.active && _dirty) {
      unawaited(_load());
    }
  }

  void _listen() {
    _changed = widget.db.favoritesChanged.listen((_) => unawaited(_load()));
    _replaced = widget.db.favoritesReplaced.listen((_) => unawaited(_load()));
  }

  Future<List<_FavoriteMedia>> _readMedia(
    AppDatabase db,
    SourceConfig config,
    ContentKind kind,
  ) async {
    final ids = await db.readFavoriteIds(config.id, kind);
    if (ids.isEmpty) return const [];
    final items = [
      ...await db.readMediaItemsByIds(config.id, kind, ids.toList()),
    ];
    items.sort((a, b) => a.title.compareTo(b.title));
    return [for (final item in items) (item: item, config: config)];
  }

  Future<void> _load() async {
    _dirty = true;
    if (!mounted || !widget.active || _loadRunning) return;
    _loadRunning = true;
    try {
      do {
        _dirty = false;
        await _readFavorites();
      } while (mounted && widget.active && _dirty);
    } finally {
      _loadRunning = false;
    }
  }

  Future<void> _readFavorites() async {
    if (!mounted) return;
    final generation = ++_generation;
    final db = widget.db;
    final store = widget.store;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final configs = await store.list();
      final lists = await Future.wait([
        for (final config in configs)
          for (final kind in const [ContentKind.movie, ContentKind.series])
            _readMedia(db, config, kind),
      ]);
      if (!mounted || generation != _generation) return;
      final media = lists.expand((items) => items);
      setState(() {
        _movies = [
          for (final entry in media)
            if (entry.item.kind == ContentKind.movie) entry,
        ];
        _series = [
          for (final entry in media)
            if (entry.item.kind == ContentKind.series) entry,
        ];
        _sourceCount = configs.length;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _movies = const [];
        _series = const [];
        _loading = false;
        _failed = true;
      });
    }
  }

  @override
  void dispose() {
    _generation++;
    unawaited(_changed?.cancel() ?? Future<void>.value());
    unawaited(_replaced?.cancel() ?? Future<void>.value());
    super.dispose();
  }

  bool _allowed(_FavoriteMedia entry) =>
      !entry.config
          .hiddenCategoryIds(entry.item.kind)
          .contains(entry.item.categoryId) &&
      widget.isMediaAllowed(entry.item, entry.config);

  @override
  Widget build(BuildContext context) {
    if (!widget.active && _lastBody != null) return _lastBody!;
    final movies = _movies.where(_allowed).toList();
    final series = _series.where(_allowed).toList();
    final channels = widget.channels;
    final hasItems =
        channels.isNotEmpty || movies.isNotEmpty || series.isNotEmpty;
    final loading = _loading || widget.channelsLoading;
    final showSource =
        _sourceCount > 1 ||
        {for (final entry in channels) entry.sourceId}.length > 1;
    final size = MediaQuery.sizeOf(context);
    final grid =
        size.width >= kMediaGridMinWidth && size.height >= kMediaGridMinHeight;
    return _lastBody = CustomScrollView(
      controller: widget.scrollController,
      slivers: [
        if (channels.isNotEmpty) ...[
          _heading(tr('Live')),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            sliver: SliverList.builder(
              itemCount: channels.length,
              itemBuilder: (context, i) =>
                  _channel(channels[i], first: i == 0, showSource: showSource),
            ),
          ),
        ],
        if (movies.isNotEmpty) ...[
          _heading(tr('Movies')),
          _media(
            context,
            movies,
            firstSection: channels.isEmpty,
            showSource: showSource,
            useGrid: grid,
          ),
        ],
        if (series.isNotEmpty) ...[
          _heading(tr('Series')),
          _media(
            context,
            series,
            firstSection: channels.isEmpty && movies.isEmpty,
            showSource: showSource,
            useGrid: grid,
          ),
        ],
        if (hasItems && loading)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: LinearProgressIndicator(),
            ),
          ),
        if (_failed)
          SliverFillRemaining(
            hasScrollBody: false,
            child: SourceErrorView(
              message: tr('Could not load favorites.'),
              onRetry: () => unawaited(_load()),
            ),
          )
        else if (!hasItems)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: loading
                  ? CircularProgressIndicator(semanticsLabel: tr('Loading'))
                  : Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        tr('No favorites yet'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: AppColors.textLo),
                      ),
                    ),
            ),
          ),
      ],
    );
  }

  Widget _heading(String title) => SliverToBoxAdapter(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 8),
      child: Text(
        title,
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
      ),
    ),
  );

  Widget _channel(
    GlobalFavoriteChannel entry, {
    required bool first,
    required bool showSource,
  }) => FocusableCard(
    key: ValueKey(entry.globalId),
    focusNode: first ? widget.firstFocusNode : null,
    autofocus: first,
    debugLabel: 'favorites.live.${entry.sourceId}.${entry.channel.id}',
    semanticsLabel: [
      entry.channel.name,
      if (showSource) entry.sourceLabel,
      tr('Favorite'),
    ].join(', '),
    onTap: () => widget.onPlayChannel(entry),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          const Icon(Icons.live_tv_outlined, color: AppColors.textLo),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.channel.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                if (showSource) ...[
                  const SizedBox(height: 4),
                  _sourceLabel(entry.sourceLabel),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          const Icon(Icons.star_rounded, size: 18, color: AppColors.accent),
          const SizedBox(width: 8),
          const Icon(Icons.play_arrow_rounded, color: AppColors.accent),
        ],
      ),
    ),
  );

  Widget _media(
    BuildContext context,
    List<_FavoriteMedia> entries, {
    required bool firstSection,
    required bool showSource,
    required bool useGrid,
  }) {
    final metrics = MediaGridMetrics.forSize(MediaQuery.sizeOf(context));
    final textBudget = mediaTileTextBudget(context, compact: true);
    Widget tile(int index, {required bool grid}) {
      final entry = entries[index];
      final first = firstSection && index == 0;
      final label = entry.config.label.trim().isEmpty
          ? entry.config.kind.name
          : entry.config.label.trim();
      final key = ValueKey((entry.config.id, entry.item.kind, entry.item.id));
      final focusLabel =
          'favorites.${entry.config.id}.${entry.item.kind.name}.${entry.item.id}';
      final card = grid
          ? MediaGridTile(
              item: entry.item,
              favorite: true,
              position: index + 1,
              total: entries.length,
              autofocus: first,
              focusNode: first ? widget.firstFocusNode : null,
              debugLabel: focusLabel,
              compact: true,
              textBudget: textBudget,
              onTap: () => widget.onOpenMedia(entry.item, entry.config),
            )
          : MediaListTile(
              item: entry.item,
              favorite: true,
              position: index + 1,
              total: entries.length,
              autofocus: first,
              focusNode: first ? widget.firstFocusNode : null,
              debugLabel: focusLabel,
              onTap: () => widget.onOpenMedia(entry.item, entry.config),
            );
      if (!showSource) return KeyedSubtree(key: key, child: card);
      return Semantics(
        key: key,
        label: label,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (grid) Expanded(child: card) else card,
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
              child: _sourceLabel(label),
            ),
          ],
        ),
      );
    }

    if (!useGrid) {
      return SliverPadding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        sliver: SliverList.builder(
          itemCount: entries.length,
          itemBuilder: (_, index) => tile(index, grid: false),
        ),
      );
    }
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final width = metrics.tileWidth(constraints.crossAxisExtent);
        final cardHeight =
            width /
            metrics.childAspectRatio(tileWidth: width, textBudget: textBudget);
        final sourceHeight = showSource
            ? MediaQuery.textScalerOf(context).scale(11) * 1.35 + 4
            : 0;
        return SliverPadding(
          padding: metrics.padding,
          sliver: SliverGrid.builder(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: metrics.columns,
              crossAxisSpacing: metrics.crossAxisSpacing,
              mainAxisSpacing: metrics.mainAxisSpacing,
              childAspectRatio: width / (cardHeight + sourceHeight),
            ),
            itemCount: entries.length,
            itemBuilder: (_, index) => tile(index, grid: true),
          ),
        );
      },
    );
  }

  Widget _sourceLabel(String label) => Text(
    label,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: const TextStyle(color: AppColors.textLo, fontSize: 11, height: 1.35),
  );
}
