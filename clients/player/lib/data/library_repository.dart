import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart' show debugPrint;

import '../sources/source.dart';
import '../sources/epg_mapping.dart';
import 'app_database.dart';
import 'diagnostics_log.dart';
import 'epg_models.dart';
import 'load_token.dart';
import 'metadata_provider.dart';
import 'net.dart'
    show ProviderRequestBlocked, formatBytes, redactText, sourceLoadErrorMessage;
import 'programme_spool.dart';
import 'source_identity_migration.dart';

class LibrarySnapshot {
  final List<Category> categories;
  final List<Channel> channels;
  final bool fromCache;
  final DateTime? syncedAt;

  const LibrarySnapshot({
    required this.categories,
    required this.channels,
    required this.fromCache,
    required this.syncedAt,
  });
}

class MediaLibrarySnapshot {
  final ContentKind kind;
  final String? categoryId;
  final String? parentId;
  final List<MediaCategory> categories;
  final List<MediaItem> items;
  final bool fromCache;
  final DateTime? syncedAt;
  final int loadedPages;
  final int totalPages;

  const MediaLibrarySnapshot({
    required this.kind,
    this.categoryId,
    this.parentId,
    required this.categories,
    required this.items,
    required this.fromCache,
    required this.syncedAt,
    this.loadedPages = 1,
    this.totalPages = 1,
  });

  bool get hasMore => loadedPages < totalPages;

  MediaLibrarySnapshot copyWith({List<MediaItem>? items}) =>
      MediaLibrarySnapshot(
        kind: kind,
        categoryId: categoryId,
        parentId: parentId,
        categories: categories,
        items: items ?? this.items,
        fromCache: fromCache,
        syncedAt: syncedAt,
        loadedPages: loadedPages,
        totalPages: totalPages,
      );
}

/// Sits between a [Source] and the [AppDatabase]: serves channels from cache
/// when available, refreshes EPG when stale, and only hits the provider for
/// the heavy fetch on a cold start or an explicit refresh.
class LibraryRepository {
  final Source source;
  final AppDatabase db;
  final List<MetadataProvider> metadataProviders;
  final bool autoEnrichMetadata;
  final String? _sourceCacheIdentity;
  final DateTime Function() _now;

  static const catalogMaxAge = Duration(hours: 24);
  static const _catalogKinds = [
    ContentKind.live,
    ContentKind.movie,
    ContentKind.series,
  ];
  final _catalogChanged = StreamController<ContentKind>.broadcast();
  final Map<ContentKind, Future<void>> _catalogSyncs = {};
  final Map<ContentKind, LoadToken> _catalogTokens = {};
  final Set<ContentKind> _forcedCatalogSyncs = {};
  final Map<Object, Future<dynamic>> _sharedReads = {};
  LoadToken? _catalogBatchToken;
  Object _implicitCatalogRefreshKey = Object();
  LibrarySnapshot? _lastLiveCatalogSnapshot;

  Stream<ContentKind> get catalogChanged => _catalogChanged.stream;

  /// EPG is re-fetched if older than this (or on a forced refresh).
  static const _epgMaxAge = Duration(hours: 6);
  static const _initialMediaPages = 1;
  static const _mediaPagesPerLoad = 3;
  static const _fallbackCategoryPages = 1;
  static const _fallbackCategoryLimit = 8;

  LibraryRepository({
    required this.source,
    required this.db,
    MetadataProvider? metadataProvider,
    List<MetadataProvider>? metadataProviders,
    this.autoEnrichMetadata = true,
    String? sourceCacheIdentity,
    DateTime Function()? now,
  }) : metadataProviders = metadataProviders ?? [?metadataProvider],
       _sourceCacheIdentity =
           sourceCacheIdentity ?? sourceCacheIdentityForSource(source),
       _now = now ?? DateTime.now;

  bool get canEnrichMetadata => metadataProviders.isNotEmpty;

  Future<String?> _cacheIdentityForCurrentCall() async {
    final expected = _sourceCacheIdentity;
    if (expected == null) return null;
    if (!await db.migrateSourceCacheIdentity(
      source.id,
      source.name,
      expected,
      onlyIfUnknown: true,
    )) {
      throw const LoadCancelledException();
    }
    await _ensureCacheIdentityCurrent(expected);
    return expected;
  }

  Future<void> _ensureCacheIdentityCurrent(String? expected) async {
    if (expected != null &&
        !await db.sourceCacheIdentityMatches(source.id, expected)) {
      throw const LoadCancelledException();
    }
  }

  // Keep the operation shared until its cache write finishes, not just until
  // HTTP completes. Otherwise another screen can miss that same cache again.
  Future<T> _shareRead<T>(Object key, Future<T> Function() read) {
    final pending = _sharedReads[key];
    if (pending != null) return pending as Future<T>;
    late final Future<T> operation;
    operation = read().whenComplete(() {
      if (identical(_sharedReads[key], operation)) _sharedReads.remove(key);
    });
    _sharedReads[key] = operation;
    return operation;
  }

  /// One deadline, based on durable full-catalog timestamps, including empty
  /// catalogs. Older builds' partially loaded lists are completed on first use.
  Future<Duration> catalogRefreshDelay() async {
    await _cacheIdentityForCurrentCall();
    var delay = catalogMaxAge;
    for (final kind in _catalogKinds) {
      final last = await db.lastCatalogSynced(source.id, kind);
      if (last == null) return Duration.zero;
      final remaining = last.add(catalogMaxAge).difference(_now());
      if (remaining <= Duration.zero) return Duration.zero;
      if (remaining < delay) delay = remaining;
    }
    return delay;
  }

  void cancelCatalogSync() {
    _catalogBatchToken?.cancel();
    for (final token in _catalogTokens.values) {
      token.cancel();
    }
  }

  /// Refresh each due section independently. A failed provider read leaves the
  /// previous section and its timestamp intact; successful sections still land.
  Future<void> synchronizeCatalog({bool forceRefresh = false}) async {
    final token = LoadToken();
    _catalogBatchToken = token;
    Object? failure;
    for (final kind in _catalogKinds) {
      if (token.isCancelled) return;
      try {
        await _synchronizeCatalogKind(
          kind,
          forceRefresh: forceRefresh,
          token: token,
        );
      } on LoadCancelledException {
        return;
      } on ProviderRequestBlocked {
        rethrow;
      } catch (error) {
        failure ??= error;
        DiagnosticsLog.instance.add(
          'library',
          '${kind.name} catalog refresh failed; retaining cached catalog: '
              '${redactText(error.toString())}',
        );
      }
    }
    if (failure != null) throw failure;
  }

  Future<void> synchronizeMediaCatalog(
    ContentKind kind, {
    bool forceRefresh = false,
    LoadToken? token,
  }) => _synchronizeCatalogKind(kind, forceRefresh: forceRefresh, token: token);

  Future<void> _synchronizeCatalogKind(
    ContentKind kind, {
    bool forceRefresh = false,
    LoadToken? token,
  }) {
    final pending = _catalogSyncs[kind];
    if (pending != null) {
      if ((forceRefresh && !_forcedCatalogSyncs.contains(kind)) ||
          _catalogTokens[kind]?.isCancelled == true) {
        return pending
            .catchError((Object _) {})
            .then(
              (_) => _synchronizeCatalogKind(
                kind,
                forceRefresh: forceRefresh,
                token: token,
              ),
            );
      }
      return pending;
    }
    if (_catalogSyncs.isEmpty) _implicitCatalogRefreshKey = Object();
    final refreshKey = token ?? _implicitCatalogRefreshKey;
    final activeToken = token ?? LoadToken();
    _catalogTokens[kind] = activeToken;
    if (forceRefresh) _forcedCatalogSyncs.add(kind);
    late final Future<void> operation;
    operation =
        (() async {
          final expectedCacheIdentity = await _cacheIdentityForCurrentCall();
          final last = await db.lastCatalogSynced(source.id, kind);
          if (!forceRefresh &&
              last != null &&
              _now().difference(last) < catalogMaxAge) {
            return;
          }
          if (activeToken.isCancelled) throw const LoadCancelledException();
          if (source is SharedCatalogSource) {
            await (source as SharedCatalogSource).prepareCatalog(
              refreshKey,
              refresh: forceRefresh || last != null,
            );
          } else if ((forceRefresh || last != null) && source is RefreshableSource) {
            (source as RefreshableSource).invalidate();
          }
          if (kind == ContentKind.live) {
            _lastLiveCatalogSnapshot = await _loadChannels(
              forceRefresh: true,
              token: activeToken,
            );
          } else {
            await source.connect();
            final categories = await source.mediaCategories(kind);
            final items = await _fetchCompleteMediaCatalog(
              kind,
              categories,
              activeToken,
            );
            await db.replaceMediaLibrary(
              source.id,
              kind,
              categories,
              items,
              completeCatalog: true,
              refreshSeriesChildren: kind == ContentKind.series,
              expectedCacheIdentity: expectedCacheIdentity,
              token: activeToken,
            );
          }
          await _ensureCacheIdentityCurrent(expectedCacheIdentity);
          if (!activeToken.isCancelled) _catalogChanged.add(kind);
        })().whenComplete(() {
          if (identical(_catalogSyncs[kind], operation)) {
            _catalogSyncs.remove(kind);
            _catalogTokens.remove(kind);
            _forcedCatalogSyncs.remove(kind);
          }
        });
    _catalogSyncs[kind] = operation;
    return operation;
  }

  Future<List<MediaItem>> _fetchCompleteMediaCatalog(
    ContentKind kind,
    List<MediaCategory> categories,
    LoadToken token,
  ) async {
    if (source is FullMediaCatalogSource) {
      return (source as FullMediaCatalogSource).allMediaItems(
        kind,
        token: token,
      );
    }
    final items = <MediaItem>[];
    final seen = <String>{};
    final categoryIds = categories.isEmpty
        ? <String?>[null]
        : categories.map((category) => category.id).toSet().toList();
    for (final categoryId in categoryIds) {
      for (var page = 1; ; page++) {
        if (token.isCancelled) throw const LoadCancelledException();
        final fetched = await source.mediaItemsPage(
          kind,
          categoryId: categoryId,
          page: page,
        );
        for (final item in fetched.items) {
          if (item.id.isNotEmpty && seen.add(item.id)) items.add(item);
        }
        if (!fetched.hasMore) break;
        if (fetched.page != page) {
          throw StateError('Provider returned an invalid catalog page');
        }
      }
    }
    return items;
  }

  /// Cooperative-cancellation token for the in-flight [load]/[loadMedia]/
  /// [loadMoreMedia] call, additive to the controllers' `_loadGeneration`
  /// guards (see docs/development.md): the
  /// generation guard stops a stale result from being *published*; this token
  /// stops a stale call from **overwriting a populated cache** once a newer
  /// call has superseded it. It does *not* stop the write outright — a
  /// superseded load may still seed an *empty* cache (`_loadChannels`,
  /// `loadMedia`), and it does not reach the EPG batch path at all, which is
  /// cancelled by `EpgIngestCoordinator`'s own tokens instead.
  ///
  /// This is a plain settable field rather than a parameter on those methods
  /// on purpose: [LibraryRepository] is subclassed by Completer-gated test
  /// doubles (`test/live_controller_test.dart`, `test/media_tab_controller_test.dart`)
  /// that `@override` `load`/`loadMedia`/`loadMoreMedia`, and Dart requires an
  /// override to redeclare every parameter of the method it overrides —
  /// adding a new named parameter to these methods would break those pinned
  /// overrides. A caller sets [loadToken] to the token it wants honoured, then
  /// invokes the method in the same synchronous prologue (no `await` in
  /// between); each method reads it into a local at its very first line,
  /// before its own first `await`, so a later reassignment (a newer call
  /// superseding this one) can never leak into a call already under way.
  LoadToken? loadToken;

  Future<LibrarySnapshot> load({bool forceRefresh = false}) async {
    final token = loadToken;
    final LibrarySnapshot snapshot;
    if (forceRefresh) {
      // Share the same ordering as daily synchronization, so an older
      // background download cannot land after a manual refresh.
      await _synchronizeCatalogKind(
        ContentKind.live,
        forceRefresh: true,
        token: token,
      );
      // Even a superseded load returns its fetched snapshot; the controller's
      // generation guard discards it while the DB keeps the previous catalog.
      snapshot = _lastLiveCatalogSnapshot!;
    } else {
      snapshot = await _loadChannels(forceRefresh: false, token: token);
    }

    // EPG is best-effort and time-sensitive: the channel list does not depend
    // on it, so it refreshes *behind* the returned snapshot rather than in
    // front of it. A second guide costs a second download and parse, and
    // awaiting that put 5-10 seconds of spinner between the user and a channel
    // list that was already in hand.
    //
    // Backgrounding it was tried once before and reverted, because
    // `replaceEpgStream` held one write transaction across every guide's
    // *download*: on the single sqflite connection this app shares, that
    // blocked all other database work for the length of the network fetch, and
    // switching source mid-ingest deadlocked (`channel_list_focus_test` hung
    // for ten minutes on sqflite's "database has been locked" warning). Two
    // things make it safe now, and neither is optional:
    //
    //  * [ProgrammeSpool] drains the guide to a temporary file first, so the
    //    transaction only ever spans local inserts — bounded, and with no
    //    network inside it.
    //  * [AppDatabase.epgIngest] holds one refresh at a time app-wide and waits
    //    for a superseded one to stop before its replacement starts.
    //
    // Whether it is *worth* refreshing is decided here rather than inside the
    // refresh, so a load that has nothing to do leaves [pendingEpgRefresh] null
    // instead of handing the UI a future that completes immediately. The live
    // status line reads that to say "updating guide", and a guide that was
    // already fresh would otherwise flash the message for one frame on every
    // load.
    //
    // A *superseded* load skips it outright. The load that cancelled this one
    // schedules its own, and `EpgIngestCoordinator` is last-start-wins — so a
    // late refresh from a stale load would take the slot *from* the correct one
    // already running, and match guides against the channel list this load
    // fetched rather than the one now cached. Nothing is lost by skipping:
    // `epg_synced_at` is only advanced by a refresh that actually landed, so
    // the next load still finds the guide stale and re-runs it.
    if (!(token?.isCancelled ?? false)) {
      await refreshEpg(snapshot.channels, forceRefresh: forceRefresh);
    } else {
      _pendingEpgRefresh = null;
    }

    return snapshot;
  }

  /// Check guide freshness without reloading the channel catalog. Returns once
  /// any due download is scheduled; [pendingEpgRefresh] observes its completion.
  Future<void> refreshEpg(
    List<Channel> channels, {
    bool forceRefresh = false,
  }) async {
    final expectedCacheIdentity = await _cacheIdentityForCurrentCall();
    if (!forceRefresh && _activeEpgRefresh != null) {
      // Onboarding seeds this repository before the browsing screen loads it.
      // Keep its guide download alive across that cache-only handoff.
      _pendingEpgRefresh = _activeEpgRefresh;
    } else if (await _epgNeedsRefresh(forceRefresh)) {
      unawaited(
        _scheduleEpgRefresh(
          channels,
          forceRefresh: forceRefresh,
          expectedCacheIdentity: expectedCacheIdentity,
        ),
      );
    } else {
      _pendingEpgRefresh = null;
    }
  }

  /// Whether the cached guide is old enough (or the load forced enough) to be
  /// worth re-fetching.
  Future<bool> _epgNeedsRefresh(bool forceRefresh) async {
    if (forceRefresh) return true;
    if (db.epgIngest.retryAfter(source.id)?.isAfter(_now()) == true) return false;
    final last = await db.lastEpgSynced(source.id);
    return last == null || _now().difference(last) > _epgMaxAge;
  }

  /// The background EPG refresh this repository last started, or null if it has
  /// not started one.
  ///
  /// Exposed for tests and for any caller that genuinely needs the guide before
  /// it can continue — [load] deliberately does not wait for it.
  Future<void>? get pendingEpgRefresh => _pendingEpgRefresh;
  Future<void>? _pendingEpgRefresh;
  Future<void>? _activeEpgRefresh;

  Future<void> _scheduleEpgRefresh(
    List<Channel> channels, {
    required bool forceRefresh,
    required String? expectedCacheIdentity,
  }) {
    if (!forceRefresh && _activeEpgRefresh != null) return _activeEpgRefresh!;
    // The token comes from the coordinator, not from [loadToken]: this outlives
    // the `load()` that started it, and cancellation now means "a newer refresh
    // has taken the slot", which is the coordinator's business rather than the
    // load's.
    final refresh = db.epgIngest.start(
      source.id,
      (token) => _refreshEpg(
        channels,
        forceRefresh: forceRefresh,
        expectedCacheIdentity: expectedCacheIdentity,
        token: token,
      ),
    );
    _pendingEpgRefresh = refresh;
    _activeEpgRefresh = refresh;
    unawaited(
      refresh.whenComplete(() {
        if (identical(_activeEpgRefresh, refresh)) _activeEpgRefresh = null;
      }),
    );
    return refresh;
  }

  Future<LibrarySnapshot> _loadChannels({
    required bool forceRefresh,
    LoadToken? token,
  }) => _shareRead(
    ('live', forceRefresh, token),
    () => _fetchChannels(forceRefresh: forceRefresh, token: token),
  );

  Future<LibrarySnapshot> _fetchChannels({
    required bool forceRefresh,
    LoadToken? token,
  }) async {
    final expectedCacheIdentity = await _cacheIdentityForCurrentCall();
    if (!forceRefresh) {
      final synced = await db.lastSynced(source.id);
      if (synced != null) {
        final channels = await db.readChannels(source.id);
        if (channels.isNotEmpty ||
            await db.lastCatalogSynced(source.id, ContentKind.live) != null) {
          final categories = await db.readCategories(source.id);
          await _ensureCacheIdentityCurrent(expectedCacheIdentity);
          return LibrarySnapshot(
            categories: categories,
            channels: channels,
            fromCache: true,
            syncedAt: synced,
          );
        }
      }
    }

    await source.connect();
    if (!forceRefresh && source is SharedCatalogSource) {
      await (source as SharedCatalogSource).prepareCatalog(
        token ?? _implicitCatalogRefreshKey,
        refresh: false,
      );
    }
    final providerWatch = Stopwatch()..start();
    final categories = await source.categories();
    final channels = await source.channels();
    providerWatch.stop();
    // A superseded load must never *overwrite* a cached catalog — but it must
    // still be allowed to **seed an empty one**, and the whole point of this
    // branch is the difference between the two.
    //
    // Overwriting is genuinely unsafe, for two reasons that outlive the
    // controller's generation guard (which only stops the UI publish). The
    // channel cache has no age check — `_loadChannels` above gates on "is there
    // a cache", nothing more — so whatever lands here stands until an explicit
    // forced refresh. And commit order is not fetch order: a slow superseded
    // load can land *after* the fast one that replaced it, stamping older rows
    // with a newer `synced_at`. Worse, `upgradeM3uToXtream` deliberately keeps
    // the source id, so an in-flight M3U load can outlive the upgrade and write
    // playlist-shaped rows under a source that is now Xtream — whose `resolve`
    // falls back to `channel.id` for the stream id, i.e. every channel silently
    // unplayable, permanently.
    //
    // Refusing to write *at all*, though, is how a device gets stuck, and that
    // is a real field report rather than a hypothetical: on a low-end TV box a
    // 66 MB playlist costs ~55 s (29 s download + 26 s isolate parse), and
    // every rebuild of the repository — the load-time M3U→Xtream probe alone
    // does one per app start — cancelled the load and threw the finished
    // catalog away. The cache stayed empty, so the next attempt paid the full
    // 55 s again, forever. A complete catalog is strictly better than none.
    //
    // `onlyIfAbsent` settles both orders with no sequencing and no identity on
    // the token: the stale writer commits only while there is nothing to lose,
    // and a fresh catalog that already landed makes it a no-op.
    final superseded = token?.isCancelled ?? false;
    final databaseWatch = Stopwatch()..start();
    var wrote = false;
    try {
      wrote = await db.replaceLibrary(
        source.id,
        source.name,
        categories,
        channels,
        onlyIfAbsent: superseded,
        token: token,
        completeCatalog: true,
        expectedCacheIdentity: expectedCacheIdentity,
      );
    } catch (error) {
      // A supersede correlates with teardown, so the connection may be closing
      // under us. Losing the seed is acceptable; failing the load is not.
      if (!superseded) rethrow;
      DiagnosticsLog.instance.add(
        'library',
        'superseded seed for ${source.id} failed: ${error.runtimeType}',
      );
    }
    await _ensureCacheIdentityCurrent(expectedCacheIdentity);
    databaseWatch.stop();
    if (wrote) {
      DiagnosticsLog.instance.recordIngestion(
        scope: 'source:${source.id}',
        providerDuration: providerWatch.elapsed,
        databaseDuration: databaseWatch.elapsed,
      );
    } else {
      // The field report's worst property was silence: ~55 s of work left
      // nothing whatsoever in the exported log.
      DiagnosticsLog.instance.add(
        'library',
        'superseded load for ${source.id}: ${channels.length} channels fetched '
            'in ${providerWatch.elapsed.inMilliseconds} ms, not written '
            '(cache already populated)',
      );
    }
    return LibrarySnapshot(
      categories: categories,
      channels: channels,
      fromCache: false,
      syncedAt: DateTime.now(),
    );
  }

  /// Whether the last completed guide refresh failed outright.
  ///
  /// A failed refresh is invisible by design — the cached guide is retained and
  /// the channel list is untouched — which is right, except when there is no
  /// cached guide to retain. "No EPG at all" and "every guide URL is broken"
  /// then look identical on screen, and only the second is something the user
  /// can act on. `LiveController` pairs this with an empty guide to say so.
  ///
  /// A *superseded* refresh sets neither verdict: it is not an outcome.
  bool get lastEpgRefreshFailed => _lastEpgRefreshFailed;
  bool _lastEpgRefreshFailed = false;
  String? get lastEpgRefreshError => _lastEpgRefreshError;
  String? _lastEpgRefreshError;

  /// [_ensureEpg] wrapped in [load]'s failure policy, and the only place the
  /// [lastEpgRefreshFailed] verdict is decided.
  ///
  /// Completes without an error in every case: the coordinator drops this
  /// future, where a rejection would surface as an unhandled asynchronous
  /// error rather than as anything a user could act on.
  Future<void> _refreshEpg(
    List<Channel> channels, {
    required bool forceRefresh,
    required String? expectedCacheIdentity,
    LoadToken? token,
  }) async {
    try {
      // Another caller may have committed a guide while this refresh queued.
      if (!await _epgNeedsRefresh(forceRefresh)) return;
      await _ensureEpg(
        channels,
        forceRefresh: forceRefresh,
        expectedCacheIdentity: expectedCacheIdentity,
        token: token,
      );
      _lastEpgRefreshFailed = false;
      _lastEpgRefreshError = null;
      db.epgIngest.deferRetry(source.id, null);
    } on LoadCancelledException {
      // Superseded by a newer refresh — neither a success nor a failure, so the
      // previous verdict stands rather than being overwritten by a non-event.
      DiagnosticsLog.instance.add('epg', 'EPG refresh superseded');
    } catch (error) {
      // Source may not provide EPG, or the call failed — keep the cached
      // guide. Re-entering the screen must not immediately repeat a failed
      // automatic download; explicit refresh remains available.
      _lastEpgRefreshFailed = true;
      _lastEpgRefreshError = sourceLoadErrorMessage(error);
      db.epgIngest.deferRetry(source.id, _now().add(const Duration(minutes: 15)));
      DiagnosticsLog.instance.add(
        'epg',
        'EPG refresh failed; retaining cached guide: ${redactText(error.toString())}',
      );
    }
  }

  Future<void> _ensureEpg(
    List<Channel> channels, {
    required bool forceRefresh,
    required String? expectedCacheIdentity,
    LoadToken? token,
  }) async {
    await source.connect();
    final overrides = await db.readEpgMappings(source.id);
    if (token?.isCancelled ?? false) throw const LoadCancelledException();
    final mapping = source is MappedEpgSource
        ? (source as MappedEpgSource).epgMapping
        : null;
    mapping?.begin(overrides);
    final offsets = {
      for (final override in overrides)
        if (override.offsetMinutes != 0)
          override.channelId: Duration(minutes: override.offsetMinutes),
    };
    Programme correct(Programme p) {
      final offset = offsets[p.channelId];
      if (offset == null) return p;
      return Programme(
        channelId: p.channelId,
        start: p.start.add(offset),
        stop: p.stop.add(offset),
        title: p.title,
        description: p.description,
      );
    }

    // _refreshEpg rechecks freshness after waiting for the shared ingest slot.
    if (source is BatchedEpgSource) {
      // `is` doesn't promote across unrelated interfaces (Source and
      // BatchedEpgSource share no subtype relationship), hence the explicit
      // cast — safe, guarded by the check above.
      final batchedSource = source as BatchedEpgSource;
      final batches = batchedSource.epgBatched(channels, token: token);
      if (batches != null) {
        // Download, decompress and parse every guide to a temporary file
        // **before** opening a transaction. See [ProgrammeSpool]: consumed
        // directly, this stream would have held the app's only database
        // connection for the length of the network fetch.
        //
        // A supersede propagates out of here rather than being caught: it is
        // [_refreshEpg] that decides what a cancellation means, and swallowing
        // it here recorded one as a successful guide.
        final providerWatch = Stopwatch()..start();
        final spool = await ProgrammeSpool.drain(
          offsets.isEmpty
              ? batches
              : batches.map((batch) => batch.map(correct).toList()),
        );
        providerWatch.stop();
        try {
          if (token?.isCancelled ?? false) throw const LoadCancelledException();
          final metrics = await db.replaceEpgStream(
            source.id,
            spool.read(),
            guideChannels: mapping?.catalogue,
            token: token,
            expectedCacheIdentity: expectedCacheIdentity,
          );
          DiagnosticsLog.instance.add(
            'epg',
            'guide staged for ${source.id}: ${spool.programmes} programmes '
                'in ${spool.batches} batches, ${formatBytes(spool.bytes)} '
                'spooled',
          );
          DiagnosticsLog.instance.recordIngestion(
            scope: 'epg:${source.id}',
            providerDuration: providerWatch.elapsed,
            databaseDuration: metrics.databaseDuration,
          );
        } finally {
          await spool.dispose();
        }
        db.notifyEpgChanged(source.id);
        return;
      }
    }

    final providerWatch = Stopwatch()..start();
    final programmes = await source.epg(channels);
    providerWatch.stop();
    if (token?.isCancelled ?? false) {
      // Superseded by a newer refresh — skip the stale guide write. Thrown
      // rather than returned so [_refreshEpg] can tell this apart from a
      // guide that genuinely landed: returning normally recorded a supersede
      // as a *success*, clearing any real failure verdict behind it. The
      // previous guide stays intact with its epg_synced_at un-advanced, so
      // the newer refresh still replaces it.
      throw const LoadCancelledException();
    }
    // Always replace — a success-empty result (a source with no EPG data)
    // must still clear any stale cached programmes and advance
    // epg_synced_at, or a no-EPG source gets re-fetched on every load.
    final databaseWatch = Stopwatch()..start();
    await db.replaceEpg(
      source.id,
      offsets.isEmpty ? programmes : programmes.map(correct),
      guideChannels: mapping?.catalogue,
      expectedCacheIdentity: expectedCacheIdentity,
    );
    databaseWatch.stop();
    DiagnosticsLog.instance.recordIngestion(
      scope: 'epg:${source.id}',
      providerDuration: providerWatch.elapsed,
      databaseDuration: databaseWatch.elapsed,
    );
    db.notifyEpgChanged(source.id);
  }

  Future<({Map<String, Programme> now, Map<String, Programme> next})>
  nowNext({List<String>? channelIds}) => channelIds == null
      ? db.nowNext(source.id, DateTime.now())
      : db.nowNextForChannels(source.id, channelIds, DateTime.now());

  Future<List<ProgrammeSearchResult>> searchProgrammes(
    String query, {
    Set<String>? allowedChannelIds,
    DateTime? from,
    DateTime? to,
    int limit = 80,
  }) => db.searchProgrammes(
    query,
    sourceId: source.id,
    allowedChannelIds: allowedChannelIds,
    from: from,
    to: to,
    limit: limit,
  );

  Future<List<EpgChannelOverride>> readEpgMappings() =>
      db.readEpgMappings(source.id);

  Future<List<EpgGuideChannel>> readEpgGuideChannels() =>
      db.readEpgGuideChannels(source.id);

  Future<void> setEpgMapping(
    EpgChannelOverride mapping, {
    List<Channel>? channels,
  }) async {
    final expectedCacheIdentity = await _cacheIdentityForCurrentCall();
    await db.setEpgMapping(source.id, mapping);
    final available = channels ?? await db.readChannels(source.id);
    // The settings save is immediate; staging and atomic replacement retain the
    // same background-refresh contract as load(). The coordinator serializes
    // this against any refresh using an older set of overrides.
    unawaited(
      _scheduleEpgRefresh(
        available,
        forceRefresh: true,
        expectedCacheIdentity: expectedCacheIdentity,
      ),
    );
  }

  /// Cached programmes for [channel] over the catch-up window (its
  /// [Channel.archiveDays] back to now), newest-last. Empty when the channel has
  /// no archive or no cached EPG. The guide reads this to list past programmes.
  Future<List<Programme>> archiveProgrammes(Channel channel) {
    if (!channel.hasArchive) return Future.value(const []);
    final now = DateTime.now();
    return db.programmesForChannel(
      source.id,
      channel.id,
      from: now.subtract(Duration(days: channel.archiveDays)),
      to: now,
    );
  }

  /// Reveal point (see [db.revealChannel] and docs/development.md "Sealed playback
  /// locators"): cached channels carry their locator encrypted, so it is
  /// decrypted here — one model, at play time — before crossing into the
  /// [Source].
  Future<StreamInfo> resolve(Channel channel) async {
    await source.connect();
    return source.resolve(await db.revealChannel(channel));
  }

  /// Resolve a past [programme] on [channel] into a catch-up stream. Resolved at
  /// play time (archive URLs are short-lived, like live). Reveal point.
  Future<StreamInfo> resolveArchive(
    Channel channel,
    Programme programme,
  ) async {
    await source.connect();
    return source.resolveArchive(await db.revealChannel(channel), programme);
  }

  /// Playback can skip external child lookups while retaining cached metadata.
  Future<MediaLibrarySnapshot> loadMedia(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    bool forceRefresh = false,
    bool enrichChildren = true,
  }) {
    final token = loadToken;
    return _shareRead(
      ('media', kind, categoryId, parent?.id, forceRefresh, enrichChildren, token),
      () => _loadMedia(
        kind,
        categoryId: categoryId,
        parent: parent,
        forceRefresh: forceRefresh,
        enrichChildren: enrichChildren,
        token: token,
      ),
    );
  }

  Future<MediaLibrarySnapshot> _loadMedia(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    required bool forceRefresh,
    required bool enrichChildren,
    LoadToken? token,
  }) async {
    final expectedCacheIdentity = await _cacheIdentityForCurrentCall();
    // A forced reload must drop any memoized VOD/series catalog before
    // fetching (see [load]); pagination (`loadMoreMedia`) never invalidates.
    // Reveal point, and the easiest one to miss: `parent` is a *cached* model
    // (a season the user drilled into), so its locator is sealed, and
    // `StalkerSource._seasonPlaybackHints` reads `parent.extra['cmd']` to give
    // every episode it builds a playable command. Reassigning the parameter
    // rather than introducing a local guarantees no downstream use here can
    // keep hold of the sealed one; see docs/development.md.
    if (parent != null) parent = await db.revealMediaItem(parent);
    final parentId = parent?.id;
    if (parent == null &&
        (kind == ContentKind.movie || kind == ContentKind.series)) {
      final cached = await db.lastCatalogSynced(source.id, kind);
      if (forceRefresh || cached == null) {
        await synchronizeMediaCatalog(
          kind,
          forceRefresh: forceRefresh,
          token: token,
        );
      }
      final categories = await db.readMediaCategories(source.id, kind);
      final items = await _readMergedMediaItems(kind, categoryId: categoryId);
      final syncedAt = await db.lastCatalogSynced(source.id, kind);
      await _ensureCacheIdentityCurrent(expectedCacheIdentity);
      return MediaLibrarySnapshot(
        kind: kind,
        categoryId: categoryId,
        categories: categories,
        items: items,
        fromCache: !forceRefresh && cached != null,
        syncedAt: syncedAt,
      );
    }
    if (forceRefresh && source is RefreshableSource) {
      (source as RefreshableSource).invalidate();
    }
    if (!forceRefresh) {
      final sync = await db.mediaSyncState(
        source.id,
        kind,
        categoryId: categoryId,
        parentId: parentId,
      );
      if (sync != null) {
        final items = await db.readMediaItems(
          source.id,
          kind,
          categoryId: categoryId,
          parentId: parentId,
        );
        if (items.isNotEmpty || sync.loadedPages >= sync.totalPages) {
          var mergedItems = await _mergeCachedMetadata(items);
          if (parent != null && enrichChildren) {
            mergedItems = await _applyChildExternalMetadata(
              parent,
              mergedItems,
              action: 'cache-child',
              persistChanges: true,
            );
          }
          final categories = await db.readMediaCategories(source.id, kind);
          await _ensureCacheIdentityCurrent(expectedCacheIdentity);
          return MediaLibrarySnapshot(
            kind: kind,
            categoryId: categoryId,
            parentId: parentId,
            categories: categories,
            items: mergedItems,
            fromCache: true,
            syncedAt: sync.syncedAt,
            loadedPages: sync.loadedPages,
            totalPages: sync.totalPages,
          );
        }
      }
    }

    final seriesCatalogVersion =
        kind == ContentKind.season || kind == ContentKind.episode
        ? (syncedAt: await db.lastCatalogSynced(source.id, ContentKind.series))
        : null;
    if (parent?.kind == ContentKind.series) {
      // An open details sheet may still hold the pre-refresh episode tree.
      // Only a child-cache miss needs this read; warm browsing stays unchanged.
      final current = await db.readMediaItemsByIds(
        source.id,
        ContentKind.series,
        [parent!.id],
      );
      if (current.isNotEmpty) parent = await db.revealMediaItem(current.single);
    } else if (parent?.kind == ContentKind.season &&
        seriesCatalogVersion?.syncedAt != null) {
      // A sheet can also retain an old season whose embedded episode list was
      // invalidated. Rebuild that season from the current series on demand.
      var current = await db.readMediaItemsByIds(
        source.id,
        ContentKind.season,
        [parent!.id],
      );
      if (current.isEmpty && parent.parentId != null) {
        final roots = await db.readMediaItemsByIds(
          source.id,
          ContentKind.series,
          [parent.parentId!],
        );
        if (roots.isNotEmpty) {
          final seasons = await loadMedia(
            ContentKind.season,
            parent: roots.single,
            enrichChildren: false,
          );
          current = seasons.items.where((item) => item.id == parent!.id).toList();
        }
      }
      if (current.isEmpty) throw const LoadCancelledException();
      parent = await db.revealMediaItem(current.single);
    }
    await source.connect();
    final categories = await source.mediaCategories(kind);
    final fetched = await _fetchMediaItems(
      kind,
      categories,
      categoryId: categoryId,
      parent: parent,
    );
    final fetchedItems = parent == null || !enrichChildren
        ? fetched.items
        : await _applyChildExternalMetadata(
            parent,
            fetched.items,
            action: 'load-child',
          );
    // Seed-but-never-overwrite, exactly as `_loadChannels` does and for the
    // same reasons — read the long comment there. The media cache has the same
    // shape of trap: `loadMedia`'s gate above asks only whether a cache exists.
    final superseded = token?.isCancelled ?? false;
    try {
      await db.replaceMediaLibrary(
        source.id,
        kind,
        categories,
        fetchedItems,
        categoryId: categoryId,
        parentId: parentId,
        loadedPages: fetched.loadedPages,
        totalPages: fetched.totalPages,
        onlyIfAbsent: superseded,
        seriesCatalogVersion: seriesCatalogVersion,
        expectedCacheIdentity: expectedCacheIdentity,
      );
    } catch (error) {
      if (!superseded) rethrow;
      DiagnosticsLog.instance.add(
        'library',
        'superseded ${kind.name} seed for ${source.id} failed: '
            '${error.runtimeType}',
      );
    }
    await _ensureCacheIdentityCurrent(expectedCacheIdentity);
    return MediaLibrarySnapshot(
      kind: kind,
      categoryId: categoryId,
      parentId: parentId,
      categories: categories,
      items: await _mergeCachedMetadata(fetchedItems),
      fromCache: false,
      syncedAt: DateTime.now(),
      loadedPages: fetched.loadedPages,
      totalPages: fetched.totalPages,
    );
  }

  Future<({List<MediaItem> items, int loadedPages, int totalPages})>
  _fetchMediaItems(
    ContentKind kind,
    List<MediaCategory> categories, {
    String? categoryId,
    MediaItem? parent,
  }) async {
    final out = <MediaItem>[];
    final seen = <String>{};
    var loadedPages = 1;
    var totalPages = 1;
    void addAll(List<MediaItem> items) {
      for (final item in items) {
        if (item.id.isNotEmpty && seen.add(item.id)) out.add(item);
      }
    }

    for (var page = 1; page <= _initialMediaPages; page++) {
      final fetched = await source.mediaItemsPage(
        kind,
        categoryId: categoryId,
        parent: parent,
        page: page,
      );
      totalPages = fetched.totalPages;
      loadedPages = page;
      addAll(fetched.items);
      if (!fetched.hasMore) break;
    }
    if (out.isNotEmpty || categories.isEmpty) {
      return (items: out, loadedPages: loadedPages, totalPages: totalPages);
    }
    if (categoryId != null) {
      return (items: out, loadedPages: loadedPages, totalPages: totalPages);
    }

    for (final category in _prioritizedFallbackCategories(kind, categories)) {
      addAll(
        await source.mediaItems(
          kind,
          categoryId: category.id,
          parent: parent,
          maxPages: _fallbackCategoryPages,
        ),
      );
      if (out.length >= 200) break;
    }
    return (items: out, loadedPages: 1, totalPages: 1);
  }

  Iterable<MediaCategory> _prioritizedFallbackCategories(
    ContentKind kind,
    List<MediaCategory> categories,
  ) {
    final ordered = [...categories];
    if (kind == ContentKind.series) {
      int score(MediaCategory category) {
        final title = category.title.toLowerCase();
        if (title.contains('series') ||
            title.contains('shows') ||
            title.contains('episodes')) {
          return 0;
        }
        if (title.contains('tv')) return 1;
        return 2;
      }

      ordered.sort((a, b) {
        final byScore = score(a).compareTo(score(b));
        return byScore == 0 ? a.title.compareTo(b.title) : byScore;
      });
    }
    return ordered.take(_fallbackCategoryLimit);
  }

  MediaLibrarySnapshot? _pagingSnapshot;

  /// Extends the caller's current list without reloading every cached media
  /// row. Dispatch through [loadMoreMedia] so existing repository overrides
  /// retain their behavior; the base method captures this context before await.
  Future<MediaLibrarySnapshot> loadMoreMediaFromSnapshot(
    MediaLibrarySnapshot snapshot, {
    MediaItem? parent,
  }) {
    _pagingSnapshot = snapshot;
    try {
      return loadMoreMedia(
        snapshot.kind,
        categoryId: snapshot.categoryId,
        parent: parent,
      );
    } finally {
      _pagingSnapshot = null;
    }
  }

  Future<MediaLibrarySnapshot> loadMoreMedia(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    bool enrichChildren = true,
  }) {
    final current = _pagingSnapshot;
    final token = loadToken;
    return _shareRead(
      ('more', kind, categoryId, parent?.id, enrichChildren, token),
      () => _loadMoreMedia(
        kind,
        categoryId: categoryId,
        parent: parent,
        enrichChildren: enrichChildren,
        token: token,
        current: current,
      ),
    );
  }

  Future<MediaLibrarySnapshot> _loadMoreMedia(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    required bool enrichChildren,
    LoadToken? token,
    MediaLibrarySnapshot? current,
  }) async {
    final expectedCacheIdentity = await _cacheIdentityForCurrentCall();
    // Reveal point — same reason as in [loadMedia]: `parent` reaches
    // `source.mediaItemsPage(parent:)`, which reads its locator.
    if (parent != null) parent = await db.revealMediaItem(parent);
    final parentId = parent?.id;
    final sync = await db.mediaSyncState(
      source.id,
      kind,
      categoryId: categoryId,
      parentId: parentId,
    );
    if (sync == null ||
        sync.loadedPages >= sync.totalPages ||
        (token?.isCancelled ?? false)) {
      final categories = await db.readMediaCategories(source.id, kind);
      final items = await _readMergedMediaItems(
        kind,
        categoryId: categoryId,
        parentId: parentId,
      );
      await _ensureCacheIdentityCurrent(expectedCacheIdentity);
      return MediaLibrarySnapshot(
        kind: kind,
        categoryId: categoryId,
        parentId: parentId,
        categories: categories,
        items: items,
        fromCache: true,
        syncedAt: sync?.syncedAt,
        loadedPages: sync?.loadedPages ?? 1,
        totalPages: sync?.totalPages ?? 1,
      );
    }

    await source.connect();
    var loadedPages = sync.loadedPages;
    var totalPages = sync.totalPages;
    final items = <MediaItem>[];
    final pagesPerLoad = parent == null ? _mediaPagesPerLoad : 1;
    for (var i = 0; i < pagesPerLoad && loadedPages < totalPages; i++) {
      if (token?.isCancelled ?? false) break;
      final fetched = await source.mediaItemsPage(
        kind,
        categoryId: categoryId,
        parent: parent,
        page: loadedPages + 1,
      );
      if (token?.isCancelled ?? false) break;
      loadedPages = fetched.page;
      totalPages = fetched.totalPages;
      items.addAll(
        parent == null || !enrichChildren
            ? fetched.items
            : await _applyChildExternalMetadata(
                parent,
                fetched.items,
                action: 'load-more-child',
              ),
      );
      if (!fetched.hasMore) break;
    }
    if (token?.isCancelled ?? false) {
      // Superseded by a newer load — skip the stale append; the prior sync
      // state (loadedPages/totalPages) stays intact for the next read.
      //
      // Deliberately *not* the seed-when-absent treatment `_loadChannels` and
      // `loadMedia` now get. This is a page-bookkeeping guard, not a
      // cache-freshness one: `appendMediaItems` writes back `loadedPages`/
      // `totalPages` read at the top of this method, so a late append lands
      // stale paging state over whatever replaced it. And "no cache" cannot
      // hold here anyway — this method returns early when `sync == null`, so
      // there is never an empty cache to seed.
      final categories = await db.readMediaCategories(source.id, kind);
      final items = await _readMergedMediaItems(
        kind,
        categoryId: categoryId,
        parentId: parentId,
      );
      await _ensureCacheIdentityCurrent(expectedCacheIdentity);
      return MediaLibrarySnapshot(
        kind: kind,
        categoryId: categoryId,
        parentId: parentId,
        categories: categories,
        items: items,
        fromCache: true,
        syncedAt: sync.syncedAt,
        loadedPages: sync.loadedPages,
        totalPages: sync.totalPages,
      );
    }
    await db.appendMediaItems(
      source.id,
      kind,
      items,
      categoryId: categoryId,
      parentId: parentId,
      loadedPages: loadedPages,
      totalPages: totalPages,
      expectedCacheIdentity: expectedCacheIdentity,
    );
    await _ensureCacheIdentityCurrent(expectedCacheIdentity);
    final canExtend =
        current != null &&
        current.kind == kind &&
        current.categoryId == categoryId &&
        current.parentId == parentId &&
        current.loadedPages == sync.loadedPages &&
        current.totalPages == sync.totalPages &&
        current.syncedAt != null &&
        !sync.syncedAt.isAfter(current.syncedAt!);
    final mergedItems = canExtend
        ? await _extendMediaSnapshot(
            current,
            items,
            categoryId: categoryId,
            parentId: parentId,
          )
        : await _readMergedMediaItems(
            kind,
            categoryId: categoryId,
            parentId: parentId,
          );
    return MediaLibrarySnapshot(
      kind: kind,
      categoryId: categoryId,
      parentId: parentId,
      categories: await db.readMediaCategories(source.id, kind),
      items: mergedItems,
      fromCache: false,
      syncedAt: DateTime.now(),
      loadedPages: loadedPages,
      totalPages: totalPages,
    );
  }

  Future<List<MediaItem>> _extendMediaSnapshot(
    MediaLibrarySnapshot current,
    List<MediaItem> appended, {
    String? categoryId,
    String? parentId,
  }) async {
    // INSERT OR REPLACE moves repeated ids to their final page position. Read
    // only those rows back so sealed locators and effective parent ids match DB.
    final ids = appended.reversed.map((item) => item.id).toSet().toList();
    final byId = <String, MediaItem>{};
    for (var start = 0; start < ids.length; start += 500) {
      final rows = await db.readMediaItemsByIds(
        source.id,
        current.kind,
        ids.skip(start).take(500).toList(),
      );
      for (final item in rows) {
        if ((categoryId == null || item.categoryId == categoryId) &&
            (parentId == null || item.parentId == parentId)) {
          byId[item.id] = item;
        }
      }
    }
    final replaced = ids.toSet();
    return _mergeCachedMetadata([
      for (final item in current.items)
        if (!replaced.contains(item.id)) item,
      for (final id in ids.reversed)
        ?byId[id],
    ]);
  }

  Future<MediaItem> mediaDetails(MediaItem item) => _shareRead(
    ('details', item.kind, item.id),
    () => _mediaDetails(item),
  );

  Future<MediaItem> _mediaDetails(MediaItem item) async {
    final expectedCacheIdentity = await _cacheIdentityForCurrentCall();
    final seriesCatalogVersion = item.kind == ContentKind.series
        ? (syncedAt: await db.lastCatalogSynced(source.id, ContentKind.series))
        : null;
    // The current catalog row is authoritative: replacement retains details
    // only for unchanged provider data, even if a caller holds an older item.
    final cached = await db.readMediaItemsByIds(source.id, item.kind, [
      item.id,
    ]);
    var details = cached.isEmpty ? item : cached.single;
    if (details.extra['details'] is! Map) {
      await source.connect();
      // Reveal locators only when crossing into the source. Cache hits can
      // retain their sealed locators through metadata merging and persistence.
      details = await source.mediaDetails(await db.revealMediaItem(details));
    }
    final merged = await _applyExternalMetadata(
      details,
      action: 'details',
      includeDetails: true,
    );
    await db.updateMediaDisplayFields(
      source.id,
      [merged],
      seriesCatalogVersion: seriesCatalogVersion,
      expectedCacheIdentity: expectedCacheIdentity,
    );
    return merged;
  }

  Future<List<MediaItem>> _readMergedMediaItems(
    ContentKind kind, {
    String? categoryId,
    String? parentId,
  }) async {
    final items = await db.readMediaItems(
      source.id,
      kind,
      categoryId: categoryId,
      parentId: parentId,
    );
    return _mergeCachedMetadata(items);
  }

  Future<List<MediaItem>> _mergeCachedMetadata(List<MediaItem> items) async {
    if (items.isEmpty) return items;
    final expectedCacheIdentity = await _cacheIdentityForCurrentCall();
    var out = [...items];
    for (final provider in metadataProviders) {
      final metadata = await db.readExternalMetadataForItems(
        source.id,
        out,
        provider.provider,
      );
      if (metadata.isEmpty) continue;
      out = [
        for (final item in out)
          if (metadata[item.id] case final itemMetadata?)
            _mergeMetadata(
              item,
              itemMetadata,
              ratingsOnly: provider.ratingsOnly,
            )
          else
            item,
      ];
    }
    await _ensureCacheIdentityCurrent(expectedCacheIdentity);
    return out;
  }

  Future<List<MediaItem>> _applyChildExternalMetadata(
    MediaItem parent,
    List<MediaItem> items, {
    required String action,
    bool persistChanges = false,
  }) async {
    if (metadataProviders.isEmpty || items.isEmpty) return items;
    final expectedCacheIdentity = await _cacheIdentityForCurrentCall();
    if (items.first.kind != ContentKind.season &&
        items.first.kind != ContentKind.episode) {
      return items;
    }
    final enrichedParent = (await _mergeCachedMetadata([parent])).first;
    final cachedByProvider = <String, Map<String, ExternalMetadata>>{};
    for (final provider in metadataProviders) {
      cachedByProvider[provider.provider] = await db
          .readExternalMetadataForItems(source.id, items, provider.provider);
    }
    final out = [...items];
    final changed = <MediaItem>[];
    var nextIndex = 0;
    Future<void> worker() async {
      while (nextIndex < items.length) {
        final index = nextIndex++;
        final result = await _applyOneChildExternalMetadata(
          enrichedParent,
          items[index],
          action,
          cachedByProvider,
        );
        out[index] = result.item;
        if (result.changed) changed.add(result.item);
      }
    }

    final workerCount = items.length < _enrichConcurrency
        ? items.length
        : _enrichConcurrency;
    await Future.wait(List.generate(workerCount, (_) => worker()));
    if (persistChanges) {
      await db.updateMediaDisplayFields(
        source.id,
        changed,
        expectedCacheIdentity: expectedCacheIdentity,
      );
    }
    await _ensureCacheIdentityCurrent(expectedCacheIdentity);
    return out;
  }

  Future<({MediaItem item, bool changed})> _applyOneChildExternalMetadata(
    MediaItem parent,
    MediaItem item,
    String action,
    Map<String, Map<String, ExternalMetadata>> cachedByProvider,
  ) async {
    if (item.kind != ContentKind.season && item.kind != ContentKind.episode) {
      return (item: item, changed: false);
    }
    var out = item;
    var changed = false;
    var visualMatched = false;
    for (final provider in metadataProviders) {
      if (provider.ratingsOnly && !visualMatched) continue;
      if (provider.provider == 'tvmaze' && visualMatched) continue;
      final cached = cachedByProvider[provider.provider]?[out.id];
      if (cached != null) {
        _logMetadata(
          '$action cache hit ${provider.provider} ${out.kind.name}:${out.id} -> ${cached.providerKey}',
        );
        out = _mergeMetadata(out, cached, ratingsOnly: provider.ratingsOnly);
        if (!provider.ratingsOnly) visualMatched = true;
        continue;
      }
      try {
        final metadata = out.kind == ContentKind.season
            ? await provider.seasonMetadata(parent, out)
            : await provider.episodeMetadata(parent, out);
        if (metadata == null) {
          _logMetadata(
            '$action no match ${provider.provider} ${out.kind.name}:${out.id} title=${out.title}',
          );
          continue;
        }
        await cacheExternalMetadata(out, metadata);
        changed = true;
        _logMetadata(
          '$action matched ${provider.provider} ${out.kind.name}:${out.id} -> ${metadata.providerKey}',
        );
        out = _mergeMetadata(out, metadata, ratingsOnly: provider.ratingsOnly);
        if (!provider.ratingsOnly) visualMatched = true;
      } catch (error) {
        _logMetadata(
          '$action error ${provider.provider} ${out.kind.name}:${out.id}: $error',
        );
      }
    }
    return (item: out, changed: changed);
  }

  bool _supportsMetadata(MediaItem item) =>
      metadataProviders.isNotEmpty &&
      (item.kind == ContentKind.movie ||
          item.kind == ContentKind.season ||
          item.kind == ContentKind.series ||
          item.kind == ContentKind.episode);

  bool _shouldLookupMetadata(MediaItem item) {
    if (!_supportsMetadata(item)) return false;
    if (item.kind != ContentKind.episode) return true;
    return _hasExternalMetadataId(item);
  }

  bool _hasExternalMetadataId(MediaItem item) {
    final providerId = item.providerId;
    if (providerId != null && providerId.trim().isNotEmpty) return true;
    for (final key in const [
      'tmdb_id',
      'tmdbId',
      'tvdb_id',
      'tvdbId',
      'imdb_id',
      'imdbId',
    ]) {
      final value = item.extra[key]?.toString().trim();
      if (value != null && value.isNotEmpty && value != 'null') return true;
    }
    return false;
  }

  Future<MediaItem> _applyExternalMetadata(
    MediaItem item, {
    required String action,
    bool includeDetails = false,
  }) async {
    if (!_shouldLookupMetadata(item)) {
      if (_supportsMetadata(item)) {
        _logMetadata(
          '$action skipped ${item.kind.name}:${item.id} title=${item.title}',
        );
      }
      return item;
    }
    var out = item;
    var visualMatched = false;
    for (final provider in metadataProviders) {
      if (provider.ratingsOnly && !visualMatched) continue;
      if (provider.provider == 'tvmaze' && visualMatched) continue;
      final cached = await cachedExternalMetadata(out, provider.provider);
      if (cached != null) {
        _logMetadata(
          '$action cache hit ${provider.provider} ${out.kind.name}:${out.id} -> ${cached.providerKey}',
        );
        out = _mergeMetadata(out, cached, ratingsOnly: provider.ratingsOnly);
        if (!provider.ratingsOnly) visualMatched = true;
        // Older entries can contain only a search row. Upgrade those when
        // opening details, retaining the cached display data if it fails.
        final needsDetails =
            includeDetails &&
            (out.kind == ContentKind.movie || out.kind == ContentKind.series) &&
            ((provider.provider == 'tmdb' && cached.payload['credits'] is! Map) ||
                (provider.provider == 'tvdb' &&
                    out.kind == ContentKind.movie &&
                    cached.payload['details_loaded'] != true));
        if (!needsDetails) continue;
      }
      try {
        final metadata = await provider.search(out);
        if (metadata == null) {
          _logMetadata(
            '$action no match ${provider.provider} ${out.kind.name}:${out.id} title=${out.title}',
          );
          continue;
        }
        await cacheExternalMetadata(out, metadata);
        _logMetadata(
          '$action matched ${provider.provider} ${out.kind.name}:${out.id} -> ${metadata.providerKey}',
        );
        out = _mergeMetadata(out, metadata, ratingsOnly: provider.ratingsOnly);
        if (!provider.ratingsOnly) visualMatched = true;
      } catch (error) {
        _logMetadata(
          '$action error ${provider.provider} ${out.kind.name}:${out.id}: $error',
        );
      }
    }
    return out;
  }

  MediaItem _mergeMetadata(
    MediaItem item,
    ExternalMetadata metadata, {
    bool ratingsOnly = false,
  }) {
    final existingMetadata = item.extra['metadata'];
    if (metadata.provider == 'tvmaze' &&
        existingMetadata is Map &&
        metadataProviders.any(
          (provider) => !provider.ratingsOnly &&
              provider.provider != 'tvmaze' &&
              existingMetadata[provider.provider] is Map,
        )) {
      return item;
    }
    final providerTitle =
        item.extra['providerTitle'] ??
        item.extra['sourceTitle'] ??
        item.extra['name'] ??
        item.extra['title'] ??
        item.title;
    return item.copyWith(
      title: ratingsOnly || metadata.title == null || metadata.title!.isEmpty
          ? null
          : metadata.title,
      poster: ratingsOnly ? item.poster : metadata.poster ?? item.poster,
      backdrop: ratingsOnly
          ? item.backdrop
          : metadata.backdrop ?? item.backdrop,
      description:
          ratingsOnly || metadata.overview == null || metadata.overview!.isEmpty
          ? item.description
          : metadata.overview,
      year: ratingsOnly ? item.year : metadata.year ?? item.year,
      rating: metadata.rating ?? item.rating,
      providerId: ratingsOnly ||
              metadata.provider == 'tvmaze' ||
              metadata.providerKey.isEmpty
          ? item.providerId
          : metadata.providerKey,
      extra: {
        ...item.extra,
        'providerTitle': providerTitle,
        'metadata': {
          if (existingMetadata is Map) ...existingMetadata,
          metadata.provider: metadata.payload,
        },
      },
    );
  }

  void _logMetadata(String message) {
    DiagnosticsLog.instance.add('metadata', message);
    developer.log(message, name: 'iptvs.metadata');
    debugPrint('[iptvs.metadata] $message');
  }

  Future<ExternalMetadata?> cachedExternalMetadata(
    MediaItem item,
    String provider,
  ) async {
    await _cacheIdentityForCurrentCall();
    return db.readExternalMetadata(source.id, item, provider);
  }

  Future<void> cacheExternalMetadata(
    MediaItem item,
    ExternalMetadata metadata,
  ) async {
    final expectedCacheIdentity = await _cacheIdentityForCurrentCall();
    await db.cacheExternalMetadata(
      source.id,
      item,
      metadata,
      expectedCacheIdentity: expectedCacheIdentity,
    );
  }

  Future<ExternalMetadata?> refreshExternalMetadata(MediaItem item) async {
    if (!_shouldLookupMetadata(item)) return null;
    final expectedCacheIdentity = await _cacheIdentityForCurrentCall();
    var merged = item;
    ExternalMetadata? refreshed;
    Object? firstError;
    StackTrace? firstStackTrace;
    for (final provider in metadataProviders) {
      if (provider.ratingsOnly && refreshed == null) continue;
      if (!provider.ratingsOnly && refreshed != null) continue;
      try {
        final cached = await cachedExternalMetadata(merged, provider.provider);
        if (cached != null) {
          merged = _mergeMetadata(
            merged,
            cached,
            ratingsOnly: provider.ratingsOnly,
          );
        }
        // An explicit refresh always queries the provider. Keep the existing
        // cache until a replacement succeeds, including on a missing match.
        final metadata = await provider.search(merged);
        if (metadata == null) {
          _logMetadata(
            'refresh no match ${provider.provider} ${item.kind.name}:${item.id}',
          );
          continue;
        }
        await cacheExternalMetadata(merged, metadata);
        merged = _mergeMetadata(
          merged,
          metadata,
          ratingsOnly: provider.ratingsOnly,
        );
        if (!provider.ratingsOnly) refreshed = metadata;
        _logMetadata(
          'refresh matched ${provider.provider} ${item.kind.name}:${item.id} -> ${metadata.providerKey}',
        );
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
        _logMetadata(
          'refresh error ${provider.provider} ${item.kind.name}:${item.id}: $error',
        );
      }
    }
    if (refreshed == null) {
      if (firstError != null) {
        Error.throwWithStackTrace(firstError, firstStackTrace!);
      }
      return null;
    }
    await db.updateMediaDisplayFields(
      source.id,
      [merged],
      expectedCacheIdentity: expectedCacheIdentity,
    );
    return refreshed;
  }

  MediaItem mergeExternalMetadata(MediaItem item, ExternalMetadata metadata) =>
      _mergeMetadata(item, metadata);

  /// Max metadata lookups in flight during root and child enrichment.
  ///
  /// Each lookup is 1-2 sequential HTTP round trips (a search call, plus a
  /// cache-miss write), so a plain serial loop over `_autoEnrichLimit` (40,
  /// see `media_tab_controller.dart`) items at a realistic ~250ms provider
  /// RTT took 15-20s before posters appeared. A fixed worker pool pulling
  /// from a shared queue keeps concurrency bounded and cheap (the
  /// `HttpClient`s are already reused per metadata-client instance, so
  /// connections are pooled) without ever `Future.wait`-ing the whole list —
  /// that would open thousands of sockets on a 250k-item catalog and get the
  /// user rate-limited or banned by the provider.
  ///
  /// This is a single constant rather than per-provider because
  /// [metadataProviders] can mix a visual provider (TMDB/TVDB) with a
  /// `ratingsOnly` one (MDBList, which rate-limits harder); per-provider caps
  /// would mean threading a limit through `MetadataProvider` itself, which
  /// ripples well beyond this method. A shared, conservative cap keeps the
  /// stricter provider safe at the cost of some possible headroom on the
  /// looser one.
  static const _enrichConcurrency = 4;

  Future<List<MediaItem>> enrichMediaMetadata(
    List<MediaItem> items, {
    int? limit,
  }) async {
    if (metadataProviders.isEmpty ||
        items.isEmpty ||
        (limit != null && limit <= 0)) {
      // Say so rather than returning in silence. A catalog refresh *deletes*
      // and re-inserts `media_items` (`replaceMediaLibrary`), so the enriched
      // poster/backdrop/title are gone until this method re-merges them from
      // the `external_metadata` cache. When it no-ops, every tile falls back to
      // the placeholder with no network request and therefore no error to log
      // anywhere — the artwork simply never appears and the session looks
      // healthy. That is the shape of a real report that took a full
      // investigation to place.
      if (metadataProviders.isEmpty && items.isNotEmpty) {
        _logMetadata(
          'enrich skipped: no metadata providers configured (items=${items.length})',
        );
      }
      return items;
    }
    final expectedCacheIdentity = await _cacheIdentityForCurrentCall();
    final out = [...items];
    final targets = <int>[];
    for (var i = 0; i < out.length; i++) {
      if (limit != null && targets.length >= limit) break;
      final item = out[i];
      if (item.kind != ContentKind.movie &&
          item.kind != ContentKind.series &&
          item.kind != ContentKind.episode) {
        continue;
      }
      targets.add(i);
    }
    var nextTarget = 0;
    Future<void> worker() async {
      while (nextTarget < targets.length) {
        final index = targets[nextTarget++];
        try {
          out[index] = await _applyExternalMetadata(
            out[index],
            action: 'prefetch',
          );
        } catch (error) {
          // _applyExternalMetadata already swallows per-provider (network)
          // failures internally; this is a defensive backstop (e.g. a local
          // cache read/write error) so one item's failure can't strand the
          // rest of the pool or leave enrichMediaMetadata hanging.
          _logMetadata(
            'prefetch error ${out[index].kind.name}:${out[index].id}: $error',
          );
        }
      }
    }

    final workerCount = targets.length < _enrichConcurrency
        ? targets.length
        : _enrichConcurrency;
    await Future.wait(List.generate(workerCount, (_) => worker()));
    // A prefetch normally enriches only the visible 40 items. Rewriting `out`
    // here also updated every untouched row in a large catalogue, turning one
    // poster refresh into thousands of JSON conversions and SQLite writes.
    await db.updateMediaDisplayFields(source.id, [
      for (final index in targets)
        if (!identical(out[index], items[index])) out[index],
    ], expectedCacheIdentity: expectedCacheIdentity);
    await _ensureCacheIdentityCurrent(expectedCacheIdentity);
    // Bounded outcome summary. Per-item lines already exist, but they don't
    // answer the question that matters when a user reports "no artwork":
    // whether enrichment ran and still produced nothing. A pass that targets
    // items and returns almost none with a poster is the signature of that
    // failure, and it is invisible from the individual lines.
    final withPoster = targets
        .where((index) => (out[index].poster ?? '').isNotEmpty)
        .length;
    _logMetadata(
      'enrich done targets=${targets.length} with_poster=$withPoster',
    );
    return out;
  }

  Future<List<MediaItem>> searchMedia(
    ContentKind kind,
    String query, {
    String? categoryId,
  }) async {
    if (query.trim().isEmpty) return const [];
    if (await db.lastCatalogSynced(source.id, kind) == null) {
      await synchronizeMediaCatalog(kind);
    }
    return _mergeCachedMetadata(
      await db.searchMediaItems(source.id, kind, query, categoryId: categoryId),
    );
  }

  /// Reveal point — see [resolve].
  Future<StreamInfo> resolveMedia(MediaItem item) async {
    await source.connect();
    return source.resolveMedia(await db.revealMediaItem(item));
  }
}
