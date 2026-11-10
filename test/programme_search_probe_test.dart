import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/programme_search.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// The host SQLite provides FTS5, but need not provide FTS4. Only the successful
// FTS4 CREATE is translated to FTS5; transaction/savepoint behavior stays real.
class _ProbeExecutor implements DatabaseExecutor {
  final DatabaseExecutor delegate;
  final bool partialFts5Create;
  final bool missingExistingModule;
  final bool rejectWrites;
  int fts4Attempts = 0;

  _ProbeExecutor(
    this.delegate, {
    this.partialFts5Create = false,
    this.missingExistingModule = false,
    this.rejectWrites = false,
  });

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) async {
    if (rejectWrites) {
      throw StateError('Reopen must preserve the existing index');
    }
    if (partialFts5Create && sql.trim().toLowerCase().startsWith('rollback')) {
      throw StateError('sqflite would clear the outer transaction id');
    }
    if (partialFts5Create && sql.contains('USING fts5(')) {
      // Simulate the native partial CREATE before the missing-module error.
      await delegate.execute('CREATE TABLE programme_search(partial INTEGER)');
      throw _MissingFtsModule();
    }
    if (partialFts5Create && sql.contains('USING fts4(')) {
      fts4Attempts++;
      sql = sql
          .replaceFirst('USING fts4(', 'USING fts5(')
          .replaceFirst('tokenize=unicode61', "tokenize='unicode61'");
    }
    await delegate.execute(sql, arguments);
  }

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) async {
    if (missingExistingModule &&
        sql == 'SELECT rowid FROM programme_search LIMIT 0') {
      throw _MissingFtsModule();
    }
    return delegate.rawQuery(sql, arguments);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MissingFtsModule extends DatabaseException {
  _MissingFtsModule() : super('no such module: fts5');

  @override
  int? getResultCode() => 1;

  @override
  Object? get result => null;
}

void main() {
  late Directory temp;
  setUpAll(sqfliteFfiInit);
  setUp(() => temp = Directory.systemTemp.createTempSync('iptvs_search_probe'));
  tearDown(() => temp.deleteSync(recursive: true));

  Future<Database> open() async {
    final db = await databaseFactoryFfi.openDatabase('${temp.path}/db');
    addTearDown(db.close);
    await db.execute('CREATE TABLE programmes(title TEXT, description TEXT)');
    await db.insert('programmes', {
      'title': 'Existing programme',
      'description': 'Keep the cached guide',
    });
    await db.setVersion(16);
    return db;
  }

  test('partial FTS5 CREATE is rolled back before the FTS4 probe', () async {
    final db = await open();
    late _ProbeExecutor probe;
    final index = await db.transaction((txn) async {
      await txn.execute('CREATE TABLE outer_marker(value INTEGER)');
      await txn.insert('outer_marker', {'value': 1});
      probe = _ProbeExecutor(txn, partialFts5Create: true);
      final index = await ProgrammeSearchIndex.open(probe);
      await txn.insert('outer_marker', {'value': 2});
      return index;
    });

    expect(index.engine, ProgrammeSearchEngine.fts4);
    expect(probe.fts4Attempts, 1);
    expect(await db.query('outer_marker'), [
      {'value': 1},
      {'value': 2},
    ]);
    expect(await db.query('programmes'), [
      {'title': 'Existing programme', 'description': 'Keep the cached guide'},
    ]);
    expect(
      (await db.rawQuery(
        'SELECT title FROM programme_search WHERE programme_search MATCH ?',
        ['existing'],
      )).single['title'],
      'Existing programme',
    );
    expect(await db.getVersion(), 16);
  });

  for (final staleVirtualTable in [false, true]) {
    test(
      'token reopen preserves index without writes, stale FTS=$staleVirtualTable',
      () async {
        final db = await open();
        await db.transaction(
          (txn) => ProgrammeSearchIndex.open(
            txn,
            preferred: ProgrammeSearchEngine.tokens,
          ),
        );
        if (staleVirtualTable) {
          // The schema entry is real; simulate moving to a native SQLite
          // without its module, including a DROP that cannot safely run.
          await db.execute(
            'CREATE VIRTUAL TABLE programme_search USING fts5('
            "title, description, content='programmes')",
          );
        }
        final before = await db.query('programme_search_terms');
        expect(before, isNotEmpty);
        for (var reopen = 0; reopen < 2; reopen++) {
          final index = await db.transaction(
            (txn) => ProgrammeSearchIndex.open(
              _ProbeExecutor(
                txn,
                missingExistingModule: staleVirtualTable,
                rejectWrites: true,
              ),
            ),
          );
          expect(index.engine, ProgrammeSearchEngine.tokens);
          final arguments = <Object?>[];
          final predicate = index.predicate(['existing'], arguments);
          expect(
            (await db.rawQuery(
              'SELECT title FROM programmes p WHERE $predicate',
              arguments,
            )).single['title'],
            'Existing programme',
          );
          expect(await db.query('programme_search_terms'), before);
          expect(await db.getVersion(), 16);
        }
      },
    );
  }
}
