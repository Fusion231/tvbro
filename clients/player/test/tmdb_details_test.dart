import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/media_info.dart';
import 'package:iptvs/data/tmdb_client.dart';
import 'package:iptvs/sources/source.dart';

void main() {
  test('a missing provider TMDB ID falls back to a title match', () async {
    final http = _TmdbHttpClient([
      const _Reply({}, statusCode: HttpStatus.notFound),
      const _Reply({
        'results': [
          {'id': 42, 'title': 'Matched title'},
        ],
      }),
      const _Reply({
        'id': 42,
        'title': 'Matched title',
        'overview': 'Recovered synopsis',
        'credits': {'cast': []},
      }),
    ]);
    final client = TmdbClient(apiKey: 'api-key', http: http);
    addTearDown(client.close);

    final metadata = await client.search(
      const MediaItem(
        id: 'source-1',
        title: 'Matched title',
        kind: ContentKind.movie,
        extra: {'tmdb_id': '999999'},
      ),
    );

    expect(metadata?.overview, 'Recovered synopsis');
    expect(http.urls.map((url) => url.path), [
      '/3/movie/999999',
      '/3/search/movie',
      '/3/movie/42',
    ]);
  });

  test(
    'matches the original title when TMDB returns a translated title',
    () async {
      final http = _TmdbHttpClient([
        const _Reply({
          'results': [
            {
              'id': 42,
              'title': 'A translated title',
              'original_title': 'Polski tytuł',
            },
          ],
        }),
        const _Reply({
          'id': 42,
          'title': 'A translated title',
          'overview': 'Full synopsis',
          'credits': {'cast': []},
        }),
      ]);
      final client = TmdbClient(apiKey: 'api-key', http: http);
      addTearDown(client.close);

      final metadata = await client.search(
        const MediaItem(
          id: 'source-1',
          title: 'Polski tytuł',
          kind: ContentKind.movie,
        ),
      );

      expect(metadata?.overview, 'Full synopsis');
    },
  );

  for (final statusCode in [
    HttpStatus.unauthorized,
    HttpStatus.serviceUnavailable,
  ]) {
    test('TMDB HTTP $statusCode is not mistaken for a missing movie', () async {
      final http = _TmdbHttpClient([_Reply({}, statusCode: statusCode)]);
      final client = TmdbClient(apiKey: 'api-key', http: http);
      addTearDown(client.close);

      await expectLater(
        client.search(
          const MediaItem(
            id: 'source-1',
            title: 'Movie title',
            kind: ContentKind.movie,
            providerId: '42',
          ),
        ),
        throwsA(isA<StateError>()),
      );
      expect(http.urls, hasLength(1));
    });
  }

  test(
    'season episode rows retain complete episode display metadata',
    () async {
      final rows = [
        for (var number = 1; number <= 12; number++)
          {
            'id': 1000 + number,
            'episode_number': number,
            'season_number': 1,
            'name': 'Episode $number',
            'overview': 'Synopsis $number',
            'still_path': '/episode-$number.jpg',
            'air_date': '2026-01-01',
            'runtime': 42,
            'vote_average': 8.5,
          },
      ];
      final http = _TmdbHttpClient([for (final row in rows) _Reply(row)]);
      final client = TmdbClient(apiKey: 'api-key', http: http);
      addTearDown(client.close);
      final season = MediaItem(
        id: 'season',
        title: 'Season',
        kind: ContentKind.season,
        seasonNumber: 1,
        providerId: 'season-metadata',
        extra: {
          'metadata': {
            'tmdb': {
              'series_tmdb_id': '42',
              'season_number': 1,
              'episodes': rows,
            },
          },
        },
      );
      for (var number = 1; number <= 12; number++) {
        final metadata = await client.episodeMetadata(
          season,
          MediaItem(
            id: 'provider-$number',
            title: 'Provider episode $number',
            kind: ContentKind.episode,
            seasonNumber: 1,
            episodeNumber: number,
          ),
        );
        expect(metadata?.providerKey, '${1000 + number}');
        expect(metadata?.title, 'Episode $number');
        expect(metadata?.overview, 'Synopsis $number');
        expect(
          metadata?.poster,
          'https://image.tmdb.org/t/p/w500/episode-$number.jpg',
        );
        expect(metadata?.year, '2026');
        expect(metadata?.rating, 8.5);
        expect(metadata?.payload['runtime'], 42);
        expect(metadata?.payload['season_metadata_id'], season.providerId);
      }
      expect(http.urls, isEmpty);
    debugPrint('SERIES_TMDB_WORK episodes=12 httpRequests=${http.urls.length}');
    },
  );

  for (final cache in [
    'absent',
    'missing episode',
    'partial',
    'wrong series',
    'wrong season',
    'invalid id',
  ]) {
    test(
      'episode endpoint remains the fallback for $cache season data',
      () async {
        final http = _TmdbHttpClient([
          const _Reply({
            'id': 101,
            'name': 'Endpoint episode',
            'overview': 'Full synopsis',
          }),
        ]);
        final client = TmdbClient(apiKey: 'api-key', http: http);
        addTearDown(client.close);
        final metadata = await client.episodeMetadata(
          MediaItem(
            id: 'season',
            title: 'Season',
            kind: ContentKind.season,
            seasonNumber: 1,
            extra: {
              'series_tmdb_id': '42',
              if (cache != 'absent')
                'metadata': {
                  'tmdb': {
                    'series_tmdb_id': cache == 'wrong series' ? '99' : '42',
                    'season_number': cache == 'wrong season' ? 2 : 1,
                    'episodes': [
                      {
                        'id': cache == 'invalid id' ? 'invalid' : 102,
                        'episode_number': cache == 'missing episode' ? 2 : 1,
                        'season_number': 1,
                        'name': 'Cached episode',
                        if (cache != 'partial') ...{
                          'overview': 'Cached synopsis',
                          'still_path': null,
                          'air_date': null,
                          'vote_average': 0,
                          'runtime': null,
                        },
                      },
                    ],
                  },
                },
            },
          ),
          const MediaItem(
            id: 'episode',
            title: 'Provider episode',
            kind: ContentKind.episode,
            episodeNumber: 1,
          ),
        );
        expect(metadata?.title, 'Endpoint episode');
        expect(metadata?.overview, 'Full synopsis');
        expect(http.urls.single.path, '/3/tv/42/season/1/episode/1');
      },
    );
  }

  for (final kind in [ContentKind.movie, ContentKind.series]) {
    final type = kind == ContentKind.movie ? 'movie' : 'tv';
    for (final nestedInfo in [true, false]) {
      test('loads $type cast photos using the provider details TMDB ID '
          '(${nestedInfo ? 'info' : 'details'})', () async {
        final http = _TmdbHttpClient([
          _Reply({
            'id': 42,
            'credits': {
              'cast': [
                {
                  'name': 'Actor Name',
                  'character': 'Lead',
                  'profile_path': '/actor.jpg',
                },
              ],
            },
          }),
        ]);
        final client = TmdbClient(apiKey: 'api-key', http: http);
        addTearDown(client.close);
        final idFields = {'tmdb_id': '42'};
        final item = MediaItem(
          id: '98765',
          title: 'Provider title without a search match',
          kind: kind,
          extra: {
            'stream_id': 98765,
            'tmdb_id': 'invalid',
            'details': nestedInfo ? {'info': idFields} : idFields,
          },
        );

        final metadata = await client.search(item);

        expect(http.urls.single.path, '/3/$type/42');
        expect(
          http.urls.single.queryParameters['append_to_response'],
          'credits',
        );
        expect(metadata, isNotNull);
        final info = MediaInfo.fromItem(
          item.copyWith(
            extra: {
              ...item.extra,
              'metadata': {'tmdb': metadata!.payload},
            },
          ),
        );
        expect(
          info.cast.single.photoUrl,
          'https://image.tmdb.org/t/p/w185/actor.jpg',
        );
      });
    }

    test('loads $type details and credits by provider ID', () async {
      final http = _TmdbHttpClient([
        _Reply({
          'id': 42,
          'title': 'Film title',
          'name': 'Series title',
          'runtime': 103,
          'credits': {
            'cast': [
              {'name': 'Actor Name', 'character': 'Lead'},
            ],
          },
        }),
      ]);
      final bearer = kind == ContentKind.series;
      final credential = bearer ? 'eyJhbGciOiJIUzI1Ni.test.token' : 'api-key';
      final client = TmdbClient(apiKey: credential, http: http);
      addTearDown(client.close);

      final metadata = await client.search(
        MediaItem(
          id: 'source-1',
          title: 'Provider title',
          kind: kind,
          providerId: '42',
        ),
      );

      expect(http.urls.single.path, '/3/$type/42');
      expect(http.urls.single.queryParameters['append_to_response'], 'credits');
      expect(
        http.urls.single.queryParameters['api_key'],
        bearer ? isNull : credential,
      );
      expect(
        http.requestHeaders.single.value(HttpHeaders.authorizationHeader),
        bearer ? 'Bearer $credential' : isNull,
      );
      expect(metadata?.providerKey, '42');
      expect(metadata?.payload['credits'], {
        'cast': [
          {'name': 'Actor Name', 'character': 'Lead'},
        ],
      });
      expect(metadata?.payload['runtime'], 103);
    });

    test('fetches full $type details after a title match', () async {
      final http = _TmdbHttpClient([
        _Reply({
          'results': [
            {'id': 13, 'title': 'Unrelated title', 'name': 'Unrelated title'},
            {'id': 42, 'title': 'Matched title', 'name': 'Matched title'},
          ],
        }),
        _Reply({
          'id': 42,
          'title': 'Matched title',
          'name': 'Matched title',
          'overview': 'Full synopsis',
          'production_countries': [
            {'name': 'Poland'},
          ],
          'credits': {'cast': [], 'crew': []},
        }),
      ]);
      final client = TmdbClient(apiKey: 'api-key', http: http);
      addTearDown(client.close);

      final metadata = await client.search(
        MediaItem(id: 'source-1', title: 'Matched title', kind: kind),
      );

      expect(http.urls.map((url) => url.path), [
        '/3/search/$type',
        '/3/$type/42',
      ]);
      expect(http.urls.first.queryParameters['query'], 'Matched title');
      expect(http.urls.last.queryParameters['append_to_response'], 'credits');
      expect(metadata?.overview, 'Full synopsis');
      expect(metadata?.payload['production_countries'], [
        {'name': 'Poland'},
      ]);
    });
  }

  test('keeps the matched search result when full details fail', () async {
    final http = _TmdbHttpClient([
      _Reply({
        'results': [
          {
            'id': 42,
            'title': 'Matched title',
            'overview': 'Search synopsis',
            'poster_path': '/search.jpg',
          },
        ],
      }),
      const _Reply({}, statusCode: HttpStatus.serviceUnavailable),
    ]);
    final client = TmdbClient(apiKey: 'api-key', http: http);
    addTearDown(client.close);

    final metadata = await client.search(
      const MediaItem(
        id: 'source-1',
        title: 'Matched title',
        kind: ContentKind.movie,
      ),
    );

    expect(http.urls, hasLength(2));
    expect(metadata?.providerKey, '42');
    expect(metadata?.overview, 'Search synopsis');
    expect(metadata?.poster, 'https://image.tmdb.org/t/p/w500/search.jpg');
  });
}

class _Reply {
  const _Reply(this.body, {this.statusCode = HttpStatus.ok});

  final Map<String, dynamic> body;
  final int statusCode;
}

class _TmdbHttpClient extends Fake implements HttpClient {
  _TmdbHttpClient(this.replies);

  final List<_Reply> replies;
  final urls = <Uri>[];
  final requestHeaders = <_Headers>[];

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    final reply = replies[urls.length];
    final headers = _Headers();
    urls.add(url);
    requestHeaders.add(headers);
    return _Request(reply, headers);
  }

  @override
  void close({bool force = false}) {}
}

class _Request extends Fake implements HttpClientRequest {
  _Request(this.reply, this.headers);

  final _Reply reply;

  @override
  final HttpHeaders headers;

  @override
  Future<HttpClientResponse> close() async => _Response(reply);
}

class _Response extends Fake implements HttpClientResponse {
  _Response(this.reply) : bytes = utf8.encode(jsonEncode(reply.body));

  final _Reply reply;
  final List<int> bytes;

  @override
  int get statusCode => reply.statusCode;

  @override
  int get contentLength => bytes.length;

  @override
  HttpHeaders get headers => _Headers();

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(bytes).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
}

class _Headers extends Fake implements HttpHeaders {
  final values = <String, String>{};

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name] = value.toString();
  }

  @override
  String? value(String name) => values[name];
}
