import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/cloud_config.dart';
import 'package:iptvs/data/cloud_sync.dart';
import 'package:iptvs/l10n/app_language.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    final previousLanguage = AppLanguageController.instance.language;
    addTearDown(() => AppLanguageController.instance.preview(previousLanguage));
  });

  test('panel links carry the chosen app language with or without a code', () {
    expect(
      pairingPanelLink(
        'https://panel.example/panel/?foo=1',
        'ABCD2345',
        language: 'pl',
      ),
      'https://panel.example/panel/?foo=1&code=ABCD2345&lang=pl',
    );
    expect(
      pairingPanelLink('https://panel.example/?lang=pl', '', language: 'en'),
      'https://panel.example/?lang=en',
    );
    expect(
      pairingPanelLink('https://panel.example/', 'ABCD2345', language: 'xx'),
      'https://panel.example/?code=ABCD2345',
    );
    expect(pairingPanelLink('invalid', 'ABCD2345', language: 'pl'), 'invalid');
  });

  for (final language in AppLanguage.values) {
    test(
      'pairing code request sends the selected ${language.code} language',
      () async {
        AppLanguageController.instance.preview(language);
        final requests = <Map<String, dynamic>>[];
        final sync = await pairingSync((request, body) {
          requests.add(body);
          request.response.write(
            jsonEncode([
              {'code': 'ABCD2345', 'expires_at': '2026-10-24T12:00:00Z'},
            ]),
          );
        });
        expect(
          (await sync.requestPairingCode(label: 'Android TV')).code,
          'ABCD2345',
        );
        expect(requests, [
          {'p_label': 'Android TV', 'p_language': language.code},
        ]);
      },
    );
  }

  test(
    'missing language and label overloads fall back only once each',
    () async {
      AppLanguageController.instance.preview(AppLanguage.polish);
      final requests = <Map<String, dynamic>>[];
      final sync = await pairingSync((request, body) {
        requests.add(body);
        if (body.isNotEmpty) {
          request.response.statusCode = 404;
          request.response.write(
            jsonEncode({'code': 'PGRST202', 'message': 'Function not found'}),
          );
        } else {
          request.response.write(
            jsonEncode([
              {'code': 'ABCD2345', 'expires_at': '2026-10-24T12:00:00Z'},
            ]),
          );
        }
      });
      expect((await sync.requestPairingCode(label: 'TV')).code, 'ABCD2345');
      expect(requests, [
        {'p_label': 'TV', 'p_language': 'pl'},
        {'p_label': 'TV'},
        <String, dynamic>{},
      ]);
    },
  );

  test('rate-limit failures never retry an older request overload', () async {
    var requests = 0;
    final sync = await pairingSync((request, body) {
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
  });

  test('an older native API keeps the device-name pairing fallback', () async {
    final requests = <Map<String, dynamic>>[];
    final sync = await pairingSync((request, body) {
      requests.add(body);
      if (body.containsKey('p_language')) {
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
            {'code': 'ABCD2345', 'expires_at': '2026-10-24T12:00:00Z'},
          ]),
        );
      }
    });
    expect((await sync.requestPairingCode(label: 'TV')).code, 'ABCD2345');
    expect(requests.length, 2);
    expect(requests.last, {'p_label': 'TV'});
  });
}

Future<CloudSync> pairingSync(
  void Function(HttpRequest request, Map<String, dynamic> body) respond,
) async {
  final previousOverrides = HttpOverrides.current;
  HttpOverrides.global = null;
  addTearDown(() {
    HttpOverrides.global = previousOverrides;
  });
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => server.close(force: true));
  server.listen((request) async {
    expect(request.uri.path, '/rest/v1/rpc/request_pairing');
    final body =
        (jsonDecode(await utf8.decoder.bind(request).join())
            as Map<String, dynamic>?) ??
        <String, dynamic>{};
    request.response.headers.contentType = ContentType.json;
    respond(request, body);
    await request.response.close();
  });
  final client = SupabaseClient('http://127.0.0.1:${server.port}', 'test-key');
  addTearDown(client.dispose);
  return _PairingSync(client);
}

class _PairingSync extends CloudSync {
  _PairingSync(SupabaseClient client) : super(client: client);

  @override
  Future<void> ensureAnonSession() async {}
}
