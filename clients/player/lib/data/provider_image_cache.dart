import 'dart:io';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import 'net.dart';

/// Preserve the existing artwork disk cache and shared provider cooldowns.
/// Android artwork has its own download queue so it cannot delay API requests.
final providerImageCache = _ProviderImageCache();

void configureProviderImages() {
  CachedNetworkImageProvider.defaultCacheManager = providerImageCache;
}

Future<String?> loadCachedArtworkPath(
  String url, {
  void Function()? checkCancellation,
}) async {
  checkCancellation?.call();
  final File file;
  try {
    file = await providerImageCache.getSingleFile(url);
  } catch (_) {
    // Match Flutter artwork: a failed revalidation must not hide a usable file.
    final cached = await providerImageCache.getFileFromCache(url);
    if (cached == null || !await cached.file.exists()) rethrow;
    checkCancellation?.call();
    return cached.file.path;
  }
  checkCancellation?.call();
  return file.path;
}

class _ProviderImageCache extends CacheManager with ImageCacheManager {
  _ProviderImageCache()
    : super(
        Config(
          DefaultCacheManager.key,
          fileService: ProviderImageFileService(),
        ),
      );
}

const _imageWorkload = HttpWorkloadPolicy(
  name: 'artwork',
  maximumBodyBytes: 6 * 1024 * 1024,
  maximumDecodedBytes: 6 * 1024 * 1024,
  totalTimeout: Duration(seconds: 30),
  idleTimeout: Duration(seconds: 10),
);

class ProviderImageFileService extends FileService {
  ProviderImageFileService({HttpClient? client})
    : _client =
          client ??
          (HttpClient()..connectionTimeout = const Duration(seconds: 10)) {
    concurrentFetches = _androidArtwork ? 12 : 2;
    _artworkRefusals = ProviderRequestGate(
      minimumStartGap: Duration.zero,
      maximumConcurrentRequests: concurrentFetches,
    );
  }

  final HttpClient _client;
  final bool _androidArtwork = defaultTargetPlatform == TargetPlatform.android;
  // A refused poster must not block playback, but scrolling must not keep
  // requesting hundreds of other refused posters on the same image host.
  late final ProviderRequestGate _artworkRefusals;
  final _failures = <String, ({DateTime until, Object error})>{};

  @override
  Future<FileServiceResponse> get(
    String url, {
    Map<String, String>? headers,
  }) async {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw const HttpWorkloadException('Invalid artwork address');
    }
    ProviderRequestGate.instance.check(uri);
    _artworkRefusals.check(uri);
    final failed = _failures[url];
    if (failed != null && failed.until.isAfter(DateTime.now())) {
      throw failed.error;
    }
    final operation = HttpOperation(_imageWorkload);
    var responseUri = uri;
    try {
      return await providerHttpGet<FileServiceResponse>(
        uri,
        client: _client,
        operation: operation,
        headers: headers ?? const {},
        admissionGate: _androidArtwork ? _artworkRefusals : null,
        pauseOnAuthenticationFailure: false,
        onResponseUri: (value) => responseUri = value,
        checkCancellation: () => _artworkRefusals.check(uri),
        readResponse: (response) async {
          if (response.statusCode == HttpStatus.unauthorized) {
            _artworkRefusals.recordResponse(
              uri, response.statusCode,
              retryAfter: response.headers.value(HttpHeaders.retryAfterHeader),
            );
            _artworkRefusals.recordResponse(
              responseUri, response.statusCode,
              retryAfter: response.headers.value(HttpHeaders.retryAfterHeader),
            );
            await operation.wait(response.take(0).drain<void>());
            _artworkRefusals.check(uri);
          }
          if (response.statusCode != HttpStatus.ok &&
              response.statusCode != HttpStatus.accepted &&
              response.statusCode != HttpStatus.notModified) {
            await operation.wait(response.take(0).drain<void>());
            throw HttpWorkloadException('Artwork HTTP ${response.statusCode}');
          }
          final bytes = response.statusCode == HttpStatus.notModified
              ? Uint8List(0)
              : await operation.readBytes(response);
          if (response.statusCode == HttpStatus.notModified) {
            await operation.wait(response.take(0).drain<void>());
          }
          return _ImageResponse(response, bytes);
        },
      );
    } catch (error) {
      // Broken logos otherwise get fetched every time their tile re-enters the
      // viewport. HTTP 403 stays retryable, including for the same image URL.
      if (providerHttpRefusalStatus(error) == HttpStatus.forbidden) rethrow;
      _failures.remove(url);
      _failures[url] = (
        until: DateTime.now().add(const Duration(minutes: 1)),
        error: error,
      );
      if (_failures.length > 256) _failures.remove(_failures.keys.first);
      rethrow;
    }
  }

  void close() => _client.close(force: true);
}

class _ImageResponse implements FileServiceResponse {
  _ImageResponse(HttpClientResponse response, this._bytes)
    : statusCode = response.statusCode,
      eTag = response.headers.value(HttpHeaders.etagHeader),
      _contentType = response.headers.contentType?.mimeType,
      validTill = _validTill(
        response.headers.value(HttpHeaders.cacheControlHeader),
      );

  final Uint8List _bytes;
  final String? _contentType;
  @override
  final int statusCode;
  @override
  final String? eTag;
  @override
  final DateTime validTill;
  @override
  int get contentLength => _bytes.length;
  @override
  Stream<List<int>> get content => Stream.value(_bytes);
  @override
  String get fileExtension => switch (_contentType) {
    'image/jpeg' => '.jpg',
    'image/png' => '.png',
    'image/webp' => '.webp',
    'image/gif' => '.gif',
    'image/avif' => '.avif',
    'image/bmp' => '.bmp',
    _ => '',
  };

  static DateTime _validTill(String? cacheControl) {
    var age = const Duration(days: 7);
    for (final directive
        in cacheControl?.toLowerCase().split(',') ?? <String>[]) {
      final setting = directive.trim();
      if (setting == 'no-cache' || setting == 'no-store') {
        age = Duration.zero;
        break;
      }
      if (setting.startsWith('max-age=')) {
        final seconds = int.tryParse(setting.substring(8));
        if (seconds != null && seconds >= 0) age = Duration(seconds: seconds);
      }
    }
    return DateTime.now().add(age);
  }
}
