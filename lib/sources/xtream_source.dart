import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute, visibleForTesting;

import '../data/load_token.dart';
import '../data/diagnostics_log.dart';
import '../data/net.dart';
import 'epg_guides.dart';
import 'epg_matching.dart';
import 'epg_mapping.dart';
import '../data/epg_download_cache.dart';
import 'expiry.dart';
import 'source.dart';
import 'source_identity.dart';

/// Container extensions an Xtream panel can be asked for on the live and
/// timeshift endpoints. Most panels serve both.
const kXtreamStreamExtensions = <String>{'ts', 'm3u8'};

/// Which container extension [XtreamSource] asks the panel for.
///
/// **`m3u8` on iOS, `ts` everywhere else — a per-platform default, not a
/// feature.** `AVPlayer` cannot play a naked continuous MPEG-TS stream (TS
/// segments *inside* an HLS playlist are fine), so on iOS a `.ts` locator routes
/// straight to the libmpv fallback, which is permanently tone-mapped SDR with no
/// PiP and no AirPlay (docs/ios.md "Known parity gaps"). Since the extension is
/// something this source *chooses* rather than something the provider dictates,
/// preferring `m3u8` there is what decides whether AVPlayer is the common path
/// or a rare one — see docs/ios.md "The `streamExtension` lever".
///
/// This deliberately does **not** help Stalker, whose `create_link` returns
/// whatever the portal chooses and is typically extension-less (and therefore
/// routes to mpv by `selectIosEngine` rule 4), nor M3U playlists that name `.ts`
/// directly.
///
/// [override] is the per-source escape hatch (`SourceConfig.settings`
/// `streamExtension`). It exists because the failure mode of a wrong default is
/// not graceful: a panel that does *not* serve `m3u8` answers 404, AVPlayer
/// reports `engineFailed`, and Dart's fallback reopens the **same** 404 URL on
/// mpv — so the channel is dead rather than merely SDR. Anything not in
/// [kXtreamStreamExtensions] falls back to the platform default rather than
/// being passed through to the URL builder.
///
/// Pure and platform-injected so `flutter test` can assert both branches from a
/// desktop VM.
String resolveXtreamStreamExtension(String? override, {required bool isIOS}) {
  final value = override?.trim().toLowerCase() ?? '';
  if (kXtreamStreamExtensions.contains(value)) return value;
  return isIOS ? 'm3u8' : 'ts';
}

/// A [Source] backed by an Xtream Codes panel (host + username + password).
///
/// Implements live TV; VOD and series can be layered on the same interface
/// later. Stream URLs follow `/live/USER/PASS/STREAM_ID.ext`.
class XtreamSource
    implements
        Source,
        BatchedEpgSource,
        MappedEpgSource,
        CatchupSource,
        SourceCapabilityReporter,
        ProviderStreamSource,
        FullMediaCatalogSource,
        RefreshableSource {
  final String sourceId;
  final String host; // e.g. http://host:port
  final String username;
  final String password;
  final int? maximumStreams;

  /// `'ts'` (most compatible) or `'m3u8'`. Resolved once at construction by
  /// [resolveXtreamStreamExtension] — see there for the iOS default and the
  /// per-source override.
  final String streamExtension;

  /// Expiry carried by an M3U/get.php URL before it was converted to an
  /// Xtream source. Some panels expose it in the playlist URL but omit it
  /// from `player_api.php`.
  final String? playlistExpiryHint;

  /// Extra XMLTV guides layered *under* the panel's own `xmltv.php`, in
  /// priority order. See [mergeEpgGuides]: a channel is served by the first
  /// guide that carries it, never by two at once.
  final List<String> extraEpgUrls;
  @override
  final epgMapping = EpgMappingSession();

  /// Advanced per-source catch-up overrides. When omitted, Xtream panels are
  /// treated as using the device wall clock.
  final String? catchupTimezone;
  final int? catchupOffsetMinutes;
  final int? catchupMaxDays;
  @visibleForTesting
  final Future<dynamic> Function(Map<String, String> params)? debugApi;
  @visibleForTesting
  final DateTime Function()? debugNow;

  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..autoUncompress = false;
  final _shortEpgCache = <String, ({DateTime at, List<Programme> programmes})>{};
  DateTime? _windowXmltvRetryAt, _shortEpgRetryAt, _nextShortEpgAt;
  Object? _shortEpgError;
  Future<void> _shortEpgTail = Future.value();
  bool _epgDisposed = false;
  final Map<String, Future<List<MediaItem>>> _mediaListCache = {};
  final Map<ContentKind, Future<List<MediaCategory>>> _mediaCategoriesCache =
      {};
  final Map<String, int> _mediaListSizes = {};
  final Map<String, int> _mediaCategorySizes = {};
  final Map<ContentKind, String> _pagedCategoryKeys = {};
  int _cachedMediaItems = 0;
  final Map<ContentKind, int> _searchGenerations = {};
  String? _providerCatchupTimezone;
  Future<void>? _connectFuture;
  DateTime? _connectedAt;
  int _reportedMaximumStreams = 1;
  int? _reportedActiveStreams;
  DateTime? _accountCheckedAt;
  final Map<String, Future<dynamic>> _apiReads = {};

  static const _authenticationMaxAge = Duration(hours: 24);

  // Stalker portals usually return compact provider pages, often around
  // 14 rows. Xtream's common API does not expose equivalent paging, so keep
  // the app-facing page small and let category filters/search carry discovery.
  static const _mediaPageSize = 14;
  static const _searchResultLimit = 120;
  static const _maximumCachedMediaItems = 5000;
  static const _maximumCachedMediaCategories = 32;

  XtreamSource({
    required this.sourceId,
    required this.host,
    required this.username,
    required this.password,
    this.maximumStreams,
    String? streamExtension,
    this.playlistExpiryHint,
    this.extraEpgUrls = const [],
    this.catchupTimezone,
    this.catchupOffsetMinutes,
    this.catchupMaxDays,
    this.debugApi,
    this.debugNow,
    this.displayName,
  }) : streamExtension = resolveXtreamStreamExtension(
         streamExtension,
         isIOS: Platform.isIOS,
       );

  /// User-assigned label (from SourceConfig); preferred over the derived name.
  final String? displayName;

  String get _base {
    var h = host.trim();
    if (!h.startsWith('http://') && !h.startsWith('https://')) h = 'http://$h';
    if (h.endsWith('/')) h = h.substring(0, h.length - 1);
    return h;
  }

  @override
  String get id => sourceId;

  @override
  ProviderStreamAccount get streamAccount {
    var maximum = _reportedMaximumStreams;
    final configured = maximumStreams;
    if (configured != null &&
        configured > 0 &&
        (maximum == 0 || configured < maximum)) {
      maximum = configured;
    }
    return ProviderStreamAccount(
      id: providerStreamAccountId(
        _base,
        username: username,
        password: password,
      ),
      maximumStreams: maximum,
      reportedActiveStreams: _reportedActiveStreams,
      checkedAt: _accountCheckedAt,
    );
  }

  @override
  String get name => displayName?.trim().isNotEmpty == true
      ? displayName!.trim()
      : 'Xtream · ${Uri.tryParse(_base)?.host ?? 'panel'}';

  @override
  CatchupCapability get catchupCapability => CatchupCapability(
    mode: CatchupUrlMode.xtreamTimeshift,
    timezone: catchupTimezone ?? _providerCatchupTimezone,
    fixedOffsetMinutes: catchupOffsetMinutes,
    maxArchiveWindow: catchupMaxDays == null
        ? null
        : Duration(days: catchupMaxDays!),
    startFormat: 'yyyy-MM-dd:HH-mm',
  );

  @override
  SourceCapabilities get sourceCapabilities => const SourceCapabilities(
    epg: CapabilityAvailability.supported,
    catchup: CapabilityAvailability.supported,
    resolution: ResolutionCapability.providerDefined,
  );

  /// Coalesces setup's concurrent catalog checks and revalidates after a day.
  @override
  Future<void> connect() async {
    final pending = _connectFuture;
    if (pending != null) return pending;
    final connectedAt = _connectedAt;
    if (connectedAt != null) {
      final age = (debugNow?.call() ?? DateTime.now()).difference(connectedAt);
      if (!age.isNegative && age < _authenticationMaxAge) return;
    }
    final future = _authenticate();
    _connectFuture = future;
    try {
      await future;
    } finally {
      _connectFuture = null;
    }
  }

  Future<void> _authenticate() async {
    final info = await _api({});
    final user = info is Map ? info['user_info'] : null;
    if (user is! Map) {
      throw const FormatException('Invalid Xtream account response');
    }
    if (!_hasPositiveAuthentication(user)) {
      throw const FormatException('Invalid Xtream authentication response');
    }
    final status = '${user['status'] ?? ''}'.trim().toLowerCase();
    final expiry = parseSubscriptionExpiryValue(user['exp_date']).date;
    final now = debugNow?.call() ?? DateTime.now();
    if (const {'expired', 'disabled', 'banned'}.contains(status) ||
        (expiry != null && !expiry.isAfter(now))) {
      await _rejectAuthentication();
    }
    _readStreamAccount(user, now);
    final server = info is Map ? info['server_info'] : null;
    final reported = server is Map
        ? server['timezone']?.toString().trim()
        : null;
    if (reported != null &&
        reported.isNotEmpty &&
        isSupportedCatchupTimezone(reported)) {
      _providerCatchupTimezone = reported;
    }
    _connectedAt = now;
  }

  bool _hasPositiveAuthentication(Map user) {
    final auth = '${user['auth'] ?? ''}'.trim().toLowerCase();
    return user['auth'] == true ||
        user['auth'] == 1 ||
        auth == '1' ||
        auth == 'true';
  }

  void _readStreamAccount(Map user, DateTime now) {
    final maximum = _parseInt(user['max_connections']);
    final active = _parseInt(user['active_cons']);
    _reportedMaximumStreams = maximum != null && maximum >= 0 ? maximum : 1;
    _reportedActiveStreams = active != null && active >= 0 ? active : null;
    _accountCheckedAt = now;
  }

  @override
  Future<List<Category>> categories() async {
    final r = await _api({'action': 'get_live_categories'});
    if (r is! List) return const [];
    return r
        .whereType<Map>()
        .map(
          (c) => Category(
            id: '${c['category_id']}',
            title: '${c['category_name']}',
          ),
        )
        .toList();
  }

  @override
  Future<List<Channel>> channels({String? categoryId}) async {
    final params = {'action': 'get_live_streams'};
    if (categoryId != null) params['category_id'] = categoryId;
    Object? raw;
    try {
      raw = await _fetchCatalogRaw(params);
    } on HttpWorkloadException catch (error) {
      if (categoryId != null || !error.isSizeLimit) rethrow;
      return _channelsPartitionedByCategory();
    }
    return _channelsFromRaw(raw);
  }

  /// Xtream's common API has no formal pagination for live streams, but most
  /// panels honor category_id. If the monolithic catalog crosses the bounded
  /// response limit, partition it by category and merge stable stream IDs.
  Future<List<Channel>> _channelsPartitionedByCategory() async {
    final available = await categories();
    if (available.isEmpty) {
      throw const HttpWorkloadException(
        'Xtream live catalog is too large and exposes no categories',
        isSizeLimit: true,
      );
    }
    final out = <Channel>[];
    final seen = <String>{};
    for (final category in available) {
      final raw = await _fetchCatalogRaw({
        'action': 'get_live_streams',
        'category_id': category.id,
      });
      for (final channel in await _channelsFromRaw(raw)) {
        if (seen.add(channel.id)) out.add(channel);
      }
    }
    return out;
  }

  @override
  Future<StreamInfo> resolve(Channel channel) async {
    final streamId = channel.extra['streamId']?.toString() ?? channel.id;
    return StreamInfo(
      url: '$_base/live/$_credentialPath/${Uri.encodeComponent(streamId)}.$streamExtension',
      providerAccount: streamAccount,
    );
  }

  @override
  Future<StreamInfo> resolveArchive(
    Channel channel,
    Programme programme,
  ) async {
    final streamId = channel.extra['streamId']?.toString() ?? channel.id;
    final duration = programme.stop.difference(programme.start).inMinutes;
    return StreamInfo(
      url:
          '$_base/timeshift/$_credentialPath/$duration/'
          '${_timeshiftStart(programme.start, catchupCapability)}/${Uri.encodeComponent(streamId)}.$streamExtension',
      isLive: false,
      providerAccount: streamAccount,
    );
  }

  /// Xtream timeshift start stamp `Y-m-d:H-i`. XMLTV times are absolute, but the
  /// endpoint expects the panel's local time; we use the device's local zone
  /// (device ≈ panel region in practice). A per-source offset is the future
  /// refinement if a panel sits in a different zone.
  @visibleForTesting
  static String timeshiftStart(
    DateTime start, [
    CatchupCapability? capability,
  ]) => _timeshiftStart(
    start,
    capability ?? const CatchupCapability(mode: CatchupUrlMode.xtreamTimeshift),
  );

  static String _timeshiftStart(DateTime start, CatchupCapability capability) =>
      formatCatchupTime(start, capability);

  /// Unbatched fallback, kept for [Source]'s contract. Drains the same merged
  /// feed [epgBatched] builds, so the two can't diverge.
  @override
  Future<List<Programme>> epg(List<Channel> channels) async {
    final feeds = _guideFeeds(channels, null);
    if (feeds.isEmpty) return const [];
    final out = <Programme>[];
    await for (final batch in mergeEpgGuides(feeds)) {
      out.addAll(batch);
    }
    return out;
  }

  /// A small visible window may use the provider's per-channel guide when its
  /// bulk XMLTV endpoint is unavailable. Never fan out a full library refresh.
  Future<List<Programme>> epgForWindow(List<Channel> channels) async {
    final now = debugNow?.call() ?? DateTime.now();
    if (channels.length > 12 || extraEpgUrls.isNotEmpty ||
        epgMapping.requiresGuide(epgGuideId(id, _xmltvUri.toString()))) {
      return epg(channels);
    }
    if (_windowXmltvRetryAt == null || !now.isBefore(_windowXmltvRetryAt!)) {
      try {
        final programmes = await epg(channels);
        _windowXmltvRetryAt = null;
        return programmes;
      } catch (error) {
        final unavailable = error is StateError &&
            RegExp(r'^HTTP (404|405|500|502|503|504)\b').hasMatch(error.message.toString());
        final oversized = error is HttpWorkloadException && error.isSizeLimit;
        if (!unavailable && !oversized) rethrow;
        _windowXmltvRetryAt = now.add(const Duration(minutes: 15));
      }
    }
    final operation = _shortEpgTail.then((_) => _shortEpg(channels));
    _shortEpgTail = operation.then<void>((_) {}, onError: (Object _) {});
    return operation;
  }

  Future<List<Programme>> _shortEpg(List<Channel> channels) async {
    final programmes = <Programme>[];
    for (final channel in {for (final channel in channels) channel.id: channel}.values) {
      if (_epgDisposed) throw const LoadCancelledException();
      final now = debugNow?.call() ?? DateTime.now();
      final cached = _shortEpgCache[channel.id];
      if (cached != null && !now.isBefore(cached.at) &&
          now.difference(cached.at) < const Duration(minutes: 10)) {
        programmes.addAll(cached.programmes);
        continue;
      }
      if (_shortEpgRetryAt != null && now.isBefore(_shortEpgRetryAt!)) {
        throw _shortEpgError!;
      }
      final delay = _nextShortEpgAt?.difference(DateTime.now()) ?? Duration.zero;
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      if (_epgDisposed) throw const LoadCancelledException();
      try {
        final response = await _api({'action': 'get_short_epg', 'stream_id': channel.id, 'limit': '12'});
        if (_epgDisposed) throw const LoadCancelledException();
        // Shared provider admission can delay the physical request. Start the
        // quiet period after its response so that queueing cannot consume it.
        _nextShortEpgAt = DateTime.now().add(const Duration(seconds: 1));
        if (response is! Map || response['epg_listings'] is! List) {
          throw const FormatException('Invalid per-channel EPG response');
        }
        String decode(Object? value) {
          final text = value?.toString() ?? '';
          try { return utf8.decode(base64Decode(text)); } catch (_) { return text; }
        }
        final rows = <Programme>[];
        for (final row in (response['epg_listings'] as List).take(12).whereType<Map>()) {
          final start = _parseInt(row['start_timestamp']), stop = _parseInt(row['stop_timestamp']);
          if (start == null || stop == null || stop <= start) continue;
          rows.add(Programme(channelId: channel.id,
            start: DateTime.fromMillisecondsSinceEpoch(start * 1000, isUtc: true),
            stop: DateTime.fromMillisecondsSinceEpoch(stop * 1000, isUtc: true),
            title: decode(row['title']), description: decode(row['description'])));
        }
        _shortEpgCache.remove(channel.id);
        while (_shortEpgCache.length >= 96) {
          _shortEpgCache.remove(_shortEpgCache.keys.first);
        }
        _shortEpgCache[channel.id] = (at: debugNow?.call() ?? DateTime.now(), programmes: rows);
        programmes.addAll(rows);
      } catch (error) {
        if (error is LoadCancelledException ||
            providerHttpRefusalStatus(error) == HttpStatus.forbidden) {
          rethrow;
        }
        _shortEpgError = error;
        _shortEpgRetryAt = (debugNow?.call() ?? DateTime.now()).add(const Duration(minutes: 15));
        rethrow;
      }
    }
    return programmes;
  }

  @override
  Stream<List<Programme>>? epgBatched(
    List<Channel> channels, {
    LoadToken? token,
  }) {
    final feeds = _guideFeeds(channels, token);
    return feeds.isEmpty ? null : mergeEpgGuides(feeds, token: token);
  }

  /// The panel's own `xmltv.php` first, then any [extraEpgUrls] the user added
  /// — a panel guide that covers only part of the catalog is the usual reason
  /// to add one.
  List<EpgGuideFeed> _guideFeeds(List<Channel> channels, LoadToken? token) {
    if (channels.isEmpty) return const [];
    final urls = <String>{
      _xmltvUri.toString(),
      for (final url in extraEpgUrls)
        if (url.isNotEmpty) url,
    }.toList();
    epgMapping.validateGuides(
      urls.take(kMaxEpgGuides).map((url) => epgGuideId(id, url)),
    );
    final tvgIds = buildTvgIdIndex(channels);
    final names = epgNameIndexFor(channels, extraCount: urls.length - 1);
    return [
      for (var i = 0; i < urls.length && i < kMaxEpgGuides; i++)
        xmltvGuideFeed(
          url: urls[i],
          cachedDownload: (uri, file) =>
              _downloadToFile(uri, file, token: token),
          tvgIdToChannelIds: tvgIds,
          // The panel's own guide keeps exact `tvg-id` matching only — see
          // [epgNameIndexFor].
          nameToChannelIds: i == 0 ? const {} : names,
          token: token,
          guideId: epgGuideId(id, urls[i]),
          guideLabel: i == 0 ? 'Provider guide' : 'XMLTV guide ${i + 1}',
          mapping: epgMapping,
        ),
    ];
  }

  String get _credentialPath =>
      '${Uri.encodeComponent(username)}/${Uri.encodeComponent(password)}';

  Uri get _xmltvUri => Uri.parse('$_base/xmltv.php').replace(
    queryParameters: {'username': username, 'password': password},
  );

  @override
  Future<List<MediaCategory>> mediaCategories(ContentKind kind) {
    final action = switch (kind) {
      ContentKind.movie => 'get_vod_categories',
      ContentKind.series => 'get_series_categories',
      _ => null,
    };
    if (action == null) return Future.value(const []);
    final cached = _mediaCategoriesCache[kind];
    if (cached != null) return cached;
    final pending = _fetchMediaCategories(kind, action);
    _mediaCategoriesCache[kind] = pending;
    unawaited(
      pending.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {
          if (identical(_mediaCategoriesCache[kind], pending)) {
            _mediaCategoriesCache.remove(kind);
          }
        },
      ),
    );
    return pending;
  }

  Future<List<MediaCategory>> _fetchMediaCategories(
    ContentKind kind,
    String action,
  ) async {
    final r = await _api({'action': action});
    return _listFromAny(r)
        .map((c) {
          final m = Map<String, dynamic>.from(c);
          return MediaCategory(
            id: _firstString(m, ['category_id', 'id']) ?? '',
            title: _firstString(m, ['category_name', 'name', 'title']) ?? '',
            kind: kind,
          );
        })
        .where((c) => c.id.isNotEmpty && c.title.isNotEmpty)
        .toList();
  }

  @override
  Future<List<MediaItem>> allMediaItems(
    ContentKind kind, {
    LoadToken? token,
  }) async {
    if (kind != ContentKind.movie && kind != ContentKind.series) {
      return const [];
    }
    if (token?.isCancelled == true) throw const LoadCancelledException();
    final action = kind == ContentKind.movie ? 'get_vod_streams' : 'get_series';
    try {
      // A full sync needs one list, not one request per category. Decode with
      // the existing bounded worker and let SQLite own the complete catalog;
      // retaining it in the category LRU would duplicate a large TV library.
      final raw = await _fetchCatalogRaw({'action': action}, token: token);
      if (raw is Uint8List
          ? raw.firstWhere((byte) => byte > 32, orElse: () => 0) != 91
          : raw is! List) {
        throw const FormatException('Invalid full media catalog');
      }
      final items = await _mediaItemsFromRaw(raw, kind);
      if (token?.isCancelled == true) throw const LoadCancelledException();
      final seen = <String>{};
      return [
        for (final item in items)
          if (item.id.isNotEmpty && seen.add(item.id)) item,
      ];
    } catch (error) {
      if (token?.isCancelled == true) throw const LoadCancelledException();
      // Only unsupported bulk endpoints or bounded payloads justify splitting
      // the request. Refusals, timeouts and server failures must not fan out
      // into requests for every category.
      final unsupported =
          error is StateError &&
          RegExp(r'\bHTTP (400|404|405|501)\b')
              .hasMatch(error.message.toString());
      final oversized =
          error is HttpWorkloadException && error.isSizeLimit;
      if (!unsupported && !oversized) rethrow;
    }
    final categories = await mediaCategories(kind);
    if (categories.isEmpty) {
      throw StateError('Provider bulk catalog unavailable and no categories');
    }
    final items = <MediaItem>[];
    final seenIds = <String>{};
    final seenCategories = <String>{};
    final categoryIds = categories.map((category) => category.id);
    for (final categoryId in categoryIds) {
      if (token?.isCancelled == true) throw const LoadCancelledException();
      if (!seenCategories.add(categoryId)) continue;
      final categoryItems = await _fetchMediaList(kind, categoryId: categoryId);
      for (final item in categoryItems) {
        if (item.id.isNotEmpty && seenIds.add(item.id)) items.add(item);
      }
    }
    if (token?.isCancelled == true) throw const LoadCancelledException();
    return items;
  }

  @override
  Future<List<MediaItem>> mediaItems(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    int? maxPages,
  }) async {
    if (kind == ContentKind.season && parent != null) {
      return _seriesSeasons(parent);
    }
    if (kind == ContentKind.episode && parent != null) {
      return _seasonEpisodes(parent);
    }
    final pagesToLoad = maxPages ?? 1;
    final out = <MediaItem>[];
    for (var page = 1; page <= pagesToLoad; page++) {
      final fetched = await mediaItemsPage(
        kind,
        categoryId: categoryId,
        parent: parent,
        page: page,
      );
      out.addAll(fetched.items);
      if (!fetched.hasMore) break;
    }
    return out;
  }

  @override
  Future<MediaPage> mediaItemsPage(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    int page = 1,
  }) async {
    if (kind == ContentKind.season && parent != null) {
      return MediaPage(
        items: await _seriesSeasons(parent),
        page: page,
        totalPages: page,
      );
    }
    if (kind == ContentKind.episode && parent != null) {
      return MediaPage(
        items: _seasonEpisodes(parent),
        page: page,
        totalPages: page,
      );
    }
    if (kind != ContentKind.movie && kind != ContentKind.series) {
      return MediaPage(items: const [], page: page, totalPages: page);
    }
    if (categoryId == null) {
      return _aggregateMediaPage(kind, page: page);
    }
    _pagedCategoryKeys[kind] = _mediaListKey(kind, categoryId);
    final items = await _fetchMediaList(kind, categoryId: categoryId);
    return _sliceMediaPage(items, page: page);
  }

  @override
  Future<List<MediaItem>> searchMedia(
    ContentKind kind,
    String query, {
    String? categoryId,
  }) async {
    // Movies and series are searched concurrently by the global search view.
    // Only a newer query of the same kind supersedes this traversal.
    final generation = (_searchGenerations[kind] ?? 0) + 1;
    _searchGenerations[kind] = generation;
    bool superseded() => _searchGenerations[kind] != generation;
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    if (kind != ContentKind.movie && kind != ContentKind.series) {
      return const [];
    }
    if (categoryId != null) {
      final items = await _fetchMediaList(kind, categoryId: categoryId);
      if (superseded()) return const [];
      return items
          .where((item) => item.title.toLowerCase().contains(q))
          .take(_searchResultLimit)
          .toList();
    }
    final results = <MediaItem>[];
    final seen = <String>{};
    final categories = await mediaCategories(kind);
    if (superseded()) return const [];
    if (categories.isEmpty) {
      final items = await _fetchMediaList(kind);
      if (superseded()) return const [];
      return items
          .where((item) => item.title.toLowerCase().contains(q))
          .take(_searchResultLimit)
          .toList();
    }
    for (final category in categories) {
      if (superseded()) return const [];
      final items = await _fetchMediaList(kind, categoryId: category.id);
      if (superseded()) return const [];
      for (final item in items) {
        if (!item.title.toLowerCase().contains(q)) continue;
        if (item.id.isNotEmpty && !seen.add(item.id)) continue;
        results.add(item);
        if (results.length >= _searchResultLimit) {
          _pruneMediaLists(keep: '');
          return results;
        }
      }
      _pruneMediaLists(keep: '');
      // Cached categories may otherwise chain only microtasks for a large
      // catalog, delaying the keystroke that cancels this search.
      await Future<void>.delayed(Duration.zero);
    }
    return results;
  }

  @override
  Future<MediaItem> mediaDetails(MediaItem item) async {
    final action = switch (item.kind) {
      ContentKind.movie => 'get_vod_info',
      ContentKind.series => 'get_series_info',
      _ => null,
    };
    if (action == null) return item;
    final idParam = item.kind == ContentKind.movie ? 'vod_id' : 'series_id';
    final r = await _api({'action': action, idParam: item.id});
    final details = r is Map ? Map<String, dynamic>.from(r) : const {};
    final info = details['info'] is Map
        ? Map<String, dynamic>.from(details['info'] as Map)
        : details;
    return item.copyWith(
      poster:
          _firstImageUrl(info, ['movie_image', 'cover', 'cover_big']) ??
          item.poster,
      backdrop:
          _firstImageUrl(info, ['backdrop_path', 'backdrop', 'cover_big']) ??
          item.backdrop,
      description:
          _firstString(info, ['description', 'plot']) ?? item.description,
      year:
          _firstString(info, ['releasedate', 'release_date', 'year']) ??
          item.year,
      extra: {...item.extra, 'details': details},
    );
  }

  @override
  Future<StreamInfo> resolveMedia(MediaItem item) async {
    if (item.kind != ContentKind.movie && item.kind != ContentKind.episode) {
      throw UnsupportedError('${item.kind.name} is not directly playable yet');
    }
    if (item.id.trim().isEmpty) {
      throw ArgumentError('A playable media item must have a provider ID');
    }
    final details = item.extra['details'];
    final movieData = details is Map ? details['movie_data'] : null;
    final info = details is Map ? details['info'] : null;
    final ext = _firstString(item.extra, ['container_extension']) ??
        (movieData is Map ? _firstString(Map<String, dynamic>.from(movieData), ['container_extension']) : null) ??
        (info is Map ? _firstString(Map<String, dynamic>.from(info), ['container_extension']) : null);
    final extension = ext == null || ext.isEmpty ? 'mp4' : ext;
    final path = item.kind == ContentKind.movie ? 'movie' : 'series';
    return StreamInfo(
      url: '$_base/$path/$_credentialPath/${Uri.encodeComponent(item.id)}.${Uri.encodeComponent(extension)}',
      headers: {HttpHeaders.userAgentHeader: 'VLC/3.0.20 LibVLC/3.0.20'},
      isLive: false,
      providerAccount: streamAccount,
    );
  }

  @override
  Future<SubscriptionExpiry> subscriptionExpiry() async {
    final info = await _api({});
    final user = info is Map ? info['user_info'] : null;
    if (user is Map) {
      if (_hasPositiveAuthentication(user)) {
        _readStreamAccount(user, debugNow?.call() ?? DateTime.now());
      }
      final parsed = parseSubscriptionExpiryValue(user['exp_date']);
      if (parsed.kind != SubscriptionExpiryKind.unknown) return parsed;
    }
    return parseSubscriptionExpiryValue(playlistExpiryHint);
  }

  @override
  Future<void> dispose() async {
    _epgDisposed = true;
    _http.close(force: true);
  }

  // ── http ──────────────────────────────────────────────────────────────

  Future<dynamic> _api(Map<String, String> params) {
    final keys = params.keys.toList()..sort();
    final key = jsonEncode([for (final key in keys) [key, params[key]]]);
    final pending = _apiReads[key];
    if (pending != null) return pending;
    late final Future<dynamic> operation;
    operation = _apiUnshared(params).whenComplete(() {
      if (identical(_apiReads[key], operation)) _apiReads.remove(key);
    });
    _apiReads[key] = operation;
    return operation;
  }

  Future<dynamic> _apiUnshared(Map<String, String> params) async {
    ProviderRequestGate.instance.check(Uri.parse(_base));
    final override = debugApi;
    if (override != null) {
      final result = await override(params);
      await _throwIfAuthenticationRefused(result);
      return result;
    }
    final uri = Uri.parse('$_base/player_api.php').replace(
      queryParameters: {'username': username, 'password': password, ...params},
    );
    final response = await _download(uri, kProviderJsonWorkload);
    final result = await _decodeJson(response.bytes);
    await _throwIfAuthenticationRefused(
      result,
      responseUri: response.responseUri,
    );
    return result;
  }

  Future<void> _throwIfAuthenticationRefused(
    dynamic response, {
    Uri? responseUri,
  }) async {
    final user = response is Map ? response['user_info'] : null;
    if (user is! Map) return;
    final auth = user['auth'];
    if (auth != false &&
        '${auth ?? ''}'.trim().toLowerCase() != '0' &&
        '${auth ?? ''}'.trim().toLowerCase() != 'false') {
      return;
    }
    await _rejectAuthentication(responseUri: responseUri);
  }

  Future<void> _rejectAuthentication({Uri? responseUri}) async {
    final uri = Uri.parse(_base);
    ProviderRequestGate.instance.recordResponse(uri, HttpStatus.unauthorized);
    if (responseUri != null) {
      ProviderRequestGate.instance.recordResponse(
        responseUri,
        HttpStatus.unauthorized,
      );
    }
    try {
      await ProviderRequestGate.instance.flushCooldowns();
    } catch (_) {
      // Persistence failure cannot undo the active in-memory refusal.
    }
    ProviderRequestGate.instance.check(uri);
  }

  /// Catalog responses (`get_vod_streams`/`get_live_streams`) can be many MB;
  /// decoding them on the UI thread stalls the frame. Offload big payloads to a
  /// background isolate, but decode small ones inline — isolate spawn overhead
  /// would dominate for the many tiny auth/category calls.
  static const _isolateJsonThreshold = 256 * 1024;

  Future<dynamic> _decodeJson(Uint8List bytes) {
    if (bytes.length < _isolateJsonThreshold) {
      return Future.value(_decodeJsonBytes(bytes));
    }
    return compute(_decodeJsonBytes, bytes);
  }

  /// Fetches a catalog endpoint (`get_live_streams`/`get_vod_streams`/
  /// `get_series`) and hands back either the already-decoded value from
  /// [debugApi] (tests bypass HTTP entirely) or the raw response bytes for a
  /// real panel call. Real bytes let the caller route through the one-pass
  /// typed worker below instead of decoding into a dynamic tree first.
  Future<Object?> _fetchCatalogRaw(
    Map<String, String> params, {
    LoadToken? token,
  }) async {
    if (token?.isCancelled == true) throw const LoadCancelledException();
    ProviderRequestGate.instance.check(Uri.parse(_base));
    final override = debugApi;
    if (override != null) {
      final result = await override(params);
      await _throwIfAuthenticationRefused(result);
      return result;
    }
    final uri = Uri.parse('$_base/player_api.php').replace(
      queryParameters: {'username': username, 'password': password, ...params},
    );
    final response = await _download(uri, kProviderJsonWorkload, token: token);
    final bytes = response.bytes;
    // Catalogs are arrays. A map may instead be a small HTTP-200 login
    // rejection; keep the large, ordinary catalog worker path unchanged.
    final first = bytes.indexWhere((byte) => byte > 32);
    if (first >= 0 && bytes[first] == 123) {
      await _throwIfAuthenticationRefused(
        await _decodeJson(bytes),
        responseUri: response.responseUri,
      );
    }
    return bytes;
  }

  /// Bounded one-pass ingestion for `get_live_streams`: [raw] is either the
  /// decoded [debugApi] value (mapped inline — it's already small, synthetic
  /// test data) or real response bytes, which get the same threshold-gated
  /// isolate/inline routing as [_decodeJson].
  Future<List<Channel>> _channelsFromRaw(Object? raw) => raw is Uint8List
      ? _decodeLiveChannels(raw)
      : Future.value(mapLiveChannels(raw));

  Future<List<Channel>> _decodeLiveChannels(Uint8List bytes) {
    if (bytes.length < _isolateJsonThreshold) {
      return Future.value(decodeLiveChannelsBytes(bytes));
    }
    return compute(decodeLiveChannelsBytes, bytes);
  }

  /// Bounded one-pass ingestion for `get_vod_streams`/`get_series`. See
  /// [_channelsFromRaw] for the debugApi-vs-real-bytes split.
  Future<List<MediaItem>> _mediaItemsFromRaw(Object? raw, ContentKind kind) =>
      raw is Uint8List
      ? _decodeMediaItems(raw, kind)
      : Future.value(mapMediaItemsFromDecoded(raw, kind));

  Future<List<MediaItem>> _decodeMediaItems(Uint8List bytes, ContentKind kind) {
    final args = XtreamMediaDecodeArgs(bytes, kind);
    if (bytes.length < _isolateJsonThreshold) {
      return Future.value(decodeMediaItemsBytes(args));
    }
    return compute(decodeMediaItemsBytes, args);
  }

  Future<({Uint8List bytes, Uri responseUri})> _download(
    Uri uri,
    HttpWorkloadPolicy policy, {
    LoadToken? token,
  }) async {
    // A fallback guide is already an alternative request. Do not multiply it
    // with the normal catalogue retry before its fifteen-minute backoff.
    final maximumAttempts = uri.queryParameters['action'] == 'get_short_epg' ? 1 : 2;
    final operation = HttpOperation(
      policy,
      onReadMetrics: (m) => DiagnosticsLog.instance.add(
        'http:${policy.name}',
        'compressed_bytes=${m.compressedBytes} decoded_bytes=${m.decodedBytes}',
      ),
    );
    for (var attempt = 1; ; attempt++) {
      try {
        var responseUri = uri;
        final bytes = await providerHttpGet<Uint8List?>(
          uri,
          client: _http,
          operation: operation,
          token: token,
          onResponseUri: (uri) => responseUri = uri,
          readResponse: (resp) async {
            if (resp.statusCode == HttpStatus.ok) {
              return await operation.readBytes(resp);
            }
            await operation.wait(resp.take(0).drain<void>());
            // Some panels also return 404 briefly for an existing API endpoint.
            if (attempt >= maximumAttempts ||
                (resp.statusCode != HttpStatus.notFound &&
                    !isTransientHttpStatus(resp.statusCode))) {
              throw StateError(
                'HTTP ${resp.statusCode} from ${redactUrl(uri)}',
              );
            }
            DiagnosticsLog.instance.add(
              'http:${policy.name}',
              'retrying HTTP ${resp.statusCode} attempt=2 url=${redactUrl(uri)}',
            );
            return null;
          },
        );
        if (bytes != null) return (bytes: bytes, responseUri: responseUri);
      } catch (error) {
        if (token?.isCancelled == true) throw const LoadCancelledException();
        if (attempt >= maximumAttempts || !isTransientNetworkError(error)) rethrow;
      }
      await operation.wait(
        Future<void>.delayed(const Duration(milliseconds: 600)),
      );
    }
  }

  /// Streams [uri]'s body into [destination] without holding it in memory —
  /// the XMLTV path, whose guides can run to hundreds of MB.
  Future<EpgDownloadReceipt> _downloadToFile(
    Uri uri,
    File destination, {
    LoadToken? token,
  }) => const EpgDownloadCache().fetch(
    sourceId: id,
    uri: uri,
    client: _http,
    destination: destination,
    token: token,
  );

  Future<MediaPage> _aggregateMediaPage(
    ContentKind kind, {
    required int page,
  }) async {
    final categories = await mediaCategories(kind);
    if (categories.isEmpty) {
      _pagedCategoryKeys[kind] = _mediaListKey(kind, null);
      final items = await _fetchMediaList(kind);
      return _sliceMediaPage(items, page: page);
    }

    final start = (page - 1) * _mediaPageSize;
    var skipped = 0;
    final pageItems = <MediaItem>[];
    final seen = <String>{};

    for (final category in categories) {
      final key = _mediaListKey(kind, category.id);
      final knownSize = _mediaCategorySizes[key];
      if (knownSize != null && skipped + knownSize <= start) {
        skipped += knownSize;
        continue;
      }
      final items = await _fetchMediaList(kind, categoryId: category.id);
      if (skipped + items.length <= start) {
        skipped += items.length;
        continue;
      }

      _pagedCategoryKeys[kind] = key;
      _pruneMediaLists(keep: key);
      final startInCategory = math.max(0, start - skipped);
      for (var i = startInCategory; i < items.length; i++) {
        final item = items[i];
        if (item.id.isNotEmpty && !seen.add(item.id)) continue;
        pageItems.add(item);
        if (pageItems.length >= _mediaPageSize) {
          return MediaPage(items: pageItems, page: page, totalPages: page + 1);
        }
      }
      skipped += items.length;
    }

    return MediaPage(items: pageItems, page: page, totalPages: page);
  }

  MediaPage _sliceMediaPage(List<MediaItem> items, {required int page}) {
    final totalPages = items.isEmpty
        ? page
        : (items.length / _mediaPageSize).ceil();
    final start = (page - 1) * _mediaPageSize;
    if (start >= items.length) {
      return MediaPage(items: const [], page: page, totalPages: page);
    }
    final end = math.min(start + _mediaPageSize, items.length);
    return MediaPage(
      items: items.sublist(start, end),
      page: page,
      totalPages: totalPages < page ? page : totalPages,
    );
  }

  @override
  void invalidate() {
    // Drop the memoized VOD/series catalogs so a forced reload re-fetches them.
    // Xtream live channels aren't memoized, so nothing else to clear here.
    _mediaCategoriesCache.clear();
    _mediaListCache.clear();
    _mediaListSizes.clear();
    _mediaCategorySizes.clear();
    _pagedCategoryKeys.clear();
    _cachedMediaItems = 0;
    for (final kind in _searchGenerations.keys.toList()) {
      _searchGenerations[kind] = _searchGenerations[kind]! + 1;
    }
  }

  Future<List<MediaItem>> _fetchMediaList(
    ContentKind kind, {
    String? categoryId,
  }) {
    final key = _mediaListKey(kind, categoryId);
    final cached = _mediaListCache[key];
    if (cached != null) {
      final size = _mediaListSizes.remove(key);
      if (size != null) _mediaListSizes[key] = size;
      return cached;
    }
    final pending = () async {
      final action = switch (kind) {
        ContentKind.movie => 'get_vod_streams',
        ContentKind.series => 'get_series',
        _ => null,
      };
      if (action == null) return const <MediaItem>[];
      final params = {'action': action};
      if (categoryId != null) params['category_id'] = categoryId;
      final raw = await _fetchCatalogRaw(params);
      return _mediaItemsFromRaw(raw, kind);
    }();
    _mediaListCache[key] = pending;
    // A transient failure must not become a permanently memoized error. An
    // older failed request must also leave a replacement after invalidate alone.
    unawaited(
      pending.then<void>((items) {
        if (!identical(_mediaListCache[key], pending)) return;
        _mediaListSizes[key] = items.length;
        _mediaCategorySizes[key] = items.length;
        _cachedMediaItems += items.length;
        _pruneMediaLists(keep: key);
      }, onError: (Object _, StackTrace _) {
        if (identical(_mediaListCache[key], pending)) _mediaListCache.remove(key);
      }),
    );
    return pending;
  }

  static String _mediaListKey(ContentKind kind, String? categoryId) =>
      '${kind.name}:${categoryId ?? ''}';

  void _pruneMediaLists({required String keep}) {
    // Keep counts after eviction: aggregate paging can skip previous categories
    // without downloading their full catalogs again. In-flight requests are not
    // in this LRU and remain shared. One oversized active category may exceed
    // the budget because the provider does not offer real category pagination.
    for (final key in _mediaListSizes.keys.toList()) {
      if (_cachedMediaItems <= _maximumCachedMediaItems &&
          _mediaListSizes.length <= _maximumCachedMediaCategories) {
        break;
      }
      if (key == keep || _pagedCategoryKeys.containsValue(key)) continue;
      _cachedMediaItems -= _mediaListSizes.remove(key)!;
      _mediaListCache.remove(key);
    }
  }

  Future<List<MediaItem>> _seriesSeasons(MediaItem series) async {
    final details = await _seriesDetails(series);
    final episodes = details['episodes'];
    if (episodes is! Map) return const [];
    final infoSeasons = details['seasons'] is List
        ? (details['seasons'] as List).whereType<Map>().toList()
        : const <Map>[];
    // Each season carries its own episode slice below. Repeating the complete
    // series tree in every cached row multiplies JSON, encryption and IO work.
    final sharedDetails = Map<String, dynamic>.from(details)
      ..remove('episodes')
      ..remove('seasons');
    final keys = episodes.keys.toList();
    final order = {for (var i = 0; i < keys.length; i++) keys[i]: i};
    keys.sort((a, b) {
      final number = (int.tryParse(a.toString()) ?? 0)
          .compareTo(int.tryParse(b.toString()) ?? 0);
      return number != 0 ? number : order[a]!.compareTo(order[b]!);
    });
    return keys.map((key) {
      final seasonNumber = int.tryParse(key.toString());
      final info = infoSeasons
          .map((e) => Map<String, dynamic>.from(e))
          .where((e) => '${e['season_number'] ?? e['season']}' == '$key')
          .cast<Map<String, dynamic>?>()
          .firstWhere((e) => e != null, orElse: () => null);
      final title =
          _firstString(info ?? const {}, ['name', 'title']) ??
          'Season ${seasonNumber ?? key}';
      return MediaItem(
        id: '${series.id}:season:$key',
        title: title,
        kind: ContentKind.season,
        parentId: series.id,
        poster:
            _firstString(info ?? const {}, ['cover', 'cover_big']) ??
            series.poster,
        seasonNumber: seasonNumber,
        extra: {
          'seriesId': series.id,
          'seasonId': '$key',
          'episodes': episodes[key],
          'details': sharedDetails,
        },
      );
    }).toList();
  }

  List<MediaItem> _seasonEpisodes(MediaItem season) {
    final raw = season.extra['episodes'];
    if (raw is! List) return const [];
    final result = raw.whereType<Map>().map((entry) {
      final m = Map<String, dynamic>.from(entry);
      final info = m['info'] is Map
          ? Map<String, dynamic>.from(m['info'] as Map)
          : const <String, dynamic>{};
      final id = _firstString(m, ['id', 'episode_id', 'stream_id']) ?? '';
      return MediaItem(
        id: id,
        title: _firstString(m, ['title', 'name']) ?? 'Episode',
        kind: ContentKind.episode,
        parentId: season.id,
        poster:
            _firstImageUrl(m, ['movie_image', 'cover', 'cover_big']) ??
            _firstImageUrl(info, ['movie_image', 'cover', 'cover_big']) ??
            season.poster,
        description:
            _firstString(m, ['plot', 'description']) ??
            _firstString(info, ['plot', 'description']),
        year: _firstString(m, ['releasedate', 'release_date', 'year']),
        durationSeconds:
            _parseDurationSeconds(
              _firstString(m, ['duration', 'time', 'length']),
            ) ??
            _parseDurationSeconds(
              _firstString(info, ['duration_secs', 'duration', 'time', 'length']),
            ),
        seasonNumber: season.seasonNumber,
        episodeNumber: _parseInt(m['episode_num'] ?? m['episode_number']),
        extra: m,
      );
    }).where((episode) => episode.id.trim().isNotEmpty).toList();
    final order = {for (var i = 0; i < result.length; i++) result[i]: i};
    result.sort((a, b) {
      if (a.episodeNumber == null && b.episodeNumber != null) return 1;
      if (a.episodeNumber != null && b.episodeNumber == null) return -1;
      final number = (a.episodeNumber ?? 0).compareTo(b.episodeNumber ?? 0);
      return number != 0 ? number : order[a]!.compareTo(order[b]!);
    });
    return result;
  }

  Future<Map<String, dynamic>> _seriesDetails(MediaItem series) async {
    final existing = series.extra['details'];
    if (existing is Map) return Map<String, dynamic>.from(existing);
    final r = await _api({'action': 'get_series_info', 'series_id': series.id});
    return r is Map ? Map<String, dynamic>.from(r) : const {};
  }

  @visibleForTesting
  MediaItem debugMapMediaItem(Map<String, dynamic> m, ContentKind kind) =>
      _mapMediaItem(m, kind);
}

/// Isolate entrypoint: decode UTF-8 JSON bytes. Top-level + pure so it can run
/// under [compute]. Returns the raw decoded tree (List/Map of primitives),
/// which is sendable back across the isolate port. Used for the small/generic
/// calls (auth, categories, `get_series_info`) that have no typed worker.
dynamic _decodeJsonBytes(Uint8List bytes) =>
    jsonDecode(utf8.decode(bytes, allowMalformed: true));

/// Maps a decoded `get_live_streams` response (or a category-partitioned
/// slice of one) straight to typed [Channel]s. Top-level + pure: it's the
/// core of [decodeLiveChannelsBytes] (isolate path) and is also called
/// directly with an already-decoded [debugApi] value (test path, no bytes to
/// decode). Public so fixture-driven tests can exercise it directly.
@visibleForTesting
List<Channel> mapLiveChannels(dynamic decoded) {
  if (decoded is! List) {
    throw const FormatException('Invalid live channel catalog');
  }
  return decoded.whereType<Map>().map((s) {
    final m = Map<String, dynamic>.from(s);
    final streamId = '${m['stream_id']}';
    final epgId = m['epg_channel_id']?.toString();
    return Channel(
      id: streamId,
      name: '${m['name']}',
      number: int.tryParse('${m['num']}'),
      logo:
          (m['stream_icon'] is String &&
              (m['stream_icon'] as String).isNotEmpty)
          ? m['stream_icon'] as String
          : null,
      categoryId: m['category_id']?.toString(),
      archiveDays: _archiveDays(m['tv_archive'], m['tv_archive_duration']),
      extra: {
        'streamId': streamId,
        if (epgId != null && epgId.isNotEmpty) 'tvgId': epgId,
      },
    );
  }).toList();
}

/// Isolate entrypoint: decode + map a `get_live_streams` response in one
/// pass, so the dynamic JSON tree is built and consumed entirely inside the
/// worker isolate — only the typed [Channel] list crosses back to the main
/// isolate. Top-level + pure so it can run under [compute]; public so
/// fixture-driven tests can exercise it directly with raw bytes.
@visibleForTesting
List<Channel> decodeLiveChannelsBytes(Uint8List bytes) =>
    mapLiveChannels(jsonDecode(utf8.decode(bytes, allowMalformed: true)));

/// Maps a decoded VOD/series catalog response (`get_vod_streams`/
/// `get_series`) to typed [MediaItem]s. Shared by the already-decoded
/// [debugApi] path and [decodeMediaItemsBytes] (isolate) path.
@visibleForTesting
List<MediaItem> mapMediaItemsFromDecoded(dynamic decoded, ContentKind kind) =>
    _listFromAny(decoded)
        .map((e) => _mapMediaItem(e, kind))
        .where((item) => item.id.isNotEmpty)
        .toList();

/// Bundles the isolate arguments for [decodeMediaItemsBytes] — [compute]
/// only passes a single message, and mapping needs both the raw bytes and
/// which [ContentKind] they represent.
@visibleForTesting
class XtreamMediaDecodeArgs {
  final Uint8List bytes;
  final ContentKind kind;
  const XtreamMediaDecodeArgs(this.bytes, this.kind);
}

/// Isolate entrypoint: decode + map a VOD/series catalog response in one
/// pass — the dynamic JSON tree never leaves the worker isolate. Top-level +
/// pure so it can run under [compute]; public so fixture-driven tests can
/// exercise it directly with raw bytes.
@visibleForTesting
List<MediaItem> decodeMediaItemsBytes(XtreamMediaDecodeArgs args) =>
    mapMediaItemsFromDecoded(
      jsonDecode(utf8.decode(args.bytes, allowMalformed: true)),
      args.kind,
    );

MediaItem _mapMediaItem(Map<String, dynamic> m, ContentKind kind) {
  final id = kind == ContentKind.movie
      ? _firstString(m, ['stream_id', 'id', 'movie_id', 'vod_id'])
      : _firstString(m, ['series_id', 'id', 'stream_id']);
  return MediaItem(
    id: id ?? '',
    title: _firstString(m, ['name', 'title']) ?? 'Untitled',
    kind: kind,
    categoryId: m['category_id']?.toString(),
    poster: _firstImageUrl(m, ['stream_icon', 'cover', 'cover_big']),
    backdrop: _firstImageUrl(m, ['backdrop_path', 'backdrop', 'cover_big']),
    description: _firstString(m, ['plot', 'description']),
    year: _firstString(m, ['year', 'releaseDate', 'release_date']),
    rating: _parseDouble(_firstString(m, ['rating', 'rating_5based'])),
    providerId: _firstString(m, ['tmdb_id', 'imdb_id']),
    extra: m,
  );
}

List<Map<String, dynamic>> _listFromAny(dynamic value) {
  if (value is List) {
    return value
        .whereType<Map>()
        .map((entry) => Map<String, dynamic>.from(entry))
        .toList();
  }
  if (value is Map) {
    for (final key in const [
      'data',
      'items',
      'results',
      'series',
      'movies',
      'available_channels',
      'categories',
    ]) {
      final nested = value[key];
      final rows = _listFromAny(nested);
      if (rows.isNotEmpty) return rows;
    }
  }
  return const [];
}

int? _parseInt(dynamic value) {
  if (value is int) return value;
  if (value == null) return null;
  return int.tryParse(value.toString());
}

/// Catch-up window in days from a live-stream's `tv_archive` (0/1) and
/// `tv_archive_duration` (days). Archive off → 0; on but duration
/// missing/zero → [kDefaultArchiveDays].
int _archiveDays(dynamic archive, dynamic duration) {
  final on = archive == 1 || archive == '1' || archive == true;
  if (!on) return 0;
  final days = _parseInt(duration) ?? 0;
  return days > 0 ? days : kDefaultArchiveDays;
}

double? _parseDouble(String? value) {
  if (value == null) return null;
  return double.tryParse(value.replaceAll(',', '.'));
}

int? _parseDurationSeconds(String? value) {
  if (value == null || value.isEmpty) return null;
  final direct = int.tryParse(value);
  if (direct != null) return direct;
  final parts = value.split(':').map(int.tryParse).toList();
  if (parts.any((part) => part == null)) return null;
  if (parts.length == 3) return parts[0]! * 3600 + parts[1]! * 60 + parts[2]!;
  if (parts.length == 2) return parts[0]! * 60 + parts[1]!;
  return null;
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

String? _firstImageUrl(Map<dynamic, dynamic> map, List<String> keys) {
  for (final key in keys) {
    final url = normalizeImageUrl(map[key]);
    if (url != null) return url;
  }
  return null;
}

/// Credentials extracted from a URL that points at an Xtream Codes panel
/// (typically a `get.php` playlist link). [host] is `scheme://host[:port]`.
class XtreamCredentials {
  final String host;
  final String username;
  final String password;
  const XtreamCredentials({
    required this.host,
    required this.username,
    required this.password,
  });
}

/// Pulls Xtream credentials out of [uri] when it looks like a panel link —
/// either `http://user:pass@host/...` or `?username=…&password=…`. Returns
/// null when host/username/password aren't all present.
XtreamCredentials? xtreamCredentialsFromUrl(Uri uri) {
  String? username;
  String? password;
  if (uri.userInfo.isNotEmpty) {
    final parts = uri.userInfo.split(':');
    if (parts.length >= 2) {
      username = parts[0];
      password = parts.sublist(1).join(':');
    }
  }
  username ??= uri.queryParameters['username'];
  password ??= uri.queryParameters['password'];
  if (username == null ||
      username.isEmpty ||
      password == null ||
      password.isEmpty) {
    return null;
  }
  if (uri.host.isEmpty) return null;
  final scheme = uri.scheme.isEmpty ? 'http' : uri.scheme;
  final host = '$scheme://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}';
  return XtreamCredentials(host: host, username: username, password: password);
}
