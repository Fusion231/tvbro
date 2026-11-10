import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/tvdb_client.dart';
import 'package:iptvs/sources/source.dart';

void main() {
  const season = MediaItem(
    id: 'season',
    title: 'Season',
    kind: ContentKind.season,
    seasonNumber: 1,
    extra: {'series_tvdb_id': '42'},
  );
  const episode = MediaItem(
    id: 'episode',
    title: 'Episode',
    kind: ContentKind.episode,
    episodeNumber: 1,
  );

  test('concurrent TVDB child lookups share a login', () async {
    final http = _TvdbHttpClient();
    final client = TvdbClient(apiKey: 'key', http: http);
    addTearDown(client.close);

    final results = await Future.wait([
      for (var index = 0; index < 4; index++)
        client.episodeMetadata(season, episode),
    ]);

    expect(http.logins, 1);
    expect(http.gets, 4);
    debugPrint('SERIES_TVDB_WORK concurrency=4 logins=${http.logins}');
    expect(
      results.map((result) => result?.title),
      everyElement('Fixture episode'),
    );
    await client.episodeMetadata(season, episode);
    expect(http.logins, 1);
  });

  test('a failed TVDB login stays retryable', () async {
    final http = _TvdbHttpClient()..failLogin = true;
    final client = TvdbClient(apiKey: 'key', http: http);
    addTearDown(client.close);

    await expectLater(
      client.episodeMetadata(season, episode),
      throwsStateError,
    );
    http.failLogin = false;
    expect(
      (await client.episodeMetadata(season, episode))?.title,
      'Fixture episode',
    );
    expect(http.logins, 2);
  });
}

class _TvdbHttpClient extends Fake implements HttpClient {
  int logins = 0;
  int gets = 0;
  bool failLogin = false;

  @override
  Future<HttpClientRequest> postUrl(Uri url) async {
    logins++;
    return _Request({
      'data': {'token': 'fixture-token'},
    }, status: failLogin ? 500 : 200);
  }

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    gets++;
    return _Request({
      'data': {
        'episodes': [
          {
            'id': 101,
            'name': 'Fixture episode',
            'seasonNumber': 1,
            'number': 1,
          },
        ],
      },
    });
  }

  @override
  void close({bool force = false}) {}
}

class _Request extends Fake implements HttpClientRequest {
  _Request(this.body, {this.status = 200});

  final Map<String, dynamic> body;
  final int status;

  @override
  final HttpHeaders headers = _Headers();

  @override
  void write(Object? object) {}

  @override
  Future<HttpClientResponse> close() async {
    await Future<void>.delayed(Duration.zero);
    return _Response(body, status);
  }
}

class _Response extends Fake implements HttpClientResponse {
  _Response(Map<String, dynamic> body, this.statusCode)
    : bytes = utf8.encode(jsonEncode(body));

  final List<int> bytes;

  @override
  final int statusCode;

  @override
  int get contentLength => bytes.length;

  @override
  final HttpHeaders headers = _Headers();

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream.value(bytes).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
}

class _Headers extends Fake implements HttpHeaders {
  @override
  set contentType(ContentType? value) {}

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  String? value(String name) => null;
}
