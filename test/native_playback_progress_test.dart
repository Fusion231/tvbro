import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/player/player_screen.dart';
import 'package:iptvs/sources/source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late AppDatabase db;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    directory = Directory.systemTemp.createTempSync('tvbro_native_progress');
    db = await AppDatabase.openAt('${directory.path}/test.db');
  });

  tearDown(() async {
    await db.close();
    directory.deleteSync(recursive: true);
  });

  PlaybackContext context({ContentKind kind = ContentKind.episode}) =>
      PlaybackContext(
        db: db,
        sourceId: 'source',
        kind: kind,
        itemId: 'episode',
      );

  Map<String, Object?> sample({
    int openId = 7,
    Object? position = 30000,
    Object? duration = 2700000,
    bool flush = false,
  }) => {
    'nativeOpenId': openId,
    'positionMs': position,
    'durationMs': duration,
    'flush': flush,
  };

  test(
    'periodic and sleep checkpoints survive reopening without player exit',
    () async {
      await persistNativePlaybackProgress(context(), sample(), nativeOpenId: 7);
      await persistNativePlaybackProgress(
        context(),
        sample(position: 75000),
        nativeOpenId: 7,
      );
      await db.close();
      db = await AppDatabase.openAt('${directory.path}/test.db');

      final saved = await db.readPlaybackPosition(
        'source',
        ContentKind.episode,
        'episode',
      );
      expect(saved!.position, const Duration(seconds: 75));
      final pending = await db.readPlaybackOutbox();
      expect(pending.single.positionMs, 75000);
      expect(pending.single.removed, isFalse);
    },
  );

  test(
    'only a committed lifecycle checkpoint requests an immediate upload',
    () async {
      var checkpoints = 0;
      final subscription = db.playbackCheckpointed.listen((_) => checkpoints++);
      await persistNativePlaybackProgress(context(), sample(), nativeOpenId: 7);
      await Future<void>.delayed(Duration.zero);
      expect(checkpoints, 0);

      final savedAtCheckpoint = db.playbackCheckpointed.first.then(
        (_) async => (
          await db.readPlaybackPosition(
            'source',
            ContentKind.episode,
            'episode',
          ),
          await db.readPlaybackOutbox(),
        ),
      );
      await persistNativePlaybackProgress(
        context(),
        sample(position: 75000, flush: true),
        nativeOpenId: 7,
      );
      final (saved, pending) = await savedAtCheckpoint;
      expect(saved!.position, const Duration(seconds: 75));
      expect(pending.single.positionMs, 75000);
      expect(checkpoints, 1);
      await subscription.cancel();
    },
  );

  test('failed local checkpoint does not request a cloud upload', () async {
    final failing = _FailingPlaybackDatabase();
    await expectLater(
      persistNativePlaybackProgress(
        PlaybackContext(
          db: failing,
          sourceId: 'source',
          kind: ContentKind.episode,
          itemId: 'episode',
        ),
        sample(flush: true),
        nativeOpenId: 7,
      ),
      throwsStateError,
    );
    expect(failing.checkpointed, isFalse);
  });

  test('late sessions, live playback and malformed samples cannot overwrite progress', () async {
    var checkpoints = 0;
    final subscription = db.playbackCheckpointed.listen((_) => checkpoints++);
    await persistNativePlaybackProgress(context(), sample(), nativeOpenId: 7);
    for (final value in [
      sample(openId: 6, position: 90000, flush: true),
      sample(position: -1, flush: true),
      sample(position: 9999, flush: true),
      sample(duration: 0, flush: true),
      sample(position: '90000', flush: true),
    ]) {
      await persistNativePlaybackProgress(context(), value, nativeOpenId: 7);
    }
    await persistNativePlaybackProgress(
      null,
      sample(flush: true),
      nativeOpenId: 7,
    );
    await persistNativePlaybackProgress(
      context(kind: ContentKind.live),
      sample(flush: true),
      nativeOpenId: 7,
    );
    final saved = await db.readPlaybackPosition(
      'source',
      ContentKind.episode,
      'episode',
    );
    expect(saved!.position, const Duration(seconds: 30));
    expect(
      await db.readPlaybackPosition('source', ContentKind.live, 'episode'),
      isNull,
    );
    expect((await db.readPlaybackOutbox()).single.positionMs, 30000);
    await Future<void>.delayed(Duration.zero);
    expect(checkpoints, 0);
    await subscription.cancel();
  });
}

class _FailingPlaybackDatabase implements AppDatabase {
  bool checkpointed = false;

  @override
  Future<void> savePlaybackPosition(
    String sourceId,
    ContentKind kind,
    String itemId, {
    required Duration position,
    required Duration duration,
  }) async => throw StateError('storage unavailable');

  @override
  void notifyPlaybackCheckpoint() => checkpointed = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
