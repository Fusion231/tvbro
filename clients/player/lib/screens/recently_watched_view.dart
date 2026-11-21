import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../data/library_repository.dart';
import '../data/recently_watched_store.dart';
import '../l10n/app_localizations.dart';
import '../sources/source.dart';
import '../theme.dart';
import '../widgets/focusable_card.dart';
import '../widgets/image_utils.dart';

typedef _RecentItem = ({Object item, String? seriesId, MediaItem? series});

class RecentlyWatchedView extends StatefulWidget {
  final LibraryRepository repo;
  final RecentlyWatchedStore store;
  final bool Function(Channel) channelAllowed;
  final bool Function(MediaItem) mediaAllowed;
  final ValueChanged<Channel> onPlayChannel;
  final ValueChanged<MediaItem> onPlayMedia;

  const RecentlyWatchedView({
    super.key,
    required this.repo,
    required this.store,
    required this.channelAllowed,
    required this.mediaAllowed,
    required this.onPlayChannel,
    required this.onPlayMedia,
  });

  @override
  State<RecentlyWatchedView> createState() => _RecentlyWatchedViewState();
}

class _RecentlyWatchedViewState extends State<RecentlyWatchedView> {
  late Future<List<_RecentItem>> _items;

  @override
  void initState() {
    super.initState();
    _items = _load();
    widget.store.addListener(_reload);
  }

  @override
  void didUpdateWidget(covariant RecentlyWatchedView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store != widget.store || oldWidget.repo != widget.repo) {
      oldWidget.store.removeListener(_reload);
      widget.store.addListener(_reload);
      _items = _load();
    }
  }

  void _reload() {
    setState(() {
      _items = _load();
    });
  }

  Future<List<_RecentItem>> _load() async {
    final repo = widget.repo;
    final entries = await widget.store.read(repo.source.id);
    // Existing VOD resume points populate the rail on the first upgraded run.
    final positions = await repo.db.readRecentPositions(repo.source.id);
    final combined = [...entries];
    for (final position in positions) {
      if (!combined.any(
        (e) => e.kind == position.kind && e.itemId == position.itemId,
      )) {
        combined.add((
          kind: position.kind,
          itemId: position.itemId,
          watchedAt: position.updatedAt,
        ));
      }
    }
    combined.sort((a, b) => b.watchedAt.compareTo(a.watchedAt));
    final items = <Object>[];
    for (final entry in combined) {
      if (entry.kind == ContentKind.live) {
        final channel = await repo.db.readChannel(repo.source.id, entry.itemId);
        if (channel != null) items.add(channel);
      } else {
        items.addAll(
          await repo.db.readMediaItemsByIds(repo.source.id, entry.kind, [
            entry.itemId,
          ]),
        );
      }
    }
    final episodeParents = {
      for (final item in items.whereType<MediaItem>())
        if (item.kind == ContentKind.episode && item.parentId != null)
          item.id: item.parentId!,
    };
    final seasons = await repo.db.readMediaItemsByIds(
      repo.source.id,
      ContentKind.season,
      episodeParents.values.toSet().toList(),
    );
    final seasonSeries = {
      for (final season in seasons) season.id: season.parentId,
    };
    final seriesIds = episodeParents.map(
      (episodeId, parentId) =>
          MapEntry(episodeId, seasonSeries[parentId] ?? parentId),
    );
    final seriesItems = await repo.db.readMediaItemsByIds(
      repo.source.id,
      ContentKind.series,
      seriesIds.values.toSet().toList(),
    );
    final seriesById = {for (final series in seriesItems) series.id: series};
    return [
      for (final item in items)
        if (item is MediaItem && item.kind == ContentKind.episode)
          (
            item: item,
            seriesId: seriesIds[item.id],
            series: seriesById[seriesIds[item.id]],
          )
        else
          (item: item, seriesId: null, series: null),
    ];
  }

  @override
  void dispose() {
    widget.store.removeListener(_reload);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        tr('Recently watched'),
        style: const TextStyle(
          color: AppColors.textHi,
          fontSize: 20,
          fontWeight: FontWeight.w600,
        ),
      ),
      const SizedBox(height: 12),
      FutureBuilder<List<_RecentItem>>(
        future: _items,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: snapshot.hasError
                  ? Text(tr('Could not load recently watched.'))
                  : const LinearProgressIndicator(),
            );
          }
          final seenSeries = <String>{};
          final items = <_RecentItem>[];
          for (final entry in snapshot.data!) {
            final allowed = switch (entry.item) {
              Channel channel => widget.channelAllowed(channel),
              MediaItem media => widget.mediaAllowed(media),
              _ => false,
            };
            if (!allowed) continue;
            if (entry.series case final series?
                when !widget.mediaAllowed(series)) {
              continue;
            }
            if (entry.seriesId case final id? when !seenSeries.add(id)) {
              continue;
            }
            items.add(entry);
            if (items.length == RecentlyWatchedStore.limit) break;
          }
          if (items.isEmpty) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Text(
                tr(
                  'Your recently watched TV, movies and series will appear here.',
                ),
                style: const TextStyle(color: AppColors.textLo),
              ),
            );
          }
          final scale = MediaQuery.textScalerOf(context);
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final item in items)
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: SizedBox(
                      width: 156,
                      child: _card(context, item, scale),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    ],
  );

  Widget _card(BuildContext context, _RecentItem entry, TextScaler scale) {
    final item = entry.item;
    final channel = item is Channel ? item : null;
    final media = item is MediaItem ? item : null;
    final title = channel?.name ?? entry.series?.title ?? media!.title;
    final artwork = channel?.logo ?? entry.series?.poster ?? media?.poster;
    final label = channel != null
        ? tr('TV')
        : media!.kind == ContentKind.movie
        ? tr('Movies')
        : tr('Series');
    final icon = channel != null
        ? Icons.live_tv_rounded
        : media!.kind == ContentKind.movie
        ? Icons.movie_outlined
        : Icons.video_library_outlined;
    final fallback = Center(
      child: Icon(icon, size: 32, color: AppColors.textLo),
    );
    return FocusableCard(
      key: ValueKey(
        'recent-${channel != null ? 'live' : media!.kind.name}-${channel?.id ?? media!.id}',
      ),
      semanticsLabel: entry.series == null
          ? '$label: $title'
          : '$label: $title, ${media!.title}',
      onTap: () => channel != null
          ? widget.onPlayChannel(channel)
          : widget.onPlayMedia(media!),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                height: 90,
                width: double.infinity,
                child: artwork == null || artwork.isEmpty
                    ? fallback
                    : CachedNetworkImage(
                        imageUrl: artwork,
                        fit: channel != null ? BoxFit.contain : BoxFit.cover,
                        memCacheWidth: imageCacheSize(context, 140),
                        placeholder: (_, _) => fallback,
                        errorWidget: (_, _, _) => fallback,
                      ),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: scale.scale(13) * 2.6,
              child: Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13,
                  height: 1.3,
                  color: AppColors.textHi,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              entry.series == null ? label : media!.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: AppColors.textLo),
            ),
          ],
        ),
      ),
    );
  }
}
