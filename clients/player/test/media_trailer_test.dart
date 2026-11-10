import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/media_trailer.dart';
import 'package:iptvs/sources/source.dart';

void main() {
  const youtubeId = 'Abc_123-xy0';
  final youtubeUri = Uri.https('www.youtube.com', '/watch', {'v': youtubeId});

  MediaItem item({
    String title = 'Diuna',
    String? year = '2021',
    Map<String, dynamic> extra = const {},
  }) => MediaItem(
    id: 'movie-1',
    title: title,
    kind: ContentKind.movie,
    year: year,
    extra: extra,
  );

  test('reads trailer fields in catalog, Xtream and Stalker details', () {
    for (final extra in <Map<String, dynamic>>[
      {'youtube_trailer': youtubeId},
      {'trailer_url': 'https://youtu.be/$youtubeId'},
      {
        'details': {'trailer': 'https://youtu.be/$youtubeId'},
      },
      {
        'details': {
          'info': {'youtube_trailer': youtubeId},
        },
      },
      {
        'metadata': {
          'tvdb': {'trailer_url': 'https://youtu.be/$youtubeId'},
        },
      },
    ]) {
      expect(
        mediaTrailerLink(item(extra: extra)),
        youtubeUri,
        reason: '$extra',
      );
      expect(mediaTrailerUri(item(extra: extra)), youtubeUri);
    }
  });

  test('normalizes supported YouTube URLs and bare IDs', () {
    for (final value in [
      ' $youtubeId ',
      'https://www.youtube.com/watch?v=$youtubeId&feature=shared',
      'https://m.youtube.com/watch?v=$youtubeId',
      'http://youtu.be/$youtubeId?t=30',
      'https://youtube.com/embed/$youtubeId',
      'https://www.youtube-nocookie.com/embed/$youtubeId',
      'https://www.youtube.com/shorts/$youtubeId',
      'https://www.youtube.com/live/$youtubeId',
      'www.youtube.com/watch?v=$youtubeId',
      'youtu.be/$youtubeId',
    ]) {
      expect(
        mediaTrailerLink(item(extra: {'youtube_trailer': value})),
        youtubeUri,
        reason: value,
      );
    }
  });

  test('preserves an explicit external HTTP or HTTPS trailer URL', () {
    for (final scheme in ['https', 'http']) {
      final uri = Uri.parse('$scheme://media.example/trailer.mp4?lang=pl');
      expect(mediaTrailerUri(item(extra: {'trailer': '$uri'})), uri);
    }
  });

  test('skips invalid values and continues to a usable trailer field', () {
    expect(
      mediaTrailerLink(
        item(
          extra: {
            'youtube_trailer': false,
            'trailer_url': 'javascript:alert(1)',
            'details': {'trailer': youtubeId},
          },
        ),
      ),
      youtubeUri,
    );
  });

  test('invalid schemes, URLs and YouTube IDs use search instead', () {
    for (final value in <Object?>[
      null,
      false,
      123,
      <String, dynamic>{'url': 'https://youtu.be/$youtubeId'},
      '',
      'null',
      'not a video',
      'javascript:alert(1)',
      'file:///trailer.mp4',
      'intent://trailer',
      '//media.example/trailer.mp4',
      'https:///trailer.mp4',
      'https://user:password@media.example/trailer.mp4',
      'https://media.example/trailer clip.mp4',
      'https://youtube.com/watch?v=short',
      'https://youtube.com/watch?v=',
      'https://youtube.com/watch?v=%FF',
      'https://youtu.be/%FF',
      'https://youtube.com/results?search_query=trailer',
      'https://youtu.be/',
    ]) {
      final media = item(extra: {'trailer': value});
      expect(mediaTrailerLink(media), isNull, reason: '$value');
      expect(
        mediaTrailerUri(media).queryParameters['search_query'],
        'Diuna 2021 zwiastun PL',
        reason: '$value',
      );
    }
  });

  test('ignores main media URLs and unrelated nested trailer fields', () {
    final media = item(
      extra: {
        'url': 'https://media.example/movie.mp4',
        'cmd': 'ffmpeg https://media.example/movie.mp4',
        'episodes': [
          {'trailer': youtubeId},
        ],
        'unrelated': {'trailer': youtubeId},
      },
    );
    expect(mediaTrailerLink(media), isNull);
    expect(mediaTrailerUri(media).path, '/results');
  });

  test('encodes the title and extracts a year from provider release dates', () {
    final uri = mediaTrailerUri(
      item(title: '  Film:   Łódź & Kraków?  ', year: '2024-10-22'),
    );
    expect(uri.host, 'www.youtube.com');
    expect(uri.path, '/results');
    expect(uri.queryParameters, {
      'search_query': 'Film: Łódź & Kraków? 2024 zwiastun PL',
    });
  });

  test('search handles missing years and avoids repeating a title year', () {
    expect(
      mediaTrailerUri(item(year: null)).queryParameters['search_query'],
      'Diuna zwiastun PL',
    );
    expect(
      mediaTrailerUri(item(year: 'unknown')).queryParameters['search_query'],
      'Diuna zwiastun PL',
    );
    expect(
      mediaTrailerUri(item(title: 'Diuna (2021)'))
          .queryParameters['search_query'],
      'Diuna (2021) zwiastun PL',
    );
  });
}
