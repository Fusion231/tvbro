import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/distribution_channel.dart';
import 'package:iptvs/data/update_service.dart';

ReleaseInfo _rel(String version) => ReleaseInfo(
  version: version,
  tagName: 'v$version',
  name: 'TVBro $version',
  notes: '',
  htmlUrl: Uri.parse('https://github.com/Fusion231/tvbro/releases'),
);

void main() {
  group('TVBro update discovery', () {
    test(
      'verifies releases from a separately configured public repository',
      () async {
        const owner = 'TVBroPublisher';
        const repo = 'tvbro-releases';
        final manifestUrl = Uri.https(
          'github.com',
          '/$owner/$repo/releases/download/v1.2.3/iptvs-1.2.3-manifest.json',
        );
        final signatureUrl = Uri.parse('$manifestUrl.sig');
        final manifest = utf8.encode(
          jsonEncode({
            'schema': 1,
            'version': '1.2.3',
            'minimum_version': '1.0.0',
            'artifacts': [
              {
                'platform': 'android',
                'filename': 'iptvs-1.2.3-android.apk',
                'byte_size': 5,
                'sha256': List.filled(64, 'a').join(),
              },
            ],
          }),
        );
        final algorithm = Ed25519();
        final keyPair = await algorithm.newKeyPair();
        final publicKey = await keyPair.extractPublicKey();
        final signature = await algorithm.sign(manifest, keyPair: keyPair);
        final http = _UpdateHttpClient(
          body: _releasePayload(repository: '$owner/$repo'),
          responses: {
            manifestUrl: manifest,
            signatureUrl: utf8.encode(base64Encode(signature.bytes)),
          },
        );
        final service = UpdateService(
          http: http,
          owner: owner,
          repo: repo,
          manifestPublicKey: base64Encode(publicKey.bytes),
        );
        addTearDown(service.close);

        final release = await service.fetchLatest();

        expect(release?.version, '1.2.3');
        expect(
          release?.androidAsset,
          Uri.https(
            'github.com',
            '/$owner/$repo/releases/download/v1.2.3/iptvs-1.2.3-android.apk',
          ),
        );
        expect(http.urls, [
          Uri.https('api.github.com', '/repos/$owner/$repo/releases/latest'),
          manifestUrl,
          signatureUrl,
        ]);
      },
    );

    for (final track in UpdateTrack.values) {
      test('$track queries only the TVBro repository', () async {
        final http = _UpdateHttpClient(statusCode: 404);
        final service = UpdateService(http: http, track: track);
        addTearDown(service.close);

        expect(await service.fetchLatest(), isNull);
        expect(http.urls, [
          Uri.parse(
            track == UpdateTrack.beta
                ? 'https://api.github.com/repos/Fusion231/tvbro/releases?per_page=20'
                : 'https://api.github.com/repos/Fusion231/tvbro/releases/latest',
          ),
        ]);
        expect(
          http.requestHeaders.value(HttpHeaders.userAgentHeader),
          'tvbro-updater',
        );
      });
    }

    test(
      'missing TVBro verification key prevents metadata downloads',
      () async {
        final http = _UpdateHttpClient(body: _releasePayload());
        final service = UpdateService(http: http, manifestPublicKey: '');
        addTearDown(service.close);

        await expectLater(
          service.fetchLatest(),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'Update verification key is not configured',
            ),
          ),
        );
        expect(http.urls, hasLength(1));
      },
    );

    for (final repository in ['GCHOfficial/iptvs', 'Fusion231/other']) {
      test('does not fetch update metadata from $repository', () async {
        final http = _UpdateHttpClient(
          body: _releasePayload(repository: repository),
        );
        final service = UpdateService(
          http: http,
          manifestPublicKey: 'configured',
        );
        addTearDown(service.close);

        await expectLater(
          service.fetchLatest(),
          throwsA(isA<FormatException>()),
        );
        expect(http.urls, hasLength(1));
      });
    }

    test('metadata URLs must belong to the selected TVBro release', () async {
      final http = _UpdateHttpClient(
        body: _releasePayload(downloadTag: 'v1.2.2'),
      );
      final service = UpdateService(
        http: http,
        manifestPublicKey: 'configured',
      );
      addTearDown(service.close);

      await expectLater(service.fetchLatest(), throwsA(isA<FormatException>()));
      expect(http.urls, hasLength(1));
    });
  });

  group('compareVersions', () {
    test('orders numerically, not lexically', () {
      expect(compareVersions('1.2.10', '1.2.3'), greaterThan(0));
      expect(compareVersions('1.2.3', '1.2.10'), lessThan(0));
    });

    test('pads differing part counts', () {
      expect(compareVersions('1.2.0', '1.2'), 0);
      expect(compareVersions('1.2', '1.2.1'), lessThan(0));
    });

    test('equal versions', () {
      expect(compareVersions('2.0.0', '2.0.0'), 0);
    });

    test('ignores build metadata / suffixes', () {
      expect(compareVersions('1.2.3+45', '1.2.3'), 0);
      expect(compareVersions('1.2.3-beta', '1.2.3'), 0);
    });

    test('major and minor take precedence', () {
      expect(compareVersions('2.0.0', '1.9.9'), greaterThan(0));
      expect(compareVersions('1.3.0', '1.2.9'), greaterThan(0));
    });
  });

  group('isNewer', () {
    test('true only when release is strictly newer', () {
      expect(isNewer(_rel('1.3.0'), '1.2.0'), isTrue);
      expect(isNewer(_rel('1.2.0'), '1.2.0'), isFalse);
      expect(isNewer(_rel('1.1.0'), '1.2.0'), isFalse);
    });
  });

  group('isUpdateAllowed', () {
    test('rejects same-version installs and downgrades by default', () {
      expect(isUpdateAllowed(_rel('1.2.0'), '1.2.0'), isFalse);
      expect(isUpdateAllowed(_rel('1.1.9'), '1.2.0'), isFalse);
    });

    test('allows an explicitly labelled local downgrade override', () {
      expect(
        isUpdateAllowed(
          _rel('1.1.9'),
          '1.2.0',
          developerDowngradeOverride: true,
        ),
        isTrue,
      );
    });
  });

  group('release track selection', () {
    test('stable consumes the latest-release object', () {
      final payload = {'tag_name': 'v1.2.3'};
      expect(
        selectReleasePayload(payload, UpdateTrack.stable)?['tag_name'],
        'v1.2.3',
      );
    });

    test('beta selects the highest non-draft stable or prerelease', () {
      final payload = [
        {'tag_name': 'v1.2.4', 'prerelease': true, 'draft': true},
        {'tag_name': 'v1.2.3', 'prerelease': false, 'draft': false},
        {'tag_name': 'v1.3.0', 'prerelease': true, 'draft': false},
        {'tag_name': 'not-semver', 'prerelease': true, 'draft': false},
      ];
      expect(
        selectReleasePayload(payload, UpdateTrack.beta)?['tag_name'],
        'v1.3.0',
      );
    });
  });

  group('shouldAutoCheck', () {
    final now = DateTime(2026, 7, 10, 12);

    test('runs when never checked', () {
      expect(shouldAutoCheck(null, now), isTrue);
    });

    test('throttled within the gap, allowed after', () {
      expect(
        shouldAutoCheck(now.subtract(const Duration(hours: 1)), now),
        isFalse,
      );
      expect(
        shouldAutoCheck(now.subtract(const Duration(hours: 5)), now),
        isFalse,
      );
      expect(
        shouldAutoCheck(now.subtract(const Duration(hours: 7)), now),
        isTrue,
      );
    });
  });

  group('approved update URLs', () {
    test(
      'a configured public repository replaces the default trust boundary',
      () {
        final configured = Uri.parse(
          'https://github.com/Fusion231/tvbro-releases/releases/download/v1.2.3/file.apk',
        );
        expect(isApprovedUpdateUri(configured, repo: 'tvbro-releases'), isTrue);
        expect(
          isApprovedUpdateUri(
            Uri.parse('https://github.com/Fusion231/tvbro/releases/latest'),
            repo: 'tvbro-releases',
          ),
          isFalse,
        );
        expect(
          resolveApprovedUpdateRedirect(
            configured,
            '/Fusion231/tvbro-releases/releases/download/v1.2.3/next.apk',
            repo: 'tvbro-releases',
          ),
          Uri.parse(
            'https://github.com/Fusion231/tvbro-releases/releases/download/v1.2.3/next.apk',
          ),
        );
        expect(
          () => resolveApprovedUpdateRedirect(
            configured,
            '/Fusion231/tvbro/releases/download/v1.2.3/next.apk',
            repo: 'tvbro-releases',
          ),
          throwsA(isA<FormatException>()),
        );
      },
    );

    test('rejects malformed repository configuration', () {
      for (final repository in ['', '../other', 'tvbro/releases']) {
        expect(
          isApprovedUpdateUri(
            Uri.parse('https://release-assets.githubusercontent.com/file'),
            repo: repository,
          ),
          isFalse,
        );
      }
    });

    test('accepts HTTPS GitHub release infrastructure', () {
      expect(
        isApprovedUpdateUri(
          Uri.parse(
            'https://github.com/Fusion231/tvbro/releases/download/v1.2.3/x',
          ),
        ),
        isTrue,
      );
      expect(
        isApprovedUpdateUri(
          Uri.parse(
            'https://api.github.com/repos/Fusion231/tvbro/releases/latest',
          ),
        ),
        isTrue,
      );
      expect(
        isApprovedUpdateUri(
          Uri.parse('https://release-assets.githubusercontent.com/file'),
        ),
        isTrue,
      );
    });

    test('rejects HTTP, user-controlled hosts, and lookalike suffixes', () {
      expect(isApprovedUpdateUri(Uri.parse('http://github.com/file')), isFalse);
      expect(
        isApprovedUpdateUri(Uri.parse('https://example.com/file')),
        isFalse,
      );
      expect(
        isApprovedUpdateUri(Uri.parse('https://github.com.example.com/file')),
        isFalse,
      );
      expect(
        isApprovedUpdateUri(Uri.parse('https://github.com:444/file')),
        isFalse,
      );
      expect(
        isApprovedUpdateUri(Uri.parse('https://user@github.com/file')),
        isFalse,
      );
    });

    test('rejects upstream and unrelated GitHub repository paths', () {
      for (final url in [
        'https://github.com/GCHOfficial/iptvs/releases/download/v1.2.3/file.apk',
        'https://api.github.com/repos/GCHOfficial/iptvs/releases/latest',
        'https://github.com/Fusion231/other/releases/download/v1.2.3/file.apk',
        'https://github.com/Fusion231/tvbro/releases-other/file.apk',
        'https://github.com/Fusion231/tvbro/releases/../../other/releases/file.apk',
      ]) {
        expect(isApprovedUpdateUri(Uri.parse(url)), isFalse, reason: url);
      }
    });

    test('resolves an approved relative redirect', () {
      expect(
        resolveApprovedUpdateRedirect(
          Uri.parse('https://github.com/Fusion231/tvbro/releases'),
          '/Fusion231/tvbro/releases/download/v1.2.3/file.apk',
        ),
        Uri.parse(
          'https://github.com/Fusion231/tvbro/releases/download/v1.2.3/file.apk',
        ),
      );
    });

    test('rejects an unapproved redirect before it can be followed', () {
      for (final location in [
        'https://example.com/payload.apk',
        'http://github.com/payload.apk',
        'https://github.com.example.com/payload.apk',
        'https://github.com:444/payload.apk',
        'https://github.com/GCHOfficial/iptvs/releases/download/v1.2.3/file.apk',
        'https://api.github.com/repos/GCHOfficial/iptvs/releases/latest',
      ]) {
        expect(
          () => resolveApprovedUpdateRedirect(
            Uri.parse('https://github.com/Fusion231/tvbro/releases'),
            location,
          ),
          throwsA(isA<FormatException>()),
        );
      }
    });
  });
}

Map<String, Object> _releasePayload({
  String repository = 'Fusion231/tvbro',
  String downloadTag = 'v1.2.3',
}) => {
  'tag_name': 'v1.2.3',
  'assets': [
    for (final name in [
      'iptvs-1.2.3-manifest.json',
      'iptvs-1.2.3-manifest.json.sig',
    ])
      {
        'name': name,
        'browser_download_url':
            'https://github.com/$repository/releases/download/$downloadTag/$name',
      },
  ],
};

class _UpdateHttpClient extends Fake implements HttpClient {
  _UpdateHttpClient({
    this.statusCode = 200,
    Object? body,
    this.responses = const {},
  }) : bytes = utf8.encode(body == null ? '' : jsonEncode(body));

  final int statusCode;
  final List<int> bytes;
  final Map<Uri, List<int>> responses;
  final urls = <Uri>[];
  final requestHeaders = _UpdateHeaders();

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    urls.add(url);
    return _UpdateRequest(this, url);
  }

  @override
  void close({bool force = false}) {}
}

class _UpdateRequest extends Fake implements HttpClientRequest {
  _UpdateRequest(this.client, this.url);

  final _UpdateHttpClient client;
  final Uri url;

  @override
  HttpHeaders get headers => client.requestHeaders;

  @override
  set followRedirects(bool value) {}

  @override
  Future<HttpClientResponse> close() async => _UpdateResponse(client, url);
}

class _UpdateResponse extends Fake implements HttpClientResponse {
  _UpdateResponse(this.client, this.url);

  final _UpdateHttpClient client;
  final Uri url;
  List<int> get bytes => client.responses[url] ?? client.bytes;

  @override
  int get statusCode => client.statusCode;

  @override
  bool get isRedirect => false;

  @override
  int get contentLength => bytes.length;

  @override
  HttpHeaders get headers => _UpdateHeaders();

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(bytes).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
}

class _UpdateHeaders extends Fake implements HttpHeaders {
  final values = <String, String>{};

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name] = value.toString();
  }

  @override
  String? value(String name) => values[name];
}
