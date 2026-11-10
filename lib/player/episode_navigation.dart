import '../data/library_repository.dart';
import '../sources/source.dart';

/// Provider order breaks ties when numbering is missing or duplicated.
List<MediaItem> orderPlaybackEpisodes(Iterable<MediaItem> episodes) {
  final result = episodes.toList();
  final order = {for (var i = 0; i < result.length; i++) result[i].id: i};
  int numbered(int? a, int? b) => a == null
      ? (b == null ? 0 : 1)
      : b == null
      ? -1
      : a.compareTo(b);
  result.sort((a, b) {
    final season = numbered(a.seasonNumber, b.seasonNumber);
    if (season != 0) return season;
    final episode = numbered(a.episodeNumber, b.episodeNumber);
    return episode != 0 ? episode : order[a.id]!.compareTo(order[b.id]!);
  });
  return result;
}

MediaItem? adjacentPlaybackEpisode(
  List<MediaItem> episodes,
  String? currentId,
  int delta,
) {
  final current = episodes.indexWhere((episode) => episode.id == currentId);
  if (current < 0) return null;
  final next = current + delta;
  return next >= 0 && next < episodes.length ? episodes[next] : null;
}

/// Load the playing series through the same provider-neutral cache as its
/// details screen. Stream URLs are deliberately resolved only after selection.
/// Keep provider/cached artwork, but never wait for external metadata lookups
/// for every season and episode before starting the selected stream. Paginated
/// portals limit navigation to the requested season instead of fetching every
/// other season as a side effect of pressing Play.
Future<List<MediaItem>> loadPlaybackEpisodes(
  LibraryRepository repo,
  MediaItem current,
) async {
  if (current.kind != ContentKind.episode) return const [];
  final episodes = <String, MediaItem>{};
  final parentId = current.parentId;
  if (parentId == null) return [current];
  final parents = await repo.db.readMediaItemsByIds(
    repo.source.id,
    ContentKind.season,
    [parentId],
  );
  if (parents.isEmpty) {
    final cached = await repo.db.readMediaItems(
      repo.source.id,
      ContentKind.episode,
      parentId: parentId,
    );
    return [
      ...cached,
      if (!cached.any((episode) => episode.id == current.id)) current,
    ];
  }
  final currentSeason = parents.first;
  final source = repo.source;
  final prefetchSeasons =
      source is! SourceCapabilityReporter ||
      (source as SourceCapabilityReporter)
          .sourceCapabilities
          .prefetchPlaybackSeasons;
  var seasons = <MediaItem>[currentSeason];
  String? seriesArtwork;
  final seriesId = currentSeason.parentId;
  if (seriesId != null) {
    final series = await repo.db.readMediaItemsByIds(
      repo.source.id,
      ContentKind.series,
      [seriesId],
    );
    if (series.isNotEmpty) {
      seriesArtwork = [
        series.first.backdrop,
        series.first.poster,
      ].whereType<String>().where((url) => url.isNotEmpty).firstOrNull;
      if (prefetchSeasons) {
        try {
          repo.loadToken = null;
          var snapshot = await repo.loadMedia(
            ContentKind.season,
            parent: series.first,
            enrichChildren: false,
          );
          while (snapshot.hasMore) {
            final loadedPages = snapshot.loadedPages;
            repo.loadToken = null;
            snapshot = await repo.loadMoreMedia(
              ContentKind.season,
              parent: series.first,
              enrichChildren: false,
            );
            if (snapshot.loadedPages <= loadedPages) break;
          }
          seasons = [
            currentSeason,
            ...snapshot.items.where((season) => season.id != currentSeason.id),
          ];
        } catch (_) {
          // A failed season refresh must not prevent playing the chosen episode.
        }
      }
    }
  }
  for (final season in seasons) {
    try {
      repo.loadToken = null;
      var snapshot = await repo.loadMedia(
        ContentKind.episode,
        parent: season,
        enrichChildren: false,
      );
      while (snapshot.hasMore) {
        final loadedPages = snapshot.loadedPages;
        repo.loadToken = null;
        snapshot = await repo.loadMoreMedia(
          ContentKind.episode,
          parent: season,
          enrichChildren: false,
        );
        if (snapshot.loadedPages <= loadedPages) break;
      }
      for (final episode in snapshot.items) {
        episodes[episode.id] = episode;
      }
    } catch (_) {
      // Keep cached siblings when the provider cannot return a season.
      final cached = await repo.db.readMediaItems(
        repo.source.id,
        ContentKind.episode,
        parentId: season.id,
      );
      for (final episode in cached) {
        episodes[episode.id] = episode;
      }
    }
  }
  episodes.putIfAbsent(current.id, () => current);
  final result = orderPlaybackEpisodes(episodes.values);
  return [
    for (final episode in result)
      if (episode.poster?.isNotEmpty != true &&
          episode.backdrop?.isNotEmpty != true &&
          seriesArtwork != null)
        episode.copyWith(backdrop: seriesArtwork)
      else
        episode,
  ];
}
