import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'source.dart';

/// Locally classified VOD from the same download as the live channel list.
class M3uMediaCatalog {
  final Map<ContentKind, List<MediaCategory>> categories;
  final Map<ContentKind, List<MediaItem>> roots;
  final Map<String, List<MediaItem>> children;

  const M3uMediaCatalog({
    this.categories = const {},
    this.roots = const {},
    this.children = const {},
  });
}

final _m3uEpisodePatterns = [
  RegExp(r'\bS(\d{1,3})[\s._-]*E(\d{1,4})\b', caseSensitive: false),
  RegExp(r'\b(\d{1,3})x(\d{1,4})\b', caseSensitive: false),
  RegExp(
    r'\b(?:Season|Sezon)\s*(\d{1,3})[\s._-]*(?:Episode|Ep\.?|Odcinek|Odc\.?)\s*(\d{1,4})\b',
    caseSensitive: false,
  ),
];
final _m3uMovieExtension = RegExp(
  r'\.(?:mkv|mp4|m4v|avi|mov|wmv|webm|mpg|mpeg|flv)$',
  caseSensitive: false,
);

/// Strong provider hints win over filename guesses. Genre/category names
/// alone cannot turn a movie-themed live TV channel into a movie.
class M3uMediaBuilder {
  final _movies = <String, MediaItem>{};
  final _series = <String, MediaItem>{};
  final _seasons = <String, Map<int, MediaItem>>{};
  final _episodes = <String, Map<String, MediaItem>>{};
  final _categories = <ContentKind, Map<String, MediaCategory>>{};

  bool add(
    Channel entry, {
    String? mediaType,
    bool media = false,
    bool radio = false,
  }) {
    if (radio) return false;
    final explicit = mediaType?.trim().toLowerCase();
    if (explicit == 'live' || explicit == 'radio') return false;
    final uri = Uri.tryParse(entry.extra['url'] as String? ?? '');
    final parts = uri?.pathSegments ?? const <String>[];
    final pathKind = parts.isEmpty ? '' : parts.first.toLowerCase();
    RegExpMatch? episode;
    for (final pattern in _m3uEpisodePatterns) {
      episode = pattern.firstMatch(entry.name);
      if (episode != null) break;
    }
    final ContentKind kind;
    if (explicit == 'series' || explicit == 'episode') {
      kind = ContentKind.episode;
    } else if (explicit == 'movie' || explicit == 'vod') {
      kind = ContentKind.movie;
    } else if (media) {
      kind = episode != null || pathKind == 'series'
          ? ContentKind.episode
          : ContentKind.movie;
    } else if (pathKind == 'live') {
      return false;
    } else if (pathKind == 'series') {
      kind = ContentKind.episode;
    } else if (const {'movie', 'movies', 'vod'}.contains(pathKind)) {
      kind = ContentKind.movie;
    } else if (episode != null) {
      kind = ContentKind.episode;
    } else if (_m3uMovieExtension.hasMatch(uri?.path ?? '')) {
      kind = ContentKind.movie;
    } else {
      return false;
    }

    final group = entry.categoryId ?? 'Uncategorized';
    final rootKind = kind == ContentKind.movie ? kind : ContentKind.series;
    (_categories[rootKind] ??= {}).putIfAbsent(
      group,
      () => MediaCategory(id: group, title: group, kind: rootKind),
    );
    if (kind == ContentKind.movie) {
      _movies.putIfAbsent(
        entry.id,
        () => MediaItem(
          id: entry.id,
          title: entry.name,
          kind: ContentKind.movie,
          categoryId: group,
          poster: entry.logo,
          extra: entry.extra,
        ),
      );
      return true;
    }

    final prefix = episode == null
        ? entry.name
        : entry.name.substring(0, episode.start);
    final title = prefix.replaceFirst(RegExp(r'[\s._\-|:]+$'), '').trim();
    final seriesTitle = title.isEmpty ? entry.name : title;
    // Keep language, year and provider category: removing them merges unrelated
    // remakes, dubbed versions or groups. The digest never exposes locators.
    final seriesId =
        'm3u-series:${sha256.convert(utf8.encode(jsonEncode([group, seriesTitle.toLowerCase().replaceAll(RegExp(r'\s+'), ' ')])))}';
    final seasonNumber = episode == null ? 1 : int.parse(episode.group(1)!);
    final episodeNumber = episode == null ? null : int.parse(episode.group(2)!);
    final seasonId = '$seriesId:season:$seasonNumber';
    _series.putIfAbsent(
      seriesId,
      () => MediaItem(
        id: seriesId,
        title: seriesTitle,
        kind: ContentKind.series,
        categoryId: group,
        poster: entry.logo,
      ),
    );
    (_seasons[seriesId] ??= {}).putIfAbsent(
      seasonNumber,
      () => MediaItem(
        id: seasonId,
        title: 'Season $seasonNumber',
        kind: ContentKind.season,
        parentId: seriesId,
        categoryId: group,
        poster: entry.logo,
        seasonNumber: seasonNumber,
      ),
    );
    (_episodes[seasonId] ??= {}).putIfAbsent(
      entry.id,
      () => MediaItem(
        id: entry.id,
        title: entry.name,
        kind: ContentKind.episode,
        parentId: seasonId,
        categoryId: group,
        poster: entry.logo,
        seasonNumber: seasonNumber,
        episodeNumber: episodeNumber,
        extra: entry.extra,
      ),
    );
    return true;
  }

  M3uMediaCatalog build() {
    final children = <String, List<MediaItem>>{};
    for (final entry in _seasons.entries) {
      children[entry.key] = entry.value.values.toList()
        ..sort((a, b) => a.seasonNumber!.compareTo(b.seasonNumber!));
    }
    for (final entry in _episodes.entries) {
      children[entry.key] = entry.value.values.toList()
        ..sort((a, b) {
          final order = (a.episodeNumber ?? 0).compareTo(b.episodeNumber ?? 0);
          return order != 0 ? order : a.id.compareTo(b.id);
        });
    }
    return M3uMediaCatalog(
      categories: _categories.map(
        (kind, rows) => MapEntry(kind, rows.values.toList()),
      ),
      roots: {
        ContentKind.movie: _movies.values.toList(),
        ContentKind.series: _series.values.toList(),
      },
      children: children,
    );
  }
}
