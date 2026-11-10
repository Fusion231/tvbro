import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/media_info.dart';
import 'package:iptvs/data/media_trailer.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/stalker_source.dart';
import 'package:iptvs/sources/xtream_source.dart';

void main() {
  const series = MediaItem(
    id: '42',
    title: 'Series',
    kind: ContentKind.series,
    poster: 'https://art.invalid/poster.jpg',
  );

  for (final provider in ['xtream', 'stalker']) {
    test('$provider seasons keep their own episodes and shared display info', () async {
      final episodes = {
        for (var season = 1; season <= 8; season++)
          '$season': [
            for (var episode = 1; episode <= 12; episode++)
              {
                'id': '$season-$episode',
                'name': 'Episode $episode',
                'title': 'Episode $episode',
                'episode_num': episode,
                'episode_number': episode,
                'cmd': '/media/season-$season-episode-$episode.mpg',
                'description': 'Synopsis $season/$episode',
                'duration': '00:42:05',
              },
          ],
      };
      final details = {
        'info': {
          'director': 'Fixture director',
          'youtube_trailer': 'abcdefghijk',
        },
        'series_tmdb_id': '99',
        'series': 'provider-series-id',
        'season': 'provider-season-hint',
        'episodes': episodes,
        'seasons': [
          for (var number = 1; number <= 8; number++)
            {
              'season_number': number,
              'number': number,
              'name': 'Season $number',
            },
        ],
      };
      final xtream = XtreamSource(
        sourceId: 'fixture',
        host: 'https://provider.invalid',
        username: 'user',
        password: 'password',
        debugApi: (_) async => throw StateError('Unexpected provider request'),
      );
      final stalker = StalkerSource(
        sourceId: 'fixture',
        portal: 'https://provider.invalid/c/',
        mac: '00:1A:79:00:00:00',
      );
      addTearDown(xtream.dispose);
      addTearDown(stalker.dispose);
      final seasons = provider == 'xtream'
          ? (await xtream.mediaItemsPage(
              ContentKind.season,
              parent: series.copyWith(extra: {'details': details}),
            )).items
          : stalker.debugSeasonsFromDetails(series, details);
      expect(seasons, hasLength(8));
      for (final season in seasons) {
        final children = provider == 'xtream'
            ? (await xtream.mediaItemsPage(
                ContentKind.episode,
                parent: season,
              )).items
            : stalker.debugEpisodesFromEmbeddedSeason(season);
        expect(children, hasLength(12));
        expect(children.first.id, '${season.seasonNumber}-1');
        expect(children.first.durationSeconds, 2525);
        expect(
          children.first.extra['cmd'],
          '/media/season-${season.seasonNumber}-episode-1.mpg',
        );
        expect(MediaInfo.fromItem(season).directors, ['Fixture director']);
        expect(mediaTrailerLink(season)?.queryParameters['v'], 'abcdefghijk');
        expect((season.extra['details'] as Map)['series_tmdb_id'], '99');
        expect(
          (season.extra['details'] as Map)['series'],
          'provider-series-id',
        );
        expect(
          (season.extra['details'] as Map)['season'],
          'provider-season-hint',
        );
        expect(season.extra['details'], isNot(contains('episodes')));
        expect(season.extra['details'], isNot(contains('seasons')));
      }
      final bytes = utf8
          .encode(jsonEncode(seasons.map((e) => e.extra).toList()))
          .length;
      debugPrint(
        'SERIES_PAYLOAD_WORK provider=$provider seasons=8 episodes=96 bytes=$bytes',
      );
    });
  }
}
