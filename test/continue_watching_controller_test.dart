import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/screens/media_tab_controller.dart';
import 'package:iptvs/sources/demo_source.dart';
import 'package:iptvs/sources/source.dart';

class _ResumeDatabase implements AppDatabase {
  final reads = <Completer<List<PlaybackPosition>>>[];
  final mediaReads = <List<String>>[];
  final removed = <String>[];
  Completer<List<MediaItem>>? mediaGate;

  @override
  Future<List<PlaybackPosition>> readRecentPositions(
    String sourceId, {
    int limit = 20,
  }) {
    final read = Completer<List<PlaybackPosition>>();
    reads.add(read);
    return read.future;
  }

  @override
  Future<List<MediaItem>> readMediaItemsByIds(
    String sourceId,
    ContentKind kind,
    List<String> ids,
  ) {
    mediaReads.add(ids);
    return mediaGate?.future ??
        Future.value([
          for (final id in ids) MediaItem(id: id, title: id, kind: kind),
        ]);
  }

  @override
  Future<void> clearPlaybackPosition(
    String sourceId,
    ContentKind kind,
    String itemId,
  ) async {
    removed.add(itemId);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

PlaybackPosition _position(String id, {int minutes = 5}) => PlaybackPosition(
  kind: ContentKind.movie,
  itemId: id,
  position: Duration(minutes: minutes),
  duration: const Duration(hours: 2),
  updatedAt: DateTime(2026, 10, 24),
);

void main() {
  late _ResumeDatabase db;
  late MediaTabController controller;

  setUp(() {
    db = _ResumeDatabase();
    controller = MediaTabController(
      kind: ContentKind.movie,
      repo: LibraryRepository(source: DemoSource(), db: db),
    );
  });

  tearDown(() => controller.dispose());

  test('newest resume read wins and stale reads skip item lookups', () async {
    final old = controller.loadContinueWatching();
    final latest = controller.loadContinueWatching();
    db.reads.last.complete([_position('latest', minutes: 30)]);
    await latest;

    db.reads.first.complete([_position('old')]);
    await old;

    expect(controller.continueWatching.single.item.id, 'latest');
    expect(
      controller.continueWatching.single.position.position,
      const Duration(minutes: 30),
    );
    expect(db.mediaReads, [
      ['latest'],
    ]);
  });

  test('an old empty read cannot clear a newer resume rail', () async {
    final old = controller.loadContinueWatching();
    final latest = controller.loadContinueWatching();
    db.reads.last.complete([_position('latest')]);
    await latest;

    db.reads.first.complete(const []);
    await old;

    expect(controller.continueWatching.single.item.id, 'latest');
  });

  test(
    'removing a title invalidates an item lookup already in flight',
    () async {
      final initial = controller.loadContinueWatching();
      db.reads.last.complete([_position('movie')]);
      await initial;
      final entry = controller.continueWatching.single;

      db.mediaGate = Completer<List<MediaItem>>();
      final refresh = controller.loadContinueWatching();
      db.reads.last.complete([_position('movie')]);
      await Future<void>.delayed(Duration.zero);
      expect(db.mediaReads, hasLength(2));

      await controller.removeFromContinueWatching(entry);
      db.mediaGate!.complete([entry.item]);
      await refresh;

      expect(db.removed, ['movie']);
      expect(controller.continueWatching, isEmpty);
    },
  );
}
