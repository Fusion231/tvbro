import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/player/channel_variants.dart';
import 'package:iptvs/sources/source.dart';

Channel channel(String id, String name) => Channel(id: id, name: name);

void main() {
  test('only lower renditions of the same named feed qualify', () {
    final current = channel('a', 'News PL FHD');
    final choices = lighterChannelVariants(current, [
      current,
      channel('b', 'News PL HD'),
      channel('c', 'News PL SD'),
      channel('d', 'News PL 4K'),
      channel('e', 'News DE HD'),
      channel('f', 'News PL +1 HD'),
      channel('g', 'News PL 2 HD'),
      channel('h', 'News PL HEVC HD'),
      channel('i', 'News PL'),
    ]);
    expect(choices.map((c) => c.id), ['b', 'c']);
  });
  test(
    'uses measured resolution when the current name has no quality marker',
    () {
      final current = channel('a', 'News');
      final channels = [channel('b', 'News HD'), channel('c', 'News FHD')];
      expect(lighterChannelVariants(current, channels), isEmpty);
      expect(
        lighterChannelVariants(
          current,
          channels,
          currentHeight: 1080,
        ).map((c) => c.id),
        ['b'],
      );
    },
  );
  test(
    'brackets and case normalize without changing language or timeshift',
    () {
      expect(channelVariantIdentity('News  [HD] PL'), 'news pl');
      expect(channelVariantIdentity('News (FHD) PL'), 'news pl');
      expect(channelVariantIdentity('News +1 HD PL'), 'news +1 pl');
      expect(channelVariantIdentity('HDTV PL'), 'hdtv pl');
      expect(channelResolution('News 1080i'), 1080);
      expect(channelResolution('News UHD'), 2160);
      expect(channelResolution('News'), isNull);
    },
  );
}
