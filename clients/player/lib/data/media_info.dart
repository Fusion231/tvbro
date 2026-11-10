import '../sources/source.dart';

class MediaCastMember {
  final String name;
  final String? role;
  final String? photoUrl;

  const MediaCastMember({required this.name, this.role, this.photoUrl});
}

/// Displayable details from provider data and already cached external metadata.
class MediaInfo {
  final List<MediaCastMember> cast;
  final List<String> directors;
  final List<String> creators;
  final List<String> genres;
  final List<String> countries;
  final String? originalTitle;
  final String? releaseDate;
  final int? durationSeconds;

  const MediaInfo._({
    required this.cast,
    required this.directors,
    required this.creators,
    required this.genres,
    required this.countries,
    this.originalTitle,
    this.releaseDate,
    this.durationSeconds,
  });

  factory MediaInfo.fromItem(MediaItem item) {
    final fields = _fields(item.extra).toList();
    final cast = <String, String>{};
    final roles = <String, List<String>>{};
    final photos = <String, String>{};
    for (final map in fields) {
      final credits = map['credits'];
      for (final value in [
        map['cast'],
        map['actors'],
        if (credits is Map) credits['cast'],
      ]) {
        for (final member in _cast(value)) {
          final key = member.name.toLowerCase();
          cast.putIfAbsent(key, () => member.name);
          final photoUrl = member.photoUrl;
          if (photoUrl != null) photos.putIfAbsent(key, () => photoUrl);
          final knownRoles = roles.putIfAbsent(key, () => []);
          final role = member.role;
          if (role != null &&
              !knownRoles.any(
                (value) => value.toLowerCase() == role.toLowerCase(),
              )) {
            knownRoles.add(role);
          }
        }
      }
    }
    return MediaInfo._(
      cast: [
        for (final entry in cast.entries)
          MediaCastMember(
            name: entry.value,
            role: roles[entry.key]!.isEmpty
                ? null
                : roles[entry.key]!.join(', '),
            photoUrl: photos[entry.key],
          ),
      ],
      directors: _firstList(fields, (map) sync* {
        yield* _names(map['director']);
        yield* _names(map['directors']);
        final credits = map['credits'];
        final crew = credits is Map ? credits['crew'] : null;
        if (crew is List) {
          for (final member in crew.whereType<Map>()) {
            if (_text(member['job'])?.toLowerCase() == 'director') {
              yield* _names(member);
            }
          }
        }
      }),
      creators: _firstList(fields, (map) sync* {
        yield* _names(map['created_by']);
        yield* _names(map['creator']);
        yield* _names(map['creators']);
      }),
      genres: _firstList(fields, (map) sync* {
        yield* _names(map['genre']);
        yield* _names(map['genres']);
      }),
      countries: _firstList(fields, (map) sync* {
        yield* _names(map['country']);
        yield* _names(map['countries']);
        yield* _names(map['production_countries']);
        yield* _names(map['origin_country']);
      }),
      originalTitle: _firstText(fields, const [
        'original_title',
        'original_name',
        'o_name',
      ]),
      releaseDate: _firstText(fields, const [
        'releasedate',
        'release_date',
        'releaseDate',
        'first_air_date',
        'released',
      ]),
      durationSeconds:
          _firstDuration(fields) ??
          (item.durationSeconds != null && item.durationSeconds! > 0
              ? item.durationSeconds
              : null),
    );
  }
}

// Deliberately inspect only known containers, never episode lists or other maps.
Iterable<Map> _fields(Map<String, dynamic> extra) sync* {
  final details = extra['details'];
  if (details is Map) {
    final info = details['info'];
    if (info is Map) yield info;
    yield details;
  }
  yield extra;
  final metadata = extra['metadata'];
  if (metadata is Map) {
    for (final provider in const ['tmdb', 'tvdb', 'tvmaze']) {
      final payload = metadata[provider];
      if (payload is Map) yield payload;
    }
  }
}

String? _text(Object? value) {
  if (value is! String) return null;
  final text = value.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (const {
        '',
        '-',
        '--',
        '0',
        'null',
        'none',
        'n/a',
        'unknown',
      }.contains(text.toLowerCase()) ||
      text.startsWith('{') ||
      text.startsWith('[')) {
    return null;
  }
  return text;
}

Iterable<String> _names(Object? value) sync* {
  if (value is List) {
    for (final entry in value) {
      yield* _names(entry);
    }
  } else if (value is Map) {
    final name = _text(value['name']) ?? _text(value['iso_3166_1']);
    if (name != null && !RegExp(r'^\d+$').hasMatch(name)) yield name;
  } else {
    if (value is! String || _text(value) == null) return;
    for (final part in value.split(RegExp(r'[,;/\n]'))) {
      final name = _text(part);
      if (name != null && !RegExp(r'^\d+$').hasMatch(name)) yield name;
    }
  }
}

Iterable<MediaCastMember> _cast(Object? value) sync* {
  if (value is List) {
    for (final entry in value) {
      yield* _cast(entry);
    }
  } else if (value is Map) {
    final name = _text(value['name']);
    if (name != null && !RegExp(r'^\d+$').hasMatch(name)) {
      yield MediaCastMember(
        name: name,
        role: _text(value['character']),
        photoUrl: _castPhoto(value),
      );
    }
  } else {
    for (final name in _names(value)) {
      yield MediaCastMember(name: name);
    }
  }
}

String? _castPhoto(Map member) {
  for (final key in const ['profile_path', 'photo_url', 'image']) {
    final value = _text(member[key]);
    if (value == null) continue;
    if (key == 'profile_path' &&
        value.startsWith('/') &&
        !value.startsWith('//')) {
      return 'https://image.tmdb.org/t/p/w185$value';
    }
    final uri = Uri.tryParse(value);
    if (uri != null &&
        (uri.scheme == 'https' || uri.scheme == 'http') &&
        uri.host.isNotEmpty) {
      return value;
    }
  }
  return null;
}

List<String> _firstList(List<Map> fields, Iterable<String> Function(Map) read) {
  for (final map in fields) {
    final seen = <String>{};
    final values = [
      for (final name in read(map))
        if (seen.add(name.toLowerCase())) name,
    ];
    if (values.isNotEmpty) return values;
  }
  return const [];
}

String? _firstText(List<Map> fields, List<String> keys) {
  for (final map in fields) {
    for (final key in keys) {
      final value = _text(map[key]);
      if (value != null) return value;
    }
  }
  return null;
}

int? _firstDuration(List<Map> fields) {
  for (final map in fields) {
    for (final key in const ['duration_secs', 'duration_seconds', 'duration']) {
      final seconds = _duration(map[key]);
      if (seconds != null) return seconds;
    }
    final runtime = _duration(map['runtime'], minutes: true);
    if (runtime != null) return runtime;
    final episodes = map['episode_run_time'];
    if (episodes is List) {
      for (final value in episodes) {
        final seconds = _duration(value, minutes: true);
        if (seconds != null) return seconds;
      }
    }
  }
  return null;
}

int? _duration(Object? value, {bool minutes = false}) {
  final text = value is num ? value.toString() : _text(value);
  if (text == null) return null;
  final numeric = num.tryParse(text);
  if (numeric != null && numeric.isFinite) {
    final seconds = (numeric * (minutes ? 60 : 1)).round();
    return seconds > 0 ? seconds : null;
  }
  if (minutes) return null;
  final parts = text.split(':');
  if (parts.length != 2 && parts.length != 3) return null;
  final numbers = parts.map(int.tryParse).toList();
  if (numbers.any((part) => part == null || part < 0) ||
      numbers.skip(1).any((part) => part! >= 60)) {
    return null;
  }
  final seconds = numbers.fold<int>(0, (total, part) => total * 60 + part!);
  return seconds > 0 ? seconds : null;
}
