import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/epg_download_cache.dart';
import 'package:iptvs/data/load_token.dart';
import 'package:iptvs/data/net.dart';
import 'package:iptvs/sources/epg_guides.dart';
import 'package:iptvs/sources/source.dart';

void main() {
  late Directory temp;
  late HttpServer server;
  late HttpClient client;
  late String url;
  final requests =
      <
        ({String? etag, String? modified, String? authorization, String path})
      >[];
  var mode = 'normal';
  const body =
      '<tv><channel id="a"><display-name>News</display-name></channel>'
      '<programme channel="a" start="20261022120000 +0000" stop="20261022130000 +0000"><title>News Hour</title></programme></tv>';

  setUp(() async {
    ProviderRequestGate.instance.debugReset();
    requests.clear();
    mode = 'normal';
    temp = Directory.systemTemp.createTempSync('iptvs_epg_http_test');
    client = HttpClient()..autoUncompress = false;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    url =
        'http://127.0.0.1:${server.port}/guide?username=private&password=secret';
    server.listen((request) async {
      final etag = request.headers.value(HttpHeaders.ifNoneMatchHeader);
      requests.add((
        etag: etag,
        modified: request.headers.value(HttpHeaders.ifModifiedSinceHeader),
        authorization: request.headers.value(HttpHeaders.authorizationHeader),
        path: request.uri.path,
      ));
      if (mode == 'rateLimited') {
        request.response.statusCode = HttpStatus.tooManyRequests;
        request.response.headers.set(HttpHeaders.retryAfterHeader, '900');
      } else if (mode == 'broken') {
        request.response.headers.set(HttpHeaders.etagHeader, '"broken"');
        request.response.write('<tv><programme');
      } else if (etag == '"good"') {
        request.response.statusCode = HttpStatus.notModified;
      } else {
        request.response.headers.set(HttpHeaders.etagHeader, '"good"');
        request.response.headers.set(
          HttpHeaders.lastModifiedHeader,
          'Wed, 21 Oct 2026 12:00:00 GMT',
        );
        request.response.write(body);
      }
      await request.response.close();
    });
  });

  tearDown(() async {
    client.close(force: true);
    await server.close(force: true);
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  Future<List<Programme>> read(
    EpgDownloadCache cache, {
    String source = 'source',
    String? guideUrl,
    Map<String, String> headers = const {},
    LoadToken? token,
  }) async {
    final feed = xmltvGuideFeed(
      url: guideUrl ?? url,
      cachedDownload: (uri, file) => cache.fetch(
        sourceId: source,
        uri: uri,
        client: client,
        destination: file,
        headers: headers,
        token: token,
      ),
      tvgIdToChannelIds: const {
        'a': ['channel'],
      },
      nameToChannelIds: const {},
      token: token,
      tempDirectory: temp,
    );
    return (await feed.open().toList()).expand((batch) => batch).toList();
  }

  test(
    '200 caches only accepted XML; 304 replays the complete guide',
    () async {
      final cache = EpgDownloadCache(
        directory: Directory('${temp.path}/cache'),
      );
      expect((await read(cache)).single.title, 'News Hour');
      expect((await read(cache)).single.title, 'News Hour');
      expect(requests[0].etag, isNull);
      expect(requests[1].etag, '"good"');
      expect(requests[1].modified, 'Wed, 21 Oct 2026 12:00:00 GMT');
      mode = 'broken';
      await expectLater(read(cache), throwsA(anything));
      mode = 'normal';
      expect((await read(cache)).single.title, 'News Hour');
      expect(
        requests.last.etag,
        '"good"',
        reason: 'malformed response replaced the last good validator',
      );
      final metadata = await Directory('${temp.path}/cache')
          .list()
          .where((file) => file.path.endsWith('.json'))
          .toList();
      final content = await File(metadata.single.path).readAsString();
      for (final secret in ['private', 'secret', 'username', '127.0.0.1']) {
        expect(content, isNot(contains(secret)));
        expect(metadata.single.path, isNot(contains(secret)));
      }
    },
  );

  test('missing or same-size corrupt body disables stale validators', () async {
    final directory = Directory('${temp.path}/cache');
    final cache = EpgDownloadCache(directory: directory);
    await read(cache);
    var file =
        (await directory
                .list()
                .where((file) => file.path.endsWith('.body'))
                .toList())
            .single;
    await File(file.path).writeAsString('x' * body.length);
    expect((await read(cache)).single.title, 'News Hour');
    expect(requests.last.etag, isNull);
    file =
        (await directory
                .list()
                .where((file) => file.path.endsWith('.body'))
                .toList())
            .single;
    await file.delete();
    expect((await read(cache)).single.title, 'News Hour');
    expect(requests.last.etag, isNull);
  });

  test(
    'cache keys isolate source, complete URL and authentication context',
    () async {
      final cache = EpgDownloadCache(
        directory: Directory('${temp.path}/cache'),
      );
      await read(
        cache,
        headers: {HttpHeaders.authorizationHeader: 'Bearer first-secret'},
      );
      await read(
        cache,
        source: 'second-source',
        headers: {HttpHeaders.authorizationHeader: 'Bearer first-secret'},
      );
      await read(
        cache,
        headers: {HttpHeaders.authorizationHeader: 'Bearer second-secret'},
      );
      await read(
        cache,
        guideUrl: '$url&different=1',
        headers: {HttpHeaders.authorizationHeader: 'Bearer first-secret'},
      );
      expect(requests.map((request) => request.etag), everyElement(isNull));
      await read(
        cache,
        headers: {HttpHeaders.authorizationHeader: 'Bearer first-secret'},
      );
      expect(requests.last.etag, '"good"');
    },
  );

  test('bounded cache evicts validators together with their bodies', () async {
    final directory = Directory('${temp.path}/cache');
    final cache = EpgDownloadCache(
      directory: directory,
      maximumEntries: 1,
      maximumBytes: 10000,
    );
    await read(cache);
    await read(cache, guideUrl: '$url&other=1');
    expect(
      (await directory
              .list()
              .where((file) => file.path.endsWith('.json'))
              .toList())
          .length,
      1,
    );
    expect(
      (await directory
              .list()
              .where((file) => file.path.endsWith('.body'))
              .toList())
          .length,
      1,
    );
    await read(cache);
    expect(requests.last.etag, isNull);
  });

  test(
    'cancelled download throws rather than yielding an empty guide',
    () async {
      final token = LoadToken()..cancel();
      final cache = EpgDownloadCache(
        directory: Directory('${temp.path}/cache'),
      );
      await expectLater(
        read(cache, token: token),
        throwsA(isA<LoadCancelledException>()),
      );
      expect(requests, isEmpty);
    },
  );

  test(
    'EPG refusal pauses fresh sources without replacing a good body',
    () async {
      final cache = EpgDownloadCache(
        directory: Directory('${temp.path}/cache'),
      );
      expect((await read(cache)).single.title, 'News Hour');
      mode = 'rateLimited';
      final destination = File('${temp.path}/rejected.xml');
      await expectLater(
        cache.fetch(
          sourceId: 'first',
          uri: Uri.parse(url),
          client: client,
          destination: destination,
        ),
        throwsA(
          isA<ProviderRequestBlocked>().having((e) => e.status, 'status', 429),
        ),
      );
      mode = 'normal';
      await expectLater(
        cache.fetch(
          sourceId: 'new-source',
          uri: Uri.parse(url),
          client: client,
          destination: destination,
        ),
        throwsA(isA<ProviderRequestBlocked>()),
      );
      expect(requests, hasLength(2));
      expect(await destination.exists(), isFalse);
      ProviderRequestGate.instance.debugReset();
      expect((await read(cache)).single.title, 'News Hour');
      expect(requests.last.etag, '"good"');
    },
  );

  test(
    'an unavailable cache directory uses the normal bounded transfer',
    () async {
      final occupied = File('${temp.path}/not-a-directory');
      await occupied.writeAsString('already a file');
      final cache = EpgDownloadCache(directory: Directory(occupied.path));
      expect((await read(cache)).single.title, 'News Hour');
      expect((await read(cache)).single.title, 'News Hour');
      expect(requests.map((request) => request.etag), everyElement(isNull));
      expect(await occupied.readAsString(), 'already a file');
    },
  );
}
