import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/media_info.dart';
import 'package:iptvs/data/tvdb_client.dart';
import 'package:iptvs/sources/source.dart';

import 'support/metadata_http.dart';

const movie = MediaItem(
  id: 'iptv-1',
  title: 'Polski film',
  kind: ContentKind.movie,
  year: '2024',
);
const details = {
  'data': {
    'id': 42,
    'name': 'Original movie',
    'year': '2024',
    'runtime': 103,
    'originalCountry': 'pol',
    'image': 'https://images.test/poster.jpg',
    'genres': [
      {'name': 'Drama'},
    ],
    'first_release': {'date': '2024-01-02'},
    'translations': {
      'nameTranslations': [
        {'language': 'pol', 'name': 'Polski film'},
      ],
      'overviewTranslations': [
        {'language': 'pol', 'overview': 'Pełny opis filmu.'},
        {'language': 'eng', 'overview': 'Full synopsis.'},
      ],
    },
    'characters': [
      {
        'personName': 'Actor',
        'name': 'Lead',
        'peopleType': 'Actor',
        'personImgURL': 'https://images.test/actor.jpg',
      },
      {'personName': 'Director', 'peopleType': 'Director'},
    ],
  },
};

void main() {
  test(
    'movies use the full endpoint and Polish translations after matching',
    () async {
      final http = MetadataHttp(
        (uri) => uri.path == '/v4/search'
            ? const MetadataReply({
                'data': [
                  {
                    'tvdb_id': '42',
                    'name': 'Original movie',
                    'translations': {'pol': 'Polski film'},
                    'year': '2024',
                  },
                ],
              })
            : const MetadataReply(details),
      );
      final client = TvdbClient(apiKey: 'key', language: 'pol', http: http);
      addTearDown(client.close);
      final metadata = await client.search(movie);
      expect(http.urls.first.queryParameters['type'], 'movie');
      expect(http.urls.last.path, '/v4/movies/42/extended');
      expect(http.urls.last.queryParameters['meta'], 'translations');
      expect(http.loginBodies, hasLength(1));
      expect(metadata?.title, 'Polski film');
      expect(metadata?.overview, 'Pełny opis filmu.');
      final info = MediaInfo.fromItem(
        movie.copyWith(
          extra: {
            'metadata': {'tvdb': metadata!.payload},
          },
        ),
      );
      expect(info.cast.single.name, 'Actor');
      expect(info.directors, ['Director']);
      expect(info.durationSeconds, 6180);
      expect(info.releaseDate, '2024-01-02');
    },
  );

  test(
    'explicit TVDB movie IDs bypass title matching and use English fallback',
    () async {
      final http = MetadataHttp((_) => const MetadataReply(details));
      final client = TvdbClient(apiKey: 'key', language: 'deu', http: http);
      addTearDown(client.close);
      final metadata = await client.search(
        movie.copyWith(
          extra: {
            'details': {
              'info': {'tvdb_id': 42},
            },
          },
        ),
      );
      expect(http.urls.single.path, '/v4/movies/42/extended');
      expect(metadata?.overview, 'Full synopsis.');
    },
  );

  test('a TMDB provider ID is not treated as a TVDB movie ID', () async {
    final http = MetadataHttp((_) => const MetadataReply({'data': []}));
    final client = TvdbClient(apiKey: 'key', http: http);
    addTearDown(client.close);
    expect(await client.search(movie.copyWith(providerId: '98765')), isNull);
    expect(http.urls.single.path, '/v4/search');
  });

  test('missing TVDB ID falls back to search', () async {
    final http = MetadataHttp(
      (uri) => uri.path == '/v4/search'
          ? const MetadataReply({'data': []})
          : const MetadataReply({}, status: 404),
    );
    final client = TvdbClient(apiKey: 'key', http: http);
    addTearDown(client.close);
    expect(
      await client.search(movie.copyWith(extra: {'tvdb_id': 999})),
      isNull,
    );
    expect(http.urls.map((u) => u.path), [
      '/v4/movies/999/extended',
      '/v4/search',
    ]);
  });

  test('a details outage retains the matched movie synopsis', () async {
    final http = MetadataHttp(
      (uri) => uri.path == '/v4/search'
          ? const MetadataReply({
              'data': [
                {
                  'tvdb_id': '42',
                  'name': 'Polski film',
                  'overview': 'Search synopsis',
                },
              ],
            })
          : const MetadataReply({}, status: 503),
    );
    final client = TvdbClient(apiKey: 'key', http: http);
    addTearDown(client.close);
    final metadata = await client.search(movie);
    expect(metadata?.overview, 'Search synopsis');
    expect(metadata?.payload['details_loaded'], isNot(true));
  });
}
