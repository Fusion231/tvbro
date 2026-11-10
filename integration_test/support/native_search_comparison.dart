// Opt-in native before/current comparisons on the same isolated SQLite file.
// Legacy SQL is retained here so emulator warmup cannot masquerade as a gain.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/programme_search.dart';
import 'package:iptvs/sources/source.dart';
import 'package:sqflite/sqflite.dart';

Future<Map<String, Object?>> compareNativeSearches({
  required AppDatabase db,
  required String path,
  required String sourceId,
  required List<String> channelIds,
  required DateTime now,
}) async {
  final raw = await openDatabase(path, singleInstance: false);
  final cases = <Map<String, Object?>>[];
  try {
    for (final (label, query, count) in [
      ('guide_broad_1000', 'Fixture programme', 1000),
      ('guide_rare_1000', 'Fixture programme 999', 1000),
      ('guide_miss_1000', 'Nonexistent needle', 1000),
      ('guide_broad_all', 'Fixture programme', channelIds.length),
    ]) {
      final allowed = channelIds.take(count).toSet();
      final legacyTimes = <int>[];
      final setupTimes = <int>[];
      final queryTimes = <int>[];
      final currentTimes = <int>[];
      List<String>? expected;
      List<Map<String, Object?>>? plan;
      Future<void> legacy(bool retain) async {
        final watch = Stopwatch()..start();
        final result = await raw.transaction((txn) async {
          final setup = Stopwatch()..start();
          await txn.execute(
            'CREATE TEMP TABLE IF NOT EXISTS benchmark_search_allowed ('
            'request_id INTEGER NOT NULL, channel_id TEXT NOT NULL, '
            'PRIMARY KEY (request_id, channel_id)) WITHOUT ROWID',
          );
          final ids = allowed.toList();
          try {
            for (var start = 0; start < ids.length; start += 500) {
              final batch = txn.batch();
              for (final id in ids.skip(start).take(500)) {
                batch.insert('benchmark_search_allowed', {
                  'request_id': 1,
                  'channel_id': id,
                });
              }
              await batch.commit(noResult: true);
            }
            final setupUs = setup.elapsedMicroseconds;
            final args = <Object?>[];
            final match = ProgrammeSearchIndex(db.programmeSearchEngine)
                .predicate(ProgrammeSearchIndex.queryTokens(query), args);
            args.addAll([1, sourceId, now.millisecondsSinceEpoch, 80]);
            final sql =
                'SELECT p.rowid AS programme_rowid, p.source_id, '
                'p.channel_id, p.start, p.stop, p.title, p.description, '
                's.name AS source_name, c.id, c.name, c.number, c.logo, '
                'c.category_id, c.archive_days, c.extra '
                'FROM programmes p JOIN channels c '
                'ON c.source_id = p.source_id AND c.id = p.channel_id '
                'JOIN sources s ON s.id = p.source_id '
                'WHERE $match AND p.channel_id IN '
                '(SELECT channel_id FROM benchmark_search_allowed '
                'WHERE request_id = ?) AND p.source_id = ? AND p.stop > ? '
                'ORDER BY p.start, p.rowid LIMIT ?';
            final queryWatch = Stopwatch()..start();
            final rows = await txn.rawQuery(sql, args);
            final queryUs = queryWatch.elapsedMicroseconds;
            plan ??= await txn.rawQuery('EXPLAIN QUERY PLAN $sql', args);
            if (retain) {
              setupTimes.add(setupUs);
              queryTimes.add(queryUs);
            }
            return [
              for (final row in rows)
                jsonEncode([
                  row['source_id'],
                  row['channel_id'],
                  row['start'],
                  row['stop'],
                  row['title'],
                  row['description'],
                ]),
            ];
          } finally {
            await txn.delete('benchmark_search_allowed');
          }
        });
        expected ??= result;
        expect(result, expected);
        if (retain) legacyTimes.add(watch.elapsedMicroseconds);
      }

      Future<void> current(bool retain) async {
        final watch = Stopwatch()..start();
        final rows = await db.searchProgrammes(
          query,
          sourceId: sourceId,
          allowedChannelIds: allowed,
          from: now,
        );
        final elapsed = watch.elapsedMicroseconds;
        expect([
          for (final row in rows)
            jsonEncode([
              row.sourceId,
              row.channel.id,
              row.programme.start.millisecondsSinceEpoch,
              row.programme.stop.millisecondsSinceEpoch,
              row.programme.title,
              row.programme.description,
            ]),
        ], expected);
        if (retain) currentTimes.add(elapsed);
      }

      await legacy(false);
      await current(false);
      for (var trial = 0; trial < 3; trial++) {
        if (trial.isEven) {
          await legacy(true);
          await current(true);
        } else {
          await current(true);
          await legacy(true);
        }
      }
      final result = <String, Object?>{
        'case': label,
        'allowedIds': allowed.length,
        'resultCount': expected!.length,
        'legacyMedianUs': _median(legacyTimes),
        'legacySetupMedianUs': _median(setupTimes),
        'legacyQueryMedianUs': _median(queryTimes),
        'currentMedianUs': _median(currentTimes),
        'legacyPlan': plan,
      };
      cases.add(result);
      // ignore: avoid_print
      print('NATIVE_SEARCH_COMPARISON ${jsonEncode(result)}');
    }

    // The original 50k full-record read exceeds this TV's 192 MiB Java heap.
    // Compare safely at 10k, then validate the bounded current path at 50k.
    const movieCount = 10000;
    final payload = jsonEncode({
      'providerTitle': 'Synthetic movie',
      'plot': List.filled(128, 'synthetic').join(' '),
      'details': {'container_extension': 'mp4'},
    });
    Future<void> seedMovies(int from, int to) => raw.transaction((txn) async {
      for (var start = from; start < to; start += 500) {
        final batch = txn.batch();
        for (var i = start; i < start + 500; i++) {
          batch.insert('media_items', {
            'source_id': sourceId,
            'kind': 'movie',
            'id': '$i',
            'title': i % 1000 == 0 ? 'Wanted movie $i' : 'Movie $i',
            'extra': payload,
            'display_order': i,
          });
        }
        await batch.commit(noResult: true);
      }
    });
    await seedMovies(0, movieCount);
    for (final query in ['wanted', 'absent', 'movie']) {
      final before = <int>[];
      final after = <int>[];
      Future<List<MediaItem>> legacy() async {
        final rows = await raw.query(
          'media_items',
          where: 'source_id = ? AND kind = ?',
          whereArgs: [sourceId, 'movie'],
          orderBy: 'display_order, title',
        );
        return [
          for (final row in rows)
            if ((row['title'] as String).toLowerCase().contains(query))
              MediaItem(
                id: row['id'] as String,
                title: row['title'] as String,
                kind: ContentKind.movie,
                parentId: row['parent_id'] as String?,
                categoryId: row['category_id'] as String?,
                poster: normalizeImageUrl(row['poster']),
                backdrop: normalizeImageUrl(row['backdrop']),
                description: row['description'] as String?,
                year: row['year'] as String?,
                rating: _readDouble(row['rating']),
                durationSeconds: _readInt(row['duration_seconds']),
                seasonNumber: _readInt(row['season_number']),
                episodeNumber: _readInt(row['episode_number']),
                providerId: row['provider_id'] as String?,
                extra:
                    jsonDecode(row['extra'] as String) as Map<String, dynamic>,
              ),
        ];
      }

      final expected = (await legacy()).map((row) => row.id).toList();
      await db.searchMediaItems(sourceId, ContentKind.movie, query);
      for (var trial = 0; trial < 3; trial++) {
        Future<void> measure(bool old) async {
          final watch = Stopwatch()..start();
          final rows = old
              ? await legacy()
              : await db.searchMediaItems(sourceId, ContentKind.movie, query);
          (old ? before : after).add(watch.elapsedMicroseconds);
          expect(rows.map((row) => row.id), expected);
        }

        await measure(trial.isEven);
        await measure(!trial.isEven);
      }
      final result = <String, Object?>{
        'case': 'movie_$query',
        'catalogItems': movieCount,
        'resultCount': expected.length,
        'payloadBytesPerRow': payload.length,
        'legacyMedianUs': _median(before),
        'currentMedianUs': _median(after),
      };
      cases.add(result);
      // ignore: avoid_print
      print('NATIVE_SEARCH_COMPARISON ${jsonEncode(result)}');
    }
    await seedMovies(movieCount, 50000);
    Future<void> validateFullRead() async {
      final watch = Stopwatch()..start();
      final rows = await db.readMediaItems(sourceId, ContentKind.movie);
      final elapsed = watch.elapsedMicroseconds;
      expect(rows, hasLength(50000));
      expect(rows.first.id, '0');
      expect(rows.last.id, '49999');
      expect(rows.first.extra['providerTitle'], 'Synthetic movie');
      final result = <String, Object?>{
        'case': 'large_movie_read_current',
        'catalogItems': 50000,
        'resultCount': rows.length,
        'currentUs': elapsed,
        'validationOnly': true,
      };
      cases.add(result);
      // ignore: avoid_print
      print('NATIVE_SEARCH_COMPARISON ${jsonEncode(result)}');
    }

    await validateFullRead();
    for (final (query, expectedCount) in [
      ('wanted', 50),
      ('absent', 0),
      ('movie', 50000),
    ]) {
      final watch = Stopwatch()..start();
      final rows = await db.searchMediaItems(
        sourceId,
        ContentKind.movie,
        query,
      );
      final elapsed = watch.elapsedMicroseconds;
      expect(rows, hasLength(expectedCount));
      expect(db.vault.decryptCount, 0);
      final result = <String, Object?>{
        'case': 'large_movie_${query}_current',
        'catalogItems': 50000,
        'resultCount': rows.length,
        'currentUs': elapsed,
        'validationOnly': true,
      };
      cases.add(result);
      // ignore: avoid_print
      print('NATIVE_SEARCH_COMPARISON ${jsonEncode(result)}');
    }
    return {'trials': 3, 'cases': cases};
  } finally {
    await raw.close();
  }
}

int _median(List<int> values) => (values..sort())[values.length ~/ 2];

int? _readInt(Object? value) => value is int
    ? value
    : value == null
    ? null
    : int.tryParse(value.toString());

double? _readDouble(Object? value) => value is num
    ? value.toDouble()
    : value == null
    ? null
    : double.tryParse(value.toString());
