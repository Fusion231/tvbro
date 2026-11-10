import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/dvr/dvr_models.dart';
import 'package:iptvs/dvr/hls_playlist.dart';

void main() {
  final base = Uri.parse('https://example.test/media/live.m3u8');

  test('resolves variants and keeps a muxed audio variant', () {
    final playlist = HlsPlaylist.parse('''#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",URI="audio.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=3000,AUDIO="a"
separate.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2000
video.m3u8
''', base);
    expect(playlist.variant, base.resolve('video.m3u8'));
  });

  test(
    'tracks byte ranges, discontinuities, AES IV and initialization map',
    () {
      final playlist = HlsPlaylist.parse('''#EXTM3U
#EXT-X-TARGETDURATION:2
#EXT-X-MEDIA-SEQUENCE:137
#EXT-X-DISCONTINUITY-SEQUENCE:4
#EXT-X-MAP:URI="init.mp4",BYTERANGE="8@0"
#EXT-X-BYTERANGE:10@4
#EXTINF:2,
part.mp4
#EXT-X-DISCONTINUITY
#EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0xA
#EXT-X-BYTERANGE:12
#EXTINF:1.5,
part.mp4
#EXT-X-ENDLIST
''', base);
      expect(playlist.ended, isTrue);
      expect(playlist.segments.first.sequence, 137);
      expect(playlist.segments.first.map!.range!.length, 8);
      expect(playlist.segments.last.range!.offset, 14);
      expect(playlist.segments.last.discontinuitySequence, 5);
      expect(playlist.segments.last.discontinuity, isTrue);
      expect(playlist.segments.last.key!.iv, '0xA');
    },
  );

  test(
    'rejects encryption and resources that cannot be captured faithfully',
    () {
      for (final body in [
        '#EXT-X-KEY:METHOD=SAMPLE-AES,URI="key"',
        '#EXT-X-KEY:METHOD=AES-128,URI="key"\n#EXT-X-MAP:URI="init"',
        '#EXT-X-MAP:URI="file:///secrets"',
        '#EXTINF:NaN,\nsegment.ts',
        '#EXT-X-BYTERANGE:2\n#EXTINF:2,\nsegment.ts',
        '#EXT-X-GAP',
      ]) {
        expect(
          () => HlsPlaylist.parse('#EXTM3U\n$body', base),
          throwsA(isA<DvrException>()),
        );
      }
    },
  );

  test('malformed locator errors never repeat provider credentials', () {
    try {
      HlsPlaylist.parse('#EXTM3U\n#EXTINF:2,\nhttp://[provider-secret', base);
      fail('expected malformed locator');
    } catch (error) {
      expect(error, isA<DvrException>());
      expect(error.toString(), isNot(contains('provider-secret')));
    }
  });
}
