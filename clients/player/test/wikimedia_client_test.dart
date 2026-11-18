import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/wikimedia_client.dart';
import 'package:iptvs/sources/source.dart';

import 'support/metadata_http.dart';

const _movie = MediaItem(
  id: 'iptv-item',
  title: 'PL 4K - Wąwóz (2025)',
  kind: ContentKind.movie,
);

Map<String, Object> _claim(Object value) => {
  'mainsnak': {
    'datavalue': {'value': value},
  },
};

Map<String, Object> _film(String id, String year, {String type = 'Q11424'}) => {
  'id': id,
  'labels': {
    'pl': {'value': 'Wąwóz'},
  },
  'claims': {
    'P31': [
      _claim({'id': type}),
    ],
    'P577': [
      _claim({'time': '+$year-02-14T00:00:00Z', 'precision': 11}),
    ],
    'P345': [_claim('tt13654226')],
    'P3383': [_claim('Fixture poster.jpg')],
    'P2047': [
      _claim({
        'amount': '+127',
        'unit': 'http://www.wikidata.org/entity/Q7727',
      }),
    ],
    'P161': [
      _claim({'id': 'Q88'}),
    ],
  },
  'sitelinks': {
    'enwiki': {'title': 'The Gorge (film)'},
  },
};

MetadataReply _article() => const MetadataReply({
  'query': {
    'pages': [
      {'title': 'The Gorge (film)', 'extract': 'A reusable synopsis.'},
    ],
  },
});

MetadataReply _poster(String license, {String restrictions = ''}) =>
    MetadataReply({
      'query': {
        'pages': [
          {
            'title': 'File:Fixture poster.jpg',
            'imageinfo': [
              {
                'thumburl': 'https://thumb.wikimedia.org/poster.jpg',
                'extmetadata': {
                  'License': {'value': license},
                  'LicenseShortName': {'value': 'CC BY-SA 4.0'},
                  'LicenseUrl': {
                    'value': 'https://creativecommons.org/licenses/by-sa/4.0/',
                  },
                  'Artist': {'value': 'Poster artist'},
                  'Restrictions': {'value': restrictions},
                },
              },
            ],
          },
        ],
      },
    });

void main() {
  test(
    'looks up a cleaned title and rejects an unrelated entity and remake',
    () async {
      final http = MetadataHttp((uri) {
        if (uri.host == 'en.wikipedia.org') return _article();
        if (uri.host == 'commons.wikimedia.org') return _poster('cc-by-sa-4.0');
        if (uri.queryParameters['action'] == 'wbsearchentities') {
          expect(uri.queryParameters['search'], 'Wąwóz');
          return const MetadataReply({
            'search': [
              {'id': 'Q1'},
              {'id': 'Q2'},
              {'id': 'Q3'},
            ],
          });
        }
        if (uri.queryParameters['ids'] == 'Q88') {
          return const MetadataReply({
            'entities': {
              'Q88': {
                'labels': {
                  'en': {'value': 'Actor Name'},
                },
              },
            },
          });
        }
        return MetadataReply({
          'entities': {
            'Q1': _film('Q1', '2025', type: 'Q5'),
            'Q2': _film('Q2', '1980'),
            'Q3': _film('Q3', '2025'),
          },
        });
      });
      final client = WikimediaClient(
        language: 'pl',
        http: http,
        requestInterval: Duration.zero,
      );
      addTearDown(client.close);
      final info = await client.search(_movie);
      expect(info?.providerKey, 'Q3');
      expect(info?.overview, 'A reusable synopsis.');
      expect(info?.year, '2025');
      expect(info?.poster, 'https://thumb.wikimedia.org/poster.jpg');
      expect(info?.payload['runtime'], 127);
      expect(info?.payload['cast'], ['Actor Name']);
      expect(
        info?.payload['wikipedia_url'],
        'https://en.wikipedia.org/wiki/The_Gorge_(film)',
      );
      expect(info?.payload['commons_artist'], 'Poster artist');
      expect(client.matchesCache(_movie, info!), isTrue);
      expect(
        client.matchesCache(
          _movie.copyWith(title: 'A different film (2025)'),
          info,
        ),
        isFalse,
      );
      expect(client.matchesCache(_movie.copyWith(year: '2026'), info), isFalse);
      expect(
        http.headers.every(
          (header) => header.value(HttpHeaders.authorizationHeader) == null,
        ),
        isTrue,
      );
      expect(
        http.headers.first.value(HttpHeaders.userAgentHeader),
        contains('tvbro.online'),
      );
    },
  );

  test(
    'matches the IMDb ID from IPTV details without sending provider secrets',
    () async {
      final http = MetadataHttp((uri) {
        if (uri.host == 'en.wikipedia.org') return _article();
        if (uri.queryParameters['list'] == 'search') {
          expect(
            uri.queryParameters['srsearch'],
            'haswbstatement:P345=tt13654226',
          );
          return const MetadataReply({
            'query': {
              'search': [
                {'title': 'Q3'},
              ],
            },
          });
        }
        final film = _film('Q3', '2025');
        film['labels'] = {
          'en': {'value': 'The Gorge'},
        };
        expect(uri.queryParameters['ids'], 'Q3');
        return MetadataReply({
          'entities': {'Q3': film},
        });
      });
      final client = WikimediaClient(
        language: 'pl',
        http: http,
        requestInterval: Duration.zero,
      );
      addTearDown(client.close);
      final info = await client.search(
        _movie.copyWith(
          poster: 'https://iptv.example/poster.jpg',
          extra: {
            'cast': [
              {
                'name': 'Provider Actor',
                'photo_url': 'https://iptv.example/actor.jpg',
              },
            ],
            'details': {
              'info': {'imdb_id': 'tt13654226', 'password': 'fixture-secret'},
            },
          },
        ),
      );
      expect(info?.overview, 'A reusable synopsis.');
      expect(info?.poster, isNull);
      expect(info?.payload['cast'], isNull);
      expect(http.urls, hasLength(3));
      expect(
        http.urls.any((uri) => uri.toString().contains('fixture-secret')),
        isFalse,
      );
    },
  );

  test('leaves ambiguous titles unmatched', () async {
    final http = MetadataHttp(
      (uri) => uri.queryParameters['action'] == 'wbsearchentities'
          ? const MetadataReply({
              'search': [
                {'id': 'Q1'},
                {'id': 'Q2'},
              ],
            })
          : MetadataReply({
              'entities': {
                'Q1': _film('Q1', '2025'),
                'Q2': _film('Q2', '2025'),
              },
            }),
    );
    final client = WikimediaClient(http: http, requestInterval: Duration.zero);
    addTearDown(client.close);
    expect(await client.search(_movie), isNull);
    expect(http.urls, hasLength(2));
  });

  test('requires a year when IPTV provides only a title', () async {
    final http = MetadataHttp(
      (_) => throw StateError('Unexpected network call'),
    );
    final client = WikimediaClient(http: http);
    addTearDown(client.close);
    expect(await client.search(_movie.copyWith(title: 'Wąwóz')), isNull);
    expect(http.urls, isEmpty);
  });

  test(
    'hydrates missing IPTV cast portraits with licensed Commons files',
    () async {
      final http = MetadataHttp((uri) {
        if (uri.host == 'commons.wikimedia.org') {
          expect(uri.queryParameters['titles'], 'File:Actor photo.jpg');
          final reply = _poster('cc-by-sa-4.0');
          final page = ((reply.body as Map)['query'] as Map)['pages'][0] as Map;
          page['title'] = 'File:Actor photo.jpg';
          return reply;
        }
        if (uri.queryParameters['action'] == 'wbsearchentities') {
          return const MetadataReply({
            'search': [
              {'id': 'Q3'},
            ],
          });
        }
        if (uri.queryParameters['ids'] == 'Q88') {
          return MetadataReply({
            'entities': {
              'Q88': {
                'labels': {
                  'en': {'value': 'Actor Name'},
                },
                'claims': {
                  'P18': [_claim('Actor photo.jpg')],
                },
              },
            },
          });
        }
        return MetadataReply({
          'entities': {'Q3': _film('Q3', '2025')},
        });
      });
      final client = WikimediaClient(
        http: http,
        requestInterval: Duration.zero,
      );
      addTearDown(client.close);
      final item = _movie.copyWith(
        description: 'IPTV plot',
        poster: 'https://iptv.example/poster.jpg',
        year: '2025',
        durationSeconds: 200,
        extra: {
          'cast': 'Actor Name, IPTV Other Actor',
          'director': 'Director',
          'genres': 'Drama',
        },
      );
      final metadata = await client.search(item);
      expect(metadata?.payload['cast'], isNull);
      expect(
        metadata?.payload['cast_photos']['actor name'],
        containsPair('photo_url', 'https://thumb.wikimedia.org/poster.jpg'),
      );
      expect(
        metadata?.payload['cast_photos']['actor name']['commons_artist'],
        'Poster artist',
      );
      expect(metadata?.payload['cast_photos']['iptv other actor'], isNull);
    },
  );

  for (final (license, restrictions) in [
    ('fair-use', ''),
    ('cc-by-sa-4.0', 'restricted'),
  ]) {
    test(
      'does not display Commons images with $license $restrictions',
      () async {
        final http = MetadataHttp((uri) {
          if (uri.host == 'en.wikipedia.org') return _article();
          if (uri.host == 'commons.wikimedia.org') {
            return _poster(license, restrictions: restrictions);
          }
          if (uri.queryParameters['action'] == 'wbsearchentities') {
            return const MetadataReply({
              'search': [
                {'id': 'Q3'},
              ],
            });
          }
          return MetadataReply({
            'entities': {'Q3': _film('Q3', '2025')},
          });
        });
        final client = WikimediaClient(
          http: http,
          requestInterval: Duration.zero,
        );
        addTearDown(client.close);
        final info = await client.search(
          _movie.copyWith(extra: {'cast': 'IPTV Actor'}),
        );
        expect(info?.overview, 'A reusable synopsis.');
        expect(info?.poster, isNull);
        expect(info?.payload['commons_url'], isNull);
      },
    );
  }
}
