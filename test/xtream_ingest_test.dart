import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/xtream_source.dart';

import 'support/workload_fixtures.dart';

void main() {
  test('normalizes legacy and JSON artwork arrays without splitting URLs', () {
    const url = 'https://images.test/backdrop.jpg?token=a,b&size=1280';

    expect(normalizeImageUrl('  $url  '), url);
    expect(
      normalizeImageUrl('[null, invalid, $url, https://images.test/b.jpg]'),
      url,
    );
    expect(normalizeImageUrl(jsonEncode(['null', '', url])), url);
    expect(normalizeImageUrl('[null, invalid]'), isNull);
  });

  group('decodeLiveChannelsBytes (one-pass get_live_streams worker)', () {
    test('rejects non-list payloads while accepting an empty catalog', () {
      for (final payload in <Object?>[
        null,
        {},
        {'error': 'unavailable'},
        'error',
      ]) {
        final bytes = Uint8List.fromList(utf8.encode(jsonEncode(payload)));
        expect(() => mapLiveChannels(payload), throwsFormatException);
        expect(() => decodeLiveChannelsBytes(bytes), throwsFormatException);
      }
      expect(mapLiveChannels([]), isEmpty);
      expect(
        decodeLiveChannelsBytes(Uint8List.fromList(utf8.encode('[]'))),
        isEmpty,
      );
    });

    test('matches the two-step decode+map pipeline field-by-field', () {
      const itemCount = 500;
      final bytes = WorkloadFixtures.xtreamLiveJson(itemCount);

      final onePass = decodeLiveChannelsBytes(bytes);
      final twoStep = mapLiveChannels(
        jsonDecode(utf8.decode(bytes, allowMalformed: true)),
      );

      expect(onePass, hasLength(itemCount));
      expect(twoStep, hasLength(itemCount));

      // Even index: tv_archive on, 7-day duration. Odd index: archive off.
      for (final channels in [onePass, twoStep]) {
        final even = channels[0];
        expect(even.id, '1');
        expect(even.name, 'Live 0');
        expect(even.number, isNull);
        expect(even.logo, 'https://images.example.invalid/live/0.png');
        expect(even.categoryId, '0');
        expect(even.archiveDays, 7);
        expect(even.hasArchive, isTrue);
        expect(even.extra['streamId'], '1');
        expect(even.extra['tvgId'], 'channel.0');

        final odd = channels[1];
        expect(odd.id, '2');
        expect(odd.name, 'Live 1');
        expect(odd.categoryId, '1');
        expect(odd.archiveDays, 0);
        expect(odd.hasArchive, isFalse);
        expect(odd.extra['tvgId'], 'channel.1');
      }
    });

    test('drops non-map rows without throwing', () {
      final rows = <Object?>[
        for (var i = 0; i < 20; i++) {'stream_id': i + 1, 'name': 'Live $i'},
        null,
        'not-a-channel',
        42,
        true,
      ];
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode(rows)));

      final channels = decodeLiveChannelsBytes(bytes);

      expect(channels, hasLength(20));
      expect(channels.map((c) => c.id), everyElement(isNotEmpty));
    });

    test(
      'a malformed JSON payload throws FormatException, same as jsonDecode',
      () {
        final bytes = Uint8List.fromList(utf8.encode('{not valid json'));
        expect(() => decodeLiveChannelsBytes(bytes), throwsFormatException);
        expect(() => jsonDecode(utf8.decode(bytes)), throwsFormatException);
      },
    );
  });

  group(
    'decodeMediaItemsBytes (one-pass get_vod_streams/get_series worker)',
    () {
      test('movie payload matches the two-step decode+map pipeline', () {
        const itemCount = 500;
        final bytes = WorkloadFixtures.xtreamVodJson(itemCount);
        final args = XtreamMediaDecodeArgs(bytes, ContentKind.movie);

        final onePass = decodeMediaItemsBytes(args);
        final twoStep = mapMediaItemsFromDecoded(
          jsonDecode(utf8.decode(bytes, allowMalformed: true)),
          ContentKind.movie,
        );

        expect(onePass, hasLength(itemCount));
        expect(twoStep, hasLength(itemCount));

        for (final items in [onePass, twoStep]) {
          final first = items[0];
          expect(first.id, '1');
          expect(first.title, 'Movie 0');
          expect(first.kind, ContentKind.movie);
          expect(first.categoryId, '0');
          expect(first.poster, 'https://images.example.invalid/movie/0.png');
          expect(first.rating, 5.0);
          expect(first.extra['container_extension'], 'mkv');
        }
      });

      test('series payload matches the two-step decode+map pipeline', () {
        const itemCount = 500;
        final bytes = WorkloadFixtures.xtreamSeriesJson(itemCount);
        final args = XtreamMediaDecodeArgs(bytes, ContentKind.series);

        final onePass = decodeMediaItemsBytes(args);
        final twoStep = mapMediaItemsFromDecoded(
          jsonDecode(utf8.decode(bytes, allowMalformed: true)),
          ContentKind.series,
        );

        expect(onePass, hasLength(itemCount));
        expect(twoStep, hasLength(itemCount));

        for (final items in [onePass, twoStep]) {
          final first = items[0];
          expect(first.id, '1');
          expect(first.title, 'Series 0');
          expect(first.kind, ContentKind.series);
          expect(first.categoryId, '0');
          expect(first.poster, 'https://images.example.invalid/series/0.png');
          expect(first.rating, 5.0);
        }
      });

      test('selects the first valid URL from catalog artwork lists', () {
        for (final kind in [ContentKind.movie, ContentKind.series]) {
          final bytes = Uint8List.fromList(
            utf8.encode(
              jsonEncode([
                {
                  'stream_id': 1,
                  'series_id': 1,
                  'name': 'Artwork lists',
                  'stream_icon': 'null',
                  'cover': [null, '', '  https://images.test/poster.jpg  '],
                  'backdrop_path': [
                    null,
                    '',
                    'null',
                    'not a URL',
                    'ftp://images.test/backdrop.jpg',
                    'https:///missing-host.jpg',
                    '  https://images.test/first.jpg  ',
                    'https://images.test/second.jpg',
                  ],
                },
              ]),
            ),
          );

          final item = decodeMediaItemsBytes(
            XtreamMediaDecodeArgs(bytes, kind),
          ).single;

          expect(item.poster, 'https://images.test/poster.jpg');
          expect(item.backdrop, 'https://images.test/first.jpg');
        }
      });

      test('skips invalid artwork fields and preserves scalar URLs', () {
        final items = mapMediaItemsFromDecoded([
          {
            'stream_id': 1,
            'stream_icon': 'http://images.test/poster.jpg?size=500',
            'backdrop_path': ['', 'null', false, 0],
            'backdrop': 'invalid',
            'cover_big': 'https://images.test/fallback.jpg',
          },
          {
            'stream_id': 2,
            'stream_icon': ['', 'null'],
            'backdrop_path': [],
          },
        ], ContentKind.movie);

        expect(items[0].poster, 'http://images.test/poster.jpg?size=500');
        expect(items[0].backdrop, 'https://images.test/fallback.jpg');
        expect(items[1].poster, isNull);
        expect(items[1].backdrop, isNull);
      });

      test('drops non-map rows and rows without an id, never throws', () {
        final rows = <Object?>[
          for (var i = 0; i < 15; i++)
            {'stream_id': i + 1, 'name': 'Movie $i', 'category_id': 'cat-a'},
          // No id-shaped field at all -> filtered by the empty-id guard.
          {'name': 'No id fields', 'category_id': 'cat-a'},
          null,
          'not-a-movie',
        ];
        final bytes = Uint8List.fromList(utf8.encode(jsonEncode(rows)));
        final args = XtreamMediaDecodeArgs(bytes, ContentKind.movie);

        final items = decodeMediaItemsBytes(args);

        expect(items, hasLength(15));
        expect(items.map((i) => i.id), everyElement(isNotEmpty));
      });

      test(
        'a malformed JSON payload throws FormatException, same as jsonDecode',
        () {
          final bytes = Uint8List.fromList(utf8.encode('[1, 2,'));
          final args = XtreamMediaDecodeArgs(bytes, ContentKind.movie);
          expect(() => decodeMediaItemsBytes(args), throwsFormatException);
          expect(() => jsonDecode(utf8.decode(bytes)), throwsFormatException);
        },
      );
    },
  );

  group('XtreamSource artwork details', () {
    test('reads episode preview metadata from nested info', () async {
      final source = XtreamSource(
        sourceId: 'test',
        host: 'http://host.tv',
        username: 'u',
        password: 'p',
      );
      addTearDown(source.dispose);

      final episodes = await source.mediaItems(
        ContentKind.episode,
        parent: const MediaItem(
          id: 'series:season:2',
          title: 'Season 2',
          kind: ContentKind.season,
          poster: 'https://images.test/season.jpg',
          seasonNumber: 2,
          extra: {
            'episodes': [
              {
                'id': '1',
                'title': 'Nested episode',
                'episode_num': 1,
                'info': {
                  'movie_image': ['', 'https://images.test/episode.jpg'],
                  'plot': 'Episode synopsis',
                  'duration_secs': 1495,
                },
              },
              {
                'id': '2',
                'title': 'Flat episode',
                'movie_image': 'https://images.test/flat.jpg',
                'plot': 'Flat synopsis',
                'duration': '00:22:30',
                'info': {
                  'movie_image': 'https://images.test/unused.jpg',
                  'plot': 'Unused synopsis',
                  'duration_secs': 1,
                },
              },
              {'id': '3', 'title': 'No episode metadata'},
            ],
          },
        ),
      );

      expect(episodes, hasLength(3));
      expect(episodes[0].poster, 'https://images.test/episode.jpg');
      expect(episodes[0].description, 'Episode synopsis');
      expect(episodes[0].durationSeconds, 1495);
      expect(episodes[0].seasonNumber, 2);
      expect(episodes[0].episodeNumber, 1);
      expect(episodes[1].poster, 'https://images.test/flat.jpg');
      expect(episodes[1].description, 'Flat synopsis');
      expect(episodes[1].durationSeconds, 1350);
      expect(episodes[2].poster, 'https://images.test/season.jpg');
      expect(episodes[2].description, isNull);
      expect(episodes[2].durationSeconds, isNull);
    });

    test('normalizes detail artwork lists for movies and series', () async {
      for (final kind in [ContentKind.movie, ContentKind.series]) {
        final source = XtreamSource(
          sourceId: 'test',
          host: 'http://host.tv',
          username: 'u',
          password: 'p',
          debugApi: (_) async => {
            'info': {
              'movie_image': ['', 'https://images.test/details-poster.jpg'],
              'backdrop_path': [
                'null',
                'https://images.test/details-backdrop.jpg',
                'https://images.test/second-backdrop.jpg',
              ],
            },
          },
        );
        addTearDown(source.dispose);

        final item = await source.mediaDetails(
          MediaItem(id: '1', title: 'Artwork details', kind: kind),
        );

        expect(item.poster, 'https://images.test/details-poster.jpg');
        expect(item.backdrop, 'https://images.test/details-backdrop.jpg');
      }
    });

    test('keeps catalog artwork when detail artwork is invalid', () async {
      final source = XtreamSource(
        sourceId: 'test',
        host: 'http://host.tv',
        username: 'u',
        password: 'p',
        debugApi: (_) async => {
          'info': {
            'movie_image': ['null', 'invalid'],
            'backdrop_path': ['', 'ftp://images.test/backdrop.jpg'],
          },
        },
      );
      addTearDown(source.dispose);

      final item = await source.mediaDetails(
        const MediaItem(
          id: '1',
          title: 'Catalog artwork',
          kind: ContentKind.movie,
          poster: 'https://images.test/catalog-poster.jpg',
          backdrop: 'https://images.test/catalog-backdrop.jpg',
        ),
      );

      expect(item.poster, 'https://images.test/catalog-poster.jpg');
      expect(item.backdrop, 'https://images.test/catalog-backdrop.jpg');
    });
  });
}
