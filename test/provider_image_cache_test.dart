import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/net.dart';
import 'package:iptvs/data/provider_image_cache.dart';

void main() {
  late HttpServer server;
  late HttpClient client;
  late ProviderImageFileService service;
  late Uri origin;
  var requests = 0;
  var status = 200;
  var headers = <String, String>{};
  Future<void> Function(HttpRequest)? onRequest;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    ProviderRequestGate.instance.debugReset();
    requests = 0;
    status = 200;
    headers = {};
    onRequest = null;
    client = HttpClient();
    service = ProviderImageFileService(client: client);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin = Uri.parse('http://127.0.0.1:${server.port}');
    server.listen((request) async {
      requests++;
      await onRequest?.call(request);
      request.response.statusCode = status;
      headers.forEach(request.response.headers.set);
      if (status != 304) request.response.add([1, 2, 3]);
      await request.response.close();
    });
  });

  tearDown(() async {
    service.close();
    await server.close(force: true);
    ProviderRequestGate.instance.debugReset();
    debugDefaultTargetPlatformOverride = null;
  });

  test('artwork sends zero requests while provider API is blocked', () async {
    ProviderRequestGate.instance.recordResponse(origin, 401);
    await expectLater(
      service.get(origin.resolve('/logo.png').toString()),
      throwsA(isA<ProviderRequestBlocked>()),
    );
    expect(requests, 0);
  });

  for (final code in [401]) {
    test('artwork HTTP $code pauses artwork on the host but keeps the API usable', () async {
      status = code;
      headers = {'retry-after': '900'};
      final url = origin.resolve('/restricted.png').toString();
      await expectLater(service.get(url), throwsA(isA<ProviderRequestBlocked>()));
      await expectLater(service.get(url), throwsA(isA<ProviderRequestBlocked>()));
      expect(requests, 1);

      status = 200;
      final operation = HttpOperation(kProviderJsonWorkload);
      final api = await providerHttpGet(
        origin.resolve('/player_api.php'),
        client: client,
        operation: operation,
        readResponse: operation.readBytes,
      );
      expect(api, [1, 2, 3]);
      await expectLater(service.get(origin.resolve('/another-poster.png').toString()),
        throwsA(isA<ProviderRequestBlocked>()));
      expect(requests, 2);
    });
  }

  test('scrolling through different refused posters stops the queued image burst', () async {
    status = 401;
    final results = await Future.wait([
      for (var i = 0; i < 30; i++)
        service.get(origin.resolve('/poster-$i.png').toString())
          .then<Object>((response) => response, onError: (Object error) => error),
    ]);
    expect(results, everyElement(isA<ProviderRequestBlocked>()));
    // At most the two already-admitted downloads can reach the server.
    expect(requests, inInclusiveRange(1, 2));
    final afterRefusal = requests;
    await expectLater(service.get(origin.resolve('/after-scroll.png').toString()),
      throwsA(isA<ProviderRequestBlocked>()));
    expect(requests, afterRefusal);
    ProviderRequestGate.instance.check(origin.resolve('/movie.ts'));
  });

  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    test('artwork HTTP 403 allows immediate URL and host retries on $platform', () async {
      service.close();
      debugDefaultTargetPlatformOverride = platform;
      client = HttpClient();
      service = ProviderImageFileService(client: client);
      status = 403;
      headers = {'retry-after': '900'};
      final url = origin.resolve('/restricted.png').toString();
      for (var attempt = 1; attempt <= 2; attempt++) {
        await expectLater(
          service.get(url),
          throwsA(isA<HttpWorkloadException>().having(
            (error) => error.toString(), 'status', contains('HTTP 403'),
          )),
        );
        expect(requests, attempt);
      }

      status = 200;
      final response = await service.get(url);
      expect(await response.content.expand((chunk) => chunk).toList(), [1, 2, 3]);
      await service.get(origin.resolve('/another-poster.png').toString());
      final operation = HttpOperation(kProviderJsonWorkload);
      expect(await providerHttpGet(
        origin.resolve('/player_api.php'),
        client: client,
        operation: operation,
        readResponse: operation.readBytes,
      ), [1, 2, 3]);
      expect(requests, 5);
    });
  }

  for (final code in [429, 503]) {
    test('artwork HTTP $code blocks other images and provider API', () async {
      status = code;
      headers = {'retry-after': '900'};
      await expectLater(
        service.get(origin.resolve('/logo.png').toString()),
        throwsA(isA<ProviderRequestBlocked>()),
      );
      await expectLater(
        service.get(origin.resolve('/poster.png').toString()),
        throwsA(isA<ProviderRequestBlocked>()),
      );
      var opened = false;
      await expectLater(
        ProviderRequestGate.instance.run(origin, () async {
          opened = true;
        }),
        throwsA(isA<ProviderRequestBlocked>()),
      );
      expect(opened, isFalse);
      expect(requests, 1);
    });
  }

  test('missing logo is briefly cached as failure instead of fetched for every tile', () async {
    status = 404;
    final url = origin.resolve('/missing.png').toString();
    await expectLater(service.get(url), throwsA(isA<HttpWorkloadException>()));
    await expectLater(service.get(url), throwsA(isA<HttpWorkloadException>()));
    expect(requests, 1);
    // A broken individual logo must not pause other items on the host.
    status = 200;
    final response = await service.get(origin.resolve('/good.png').toString());
    expect(await response.content.expand((chunk) => chunk).toList(), [1, 2, 3]);
    expect(requests, 2);
  });

  test(
    'artwork preserves HTTP validators, freshness and conditional 304',
    () async {
      headers = {
        'cache-control': 'max-age=3600',
        'etag': 'image-v1',
        'content-type': 'image/png',
      };
      final before = DateTime.now();
      final response = await service.get(
        origin.resolve('/logo.png').toString(),
      );
      expect(response.eTag, 'image-v1');
      expect(response.fileExtension, '.png');
      expect(
        response.validTill.difference(before).inSeconds,
        inInclusiveRange(3599, 3601),
      );
      expect(await response.content.expand((chunk) => chunk).toList(), [
        1,
        2,
        3,
      ]);
      status = 304;
      final unchanged = await service.get(
        origin.resolve('/logo.png').toString(),
        headers: {'if-none-match': response.eTag!},
      );
      expect(unchanged.statusCode, 304);
      expect(
        await unchanged.content.expand((chunk) => chunk).toList(),
        isEmpty,
      );
    },
  );

  test(
    'artwork redirect respects destination cooldown before connecting',
    () async {
      final destination = origin
          .replace(host: 'localhost')
          .resolve('/logo.png');
      ProviderRequestGate.instance.recordResponse(destination, 429);
      status = 302;
      headers = {'location': destination.toString()};
      await expectLater(
        service.get(origin.resolve('/redirect').toString()),
        throwsA(isA<ProviderRequestBlocked>()),
      );
      expect(requests, 1);
    },
  );

  test('artwork rejects credentials and non-HTTP locators locally', () async {
    for (final url in [
      'file:///private',
      'data:image/png;base64,AA',
      'https://user:secret@provider.test/logo',
    ]) {
      await expectLater(
        service.get(url),
        throwsA(isA<HttpWorkloadException>()),
      );
    }
    expect(requests, 0);
  });

  group('Android artwork', () {
    setUp(() {
      service.close();
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      client = HttpClient();
      service = ProviderImageFileService(client: client);
    });

    test('twelve image downloads leave both API permits available', () async {
      final imagesStarted = Completer<void>();
      final releaseImages = Completer<void>();
      var activeImages = 0;
      onRequest = (request) async {
        if (!request.uri.path.startsWith('/poster-')) return;
        activeImages++;
        if (activeImages == 12) imagesStarted.complete();
        await releaseImages.future;
        activeImages--;
      };
      final images = Future.wait([
        for (var i = 0; i < 12; i++)
          service.get(origin.resolve('/poster-$i.png').toString()),
      ]);
      try {
        await imagesStarted.future.timeout(const Duration(seconds: 5));
        expect(activeImages, 12);
        final results = await Future.wait([
          for (var i = 0; i < 2; i++)
            (() {
              final operation = HttpOperation(kProviderJsonWorkload);
              return providerHttpGet(
                origin.resolve('/player_api.php?request=$i'),
                client: client,
                operation: operation,
                readResponse: operation.readBytes,
              );
            })(),
        ]).timeout(const Duration(seconds: 5));
        expect(results, [
          [1, 2, 3],
          [1, 2, 3],
        ]);
        expect(activeImages, 12);
      } finally {
        releaseImages.complete();
        await images;
      }
      expect(requests, 14);
    });

    for (final code in [401, 429, 503]) {
      test('HTTP $code stops the queue after admitted images', () async {
        status = code;
        headers = {'retry-after': '900'};
        final imagesStarted = Completer<void>();
        final releaseImages = Completer<void>();
        onRequest = (_) async {
          if (requests == 12) imagesStarted.complete();
          await releaseImages.future;
        };
        final images = Future.wait([
          for (var i = 0; i < 30; i++)
            service
                .get(origin.resolve('/refused-$i.png').toString())
                .then<Object>(
                  (response) => response,
                  onError: (Object error) => error,
                ),
        ]);
        late final List<Object> results;
        try {
          await imagesStarted.future.timeout(const Duration(seconds: 5));
          expect(requests, 12);
        } finally {
          releaseImages.complete();
          results = await images;
        }
        expect(results, everyElement(isA<ProviderRequestBlocked>()));
        expect(requests, 12);
        await expectLater(
          service.get(origin.resolve('/after-refusal.png').toString()),
          throwsA(isA<ProviderRequestBlocked>()),
        );
        expect(requests, 12);
        if (code == 401) {
          ProviderRequestGate.instance.check(origin.resolve('/movie.ts'));
        } else {
          expect(
            () => ProviderRequestGate.instance.check(origin),
            throwsA(isA<ProviderRequestBlocked>()),
          );
        }
      });
    }
  });
}
