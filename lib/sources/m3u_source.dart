import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute, visibleForTesting;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:crypto/crypto.dart';

import '../data/load_token.dart';
import '../data/diagnostics_log.dart';
import '../data/epg_download_cache.dart';
import '../data/net.dart';
import '../data/secret_locator_vault.dart' show hasSealedLocator;
import 'epg_guides.dart';
import 'epg_matching.dart';
import 'epg_mapping.dart';
import 'expiry.dart';
import 'm3u_catalog.dart';
import 'source.dart';
import 'source_identity.dart';

/// Only provider-supplied HTTP playback options are accepted from a playlist.
Map<String, String> m3uPlaybackHeaders(Channel channel, String? userAgent) {
  final headers = <String, String>{};
  void add(String name, String? value) {
    if (value != null && value.isNotEmpty &&
        !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
      headers[name] = value;
    }
  }
  add('User-Agent', channel.extra['streamUserAgent'] as String? ?? userAgent);
  add('Referer', channel.extra['streamReferer'] as String?);
  return headers;
}

/// Live and VOD catalogs backed by one extended M3U/M3U8 playlist (URL).
///
/// Stream URLs are static, so resolving needs no network. EPG comes from an
/// XMLTV guide — either an explicit [epgUrl] or the playlist's own
/// `url-tvg`/`x-tvg-url`/`tvg-url` header attributes. Credentialed `get.php` links without
/// either use the provider's sibling `xmltv.php` endpoint.
class M3uSource
    implements
        Source,
        BatchedEpgSource,
        MappedEpgSource,
        CatchupSource,
        SourceCapabilityReporter,
        ProviderStreamSource,
        FullMediaCatalogSource,
        SharedCatalogSource,
        RefreshableSource {
  final String sourceId;
  final String playlistUrl;
  final String? epgUrl;

  /// Extra XMLTV guides layered *under* [epgUrl]/`url-tvg`, in priority order.
  /// See [mergeEpgGuides] for what "under" means: a channel is served by the
  /// first guide that carries it, never by two at once.
  final List<String> extraEpgUrls;

  final String? userAgent;
  @override
  final epgMapping = EpgMappingSession();
  final String? catchupTimezone;
  final int? catchupOffsetMinutes;
  final int? catchupMaxDays;
  final int? maximumStreams;

  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..autoUncompress = false;

  List<Channel>? _channels;
  List<Category>? _categories;
  M3uMediaCatalog? _media;
  Object? _catalogKey;
  Future<void>? _catalogPreparation;
  Future<void>? _parseFuture;
  LoadToken? _parseToken;
  int _parseGeneration = 0;
  bool _disposed = false;
  String? _headerEpgUrl;
  Uri? _effectivePlaylistUri;
  bool _headerKnown = false;
  CatchupCapability _catchupCapability = CatchupCapability.unsupported;

  M3uSource({
    required this.sourceId,
    required this.playlistUrl,
    this.epgUrl,
    this.extraEpgUrls = const [],
    this.userAgent,
    this.catchupTimezone,
    this.catchupOffsetMinutes,
    this.catchupMaxDays,
    this.maximumStreams,
    this.displayName,
  });

  /// User-assigned label (from SourceConfig); preferred over the derived name.
  final String? displayName;

  @override
  String get id => sourceId;

  @override
  ProviderStreamAccount get streamAccount => ProviderStreamAccount(
    id: providerStreamAccountId(playlistUrl),
    maximumStreams: maximumStreams ?? 1,
  );

  @override
  String get name => displayName?.trim().isNotEmpty == true
      ? displayName!.trim()
      : 'M3U · ${Uri.tryParse(playlistUrl)?.host ?? 'playlist'}';

  @override
  CatchupCapability get catchupCapability => _catchupCapability;

  String? get _defaultEpgUrl {
    return _inferEpgUrl(_effectivePlaylistUri) ??
        _inferEpgUrl(Uri.tryParse(playlistUrl));
  }

  String? _inferEpgUrl(Uri? uri) {
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty ||
        !uri.path.endsWith('/get.php')) {
      return null;
    }
    final username = uri.queryParameters['username'];
    final password = uri.queryParameters['password'];
    if (username == null ||
        username.isEmpty ||
        password == null ||
        password.isEmpty) {
      return null;
    }
    // These playlist links share their credentials with the sibling XMLTV
    // endpoint. Keep the source M3U and never probe the player API.
    return uri
        .resolve('xmltv.php')
        .replace(
          userInfo: '',
          queryParameters: {'username': username, 'password': password},
          fragment: '',
        )
        .toString();
  }

  List<String> get _headerEpgUrls {
    final raw = _headerEpgUrl;
    final base = _effectivePlaylistUri ?? Uri.tryParse(playlistUrl);
    if (raw == null || base == null) return const [];
    final urls = <String>{};
    for (final value in raw.split(RegExp(r'[\s,]+'))) {
      if (value.isEmpty) continue;
      final relative = Uri.tryParse(value);
      if (relative == null) continue;
      final uri = base.resolveUri(relative);
      if ((uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) {
        continue;
      }
      urls.add(uri.toString());
      if (urls.length == kMaxEpgGuides) break;
    }
    return urls.toList(growable: false);
  }

  @override
  SourceCapabilities get sourceCapabilities => SourceCapabilities(
    epg:
        (epgUrl?.isNotEmpty == true ||
            extraEpgUrls.any((url) => url.isNotEmpty) ||
            _headerEpgUrls.isNotEmpty ||
            _defaultEpgUrl != null)
        ? CapabilityAvailability.supported
        : (!_headerKnown
              ? CapabilityAvailability.unknown
              : CapabilityAvailability.unavailable),
    catchup: _channels == null
        ? CapabilityAvailability.unknown
        : (_catchupCapability.supported
              ? CapabilityAvailability.supported
              : CapabilityAvailability.unavailable),
    resolution: ResolutionCapability.playlistDefined,
    prefetchPlaybackSeasons: false,
  );

  @override
  Future<void> connect() async {} // nothing to authenticate

  @override
  Future<List<Category>> categories() async {
    await _ensureParsed();
    return _categories!;
  }

  @override
  Future<List<Channel>> channels({String? categoryId}) async {
    await _ensureParsed();
    if (categoryId == null) return _channels!;
    return _channels!.where((c) => c.categoryId == categoryId).toList();
  }

  @override
  Future<StreamInfo> resolve(Channel channel) async {
    assert(
      !hasSealedLocator(channel.extra),
      'sealed locator reached M3uSource.resolve — reveal it in '
      'LibraryRepository first',
    );
    final url = channel.extra['url']?.toString();
    if (url == null || url.isEmpty) {
      throw StateError('Channel "${channel.name}" has no stream URL');
    }
    return StreamInfo(
      url: url,
      headers: m3uPlaybackHeaders(channel, userAgent),
      providerAccount: streamAccount,
    );
  }

  @override
  Future<StreamInfo> resolveArchive(
    Channel channel,
    Programme programme,
  ) async {
    assert(
      !hasSealedLocator(channel.extra),
      'sealed locator reached M3uSource.resolveArchive — reveal it in '
      'LibraryRepository first',
    );
    final template =
        channel.extra['catchupSource']?.toString() ??
        catchupCapability.template;
    if (template == null || template.isEmpty) {
      throw UnsupportedError('M3U channel does not advertise catch-up');
    }
    final start = programme.start.toUtc().millisecondsSinceEpoch ~/ 1000;
    final end = programme.stop.toUtc().millisecondsSinceEpoch ~/ 1000;
    final url = template
        .replaceAll('{start}', '$start')
        .replaceAll('{end}', '$end')
        .replaceAll('%START%', '$start')
        .replaceAll('%END%', '$end');
    return StreamInfo(
      url: url,
      headers: m3uPlaybackHeaders(channel, userAgent),
      isLive: false,
      providerAccount: streamAccount,
    );
  }

  /// Unbatched fallback, kept for [Source]'s contract. Drains the same merged
  /// feed [epgBatched] builds, so the two can't diverge in matching or merge
  /// order — only in whether the result is held in memory at once.
  @override
  Future<List<Programme>> epg(List<Channel> channels) async {
    final batches = epgBatched(channels);
    if (batches == null) return const [];
    final out = <Programme>[];
    await for (final batch in batches) {
      out.addAll(batch);
    }
    return out;
  }

  @override
  Stream<List<Programme>>? epgBatched(
    List<Channel> channels, {
    LoadToken? token,
  }) {
    if (epgUrl?.isNotEmpty != true && _channels == null) {
      return _discoverEpg(channels, token);
    }
    final feeds = _guideFeeds(channels, token);
    return feeds.isEmpty ? null : mergeEpgGuides(feeds, token: token);
  }

  Stream<List<Programme>> _discoverEpg(
    List<Channel> channels,
    LoadToken? token,
  ) async* {
    // A new source can receive its channels from SQLite without parsing the
    // playlist. Discover its header in the background EPG stage rather than
    // interpreting an unknown header as a successful empty guide.
    if (_disposed || (token?.isCancelled ?? false)) {
      throw const LoadCancelledException();
    }
    await _restoreGuideHeader();
    while (!_headerKnown) {
      if (_disposed || (token?.isCancelled ?? false)) {
        throw const LoadCancelledException();
      }
      final generation = _parseGeneration;
      try {
        await _ensureParsed();
      } on LoadCancelledException {
        // A daily catalog refresh replaces the playlist parse, but does not
        // supersede this guide refresh. Join its replacement to obtain the URL.
        if (_disposed ||
            (token?.isCancelled ?? false) ||
            generation == _parseGeneration) {
          rethrow;
        }
      }
    }
    if (_disposed || (token?.isCancelled ?? false)) {
      throw const LoadCancelledException();
    }
    yield* mergeEpgGuides(_guideFeeds(channels, token), token: token);
  }

  /// The guides this source should ingest, in priority order: the playlist's
  /// own (explicit [epgUrl] or its header guides) first, then [extraEpgUrls].
  ///
  /// Empty when there is no guide URL or no provider channels. A nonempty
  /// playlist without usable ids/names still parses its guide: unmatched
  /// declarations supply the catalogue for explicit user mappings.
  List<EpgGuideFeed> _guideFeeds(List<Channel> channels, LoadToken? token) {
    if (channels.isEmpty) return const [];
    final headerUrls = _headerEpgUrls;
    final inferred = _defaultEpgUrl;
    final primaryOrigin = epgUrl?.isNotEmpty == true
        ? 'explicit'
        : headerUrls.isNotEmpty
        ? 'playlist_header'
        : inferred != null
        ? 'inferred_get_php'
        : 'none';
    final primaryUrls = <String>{
      if (epgUrl?.isNotEmpty == true)
        epgUrl!
      else if (headerUrls.isNotEmpty)
        ...headerUrls
      else
        ?inferred,
    };
    final urls = <String>{
      ...primaryUrls,
      for (final url in extraEpgUrls)
        if (url.isNotEmpty) url,
    }.take(kMaxEpgGuides).toList();
    DiagnosticsLog.instance.add(
      'epg',
      'm3u primary_origin=$primaryOrigin guides=${urls.length}',
    );
    epgMapping.validateGuides(
      urls.take(kMaxEpgGuides).map((url) => epgGuideId(id, url)),
    );
    if (urls.isEmpty) return const [];
    final tvgIds = buildTvgIdIndex(channels);
    final names = epgNameIndexFor(
      channels,
      extraCount: urls.where((url) => !primaryUrls.contains(url)).length,
    );
    return [
      for (var i = 0; i < urls.length && i < kMaxEpgGuides; i++)
        xmltvGuideFeed(
          url: urls[i],
          cachedDownload: (uri, file) =>
              _downloadToFile(uri, file, token: token),
          tvgIdToChannelIds: tvgIds,
          nameToChannelIds: primaryUrls.contains(urls[i]) ? const {} : names,
          token: token,
          guideId: epgGuideId(id, urls[i]),
          guideLabel: primaryUrls.contains(urls[i])
              ? 'Playlist guide'
              : 'XMLTV guide ${i + 1}',
          mapping: epgMapping,
        ),
    ];
  }

  @override
  Future<List<MediaCategory>> mediaCategories(ContentKind kind) async {
    await _ensureParsed();
    return _media!.categories[kind] ?? const [];
  }

  @override
  Future<List<MediaItem>> mediaItems(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    int? maxPages,
  }) async {
    await _ensureParsed();
    final items = parent == null
        ? _media!.roots[kind] ?? const <MediaItem>[]
        : _media!.children[parent.id] ?? const <MediaItem>[];
    return items.where((item) =>
      item.kind == kind && (categoryId == null || item.categoryId == categoryId),
    ).toList();
  }

  @override
  Future<List<MediaItem>> allMediaItems(ContentKind kind, {LoadToken? token}) async {
    if (token?.isCancelled ?? false) throw const LoadCancelledException();
    final items = await mediaItems(kind);
    if (token?.isCancelled ?? false) throw const LoadCancelledException();
    return items;
  }

  @override
  Future<MediaPage> mediaItemsPage(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    int page = 1,
  }) async {
    const pageSize = 100;
    final items = await mediaItems(kind, categoryId: categoryId, parent: parent);
    final totalPages = (items.length + pageSize - 1) ~/ pageSize;
    final start = (page - 1) * pageSize;
    return MediaPage(
      items: start < 0 || start >= items.length
          ? const []
          : items.skip(start).take(pageSize).toList(),
      page: page,
      totalPages: totalPages < 1 ? 1 : totalPages,
    );
  }

  @override
  Future<List<MediaItem>> searchMedia(
    ContentKind kind,
    String query, {
    String? categoryId,
  }) async {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    final items = await mediaItems(kind, categoryId: categoryId);
    return items.where((item) => item.title.toLowerCase().contains(q)).toList();
  }

  @override
  Future<MediaItem> mediaDetails(MediaItem item) async => item;

  @override
  Future<StreamInfo> resolveMedia(MediaItem item) async {
    if (item.kind != ContentKind.movie && item.kind != ContentKind.episode) {
      throw UnsupportedError('This M3U item is not playable');
    }
    assert(!hasSealedLocator(item.extra), 'Reveal the M3U media locator before playback');
    final url = item.extra['url'] as String?;
    if (url == null || url.isEmpty) throw StateError('M3U item has no stream URL');
    return StreamInfo(
      url: url,
      isLive: false,
      headers: m3uPlaybackHeaders(Channel(id: item.id, name: item.title, extra: item.extra), userAgent),
      providerAccount: streamAccount,
    );
  }

  @override
  Future<void> prepareCatalog(Object refreshKey, {required bool refresh}) {
    if (identical(_catalogKey, refreshKey) && _catalogPreparation != null) {
      return _catalogPreparation!;
    }
    if (refresh) invalidate();
    _catalogKey = refreshKey;
    return _catalogPreparation = _ensureParsed();
  }

  /// Read only metadata in the configured playlist URL. Access to an M3U
  /// does not imply access to player_api.php; probing it can reject the account.
  /// Users can explicitly upgrade to Xtream in source settings when supported.
  @override
  Future<SubscriptionExpiry> subscriptionExpiry() async =>
      subscriptionExpiryFromPlaylistUrl(playlistUrl);

  @override
  Future<void> dispose() async {
    _disposed = true;
    _parseToken?.cancel();
    _parseGeneration++;
    _parseFuture = null;
    _catalogKey = null;
    _catalogPreparation = null;
    _media = null;
    _http.close(force: true);
  }

  // ── parsing ────────────────────────────────────────────────────────────

  // Small playlists parse fast enough inline; isolate spawn overhead would
  // dominate. Mirrors XtreamSource's `_isolateJsonThreshold`.
  static const _isolateM3uThreshold = 256 * 1024;

  @override
  void invalidate() {
    _parseToken?.cancel();
    // Drop everything _ensureParsed memoizes so a forced reload re-downloads
    // and re-parses the playlist — otherwise a stale channel list, header EPG
    // url, and catch-up capability would survive "Reload source".
    _parseGeneration++;
    _parseFuture = null;
    _channels = null;
    _categories = null;
    _media = null;
    _catalogKey = null;
    _catalogPreparation = null;
    _headerEpgUrl = null;
    _effectivePlaylistUri = null;
    _headerKnown = false;
    _catchupCapability = CatchupCapability.unsupported;
  }

  Future<void> _ensureParsed() async {
    if (_disposed) throw const LoadCancelledException();
    if (_channels != null && _media != null) return;
    final pending = _parseFuture;
    if (pending != null) return pending;
    final token = LoadToken();
    _parseToken = token;
    final future = _parse(_parseGeneration, token);
    _parseFuture = future;
    try {
      await future;
    } finally {
      if (identical(_parseFuture, future)) {
        _parseFuture = null;
        _parseToken = null;
      }
    }
  }

  Future<void> _parse(int generation, LoadToken token) async {
    var effectiveUri = Uri.parse(playlistUrl);
    final bytes = await _download(
      effectiveUri,
      kPlaylistWorkload,
      generation: generation,
      token: token,
      onResponseUri: (uri) => effectiveUri = uri,
    );
    // Decode + parse on a background isolate: a large playlist (tens of MB,
    // tens of thousands of channels) would otherwise stall the UI thread for
    // hundreds of ms while building Channel objects.
    final parsed = bytes.length < _isolateM3uThreshold
        ? _parseM3uBytes(bytes)
        : await compute(_parseM3uBytes, bytes);
    if (_disposed || generation != _parseGeneration) {
      throw const LoadCancelledException();
    }
    _channels = parsed.channels;
    _categories = parsed.categories;
    _media = parsed.media;
    _headerEpgUrl = parsed.headerEpgUrl;
    _effectivePlaylistUri = effectiveUri;
    _headerKnown = true;
    final parsedCapability = parsed.catchupCapability;
    _catchupCapability = parsedCapability.supported
        ? CatchupCapability(
            mode: parsedCapability.mode,
            timezone: catchupTimezone ?? parsedCapability.timezone,
            fixedOffsetMinutes: catchupOffsetMinutes,
            maxArchiveWindow: catchupMaxDays == null
                ? parsedCapability.maxArchiveWindow
                : Duration(days: catchupMaxDays!),
            startFormat: parsedCapability.startFormat,
            endFormat: parsedCapability.endFormat,
            template: parsedCapability.template,
          )
        : parsedCapability;
    DiagnosticsLog.instance.add(
      'parse:m3u',
      'rejected_rows=${parsed.rejectedRows}',
    );
    try {
      await const FlutterSecureStorage().write(
        key: _guideHeaderKey,
        value: jsonEncode({
          'schemaVersion': 2,
          'url': _headerEpgUrl,
          'effectivePlaylistUri': effectiveUri.toString(),
          'at': DateTime.now().toIso8601String(),
        }),
      );
    } catch (_) {
      // Optional device-local metadata; channels remain usable without it.
    }
  }

  String get _guideHeaderKey => 'm3u_guide_header_${sha256.convert(utf8.encode(
    jsonEncode([playlistUrl, userAgent]),
  ))}';

  Future<void> _restoreGuideHeader() async {
    if (_headerKnown) return;
    final generation = _parseGeneration;
    try {
      final raw = await const FlutterSecureStorage().read(key: _guideHeaderKey);
      if (_disposed || _headerKnown || generation != _parseGeneration) return;
      if (raw == null) return;
      final value = jsonDecode(raw) as Map;
      // Earlier parsers could miss a header, and never saved its redirect base.
      if (value['schemaVersion'] != 2) return;
      final at = DateTime.parse(value['at'] as String);
      final age = DateTime.now().difference(at);
      if (age.isNegative || age >= const Duration(hours: 24)) return;
      final url = value['url'];
      if (url != null && url is! String) return;
      final savedBase = value['effectivePlaylistUri'];
      if (savedBase is! String) return;
      final base = Uri.tryParse(savedBase);
      if (base == null ||
          (base.scheme != 'http' && base.scheme != 'https') ||
          base.host.isEmpty) {
        return;
      }
      _headerEpgUrl = url as String?;
      _effectivePlaylistUri = base;
      _headerKnown = true;
    } catch (_) {
      // Fall back to discovering the header from the playlist.
    }
  }

  Future<Uint8List> _download(
    Uri uri,
    HttpWorkloadPolicy policy, {
    required int generation,
    required LoadToken token,
    void Function(Uri)? onResponseUri,
  }) async {
    final operation = HttpOperation(
      policy,
      onReadMetrics: (m) => DiagnosticsLog.instance.add(
        'http:${policy.name}',
        'compressed_bytes=${m.compressedBytes} decoded_bytes=${m.decodedBytes}',
      ),
    );
    for (var attempt = 1; ; attempt++) {
      try {
        final bytes = await providerHttpGet<Uint8List?>(
          uri,
          client: _http,
          operation: operation,
          token: token,
          headers: {HttpHeaders.userAgentHeader: ?userAgent},
          onResponseUri: onResponseUri,
          checkCancellation: () {
            if (_disposed || generation != _parseGeneration) {
              throw const LoadCancelledException();
            }
          },
          readResponse: (resp) async {
            if (resp.statusCode == HttpStatus.ok) {
              return await operation.readBytes(resp);
            }
            await operation.wait(resp.take(0).drain<void>());
            if (attempt >= 2 || !isTransientHttpStatus(resp.statusCode)) {
              throw StateError(
                'HTTP ${resp.statusCode} fetching ${redactUrl(uri)}',
              );
            }
            DiagnosticsLog.instance.add(
              'http:${policy.name}',
              'retrying HTTP ${resp.statusCode} attempt=2 url=${redactUrl(uri)}',
            );
            return null;
          },
        );
        if (bytes != null) return bytes;
      } catch (error) {
        if (_disposed || generation != _parseGeneration) {
          throw const LoadCancelledException();
        }
        if (attempt >= 2 || !isTransientNetworkError(error)) rethrow;
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
    headers: {HttpHeaders.userAgentHeader: ?userAgent},
    token: token,
  );
}

/// Result of parsing a playlist, sent back from the parse isolate.
class M3uParsed {
  final List<Channel> channels;
  final List<Category> categories;
  final String? headerEpgUrl;
  final CatchupCapability catchupCapability;
  final int rejectedRows;
  final M3uMediaCatalog media;
  const M3uParsed(
    this.channels,
    this.categories,
    this.headerEpgUrl, [
    this.catchupCapability = CatchupCapability.unsupported,
    this.rejectedRows = 0,
    this.media = const M3uMediaCatalog(),
  ]);
}

/// Isolate entrypoint: decodes [bytes] and parses the playlist. Kept top-level
/// and pure so it can run under [compute] (no access to instance state).
M3uParsed _parseM3uBytes(Uint8List bytes) =>
    parseM3uPlaylist(utf8.decode(bytes, allowMalformed: true));

/// Parses an extended M3U playlist. Public only for tests — production code
/// goes through [M3uSource], which runs this on a background isolate.
@visibleForTesting
M3uParsed parseM3uPlaylist(String content) {
  final channels = <Channel>[];
  final categoryTitles = <String>{};
  final mediaBuilder = M3uMediaBuilder();
  String? headerEpgUrl;
  CatchupCapability capability = CatchupCapability.unsupported;

  String? name, group, logo, tvgId;
  String? mediaType;
  var isMedia = false, isRadio = false;
  String? entryUserAgent, entryReferer;
  String? headerCatchupSource;
  var headerCatchupDays = 0;
  String? catchupSource;
  var catchupDays = 0;
  var rejectedRows = 0;
  var hasPlaylistMarker = false;

  for (final raw in const LineSplitter().convert(
    content.replaceFirst(RegExp(r'^\uFEFF'), ''),
  )) {
    final line = raw.trim();
    if (line.isEmpty) continue;

    if (line.startsWith('#EXTM3U')) {
      hasPlaylistMarker = true;
      headerEpgUrl = _headerEpgAttribute(line);
      final catchup = _attr(line, 'catchup')?.toLowerCase();
      final days = int.tryParse(_attr(line, 'catchup-days') ?? '');
      headerCatchupSource = _attr(line, 'catchup-source');
      headerCatchupDays = days ?? 0;
      if (headerCatchupSource != null && catchup != 'none') {
        capability = CatchupCapability(
          mode: CatchupUrlMode.m3uTemplate,
          maxArchiveWindow: days == null ? null : Duration(days: days),
          template: headerCatchupSource,
        );
      }
      continue;
    }
    if (line.startsWith('#EXTINF')) {
      hasPlaylistMarker = true;
      if (name != null) entryUserAgent = entryReferer = null;
      tvgId = _attr(line, 'tvg-id');
      logo = _attr(line, 'tvg-logo');
      group = _attr(line, 'group-title');
      name = _name(line);
      mediaType = _attr(line, 'stream-type') ?? _attr(line, 'media-type') ?? _attr(line, 'type');
      isMedia = _attr(line, 'media')?.toLowerCase() == 'true' ||
          _attr(line, 'media-dir') != null || _attr(line, 'media-size') != null;
      isRadio = _attr(line, 'radio')?.toLowerCase() == 'true';
      final entryMode = _attr(line, 'catchup')?.toLowerCase();
      catchupSource = entryMode == 'none'
          ? null
          : (_attr(line, 'catchup-source') ?? headerCatchupSource);
      catchupDays =
          int.tryParse(_attr(line, 'catchup-days') ?? '') ?? headerCatchupDays;
      if (catchupSource != null) {
        final window = catchupDays > 0 ? Duration(days: catchupDays) : null;
        if (!capability.supported ||
            (window != null &&
                (capability.maxArchiveWindow == null ||
                    window > capability.maxArchiveWindow!))) {
          capability = CatchupCapability(
            mode: CatchupUrlMode.m3uTemplate,
            maxArchiveWindow: window,
            template: catchupSource,
          );
        }
      }
      continue;
    }
    if (line.startsWith('#EXTGRP:')) {
      if (name != null && (group == null || group.isEmpty)) group = line.substring(8).trim();
      continue;
    }
    if (line.startsWith('#EXT-X-PLAYLIST-TYPE:')) {
      if (name != null && line.substring(21).trim().toUpperCase() == 'VOD') isMedia = true;
      continue;
    }
    if (line.startsWith('#EXTVLCOPT:')) {
      final option = line.substring('#EXTVLCOPT:'.length);
      final separator = option.indexOf('=');
      if (separator > 0) {
        final key = option.substring(0, separator).trim().toLowerCase();
        final value = option.substring(separator + 1).trim();
        if (value.isNotEmpty && !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
          if (key == 'http-user-agent') entryUserAgent = value;
          if (key == 'http-referrer' || key == 'http-referer') entryReferer = value;
        }
      }
      continue;
    }
    if (line.startsWith('#')) continue;

    // A URL line completes the pending channel.
    if (name != null) {
      final g = (group == null || group.isEmpty) ? 'Uncategorized' : group;
      final entry = Channel(
          // The stream URL is the only per-entry unique key. tvg-id must NOT
          // be the id: playlists commonly reuse one tvg-id across quality
          // variants (HD/FHD/4K of the same channel), and the SQLite cache's
          // (source_id, id) primary key would silently drop all but one.
          // tvg-id stays in extra for the XMLTV EPG mapping.
          id: stableM3uChannelId(line),
          name: name,
          number: channels.length + 1,
          logo: (logo != null && logo.isNotEmpty) ? logo : null,
          categoryId: g,
          archiveDays: catchupSource == null
              ? 0
              : (catchupDays > 0 ? catchupDays : kDefaultArchiveDays),
          extra: {
            'url': line,
            'streamUserAgent': ?entryUserAgent,
            'streamReferer': ?entryReferer,
            if (tvgId != null && tvgId.isNotEmpty) 'tvgId': tvgId,
            ...?catchupSource == null
                ? null
                : <String, dynamic>{'catchupSource': catchupSource},
          },
        );
      if (!mediaBuilder.add(entry, mediaType: mediaType, media: isMedia, radio: isRadio)) {
        categoryTitles.add(g);
        channels.add(entry);
      }
      name = group = logo = tvgId = catchupSource = null;
      entryUserAgent = entryReferer = null;
      catchupDays = 0;
    }
  }
  if (!hasPlaylistMarker) {
    throw const FormatException('Invalid M3U playlist response');
  }
  if (name != null) rejectedRows++;

  final categories = (categoryTitles.toList()..sort())
      .map((t) => Category(id: t, title: t))
      .toList();
  return M3uParsed(
    channels,
    categories,
    headerEpgUrl,
    capability,
    rejectedRows,
    mediaBuilder.build(),
  );
}

String? _attr(String line, String key) =>
    RegExp('$key="([^"]*)"').firstMatch(line)?.group(1);

String? _headerEpgAttribute(String line) {
  final matches = RegExp(
    r'''(?:^|\s)(url-tvg|x-tvg-url|tvg-url)\s*=\s*(?:"([^"]*)"|'([^']*)')(?=\s|$)''',
    caseSensitive: false,
  ).allMatches(line).toList();
  final values = <String>{};
  for (final key in const ['url-tvg', 'x-tvg-url', 'tvg-url']) {
    for (final match in matches) {
      if (match[1]!.toLowerCase() != key) continue;
      final value = (match[2] ?? match[3]!).trim();
      if (value.isNotEmpty) values.add(value);
    }
  }
  return values.isEmpty ? null : values.join(',');
}

String _name(String extinf) {
  final lastQuote = extinf.lastIndexOf('"');
  final comma = extinf.indexOf(',', lastQuote == -1 ? 0 : lastQuote);
  return comma == -1 ? '' : extinf.substring(comma + 1).trim();
}
