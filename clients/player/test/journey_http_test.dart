import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../integration_test/support/journey_http.dart';

void main() {
  test('only the expected TVmaze search receives a local response', () async {
    final network = await JourneyHttp.start(
      (title) => title == 'Fixture Series',
      acceptsMovie: (title) => title == 'Fixture Movie',
    );
    addTearDown(network.close);
    final client = network.createHttpClient(null);
    final search = Uri.https('api.tvmaze.com', '/search/shows', {
      'q': 'Fixture Series',
    });
    final response = await (await client.getUrl(search)).close();
    expect(response.statusCode, HttpStatus.ok);
    expect(await response.transform(utf8.decoder).join(), '[]');
    expect(network.tvmazeSearches, 1);
    expect(network.deniedHosts, isEmpty);

    final movie = Uri.https('www.wikidata.org', '/w/api.php', {
      'action': 'wbsearchentities',
      'search': 'Fixture Movie',
      'language': 'en',
      'uselang': 'en',
      'type': 'item',
      'limit': '8',
      'format': 'json',
      'formatversion': '2',
    });
    final matchingMovie = await (await client.getUrl(movie)).close();
    expect(matchingMovie.statusCode, HttpStatus.ok);
    expect(await matchingMovie.transform(utf8.decoder).join(), '{"search":[]}');
    expect(network.wikimediaSearches, 1);

    for (final (method, uri) in [
      ('GET', search.resolve('/other')),
      ('POST', search),
      ('GET', search.replace(queryParameters: {'q': 'unrelated'})),
    ]) {
      final unexpected = await (await client.openUrl(method, uri)).close();
      await unexpected.drain<void>();
      expect(unexpected.statusCode, HttpStatus.notFound);
    }
    expect(network.deniedHosts, {'api.tvmaze.com'});

    await expectLater(
      () => client.getUrl(Uri.https('unrelated.invalid', '/')),
      throwsStateError,
    );
    expect(network.deniedHosts, {'api.tvmaze.com', 'unrelated.invalid'});
  });
}
