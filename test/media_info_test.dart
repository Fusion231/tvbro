import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/media_info.dart';
import 'package:iptvs/sources/source.dart';

void main() {
  MediaItem item(Map<String, dynamic> extra, {int? durationSeconds}) =>
      MediaItem(
        id: 'movie-1',
        title: 'Film',
        kind: ContentKind.movie,
        durationSeconds: durationSeconds,
        extra: extra,
      );

  test('reads nested Xtream details ahead of catalog fields', () {
    final info = MediaInfo.fromItem(
      item({
        'director': 'Catalog director',
        'genre': 'Old genre',
        'details': {
          'info': {
            'cast': 'Timothee Chalamet, Rebecca Ferguson; Timothee Chalamet\nOscar Isaac',
            'director': 'Denis Villeneuve',
            'genre': 'Science fiction / Adventure',
            'country': 'USA, Canada',
            'o_name': 'Dune',
            'releasedate': '2021-09-15',
            'duration_secs': '9300',
          },
        },
      }),
    );
    expect(info.cast.map((actor) => actor.name), [
      'Timothee Chalamet',
      'Rebecca Ferguson',
      'Oscar Isaac',
    ]);
    expect(info.directors, ['Denis Villeneuve']);
    expect(info.genres, ['Science fiction', 'Adventure']);
    expect(info.countries, ['USA', 'Canada']);
    expect(info.originalTitle, 'Dune');
    expect(info.releaseDate, '2021-09-15');
    expect(info.durationSeconds, 9300);
  });

  test('reads Stalker lists and duration from movie details', () {
    final info = MediaInfo.fromItem(
      item({
        'actors': ['Amy Adams', 'Jeremy Renner', 'amy adams'],
        'details': {
          'director': ['Denis Villeneuve'],
          'genres': [
            {'name': 'Drama'},
            {'name': 'Science fiction'},
          ],
          'country': 'Canada',
          'released': '2016-11-11',
          'duration': '01:56:30',
        },
      }, durationSeconds: 60),
    );
    expect(info.cast.map((actor) => actor.name), [
      'Amy Adams',
      'Jeremy Renner',
    ]);
    expect(info.directors, ['Denis Villeneuve']);
    expect(info.genres, ['Drama', 'Science fiction']);
    expect(info.countries, ['Canada']);
    expect(info.releaseDate, '2016-11-11');
    expect(info.durationSeconds, 6990);
  });

  test('TMDB credits add deduplicated roles and fill missing metadata', () {
    final info = MediaInfo.fromItem(
      item({
        'cast': 'Amy Adams',
        'director': 'null',
        'details': {
          'info': {'genre': ' ', 'duration_secs': 0},
        },
        'metadata': {
          'tmdb': {
            'credits': {
              'cast': [
                {
                  'name': 'Amy Adams',
                  'character': 'Louise Banks',
                  'profile_path': '/amy.jpg',
                },
                {'name': 'amy adams', 'character': 'Louise Banks'},
                {'name': 'Jeremy Renner', 'character': 'Ian Donnelly'},
              ],
              'crew': [
                {'name': 'Someone Else', 'job': 'Producer'},
                {'name': 'Denis Villeneuve', 'job': 'Director'},
              ],
            },
            'created_by': [
              {'id': 1, 'name': 'Jane Creator'},
            ],
            'genres': [
              {'id': 18, 'name': 'Drama'},
            ],
            'production_countries': [
              {'iso_3166_1': 'US', 'name': 'United States'},
            ],
            'original_title': 'Arrival',
            'release_date': '2016-11-10',
            'runtime': 116,
          },
        },
      }),
    );
    expect(info.cast.map((actor) => actor.name), [
      'Amy Adams',
      'Jeremy Renner',
    ]);
    expect(info.cast.map((actor) => actor.role), [
      'Louise Banks',
      'Ian Donnelly',
    ]);
    expect(info.cast.map((actor) => actor.photoUrl), [
      'https://image.tmdb.org/t/p/w185/amy.jpg',
      null,
    ]);
    expect(info.directors, ['Denis Villeneuve']);
    expect(info.creators, ['Jane Creator']);
    expect(info.genres, ['Drama']);
    expect(info.countries, ['United States']);
    expect(info.originalTitle, 'Arrival');
    expect(info.releaseDate, '2016-11-10');
    expect(info.durationSeconds, 6960);
  });

  test('keeps provider cast photos and ignores invalid image values', () {
    final info = MediaInfo.fromItem(
      item({
        'cast': [
          {'name': 'First actor', 'photo_url': 'https://provider.test/first.jpg'},
          {'name': 'Second actor', 'image': 'http://provider.test/second.jpg'},
          {'name': 'Third actor', 'profile_path': null},
          {'name': 'Fourth actor', 'photo_url': 'file:///private/photo.jpg'},
          {'name': 'Fifth actor', 'image': '/relative.jpg'},
        ],
        'metadata': {
          'tmdb': {
            'credits': {
              'cast': [
                {'name': 'first actor', 'profile_path': '/other.jpg'},
                {'name': 'Third actor', 'profile_path': '/third.jpg'},
              ],
            },
          },
        },
      }),
    );
    expect(info.cast.map((actor) => actor.photoUrl), [
      'https://provider.test/first.jpg',
      'http://provider.test/second.jpg',
      'https://image.tmdb.org/t/p/w185/third.jpg',
      null,
      null,
    ]);
  });

  test('uses series original title, air date and episode runtime', () {
    final info = MediaInfo.fromItem(
      item({
        'metadata': {
          'tvdb': {
            'original_name': 'Original series',
            'first_air_date': '2024-04-01',
            'origin_country': ['PL'],
            'episode_run_time': [0, 45],
          },
        },
      }),
    );
    expect(info.originalTitle, 'Original series');
    expect(info.releaseDate, '2024-04-01');
    expect(info.countries, ['PL']);
    expect(info.durationSeconds, 2700);
  });

  test(
    'ignores malformed, placeholder and unrelated metadata without dumps',
    () {
      final info = MediaInfo.fromItem(
        item({
          'cast': [
            false,
            123,
            {'id': 7},
            '0',
            'null',
            '[]',
          ],
          'director': {'id': 8},
          'genre': [
            12,
            {'id': 18},
            'N/A',
          ],
          'country': false,
          'original_title': {'title': 'Hidden title'},
          'release_date': 'unknown',
          'duration_secs': -1,
          'duration': '01:99:00',
          'details': {
            'episodes': [
              {'cast': 'Episode actor', 'runtime': 90},
            ],
          },
          'unknown': {'cast': 'Unrelated actor'},
          'metadata': {
            'unknown': {'cast': 'Unknown provider actor'},
          },
        }),
      );
      expect(info.cast, isEmpty);
      expect(info.directors, isEmpty);
      expect(info.creators, isEmpty);
      expect(info.genres, isEmpty);
      expect(info.countries, isEmpty);
      expect(info.originalTitle, isNull);
      expect(info.releaseDate, isNull);
      expect(info.durationSeconds, isNull);
    },
  );

  test('duration units and item duration fallback are preserved', () {
    for (final entry in <Map<String, dynamic>, int>{
      {'duration_seconds': '120'}: 120,
      {'duration': '120'}: 120,
      {'duration': '02:30'}: 150,
      {'runtime': '120'}: 7200,
      {'runtime': 0}: 600,
    }.entries) {
      expect(
        MediaInfo.fromItem(item(entry.key, durationSeconds: 600))
            .durationSeconds,
        entry.value,
      );
    }
  });
}
