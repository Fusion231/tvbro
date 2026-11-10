import '../sources/source.dart';

/// A provider-supplied trailer, without fetching any external metadata.
Uri? mediaTrailerLink(MediaItem item) {
  for (final fields in _trailerFields(item.extra)) {
    for (final key in const ['youtube_trailer', 'trailer_url', 'trailer']) {
      try {
        final uri = _trailerUri(fields[key]);
        if (uri != null) return uri;
      } on FormatException {
        // A URI can parse but still contain invalid UTF-8 in its video ID.
        continue;
      }
    }
  }
  return null;
}

/// Opens the known trailer or a YouTube search requiring no API credentials.
Uri mediaTrailerUri(MediaItem item) {
  final trailer = mediaTrailerLink(item);
  if (trailer != null) return trailer;

  final title = item.title.trim().replaceAll(RegExp(r'\s+'), ' ');
  final year = RegExp(r'\b[12]\d{3}\b').firstMatch(item.year ?? '')?.group(0);
  final query = [
    if (title.isNotEmpty) title,
    if (year != null && !title.contains(RegExp(r'\b' + year + r'\b'))) year,
    'zwiastun PL',
  ].join(' ');
  return Uri.https('www.youtube.com', '/results', {'search_query': query});
}

Iterable<Map> _trailerFields(Map<String, dynamic> extra) sync* {
  yield extra;
  final details = extra['details'];
  if (details is Map) {
    yield details;
    final info = details['info'];
    if (info is Map) yield info;
  }
  // LibraryRepository retains each metadata provider's original payload here.
  // Only examine known containers, never unrelated links or episode lists.
  final metadata = extra['metadata'];
  if (metadata is Map) {
    for (final provider in const ['tmdb', 'tvdb', 'mdblist']) {
      final payload = metadata[provider];
      if (payload is Map) yield payload;
    }
  }
}

final _youtubeId = RegExp(r'^[A-Za-z0-9_-]{11}$');

Uri? _trailerUri(Object? value) {
  if (value is! String) return null;
  var text = value.trim();
  if (text.isEmpty) return null;
  if (_youtubeId.hasMatch(text)) return _youtubeWatchUri(text);
  // Some panels omit the scheme on an otherwise ordinary YouTube link.
  if (RegExp(
    r'^(?:(?:www|m)\.)?(?:youtube\.com|youtu\.be)/',
    caseSensitive: false,
  ).hasMatch(text)) {
    text = 'https://$text';
  }
  if (RegExp(r'\s').hasMatch(text)) return null;
  final uri = Uri.tryParse(text);
  if (uri == null ||
      (uri.scheme != 'https' && uri.scheme != 'http') ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return null;
  }

  final host = uri.host.toLowerCase();
  final segments = uri.pathSegments;
  String? id;
  if (host == 'youtu.be' || host == 'www.youtu.be') {
    if (segments.length == 1) id = segments.first;
  } else if (const {
    'youtube.com',
    'www.youtube.com',
    'm.youtube.com',
    'youtube-nocookie.com',
    'www.youtube-nocookie.com',
  }.contains(host)) {
    if (uri.path == '/watch') {
      id = uri.queryParameters['v'];
    } else if (segments.length == 2 &&
        const ['embed', 'shorts', 'live', 'v'].contains(segments.first)) {
      id = segments[1];
    }
  } else {
    return uri;
  }
  return id != null && _youtubeId.hasMatch(id) ? _youtubeWatchUri(id) : null;
}

Uri _youtubeWatchUri(String id) =>
    Uri.https('www.youtube.com', '/watch', {'v': id});
