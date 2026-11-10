import 'dart:isolate';

import 'load_token.dart';

import 'package:sqflite_common_ffi/sqflite_ffi.dart'
    show ConflictAlgorithm, DatabaseException, DatabaseExecutor;

/// Android uses the system SQLite, whose FTS5 compile flag is not guaranteed.
/// Probe by creating the actual virtual table, then fall back to FTS4 or a
/// normal indexed token table. Every engine uses literal token-prefix AND.
enum ProgrammeSearchEngine { fts5, fts4, tokens }

class ProgrammeSearchIndex {
  final ProgrammeSearchEngine engine;
  const ProgrammeSearchIndex(this.engine);

  static Future<ProgrammeSearchIndex> open(
    DatabaseExecutor db, {
    ProgrammeSearchEngine? preferred,
    bool rebuild = false,
  }) async {
    final existing = await db.rawQuery(
      "SELECT sql FROM sqlite_master WHERE name = 'programme_search'",
    );
    if (existing.isNotEmpty && preferred == null) {
      final sql = (existing.single['sql'] as String).toLowerCase();
      // Probe the module as well: a cache may have moved between platforms.
      try {
        await db.rawQuery('SELECT rowid FROM programme_search LIMIT 0');
        return ProgrammeSearchIndex(
          sql.contains('fts5')
              ? ProgrammeSearchEngine.fts5
              : ProgrammeSearchEngine.fts4,
        );
      } on DatabaseException {
        // Rebuild below using a module the current device actually provides.
      }
    }
    if (existing.isEmpty && preferred == null) {
      final fallback = await db.rawQuery(
        "SELECT 1 FROM sqlite_master WHERE name = 'programme_search_terms'",
      );
      if (fallback.isNotEmpty) {
        const index = ProgrammeSearchIndex(ProgrammeSearchEngine.tokens);
        // An older build can re-stamp the schema and replace programmes; its
        // writer predates the Dart tokenizer. FTS triggers survive that round
        // trip, while this fallback needs an explicit rebuild on upgrade.
        if (rebuild) await index.rebuildTokens(db);
        return index;
      }
    }
    for (final suffix in ['ai', 'bd', 'bu', 'au']) {
      await db.execute('DROP TRIGGER IF EXISTS programme_search_$suffix');
    }
    await db.execute('DROP TABLE IF EXISTS programme_search');
    await db.execute('DROP TABLE IF EXISTS programme_search_terms');
    for (final candidate in ProgrammeSearchEngine.values) {
      if (preferred != null && candidate.index < preferred.index) continue;
      try {
        if (candidate == ProgrammeSearchEngine.tokens) {
          await db.execute('''
            CREATE TABLE programme_search_terms (
              term TEXT NOT NULL,
              programme_id INTEGER NOT NULL,
              PRIMARY KEY (term, programme_id)
            ) WITHOUT ROWID
          ''');
          await db.execute(
            'CREATE INDEX idx_programme_search_document '
            'ON programme_search_terms(programme_id)',
          );
          await db.execute('''
            CREATE TRIGGER programme_search_bd BEFORE DELETE ON programmes
            BEGIN
              DELETE FROM programme_search_terms WHERE programme_id = old.rowid;
            END
          ''');
          final index = ProgrammeSearchIndex(candidate);
          await index.rebuildTokens(db);
          return index;
        }
        await db.execute(
          candidate == ProgrammeSearchEngine.fts5
              ? "CREATE VIRTUAL TABLE programme_search USING fts5("
                    "title, description, content='programmes', tokenize='unicode61')"
              : "CREATE VIRTUAL TABLE programme_search USING fts4("
                    "title, description, content='programmes', tokenize=unicode61)",
        );
      } on DatabaseException {
        if (candidate == ProgrammeSearchEngine.tokens) rethrow;
        continue;
      }
      await db.execute('''
        CREATE TRIGGER programme_search_ai AFTER INSERT ON programmes BEGIN
          INSERT INTO programme_search(rowid, title, description)
          VALUES (new.rowid, new.title, new.description);
        END
      ''');
      final deletion = candidate == ProgrammeSearchEngine.fts5
          ? "INSERT INTO programme_search(programme_search, rowid, title, description) "
                "VALUES ('delete', old.rowid, old.title, old.description);"
          : 'DELETE FROM programme_search WHERE rowid = old.rowid;';
      await db.execute('''
        CREATE TRIGGER programme_search_bd BEFORE DELETE ON programmes BEGIN
          $deletion
        END
      ''');
      await db.execute('''
        CREATE TRIGGER programme_search_bu BEFORE UPDATE OF title, description ON programmes BEGIN
          $deletion
        END
      ''');
      await db.execute('''
        CREATE TRIGGER programme_search_au AFTER UPDATE OF title, description ON programmes BEGIN
          INSERT INTO programme_search(rowid, title, description)
          VALUES (new.rowid, new.title, new.description);
        END
      ''');
      await db.execute(
        "INSERT INTO programme_search(programme_search) VALUES ('rebuild')",
      );
      return ProgrammeSearchIndex(candidate);
    }
    throw StateError('No programme search engine');
  }

  static final _words = RegExp(r'[\p{L}\p{N}]+', unicode: true);

  static List<String> tokens(String text) => _words
      .allMatches(text.toLowerCase())
      .map((match) => match.group(0)!)
      .toSet()
      .toList();

  static List<String> queryTokens(String query) =>
      tokens(query.length > 512 ? query.substring(0, 512) : query)
          .take(12)
          .map((token) => token.length > 64 ? token.substring(0, 64) : token)
          .toList();

  /// The caller binds [arguments] as parameters; no user text enters SQL or
  /// the FTS grammar. Punctuation, quotes, OR, NEAR and '*' remain literal.
  String predicate(List<String> words, List<Object?> arguments) {
    if (engine != ProgrammeSearchEngine.tokens) {
      arguments.add(
        engine == ProgrammeSearchEngine.fts5
            ? words.map((word) => '"$word"*').join(' AND ')
            : words.map((word) => '"$word*"').join(' '),
      );
      return 'p.rowid IN (SELECT rowid FROM programme_search '
          'WHERE programme_search MATCH ?)';
    }
    final clauses = <String>[];
    for (final word in words) {
      arguments.addAll([word, '$word\u{10ffff}']);
      clauses.add(
        'SELECT programme_id FROM programme_search_terms WHERE term >= ? AND term < ?',
      );
    }
    return 'p.rowid IN (${clauses.join(' INTERSECT ')})';
  }

  Future<void> rebuildTokens(
    DatabaseExecutor db, {
    String? sourceId,
    LoadToken? token,
  }) async {
    if (engine != ProgrammeSearchEngine.tokens) return;
    if (sourceId == null) {
      await db.delete('programme_search_terms');
    } else {
      await db.rawDelete(
        'DELETE FROM programme_search_terms WHERE programme_id IN '
        '(SELECT rowid FROM programmes WHERE source_id = ?)',
        [sourceId],
      );
    }
    var cursor = 0;
    while (true) {
      if (token?.isCancelled ?? false) throw const LoadCancelledException();
      final rows = await db.rawQuery(
        'SELECT rowid, title, description FROM programmes WHERE rowid > ? '
        '${sourceId == null ? '' : 'AND source_id = ? '}ORDER BY rowid LIMIT 500',
        [cursor, ?sourceId],
      );
      if (rows.isEmpty) break;
      final documents = await _tokenizeDocuments(rows);
      if (token?.isCancelled ?? false) throw const LoadCancelledException();
      final batch = db.batch();
      for (final document in documents.entries) {
        for (final term in document.value) {
          batch.insert('programme_search_terms', {
            'term': term,
            'programme_id': document.key,
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
      }
      cursor = rows.last['rowid'] as int;
      await batch.commit(noResult: true);
    }
  }
}

Future<Map<int, List<String>>> _tokenizeDocuments(
  List<Map<String, Object?>> rows,
) => Isolate.run(
  () => {
    for (final row in rows)
      row['rowid'] as int: ProgrammeSearchIndex.tokens(
        '${row['title']} ${row['description'] ?? ''}',
      ),
  },
);
