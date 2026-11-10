import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/cloud_sync.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _hint =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a paired installation registers its hint once without pairing again',
    () async {
      final calls = <String>[];
      final sync = await _identitySync((request, body) {
        calls.add(request.uri.path);
        if (request.uri.path.endsWith('/devices')) {
          request.response.write(
            jsonEncode([
              {'device_uid': 'existing-device'},
            ]),
          );
        } else {
          expect(body, {'p_identity': _hint});
          request.response.write('null');
        }
      });
      expect(await sync.isPaired(), isTrue);
      expect(await sync.isPaired(), isTrue);
      expect(
        calls.where((path) => path.endsWith('/register_device_identity')),
        hasLength(1),
      );
      expect(calls.where((path) => path.endsWith('/request_pairing')), isEmpty);
    },
  );

  test(
    'a sessionless device does not look up an account using its hint',
    () async {
      var identityReads = 0;
      final sync = await _identitySync(
        (request, body) {
          fail('A sessionless installation must not contact the server');
        },
        deviceIdentity: () async {
          identityReads++;
          return _hint;
        },
      );
      sync.currentDevice = null;
      expect(await sync.isPaired(), isFalse);
      expect(identityReads, 0);
    },
  );

  test(
    'a reinstall includes its hint only in owner-confirmed pairing',
    () async {
      final sync = await _identitySync((request, body) {
        expect(request.uri.path, '/rest/v1/rpc/request_pairing');
        expect(body['p_device_identity'], _hint);
        expect(body['p_label'], 'Living room');
        expect(body['p_language'], isIn(['pl', 'en']));
        request.response.write(
          jsonEncode([
            {'code': 'ABCD2345', 'expires_at': '2099-01-01T00:00:00Z'},
          ]),
        );
      });
      expect(
        (await sync.requestPairingCode(label: 'Living room')).code,
        'ABCD2345',
      );
    },
  );

  test(
    'an older backend falls back to language pairing without the hint',
    () async {
      final requests = <Map<String, dynamic>>[];
      final sync = await _identitySync((request, body) {
        requests.add(body);
        if (body.containsKey('p_device_identity')) {
          request.response.statusCode = 400;
          request.response.write(
            jsonEncode({
              'code': 'invalid_request',
              'message': 'Invalid database request',
            }),
          );
        } else {
          request.response.write(
            jsonEncode([
              {'code': 'ABCD2345', 'expires_at': '2099-01-01T00:00:00Z'},
            ]),
          );
        }
      });
      expect((await sync.requestPairingCode(label: 'TV')).code, 'ABCD2345');
      expect(requests, hasLength(2));
      expect(requests.last.containsKey('p_device_identity'), isFalse);
      expect(requests.last.containsKey('p_language'), isTrue);
    },
  );

  test(
    'rate limits on identity pairing never retry a legacy overload',
    () async {
      var requests = 0;
      final sync = await _identitySync((request, body) {
        requests++;
        request.response.statusCode = 429;
        request.response.write(
          jsonEncode({
            'code': '23514',
            'message': 'iptvs: too many pairing requests, slow down',
          }),
        );
      });
      await expectLater(
        sync.requestPairingCode(label: 'TV'),
        throwsA(isA<PostgrestException>()),
      );
      expect(requests, 1);
    },
  );

  test(
    'registration failures do not disconnect an already-paired device',
    () async {
      for (final code in ['PGRST202', 'temporary_failure']) {
        final sync = await _identitySync((request, body) {
          if (request.uri.path.endsWith('/devices')) {
            request.response.write(
              jsonEncode([
                {'device_uid': 'existing-device'},
              ]),
            );
          } else {
            request.response.statusCode = code == 'PGRST202' ? 404 : 503;
            request.response.write(
              jsonEncode({'code': code, 'message': 'Unavailable'}),
            );
          }
        });
        expect(await sync.isPaired(), isTrue);
      }
    },
  );

  test(
    'unavailable or malformed platform hints keep ordinary pairing usable',
    () async {
      for (final hint in [null, '', 'hardware-id', 'a' * 63, 'A' * 64]) {
        final sync = await _identitySync((request, body) {
          expect(body.containsKey('p_device_identity'), isFalse);
          request.response.write(
            jsonEncode([
              {'code': 'ABCD2345', 'expires_at': '2099-01-01T00:00:00Z'},
            ]),
          );
        }, deviceIdentity: () async => hint);
        expect((await sync.requestPairingCode(label: 'TV')).code, 'ABCD2345');
      }
    },
  );

  test(
    'a session change during detection cannot register the previous session',
    () async {
      final requested = Completer<void>();
      final identity = Completer<String?>();
      final calls = <String>[];
      final sync = await _identitySync(
        (request, body) {
          calls.add(request.uri.path);
          request.response.write(
            jsonEncode([
              {'device_uid': 'existing-device'},
            ]),
          );
        },
        deviceIdentity: () {
          requested.complete();
          return identity.future;
        },
      );
      final result = sync.isPaired();
      await requested.future;
      sync.currentDevice = 'another-device';
      identity.complete(_hint);
      expect(await result, isFalse);
      expect(calls, ['/rest/v1/devices']);
    },
  );
}

Future<_IdentitySync> _identitySync(
  void Function(HttpRequest, Map<String, dynamic>) respond, {
  Future<String?> Function()? deviceIdentity,
}) async {
  final previousOverrides = HttpOverrides.current;
  HttpOverrides.global = null;
  addTearDown(() => HttpOverrides.global = previousOverrides);
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => server.close(force: true));
  server.listen((request) async {
    final raw = await utf8.decoder.bind(request).join();
    final body = raw.isEmpty
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(jsonDecode(raw) as Map);
    request.response.headers.contentType = ContentType.json;
    respond(request, body);
    await request.response.close();
  });
  final client = SupabaseClient('http://127.0.0.1:${server.port}', 'test-key');
  addTearDown(client.dispose);
  return _IdentitySync(client, deviceIdentity ?? () async => _hint);
}

class _IdentitySync extends CloudSync {
  String? currentDevice = 'existing-device';

  _IdentitySync(SupabaseClient client, Future<String?> Function() identity)
    : super(client: client, deviceIdentity: identity);

  @override
  String? get deviceId => currentDevice;

  @override
  Future<void> ensureAnonSession() async {}
}
