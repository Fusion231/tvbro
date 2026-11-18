import 'dart:convert';
import 'dart:io';

import '../sources/source.dart';
import 'media_info.dart';
import 'metadata_provider.dart';
import 'net.dart';

typedef _CommonsImage = ({String image, Map<String, String> credit});

class WikimediaClient extends MetadataProvider {
  WikimediaClient({
    String language = 'en',
    HttpClient? http,
    this.requestInterval = const Duration(milliseconds: 550),
  }) : language = language == 'pl' ? 'pl' : 'en',
       _http =
           http ??
           (HttpClient()
             ..connectionTimeout = const Duration(seconds: 10)
             ..autoUncompress = false);

  static const providerName = 'wikimedia';
  static const _wikidata = 'www.wikidata.org';
  static const _commons = 'commons.wikimedia.org';
  static final _entityId = RegExp(r'^Q[1-9]\d*$');
  static final _titleYear = RegExp(r'[\[(]((?:18|19|20)\d{2})[\])]\s*$');

  final String language;
  final HttpClient _http;
  final Duration requestInterval;
  Future<void> _queue = Future.value();
  DateTime _nextRequest = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? _retryAfter;
  bool _closed = false;

  @override
  String get provider => providerName;

  @override
  String get authMode => 'public';

  static bool needsMetadata(MediaItem item) {
    if (item.kind != ContentKind.movie) return false;
    final info = MediaInfo.fromItem(item);
    return isMissing(item.description) ||
        isMissing(item.poster) ||
        isMissing(item.year) ||
        info.durationSeconds == null ||
        info.cast.isEmpty ||
        info.cast.take(8).any((member) => member.photoUrl == null) ||
        info.directors.isEmpty ||
        info.genres.isEmpty;
  }

  static bool isMissing(String? value) =>
      value == null ||
      const {
        '',
        '-',
        '--',
        'null',
        'n/a',
        'unknown',
      }.contains(value.trim().toLowerCase());

  String _movieIdentity(MediaItem item) => jsonEncode([
    2,
    language,
    item.title,
    item.year,
    MediaInfo.fromItem(item).originalTitle,
    for (final (property, id) in _externalIds(item)) '$property=$id',
  ]);

  bool matchesCache(MediaItem item, ExternalMetadata cached) =>
      cached.payload['match_identity'] == _movieIdentity(item);

  @override
  Future<ExternalMetadata?> search(MediaItem item) async {
    if (!needsMetadata(item)) return null;
    final match = await _findFilm(item);
    if (match == null) return null;
    final (id, film) = match;
    final info = MediaInfo.fromItem(item);
    final titleYear = _year(item.year) ?? _titleYear.firstMatch(item.title)?[1];
    final dates = _dates(film).toList()..sort();
    final releaseDate =
        dates.where((date) => _year(date) == titleYear).firstOrNull ??
        dates.firstOrNull;
    final minutes = info.durationSeconds == null ? _minutes(film) : null;
    final overview = isMissing(item.description) ? await _extract(film) : null;
    final poster = isMissing(item.poster) ? await _poster(film) : null;
    final credits = await _credits(film, info);
    final year = isMissing(item.year) ? _year(releaseDate) : null;
    if (overview == null &&
        poster == null &&
        year == null &&
        minutes == null &&
        (info.releaseDate != null || releaseDate == null) &&
        credits.isEmpty) {
      return null;
    }
    return ExternalMetadata(
      provider: providerName,
      providerKey: id,
      overview: overview?.text,
      poster: poster?.image,
      year: year,
      payload: {
        'id': id,
        'match_identity': _movieIdentity(item),
        if (overview != null) 'wikipedia_url': overview.url,
        ...?poster?.credit,
        if (info.releaseDate == null && releaseDate != null)
          'release_date': releaseDate,
        'runtime': ?minutes,
        ...credits,
      },
      refreshedAt: DateTime.now(),
    );
  }

  static Iterable<(String, String)> _externalIds(MediaItem item) sync* {
    final details = _map(item.extra['details']);
    final fields = [
      _map(details['info']),
      _map(details['movie_data']),
      details,
      item.extra,
    ];
    for (final (property, keys, pattern) in [
      ('P345', ['imdb_id', 'imdbId', 'imdb'], RegExp(r'^tt\d{7,12}$')),
      ('P4947', ['tmdb_id', 'tmdbId'], RegExp(r'^[1-9]\d{0,9}$')),
    ]) {
      final externalId = [
        for (final map in fields)
          for (final key in keys) map[key]?.toString().trim(),
        if (property == 'P345') item.providerId?.trim(),
      ].whereType<String>().where(pattern.hasMatch).firstOrNull;
      if (externalId != null) yield (property, externalId);
    }
  }

  Future<(String, Map)?> _findFilm(MediaItem item) async {
    for (final (property, externalId) in _externalIds(item)) {
      final result = await _get(_wikidata, {
        'action': 'query',
        'list': 'search',
        'srsearch': 'haswbstatement:$property=$externalId',
        'srlimit': '8',
      });
      final ids = _rows(_map(result['query'])['search'])
          .map((row) => row['title']);
      final entities = await _entities(ids);
      final matched = entities.entries
          .where(
            (entry) =>
                _isFilm(entry.value) &&
                _claims(
                  entry.value,
                  property,
                ).any((value) => '$value' == externalId),
          )
          .toList();
      if (matched.length == 1) {
        return (matched.single.key, matched.single.value);
      }
    }

    final year = _year(item.year) ?? _titleYear.firstMatch(item.title)?[1];
    if (year == null) return null;
    final titles = {item.title, ?MediaInfo.fromItem(item).originalTitle};
    for (final raw in titles) {
      final matches = await _findByTitle(raw, year);
      if (matches.isNotEmpty) {
        return matches.length == 1
            ? (matches.single.key, matches.single.value)
            : null;
      }
    }
    return null;
  }

  Future<List<MapEntry<String, Map>>> _findByTitle(
    String raw,
    String year,
  ) async {
    final title = raw
        .replaceFirst(
          RegExp(r'^\s*[A-Z]{2,4}(?:\s+(?:4[Kk]|UHD|FHD|HD|SD))?\s*[-|:]\s*'),
          '',
        )
        .replaceFirst(_titleYear, '')
        .replaceAll(
          RegExp(
            r'\s*[\[(](?:4k|uhd|fhd|hd|sd|hdr)[\])]\s*',
            caseSensitive: false,
          ),
          ' ',
        )
        .trim();
    if (title.isEmpty || title.length > 180 || title.contains('://')) {
      return [];
    }
    for (final locale in {language, 'en'}) {
      final result = await _get(_wikidata, {
        'action': 'wbsearchentities',
        'search': title,
        'language': locale,
        'uselang': locale,
        'type': 'item',
        'limit': '8',
      });
      final entities = await _entities(
        _rows(result['search']).map((row) => row['id']),
      );
      final matches = entities.entries
          .where(
            (entry) =>
                _isFilm(entry.value) &&
                _titles(entry.value)
                    .any((value) => _normalize(value) == _normalize(title)) &&
                _dates(entry.value).any((date) => _year(date) == year),
          )
          .toList();
      if (matches.isNotEmpty) return matches;
    }
    return [];
  }

  Future<Map<String, Map>> _entities(
    Iterable<Object?> values, {
    bool creditsOnly = false,
  }) async {
    final ids = values.whereType<String>().where(_entityId.hasMatch).toSet();
    if (ids.isEmpty) return {};
    final result = await _get(_wikidata, {
      'action': 'wbgetentities',
      'ids': ids.join('|'),
      'languages': {language, 'en'}.join('|'),
      'props': creditsOnly
          ? 'labels|claims'
          : 'labels|aliases|claims|sitelinks',
      if (!creditsOnly)
        'sitefilter': {
          for (final locale in {language, 'en'}) '${locale}wiki',
        }.join('|'),
    });
    final entities = _map(result['entities']);
    return {
      for (final id in ids)
        if (entities[id] is Map) id: entities[id] as Map,
    };
  }

  Future<({String text, String url})?> _extract(Map film) async {
    for (final locale in {language, 'en'}) {
      final title = _text(
        _map(_map(film['sitelinks'])['${locale}wiki'])['title'],
      );
      if (title == null) continue;
      final host = '$locale.wikipedia.org';
      final result = await _optionalGet(host, {
        'action': 'query',
        'titles': title,
        'prop': 'extracts',
        'exintro': '1',
        'explaintext': '1',
        'exchars': '1000',
        'redirects': '1',
      });
      final page = _rows(_map(result['query'])['pages']).firstOrNull;
      final text = _text(page?['extract']);
      if (text != null) {
        final article = _text(page?['title']) ?? title;
        return (
          text: text,
          url: Uri.https(
            host,
            '/wiki/${article.replaceAll(' ', '_')}',
          ).toString(),
        );
      }
    }
    return null;
  }

  Future<_CommonsImage?> _poster(Map film) async {
    final filename = _claims(film, 'P3383').whereType<String>().firstOrNull;
    if (filename == null) return null;
    return (await _commonsImages([filename], width: 500))[_fileKey(filename)];
  }

  Future<Map<String, _CommonsImage>> _commonsImages(
    Iterable<String> filenames, {
    required int width,
  }) async {
    final files = filenames
        .where((name) => !name.contains('|'))
        .map(_fileKey)
        .where((name) => name.isNotEmpty)
        .toSet();
    if (files.isEmpty) return {};
    final result = await _optionalGet(_commons, {
      'action': 'query',
      'titles': files.map((name) => 'File:$name').join('|'),
      'prop': 'imageinfo',
      'iiprop': 'url|extmetadata',
      'iiurlwidth': '$width',
      'iiextmetadatafilter':
          'License|LicenseShortName|LicenseUrl|Artist|Attribution|Restrictions',
    });
    final images = <String, _CommonsImage>{};
    for (final page in _rows(_map(result['query'])['pages'])) {
      final title = _text(page['title']);
      if (title == null || !title.startsWith('File:')) continue;
      final name = _fileKey(title.substring(5));
      if (!files.contains(name)) continue;
      final image = _licensedImage(title, _rows(page['imageinfo']).firstOrNull);
      if (image != null) images[name] = image;
    }
    return images;
  }

  static String _fileKey(String name) {
    final trimmed = name.replaceAll('_', ' ').trim();
    if (trimmed.isEmpty) return '';
    return trimmed[0].toUpperCase() + trimmed.substring(1);
  }

  _CommonsImage? _licensedImage(String title, Map? image) {
    final fields = _map(image?['extmetadata']);
    String? field(String name) => _text(_map(fields[name])['value']);
    final license = field('License')?.toLowerCase();
    final thumb = Uri.tryParse(_text(image?['thumburl']) ?? '');
    final licenseUrl = Uri.tryParse(field('LicenseUrl') ?? '');
    final publicDomain = const {'pd', 'cc-zero'}.contains(license);
    final creativeCommons = RegExp(r'^cc-by(?:-sa)?-(?:2\.0|2\.5|3\.0|4\.0)$')
        .hasMatch(license ?? '');
    final artist = (field('Attribution') ?? field('Artist'))
        ?.replaceAll(RegExp(r'<[^>]*>'), '')
        .trim();
    final validLicenseLink =
        licenseUrl?.scheme == 'https' &&
        licenseUrl?.host == 'creativecommons.org';
    if (field('Restrictions') != null ||
        (!publicDomain &&
            !(creativeCommons && validLicenseLink && _text(artist) != null)) ||
        thumb?.scheme != 'https' ||
        !const {
          'upload.wikimedia.org',
          'thumb.wikimedia.org',
        }.contains(thumb?.host)) {
      return null;
    }
    return (
      image: thumb.toString(),
      credit: {
        'commons_url': Uri.https(
          _commons,
          '/wiki/${title.replaceAll(' ', '_')}',
        ).toString(),
        'commons_license': field('LicenseShortName') ?? license!,
        if (validLicenseLink) 'commons_license_url': licenseUrl.toString(),
        if (_text(artist) != null) 'commons_artist': artist!,
      },
    );
  }

  Future<Map<String, Object>> _credits(Map film, MediaInfo info) async {
    final missingPhotos = {
      for (final member in info.cast.take(8))
        if (member.photoUrl == null) member.name.toLowerCase(),
    };
    final castIds = info.cast.isEmpty || missingPhotos.isNotEmpty
        ? _claimIds(film, 'P161').take(8).toSet()
        : <String>{};
    final fields = {
      if (info.cast.isEmpty) 'cast': castIds,
      if (info.directors.isEmpty)
        'director': _claimIds(film, 'P57').take(4).toList(),
      if (info.genres.isEmpty)
        'genres': _claimIds(film, 'P136').take(4).toList(),
    };
    final Map<String, Map> entities;
    try {
      entities = await _entities([
        ...castIds,
        ...fields.values.expand((ids) => ids),
      ], creditsOnly: true);
    } catch (_) {
      return {};
    }
    final actorsByName = <String, List<Map>>{};
    for (final id in castIds) {
      final entity = entities[id];
      final name = _label(entity)?.toLowerCase();
      if (entity != null &&
          name != null &&
          (info.cast.isEmpty || missingPhotos.contains(name))) {
        actorsByName.putIfAbsent(name, () => []).add(entity);
      }
    }
    final photoFiles = {
      for (final actor in actorsByName.entries)
        if (actor.value.length == 1)
          actor.key: ?_claims(
            actor.value.single,
            'P18',
          ).whereType<String>().firstOrNull,
    };
    final images = await _commonsImages(photoFiles.values, width: 150);
    final photos = {
      for (final entry in photoFiles.entries)
        if (images[_fileKey(entry.value)] case final image?)
          entry.key: {'photo_url': image.image, ...image.credit},
    };
    return {
      for (final entry in fields.entries)
        if (entry.value.any(entities.containsKey))
          entry.key: [for (final id in entry.value) ?_label(entities[id])],
      if (photos.isNotEmpty) 'cast_photos': photos,
    };
  }

  String? _label(Map? entity) {
    final labels = _map(entity?['labels']);
    return _text(_map(labels[language])['value']) ??
        _text(_map(labels['en'])['value']);
  }

  static Iterable<String> _titles(Map film) sync* {
    for (final row in _map(film['labels']).values.whereType<Map>()) {
      if (_text(row['value']) case final text?) yield text;
    }
    for (final rows in _map(film['aliases']).values) {
      for (final row in _rows(rows)) {
        if (_text(row['value']) case final text?) yield text;
      }
    }
    for (final value in _claims(film, 'P1476').whereType<Map>()) {
      if (_text(value['text']) case final text?) yield text;
    }
  }

  static bool _isFilm(Map entity) =>
      _claimIds(entity, 'P31').contains('Q11424');

  static Iterable<String> _claimIds(Map entity, String property) => _claims(
    entity,
    property,
  ).whereType<Map>().map((value) => value['id']).whereType<String>();

  static Iterable<Object> _claims(Map entity, String property) sync* {
    for (final row in _rows(_map(entity['claims'])[property])) {
      if (row['rank'] == 'deprecated') continue;
      final value = _map(_map(row['mainsnak'])['datavalue'])['value'];
      if (value != null) yield value as Object;
    }
  }

  static Iterable<String> _dates(Map film) => _claims(film, 'P577')
      .whereType<Map>()
      .where(
        (value) =>
            value['precision'] is int && (value['precision'] as int) >= 9,
      )
      .map(
        (value) =>
            RegExp(r'^\+(\d{4}(?:-\d{2}-\d{2})?)T')
                .firstMatch('${value['time']}')?[1],
      )
      .whereType<String>()
      .map((value) => value.endsWith('-00-00') ? value.substring(0, 4) : value);

  static int? _minutes(Map film) {
    for (final value in _claims(film, 'P2047').whereType<Map>()) {
      final amount = double.tryParse('${value['amount']}');
      if (amount != null &&
          amount.isFinite &&
          amount > 0 &&
          '${value['unit']}'.endsWith('/Q7727')) {
        return amount.round();
      }
    }
    return null;
  }

  static String? _year(String? text) =>
      RegExp(r'^\d{4}').stringMatch(text?.trim() ?? '');
  static String _normalize(String text) => text
      .toLowerCase()
      .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
      .trim();
  static Map _map(Object? value) => value is Map ? value : const {};
  static Iterable<Map> _rows(Object? value) =>
      value is List ? value.whereType<Map>() : const [];
  static String? _text(Object? value) =>
      value is String && value.trim().isNotEmpty ? value.trim() : null;

  Future<Map> _optionalGet(String host, Map<String, String> query) async {
    try {
      return await _get(host, query);
    } catch (_) {
      return {};
    }
  }

  Future<Map> _get(String host, Map<String, String> query) {
    final result = _queue.then((_) async {
      if (_closed || (_retryAfter?.isAfter(DateTime.now()) ?? false)) {
        throw StateError('Wikimedia requests unavailable');
      }
      final wait = _nextRequest.difference(DateTime.now());
      if (wait > Duration.zero) await Future<void>.delayed(wait);
      if (_closed) throw StateError('Wikimedia client closed');
      _nextRequest = DateTime.now().add(requestInterval);
      final operation = HttpOperation(kMetadataJsonWorkload);
      final request = await operation.wait(
        _http.getUrl(
          Uri.https(host, '/w/api.php', {
            ...query,
            'format': 'json',
            'formatversion': '2',
          }),
        ),
      );
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'TVBro/1.0 (https://tvbro.online/support)',
      );
      final response = await operation.wait(request.close());
      if (response.statusCode == HttpStatus.tooManyRequests) {
        final header = response.headers.value(HttpHeaders.retryAfterHeader);
        final seconds = int.tryParse(header ?? '');
        _retryAfter = DateTime.now().add(
          Duration(seconds: seconds?.clamp(1, 3600) ?? 60),
        );
      }
      final bytes = await operation.readBytes(response);
      if (response.statusCode != HttpStatus.ok) {
        throw StateError('Wikimedia HTTP ${response.statusCode}');
      }
      final data = _map(jsonDecode(utf8.decode(bytes)));
      if (data['error'] != null) throw StateError('Wikimedia API error');
      return data;
    });
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  @override
  void close() {
    _closed = true;
    _http.close(force: true);
  }
}
