import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/media_info.dart';
import 'package:iptvs/data/metadata_clients.dart';
import 'package:iptvs/data/metadata_config.dart';
import 'package:iptvs/data/tvmaze_client.dart';
import 'package:iptvs/sources/source.dart';

import 'support/metadata_http.dart';

const series = MediaItem(
  id: 'iptv-1',
  title: 'PL | Test Show [HD]',
  kind: ContentKind.series,
  year: '2024',
);
const show = {
  'id': 42,
  'name': 'Test Show',
  'premiered': '2024-01-02',
  'summary': '<p>A <b>rich</b> synopsis &amp; &#243; &#x142;.</p>',
  'image': {'medium': 'https://images.test/show.jpg'},
  'averageRuntime': 45,
  'genres': ['Drama'],
  'rating': {'average': 8.2},
  '_embedded': {
    'cast': [
      {
        'person': {
          'name': 'Actor',
          'image': {'medium': 'https://images.test/actor.jpg'},
        },
        'character': {'name': 'Lead'},
      },
    ],
  },
};

void main() {
  test('every user gets TVmaze without credentials', () {
    final providers = buildMetadataProviders(const MetadataConfig());
    addTearDown(() {
      for (final provider in providers) {
        provider.close();
      }
    });
    expect(providers.map((p) => p.provider), ['tvmaze']);
    expect(providers.single.authMode, 'public');
  });

  test(
    'configured sources precede the free fallback and ratings remain last',
    () {
      final providers = buildMetadataProviders(
        const MetadataConfig(
          provider: 'tvdb',
          tvdbApiKey: 'tvdb-key',
          tmdbApiKey: 'tmdb-key',
          mdblistApiKey: 'ratings-key',
        ),
      );
      addTearDown(() {
        for (final provider in providers) {
          provider.close();
        }
      });
      expect(providers.map((p) => p.provider), [
        'tvdb',
        'tmdb',
        'tvmaze',
        'mdblist',
      ]);
    },
  );

  test(
    'keyless lookup maps plain text, cast, runtime and attribution',
    () async {
      final http = MetadataHttp(
        (uri) => uri.path == '/search/shows'
            ? const MetadataReply([
                {'show': show},
              ])
            : const MetadataReply(show),
      );
      final client = TvmazeClient(http: http, requestInterval: Duration.zero);
      addTearDown(client.close);
      final metadata = await client.search(series);
      expect(http.urls.first.queryParameters, {'q': 'Test Show'});
      expect(http.urls.last.queryParameters, {'embed': 'cast'});
      expect(
        http.headers.every(
          (h) => h.value(HttpHeaders.authorizationHeader) == null,
        ),
        isTrue,
      );
      expect(metadata?.overview, 'A rich synopsis & ó ł.');
      expect(
        metadata?.payload['license_url'],
        'https://creativecommons.org/licenses/by-sa/4.0/',
      );
      expect(
        metadata?.payload['attribution_url'],
        'https://www.tvmaze.com/shows/42',
      );
      final info = MediaInfo.fromItem(
        series.copyWith(
          extra: {
            'metadata': {'tvmaze': metadata!.payload},
          },
        ),
      );
      expect(info.cast.single.name, 'Actor');
      expect(info.cast.single.role, 'Lead');
      expect(info.durationSeconds, 2700);
      expect(info.genres, ['Drama']);
    },
  );

  test('movies and unrelated search matches are not enriched', () async {
    final http = MetadataHttp(
      (_) => const MetadataReply([
        {
          'show': {
            'id': 9,
            'name': 'Unrelated show',
            'premiered': '2024-01-02',
          },
        },
      ]),
    );
    final client = TvmazeClient(http: http, requestInterval: Duration.zero);
    addTearDown(client.close);
    expect(
      await client.search(
        const MediaItem(id: 'movie', title: 'Movie', kind: ContentKind.movie),
      ),
      isNull,
    );
    expect(http.urls, isEmpty);
    expect(await client.search(series), isNull);
    expect(http.urls, hasLength(1));
  });

  test('TVmaze never uses an unrelated provider ID as its own', () async {
    final http = MetadataHttp((_) => const MetadataReply([]));
    final client = TvmazeClient(http: http, requestInterval: Duration.zero);
    addTearDown(client.close);
    await client.search(series.copyWith(providerId: '98765'));
    expect(http.urls.single.path, '/search/shows');
  });

  test('optional details failure retains the matched synopsis', () async {
    final http = MetadataHttp(
      (uri) => uri.path == '/search/shows'
          ? const MetadataReply([
              {'show': show},
            ])
          : const MetadataReply({}, status: 503),
    );
    final client = TvmazeClient(http: http, requestInterval: Duration.zero);
    addTearDown(client.close);
    expect((await client.search(series))?.overview, 'A rich synopsis & ó ł.');
  });

  test(
    'rate limiting retries once and stays retryable after failure',
    () async {
      var calls = 0;
      final http = MetadataHttp(
        (_) => ++calls <= 2
            ? const MetadataReply({}, status: 429)
            : const MetadataReply([]),
      );
      final client = TvmazeClient(
        http: http,
        requestInterval: Duration.zero,
        retryDelay: Duration.zero,
      );
      addTearDown(client.close);
      await expectLater(client.search(series), throwsStateError);
      expect(calls, 2);
      expect(await client.search(series), isNull);
      expect(calls, 3);
    },
  );

  test('concurrent lookups are paced and closing cancels queued work', () {
    fakeAsync((time) {
      final http = MetadataHttp((_) => const MetadataReply([]));
      final client = TvmazeClient(http: http);
      client.search(series);
      client.search(series);
      Object? failure;
      client.search(series).catchError((Object error) {
        failure = error;
        return null;
      });
      time.flushMicrotasks();
      expect(http.urls, hasLength(1));
      time.elapse(const Duration(milliseconds: 550));
      expect(http.urls, hasLength(2));
      client.close();
      time.elapse(const Duration(milliseconds: 550));
      expect(http.urls, hasLength(2));
      expect(failure, isA<StateError>());
    });
  });
}
