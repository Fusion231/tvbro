import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/sources/source.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// Host timings are an opt-in comparison, never correctness thresholds.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('large cached movie searches baseline', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final directory = await Directory.systemTemp.createTemp('tvbro_media_perf');
    final path = '${directory.path}/library.db';
    final db = await AppDatabase.openAt(path);
    addTearDown(() async {
      await db.close();
      await directory.delete(recursive: true);
    });
    const count = 50000;
    final payload = jsonEncode({
      'providerTitle': 'Synthetic movie',
      'plot': List.filled(128, 'synthetic').join(' '),
      'details': {'container_extension': 'mp4'},
    });
    final raw = await databaseFactoryFfi.openDatabase(path);
    await raw.transaction((txn) async {
      final batch = txn.batch();
      for (var i = 0; i < count; i++) {
        batch.insert('media_items', {
          'source_id': 'source',
          'kind': 'movie',
          'id': '$i',
          'title': i % 1000 == 0 ? 'Wanted movie $i' : 'Movie $i',
          'extra': payload,
          'display_order': i,
        });
      }
      await batch.commit(noResult: true);
    });
    Future<int> measure(Future<Object?> Function() action) async {
      final times = <int>[];
      for (var i = 0; i < 3; i++) {
        final watch = Stopwatch()..start();
        await action();
        times.add(watch.elapsedMicroseconds);
      }
      times.sort();
      return times[1];
    }

    final fullRead = await measure(
      () => db.readMediaItems('source', ContentKind.movie),
    );
    final search = await measure(
      () => db.searchMediaItems('source', ContentKind.movie, 'wanted'),
    );
    final broad = await measure(
      () => db.searchMediaItems('source', ContentKind.movie, 'movie'),
    );
    final miss = await measure(
      () => db.searchMediaItems('source', ContentKind.movie, 'absent'),
    );
    final countOnly = await measure(
      () => db.countMediaItems('source', ContentKind.movie),
    );
    final matches = await db.searchMediaItems(
      'source',
      ContentKind.movie,
      'wanted',
    );
    expect(matches, hasLength(50));
    expect(db.vault.decryptCount, 0);
    // ignore: avoid_print
    print(
      'MOVIE_CACHE_BASELINE ${jsonEncode({'catalogItems': count, 'payloadBytesPerRow': payload.length, 'matchedItems': matches.length, 'medianFullReadUs': fullRead, 'medianSelectiveSearchUs': search, 'medianBroadSearchUs': broad, 'medianNoMatchSearchUs': miss, 'medianCountOnlyUs': countOnly})}',
    );
  }, skip: Platform.environment['IPTVS_RUN_MOVIE_BASELINE'] != '1');
}
