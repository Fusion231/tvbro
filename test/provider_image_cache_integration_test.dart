import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/provider_image_cache.dart';
import 'package:iptvs/data/provider_request_gate.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final originalOverrides = HttpOverrides.current;
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  late Directory directory;
  late HttpServer server;
  late Uri origin;
  var requests = 0;
  Future<void> Function(HttpRequest)? onRequest;

  setUpAll(() async {
    // These are local HTTP fixture tests, not widget image mocks.
    HttpOverrides.global = null;
    directory = await Directory.systemTemp.createTemp('provider_artwork_cache');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(paths, (_) async => directory.path);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      configureProviderImages();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  tearDownAll(() async {
    await providerImageCache.dispose();
    (providerImageCache.config.fileService as ProviderImageFileService).close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(paths, null);
    HttpOverrides.global = originalOverrides;
    await directory.delete(recursive: true);
  });

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    ProviderRequestGate.instance.debugReset();
    requests = 0;
    onRequest = null;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin = Uri.parse('http://127.0.0.1:${server.port}');
    server.listen((request) async {
      requests++;
      await onRequest?.call(request);
      request.response.headers.set('cache-control', 'max-age=3600');
      request.response.add([1, 2, 3]);
      await request.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    ProviderRequestGate.instance.debugReset();
    debugDefaultTargetPlatformOverride = null;
  });

  test(
    'Android cache downloads twelve images before admitting the next',
    () async {
      final service =
          providerImageCache.config.fileService as ProviderImageFileService;
      expect(service.concurrentFetches, 12);
      final firstBatchStarted = Completer<void>();
      final releaseFirstBatch = Completer<void>();
      var active = 0;
      var peak = 0;
      onRequest = (_) async {
        active++;
        if (active > peak) peak = active;
        if (requests == 12) firstBatchStarted.complete();
        if (requests <= 12) await releaseFirstBatch.future;
        active--;
      };
      final downloads = Future.wait([
        for (var i = 0; i < 13; i++)
          providerImageCache.getSingleFile(
            origin.resolve('/batch-$i.png').toString(),
          ),
      ]);
      try {
        await firstBatchStarted.future.timeout(const Duration(seconds: 5));
        expect(requests, 12);
        expect(active, 12);
      } finally {
        releaseFirstBatch.complete();
        await downloads;
      }
      expect(requests, 13);
      expect(peak, 12);
    },
  );

  test(
    'Flutter provider and native artwork share one disk cache and request',
    () async {
      expect(
        CachedNetworkImageProvider.defaultCacheManager,
        same(providerImageCache),
      );
      expect(providerImageCache.config.cacheKey, 'libCachedImageData');
      final url = origin.resolve('/shared-logo.png').toString();
      final loaded = await Future.wait([
        providerImageCache.getSingleFile(url).then((file) => file.path),
        loadCachedArtworkPath(url),
      ]);
      expect(loaded[0], loaded[1]);
      expect(requests, 1);
      ProviderRequestGate.instance.recordResponse(origin, 429);
      expect(await loadCachedArtworkPath(url), loaded.first);
      expect(requests, 1);
    },
  );

  test(
    'native artwork keeps a stale local file during provider cooldown',
    () async {
      final url = origin.resolve('/stale-logo.png').toString();
      final cached = await providerImageCache.putFile(
        url,
        Uint8List.fromList([4, 5, 6]),
        maxAge: Duration.zero,
      );
      ProviderRequestGate.instance.recordResponse(origin, 401);
      expect(await loadCachedArtworkPath(url), cached.path);
      expect(requests, 0);
    },
  );

  test('native cancellation before lookup sends no image request', () async {
    await expectLater(
      loadCachedArtworkPath(
        origin.resolve('/cancelled.png').toString(),
        checkCancellation: () => throw StateError('cancelled'),
      ),
      throwsStateError,
    );
    expect(requests, 0);
  });
}
