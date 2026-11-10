import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/load_token.dart';
import 'package:iptvs/data/net.dart';

void main() {
  late HttpClient client;
  late HttpServer origin;
  late HttpServer destination;
  late Uri originUri;
  late Uri destinationUri;
  var originRequests = 0;
  var destinationRequests = 0;
  var status = 200;
  String? authorization;
  String? cookie;

  setUp(() async {
    ProviderRequestGate.instance.debugReset();
    client = HttpClient();
    originRequests = destinationRequests = 0;
    status = 200;
    authorization = cookie = null;
    origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    destination = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    originUri = Uri.parse('http://127.0.0.1:${origin.port}/start');
    destinationUri = Uri.parse('http://localhost:${destination.port}/end');
    origin.listen((request) async {
      originRequests++;
      request.response.statusCode = 302;
      request.response.headers.set(HttpHeaders.locationHeader, destinationUri);
      await request.response.close();
    });
    destination.listen((request) async {
      destinationRequests++;
      authorization = request.headers.value(HttpHeaders.authorizationHeader);
      cookie = request.headers.value(HttpHeaders.cookieHeader);
      request.response.statusCode = status;
      request.response.write('response');
      await request.response.close();
    });
  });

  tearDown(() async {
    client.close(force: true);
    await origin.close(force: true);
    await destination.close(force: true);
  });

  Future<String> get(Uri uri, {Map<String, String> headers = const {}}) {
    final operation = HttpOperation(kProviderJsonWorkload);
    return providerHttpGet(
      uri,
      client: client,
      operation: operation,
      headers: headers,
      readResponse: (response) async =>
          String.fromCharCodes(await operation.readBytes(response)),
    );
  }

  test('redirects cannot send traffic to a paused destination', () async {
    ProviderRequestGate.instance.recordResponse(destinationUri, 429);
    await expectLater(get(originUri), throwsA(isA<ProviderRequestBlocked>()));
    expect(originRequests, 1);
    expect(destinationRequests, 0);
  });

  test(
    'a redirected refusal pauses both origin and actual responder',
    () async {
      status = 429;
      await expectLater(get(originUri), throwsA(isA<ProviderRequestBlocked>()));
      await expectLater(get(originUri), throwsA(isA<ProviderRequestBlocked>()));
      await expectLater(
        get(destinationUri),
        throwsA(isA<ProviderRequestBlocked>()),
      );
      expect(originRequests, 1);
      expect(destinationRequests, 1);
    },
  );

  test(
    'cross-host redirects do not forward bearer tokens or cookies',
    () async {
      expect(
        await get(
          originUri,
          headers: {
            HttpHeaders.authorizationHeader: 'Bearer private',
            HttpHeaders.cookieHeader: 'mac=private',
          },
        ),
        'response',
      );
      expect(authorization, isNull);
      expect(cookie, isNull);
    },
  );

  test(
    'header timeout aborts the socket before releasing its permit',
    () async {
      final stalled = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => stalled.close(force: true));
      final disconnected = Completer<void>();
      stalled.listen((request) async {
        final socket = await request.response.detachSocket(writeHeaders: false);
        socket.listen(
          (_) {},
          onDone: () {
            if (!disconnected.isCompleted) disconnected.complete();
            socket.destroy();
          },
        );
      });
      final operation = HttpOperation(
        kProviderJsonWorkload.copyWith(
          totalTimeout: const Duration(milliseconds: 200),
        ),
      );
      await expectLater(
        providerHttpGet(
          Uri.parse('http://127.0.0.1:${stalled.port}/stalled'),
          client: client,
          operation: operation,
          readResponse: operation.readBytes,
        ),
        throwsA(
          isA<TimeoutException>().having(
            (error) => error.message,
            'message',
            contains('deadline'),
          ),
        ),
      );
      await disconnected.future.timeout(const Duration(seconds: 3));
    },
  );

  test('total deadline includes waiting for occupied provider slots', () async {
    final body = Completer<void>();
    final occupied = List.generate(
      2,
      (_) => ProviderRequestGate.instance.run(originUri, () => body.future),
    );
    try {
      final operation = HttpOperation(
        kProviderJsonWorkload.copyWith(
          totalTimeout: const Duration(milliseconds: 100),
        ),
      );
      await expectLater(
        providerHttpGet(
          originUri,
          client: client,
          operation: operation,
          readResponse: operation.readBytes,
        ).timeout(const Duration(seconds: 2)),
        throwsA(
          isA<TimeoutException>().having(
            (error) => error.message,
            'message',
            contains('deadline'),
          ),
        ),
      );
      expect(originRequests, 0);
    } finally {
      body.complete();
      await Future.wait(occupied);
    }
    expect(await get(originUri), 'response');
    expect(originRequests, 1);
  });

  test('cancelled queued transport never opens a provider connection', () async {
    final body = Completer<void>();
    final occupied = List.generate(
      2,
      (_) => ProviderRequestGate.instance.run(originUri, () => body.future),
    );
    final token = LoadToken();
    final operation = HttpOperation(kProviderJsonWorkload);
    try {
      final result = providerHttpGet(
        originUri,
        client: client,
        operation: operation,
        token: token,
        readResponse: operation.readBytes,
      );
      final rejected = expectLater(result, throwsA(isA<LoadCancelledException>()));
      token.cancel();
      await rejected.timeout(const Duration(seconds: 2));
      expect(originRequests, 0);
    } finally {
      body.complete();
      await Future.wait(occupied);
    }
    expect(await get(originUri), 'response');
    expect(originRequests, 1);
  });

  test('cancellation aborts an admitted HTTP request and releases its slot', () async {
    final stalled = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => stalled.close(force: true));
    final connected = Completer<void>();
    final disconnected = Completer<void>();
    stalled.listen((request) async {
      final socket = await request.response.detachSocket(writeHeaders: false);
      connected.complete();
      socket.listen(
        (_) {},
        onDone: () {
          if (!disconnected.isCompleted) disconnected.complete();
          socket.destroy();
        },
      );
    });
    final token = LoadToken();
    final operation = HttpOperation(kProviderJsonWorkload);
    final result = providerHttpGet(
      Uri.parse('http://127.0.0.1:${stalled.port}/stalled'),
      client: client,
      operation: operation,
      token: token,
      readResponse: operation.readBytes,
    );
    final rejected = expectLater(result, throwsA(isA<LoadCancelledException>()));
    await connected.future.timeout(const Duration(seconds: 3));
    token.cancel();
    await rejected.timeout(const Duration(seconds: 2));
    await disconnected.future.timeout(const Duration(seconds: 3));
    expect(await get(originUri), 'response');
  });
}
