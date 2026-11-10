import 'dart:convert';
import 'dart:io';

import '../sources/source.dart';
import 'metadata_provider.dart';
import 'net.dart';

/// Public, keyless series metadata. Payloads retain their source URL and
/// CC BY-SA attribution; TVmaze IDs never share the TMDB/TVDB ID namespace.
class TvmazeClient extends MetadataProvider {
  TvmazeClient({
    HttpClient? http,
    this.requestInterval = const Duration(milliseconds: 550),
    this.retryDelay = const Duration(seconds: 2),
  }) : _http =
           http ??
           (HttpClient()
             ..connectionTimeout = const Duration(seconds: 15)
             ..idleTimeout = const Duration(seconds: 5)
             ..maxConnectionsPerHost = 1
             ..autoUncompress = false);

  final HttpClient _http;
  final Duration requestInterval;
  final Duration retryDelay;
  Future<void> _queue = Future.value();
  DateTime _nextRequest = DateTime.fromMillisecondsSinceEpoch(0);
  bool _closed = false;

  @override
  String get provider => 'tvmaze';

  @override
  String get authMode => 'public';

  @override
  Future<ExternalMetadata?> search(MediaItem item) async {
    if (item.kind != ContentKind.series) return null;
    final cached = item.extra['metadata'];
    final own = cached is Map ? cached[provider] : null;
    final ownId = own is Map ? _id(own['id']) : null;
    if (ownId != null) {
      final details = await _get('/shows/$ownId', {'embed': 'cast'});
      if (details is Map) return _map(details, item);
    }
    final title = item.title
        .replaceAll(RegExp(r'^[A-Z]{2,4}\s*[-|:]\s*'), '')
        .replaceAll(RegExp(r'\[[^\]]*\]|\([^)]*\)'), ' ')
        .replaceAll(
          RegExp(r'\b(4k|uhd|fhd|hd|sd)\b', caseSensitive: false),
          ' ',
        )
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (title.isEmpty) return null;
    final results = await _get('/search/shows', {'q': title});
    Map? best;
    var bestScore = 0.0;
    final target = _normalize(title);
    for (final entry in results is List ? results.whereType<Map>() : <Map>[]) {
      final show = entry['show'];
      if (show is! Map || _id(show['id']) == null) continue;
      final name = _normalize(_text(show['name']) ?? '');
      if (name.isEmpty) continue;
      final left = target.split(' ').toSet();
      final right = name.split(' ').toSet();
      var score = target == name
          ? 1.0
          : left.intersection(right).length / left.union(right).length;
      final year = _year(show['premiered']);
      if (item.year != null && year != null) {
        score += _year(item.year) == year ? 0.2 : -0.2;
      }
      if (score > bestScore) {
        best = show;
        bestScore = score;
      }
    }
    if (best == null || bestScore < 0.62) return null;
    try {
      final details = await _get('/shows/${best['id']}', {'embed': 'cast'});
      if (details is Map) return _map(details, item);
    } catch (_) {
      // Keep the matched synopsis when the optional cast request fails.
    }
    return _map(best, item);
  }

  Future<dynamic> _get(String path, [Map<String, String> query = const {}]) {
    final operation = _queue.then((_) async {
      for (var attempt = 0; attempt < 2; attempt++) {
        if (_closed) throw StateError('TVmaze client closed');
        final wait = _nextRequest.difference(DateTime.now());
        if (wait > Duration.zero) await Future<void>.delayed(wait);
        if (_closed) throw StateError('TVmaze client closed');
        _nextRequest = DateTime.now().add(requestInterval);
        final operation = HttpOperation(kMetadataJsonWorkload);
        final request = await operation.wait(
          _http.getUrl(Uri.https('api.tvmaze.com', path, query)),
        );
        request.headers.set(HttpHeaders.userAgentHeader, 'TVBro');
        final response = await operation.wait(request.close());
        final bytes = await operation.readBytes(response);
        if (response.statusCode == HttpStatus.notFound) return null;
        if (response.statusCode == HttpStatus.tooManyRequests && attempt == 0) {
          await Future<void>.delayed(retryDelay);
          continue;
        }
        if (response.statusCode != HttpStatus.ok) {
          throw StateError('TVmaze HTTP ${response.statusCode}');
        }
        return jsonDecode(utf8.decode(bytes, allowMalformed: true));
      }
      return null;
    });
    _queue = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return operation;
  }

  ExternalMetadata _map(Map data, MediaItem item) {
    final id = _id(data['id'])!;
    final embedded = data['_embedded'];
    final cast = embedded is Map ? embedded['cast'] : null;
    final network = data['network'] ?? data['webChannel'];
    final country = network is Map ? network['country'] : null;
    final rating = data['rating'];
    return ExternalMetadata(
      provider: provider,
      providerKey: id,
      title: _text(data['name']),
      overview: _summary(data['summary']),
      poster: _image(data['image']),
      year: _year(data['premiered']) ?? item.year,
      rating: rating is Map && rating['average'] is num
          ? (rating['average'] as num).toDouble()
          : null,
      payload: {
        ...Map<String, dynamic>.from(data),
        'attribution_url': 'https://www.tvmaze.com/shows/$id',
        'license_url': 'https://creativecommons.org/licenses/by-sa/4.0/',
        'overview': _summary(data['summary']),
        'runtime': data['runtime'] ?? data['averageRuntime'],
        'first_air_date': data['premiered'],
        if (country is Map) 'country': country['name'],
        if (cast is List)
          'credits': {
            'cast': [
              for (final row in cast.whereType<Map>())
                if (row['person'] is Map)
                  {
                    'name': row['person']['name'],
                    'character': row['character'] is Map
                        ? row['character']['name']
                        : null,
                    'photo_url': _image(row['person']['image']),
                  },
            ],
          },
      },
      refreshedAt: DateTime.now(),
    );
  }

  String? _id(Object? value) {
    final number = int.tryParse('$value');
    return number != null && number > 0 ? '$number' : null;
  }

  String? _text(Object? value) =>
      value is String && value.trim().isNotEmpty ? value.trim() : null;
  String? _year(Object? value) => RegExp(r'^\d{4}').stringMatch('$value');
  String? _image(Object? value) =>
      value is Map ? _text(value['medium']) ?? _text(value['original']) : null;
  String _normalize(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
      .trim();

  String? _summary(Object? value) {
    var text = _text(value);
    if (text == null) return null;
    text = text.replaceAll(RegExp(r'<[^>]*>'), ' ');
    text = text.replaceAllMapped(
      RegExp(
        r'&(#x[0-9a-f]+|#\d+|amp|lt|gt|quot|apos|nbsp);',
        caseSensitive: false,
      ),
      (match) {
        final entity = match[1]!.toLowerCase();
        const named = {
          'amp': '&',
          'lt': '<',
          'gt': '>',
          'quot': '"',
          'apos': "'",
          'nbsp': ' ',
        };
        if (named.containsKey(entity)) return named[entity]!;
        final code = entity.startsWith('#x')
            ? int.tryParse(entity.substring(2), radix: 16)
            : int.tryParse(entity.substring(1));
        return code != null &&
                code > 0 &&
                code <= 0x10ffff &&
                (code < 0xd800 || code > 0xdfff)
            ? String.fromCharCode(code)
            : '';
      },
    );
    return _text(text.replaceAll(RegExp(r'\s+'), ' '));
  }

  @override
  void close() {
    _closed = true;
    _http.close(force: true);
  }
}
