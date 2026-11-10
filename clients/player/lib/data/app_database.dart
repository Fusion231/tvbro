import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as mobile_sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../sources/source.dart';
import '../sources/source_identity.dart';
import '../sources/epg_mapping.dart';
import 'epg_ingest.dart';
import 'channel_library_spool.dart';
import 'epg_models.dart';
import 'load_token.dart';
import 'programme_search.dart';
import 'secret_locator_vault.dart';

typedef FavoriteChange = ({
  String sourceId,
  ContentKind kind,
  String itemId,
  bool add,
  int updatedAt,
});

typedef PlaybackPositionChange = ({
  String sourceId,
  ContentKind kind,
  String itemId,
  int positionMs,
  int durationMs,
  int updatedAt,
  bool removed,
});

/// A saved VOD resume point (see `playback_positions`).
class PlaybackPosition {
  final ContentKind kind;
  final String itemId;
  final Duration position;
  final Duration duration;
  final DateTime updatedAt;

  const PlaybackPosition({
    required this.kind,
    required this.itemId,
    required this.position,
    required this.duration,
    required this.updatedAt,
  });

  /// 0..1 watched fraction (0 when the duration is unknown).
  double get progress => duration > Duration.zero
      ? (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
      : 0.0;

  bool get isFinished =>
      duration > Duration.zero && progress >= AppDatabase.kFinishedFraction;
}

class EpgStreamWriteMetrics {
  final Duration providerDuration;
  final Duration databaseDuration;

  const EpgStreamWriteMetrics({
    required this.providerDuration,
    required this.databaseDuration,
  });
}

/// Local SQLite cache of a source's categories, channels, and EPG, keyed by
/// [Source.id], so launches are instant and search/guide work offline.
class AppDatabase {
  static int _searchRequestSequence = 0;
  final Database _db;
  final SecretLocatorVault _vault;
  final ProgrammeSearchIndex _programmeSearch;
  AppDatabase._(this._db, this._vault, this._programmeSearch);

  ProgrammeSearchEngine get programmeSearchEngine => _programmeSearch.engine;

  /// The locator vault backing this cache. Exposed so tests can assert on
  /// [SecretLocatorVault.decryptCount] — reading the cache must decrypt
  /// nothing; only [revealChannel]/[revealMediaItem] may.
  @visibleForTesting
  SecretLocatorVault get vault => _vault;

  /// Current schema version. Bump this and add an [onUpgrade] branch whenever
  /// the schema changes.
  ///
  /// Publicly shipped schema versions (repository release tags): 8
  /// (v0.1.0–v0.1.7), 9 (v0.1.8–v0.1.10), 10 (v0.1.11–v0.1.15), 11
  /// (v0.1.16–v0.1.34), 12 (v0.1.35+). Upgrades from those versions are the
  /// supported compatibility claim, pinned by
  /// `test/released_schema_fixtures_test.dart` (fixture → migrate → schema
  /// parity with a fresh install → stable second open). The pre-v8 branches
  /// below never shipped in a tagged release; they are kept as best-effort
  /// repair paths for development-era installs and are exercised only by the
  /// v1/v7 regression tests in `test/persistence_test.dart`.
  ///
  /// Re-entrancy rule: `sqflite` is opened without an `onDowngrade` handler, so
  /// running an *older* build against a newer file silently re-stamps the
  /// version down without undoing anything. Upgrading again re-runs every
  /// branch in between over a schema that may already have the change, so each
  /// branch must be idempotent (`CREATE TABLE/INDEX IF NOT EXISTS`, the
  /// `_isDuplicateColumn` guard).
  static const schemaVersion = 19;

  static Future<AppDatabase> open() async {
    // Desktop platforms use the FFI implementation; mobile uses the plugin.
    final DatabaseFactory factory;
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      sqfliteFfiInit();
      factory = databaseFactoryFfi;
    } else {
      factory = mobile_sqflite.databaseFactory;
    }

    final dir = await getApplicationSupportDirectory();
    final path = p.join(dir.path, 'iptv.db');
    final vault = SecretLocatorVault();
    await vault.ensureKey();
    final app = await _openWithFactory(path, factory, vault);
    if (vault.generatedNewKey) await app._migrateLegacyCacheSecrets();
    return app;
  }

  /// Opens (and migrates) the database at an explicit [path] using the FFI
  /// factory. Lets tests exercise schema creation, migrations, and the
  /// read/write methods without depending on `path_provider`.
  @visibleForTesting
  static Future<AppDatabase> openAt(
    String path, {
    ProgrammeSearchEngine? searchEngine,
  }) async {
    sqfliteFfiInit();
    final vault = SecretLocatorVault();
    await vault.ensureKey();
    final app = await _openWithFactory(
      path,
      databaseFactoryFfi,
      vault,
      searchEngine: searchEngine,
    );
    if (vault.generatedNewKey) await app._migrateLegacyCacheSecrets();
    return app;
  }

  static Future<AppDatabase> _openWithFactory(
    String path,
    DatabaseFactory factory,
    SecretLocatorVault vault, {
    ProgrammeSearchEngine? searchEngine,
  }) async {
    var rebuildSearch = false;
    final db = await factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        onConfigure: _configure,
        onCreate: (db, _) async {
          await db.execute('''
          CREATE TABLE sources (
            id           TEXT PRIMARY KEY,
            name         TEXT NOT NULL,
            synced_at    INTEGER,
            epg_synced_at INTEGER,
            cache_identity TEXT
          )
        ''');
          await db.execute('''
          CREATE TABLE categories (
            source_id TEXT NOT NULL,
            id        TEXT NOT NULL,
            title     TEXT NOT NULL,
            PRIMARY KEY (source_id, id)
          )
        ''');
          await db.execute('''
          CREATE TABLE channels (
            source_id   TEXT NOT NULL,
            id          TEXT NOT NULL,
            name        TEXT NOT NULL,
            number      INTEGER,
            logo        TEXT,
            category_id TEXT,
            extra       TEXT,
            archive_days INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (source_id, id)
          )
        ''');
          await _createProgrammes(db);
          await _createMediaTables(db);
          await _createCatalogSync(db);
          await _createFavorites(db);
          await _createPlaybackPositions(db);
          await _createPlaybackPositionsOutbox(db);
          await _createPlaybackCursors(db);
          await _createFavoritesOutbox(db);
          await _createEpgMappings(db);
          await db.execute(
            'CREATE INDEX idx_channels_source ON channels(source_id)',
          );
          await db.execute(
            'CREATE INDEX idx_channels_source_cat ON channels(source_id, category_id)',
          );
        },
        onUpgrade: (db, oldV, newV) async {
          if (oldV < 2) {
            await db.execute(
              'ALTER TABLE sources ADD COLUMN epg_synced_at INTEGER',
            );
            await _createProgrammes(db);
          }
          if (oldV < 3) {
            await _createMediaTables(db);
          }
          if (oldV >= 3 && oldV < 4) {
            await _addMediaPagingColumns(db);
            await _createMediaEnrichment(db);
          }
          if (oldV < 5) {
            await _createMediaPageState(db);
          }
          if (oldV >= 3 && oldV < 6) {
            await _addMediaDisplayOrderColumn(db);
          }
          if (oldV >= 3 && oldV < 7) {
            await _addMediaHierarchyColumns(db);
            await _addMediaPageParentColumn(db);
            await _createExternalMetadata(db);
          }
          if (oldV < 8) {
            // Repair DBs created fresh at v7 (and pre-v3 upgrades): `onCreate` /
            // `_createMediaTables` built every media table except external_metadata,
            // so it was missing until now. Idempotent (CREATE TABLE IF NOT EXISTS).
            await _createExternalMetadata(db);
          }
          if (oldV < 9) {
            // User favorites. `_createFavorites` lives outside `_createMediaTables`,
            // so this repair branch covers every upgrade path (incl. pre-v3, which
            // skips the v3+ media ALTER branches). Idempotent.
            await _createFavorites(db);
          }
          if (oldV < 10) {
            // Catch-up window per channel. The `channels` table is built in
            // `onCreate` (not `_createMediaTables`), so every upgrade path lands
            // here; the ALTER is guarded against a pre-existing column.
            await _addChannelArchiveColumn(db);
          }
          if (oldV < 11) {
            // VOD resume positions. Standalone table (like `favorites`, outside
            // `_createMediaTables`), so this one repair branch covers every
            // upgrade path. Idempotent.
            await _createPlaybackPositions(db);
          }
          if (oldV < 12) {
            // `nowNext` scans by (source_id, start) with no channel_id
            // constraint, so the existing (source_id, channel_id, start) lookup
            // index doesn't serve it. `programmes` is created by
            // `_createProgrammes` (called from `onCreate` and the `oldV < 2`
            // branch), which now creates this index too — `IF NOT EXISTS` makes
            // this branch a no-op on that path and a real repair everywhere else.
            await db.execute(
              'CREATE INDEX IF NOT EXISTS idx_prog_source_start '
              'ON programmes(source_id, start)',
            );
          }
          if (oldV < 13) {
            // The `nowNext` "now" query also filters on `stop`, which
            // `idx_prog_source_start` doesn't carry — so every candidate row
            // cost a table lookup just to be discarded. This covering index
            // decides the whole predicate from the index entry. Created by
            // `_createProgrammes` too, so `IF NOT EXISTS` makes this a no-op
            // on the `onCreate`/`oldV < 2` paths and a real repair elsewhere.
            await db.execute(
              'CREATE INDEX IF NOT EXISTS idx_prog_now '
              'ON programmes(source_id, start, stop, channel_id)',
            );
            // The "next" query pins `INDEXED BY idx_prog_lookup` (see
            // `_nextQuery`), which is a hard dependency: without the index the
            // query fails outright. Every supported upgrade path already has
            // it; re-asserting it here costs one no-op DDL and removes the
            // failure mode entirely.
            await db.execute(
              'CREATE INDEX IF NOT EXISTS idx_prog_lookup '
              'ON programmes(source_id, channel_id, start)',
            );
          }
          if (oldV < 14) {
            // Pending favorite changes awaiting a cloud push. Standalone table
            // (like `favorites` and `playback_positions`, outside
            // `_createMediaTables`), so this one branch covers every upgrade
            // path including pre-v3 — which skips the v3+ media branches
            // entirely. Idempotent.
            await _createFavoritesOutbox(db);
            // The seed below reads `favorites`, which an upgrade recorded at
            // v9+ never re-creates — and a database that never had it (an old
            // partial fixture, or any path where the v9 branch was skipped)
            // would make this branch throw and take the whole open with it.
            // `_createFavorites` is CREATE TABLE IF NOT EXISTS, so asserting it
            // here costs one no-op DDL and removes that failure mode.
            await _createFavorites(db);
            // Seed it with everything already favorited, as pending adds.
            //
            // Favorites now sync automatically, and the pull mirrors the
            // profile: it clears the cloud-managed sources and re-applies the
            // cloud's set. On the first launch after this upgrade a paired
            // device whose favorites were never pushed (the user only ever
            // pressed Pull, or favorited things since the last Push) would have
            // an empty outbox — and every one of those favorites would be
            // deleted, unprompted, by a sync the user never asked for. Before
            // this, that destruction at least required pressing Pull.
            //
            // Seeding says the true thing: these are local changes the cloud
            // has not been told about. The pull then rebases them instead of
            // erasing them, and the first push sends them up. Re-sending a
            // favorite the cloud already has is a no-op there.
            //
            // OR IGNORE, not OR REPLACE: the branch must survive being re-run
            // (there is no onDowngrade), and a re-run must not overwrite a
            // pending *removal* with an add — that would resurrect exactly what
            // the user deleted.
            await db.execute(
              '''
              INSERT OR IGNORE INTO favorites_outbox
                (source_id, kind, item_id, op, updated_at)
              SELECT source_id, kind, item_id, 'add', ?
                FROM favorites
            ''',
              [DateTime.now().millisecondsSinceEpoch],
            );
          }
          if (oldV < 15) {
            await _createEpgMappings(db);
            rebuildSearch = true;
          }
          if (oldV < 16) {
            await _createCatalogSync(db);
          }
          if (oldV < 17) {
            await _createPlaybackPositions(db);
            await _createPlaybackPositionsOutbox(db);
            // Existing local progress must survive the first automatic pull.
            // IGNORE preserves unsent removals if this migration is re-run.
            await db.execute(
              'INSERT OR IGNORE INTO playback_positions_outbox '
              '(source_id, kind, item_id, position_ms, duration_ms, updated_at, removed) '
              'SELECT source_id, kind, item_id, position_ms, duration_ms, updated_at, 0 '
              'FROM playback_positions',
            );
          }
          if (oldV < 18) {
            await _createPlaybackCursors(db);
          }
          if (oldV < 19) {
            await _addSourceCacheIdentityColumn(db);
          }
        },
      ),
    );
    final search = await db.transaction(
      (txn) => ProgrammeSearchIndex.open(
        txn,
        preferred: searchEngine,
        rebuild: rebuildSearch,
      ),
    );
    return AppDatabase._(db, vault, search);
  }

  static Future<void> _createEpgMappings(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS epg_channel_overrides (
        source_id TEXT NOT NULL,
        channel_id TEXT NOT NULL,
        guide_id TEXT,
        guide_channel_id TEXT,
        offset_minutes INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (source_id, channel_id)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS epg_guide_channels (
        source_id TEXT NOT NULL,
        guide_id TEXT NOT NULL,
        guide_label TEXT NOT NULL,
        channel_id TEXT NOT NULL,
        display_names TEXT NOT NULL,
        PRIMARY KEY (source_id, guide_id, channel_id)
      )
    ''');
  }

  static Future<void> _createCatalogSync(DatabaseExecutor db) => db.execute('''
    CREATE TABLE IF NOT EXISTS catalog_sync (
      source_id TEXT NOT NULL,
      kind TEXT NOT NULL,
      synced_at INTEGER NOT NULL,
      PRIMARY KEY (source_id, kind)
    )
  ''');

  /// Connection tuning, applied before the version check so it also covers
  /// `onCreate`/`onUpgrade`. `sqflite_common` runs `onConfigure` *outside* the
  /// migration transaction (`database_mixin.dart`, "first configure it"),
  /// which is what makes `journal_mode` legal here — it cannot be changed
  /// inside a transaction.
  ///
  /// Only the desktop FFI backend is really being fixed: it runs raw sqlite
  /// defaults, notably a 2 MB page cache against a cache file that a
  /// 250k-channel portal drives past a gigabyte. Android's framework already
  /// enables compatibility WAL, so there the pragmas are near no-ops.
  static Future<void> _configure(Database db) async {
    // Concurrent reads during a write, and far cheaper commits. `setJournalMode`
    // exists because Android's `execSQL` rejects a value-returning pragma
    // unless WAL is declared in the manifest; it falls back to `rawQuery`.
    await db.setJournalMode('WAL');
    // WAL + NORMAL is durable across an app crash; only an OS crash or power
    // loss can cost the most recent commits. This database is a rebuildable
    // provider cache plus small user state (favorites, resume positions), so
    // that trade is the same one the Android framework makes by default.
    await db.execute('PRAGMA synchronous = NORMAL');
    // 8 MB of page cache (negative = KiB) instead of sqlite's 2 MB default.
    await db.execute('PRAGMA cache_size = -8000');
    // Deliberately NOT setting `temp_store = MEMORY`: `readChannels` sorts by
    // `number, name` with no index to serve it, so a 250k-channel source would
    // move an unbounded sorter into RAM on exactly the low-memory TV boxes
    // that can least afford it. Pinning the `nowNext` "next" query on
    // `idx_prog_lookup` already removed the one hot temp B-tree this would
    // have helped.
  }

  Future<void> _migrateLegacyCacheSecrets() async {
    final channelRows = await _db.query(
      'channels',
      columns: ['source_id', 'id', 'extra'],
    );
    final mediaRows = await _db.query(
      'media_items',
      columns: ['source_id', 'kind', 'id', 'extra'],
    );
    final hasEncrypted = [...channelRows, ...mediaRows].any(
      (row) =>
          (row['extra'] as String?)?.contains('"$secretLocatorKey"') ?? false,
    );
    if (hasEncrypted) {
      await _invalidateRegenerableCache();
      return;
    }
    await _db.transaction((txn) async {
      for (final row in channelRows) {
        final raw = row['extra'] as String?;
        if (raw == null) continue;
        final protectedExtra = await protectSecretLocators(
          (jsonDecode(raw) as Map).cast<String, dynamic>(),
          _vault,
        );
        await txn.update(
          'channels',
          {'extra': protectedExtra.isEmpty ? null : jsonEncode(protectedExtra)},
          where: 'source_id = ? AND id = ?',
          whereArgs: [row['source_id'], row['id']],
        );
      }
      for (final row in mediaRows) {
        final raw = row['extra'] as String?;
        if (raw == null) continue;
        final protectedExtra = await protectSecretLocators(
          (jsonDecode(raw) as Map).cast<String, dynamic>(),
          _vault,
        );
        await txn.update(
          'media_items',
          {'extra': protectedExtra.isEmpty ? null : jsonEncode(protectedExtra)},
          where: 'source_id = ? AND kind = ? AND id = ?',
          whereArgs: [row['source_id'], row['kind'], row['id']],
        );
      }
    });
  }

  Future<void> _invalidateRegenerableCache() async {
    await _db.transaction((txn) async {
      for (final table in [
        'categories',
        'channels',
        'programmes',
        'media_categories',
        'media_items',
        'media_sync',
        'media_page_state',
        'catalog_sync',
        'external_metadata',
      ]) {
        await txn.delete(table);
      }
      await txn.update('sources', {'synced_at': null, 'epg_synced_at': null});
    });
  }

  /// Associates this source id with the provider configuration that produced
  /// its cache. Unknown or changed identities discard only regenerable rows;
  /// favorites and resume/history state live in separate tables and survive.
  /// With [onlyIfUnknown], a different committed identity is rejected.
  Future<bool> migrateSourceCacheIdentity(
    String sourceId,
    String name,
    String identity, {
    bool onlyIfUnknown = false,
  }) async {
    var accepted = false;
    await _db.transaction((txn) async {
      final rows = await txn.query(
        'sources',
        columns: ['cache_identity', 'name'],
        where: 'id = ?',
        whereArgs: [sourceId],
        limit: 1,
      );
      if (rows.isNotEmpty && rows.single['cache_identity'] == identity) {
        if (rows.single['name'] != name) {
          await txn.update(
            'sources',
            {'name': name},
            where: 'id = ?',
            whereArgs: [sourceId],
          );
        }
        accepted = true;
        return;
      }
      if (onlyIfUnknown &&
          rows.isNotEmpty &&
          rows.single['cache_identity'] != null) {
        return;
      }

      await _invalidateSourceCache(txn, sourceId);
      if (rows.isEmpty) {
        await txn.insert('sources', {
          'id': sourceId,
          'name': name,
          'cache_identity': identity,
        });
      } else {
        await txn.update(
          'sources',
          {
            'name': name,
            'synced_at': null,
            'epg_synced_at': null,
            'cache_identity': identity,
          },
          where: 'id = ?',
          whereArgs: [sourceId],
        );
      }
      accepted = true;
    });
    return accepted;
  }

  Future<bool> sourceCacheIdentityMatches(
    String sourceId,
    String identity,
  ) async => _sourceCacheIdentityMatches(_db, sourceId, identity);

  Future<String?> sourceCacheIdentity(String sourceId) async {
    final rows = await _db.query(
      'sources',
      columns: ['cache_identity'],
      where: 'id = ?',
      whereArgs: [sourceId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.single['cache_identity'] as String?;
  }

  static Future<bool> _sourceCacheIdentityMatches(
    DatabaseExecutor executor,
    String sourceId,
    String identity,
  ) async {
    final rows = await executor.query(
      'sources',
      columns: ['cache_identity'],
      where: 'id = ?',
      whereArgs: [sourceId],
      limit: 1,
    );
    return rows.isNotEmpty && rows.single['cache_identity'] == identity;
  }

  static Future<void> _invalidateSourceCache(
    DatabaseExecutor executor,
    String sourceId,
  ) async {
    for (final table in const [
      'categories',
      'channels',
      'programmes',
      'media_sync',
      'media_categories',
      'media_items',
      'media_enrichment',
      'media_page_state',
      'catalog_sync',
      'external_metadata',
      'epg_guide_channels',
    ]) {
      await executor.delete(
        table,
        where: 'source_id = ?',
        whereArgs: [sourceId],
      );
    }
  }

  static Future<void> _createProgrammes(Database db) async {
    await db.execute('''
      CREATE TABLE programmes (
        source_id   TEXT NOT NULL,
        channel_id  TEXT NOT NULL,
        start       INTEGER NOT NULL,
        stop        INTEGER NOT NULL,
        title       TEXT NOT NULL,
        description TEXT
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_prog_lookup ON programmes(source_id, channel_id, start)',
    );
    await db.execute(
      'CREATE INDEX idx_prog_source_start ON programmes(source_id, start)',
    );
    // Covering index for the `nowNext` "now" query — see `_nowQuery`.
    await db.execute(
      'CREATE INDEX idx_prog_now '
      'ON programmes(source_id, start, stop, channel_id)',
    );
  }

  static Future<void> _createMediaTables(Database db) async {
    await db.execute('''
      CREATE TABLE media_sync (
        source_id TEXT NOT NULL,
        kind      TEXT NOT NULL,
        synced_at INTEGER NOT NULL,
        loaded_pages INTEGER NOT NULL DEFAULT 1,
        total_pages INTEGER NOT NULL DEFAULT 1,
        PRIMARY KEY (source_id, kind)
      )
    ''');
    await db.execute('''
      CREATE TABLE media_categories (
        source_id TEXT NOT NULL,
        kind      TEXT NOT NULL,
        id        TEXT NOT NULL,
        title     TEXT NOT NULL,
        PRIMARY KEY (source_id, kind, id)
      )
    ''');
    await db.execute('''
      CREATE TABLE media_items (
        source_id   TEXT NOT NULL,
        kind        TEXT NOT NULL,
        id          TEXT NOT NULL,
        title       TEXT NOT NULL,
        parent_id   TEXT,
        category_id TEXT,
        poster      TEXT,
        backdrop    TEXT,
        description TEXT,
        year        TEXT,
        rating      REAL,
        duration_seconds INTEGER,
        season_number INTEGER,
        episode_number INTEGER,
        provider_id TEXT,
        extra       TEXT,
        display_order INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (source_id, kind, id)
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_media_items_source_kind ON media_items(source_id, kind)',
    );
    await db.execute(
      'CREATE INDEX idx_media_items_source_kind_cat ON media_items(source_id, kind, category_id)',
    );
    await _createMediaEnrichment(db);
    await _createMediaPageState(db);
    await _createExternalMetadata(db);
  }

  static Future<void> _addMediaPagingColumns(Database db) async {
    await db.execute(
      'ALTER TABLE media_sync ADD COLUMN loaded_pages INTEGER NOT NULL DEFAULT 1',
    );
    await db.execute(
      'ALTER TABLE media_sync ADD COLUMN total_pages INTEGER NOT NULL DEFAULT 1',
    );
  }

  static Future<void> _createMediaEnrichment(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS media_enrichment (
        source_id     TEXT NOT NULL,
        kind          TEXT NOT NULL,
        media_id      TEXT NOT NULL,
        provider      TEXT NOT NULL,
        provider_id   TEXT,
        title         TEXT,
        overview      TEXT,
        poster        TEXT,
        backdrop      TEXT,
        year          TEXT,
        rating        REAL,
        payload       TEXT,
        refreshed_at  INTEGER NOT NULL,
        PRIMARY KEY (source_id, kind, media_id, provider)
      )
    ''');
  }

  static Future<void> _createMediaPageState(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS media_page_state (
        source_id   TEXT NOT NULL,
        kind        TEXT NOT NULL,
        parent_id   TEXT NOT NULL DEFAULT '',
        category_id TEXT NOT NULL DEFAULT '',
        synced_at   INTEGER NOT NULL,
        loaded_pages INTEGER NOT NULL DEFAULT 1,
        total_pages INTEGER NOT NULL DEFAULT 1,
        PRIMARY KEY (source_id, kind, parent_id, category_id)
      )
    ''');
  }

  static Future<void> _addMediaDisplayOrderColumn(Database db) async {
    await db.execute(
      'ALTER TABLE media_items ADD COLUMN display_order INTEGER NOT NULL DEFAULT 0',
    );
  }

  static Future<void> _addMediaHierarchyColumns(Database db) async {
    Future<void> add(String sql) async {
      try {
        await db.execute(sql);
      } on DatabaseException catch (e) {
        if (!_isDuplicateColumn(e)) rethrow;
      }
    }

    await add('ALTER TABLE media_items ADD COLUMN parent_id TEXT');
    await add('ALTER TABLE media_items ADD COLUMN backdrop TEXT');
    await add('ALTER TABLE media_items ADD COLUMN rating REAL');
    await add('ALTER TABLE media_items ADD COLUMN duration_seconds INTEGER');
    await add('ALTER TABLE media_items ADD COLUMN season_number INTEGER');
    await add('ALTER TABLE media_items ADD COLUMN episode_number INTEGER');
    await add('ALTER TABLE media_items ADD COLUMN provider_id TEXT');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_media_items_parent ON media_items(source_id, kind, parent_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_media_items_provider ON media_items(source_id, kind, provider_id)',
    );
  }

  static Future<void> _addMediaPageParentColumn(Database db) async {
    try {
      await db.execute(
        'ALTER TABLE media_page_state ADD COLUMN parent_id TEXT NOT NULL DEFAULT ""',
      );
    } on DatabaseException catch (e) {
      if (!_isDuplicateColumn(e)) rethrow;
    }
    await db.execute('''
      CREATE TABLE IF NOT EXISTS media_page_state_v7 (
        source_id   TEXT NOT NULL,
        kind        TEXT NOT NULL,
        parent_id   TEXT NOT NULL DEFAULT '',
        category_id TEXT NOT NULL DEFAULT '',
        synced_at   INTEGER NOT NULL,
        loaded_pages INTEGER NOT NULL DEFAULT 1,
        total_pages INTEGER NOT NULL DEFAULT 1,
        PRIMARY KEY (source_id, kind, parent_id, category_id)
      )
    ''');
    await db.execute('''
      INSERT OR REPLACE INTO media_page_state_v7
      (source_id, kind, parent_id, category_id, synced_at, loaded_pages, total_pages)
      SELECT source_id, kind, COALESCE(parent_id, ''), category_id,
             synced_at, loaded_pages, total_pages
      FROM media_page_state
    ''');
    await db.execute('DROP TABLE media_page_state');
    await db.execute(
      'ALTER TABLE media_page_state_v7 RENAME TO media_page_state',
    );
  }

  static Future<void> _addChannelArchiveColumn(Database db) async {
    try {
      await db.execute(
        'ALTER TABLE channels ADD COLUMN archive_days INTEGER NOT NULL DEFAULT 0',
      );
    } on DatabaseException catch (e) {
      if (!_isDuplicateColumn(e)) rethrow;
    }
  }

  static bool _isDuplicateColumn(DatabaseException e) {
    final message = e.toString().toLowerCase();
    return message.contains('duplicate column') ||
        message.contains('duplicate column name');
  }

  static Future<void> _addSourceCacheIdentityColumn(Database db) async {
    try {
      await db.execute('ALTER TABLE sources ADD COLUMN cache_identity TEXT');
    } on DatabaseException catch (e) {
      if (!_isDuplicateColumn(e)) rethrow;
    }
  }

  static Future<void> _createExternalMetadata(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS external_metadata (
        source_id    TEXT NOT NULL,
        media_kind   TEXT NOT NULL,
        media_id     TEXT NOT NULL,
        provider     TEXT NOT NULL,
        provider_key TEXT NOT NULL,
        title        TEXT,
        overview     TEXT,
        poster       TEXT,
        backdrop     TEXT,
        year         TEXT,
        rating       REAL,
        payload      TEXT,
        refreshed_at INTEGER NOT NULL,
        PRIMARY KEY (source_id, media_kind, media_id, provider)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_external_metadata_provider ON external_metadata(provider, provider_key)',
    );
  }

  static Future<void> _createFavorites(Database db) async {
    // Favorited live channels / movies / series, keyed by their source-stable
    // ids. Deliberately separate from `channels` / `media_items` so a library
    // refresh (which replaces those rows) never drops a user's favorites.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS favorites (
        source_id  TEXT NOT NULL,
        kind       TEXT NOT NULL,
        item_id    TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        PRIMARY KEY (source_id, kind, item_id)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_favorites_source_kind ON favorites(source_id, kind)',
    );
  }

  /// Favorite changes made locally that the cloud hasn't been told about yet.
  ///
  /// The cloud merge is a *delta* — devices push what changed, not the whole
  /// set, so two devices editing different favorites can't clobber each other
  /// (`push_favorites_delta`). Computing that delta needs local change
  /// tracking: a favorite present in the cloud but absent locally is either
  /// "deleted here" or "added there and not pulled yet", and nothing in
  /// `favorites` alone can tell those apart.
  ///
  /// An outbox rather than a snapshot of the last push: it is bounded by what
  /// the user actually toggled, not by the size of the library (tens of
  /// thousands of favorites on a large portal).
  ///
  /// `op` is `'add'` or `'remove'`, and the key is the favorite's identity, so
  /// toggling the same item repeatedly collapses to its latest state instead of
  /// queueing a row per press.
  static Future<void> _createFavoritesOutbox(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS favorites_outbox (
        source_id  TEXT NOT NULL,
        kind       TEXT NOT NULL,
        item_id    TEXT NOT NULL,
        op         TEXT NOT NULL,
        updated_at INTEGER NOT NULL,
        PRIMARY KEY (source_id, kind, item_id)
      )
    ''');
  }

  static Future<void> _createPlaybackPositions(Database db) async {
    // VOD resume positions (movies/episodes), keyed like `favorites` by the
    // source-stable ids and deliberately separate from `media_items` so a
    // library refresh never drops them. Finished episodes retain their watched
    // state; finished movies are removed from the resume history.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS playback_positions (
        source_id   TEXT NOT NULL,
        kind        TEXT NOT NULL,
        item_id     TEXT NOT NULL,
        position_ms INTEGER NOT NULL,
        duration_ms INTEGER NOT NULL,
        updated_at  INTEGER NOT NULL,
        PRIMARY KEY (source_id, kind, item_id)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_positions_source_updated '
      'ON playback_positions(source_id, updated_at)',
    );
  }

  static Future<void> _createPlaybackPositionsOutbox(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS playback_positions_outbox (
        source_id   TEXT NOT NULL,
        kind        TEXT NOT NULL,
        item_id     TEXT NOT NULL,
        position_ms INTEGER NOT NULL,
        duration_ms INTEGER NOT NULL,
        updated_at  INTEGER NOT NULL,
        removed     INTEGER NOT NULL,
        PRIMARY KEY (source_id, kind, item_id)
      )
    ''');
  }

  static const _userStateColumns = {
    'favorites': ['source_id', 'kind', 'item_id', 'created_at'],
    'playback_positions': [
      'source_id',
      'kind',
      'item_id',
      'position_ms',
      'duration_ms',
      'updated_at',
    ],
    'epg_channel_overrides': [
      'source_id',
      'channel_id',
      'guide_id',
      'guide_channel_id',
      'offset_minutes',
    ],
  };
  static const _maxUserStateRows = 200000;

  /// Portable user-owned rows, without the regenerable catalogue or its
  /// installation-bound encrypted playback locators.
  Future<Map<String, dynamic>> exportUserState() =>
      _db.transaction((txn) async {
        final result = <String, dynamic>{};
        for (final entry in _userStateColumns.entries) {
          final rows = await txn.query(
            entry.key,
            columns: entry.value,
            orderBy: entry.key == 'epg_channel_overrides'
                ? 'source_id, channel_id'
                : 'source_id, kind, item_id',
            limit: _maxUserStateRows + 1,
          );
          result[entry.key] = [
            for (final row in rows) Map<String, dynamic>.from(row),
          ];
        }
        validateUserState(result);
        return result;
      });

  /// Preflight for a backup before any secure-storage or database writes.
  /// Table and column names are fixed; malformed or future payloads fail closed.
  static void validateUserState(Map<String, dynamic> state) {
    _validatedUserState(state);
  }

  static Map<String, List<Map<String, Object?>>> _validatedUserState(
    Map<String, dynamic> state,
  ) {
    Never invalid() => throw const FormatException('Invalid backup user data.');
    if (state.length != _userStateColumns.length ||
        state.keys.any((table) => !_userStateColumns.containsKey(table))) {
      invalid();
    }
    bool identity(Object? value) =>
        value is String && value.trim().isNotEmpty && value.length <= 4096;
    bool nonnegative(Object? value) =>
        value is int && value >= 0 && value <= 9007199254740991;
    final result = <String, List<Map<String, Object?>>>{};
    for (final entry in _userStateColumns.entries) {
      final rawRows = state[entry.key];
      if (rawRows is! List || rawRows.length > _maxUserStateRows) invalid();
      final rows = <Map<String, Object?>>[];
      final identities = <String>{};
      for (final raw in rawRows) {
        if (raw is! Map ||
            raw.length != entry.value.length ||
            raw.keys.any((column) => !entry.value.contains(column))) {
          invalid();
        }
        final row = <String, Object?>{
          for (final column in entry.value) column: raw[column],
        };
        if (!identity(row['source_id'])) invalid();
        final List<Object?> key;
        if (entry.key == 'epg_channel_overrides') {
          final guide = row['guide_id'];
          final channel = row['guide_channel_id'];
          final offset = row['offset_minutes'];
          if (!identity(row['channel_id']) ||
              (guide == null) != (channel == null) ||
              (guide != null && (!identity(guide) || !identity(channel))) ||
              offset is! int ||
              offset < -24 * 60 ||
              offset > 24 * 60) {
            invalid();
          }
          key = [row['source_id'], row['channel_id']];
        } else {
          final kinds = entry.key == 'favorites'
              ? const ['live', 'movie', 'series']
              : const ['movie', 'episode'];
          if (!identity(row['item_id']) || !kinds.contains(row['kind'])) {
            invalid();
          }
          for (final column in entry.value.skip(3)) {
            if (!nonnegative(row[column])) invalid();
          }
          final timestamp =
              row[entry.key == 'favorites' ? 'created_at' : 'updated_at'];
          if ((timestamp as int) > 8640000000000000) invalid();
          key = [row['source_id'], row['kind'], row['item_id']];
        }
        if (!identities.add(jsonEncode(key))) invalid();
        rows.add(row);
      }
      result[entry.key] = rows;
    }
    return result;
  }

  static Future<void> _createPlaybackCursors(Database db) => db.execute(
    'CREATE TABLE IF NOT EXISTS cloud_playback_cursors '
    '(scope TEXT PRIMARY KEY, cursor INTEGER NOT NULL)',
  );

  Future<int?> playbackCursor(String scope) async {
    final rows = await _db.query(
      'cloud_playback_cursors',
      columns: ['cursor'],
      where: 'scope = ?',
      whereArgs: [scope],
    );
    return rows.isEmpty ? null : rows.single['cursor'] as int;
  }

  Future<void> resetPlaybackCursors() async {
    await _db.delete('cloud_playback_cursors');
  }

  /// Replaces user state atomically. Restored favorites are pending additions
  /// so a later cloud pull cannot silently discard the imported set.
  Future<void> restoreUserState(Map<String, dynamic> state) async {
    // Copy and validate before awaiting, so callers cannot mutate rows between
    // preflight and insertion into the transaction.
    final tables = _validatedUserState(state);
    await _db.transaction((txn) async {
      for (final table in _userStateColumns.keys) {
        await txn.delete(table);
      }
      await txn.delete('favorites_outbox');
      await txn.delete('playback_positions_outbox');
      await txn.delete('cloud_playback_cursors');
      for (final entry in tables.entries) {
        for (var start = 0; start < entry.value.length; start += 1000) {
          final batch = txn.batch();
          for (var i = start; i < entry.value.length && i < start + 1000; i++) {
            batch.insert(entry.key, entry.value[i]);
          }
          await batch.commit(noResult: true);
        }
      }
      await txn.rawInsert(
        'INSERT INTO favorites_outbox '
        '(source_id, kind, item_id, op, updated_at) '
        "SELECT source_id, kind, item_id, 'add', ? FROM favorites",
        [DateTime.now().millisecondsSinceEpoch],
      );
      await txn.rawInsert(
        'INSERT INTO playback_positions_outbox '
        '(source_id, kind, item_id, position_ms, duration_ms, updated_at, removed) '
        'SELECT source_id, kind, item_id, position_ms, duration_ms, updated_at, 0 '
        'FROM playback_positions',
      );
      await txn.update('sources', {'epg_synced_at': null});
    });
  }

  /// Atomically moves every cache and user-state row from the pre-PR4
  /// credential-derived namespace to the stable [SourceConfig.id] namespace.
  ///
  /// A destination collision aborts and rolls back the complete transaction;
  /// callers must run this before publishing or caching rows under [toSourceId].
  Future<void> migrateSourceNamespace(
    String fromSourceId,
    String toSourceId,
  ) async {
    if (fromSourceId == toSourceId) return;
    await _db.transaction((txn) async {
      final batch = txn.batch();
      for (final table in const [
        'categories',
        'channels',
        'programmes',
        'media_sync',
        'media_categories',
        'media_items',
        'media_enrichment',
        'media_page_state',
        'catalog_sync',
        'external_metadata',
        'favorites',
        'favorites_outbox',
        'playback_positions',
        'playback_positions_outbox',
        'epg_channel_overrides',
        'epg_guide_channels',
      ]) {
        batch.update(
          table,
          {'source_id': toSourceId},
          where: 'source_id = ?',
          whereArgs: [fromSourceId],
        );
      }
      batch.update(
        'sources',
        {'id': toSourceId},
        where: 'id = ?',
        whereArgs: [fromSourceId],
      );
      // Checked on every boot for every source, including already-migrated
      // ones. One batch avoids a platform round trip for each cache table.
      await batch.commit(noResult: true);
    });
  }

  /// Rewrites legacy raw-URL M3U channel keys to opaque normalized hashes while
  /// preserving cached channels, EPG references, and live favorites in one
  /// transaction. Equivalent locators intentionally collapse to one channel;
  /// their EPG rows and favorite state are retained under the shared identity.
  ///
  /// Runs on every boot for every M3U source (from `migrateAllSourceIdentities`
  /// before first paint, and again from `HomeShell`), so the already-migrated
  /// case — which is every case after the first — has to be cheap. The probes
  /// below settle it with three indexed `LIMIT 1` lookups instead of reading
  /// the whole `channels` table and scanning `favorites` and `programmes`.
  /// True when any `channels`, `favorites`, or `programmes` row for [sourceId]
  /// still carries a pre-migration (raw locator) M3U key.
  ///
  /// Each probe is an existence check the covering index can answer on its own:
  /// `channels` and `favorites` both have a composite primary key whose
  /// auto-index carries the id column, and `programmes` has
  /// `idx_prog_lookup(source_id, channel_id, start)`. So the already-migrated
  /// case never touches a table row — where the migration body below would
  /// otherwise read every channel's `extra` blob and JSON-decode it.
  ///
  /// The `channels` probe uses `GLOB` rather than `LIKE` because `LIKE` is
  /// ASCII-case-insensitive in SQLite while `isStableM3uChannelId` is a
  /// case-sensitive `startsWith`; `GLOB` matches the Dart predicate exactly.
  /// The other two mirror the `NOT LIKE` predicates the body itself uses, so
  /// probe and body can never disagree about which rows need work.
  Future<bool> _hasLegacyM3uIds(String sourceId) async {
    Future<bool> any(String sql, List<Object?> args) async =>
        (await _db.rawQuery(sql, args)).isNotEmpty;

    return await any(
          'SELECT 1 FROM channels WHERE source_id = ? '
          "AND id NOT GLOB 'm3u-channel:*' LIMIT 1",
          [sourceId],
        ) ||
        await any(
          'SELECT 1 FROM favorites WHERE source_id = ? AND kind = ? '
          "AND item_id NOT LIKE 'm3u-channel:%' LIMIT 1",
          [sourceId, ContentKind.live.name],
        ) ||
        await any(
          'SELECT 1 FROM programmes WHERE source_id = ? '
          "AND channel_id NOT LIKE 'm3u-channel:%' LIMIT 1",
          [sourceId],
        );
  }

  Future<void> migrateM3uChannelIds(String sourceId) async {
    if (!await _hasLegacyM3uIds(sourceId)) return;
    await _db.transaction((txn) async {
      final mappings = <String, String>{};
      final channelRows = await txn.query(
        'channels',
        columns: ['id', 'extra'],
        where: 'source_id = ?',
        whereArgs: [sourceId],
      );
      for (final row in channelRows) {
        final oldId = row['id'] as String;
        if (isStableM3uChannelId(oldId)) continue;
        final extra = row['extra'] as String?;
        final decoded = extra == null
            ? const <String, dynamic>{}
            : Map<String, dynamic>.from(jsonDecode(extra) as Map);
        final locator = decoded['url']?.toString() ?? oldId;
        mappings[oldId] = stableM3uChannelId(locator);
      }

      // Favorites/EPG can outlive a replaced channel cache. Their legacy M3U
      // keys were the raw locator itself, so migrate any remaining references.
      final favoriteRows = await txn.query(
        'favorites',
        columns: ['item_id'],
        where: 'source_id = ? AND kind = ? AND item_id NOT LIKE ?',
        whereArgs: [sourceId, ContentKind.live.name, 'm3u-channel:%'],
      );
      for (final row in favoriteRows) {
        final oldId = row['item_id'] as String;
        mappings.putIfAbsent(oldId, () => stableM3uChannelId(oldId));
      }
      final programmeRows = await txn.rawQuery(
        'SELECT DISTINCT channel_id FROM programmes '
        'WHERE source_id = ? AND channel_id NOT LIKE ?',
        [sourceId, 'm3u-channel:%'],
      );
      for (final row in programmeRows) {
        final oldId = row['channel_id'] as String;
        mappings.putIfAbsent(oldId, () => stableM3uChannelId(oldId));
      }

      for (final entry in mappings.entries) {
        final oldId = entry.key;
        final newId = entry.value;
        if (oldId == newId) continue;
        await txn.rawInsert(
          'INSERT OR IGNORE INTO channels '
          '(source_id, id, name, number, logo, category_id, extra, archive_days) '
          'SELECT source_id, ?, name, number, logo, category_id, extra, archive_days '
          'FROM channels WHERE source_id = ? AND id = ?',
          [newId, sourceId, oldId],
        );
        await txn.delete(
          'channels',
          where: 'source_id = ? AND id = ?',
          whereArgs: [sourceId, oldId],
        );
        await txn.update(
          'programmes',
          {'channel_id': newId},
          where: 'source_id = ? AND channel_id = ?',
          whereArgs: [sourceId, oldId],
        );
        await txn.update(
          'epg_channel_overrides',
          {'channel_id': newId},
          where: 'source_id = ? AND channel_id = ?',
          whereArgs: [sourceId, oldId],
        );
        await txn.rawInsert(
          'INSERT OR IGNORE INTO favorites (source_id, kind, item_id, created_at) '
          'SELECT source_id, kind, ?, created_at FROM favorites '
          'WHERE source_id = ? AND kind = ? AND item_id = ?',
          [newId, sourceId, ContentKind.live.name, oldId],
        );
        await txn.delete(
          'favorites',
          where: 'source_id = ? AND kind = ? AND item_id = ?',
          whereArgs: [sourceId, ContentKind.live.name, oldId],
        );
      }
    });
  }

  // ── playback positions (VOD resume) ───────────────────────────────────────

  /// Upsert playback progress, retaining finished episodes for the watched
  /// indicator. Finished movies are cleared; neither appears in recents.
  static const kFinishedFraction = 0.95;

  Future<void> savePlaybackPosition(
    String sourceId,
    ContentKind kind,
    String itemId, {
    required Duration position,
    required Duration duration,
  }) async {
    if (kind != ContentKind.episode &&
        duration > Duration.zero &&
        position.inMilliseconds >=
            duration.inMilliseconds * kFinishedFraction) {
      await clearPlaybackPosition(sourceId, kind, itemId);
      return;
    }
    // Ignore the first instants — a resume row for second 0 is just noise.
    if (position < const Duration(seconds: 10)) return;
    await _writePlaybackPosition(
      sourceId,
      kind,
      itemId,
      positionMs: position.inMilliseconds,
      durationMs: duration.inMilliseconds,
      removed: false,
    );
  }

  Future<PlaybackPosition?> readPlaybackPosition(
    String sourceId,
    ContentKind kind,
    String itemId,
  ) async {
    final rows = await _db.query(
      'playback_positions',
      where: 'source_id = ? AND kind = ? AND item_id = ?',
      whereArgs: [sourceId, kind.name, itemId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final position = _rowToPlaybackPosition(rows.first);
    return position.isFinished ? null : position;
  }

  /// Saved progress and watched states for only the displayed episodes.
  Future<Map<String, PlaybackPosition>> readEpisodePlaybackPositions(
    String sourceId,
    List<String> itemIds,
  ) async {
    final positions = <String, PlaybackPosition>{};
    final ids = itemIds.toSet().toList();
    // Keep every query under SQLite's portable bind-parameter limit.
    for (var start = 0; start < ids.length; start += 900) {
      final chunk = ids.sublist(start, (start + 900).clamp(0, ids.length));
      final placeholders = List.filled(chunk.length, '?').join(', ');
      final rows = await _db.query(
        'playback_positions',
        where: 'source_id = ? AND kind = ? AND item_id IN ($placeholders)',
        whereArgs: [sourceId, ContentKind.episode.name, ...chunk],
      );
      for (final row in rows) {
        final position = _rowToPlaybackPosition(row);
        positions[position.itemId] = position;
      }
    }
    return positions;
  }

  Future<void> clearPlaybackPosition(
    String sourceId,
    ContentKind kind,
    String itemId,
  ) => _writePlaybackPosition(
    sourceId,
    kind,
    itemId,
    positionMs: 0,
    durationMs: 0,
    removed: true,
  );

  final _playbackPositionsChanged = StreamController<void>.broadcast();
  Stream<void> get playbackPositionsChanged => _playbackPositionsChanged.stream;

  /// A lifecycle checkpoint has committed and should bypass cloud throttling.
  final _playbackCheckpointed = StreamController<void>.broadcast();
  Stream<void> get playbackCheckpointed => _playbackCheckpointed.stream;

  void notifyPlaybackCheckpoint() {
    if (!_playbackCheckpointed.isClosed) _playbackCheckpointed.add(null);
  }

  final _playbackPositionsReplaced = StreamController<void>.broadcast();
  Stream<void> get playbackPositionsReplaced =>
      _playbackPositionsReplaced.stream;

  Future<void> _writePlaybackPosition(
    String sourceId,
    ContentKind kind,
    String itemId, {
    required int positionMs,
    required int durationMs,
    required bool removed,
  }) async {
    await _db.transaction((txn) async {
      final identity = [sourceId, kind.name, itemId];
      final previous = await txn.query(
        'playback_positions_outbox',
        columns: ['updated_at'],
        where: 'source_id = ? AND kind = ? AND item_id = ?',
        whereArgs: identity,
        limit: 1,
      );
      final current = await txn.query(
        'playback_positions',
        columns: ['updated_at'],
        where: 'source_id = ? AND kind = ? AND item_id = ?',
        whereArgs: identity,
        limit: 1,
      );
      var version = DateTime.now().millisecondsSinceEpoch;
      for (final row in [...previous, ...current]) {
        final timestamp = row['updated_at'] as int;
        if (version <= timestamp) version = timestamp + 1;
      }
      final row = <String, Object?>{
        'source_id': sourceId,
        'kind': kind.name,
        'item_id': itemId,
        'position_ms': positionMs,
        'duration_ms': durationMs,
        'updated_at': version,
      };
      if (removed) {
        await txn.delete(
          'playback_positions',
          where: 'source_id = ? AND kind = ? AND item_id = ?',
          whereArgs: identity,
        );
      } else {
        await txn.insert(
          'playback_positions',
          row,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await txn.insert('playback_positions_outbox', {
        ...row,
        'removed': removed ? 1 : 0,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
    if (!_playbackPositionsChanged.isClosed) {
      _playbackPositionsChanged.add(null);
    }
  }

  static PlaybackPositionChange _rowToPlaybackChange(
    Map<String, Object?> row,
  ) => (
    sourceId: row['source_id'] as String,
    kind: ContentKind.values.byName(row['kind'] as String),
    itemId: row['item_id'] as String,
    positionMs: row['position_ms'] as int,
    durationMs: row['duration_ms'] as int,
    updatedAt: row['updated_at'] as int,
    removed: row['removed'] == 1,
  );

  Future<List<PlaybackPositionChange>> readPlaybackOutbox() async => [
    for (final row in await _db.query(
      'playback_positions_outbox',
      orderBy: 'updated_at',
    ))
      _rowToPlaybackChange(row),
  ];

  /// Current progress for an explicit full upload; pending removals remain in
  /// [readPlaybackOutbox] and must also be included by the caller.
  Future<List<PlaybackPositionChange>> readPlaybackPositionsForSync() async => [
    for (final row in await _db.query('playback_positions'))
      _rowToPlaybackChange(row),
  ];

  Future<void> clearPlaybackOutbox(
    List<PlaybackPositionChange> delivered,
  ) async {
    if (delivered.isEmpty) return;
    final batch = _db.batch();
    for (final entry in delivered) {
      batch.delete(
        'playback_positions_outbox',
        where: 'source_id = ? AND kind = ? AND item_id = ? AND updated_at = ?',
        whereArgs: [
          entry.sourceId,
          entry.kind.name,
          entry.itemId,
          entry.updatedAt,
        ],
      );
    }
    await batch.commit(noResult: true);
  }

  /// Mirrors only managed sources, retaining newer unsent progress and removals.
  /// Timestamps resolve conflicts, with removal winning ties, as on the server.
  /// The pending overlay is read inside the same transaction as the replacement.
  Future<void> applyCloudPlaybackPositions(
    Set<String> managedIds,
    List<PlaybackPositionChange> remote, {
    bool replace = true,
    String? cursorScope,
    int? cursor,
  }) async {
    await _db.transaction((txn) async {
      final pending = await txn.query('playback_positions_outbox');
      final batch = txn.batch();
      for (final sourceId in replace ? managedIds : <String>{}) {
        batch.delete(
          'playback_positions',
          where: 'source_id = ?',
          whereArgs: [sourceId],
        );
      }
      final merged = <(String, ContentKind, String), PlaybackPositionChange>{};
      final existing = <PlaybackPositionChange>[];
      if (!replace) {
        for (final entry in remote) {
          final rows = await txn.query(
            'playback_positions',
            where: 'source_id = ? AND kind = ? AND item_id = ?',
            whereArgs: [entry.sourceId, entry.kind.name, entry.itemId],
          );
          existing.addAll(
            rows.map((row) => _rowToPlaybackChange({...row, 'removed': 0})),
          );
        }
      }
      for (final entry in [
        ...existing,
        ...remote,
        for (final row in pending) _rowToPlaybackChange(row),
      ]) {
        if (!managedIds.contains(entry.sourceId)) continue;
        final key = (entry.sourceId, entry.kind, entry.itemId);
        final previous = merged[key];
        if (previous == null ||
            entry.updatedAt > previous.updatedAt ||
            (entry.updatedAt == previous.updatedAt && entry.removed)) {
          merged[key] = entry;
        }
      }
      if (cursorScope != null && cursor != null) {
        batch.insert('cloud_playback_cursors', {
          'scope': cursorScope,
          'cursor': cursor,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final entry in merged.values) {
        if (entry.removed) {
          batch.delete(
            'playback_positions',
            where: 'source_id = ? AND kind = ? AND item_id = ?',
            whereArgs: [entry.sourceId, entry.kind.name, entry.itemId],
          );
        } else {
          batch.insert('playback_positions', {
            'source_id': entry.sourceId,
            'kind': entry.kind.name,
            'item_id': entry.itemId,
            'position_ms': entry.positionMs,
            'duration_ms': entry.durationMs,
            'updated_at': entry.updatedAt,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
      await batch.commit(noResult: true);
    });
    if (!_playbackPositionsReplaced.isClosed) {
      _playbackPositionsReplaced.add(null);
    }
  }

  /// Most recently watched in-progress items for [sourceId], newest first —
  /// the data behind the "Continue watching" rail.
  Future<List<PlaybackPosition>> readRecentPositions(
    String sourceId, {
    int limit = 20,
  }) async {
    final rows = await _db.query(
      'playback_positions',
      where:
          'source_id = ? AND '
          '(duration_ms <= 0 OR position_ms < duration_ms * ?)',
      whereArgs: [sourceId, kFinishedFraction],
      orderBy: 'updated_at DESC',
      limit: limit,
    );
    return rows.map(_rowToPlaybackPosition).toList();
  }

  static PlaybackPosition _rowToPlaybackPosition(Map<String, Object?> r) =>
      PlaybackPosition(
        kind: ContentKind.values.byName(r['kind'] as String),
        itemId: r['item_id'] as String,
        position: Duration(milliseconds: r['position_ms'] as int),
        duration: Duration(milliseconds: r['duration_ms'] as int),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(r['updated_at'] as int),
      );

  // ── favorites ─────────────────────────────────────────────────────────────

  /// The set of favorited item ids for [sourceId] / [kind].
  Future<Set<String>> readFavoriteIds(String sourceId, ContentKind kind) async {
    final rows = await _db.query(
      'favorites',
      columns: ['item_id'],
      where: 'source_id = ? AND kind = ?',
      whereArgs: [sourceId, kind.name],
    );
    return {for (final r in rows) r['item_id'] as String};
  }

  Future<bool> isFavorite(
    String sourceId,
    ContentKind kind,
    String itemId,
  ) async {
    final rows = await _db.query(
      'favorites',
      columns: ['item_id'],
      where: 'source_id = ? AND kind = ? AND item_id = ?',
      whereArgs: [sourceId, kind.name, itemId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// Adds or removes a favorite. Returns the new favorited state.
  ///
  /// Commits the favorite and its pending cloud change together. A cloud pull
  /// cannot observe a local edit without its outbox entry and overwrite it.
  Future<bool> setFavorite(
    String sourceId,
    ContentKind kind,
    String itemId,
    bool favorite,
  ) async {
    await _db.transaction((txn) async {
      if (favorite) {
        await txn.insert('favorites', {
          'source_id': sourceId,
          'kind': kind.name,
          'item_id': itemId,
          'created_at': DateTime.now().millisecondsSinceEpoch,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      } else {
        await txn.delete(
          'favorites',
          where: 'source_id = ? AND kind = ? AND item_id = ?',
          whereArgs: [sourceId, kind.name, itemId],
        );
      }
      await _recordFavoriteChange(txn, sourceId, kind, itemId, favorite);
    });
    if (!_favoritesChanged.isClosed) _favoritesChanged.add(null);
    return favorite;
  }

  // ── favorites outbox (pending cloud delta) ────────────────────────────────

  /// Records a local favorite change for the next cloud push.
  ///
  /// Keyed on the favorite's identity, so toggling one item repeatedly leaves a
  /// single row carrying its latest state rather than a queue of presses.
  ///
  /// Deliberately **not** called by the cloud *pull*: applying the cloud's own
  /// state is not a local change, and queueing it would push the cloud's data
  /// straight back at it — and, worse, resurrect anything the pull had just
  /// deleted.
  /// Fires after a local favorite change is queued in the outbox.
  ///
  /// Lets the cloud auto-sync react without every favorite-toggling widget
  /// having to know it exists — `setFavorite` is already the one choke point
  /// for user intent, so the signal belongs here rather than threaded through
  /// the UI.
  Stream<void> get favoritesChanged => _favoritesChanged.stream;
  final StreamController<void> _favoritesChanged =
      StreamController<void>.broadcast();

  /// Fires when a source's cached guide has been replaced, carrying that
  /// source's id.
  ///
  /// The EPG refresh runs behind `LibraryRepository.load`'s returned snapshot
  /// (see [epgIngest]), so the guide lands *after* the channel list is already
  /// on screen. Without this the live list would keep showing whatever now/next
  /// it read before the refresh until its one-minute poll came round — up to a
  /// minute of a visibly stale guide right after the user asked for a refresh.
  Stream<String> get epgChanged => _epgChanged.stream;
  final StreamController<String> _epgChanged =
      StreamController<String>.broadcast();

  /// Announces that [sourceId]'s guide has been replaced.
  void notifyEpgChanged(String sourceId) {
    if (!_epgChanged.isClosed) _epgChanged.add(sourceId);
  }

  /// The single slot every background EPG refresh runs in.
  ///
  /// It lives on the database rather than on `LibraryRepository` because the
  /// resource being contended for is *this connection*: sqflite serialises all
  /// work on it, repositories are built and discarded per source, and two
  /// overlapping guide ingests would queue against each other with neither
  /// aware the other exists. Everything sharing a database therefore shares the
  /// slot, with no call site having to pass one around.
  final EpgIngestCoordinator epgIngest = EpgIngestCoordinator();

  /// Fires when favorites were rewritten by something other than the user —
  /// today only the cloud pull, via [notifyFavoritesReplaced].
  ///
  /// Kept separate from [favoritesChanged] on purpose: that one means "the user
  /// changed something, push it", and feeding a pull into it would push the
  /// cloud's own state straight back. This one means "re-read, your in-memory
  /// set is stale", which is what the favorites controllers need — otherwise a
  /// background pull leaves the on-screen stars disagreeing with the database
  /// until an unrelated reload, and the next toggle writes from a stale set.
  Stream<void> get favoritesReplaced => _favoritesReplaced.stream;
  final StreamController<void> _favoritesReplaced =
      StreamController<void>.broadcast();

  /// Announces that favorites were replaced wholesale (the cloud pull).
  void notifyFavoritesReplaced() {
    if (!_favoritesReplaced.isClosed) _favoritesReplaced.add(null);
  }

  Future<void> recordFavoriteChange(
    String sourceId,
    ContentKind kind,
    String itemId,
    bool favorite,
  ) async {
    await _db.transaction(
      (txn) => _recordFavoriteChange(txn, sourceId, kind, itemId, favorite),
    );
    if (!_favoritesChanged.isClosed) _favoritesChanged.add(null);
  }

  Future<void> _recordFavoriteChange(
    DatabaseExecutor txn,
    String sourceId,
    ContentKind kind,
    String itemId,
    bool favorite,
  ) async {
    final previous = await txn.query(
      'favorites_outbox',
      columns: ['updated_at'],
      where: 'source_id = ? AND kind = ? AND item_id = ?',
      whereArgs: [sourceId, kind.name, itemId],
      limit: 1,
    );
    var version = DateTime.now().millisecondsSinceEpoch;
    if (previous.isNotEmpty &&
        version <= (previous.single['updated_at'] as int)) {
      version = (previous.single['updated_at'] as int) + 1;
    }
    await txn.insert('favorites_outbox', {
      'source_id': sourceId,
      'kind': kind.name,
      'item_id': itemId,
      'op': favorite ? 'add' : 'remove',
      'updated_at': version,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Pending favorite changes, oldest first.
  Future<List<FavoriteChange>> readFavoritesOutbox() async {
    final rows = await _db.query('favorites_outbox', orderBy: 'updated_at');
    return [
      for (final row in rows)
        if (ContentKind.values.asNameMap()[row['kind'] as String]
            case final kind?)
          (
            sourceId: row['source_id'] as String,
            kind: kind,
            itemId: row['item_id'] as String,
            add: row['op'] == 'add',
            updatedAt: row['updated_at'] as int,
          ),
    ];
  }

  /// Clears outbox rows that a push has now delivered.
  ///
  /// Takes the exact entries that were pushed rather than truncating the table:
  /// a toggle made *while* the push was in flight has already replaced its row,
  /// and clearing wholesale would drop that change on the floor. Rows whose
  /// version no longer matches what was pushed are therefore left alone, even
  /// when an item was removed and added again during the same upload.
  Future<void> clearFavoritesOutbox(List<FavoriteChange> delivered) async {
    if (delivered.isEmpty) return;
    final batch = _db.batch();
    for (final entry in delivered) {
      batch.delete(
        'favorites_outbox',
        where:
            'source_id = ? AND kind = ? AND item_id = ? AND op = ? '
            'AND updated_at = ?',
        whereArgs: [
          entry.sourceId,
          entry.kind.name,
          entry.itemId,
          entry.add ? 'add' : 'remove',
          entry.updatedAt,
        ],
      );
    }
    await batch.commit(noResult: true);
  }

  /// Replaces a profile's favorites atomically, retaining local pending edits.
  /// Reading the outbox inside the transaction also protects edits committed
  /// while the cloud snapshot was being downloaded.
  Future<void> applyCloudFavorites(
    Set<String> managedIds,
    Map<String, Map<ContentKind, Set<String>>> incoming,
  ) async {
    const kinds = [ContentKind.live, ContentKind.movie, ContentKind.series];
    await _db.transaction((txn) async {
      final merged = <String, Map<ContentKind, Set<String>>>{
        for (final source in incoming.entries)
          if (managedIds.contains(source.key))
            source.key: {
              for (final kind in source.value.entries)
                if (kinds.contains(kind.key)) kind.key: {...kind.value},
            },
      };
      for (final row in await txn.query('favorites_outbox')) {
        final sourceId = row['source_id'] as String;
        if (!managedIds.contains(sourceId)) continue;
        final kind = ContentKind.values.asNameMap()[row['kind']];
        if (!kinds.contains(kind)) continue;
        final ids = (merged[sourceId] ??= {})[kind!] ??= {};
        final itemId = row['item_id'] as String;
        if (row['op'] == 'add') {
          ids.add(itemId);
        } else {
          ids.remove(itemId);
        }
      }
      final batch = txn.batch();
      for (final sourceId in managedIds) {
        batch.delete(
          'favorites',
          where: 'source_id = ? AND kind IN (?, ?, ?)',
          whereArgs: [sourceId, ...kinds.map((kind) => kind.name)],
        );
      }
      final createdAt = DateTime.now().millisecondsSinceEpoch;
      for (final source in merged.entries) {
        for (final kind in source.value.entries) {
          for (final itemId in kind.value) {
            batch.insert('favorites', {
              'source_id': source.key,
              'kind': kind.key.name,
              'item_id': itemId,
              'created_at': createdAt,
            }, conflictAlgorithm: ConflictAlgorithm.replace);
          }
        }
      }
      await batch.commit(noResult: true);
    });
    notifyFavoritesReplaced();
  }

  /// Removes every favorite of [kind] for [sourceId] in one statement.
  ///
  /// Exists for the cloud pull, which mirrors the profile: it used to read the
  /// existing ids back and call [setFavorite] once per row, each of those its
  /// own implicit transaction (and its own fsync on desktop).
  Future<void> clearFavorites(String sourceId, ContentKind kind) async {
    await _db.delete(
      'favorites',
      where: 'source_id = ? AND kind = ?',
      whereArgs: [sourceId, kind.name],
    );
  }

  /// Marks [itemIds] as favorites of [kind] for [sourceId] in a single
  /// transaction. Same row semantics as [setFavorite] with `favorite: true`
  /// (upsert, `created_at` = now), just not one transaction per id.
  Future<void> setFavorites(
    String sourceId,
    ContentKind kind,
    Iterable<String> itemIds,
  ) async {
    final ids = itemIds.toList();
    if (ids.isEmpty) return;
    final createdAt = DateTime.now().millisecondsSinceEpoch;
    await _db.transaction((txn) async {
      final batch = txn.batch();
      for (final itemId in ids) {
        batch.insert('favorites', {
          'source_id': sourceId,
          'kind': kind.name,
          'item_id': itemId,
          'created_at': createdAt,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
  }

  // ── channels / categories ───────────────────────────────────────────────

  Future<DateTime?> lastSynced(String sourceId) =>
      _readTime('synced_at', sourceId);

  /// Whether a source has cached TV channels or root movies/series to browse.
  Future<bool> hasLibraryContent(String sourceId) async {
    final rows = await _db.rawQuery(
      'SELECT EXISTS (SELECT 1 FROM channels WHERE source_id = ?) '
      'OR EXISTS (SELECT 1 FROM media_items '
      'WHERE source_id = ? AND kind IN (?, ?) '
      "AND (parent_id IS NULL OR parent_id = '')) AS has_content",
      [sourceId, sourceId, ContentKind.movie.name, ContentKind.series.name],
    );
    return (rows.first['has_content'] as int) != 0;
  }

  Future<DateTime?> lastEpgSynced(String sourceId) =>
      _readTime('epg_synced_at', sourceId);

  /// Forgets when [sourceId]'s guide was last fetched, so the next load
  /// refetches it instead of serving the cache.
  ///
  /// `LibraryRepository._ensureEpg` skips the fetch entirely while the guide is
  /// younger than its max age, which is the right default for a background
  /// refresh but wrong after the *set of guides* changes: adding an EPG guide
  /// would otherwise do nothing visible for hours, reading as a broken feature.
  ///
  /// Deliberately leaves the cached `programmes` in place. Clearing them would
  /// blank every channel's EPG for however long the refetch takes — and if it
  /// fails, for the whole retry interval — where keeping them means the worst
  /// case is the guide the user already had.
  Future<void> invalidateEpg(String sourceId) async {
    await _db.update(
      'sources',
      {'epg_synced_at': null},
      where: 'id = ?',
      whereArgs: [sourceId],
    );
    epgIngest.deferRetry(sourceId, null);
  }

  Future<DateTime?> _readTime(String column, String sourceId) async {
    final rows = await _db.query(
      'sources',
      columns: [column],
      where: 'id = ?',
      whereArgs: [sourceId],
    );
    final v = rows.isEmpty ? null : rows.first[column];
    return v == null ? null : DateTime.fromMillisecondsSinceEpoch(v as int);
  }

  /// Cached categories for a source, **in the provider's own order**.
  ///
  /// This used to be `ORDER BY title`, and that made the category pane change
  /// order depending on where the snapshot came from: a fresh load shows
  /// `Source.categories()` — the provider's arrangement, which is the one the
  /// user recognises — while every subsequent cached load re-sorted it
  /// alphabetically. So the pane silently reshuffled between a forced refresh
  /// and the next app start, and once Favorites started deriving their order
  /// from the category order (`favorites_order.dart`), the favorites list
  /// reshuffled with it.
  ///
  /// **`rowid` is the provider's position, because this table is never patched
  /// in place.** [replaceLibrary] deletes the source's rows and re-inserts the
  /// whole list, in list order, inside one transaction; sqflite's batch keeps
  /// that order, so SQLite hands out ascending rowids along it. That full
  /// rewrite is what makes an implicit rowid sound here rather than a stored
  /// `position` column — the column would be a second copy of a number the
  /// table already has, bought with a schema migration. **If a path is ever
  /// added that updates categories in place, add the column instead.**
  ///
  /// Two things that look like hazards and aren't: `VACUUM` renumbers rowids on
  /// a table with no `INTEGER PRIMARY KEY`, but it rewrites rows *in rowid
  /// order*, so relative order survives — and nothing in this app vacuums
  /// anyway. A duplicate category id inside one provider payload is collapsed
  /// by `ConflictAlgorithm.replace` and takes the *later* position, which is
  /// the same row the old alphabetical read would have shown.
  Future<List<Category>> readCategories(String sourceId) async {
    final rows = await _db.query(
      'categories',
      where: 'source_id = ?',
      whereArgs: [sourceId],
      orderBy: 'rowid',
    );
    return rows
        .map(
          (r) => Category(id: r['id'] as String, title: r['title'] as String),
        )
        .toList();
  }

  Future<List<Channel>> readChannels(String sourceId) async {
    final rows = await _db.query(
      'channels',
      where: 'source_id = ?',
      whereArgs: [sourceId],
      orderBy: 'number, name',
    );
    // Synchronous mapping, no crypto: the returned channels keep their locator
    // SEALED in `extra['secretLocator']`. Decrypting 250k rows to play one of
    // them was the dominant cost of a cached start; `revealChannel` opens the
    // one model that is about to be played instead; see docs/development.md.
    return [
      for (final row in rows) _channelFromRow(row, _decodeExtra(row['extra'])),
    ];
  }

  /// Indexed lookup for an inactive source, retaining the sealed locator just
  /// like a bulk channel read. Scheduled recording resolves only this row.
  Future<Channel?> readChannel(String sourceId, String channelId) async {
    final rows = await _db.query(
      'channels',
      where: 'source_id = ? AND id = ?',
      whereArgs: [sourceId, channelId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _channelFromRow(rows.single, _decodeExtra(rows.single['extra']));
  }

  /// Every favorited live channel across *all* sources, each paired with the
  /// id of the source that owns it.
  ///
  /// Backs the cross-source ("all sources") Favorites view. Favorites are
  /// already stored cross-source — the `favorites` primary key is
  /// `(source_id, kind, item_id)` — so this needs no catalog to be loaded and
  /// no source to be active: it reads the `channels` rows every source left
  /// behind the last time it was opened.
  ///
  /// Rows whose channel is no longer cached are skipped by the inner join
  /// rather than surfaced as ghosts: a favorite can outlive the catalog row it
  /// points at (a refresh replaces `channels`, and `favorites` deliberately
  /// survives that — see [_createFavorites]).
  ///
  /// Like [readChannels] this maps synchronously with no crypto, so the
  /// channels come back with their locators **sealed**; the caller reveals the
  /// one it is about to play through the owning source's repository. See
  /// docs/development.md "Sealed playback locators".
  Future<List<({String sourceId, Channel channel})>>
  readFavoriteChannelsAcrossSources() async {
    final rows = await _db.rawQuery(
      '''
      SELECT c.*, f.created_at AS favorited_at
        FROM favorites f
        JOIN channels c
          ON c.source_id = f.source_id AND c.id = f.item_id
       WHERE f.kind = ?
       ORDER BY c.number, c.name
    ''',
      [ContentKind.live.name],
    );
    return [
      for (final row in rows)
        (
          sourceId: row['source_id'] as String,
          channel: _channelFromRow(row, _decodeExtra(row['extra'])),
        ),
    ];
  }

  /// Decrypts the sealed playback locator on a cached [channel] so it can be
  /// handed to the owning [Source]. A no-op for a channel that already carries
  /// plaintext locators (one straight off the provider), so it is always safe
  /// to call. Only [LibraryRepository] should need this.
  Future<Channel> revealChannel(Channel channel) async {
    if (!hasSealedLocator(channel.extra)) return channel;
    return Channel(
      id: channel.id,
      name: channel.name,
      logo: channel.logo,
      categoryId: channel.categoryId,
      number: channel.number,
      archiveDays: channel.archiveDays,
      extra: await restoreSecretLocators(channel.extra, _vault),
    );
  }

  // ── movies / series / generic media ──────────────────────────────────────

  /// Last complete root catalog import. Legacy page caches do not establish
  /// completeness, even when their paging state happens to say 1/1.
  Future<DateTime?> lastCatalogSynced(String sourceId, ContentKind kind) async {
    final stamp = await _catalogStamp(_db, sourceId, kind);
    return stamp == null ? null : DateTime.fromMillisecondsSinceEpoch(stamp);
  }

  static Future<int?> _catalogStamp(
    DatabaseExecutor executor,
    String sourceId,
    ContentKind kind,
  ) async {
    final rows = await executor.query(
      'catalog_sync',
      columns: ['synced_at'],
      where: 'source_id = ? AND kind = ?',
      whereArgs: [sourceId, kind.name],
    );
    return rows.isEmpty ? null : rows.single['synced_at'] as int;
  }

  Future<DateTime?> lastMediaSynced(String sourceId, ContentKind kind) async {
    final rows = await _db.query(
      'media_sync',
      columns: ['synced_at'],
      where: 'source_id = ? AND kind = ?',
      whereArgs: [sourceId, kind.name],
    );
    if (rows.isEmpty) return null;
    return DateTime.fromMillisecondsSinceEpoch(rows.first['synced_at'] as int);
  }

  Future<({DateTime syncedAt, int loadedPages, int totalPages})?>
  mediaSyncState(
    String sourceId,
    ContentKind kind, {
    String? categoryId,
    String? parentId,
  }) async {
    if (parentId == null) {
      final complete = await lastCatalogSynced(sourceId, kind);
      if (complete != null) {
        return (syncedAt: complete, loadedPages: 1, totalPages: 1);
      }
    }
    final categoryKey = categoryId ?? '';
    final parentKey = parentId ?? '';
    final pageRows = await _db.query(
      'media_page_state',
      where: 'source_id = ? AND kind = ? AND parent_id = ? AND category_id = ?',
      whereArgs: [sourceId, kind.name, parentKey, categoryKey],
    );
    if (pageRows.isNotEmpty) {
      final row = pageRows.first;
      return (
        syncedAt: DateTime.fromMillisecondsSinceEpoch(row['synced_at'] as int),
        loadedPages: row['loaded_pages'] as int? ?? 1,
        totalPages: row['total_pages'] as int? ?? 1,
      );
    }
    if (categoryId != null || parentId != null) return null;
    final rows = await _db.query(
      'media_sync',
      where: 'source_id = ? AND kind = ?',
      whereArgs: [sourceId, kind.name],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return (
      syncedAt: DateTime.fromMillisecondsSinceEpoch(row['synced_at'] as int),
      loadedPages: row['loaded_pages'] as int? ?? 1,
      totalPages: row['total_pages'] as int? ?? 1,
    );
  }

  /// Cached media categories for a source/kind, in the provider's own order —
  /// same reasoning as [readCategories], including why `rowid` is the position.
  ///
  /// `replaceMediaLibrary`'s one asymmetry is harmless here: the paged
  /// (`parentId != null`) path re-inserts the categories without deleting them
  /// first, so `ConflictAlgorithm.replace` moves every one of them to fresh
  /// rowids — but it re-inserts the *whole* list in list order, so their order
  /// relative to each other is unchanged.
  Future<List<MediaCategory>> readMediaCategories(
    String sourceId,
    ContentKind kind,
  ) async {
    final rows = await _db.query(
      'media_categories',
      where: 'source_id = ? AND kind = ?',
      whereArgs: [sourceId, kind.name],
      orderBy: 'rowid',
    );
    return rows
        .map(
          (r) => MediaCategory(
            id: r['id'] as String,
            title: r['title'] as String,
            kind: kind,
          ),
        )
        .toList();
  }

  Future<List<MediaItem>> readMediaItems(
    String sourceId,
    ContentKind kind, {
    String? categoryId,
    String? parentId,
  }) async {
    final where = StringBuffer('source_id = ? AND kind = ?');
    final args = <Object?>[sourceId, kind.name];
    if (categoryId != null) {
      where.write(' AND category_id = ?');
      args.add(categoryId);
    }
    if (parentId != null) {
      where.write(' AND parent_id = ?');
      args.add(parentId);
    }
    return _db.transaction<List<MediaItem>>((txn) async {
      final rows = await txn.query(
        'media_items',
        columns: ['id'],
        where: where.toString(),
        whereArgs: args,
        orderBy: 'display_order, title',
      );
      return _readOrderedMediaItems(
        txn,
        kind,
        [for (final row in rows) row['id'] as String],
        where: where.toString(),
        whereArgs: args,
      );
    });
  }

  Future<int> countMediaItems(String sourceId, ContentKind kind) async {
    final rows = await _db.rawQuery(
      'SELECT COUNT(*) AS item_count FROM media_items '
      'WHERE source_id = ? AND kind = ?',
      [sourceId, kind.name],
    );
    return rows.single['item_count'] as int;
  }

  /// Searches local titles with the same Unicode case folding as provider
  /// searches. Filtering in Dart also treats SQL wildcard characters literally.
  Future<List<MediaItem>> searchMediaItems(
    String sourceId,
    ContentKind kind,
    String query, {
    String? categoryId,
  }) async {
    final normalized = query.trim().toLowerCase();
    if (normalized.isEmpty) return const [];
    final where = StringBuffer('source_id = ? AND kind = ?');
    final args = <Object?>[sourceId, kind.name];
    if (categoryId != null) {
      where.write(' AND category_id = ?');
      args.add(categoryId);
    }
    return _db.transaction<List<MediaItem>>((txn) async {
      // Keep one catalog snapshot while matching Unicode titles in Dart. The
      // lightweight projection avoids transferring unrelated provider payloads.
      final titles = await txn.query(
        'media_items',
        columns: ['id', 'title'],
        where: where.toString(),
        whereArgs: args,
        orderBy: 'display_order, title',
      );
      final ids = [
        for (final row in titles)
          if ((row['title'] as String).toLowerCase().contains(normalized))
            row['id'] as String,
      ];
      return _readOrderedMediaItems(
        txn,
        kind,
        ids,
        where: where.toString(),
        whereArgs: args,
      );
    });
  }

  Future<List<MediaItem>> _readOrderedMediaItems(
    DatabaseExecutor connection,
    ContentKind kind,
    List<String> ids, {
    required String where,
    required List<Object?> whereArgs,
  }) async {
    // Bound every native payload transfer, including an all-catalog match.
    // Map each chunk before awaiting the next so raw rows need not accumulate.
    final items = <MediaItem>[];
    for (var start = 0; start < ids.length; start += 400) {
      final chunk = ids.sublist(start, (start + 400).clamp(0, ids.length));
      final rows = await connection.query(
        'media_items',
        where: '$where AND id IN (${List.filled(chunk.length, '?').join(',')})',
        whereArgs: [...whereArgs, ...chunk],
      );
      final byId = {for (final row in rows) row['id'] as String: row};
      for (final id in chunk) {
        final row = byId[id];
        if (row == null) continue;
        items.add(_mediaItemFromRow(row, kind, _decodeExtra(row['extra'])));
      }
    }
    return items;
  }

  /// Episodes whose cached season belongs to this series, in provider order.
  /// Reads only local catalog rows and keeps playback locators sealed.
  Future<List<MediaItem>> readCachedSeriesEpisodes(
    String sourceId,
    String seriesId,
  ) async {
    // Do not hold a catalog transaction across chunk reads: this optional
    // summary must leave playback checkpoints free to write between chunks.
    final rows = await _db.rawQuery(
      'SELECT episode.id FROM media_items episode '
      'JOIN media_items season ON season.source_id = episode.source_id '
      'AND season.kind = ? AND season.id = episode.parent_id '
      'WHERE episode.source_id = ? AND episode.kind = ? '
      'AND season.parent_id = ? '
      'ORDER BY season.display_order, season.title, '
      'episode.display_order, episode.title',
      [ContentKind.season.name, sourceId, ContentKind.episode.name, seriesId],
    );
    return _readOrderedMediaItems(
      _db,
      ContentKind.episode,
      [for (final row in rows) row['id'] as String],
      where: 'source_id = ? AND kind = ?',
      whereArgs: [sourceId, ContentKind.episode.name],
    );
  }

  /// The cached media items among [ids] (any order). Used to materialize the
  /// "Continue watching" rail from saved playback positions.
  Future<List<MediaItem>> readMediaItemsByIds(
    String sourceId,
    ContentKind kind,
    List<String> ids,
  ) async {
    if (ids.isEmpty) return const [];
    final placeholders = List.filled(ids.length, '?').join(', ');
    final rows = await _db.query(
      'media_items',
      where: 'source_id = ? AND kind = ? AND id IN ($placeholders)',
      whereArgs: [sourceId, kind.name, ...ids],
    );
    return _readMediaItems(rows, kind);
  }

  /// Synchronous, no crypto — items stay sealed. See [readChannels].
  static List<MediaItem> _readMediaItems(
    List<Map<String, Object?>> rows,
    ContentKind kind,
  ) => [
    for (final row in rows)
      _mediaItemFromRow(row, kind, _decodeExtra(row['extra'])),
  ];

  /// The [MediaItem] counterpart of [revealChannel]: decrypts the sealed
  /// playback locator so the model can be handed to the owning [Source]. A
  /// no-op when the item already carries plaintext locators.
  Future<MediaItem> revealMediaItem(MediaItem item) async {
    if (!hasSealedLocator(item.extra)) return item;
    return item.copyWith(
      extra: await restoreSecretLocators(item.extra, _vault),
    );
  }

  /// Builds the model from [r] with an already-decoded [extra] — see
  /// [_channelFromRow].
  static MediaItem _mediaItemFromRow(
    Map<String, Object?> r,
    ContentKind kind,
    Map<String, dynamic> extra,
  ) => MediaItem(
    id: r['id'] as String,
    title: r['title'] as String,
    kind: kind,
    parentId: r['parent_id'] as String?,
    categoryId: r['category_id'] as String?,
    poster: normalizeImageUrl(r['poster']),
    backdrop: normalizeImageUrl(r['backdrop']),
    description: r['description'] as String?,
    year: r['year'] as String?,
    rating: _readDouble(r['rating']),
    durationSeconds: _readInt(r['duration_seconds']),
    seasonNumber: _readInt(r['season_number']),
    episodeNumber: _readInt(r['episode_number']),
    providerId: r['provider_id'] as String?,
    extra: extra,
  );

  static int? _readInt(Object? value) {
    if (value is int) return value;
    if (value == null) return null;
    return int.tryParse(value.toString());
  }

  static double? _readDouble(Object? value) {
    if (value is double) return value;
    if (value is int) return value.toDouble();
    if (value == null) return null;
    return double.tryParse(value.toString());
  }

  /// [onlyIfAbsent] behaves exactly as it does on [replaceLibrary]: seed an
  /// empty cache, never overwrite a populated one, decided inside the
  /// transaction. The predicate mirrors [mediaSyncState] + a non-empty
  /// [readMediaItems] for the same `(kind, categoryId, parentId)` key, because
  /// that pair is `LibraryRepository.loadMedia`'s legacy cache-read gate.
  /// A complete root catalog is valid even when it contains no items.
  Future<bool> replaceMediaLibrary(
    String sourceId,
    ContentKind kind,
    List<MediaCategory> categories,
    List<MediaItem> items, {
    String? categoryId,
    String? parentId,
    int loadedPages = 1,
    int totalPages = 1,
    bool onlyIfAbsent = false,
    bool completeCatalog = false,
    bool refreshSeriesChildren = false,
    ({DateTime? syncedAt})? seriesCatalogVersion,
    String? expectedCacheIdentity,
    LoadToken? token,
  }) async {
    if (completeCatalog && (categoryId != null || parentId != null)) {
      throw ArgumentError('A complete media catalog must be unfiltered');
    }
    final protectedExtras = [
      for (final item in items) await protectSecretLocators(item.extra, _vault),
    ];
    var wrote = true;
    await _db.transaction((txn) async {
      if (expectedCacheIdentity != null &&
          !await _sourceCacheIdentityMatches(
            txn,
            sourceId,
            expectedCacheIdentity,
          )) {
        wrote = false;
        return;
      }
      if (seriesCatalogVersion != null &&
          await _catalogStamp(txn, sourceId, ContentKind.series) !=
              seriesCatalogVersion.syncedAt?.millisecondsSinceEpoch) {
        throw const LoadCancelledException();
      }
      final previousCatalogStamp = completeCatalog
          ? await _catalogStamp(txn, sourceId, kind)
          : null;
      final hadCache =
          (onlyIfAbsent || token != null) &&
          await _hasMediaCache(
            txn,
            sourceId,
            kind,
            categoryId: categoryId,
            parentId: parentId,
          );
      if ((onlyIfAbsent || token?.isCancelled == true) && hadCache) {
        wrote = false;
        return;
      }
      // Read only opened titles, inside the replacement transaction. Keep the
      // new catalog's locators and ordering; carry details forward only while
      // its provider data (including revision fields) still matches.
      final previousDetails = <String, Map<String, Object?>>{};
      if (completeCatalog &&
          (kind == ContentKind.movie || kind == ContentKind.series)) {
        final rows = await txn.query(
          'media_items',
          where: 'source_id = ? AND kind = ? AND extra LIKE ?',
          whereArgs: [sourceId, kind.name, '%"details":%'],
        );
        for (final row in rows) {
          previousDetails[row['id'] as String] = row;
        }
      }
      if (completeCatalog && kind == ContentKind.series && refreshSeriesChildren) {
        // Providers can append episodes without changing the root series row.
        // Invalidate only after a successful catalog download, atomically with
        // its replacement. Progress/favorites remain in their separate tables.
        previousDetails.clear();
        for (final childKind in [ContentKind.season, ContentKind.episode]) {
          for (final table in ['media_items', 'media_page_state', 'media_sync']) {
            await txn.delete(
              table,
              where: 'source_id = ? AND kind = ?',
              whereArgs: [sourceId, childKind.name],
            );
          }
        }
      }
      if (categoryId == null && parentId == null) {
        await txn.delete(
          'media_categories',
          where: 'source_id = ? AND kind = ?',
          whereArgs: [sourceId, kind.name],
        );
        await txn.delete(
          'media_items',
          where: 'source_id = ? AND kind = ?',
          whereArgs: [sourceId, kind.name],
        );
        await txn.delete(
          'media_page_state',
          where: 'source_id = ? AND kind = ? AND parent_id = ?',
          whereArgs: [sourceId, kind.name, ''],
        );
      } else {
        final where = StringBuffer('source_id = ? AND kind = ?');
        final args = <Object?>[sourceId, kind.name];
        if (categoryId != null) {
          where.write(' AND category_id = ?');
          args.add(categoryId);
        }
        if (parentId != null) {
          where.write(' AND parent_id = ?');
          args.add(parentId);
        }
        await txn.delete(
          'media_items',
          where: where.toString(),
          whereArgs: args,
        );
      }

      // Partial root writes cannot retain a prior claim of completeness.
      if (parentId == null) {
        await txn.delete(
          'catalog_sync',
          where: 'source_id = ? AND kind = ?',
          whereArgs: [sourceId, kind.name],
        );
      }
      final clockStamp = DateTime.now().millisecondsSinceEpoch;
      // Distinguish consecutive refreshes even within one clock tick.
      final syncedAt = previousCatalogStamp != null &&
              previousCatalogStamp >= clockStamp
          ? previousCatalogStamp + 1
          : clockStamp;
      if (completeCatalog) {
        loadedPages = 1;
        totalPages = 1;
      }
      final batch = txn.batch();
      if (categoryId == null) {
        for (final c in categories) {
          batch.insert('media_categories', {
            'source_id': sourceId,
            'kind': kind.name,
            'id': c.id,
            'title': c.title,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
      for (var i = 0; i < items.length; i++) {
        final item = items[i];
        final row = _retainMediaDetails(
          _mediaItemRow(
            sourceId,
            kind,
            item,
            parentId: parentId,
            displayOrder: i,
            protectedExtra: protectedExtras[i],
          ),
          previousDetails[item.id],
        );
        if (kind == ContentKind.series &&
            previousDetails.containsKey(item.id) &&
            _decodeExtra(row['extra'])['details'] is! Map) {
          // A changed series revision can contain new episodes. Its old child
          // page markers must not hide the updated tree on the next open.
          await _invalidateSeriesChildren(txn, sourceId, item.id);
        }
        batch.insert(
          'media_items',
          row,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      batch.insert('media_sync', {
        'source_id': sourceId,
        'kind': kind.name,
        'synced_at': syncedAt,
        'loaded_pages': loadedPages,
        'total_pages': totalPages < loadedPages ? loadedPages : totalPages,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      batch.insert('media_page_state', {
        'source_id': sourceId,
        'kind': kind.name,
        'parent_id': parentId ?? '',
        'category_id': categoryId ?? '',
        'synced_at': syncedAt,
        'loaded_pages': loadedPages,
        'total_pages': totalPages < loadedPages ? loadedPages : totalPages,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await batch.commit(noResult: true);
      if (hadCache && token?.isCancelled == true) {
        throw const LoadCancelledException();
      }
      if (completeCatalog && !onlyIfAbsent && token?.isCancelled != true) {
        await _writeCatalogSync(txn, sourceId, kind, syncedAt);
      }
    });
    return wrote;
  }

  /// Whether `(kind, categoryId, parentId)` has a media cache [loadMedia] would
  /// serve. A completed root catalog covers empty and filtered views too.
  /// Legacy caches mirror [mediaSyncState]'s two-tier lookup — the exact
  /// `media_page_state` key first, then the whole-kind `media_sync` row, which
  /// only answers for the unfiltered view — paired with at least one matching
  /// `media_items` row, the same two conditions the read gate applies.
  static Future<bool> _hasMediaCache(
    DatabaseExecutor txn,
    String sourceId,
    ContentKind kind, {
    String? categoryId,
    String? parentId,
  }) async {
    if (parentId == null && await _hasCompleteCatalog(txn, sourceId, kind)) {
      return true;
    }
    final pageRows = await txn.query(
      'media_page_state',
      where: 'source_id = ? AND kind = ? AND parent_id = ? AND category_id = ?',
      whereArgs: [sourceId, kind.name, parentId ?? '', categoryId ?? ''],
      limit: 1,
    );
    if (pageRows.isEmpty) {
      if (categoryId != null || parentId != null) return false;
      final syncRows = await txn.query(
        'media_sync',
        where: 'source_id = ? AND kind = ?',
        whereArgs: [sourceId, kind.name],
        limit: 1,
      );
      if (syncRows.isEmpty) return false;
    }
    final where = StringBuffer('source_id = ? AND kind = ?');
    final args = <Object?>[sourceId, kind.name];
    if (categoryId != null) {
      where.write(' AND category_id = ?');
      args.add(categoryId);
    }
    if (parentId != null) {
      where.write(' AND parent_id = ?');
      args.add(parentId);
    }
    final itemRows = await txn.query(
      'media_items',
      columns: ['id'],
      where: where.toString(),
      whereArgs: args,
      limit: 1,
    );
    return itemRows.isNotEmpty;
  }

  Future<void> appendMediaItems(
    String sourceId,
    ContentKind kind,
    List<MediaItem> items, {
    String? categoryId,
    String? parentId,
    required int loadedPages,
    required int totalPages,
    String? expectedCacheIdentity,
  }) async {
    final protectedExtras = [
      for (final item in items) await protectSecretLocators(item.extra, _vault),
    ];
    await _db.transaction((txn) async {
      if (expectedCacheIdentity != null &&
          !await _sourceCacheIdentityMatches(
            txn,
            sourceId,
            expectedCacheIdentity,
          )) {
        return;
      }
      if (parentId == null) {
        await txn.delete(
          'catalog_sync',
          where: 'source_id = ? AND kind = ?',
          whereArgs: [sourceId, kind.name],
        );
      }
      final startOrder = await _nextMediaDisplayOrder(
        txn,
        sourceId,
        kind,
        categoryId,
        parentId,
      );

      final batch = txn.batch();
      for (var i = 0; i < items.length; i++) {
        final item = items[i];
        batch.insert(
          'media_items',
          _mediaItemRow(
            sourceId,
            kind,
            item,
            parentId: parentId,
            displayOrder: startOrder + i,
            protectedExtra: protectedExtras[i],
          ),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      batch.insert('media_sync', {
        'source_id': sourceId,
        'kind': kind.name,
        'synced_at': DateTime.now().millisecondsSinceEpoch,
        'loaded_pages': loadedPages,
        'total_pages': totalPages < loadedPages ? loadedPages : totalPages,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      batch.insert('media_page_state', {
        'source_id': sourceId,
        'kind': kind.name,
        'parent_id': parentId ?? '',
        'category_id': categoryId ?? '',
        'synced_at': DateTime.now().millisecondsSinceEpoch,
        'loaded_pages': loadedPages,
        'total_pages': totalPages < loadedPages ? loadedPages : totalPages,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await batch.commit(noResult: true);
    });
  }

  Future<int> _nextMediaDisplayOrder(
    Transaction txn,
    String sourceId,
    ContentKind kind,
    String? categoryId,
    String? parentId,
  ) async {
    final where = StringBuffer('source_id = ? AND kind = ?');
    final args = <Object?>[sourceId, kind.name];
    if (categoryId != null) {
      where.write(' AND category_id = ?');
      args.add(categoryId);
    }
    if (parentId != null) {
      where.write(' AND parent_id = ?');
      args.add(parentId);
    }
    final rows = await txn.query(
      'media_items',
      columns: ['MAX(display_order) AS max_order'],
      where: where.toString(),
      whereArgs: args,
    );
    final max = rows.first['max_order'] as int?;
    return max == null ? 0 : max + 1;
  }

  Map<String, Object?> _mediaItemRow(
    String sourceId,
    ContentKind kind,
    MediaItem item, {
    String? parentId,
    required int displayOrder,
    Map<String, dynamic>? protectedExtra,
  }) => {
    'source_id': sourceId,
    'kind': kind.name,
    'id': item.id,
    'title': item.title,
    'parent_id': item.parentId ?? parentId,
    'category_id': item.categoryId,
    'poster': item.poster,
    'backdrop': item.backdrop,
    'description': item.description,
    'year': item.year,
    'rating': item.rating,
    'duration_seconds': item.durationSeconds,
    'season_number': item.seasonNumber,
    'episode_number': item.episodeNumber,
    'provider_id': item.providerId,
    'extra': (protectedExtra ?? item.extra).isEmpty
        ? null
        : jsonEncode(protectedExtra ?? item.extra),
    'display_order': displayOrder,
  };

  Map<String, Object?> _retainMediaDetails(
    Map<String, Object?> current,
    Map<String, Object?>? previous,
  ) {
    if (previous == null) return current;
    final oldExtra = _decodeExtra(previous['extra']);
    final newExtra = _decodeExtra(current['extra']);
    if (oldExtra['details'] is! Map || newExtra['details'] is Map) {
      return current;
    }
    String? providerTitle(
      Map<String, Object?> row,
      Map<String, dynamic> extra,
    ) =>
        _firstString(extra, [
          'providerTitle',
          'sourceTitle',
          'name',
          'title',
        ]) ??
        row['title'] as String?;
    if (providerTitle(previous, oldExtra) != providerTitle(current, newExtra)) {
      return current;
    }
    Map<String, dynamic> catalogExtra(Map<String, dynamic> extra) => {
      for (final entry in extra.entries)
        if (!const {
          'details',
          'metadata',
          'providerTitle',
          'num', // List position changes do not change a title's details.
          secretLocatorKey,
        }.contains(entry.key))
          entry.key: entry.value,
    };
    if (!_sameCatalogValue(catalogExtra(oldExtra), catalogExtra(newExtra))) {
      return current;
    }
    return {
      ...current,
      for (final field in const [
        'poster',
        'backdrop',
        'description',
        'year',
        'rating',
        'duration_seconds',
      ])
        field: current[field] ?? previous[field],
      // Never copy the old sealed playback locator or external metadata over
      // the freshly imported provider data.
      'extra': jsonEncode({...newExtra, 'details': oldExtra['details']}),
    };
  }

  static bool _sameCatalogValue(Object? a, Object? b) {
    if (a is Map && b is Map) {
      return a.length == b.length &&
          a.keys.every(
            (key) => b.containsKey(key) && _sameCatalogValue(a[key], b[key]),
          );
    }
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!_sameCatalogValue(a[i], b[i])) return false;
      }
      return true;
    }
    return a == b;
  }

  static Future<void> _invalidateSeriesChildren(
    DatabaseExecutor txn,
    String sourceId,
    String seriesId,
  ) async {
    const seasons =
        'SELECT id FROM media_items '
        'WHERE source_id = ? AND kind = ? AND parent_id = ?';
    final args = [
      sourceId,
      ContentKind.episode.name,
      sourceId,
      ContentKind.season.name,
      seriesId,
    ];
    for (final table in ['media_page_state', 'media_items']) {
      await txn.delete(
        table,
        where: 'source_id = ? AND kind = ? AND parent_id IN ($seasons)',
        whereArgs: args,
      );
    }
    for (final table in ['media_page_state', 'media_items']) {
      await txn.delete(
        table,
        where: 'source_id = ? AND kind = ? AND parent_id = ?',
        whereArgs: [sourceId, ContentKind.season.name, seriesId],
      );
    }
  }

  Future<void> updateMediaDisplayFields(
    String sourceId,
    List<MediaItem> items, {
    ({DateTime? syncedAt})? seriesCatalogVersion,
    String? expectedCacheIdentity,
  }) async {
    if (items.isEmpty) return;
    final protectedExtras = [
      for (final item in items) await protectSecretLocators(item.extra, _vault),
    ];
    Future<void> write(DatabaseExecutor executor) async {
      if (expectedCacheIdentity != null &&
          !await _sourceCacheIdentityMatches(
            executor,
            sourceId,
            expectedCacheIdentity,
          )) {
        throw const LoadCancelledException();
      }
      if (seriesCatalogVersion != null &&
          await _catalogStamp(executor, sourceId, ContentKind.series) !=
              seriesCatalogVersion.syncedAt?.millisecondsSinceEpoch) {
        throw const LoadCancelledException();
      }
      final batch = executor.batch();
      for (var i = 0; i < items.length; i++) {
        final item = items[i];
        final extra = protectedExtras[i];
        batch.update(
          'media_items',
          {
            'title': item.title,
            'poster': item.poster,
            'backdrop': item.backdrop,
            'description': item.description,
            'year': item.year,
            'rating': item.rating,
            'provider_id': item.providerId,
            'extra': extra.isEmpty ? null : jsonEncode(extra),
          },
          where: 'source_id = ? AND kind = ? AND id = ?',
          whereArgs: [sourceId, item.kind.name, item.id],
        );
      }
      await batch.commit(noResult: true);
    }
    if (seriesCatalogVersion == null && expectedCacheIdentity == null) {
      await write(_db);
    } else {
      await _db.transaction(write);
    }
  }

  Future<void> clearExternalMetadata({String? sourceId}) async {
    if (sourceId == null) {
      await _db.delete('external_metadata');
      return;
    }
    await _db.delete(
      'external_metadata',
      where: 'source_id = ?',
      whereArgs: [sourceId],
    );
  }

  Future<void> resetEnrichedMediaDisplayFields({String? sourceId}) async {
    final rows = await _db.query(
      'media_items',
      where: sourceId == null ? null : 'source_id = ?',
      whereArgs: sourceId == null ? null : [sourceId],
    );
    if (rows.isEmpty) return;
    final batch = _db.batch();
    for (final row in rows) {
      // `raw` stays SEALED: none of the display fields below live in the
      // locator set, and re-running `protectSecretLocators` over a sealed map
      // finds no plaintext locators and preserves the existing ciphertext
      // verbatim (`existingEncrypted`). So this rewrite never decrypts.
      final raw = _decodeExtra(row['extra']);
      final title =
          _firstString(raw, [
            'providerTitle',
            'sourceTitle',
            'name',
            'title',
          ]) ??
          row['title'] as String;
      final protectedExtra = await protectSecretLocators(raw, _vault);
      batch.update(
        'media_items',
        {
          'title': title,
          'poster': _firstString(raw, [
            'screenshot_uri',
            'poster',
            'cover',
            'stream_icon',
            'movie_image',
            'cover_big',
          ]),
          'backdrop': _firstString(raw, [
            'backdrop',
            'background',
            'cover_big',
          ]),
          'description': _firstString(raw, ['description', 'descr', 'plot']),
          'year': _firstString(raw, ['year', 'released', 'release_date']),
          'rating': _readDouble(raw['rating_imdb'] ?? raw['rating']),
          'provider_id': _firstString(raw, [
            'tmdb_id',
            'imdb_id',
            'kinopoisk_id',
          ]),
          'extra': protectedExtra.isEmpty ? null : jsonEncode(protectedExtra),
        },
        where: 'source_id = ? AND kind = ? AND id = ?',
        whereArgs: [row['source_id'], row['kind'], row['id']],
      );
    }
    await batch.commit(noResult: true);
  }

  String? _firstString(Map<dynamic, dynamic> map, List<String> keys) {
    for (final key in keys) {
      final value = map[key];
      if (value == null) continue;
      final text = value.toString().trim();
      if (text.isNotEmpty && text != 'null') return text;
    }
    return null;
  }

  Future<ExternalMetadata?> readExternalMetadata(
    String sourceId,
    MediaItem item,
    String provider,
  ) async {
    final rows = await _db.query(
      'external_metadata',
      where:
          'source_id = ? AND media_kind = ? AND media_id = ? AND provider = ?',
      whereArgs: [sourceId, item.kind.name, item.id, provider],
    );
    if (rows.isEmpty) return null;
    return _rowToExternalMetadata(rows.first);
  }

  Future<Map<String, ExternalMetadata>> readExternalMetadataForItems(
    String sourceId,
    List<MediaItem> items,
    String provider,
  ) async {
    if (items.isEmpty) return const {};
    final out = <String, ExternalMetadata>{};
    // The primary key starts with (source_id, media_kind, media_id). Omitting
    // kind prevented keyed lookups and scanned metadata again per ID chunk.
    final kinds = items.map((item) => item.kind.name).toSet().toList();
    final kindPlaceholders = List.filled(kinds.length, '?').join(',');
    final ids = items.map((item) => item.id).where((id) => id.isNotEmpty);
    final uniqueIds = ids.toSet().toList();
    for (var start = 0; start < uniqueIds.length; start += 500) {
      final chunk = uniqueIds.skip(start).take(500).toList();
      final placeholders = List.filled(chunk.length, '?').join(',');
      final rows = await _db.query(
        'external_metadata',
        where:
            'source_id = ? AND media_kind IN ($kindPlaceholders) '
            'AND media_id IN ($placeholders) AND provider = ?',
        whereArgs: [sourceId, ...kinds, ...chunk, provider],
      );
      for (final row in rows) {
        out[row['media_id'] as String] = _rowToExternalMetadata(row);
      }
    }
    return out;
  }

  Future<void> cacheExternalMetadata(
    String sourceId,
    MediaItem item,
    ExternalMetadata metadata, {
    String? expectedCacheIdentity,
  }) async {
    await _db.transaction((txn) async {
      if (expectedCacheIdentity != null &&
          !await _sourceCacheIdentityMatches(
            txn,
            sourceId,
            expectedCacheIdentity,
          )) {
        throw const LoadCancelledException();
      }
      await txn.insert('external_metadata', {
        'source_id': sourceId,
        'media_kind': item.kind.name,
        'media_id': item.id,
        'provider': metadata.provider,
        'provider_key': metadata.providerKey,
        'title': metadata.title,
        'overview': metadata.overview,
        'poster': metadata.poster,
        'backdrop': metadata.backdrop,
        'year': metadata.year,
        'rating': metadata.rating,
        'payload': metadata.payload.isEmpty
            ? null
            : jsonEncode(metadata.payload),
        'refreshed_at': metadata.refreshedAt.millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  ExternalMetadata _rowToExternalMetadata(Map<String, Object?> row) =>
      ExternalMetadata(
        provider: row['provider'] as String,
        providerKey: row['provider_key'] as String,
        title: row['title'] as String?,
        overview: row['overview'] as String?,
        poster: row['poster'] as String?,
        backdrop: row['backdrop'] as String?,
        year: row['year'] as String?,
        rating: _readDouble(row['rating']),
        payload: row['payload'] == null
            ? const {}
            : (jsonDecode(row['payload'] as String) as Map)
                  .cast<String, dynamic>(),
        refreshedAt: DateTime.fromMillisecondsSinceEpoch(
          row['refreshed_at'] as int,
        ),
      );

  static Map<String, dynamic> _decodeExtra(Object? raw) => raw == null
      ? const {}
      : (jsonDecode(raw as String) as Map).cast<String, dynamic>();

  /// Builds the model from [r] with an already-decoded [extra], so callers
  /// that need to transform `extra` (decrypt/reveal) do it before construction
  /// instead of building a second [Channel] to swap the map in.
  static Channel _channelFromRow(
    Map<String, Object?> r,
    Map<String, dynamic> extra,
  ) => Channel(
    id: r['id'] as String,
    name: r['name'] as String,
    number: r['number'] as int?,
    logo: r['logo'] as String?,
    categoryId: r['category_id'] as String?,
    archiveDays: (r['archive_days'] as int?) ?? 0,
    extra: extra,
  );

  /// Replace all cached channels/categories for a source in one transaction.
  ///
  /// With [onlyIfAbsent] the replace becomes a **seed**: it commits only when
  /// this source has no catalog a read would serve, and the returned bool says
  /// whether it wrote. `LibraryRepository._loadChannels` uses that to let a
  /// *superseded* load fill an empty cache without ever overwriting a populated
  /// one — see the long comment there for why the two cases differ.
  ///
  /// The predicate is evaluated **inside the transaction** (so the answer
  /// cannot change between the test and the write) and is the exact complement
  /// of `_loadChannels`'s cache-read gate: `synced_at` non-null *and* at least
  /// one channel row. Any other test produces a source that reads as "no cache"
  /// yet refuses to be seeded — permanently, because the channel cache has no
  /// age check. A completed catalog also covers an empty provider response.
  Future<bool> replaceLibrary(
    String sourceId,
    String name,
    List<Category> categories,
    List<Channel> channels, {
    bool onlyIfAbsent = false,
    bool completeCatalog = false,
    String? expectedCacheIdentity,
    LoadToken? token,
  }) async {
    var wrote = true;
    // Preserve the in-transaction seed check below; this early check merely
    // avoids preparing a large library when a cache already exists.
    if (onlyIfAbsent && await _hasChannelCache(_db, sourceId)) return false;
    final spool = channels.length >= 64
        ? await ChannelLibrarySpool.create(channels, _vault)
        : null;
    // Small catalogs do not need a worker or a disk round trip, but their
    // encryption still finishes before the transaction takes the DB lock.
    final smallRows = <Map<String, Object?>>[];
    if (spool == null) {
      for (final channel in channels) {
        final extra = await protectSecretLocators(channel.extra, _vault);
        smallRows.add({
          'id': channel.id,
          'name': channel.name,
          'number': channel.number,
          'logo': channel.logo,
          'category_id': channel.categoryId,
          'archive_days': channel.archiveDays,
          'extra': extra.isEmpty ? null : jsonEncode(extra),
        });
      }
    }
    try {
      await _db.transaction((txn) async {
        if (expectedCacheIdentity != null &&
            !await _sourceCacheIdentityMatches(
              txn,
              sourceId,
              expectedCacheIdentity,
            )) {
          wrote = false;
          return;
        }
        final hadCache =
            (onlyIfAbsent || token != null) &&
            await _hasChannelCache(txn, sourceId);
        if ((onlyIfAbsent || token?.isCancelled == true) && hadCache) {
          wrote = false;
          return;
        }
        await txn.delete(
          'categories',
          where: 'source_id = ?',
          whereArgs: [sourceId],
        );
        await txn.delete(
          'channels',
          where: 'source_id = ?',
          whereArgs: [sourceId],
        );

        var batch = txn.batch();
        var pending = 0;
        for (final c in categories) {
          batch.insert('categories', {
            'source_id': sourceId,
            'id': c.id,
            'title': c.title,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
          if (++pending == ChannelLibrarySpool.batchSize) {
            await batch.commit(noResult: true);
            batch = txn.batch();
            pending = 0;
          }
        }
        if (pending > 0) await batch.commit(noResult: true);
        await for (final rows in spool?.read() ?? Stream.value(smallRows)) {
          batch = txn.batch();
          for (final row in rows) {
            batch.insert('channels', {
              'source_id': sourceId,
              ...row,
            }, conflictAlgorithm: ConflictAlgorithm.replace);
          }
          await batch.commit(noResult: true);
        }
        // Upsert the sources row WITHOUT touching epg_synced_at (or any future
        // column this method doesn't own). INSERT OR REPLACE deletes the row
        // first, which nulled EPG freshness on every channel refresh. Explicit
        // update-else-insert (no UPSERT syntax — Android <API30 ships SQLite
        // <3.24) preserves every column we don't write.
        final now = DateTime.now().millisecondsSinceEpoch;
        final updated = await txn.update(
          'sources',
          {'name': name, 'synced_at': now},
          where: 'id = ?',
          whereArgs: [sourceId],
        );
        if (updated == 0) {
          await txn.insert('sources', {
            'id': sourceId,
            'name': name,
            'synced_at': now,
          });
        }
        if (hadCache && token?.isCancelled == true) {
          throw const LoadCancelledException();
        }
        await txn.delete(
          'catalog_sync',
          where: 'source_id = ? AND kind = ?',
          whereArgs: [sourceId, ContentKind.live.name],
        );
        if (completeCatalog && !onlyIfAbsent && token?.isCancelled != true) {
          await _writeCatalogSync(txn, sourceId, ContentKind.live, now);
        }
      });
    } finally {
      await spool?.dispose();
    }
    return wrote;
  }

  /// Whether [sourceId] has a channel catalog `_loadChannels` would serve.
  /// Both halves are required: the `sources` row and the channel rows are
  /// written in the same transaction, but an interrupted older build, a
  /// half-migrated file, or a future writer could leave one without the other,
  /// and the legacy read gate treats either absence as "no cache". An explicit
  /// completed-catalog marker instead establishes a valid empty cache.
  static Future<bool> _hasChannelCache(
    DatabaseExecutor txn,
    String sourceId,
  ) async {
    if (await _hasCompleteCatalog(txn, sourceId, ContentKind.live)) return true;
    final syncedRows = await txn.rawQuery(
      'SELECT COUNT(*) AS n FROM sources WHERE id = ? AND synced_at IS NOT NULL',
      [sourceId],
    );
    if (((syncedRows.first['n'] as int?) ?? 0) == 0) return false;
    final channelRows = await txn.rawQuery(
      'SELECT EXISTS(SELECT 1 FROM channels WHERE source_id = ?) AS n',
      [sourceId],
    );
    return ((channelRows.first['n'] as int?) ?? 0) != 0;
  }

  static Future<bool> _hasCompleteCatalog(
    DatabaseExecutor txn,
    String sourceId,
    ContentKind kind,
  ) async => (await txn.query(
    'catalog_sync',
    columns: ['synced_at'],
    where: 'source_id = ? AND kind = ?',
    whereArgs: [sourceId, kind.name],
    limit: 1,
  )).isNotEmpty;

  static Future<void> _writeCatalogSync(
    DatabaseExecutor txn,
    String sourceId,
    ContentKind kind,
    int syncedAt,
  ) => txn.insert('catalog_sync', {
    'source_id': sourceId,
    'kind': kind.name,
    'synced_at': syncedAt,
  }, conflictAlgorithm: ConflictAlgorithm.replace);

  // ── EPG ───────────────────────────────────────────────────────────────────

  /// Rows are flushed in bounded batches so a very large guide doesn't build
  /// one giant in-memory batch, but the flushes stay inside the surrounding
  /// transaction — `batch.commit` here does not COMMIT, it just executes the
  /// pending statements against the open transaction.
  static const _epgInsertChunk = 1000;

  Future<List<EpgChannelOverride>> readEpgMappings(String sourceId) async {
    final rows = await _db.query(
      'epg_channel_overrides',
      where: 'source_id = ?',
      whereArgs: [sourceId],
    );
    return [
      for (final row in rows)
        EpgChannelOverride(
          channelId: row['channel_id'] as String,
          guideId: row['guide_id'] as String?,
          guideChannelId: row['guide_channel_id'] as String?,
          offsetMinutes: row['offset_minutes'] as int,
        ),
    ];
  }

  Future<List<EpgGuideChannel>> readEpgGuideChannels(String sourceId) async {
    final rows = await _db.query(
      'epg_guide_channels',
      where: 'source_id = ?',
      whereArgs: [sourceId],
      orderBy: 'guide_label, channel_id',
    );
    return [
      for (final row in rows)
        EpgGuideChannel(
          guideId: row['guide_id'] as String,
          guideLabel: row['guide_label'] as String,
          channelId: row['channel_id'] as String,
          displayNames: (jsonDecode(row['display_names'] as String) as List)
              .cast<String>(),
        ),
    ];
  }

  Future<void> setEpgMapping(
    String sourceId,
    EpgChannelOverride override,
  ) async {
    if (override.channelId.isEmpty ||
        (override.guideId == null) != (override.guideChannelId == null) ||
        override.guideId == '' ||
        override.guideChannelId == '' ||
        override.offsetMinutes.abs() > 24 * 60) {
      throw ArgumentError('Invalid guide mapping or time correction');
    }
    await _db.transaction((txn) async {
      if (!override.hasBinding && override.offsetMinutes == 0) {
        await txn.delete(
          'epg_channel_overrides',
          where: 'source_id = ? AND channel_id = ?',
          whereArgs: [sourceId, override.channelId],
        );
      } else {
        await txn.insert('epg_channel_overrides', {
          'source_id': sourceId,
          'channel_id': override.channelId,
          'guide_id': override.guideId,
          'guide_channel_id': override.guideChannelId,
          'offset_minutes': override.offsetMinutes,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      // Keep the last usable guide until its replacement is fully staged.
      await txn.update(
        'sources',
        {'epg_synced_at': null},
        where: 'id = ?',
        whereArgs: [sourceId],
      );
    });
  }

  Future<void> _replaceEpgCatalogue(
    DatabaseExecutor txn,
    String sourceId,
    Iterable<EpgGuideChannel>? channels,
  ) async {
    if (channels == null) return;
    await txn.delete(
      'epg_guide_channels',
      where: 'source_id = ?',
      whereArgs: [sourceId],
    );
    var batch = txn.batch();
    var count = 0;
    for (final channel in channels) {
      batch.insert('epg_guide_channels', {
        'source_id': sourceId,
        'guide_id': channel.guideId,
        'guide_label': channel.guideLabel,
        'channel_id': channel.channelId,
        'display_names': jsonEncode(channel.displayNames),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      if (++count == _epgInsertChunk) {
        await batch.commit(noResult: true);
        batch = txn.batch();
        count = 0;
      }
    }
    if (count > 0) await batch.commit(noResult: true);
  }

  /// Search cached titles and descriptions. The allowlist is applied before
  /// counting results, so hidden/locked channels cannot consume the limit or
  /// leak through a broad text match. It never decrypts playback locators.
  Future<List<ProgrammeSearchResult>> searchProgrammes(
    String query, {
    String? sourceId,
    Set<String>? allowedChannelIds,
    DateTime? from,
    DateTime? to,
    int limit = 80,
  }) async {
    final words = ProgrammeSearchIndex.queryTokens(query);
    if (words.isEmpty || limit <= 0 || allowedChannelIds?.isEmpty == true) {
      return const [];
    }
    final maximum = limit.clamp(1, 500);
    final allowed = allowedChannelIds?.toList(growable: false);
    Future<List<ProgrammeSearchResult>> execute(
      DatabaseExecutor connection,
    ) async {
      int? request;
      var filterReady = false;
      try {
        if (allowed != null && allowed.length > 400) {
          request = _searchRequestSequence++;
          await connection.execute(
            'CREATE TEMP TABLE IF NOT EXISTS programme_search_allowed ('
            'request_id INTEGER NOT NULL, channel_id TEXT NOT NULL, '
            'PRIMARY KEY (request_id, channel_id)) WITHOUT ROWID',
          );
          filterReady = true;
          for (var start = 0; start < allowed.length; start += 500) {
            final batch = connection.batch();
            final end = (start + 500).clamp(0, allowed.length);
            // Retain the native batch bound while reducing SQL statements.
            // Two parameters per row stay below SQLite's 999-variable floor.
            for (var offset = start; offset < end; offset += 400) {
              final chunk = allowed.sublist(offset, (offset + 400).clamp(0, end));
              batch.rawInsert(
                'INSERT INTO programme_search_allowed (request_id, channel_id) '
                'VALUES ${List.filled(chunk.length, '(?,?)').join(',')}',
                [for (final id in chunk) ...[request, id]],
              );
            }
            await batch.commit(noResult: true);
          }
        }
        final args = <Object?>[];
        final predicates = <String>[_programmeSearch.predicate(words, args)];
        if (request != null) {
          predicates.add(
            'p.channel_id IN (SELECT channel_id FROM programme_search_allowed '
            'WHERE request_id = ?)',
          );
          args.add(request);
        } else if (allowed != null) {
          predicates.add(
            'p.channel_id IN (${List.filled(allowed.length, '?').join(',')})',
          );
          args.addAll(allowed);
        }
        if (sourceId != null) {
          predicates.add('p.source_id = ?');
          args.add(sourceId);
        }
        if (from != null) {
          predicates.add('p.stop > ?');
          args.add(from.millisecondsSinceEpoch);
        }
        if (to != null) {
          predicates.add('p.start < ?');
          args.add(to.millisecondsSinceEpoch);
        }
        args.add(maximum);
        final rows = await connection.rawQuery(
          'SELECT p.rowid AS programme_rowid, p.source_id, p.channel_id, '
          'p.start, p.stop, p.title, p.description, s.name AS source_name, '
          'c.id, c.name, c.number, c.logo, c.category_id, c.archive_days, c.extra '
          'FROM programmes p JOIN channels c '
          'ON c.source_id = p.source_id AND c.id = p.channel_id '
          'JOIN sources s ON s.id = p.source_id '
          'WHERE ${predicates.join(' AND ')} '
          'ORDER BY p.start, p.rowid LIMIT ?',
          args,
        );
        return [
          for (final row in rows)
            ProgrammeSearchResult(
              sourceId: row['source_id'] as String,
              sourceName: row['source_name'] as String,
              channel: _channelFromRow(row, _decodeExtra(row['extra'])),
              programme: _rowToProgramme(row),
            ),
        ];
      } finally {
        if (filterReady) {
          await connection.delete(
            'programme_search_allowed',
            where: 'request_id = ?',
            whereArgs: [request],
          );
        }
      }
    }

    return allowed != null && allowed.length > 400
        ? _db.transaction(execute)
        : execute(_db);
  }

  /// Replaces every cached programme for [sourceId] with [programmes] and
  /// advances `epg_synced_at`, all in one transaction — including the
  /// success-empty case (a source legitimately reporting no programmes),
  /// which must still clear stale rows and record that the refresh ran. A
  /// thrown [programmes] iterator or any other failure mid-transaction rolls
  /// back the delete along with any partial insert, leaving the previous EPG
  /// and timestamp untouched.
  Future<void> replaceEpg(
    String sourceId,
    Iterable<Programme> programmes, {
    Iterable<EpgGuideChannel>? guideChannels,
    String? expectedCacheIdentity,
  }) async {
    await _db.transaction((txn) async {
      if (expectedCacheIdentity != null &&
          !await _sourceCacheIdentityMatches(
            txn,
            sourceId,
            expectedCacheIdentity,
          )) {
        throw const LoadCancelledException();
      }
      await txn.delete(
        'programmes',
        where: 'source_id = ?',
        whereArgs: [sourceId],
      );
      var batch = txn.batch();
      var n = 0;
      for (final p in programmes) {
        batch.insert('programmes', {
          'source_id': sourceId,
          'channel_id': p.channelId,
          'start': p.start.millisecondsSinceEpoch,
          'stop': p.stop.millisecondsSinceEpoch,
          'title': p.title,
          'description': p.description,
        });
        if (++n >= _epgInsertChunk) {
          await batch.commit(noResult: true);
          batch = txn.batch();
          n = 0;
        }
      }
      if (n > 0) await batch.commit(noResult: true);
      if (_programmeSearch.engine == ProgrammeSearchEngine.tokens) {
        await _programmeSearch.rebuildTokens(txn, sourceId: sourceId);
      }
      if (guideChannels != null) {
        await _replaceEpgCatalogue(txn, sourceId, guideChannels);
      }
      await txn.update(
        'sources',
        {'epg_synced_at': DateTime.now().millisecondsSinceEpoch},
        where: 'id = ?',
        whereArgs: [sourceId],
      );
    });
  }

  /// Streamed counterpart of [replaceEpg] for a large guide ingested in
  /// bounded batches (see [BatchedEpgSource]/`parseXmltvBatched`): the delete,
  /// every inserted batch, and the `epg_synced_at` bump all happen in ONE
  /// transaction, exactly like [replaceEpg]. An empty [batches] stream that
  /// completes normally is still success — rows cleared, timestamp advanced,
  /// same success-empty contract as [replaceEpg].
  ///
  /// Cancellation contract: [batches] must signal a mid-feed cancellation by
  /// *throwing* (e.g. [LoadCancelledException]) rather than simply ending
  /// early. Any error thrown by the stream propagates out of the transaction
  /// body, which rolls it back — the delete and every batch inserted so far
  /// are undone, leaving the previous guide and its old `epg_synced_at`
  /// untouched. A stream that just stops yielding and completes normally
  /// (no error) would otherwise commit whatever partial set of rows it fed in
  /// as if it were the complete guide — exactly the half-fed state this
  /// method must never produce.
  Future<EpgStreamWriteMetrics> replaceEpgStream(
    String sourceId,
    Stream<List<Programme>> batches, {
    Iterable<EpgGuideChannel>? guideChannels,
    LoadToken? token,
    String? expectedCacheIdentity,
  }) async {
    void checkCancelled() {
      if (token?.isCancelled ?? false) throw const LoadCancelledException();
    }

    checkCancelled();
    final providerWatch = Stopwatch();
    final databaseWatch = Stopwatch();
    await _db.transaction((txn) async {
      if (expectedCacheIdentity != null &&
          !await _sourceCacheIdentityMatches(
            txn,
            sourceId,
            expectedCacheIdentity,
          )) {
        throw const LoadCancelledException();
      }
      databaseWatch.start();
      await txn.delete(
        'programmes',
        where: 'source_id = ?',
        whereArgs: [sourceId],
      );
      databaseWatch.stop();
      var batch = txn.batch();
      var n = 0;
      final iterator = StreamIterator<List<Programme>>(batches);
      try {
        while (true) {
          checkCancelled();
          providerWatch.start();
          final hasNext = await iterator.moveNext();
          providerWatch.stop();
          if (!hasNext) break;
          final chunk = iterator.current;
          databaseWatch.start();
          for (final p in chunk) {
            batch.insert('programmes', {
              'source_id': sourceId,
              'channel_id': p.channelId,
              'start': p.start.millisecondsSinceEpoch,
              'stop': p.stop.millisecondsSinceEpoch,
              'title': p.title,
              'description': p.description,
            });
            if (++n >= _epgInsertChunk) {
              checkCancelled();
              await batch.commit(noResult: true);
              batch = txn.batch();
              n = 0;
            }
          }
          databaseWatch.stop();
        }
      } finally {
        await iterator.cancel();
      }
      databaseWatch.start();
      checkCancelled();
      if (n > 0) await batch.commit(noResult: true);
      if (_programmeSearch.engine == ProgrammeSearchEngine.tokens) {
        await _programmeSearch.rebuildTokens(
          txn,
          sourceId: sourceId,
          token: token,
        );
      }
      if (guideChannels != null) {
        await _replaceEpgCatalogue(txn, sourceId, guideChannels);
      }
      checkCancelled();
      await txn.update(
        'sources',
        {'epg_synced_at': DateTime.now().millisecondsSinceEpoch},
        where: 'id = ?',
        whereArgs: [sourceId],
      );
      checkCancelled();
      databaseWatch.stop();
    });
    return EpgStreamWriteMetrics(
      providerDuration: providerWatch.elapsed,
      databaseDuration: databaseWatch.elapsed,
    );
  }

  /// The "now" half of [nowNext]: every programme airing at a given instant
  /// across a source's channels. Keyed on `(source_id, start)` with no
  /// `channel_id` constraint — a per-source scan of all channels' programmes
  /// at once — so it is served by the covering `idx_prog_now`
  /// `(source_id, start, stop, channel_id)` index, not the
  /// `(source_id, channel_id, start)` lookup index used by
  /// `programmesForChannel(s)`. `stop` sits *in* the index precisely so the
  /// `stop > ?` term is decided from the index entry: with only
  /// `idx_prog_source_start(source_id, start)` every candidate row (roughly
  /// half a guide) needed a table lookup just to be discarded.
  static const _nowQuery =
      'SELECT channel_id, title, start, stop, description FROM programmes '
      'WHERE source_id = ? AND start <= ? AND stop > ?';

  /// The "next" half of [nowNext].
  ///
  /// `INDEXED BY idx_prog_lookup` is load-bearing, not decoration. Left to
  /// itself the planner drives this off `idx_prog_source_start`, which orders
  /// by `start` and therefore has to materialise a `USE TEMP B-TREE FOR GROUP
  /// BY` over every future programme in the guide. `idx_prog_lookup`'s
  /// `(source_id, channel_id, start)` ordering delivers the groups already
  /// sorted, so the aggregation streams. Measured on a 960k-programme guide:
  /// 952 ms unpinned vs 98 ms pinned — and running `ANALYZE` makes the planner
  /// choose `idx_prog_lookup` on its own, so the hint is what a
  /// statistics-informed planner would have picked anyway. Production never
  /// runs `ANALYZE`, hence the explicit pin.
  ///
  /// `INDEXED BY` is a hard requirement: dropping or renaming
  /// `idx_prog_lookup` makes this query fail with "no query solution" rather
  /// than silently deoptimise. The v13 upgrade branch re-asserts the index for
  /// that reason, and `explainNextQueryPlan` pins the plan in tests.
  static const _nextQuery =
      'SELECT channel_id, title, MIN(start) AS start, stop, description '
      'FROM programmes INDEXED BY idx_prog_lookup '
      'WHERE source_id = ? AND start > ? GROUP BY channel_id';

  /// Current and next programme per channel at time [at].
  Future<({Map<String, Programme> now, Map<String, Programme> next})> nowNext(
    String sourceId,
    DateTime at,
  ) async {
    final t = at.millisecondsSinceEpoch;
    final now = <String, Programme>{};
    final next = <String, Programme>{};

    final currentRows = await _db.rawQuery(_nowQuery, [sourceId, t, t]);
    for (final r in currentRows) {
      now[r['channel_id'] as String] = _rowToProgramme(r);
    }

    // SQLite returns the row matching MIN(start) for the bare columns.
    final nextRows = await _db.rawQuery(_nextQuery, [sourceId, t]);
    for (final r in nextRows) {
      next[r['channel_id'] as String] = _rowToProgramme(r);
    }
    return (now: now, next: next);
  }

  /// The windowed counterpart of [nowNext]: now/next for an explicit list of
  /// [channelIds] instead of every channel the source has cached.
  ///
  /// Deliberately **not** wired into the live tab yet. [nowNext] returns a map
  /// covering every channel, and the live list reads it by channel id for
  /// arbitrary rows, so swapping in a windowed map would silently blank the
  /// EPG on rows outside the window — correcting that needs scroll-driven
  /// refresh in the UI. This exists so that change can be made later without
  /// also having to design the query.
  ///
  /// Both halves are `channel_id`-constrained, so both run on
  /// `idx_prog_lookup` and touch only the requested channels' index ranges.
  /// Ids are queried in chunks to stay under SQLite's bound-variable limit;
  /// duplicates and unknown ids are harmless (they simply contribute nothing).
  Future<({Map<String, Programme> now, Map<String, Programme> next})>
  nowNextForChannels(
    String sourceId,
    List<String> channelIds,
    DateTime at,
  ) async {
    final now = <String, Programme>{};
    final next = <String, Programme>{};
    if (channelIds.isEmpty) return (now: now, next: next);
    final t = at.millisecondsSinceEpoch;

    for (var offset = 0; offset < channelIds.length; offset += _idChunk) {
      final chunk = channelIds.sublist(
        offset,
        (offset + _idChunk).clamp(0, channelIds.length),
      );
      final placeholders = List.filled(chunk.length, '?').join(', ');
      final currentRows = await _db.rawQuery(
        'SELECT channel_id, title, start, stop, description FROM programmes '
        'WHERE source_id = ? AND channel_id IN ($placeholders) '
        'AND start <= ? AND stop > ?',
        [sourceId, ...chunk, t, t],
      );
      for (final r in currentRows) {
        now[r['channel_id'] as String] = _rowToProgramme(r);
      }
      final nextRows = await _db.rawQuery(
        'SELECT channel_id, title, MIN(start) AS start, stop, description '
        'FROM programmes WHERE source_id = ? AND channel_id IN ($placeholders) '
        'AND start > ? GROUP BY channel_id',
        [sourceId, ...chunk, t],
      );
      for (final r in nextRows) {
        next[r['channel_id'] as String] = _rowToProgramme(r);
      }
    }
    return (now: now, next: next);
  }

  /// Bound-variable budget per `IN (...)` query. SQLite's default
  /// `SQLITE_MAX_VARIABLE_NUMBER` is 999 on older builds; 500 leaves room for
  /// the surrounding `source_id`/time parameters everywhere this is used.
  /// Series title per episode id, resolved **episode → season → series**.
  ///
  /// The "Continue watching" rail on the series tab is built from episode rows,
  /// and an episode's `title` is the *episode* name — "Gran Dillama", not
  /// "Caminandes". A rail of those alone reads as a list of unrelated titles,
  /// which is what it was reported as.
  ///
  /// The series is two hops up, and the shape is uniform across providers:
  /// every source builds an episode with its **season** as `parent_id` and the
  /// season with the **series** (`xtream_source`, `stalker_source` and
  /// `demo_source` all do). Both hops are inner joins, so an episode whose
  /// season or series row was never cached is simply absent from the result and
  /// the caller falls back to the episode title — better than a blank line.
  ///
  /// Chunked like [nowNextForChannels] to stay under SQLite's bound-variable
  /// limit; unknown ids contribute nothing.
  Future<Map<String, String>> readSeriesTitlesForEpisodes(
    String sourceId,
    List<String> episodeIds,
  ) async {
    final out = <String, String>{};
    if (episodeIds.isEmpty) return out;
    for (var offset = 0; offset < episodeIds.length; offset += _idChunk) {
      final chunk = episodeIds.sublist(
        offset,
        (offset + _idChunk).clamp(0, episodeIds.length),
      );
      final placeholders = List.filled(chunk.length, '?').join(', ');
      final rows = await _db.rawQuery(
        'SELECT e.id AS episode_id, series.title AS series_title '
        'FROM media_items e '
        'JOIN media_items season '
        '  ON season.source_id = e.source_id '
        ' AND season.kind = ? AND season.id = e.parent_id '
        'JOIN media_items series '
        '  ON series.source_id = e.source_id '
        ' AND series.kind = ? AND series.id = season.parent_id '
        'WHERE e.source_id = ? AND e.kind = ? '
        '  AND e.id IN ($placeholders)',
        [
          ContentKind.season.name,
          ContentKind.series.name,
          sourceId,
          ContentKind.episode.name,
          ...chunk,
        ],
      );
      for (final row in rows) {
        final title = row['series_title'] as String?;
        if (title != null && title.isNotEmpty) {
          out[row['episode_id'] as String] = title;
        }
      }
    }
    return out;
  }

  static const _idChunk = 500;

  /// Test seam: runs `EXPLAIN QUERY PLAN` for the `nowNext` "now" query with
  /// the same SQL and args, returning each row's `detail` column — lets a
  /// test assert which index serves it without depending on the full plan
  /// string shape.
  @visibleForTesting
  Future<List<String>> explainNowQueryPlan(String sourceId, DateTime at) async {
    final t = at.millisecondsSinceEpoch;
    final rows = await _db.rawQuery('EXPLAIN QUERY PLAN $_nowQuery', [
      sourceId,
      t,
      t,
    ]);
    return rows.map((r) => r['detail'] as String).toList();
  }

  /// Test seam for the "next" half of [nowNext]. The regression this guards is
  /// invisible from results alone: a plan that falls back to
  /// `idx_prog_source_start` still returns the right rows, just an order of
  /// magnitude slower via a temp B-tree.
  @visibleForTesting
  Future<List<String>> explainNextQueryPlan(
    String sourceId,
    DateTime at,
  ) async {
    final rows = await _db.rawQuery('EXPLAIN QUERY PLAN $_nextQuery', [
      sourceId,
      at.millisecondsSinceEpoch,
    ]);
    return rows.map((r) => r['detail'] as String).toList();
  }

  /// Cached programmes for one channel overlapping the `[from, to)` window,
  /// ordered by start — the catch-up guide's data source. A programme overlaps
  /// the window when it starts before `to` and ends after `from`. Served by
  /// `idx_prog_lookup(source_id, channel_id, start)`.
  Future<List<Programme>> programmesForChannel(
    String sourceId,
    String channelId, {
    required DateTime from,
    required DateTime to,
  }) async {
    final rows = await _db.rawQuery(
      'SELECT channel_id, title, start, stop, description FROM programmes '
      'WHERE source_id = ? AND channel_id = ? AND start < ? AND stop > ? '
      'ORDER BY start',
      [
        sourceId,
        channelId,
        to.millisecondsSinceEpoch,
        from.millisecondsSinceEpoch,
      ],
    );
    return rows.map(_rowToProgramme).toList();
  }

  /// Programmes overlapping [from]..[to] for a batch of channels in one query
  /// (the EPG grid's visible window), grouped by channel id, each ordered by
  /// start. Channels without cached EPG simply have no entry.
  Future<Map<String, List<Programme>>> programmesForChannels(
    String sourceId,
    List<String> channelIds, {
    required DateTime from,
    required DateTime to,
  }) async {
    if (channelIds.isEmpty) return const {};
    final placeholders = List.filled(channelIds.length, '?').join(', ');
    final rows = await _db.rawQuery(
      'SELECT channel_id, title, start, stop, description FROM programmes '
      'WHERE source_id = ? AND channel_id IN ($placeholders) '
      'AND start < ? AND stop > ? '
      'ORDER BY channel_id, start',
      [
        sourceId,
        ...channelIds,
        to.millisecondsSinceEpoch,
        from.millisecondsSinceEpoch,
      ],
    );
    final out = <String, List<Programme>>{};
    for (final row in rows) {
      final programme = _rowToProgramme(row);
      (out[programme.channelId] ??= []).add(programme);
    }
    return out;
  }

  Programme _rowToProgramme(Map<String, Object?> r) => Programme(
    channelId: r['channel_id'] as String,
    start: DateTime.fromMillisecondsSinceEpoch(r['start'] as int),
    stop: DateTime.fromMillisecondsSinceEpoch(r['stop'] as int),
    title: r['title'] as String,
    description: r['description'] as String?,
  );

  Future<void> close() async {
    // Awaited before the connection goes: an ingest mid-transaction does not
    // stop because the database closed — `_db.close()` would simply block on it
    // instead, with no cancellation and nothing in the log. See
    // `EpgIngestCoordinator.shutdown`.
    await epgIngest.shutdown();
    await _favoritesChanged.close();
    await _favoritesReplaced.close();
    await _playbackPositionsChanged.close();
    await _playbackCheckpointed.close();
    await _playbackPositionsReplaced.close();
    await _epgChanged.close();
    await _db.close();
  }
}
