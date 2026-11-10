import '../data/library_repository.dart';
import '../sources/source.dart';

/// Load the playing series through the same provider-neutral cache as its
/// details screen. Stream URLs are deliberately resolved only after selection.
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
  var seasons = <MediaItem>[currentSeason];
  final seriesId = currentSeason.parentId;
  if (seriesId != null) {
    final series = await repo.db.readMediaItemsByIds(
      repo.source.id,
      ContentKind.series,
      [seriesId],
    );
    if (series.isNotEmpty) {
      try {
        repo.loadToken = null;
        var snapshot = await repo.loadMedia(
          ContentKind.season,
          parent: series.first,
        );
        while (snapshot.hasMore) {
          final loadedPages = snapshot.loadedPages;
          repo.loadToken = null;
          snapshot = await repo.loadMoreMedia(
            ContentKind.season,
            parent: series.first,
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
  for (final season in seasons) {
    try {
      repo.loadToken = null;
      var snapshot = await repo.loadMedia(ContentKind.episode, parent: season);
      while (snapshot.hasMore) {
        final loadedPages = snapshot.loadedPages;
        repo.loadToken = null;
        snapshot = await repo.loadMoreMedia(
          ContentKind.episode,
          parent: season,
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
  final result = episodes.values.toList();
  final providerOrder = {
    for (var index = 0; index < result.length; index++) result[index].id: index,
  };
  result.sort((a, b) {
    final season = (a.seasonNumber ?? 0).compareTo(b.seasonNumber ?? 0);
    if (season != 0) return season;
    final episode = (a.episodeNumber ?? 0).compareTo(b.episodeNumber ?? 0);
    return episode != 0
        ? episode
        : providerOrder[a.id]!.compareTo(providerOrder[b.id]!);
  });
  return result;
}
