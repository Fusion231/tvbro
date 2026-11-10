import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/player/player_screen.dart';
import 'package:iptvs/sources/source.dart';

void main() {
  const episodes = [
    MediaItem(
      id: 'episode',
      title: 'Episode',
      kind: ContentKind.episode,
      poster: 'https://art.example/poster.jpg',
      backdrop: 'http://art.example/backdrop.jpg',
    ),
  ];

  test(
    'native artwork accepts only this series exact poster/backdrop URLs',
    () {
      expect(
        isPlayerEpisodeArtworkUrl('https://art.example/poster.jpg', episodes),
        isTrue,
      );
      expect(
        isPlayerEpisodeArtworkUrl('http://art.example/backdrop.jpg', episodes),
        isTrue,
      );
      expect(
        isPlayerEpisodeArtworkUrl(
          'https://art.example/poster.jpg?other',
          episodes,
        ),
        isFalse,
      );
      expect(
        isPlayerEpisodeArtworkUrl('https://other.example/poster.jpg', episodes),
        isFalse,
      );
      expect(
        isPlayerEpisodeArtworkUrl('https://art.example/poster.jpg', const []),
        isFalse,
      );
    },
  );

  test(
    'native artwork rejects non-HTTP or credential-bearing episode images',
    () {
      for (final url in [
        'file:///private/image.jpg',
        'content://images/image.jpg',
        'data:image/png;base64,AA',
        '//art.example/image.jpg',
        'http:///image.jpg',
        'https://user:password@art.example/image.jpg',
        'https://[bad',
        '',
      ]) {
        expect(
          isPlayerEpisodeArtworkUrl(url, [
            MediaItem(
              id: 'invalid',
              title: 'Invalid',
              kind: ContentKind.episode,
              poster: url,
            ),
          ]),
          isFalse,
          reason: url,
        );
      }
    },
  );
}
