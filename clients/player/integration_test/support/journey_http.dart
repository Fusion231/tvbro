import 'dart:io';

/// Keeps journey traffic on the device, including the default TVmaze lookup.
class JourneyHttp extends HttpOverrides {
  JourneyHttp._(this._tvmaze, bool Function(String) acceptsSeries) {
    _tvmaze.listen((request) async {
      final query = request.uri.queryParametersAll;
      final titles = query['q'];
      if (request.method == 'GET' &&
          request.uri.path == '/search/shows' &&
          query.length == 1 &&
          titles != null &&
          titles.length == 1 &&
          acceptsSeries(titles.single)) {
        tvmazeSearches++;
        request.response.headers.contentType = ContentType.json;
        request.response.write('[]');
      } else {
        deniedHosts.add('api.tvmaze.com');
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });
  }

  static Future<JourneyHttp> start(bool Function(String) acceptsSeries) async =>
      JourneyHttp._(
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
        acceptsSeries,
      );

  final HttpServer _tvmaze;
  final deniedHosts = <String>{};
  final _clients = <HttpClient>[];
  int tvmazeSearches = 0;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.findProxy = (_) => 'DIRECT';
    client.connectionFactory = (uri, proxyHost, proxyPort) {
      if (uri.origin == 'https://api.tvmaze.com' && uri.userInfo.isEmpty) {
        return Socket.startConnect(_tvmaze.address, _tvmaze.port);
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
    await _tvmaze.close(force: true);
  }
}
