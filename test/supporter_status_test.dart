import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/cloud_sync.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'device sends an empty argument object to read assigned access',
    () async {
      final previousOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = previousOverrides);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var reads = 0;
      server.listen((request) async {
        expect(request.uri.path, '/rest/v1/rpc/get_supporter_status');
        expect(request.method, 'POST');
        final body = jsonDecode(await utf8.decoder.bind(request).join());
        request.response.headers.contentType = ContentType.json;
        if (body is! Map || body.isNotEmpty) {
          request.response.statusCode = 400;
          request.response.write(
            '{"code":"invalid_request","message":"Invalid database request"}',
          );
        } else {
          reads++;
          request.response.write(
            jsonEncode({
              'status': 'trialing',
              'supported': true,
              'device_limit': 5,
              'valid_until': '2099-01-01T00:00:00Z',
            }),
          );
        }
        await request.response.close();
      });
      final client = SupabaseClient(
        'http://127.0.0.1:${server.port}',
        'test-key',
      );
      addTearDown(client.dispose);
      final status = await _SessionSync(client).supporterStatus();
      expect(status.isActiveAt(DateTime.utc(2026, 10, 24)), isTrue);
      expect(status.status, 'trialing');
      expect(reads, 1);
    },
  );

  test('supporter status expires locally at its server-issued deadline', () {
    final status = SupporterStatus.fromJson({
      'status': 'active',
      'supported': true,
      'device_limit': 10,
      'valid_until': '2026-11-01T00:00:00Z',
    });
    expect(status.deviceLimit, 10);
    expect(status.isActiveAt(DateTime.utc(2026, 10, 31)), isTrue);
    expect(status.isActiveAt(DateTime.utc(2026, 11)), isFalse);
  });

  test(
    'missing, malformed or unassigned status never shows active support',
    () {
      for (final json in <Map<String, dynamic>>[
        {},
        {'supported': 'true', 'device_limit': 999},
        {'supported': true, 'valid_until': 'invalid'},
        {'supported': false, 'valid_until': '2026-11-01T00:00:00Z'},
      ]) {
        expect(
          SupporterStatus.fromJson(json).isActiveAt(DateTime.utc(2026, 10)),
          isFalse,
        );
      }
    },
  );
}

class _SessionSync extends CloudSync {
  _SessionSync(SupabaseClient client) : super(client: client);

  @override
  bool get hasSession => true;
}
