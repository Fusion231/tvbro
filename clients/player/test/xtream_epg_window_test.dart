import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/net.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/xtream_source.dart';

void main() {
  late HttpServer server;
  late XtreamSource source;
  late int status, xmltvRequests, apiRequests, apiFailureStatus;
  late bool apiFailure, oversized, physicalApi;
  late List<DateTime> starts;
  final channels = List.generate(13, (i) => Channel(id: '$i', name: 'Channel $i'));
  setUp(() async {
    ProviderRequestGate.instance.debugReset();
    status = 502; xmltvRequests = 0; apiRequests = 0; apiFailure = false; oversized = false; physicalApi = false;
    apiFailureStatus = 502;
    starts = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      if (physicalApi && request.uri.path == '/player_api.php') {
        apiRequests++; starts.add(DateTime.now());
        expect(request.uri.queryParameters['action'], 'get_short_epg');
        request.response.write(jsonEncode({'epg_listings': [{'start_timestamp': '1792962000', 'stop_timestamp': '1792965600',
          'title': base64Encode(utf8.encode('Wiadomości')), 'description': base64Encode(utf8.encode('Opis'))}]}));
        await request.response.close();
        return;
      }
      xmltvRequests++;
      if (oversized) {
        final socket = await request.response.detachSocket(writeHeaders: false);
        socket.write('HTTP/1.1 200 OK\r\nContent-Length: 536870913\r\nConnection: close\r\n\r\n');
        await socket.close();
        return;
      }
      request.response.statusCode = status;
      request.response.write(status == 200 ? '<tv></tv>' : 'Unavailable');
      await request.response.close();
    });
    source = XtreamSource(sourceId: 'window', host: 'http://127.0.0.1:${server.port}',
      username: 'user', password: 'pass', debugApi: (params) async {
        apiRequests++; starts.add(DateTime.now());
        expect(params['action'], 'get_short_epg');
        if (apiFailure) throw StateError('HTTP $apiFailureStatus fetching per-channel guide');
        return {'epg_listings': [{'start_timestamp': '1792962000', 'stop_timestamp': '1792965600',
          'title': base64Encode(utf8.encode('Wiadomości')), 'description': base64Encode(utf8.encode('Opis'))}]};
      });
  });
  tearDown(() async { await source.dispose(); await server.close(force: true); });

  test('502 uses per-channel guide, overlapping windows reuse cache and rate limit', () async {
    final first = await source.epgForWindow(channels.take(2).toList());
    expect(first.map((p) => p.channelId), ['0', '1']);
    expect(first.first.title, 'Wiadomości');
    expect(first.first.description, 'Opis');
    expect(starts[1].difference(starts[0]).inMilliseconds, greaterThanOrEqualTo(950));
    await source.epgForWindow([channels[1], channels[0]]);
    expect(xmltvRequests, 1); expect(apiRequests, 2);
  });

  test('shared HTTP admission cannot consume the fallback guide quiet period', () async {
    ProviderRequestGate.instance.debugReset(minimumStartGap: const Duration(milliseconds: 250));
    physicalApi = true;
    await source.dispose();
    source = XtreamSource(sourceId: 'physical-window', host: 'http://127.0.0.1:${server.port}',
      username: 'user', password: 'pass');
    final first = await source.epgForWindow(channels.take(2).toList());
    expect(first, hasLength(2));
    expect(starts[1].difference(starts[0]).inMilliseconds, greaterThanOrEqualTo(950));
    expect(xmltvRequests, 1); expect(apiRequests, 2);
  });

  test('successful empty XMLTV does not probe per-channel API', () async {
    status = 200;
    expect(await source.epgForWindow([channels[0]]), isEmpty);
    expect(apiRequests, 0);
  });

  test('oversized XMLTV uses bounded per-channel guide without another download', () async {
    oversized = true;
    expect(await source.epgForWindow([channels[0]]), hasLength(1));
    expect(await source.epgForWindow([channels[0]]), hasLength(1));
    expect(xmltvRequests, 1); expect(apiRequests, 1);
  });

  for (final refusal in [401, 429]) {
    test('$refusal never falls back or retries the provider API', () async {
      status = refusal;
      await expectLater(source.epgForWindow([channels[0]]), throwsA(isA<ProviderRequestBlocked>()));
      await expectLater(source.epgForWindow([channels[1]]), throwsA(isA<ProviderRequestBlocked>()));
      expect(xmltvRequests, 1); expect(apiRequests, 0);
    });
  }

  test('a manual XMLTV retry after HTTP 403 reaches the provider again', () async {
    status = 403;
    await expectLater(source.epgForWindow([channels[0]]), throwsStateError);
    expect(xmltvRequests, 1); expect(apiRequests, 0);
    status = 200;
    expect(await source.epgForWindow([channels[1]]), isEmpty);
    expect(xmltvRequests, 2); expect(apiRequests, 0);
  });

  test('a failed channel API stops the window and later windows', () async {
    apiFailure = true;
    await expectLater(source.epgForWindow(channels.take(3).toList()), throwsStateError);
    await expectLater(source.epgForWindow([channels[5]]), throwsStateError);
    expect(xmltvRequests, 1); expect(apiRequests, 1);
  });

  test('a manual per-channel guide retry after HTTP 403 reaches the API again', () async {
    apiFailure = true;
    apiFailureStatus = 403;
    await expectLater(source.epgForWindow([channels[0]]), throwsStateError);
    expect(xmltvRequests, 1); expect(apiRequests, 1);

    apiFailure = false;
    expect(await source.epgForWindow([channels[0]]), hasLength(1));
    expect(xmltvRequests, 1); expect(apiRequests, 2);
  });

  test('bulk guide request never fans out across channels', () async {
    await expectLater(source.epgForWindow(channels), throwsStateError);
    expect(xmltvRequests, 1); expect(apiRequests, 0);
  });
}
