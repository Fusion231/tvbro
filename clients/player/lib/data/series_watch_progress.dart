import '../sources/source.dart';
import 'app_database.dart';

/// Viewing history for the episodes already cached for one series.
/// Catalog completeness is deliberately left to the caller.
class SeriesWatchProgress {
  final List<MediaItem> episodes;
  final Map<String, PlaybackPosition> positions;
  final int? _latestIndex;

  const SeriesWatchProgress._(this.episodes, this.positions, this._latestIndex);

  factory SeriesWatchProgress.fromEpisodes(
    Iterable<MediaItem> episodes,
    Map<String, PlaybackPosition> positions,
  ) {
    final byId = <String, MediaItem>{};
    for (final episode in episodes) {
      if (episode.kind == ContentKind.episode) {
        byId.putIfAbsent(episode.id, () => episode);
      }
    }
    final ordered = byId.values.toList();
    final providerOrder = {
      for (var index = 0; index < ordered.length; index++)
        ordered[index].id: index,
    };
    int numbered(int? a, int? b) => a == null
        ? (b == null ? 0 : 1)
        : b == null
        ? -1
        : a.compareTo(b);
    ordered.sort((a, b) {
      final season = numbered(a.seasonNumber, b.seasonNumber);
      if (season != 0) return season;
      final episode = numbered(a.episodeNumber, b.episodeNumber);
      return episode != 0
          ? episode
          : providerOrder[a.id]!.compareTo(providerOrder[b.id]!);
    });
    final history = <String, PlaybackPosition>{};
    int? latestIndex;
    for (var index = 0; index < ordered.length; index++) {
      final episode = ordered[index];
      final position = positions[episode.id];
      if (position == null ||
          position.kind != ContentKind.episode ||
          position.itemId != episode.id) {
        continue;
      }
      history[episode.id] = position;
      // With equal checkpoint times prefer the later episode in playback order.
      if (latestIndex == null ||
          !position.updatedAt.isBefore(
            history[ordered[latestIndex].id]!.updatedAt,
          )) {
        latestIndex = index;
      }
    }
    return SeriesWatchProgress._(
      List.unmodifiable(ordered),
      Map.unmodifiable(history),
      latestIndex,
    );
  }

  int get watchedCount => positions.values.where((p) => p.isFinished).length;

  MediaItem? get latestEpisode =>
      _latestIndex == null ? null : episodes[_latestIndex];

  PlaybackPosition? get latestPosition => positions[latestEpisode?.id];

  /// Resume the latest unfinished episode, otherwise advance without wrapping
  /// back to gaps before the latest watched episode.
  MediaItem? get nextEpisode {
    final index = _latestIndex;
    if (index == null) return null;
    if (!latestPosition!.isFinished) return episodes[index];
    for (var next = index + 1; next < episodes.length; next++) {
      final episode = episodes[next];
      if (positions[episode.id]?.isFinished != true) return episode;
    }
    return null;
  }
}
