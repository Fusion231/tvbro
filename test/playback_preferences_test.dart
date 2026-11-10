import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/player/buffer_preset.dart';
import 'package:iptvs/player/playback_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test(
    'choices survive reopening and stay scoped to source and content',
    () async {
      final store = PlaybackPreferencesStore();
      await store.write(
        'provider-a',
        'live:42',
        const PlaybackPreferences(
          quality: '720:2500000',
          buffer: BufferPreset.high,
          adaptiveBuffer: true,
          matchRefreshRate: true,
          aspect: 'Fit',
        ),
      );
      final reopened = await PlaybackPreferencesStore().read(
        'provider-a',
        'live:42',
      );
      expect(reopened.quality, '720:2500000');
      expect(reopened.buffer, BufferPreset.high);
      expect(reopened.adaptiveBuffer, isTrue);
      expect(reopened.matchRefreshRate, isTrue);
      expect(reopened.aspect, 'Fit');
      for (final identity in [
        ('provider-b', 'live:42'),
        ('provider-a', 'live:43'),
        ('provider-a', 'movie:42'),
      ]) {
        final other = await store.read(identity.$1, identity.$2);
        expect(other.quality, 'auto');
        expect(other.buffer, isNull);
        expect(other.adaptiveBuffer, isFalse);
        expect(other.matchRefreshRate, isFalse);
      }
    },
  );

  test(
    'reset restores inherited defaults without changing another channel',
    () async {
      final store = PlaybackPreferencesStore();
      for (final id in ['live:a', 'live:b']) {
        await store.write(
          'source',
          id,
          const PlaybackPreferences(quality: '480:0'),
        );
      }
      await store.write('source', 'live:a', const PlaybackPreferences());
      expect((await store.read('source', 'live:a')).quality, 'auto');
      expect((await store.read('source', 'live:a')).adaptiveBuffer, isFalse);
      expect((await store.read('source', 'live:b')).quality, '480:0');
    },
  );

  test(
    'invalid stored JSON or types do not prevent opening a channel',
    () async {
      final storage = const FlutterSecureStorage();
      for (final raw in ['{', '[]', 'null', '{"quality":42,"buffer":false}']) {
        await storage.write(
          key: PlaybackPreferencesStore.key('src', 'live:1'),
          value: raw,
        );
        expect(
          (await PlaybackPreferencesStore(
            storage,
          ).read('src', 'live:1')).quality,
          'auto',
        );
      }
    },
  );

  test('compound identities cannot collide through separators', () {
    expect(
      PlaybackPreferencesStore.key('a:b', 'c'),
      isNot(PlaybackPreferencesStore.key('a', 'b:c')),
    );
  });

  const tracks = [
    VideoQuality(id: 'low', height: 480, bitrate: 1000000),
    VideoQuality(id: 'mid', height: 720, bitrate: 2500000),
    VideoQuality(id: 'high', height: 1080, bitrate: 5000000),
  ];
  test('restores a real rendition despite changed session track IDs', () {
    expect(selectVideoQuality(tracks, '720:2500000')?.id, 'mid');
    expect(selectVideoQuality(tracks, 'auto'), isNull);
  });
  test('removed rendition falls back down, then lowest available', () {
    expect(selectVideoQuality(tracks, '900:4000000')?.id, 'mid');
    expect(selectVideoQuality(tracks, '360:500000')?.id, 'low');
    expect(selectVideoQuality([], '720:2500000'), isNull);
    expect(selectVideoQuality(tracks, 'invalid'), isNull);
  });
}
