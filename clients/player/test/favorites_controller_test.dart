// Unit tests for FavoritesController: per-kind favorite id state over the real
// SQLite engine (via AppDatabase.openAt, no path_provider), plus the notifier
// plumbing and the "set is now empty" signal the screen uses to fall back off
// the Favorites view.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/screens/favorites_controller.dart';
import 'package:iptvs/sources/demo_source.dart';
import 'package:iptvs/sources/source.dart';

void main() {
  late Directory tempDir;
  late AppDatabase db;
  late FavoritesController favorites;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('iptvs_favorites_test');
    db = await AppDatabase.openAt('${tempDir.path}/iptv.db');
    favorites = FavoritesController(
      repo: LibraryRepository(source: DemoSource(), db: db),
    );
  });

  tearDown(() async {
    favorites.dispose();
    await db.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('starts empty for every kind', () {
    expect(favorites.ids(ContentKind.live), isEmpty);
    expect(favorites.isFavorite(ContentKind.live, 'bbb'), isFalse);
  });

  test('toggle adds/removes, persists, and notifies', () async {
    var notifications = 0;
    favorites.addListener(() => notifications++);

    final emptyAfterAdd = await favorites.toggle(ContentKind.live, 'bbb');
    expect(emptyAfterAdd, isFalse);
    expect(favorites.isFavorite(ContentKind.live, 'bbb'), isTrue);
    expect(notifications, 1);

    // Persisted to the DB (a fresh load reflects it).
    await favorites.load(ContentKind.live);
    expect(favorites.ids(ContentKind.live), {'bbb'});

    // Removing the last favorite reports the set is now empty.
    final emptyAfterRemove = await favorites.toggle(ContentKind.live, 'bbb');
    expect(emptyAfterRemove, isTrue);
    expect(favorites.isFavorite(ContentKind.live, 'bbb'), isFalse);
  });

  test('kinds are independent', () async {
    await favorites.toggle(ContentKind.live, 'bbb');
    await favorites.toggle(ContentKind.movie, 'm1');

    expect(favorites.ids(ContentKind.live), {'bbb'});
    expect(favorites.ids(ContentKind.movie), {'m1'});
    expect(favorites.ids(ContentKind.series), isEmpty);

    // Removing the movie leaves live untouched.
    final movieEmpty = await favorites.toggle(ContentKind.movie, 'm1');
    expect(movieEmpty, isTrue);
    expect(favorites.ids(ContentKind.live), {'bbb'});
  });

  test('overlapping taps on different ids retain both favorites', () async {
    final controlledDb = _ControlledFavoriteDatabase();
    final controller = FavoritesController(
      repo: LibraryRepository(source: DemoSource(), db: controlledDb),
    );
    addTearDown(controller.dispose);
    final snapshots = <Set<String>>[];
    controller.addListener(
      () => snapshots.add({...controller.ids(ContentKind.live)}),
    );

    final first = controller.toggle(ContentKind.live, 'a');
    final second = controller.toggle(ContentKind.live, 'b');
    final firstWrite = await controlledDb.writeAt(0);
    expect(firstWrite.id, 'a');
    firstWrite.completion.complete();
    expect(await first, isFalse);
    final secondWrite = await controlledDb.writeAt(1);
    expect(secondWrite.id, 'b');
    secondWrite.completion.complete();
    expect(await second, isFalse);

    expect(controller.ids(ContentKind.live), {'a', 'b'});
    expect(await controlledDb.readFavoriteIds('demo', ContentKind.live), {
      'a',
      'b',
    });
    expect(snapshots, [
      {'a'},
      {'a', 'b'},
    ]);
  });

  test('a double tap on one id adds then removes it', () async {
    final controlledDb = _ControlledFavoriteDatabase();
    final controller = FavoritesController(
      repo: LibraryRepository(source: DemoSource(), db: controlledDb),
    );
    addTearDown(controller.dispose);

    final first = controller.toggle(ContentKind.live, 'a');
    final second = controller.toggle(ContentKind.live, 'a');
    final firstWrite = await controlledDb.writeAt(0);
    expect(firstWrite.favorite, isTrue);
    firstWrite.completion.complete();
    expect(await first, isFalse);
    final secondWrite = await controlledDb.writeAt(1);
    expect(secondWrite.id, 'a');
    expect(secondWrite.favorite, isFalse);
    secondWrite.completion.complete();
    expect(await second, isTrue);

    expect(controller.ids(ContentKind.live), isEmpty);
    expect(
      await controlledDb.readFavoriteIds('demo', ContentKind.live),
      isEmpty,
    );
  });

  test(
    'a queued double tap still removes the favorite after disposal',
    () async {
      final controlledDb = _ControlledFavoriteDatabase();
      final controller = FavoritesController(
        repo: LibraryRepository(source: DemoSource(), db: controlledDb),
      );
      var disposed = false;
      addTearDown(() {
        if (!disposed) controller.dispose();
      });
      var notifications = 0;
      controller.addListener(() => notifications++);

      final first = controller.toggle(ContentKind.live, 'a');
      final second = controller.toggle(ContentKind.live, 'a');
      final firstWrite = await controlledDb.writeAt(0);
      controller.dispose();
      disposed = true;
      firstWrite.completion.complete();
      expect(await first, isFalse);
      final secondWrite = await controlledDb.writeAt(1);
      expect(secondWrite.favorite, isFalse);
      secondWrite.completion.complete();
      expect(await second, isTrue);

      expect(
        await controlledDb.readFavoriteIds('demo', ContentKind.live),
        isEmpty,
      );
      expect(notifications, 0);
    },
  );

  test(
    'a failed write preserves UI state and allows queued and later taps',
    () async {
      final controlledDb = _ControlledFavoriteDatabase();
      final controller = FavoritesController(
        repo: LibraryRepository(source: DemoSource(), db: controlledDb),
      );
      addTearDown(controller.dispose);
      final snapshots = <Set<String>>[];
      controller.addListener(
        () => snapshots.add({...controller.ids(ContentKind.live)}),
      );

      final failed = controller.toggle(ContentKind.live, 'a');
      final failure = expectLater(failed, throwsStateError);
      final queued = controller.toggle(ContentKind.live, 'b');
      final failedWrite = await controlledDb.writeAt(0);
      failedWrite.completion.completeError(StateError('write failed'));
      await failure;
      expect(controller.ids(ContentKind.live), isEmpty);
      expect(snapshots, isEmpty);

      final queuedWrite = await controlledDb.writeAt(1);
      queuedWrite.completion.complete();
      expect(await queued, isFalse);
      expect(controller.ids(ContentKind.live), {'b'});

      final retry = controller.toggle(ContentKind.live, 'a');
      final retryWrite = await controlledDb.writeAt(2);
      expect(retryWrite.favorite, isTrue);
      retryWrite.completion.complete();
      expect(await retry, isFalse);
      expect(controller.ids(ContentKind.live), {'a', 'b'});
      expect(await controlledDb.readFavoriteIds('demo', ContentKind.live), {
        'a',
        'b',
      });
      expect(snapshots, [
        {'b'},
        {'a', 'b'},
      ]);
    },
  );
}

class _FavoriteWrite {
  _FavoriteWrite(this.id, this.favorite);

  final String id;
  final bool favorite;
  final completion = Completer<void>();
}

class _ControlledFavoriteDatabase implements AppDatabase {
  final _persisted = <ContentKind, Set<String>>{};
  final _writes = <_FavoriteWrite>[];
  final _started = <int, Completer<_FavoriteWrite>>{};

  Future<_FavoriteWrite> writeAt(int index) {
    if (index < _writes.length) return Future.value(_writes[index]);
    return _started.putIfAbsent(index, Completer<_FavoriteWrite>.new).future;
  }

  @override
  Future<Set<String>> readFavoriteIds(
    String sourceId,
    ContentKind kind,
  ) async => {...?_persisted[kind]};

  @override
  Future<bool> setFavorite(
    String sourceId,
    ContentKind kind,
    String itemId,
    bool favorite,
  ) async {
    final write = _FavoriteWrite(itemId, favorite);
    final index = _writes.length;
    _writes.add(write);
    _started.remove(index)?.complete(write);
    await write.completion.future;
    final ids = _persisted.putIfAbsent(kind, () => <String>{});
    if (favorite) {
      ids.add(itemId);
    } else {
      ids.remove(itemId);
    }
    return favorite;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
