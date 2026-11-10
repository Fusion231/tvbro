import 'dvr_models.dart';

class HlsByteRange {
  const HlsByteRange(this.length, this.offset);
  final int length;
  final int offset;
}

class HlsKey {
  const HlsKey(this.uri, this.iv);
  final Uri uri;
  final String? iv;
}

class HlsMap {
  const HlsMap(this.uri, this.range);
  final Uri uri;
  final HlsByteRange? range;
}

class HlsSegment {
  const HlsSegment({
    required this.uri,
    required this.sequence,
    required this.duration,
    required this.discontinuitySequence,
    this.discontinuity = false,
    this.range,
    this.key,
    this.map,
  });

  final Uri uri;
  final int sequence;
  final Duration duration;
  final bool discontinuity;
  final int discontinuitySequence;
  final HlsByteRange? range;
  final HlsKey? key;
  final HlsMap? map;
}

class HlsPlaylist {
  const HlsPlaylist({
    required this.segments,
    required this.targetDuration,
    required this.ended,
    this.variant,
  });

  final List<HlsSegment> segments;
  final Duration targetDuration;
  final bool ended;
  final Uri? variant;

  /// Only standard, complete segments are captured. Low-latency PARTs are
  /// intentionally ignored until the server publishes their complete segment.
  factory HlsPlaylist.parse(String source, Uri base) {
    final lines = source.trimLeft().replaceFirst('\uFEFF', '').split('\n');
    if (lines.isEmpty || lines.first.trim() != '#EXTM3U') {
      throw const DvrException('The provider did not return an HLS playlist.');
    }
    if (lines.length > 20000) {
      throw const DvrException('The HLS playlist is too large to record.');
    }
    final externalAudio = <String>{};
    for (final raw in lines) {
      final line = raw.trim();
      if (line.startsWith('#EXT-X-MEDIA:')) {
        final attrs = hlsAttributes(line.substring(13));
        if (attrs['TYPE'] == 'AUDIO' && attrs.containsKey('URI')) {
          externalAudio.add(attrs['GROUP-ID'] ?? '');
        }
      }
    }
    final variants = <({Uri uri, int bandwidth})>[];
    Map<String, String>? variantAttrs;
    var sequence = 0;
    var discontinuitySequence = 0;
    var target = const Duration(seconds: 6);
    var ended = false;
    Duration? duration;
    HlsByteRange? range;
    HlsKey? key;
    HlsMap? map;
    var discontinuity = false;
    var lastRangeEnd = 0;
    Uri? lastRangeUri;
    String? pendingRange;
    final segments = <HlsSegment>[];
    for (final raw in lines.skip(1)) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#EXT-X-STREAM-INF:')) {
        variantAttrs = hlsAttributes(line.substring(18));
      } else if (line.startsWith('#EXT-X-MEDIA-SEQUENCE:')) {
        sequence = _positiveInt(line.substring(22), allowZero: true);
      } else if (line.startsWith('#EXT-X-DISCONTINUITY-SEQUENCE:')) {
        discontinuitySequence = _positiveInt(
          line.substring(30),
          allowZero: true,
        );
      } else if (line.startsWith('#EXT-X-TARGETDURATION:')) {
        target = Duration(seconds: _positiveInt(line.substring(22)));
      } else if (line.startsWith('#EXTINF:')) {
        final seconds = double.tryParse(line.substring(8).split(',').first);
        if (seconds == null ||
            !seconds.isFinite ||
            seconds <= 0 ||
            seconds > 3600) {
          throw const DvrException('The HLS segment duration is invalid.');
        }
        duration = Duration(microseconds: (seconds * 1000000).round());
      } else if (line == '#EXT-X-DISCONTINUITY') {
        discontinuity = true;
        discontinuitySequence++;
      } else if (line.startsWith('#EXT-X-BYTERANGE:')) {
        pendingRange = line.substring(17);
      } else if (line.startsWith('#EXT-X-KEY:')) {
        final attrs = hlsAttributes(line.substring(11));
        if (attrs['METHOD'] == 'NONE') {
          key = null;
        } else if (attrs['METHOD'] == 'AES-128' &&
            (attrs['KEYFORMAT'] == null || attrs['KEYFORMAT'] == 'identity')) {
          final iv = attrs['IV'];
          if (iv != null && !RegExp(r'^0[xX][a-fA-F0-9]{1,32}$').hasMatch(iv)) {
            throw const DvrException('The HLS encryption IV is invalid.');
          }
          key = HlsKey(_resolve(base, attrs['URI']), iv);
        } else {
          throw const DvrException(
            'This DRM or HLS encryption format cannot be recorded locally.',
          );
        }
      } else if (line.startsWith('#EXT-X-MAP:')) {
        if (key != null) {
          throw const DvrException(
            'Encrypted HLS init segments are not supported for local recording.',
          );
        }
        final attrs = hlsAttributes(line.substring(11));
        map = HlsMap(
          _resolve(base, attrs['URI']),
          attrs['BYTERANGE'] == null ? null : _range(attrs['BYTERANGE']!, 0),
        );
      } else if (line == '#EXT-X-ENDLIST') {
        ended = true;
      } else if (line == '#EXT-X-GAP' || line.startsWith('#EXT-X-SKIP:')) {
        throw const DvrException(
          'The provider HLS playlist contains a media gap.',
        );
      } else if (!line.startsWith('#')) {
        final uri = _resolve(base, line);
        if (variantAttrs != null) {
          if (!externalAudio.contains(variantAttrs['AUDIO'])) {
            variants.add((
              uri: uri,
              bandwidth: int.tryParse(variantAttrs['BANDWIDTH'] ?? '') ?? 0,
            ));
          }
          variantAttrs = null;
          continue;
        }
        if (duration == null) continue;
        if (pendingRange != null) {
          if (!pendingRange.contains('@') && lastRangeUri != uri) {
            throw const DvrException('The HLS byte range has no valid offset.');
          }
          range = _range(pendingRange, lastRangeEnd);
          lastRangeEnd = range.offset + range.length;
          lastRangeUri = uri;
        } else {
          range = null;
          lastRangeUri = null;
        }
        segments.add(
          HlsSegment(
            uri: uri,
            sequence: sequence++,
            duration: duration,
            discontinuity: discontinuity,
            discontinuitySequence: discontinuitySequence,
            range: range,
            key: key,
            map: map,
          ),
        );
        duration = null;
        pendingRange = null;
        discontinuity = false;
      }
    }
    if (variants.isNotEmpty) {
      variants.sort((a, b) => b.bandwidth.compareTo(a.bandwidth));
      return HlsPlaylist(
        segments: const [],
        targetDuration: target,
        ended: false,
        variant: variants.first.uri,
      );
    }
    if (source.contains('#EXT-X-STREAM-INF:') && segments.isEmpty) {
      throw const DvrException(
        'HLS with a separate audio playlist is not supported for local recording.',
      );
    }
    return HlsPlaylist(
      segments: segments,
      targetDuration: target,
      ended: ended,
    );
  }
}

Map<String, String> hlsAttributes(String value) {
  final result = <String, String>{};
  final pattern = RegExp(r'([A-Z0-9-]+)=(?:"([^"]*)"|([^,]*))(?:,|$)');
  for (final match in pattern.allMatches(value)) {
    result[match[1]!] = match[2] ?? match[3]!;
  }
  return result;
}

HlsByteRange _range(String value, int previousEnd) {
  final parts = value.split('@');
  if (parts.length > 2) {
    throw const DvrException('The HLS byte range is invalid.');
  }
  return HlsByteRange(
    _positiveInt(parts.first),
    parts.length == 2 ? _positiveInt(parts[1], allowZero: true) : previousEnd,
  );
}

int _positiveInt(String value, {bool allowZero = false}) {
  final number = int.tryParse(value.trim());
  if (number == null || number < (allowZero ? 0 : 1) || number > (1 << 53)) {
    throw const DvrException('The HLS playlist contains an invalid number.');
  }
  return number;
}

Uri _resolve(Uri base, String? value) {
  Uri? uri;
  try {
    uri = value == null ? null : base.resolve(value);
  } on FormatException {
    throw const DvrException(
      'The HLS playlist contains an invalid resource URL.',
    );
  }
  if (uri == null ||
      !{'http', 'https'}.contains(uri.scheme) ||
      uri.host.isEmpty) {
    throw const DvrException(
      'The HLS playlist uses an unsupported resource URL.',
    );
  }
  return uri;
}
