import 'dart:io';

/// Keeps journey traffic on the device, including public metadata lookups.
class JourneyHttp extends HttpOverrides {
  JourneyHttp._(
    this._metadata,
    bool Function(String) acceptsSeries, {
    bool Function(String)? acceptsMovie,
  }) : _acceptsWikimedia = acceptsMovie != null {
    _metadata.listen((request) async {
      final query = request.uri.queryParametersAll;
      final titles = query['q'];
      final movieTitles = query['search'];
      if (request.method == 'GET' &&
          request.uri.path == '/search/shows' &&
          query.length == 1 &&
          titles != null &&
          titles.length == 1 &&
          acceptsSeries(titles.single)) {
        tvmazeSearches++;
        request.response.headers.contentType = ContentType.json;
        request.response.write('[]');
      } else if (request.method == 'GET' &&
          request.uri.path == '/w/api.php' &&
          query.length == 8 &&
          query['action']?.singleOrNull == 'wbsearchentities' &&
          movieTitles?.length == 1 &&
          acceptsMovie?.call(movieTitles!.single) == true) {
        wikimediaSearches++;
        request.response.headers.contentType = ContentType.json;
        request.response.write('{"search":[]}');
      } else {
        deniedHosts.add(
          request.uri.path == '/w/api.php'
              ? 'www.wikidata.org'
              : 'api.tvmaze.com',
        );
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });
  }

  static Future<JourneyHttp> start(
    bool Function(String) acceptsSeries, {
    bool Function(String)? acceptsMovie,
  }) async => JourneyHttp._(
    await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    acceptsSeries,
    acceptsMovie: acceptsMovie,
  );

  final HttpServer _metadata;
  final bool _acceptsWikimedia;
  final deniedHosts = <String>{};
  final _clients = <HttpClient>[];
  int tvmazeSearches = 0;
  int wikimediaSearches = 0;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.findProxy = (_) => 'DIRECT';
    client.connectionFactory = (uri, proxyHost, proxyPort) {
      if ((uri.origin == 'https://api.tvmaze.com' ||
              (_acceptsWikimedia &&
                  uri.origin == 'https://www.wikidata.org')) &&
          uri.userInfo.isEmpty) {
        return Socket.startConnect(_metadata.address, _metadata.port);
      }
      if (uri.host != '127.0.0.1' &&
          uri.host != 'localhost' &&
          uri.host != '::1') {
        deniedHosts.add(uri.host);
        throw StateError('Only synthetic device-loopback HTTP is allowed.');
      }
      return Socket.startConnect(uri.host, uri.port);
    };
    _clients.add(client);
    return client;
  }

  Future<void> close() async {
    for (final client in _clients) {
      client.close(force: true);
    }
    await _metadata.close(force: true);
  }
}
