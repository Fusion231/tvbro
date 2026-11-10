import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/cloud_sync.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Realtime profile update classification', () {
    Map<String, dynamic> row({int revision = 1}) => {
      'id': 'profile',
      'name': 'Living room',
      'position': 0,
      'pin': null,
      'favorites': [
        {'source_id': 'source', 'kind': 'series', 'item_id': 'series'},
      ],
      'updated_at': '2026-10-25T10:00:00Z',
      'playback_revision': revision,
    };

    test('a changed playback revision with unchanged profile is selective', () {
      expect(
        classifyCloudProfileChange(row(), row(revision: 2)),
        CloudProfileChange.playback,
      );
    });

    test(
      'favorites compare structurally rather than by decoded object identity',
      () {
        final next = row(revision: 2);
        next['favorites'] = [
          {'item_id': 'series', 'kind': 'series', 'source_id': 'source'},
        ];
        expect(
          classifyCloudProfileChange(row(), next),
          CloudProfileChange.playback,
        );
        next['favorites'] = [];
        expect(
          classifyCloudProfileChange(row(), next),
          CloudProfileChange.profile,
        );
      },
    );

    test('configuration edits stay full even when playback changes too', () {
      for (final changed in [
        {'updated_at': '2026-10-25T10:01:00Z'},
        {'name': 'Bedroom'},
        {'pin': 'new-verifier'},
        {'position': 1},
        {'future_config_field': true},
      ]) {
        expect(
          classifyCloudProfileChange(row(), {...row(revision: 2), ...changed}),
          CloudProfileChange.profile,
        );
      }
    });

    test('partial and legacy payloads retain the full-profile fallback', () {
      expect(
        classifyCloudProfileChange({'id': 'profile'}, row(revision: 2)),
        CloudProfileChange.profile,
      );
      expect(classifyCloudProfileChange({}, {}), CloudProfileChange.profile);
      final missingFavorites = row()..remove('favorites');
      expect(
        classifyCloudProfileChange(missingFavorites, row(revision: 2)),
        CloudProfileChange.profile,
      );
    });

    test(
      'successive partial-old updates use a complete same-profile baseline',
      () {
        const oldKey = {'id': 'profile'};
        var baseline = row();
        expect(
          classifyCloudProfileChange(oldKey, baseline),
          CloudProfileChange.profile,
        );
        final progress = row(revision: 2);
        expect(
          classifyCloudProfileChange(
            oldKey,
            progress,
            lastKnownRecord: baseline,
          ),
          CloudProfileChange.playback,
        );
        baseline = progress;
        final configuration = {...row(revision: 3), 'name': 'Bedroom'};
        expect(
          classifyCloudProfileChange(
            oldKey,
            configuration,
            lastKnownRecord: baseline,
          ),
          CloudProfileChange.profile,
        );
        baseline = configuration;
        expect(
          classifyCloudProfileChange(oldKey, {
            ...configuration,
            'playback_revision': 4,
          }, lastKnownRecord: baseline),
          CloudProfileChange.playback,
        );
      },
    );

    test('partial or different-profile baselines cannot narrow an update', () {
      for (final baseline in [
        <String, dynamic>{'id': 'profile'},
        {...row(), 'id': 'other-profile'},
      ]) {
        expect(
          classifyCloudProfileChange(
            {'id': 'profile'},
            row(revision: 2),
            lastKnownRecord: baseline,
          ),
          CloudProfileChange.profile,
        );
      }
      expect(
        classifyCloudProfileChange(
          {'id': 'other-profile'},
          row(revision: 2),
          lastKnownRecord: row(),
        ),
        CloudProfileChange.profile,
      );
      expect(
        classifyCloudProfileChange(
          {'id': 'profile'},
          {'id': 'profile'},
          lastKnownRecord: row(),
        ),
        CloudProfileChange.profile,
      );
    });

    test(
      'unchanged, reset and invalid playback revisions are not selective',
      () {
        for (final revision in [1, 0, null, 'invalid']) {
          expect(
            classifyCloudProfileChange(row(), {
              ...row(),
              'playback_revision': revision,
            }),
            CloudProfileChange.profile,
          );
        }
      },
    );
  });

  group('native profile update observer', () {
    late HttpServer server;
    late SupabaseClient client;
    late CloudSync sync;
    late String token;
    late List<HttpRequest> requests;
    late Future<void> Function(HttpRequest) respond;

    setUp(() async {
      final previousOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = previousOverrides);
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      requests = [];
      server.listen((request) async {
        requests.add(request);
        await respond(request);
      });
      final url = 'http://127.0.0.1:${server.port}';
      client = SupabaseClient(url, 'test-key');
      String encoded(Map<String, dynamic> value) =>
          base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
      token =
          '${encoded({'alg': 'HS256', 'typ': 'JWT'})}.'
          '${encoded({'sub': 'device', 'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600})}.test-signature';
      await client.auth.recoverSession(
        jsonEncode({
          'access_token': token,
          'token_type': 'bearer',
          'user': {'id': 'device', 'aud': 'authenticated'},
        }),
      );
      sync = CloudSync(client: client, nativeApiUrl: '$url/api/');
    });

    tearDown(() async {
      await client.dispose();
      await server.close(force: true);
    });

    void send(HttpRequest request, String events) {
      // SSE responses stay open: Dart's default outbound buffer can retain
      // small chunks even after flush(), so match the API's unbuffered stream.
      request.response.bufferOutput = false;
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
      );
      request.response.write(events);
    }

    test(
      'opts in once and routes typed, legacy and unknown invalidations',
      () async {
        respond = (request) async {
          send(
            request,
            ': heartbeat\n\n'
            'event: profile_changed\ndata: {}\n\n'
            'event: playback_changed\ndata: {}\n\n'
            'event: legacy_change\ndata: {}\n\n'
            'data: {}\n\n',
          );
          await request.response.flush();
        };
        final updates = await sync
            .observeProfileUpdates('profile')
            .take(4)
            .toList();
        expect(updates, [
          CloudProfileChange.profile,
          CloudProfileChange.playback,
          CloudProfileChange.profile,
          CloudProfileChange.profile,
        ]);
        expect(requests, hasLength(1));
        expect(requests.single.uri.path, '/api/profile-events');
        expect(requests.single.uri.queryParameters, {
          'profile_id': 'profile',
          'playback_events': '1',
        });
        expect(
          requests.single.headers.value(HttpHeaders.authorizationHeader),
          'Bearer $token',
        );
        expect(
          requests.single.headers.value(HttpHeaders.acceptHeader),
          'text/event-stream',
        );
      },
    );

    test('a reconnect receives a full catch-up on the same observer', () async {
      respond = (request) async {
        if (requests.length == 1) {
          send(request, 'event: playback_changed\ndata: {}\n\n');
          await request.response.close();
        } else {
          send(request, 'event: profile_changed\ndata: {}\n\n');
          await request.response.flush();
        }
      };
      expect(await sync.observeProfileUpdates('profile').take(2).toList(), [
        CloudProfileChange.playback,
        CloudProfileChange.profile,
      ]);
      expect(requests, hasLength(2));
    });

    test(
      'an old API falls back once and reconnects with generic legacy events',
      () async {
        respond = (request) async {
          if (request.uri.queryParameters.containsKey('playback_events')) {
            request.response.statusCode = HttpStatus.badRequest;
            request.response.write('{"message":"unknown query parameter"}');
            await request.response.close();
          } else if (requests.length == 2) {
            send(
              request,
              'event: profile_changed\ndata: {}\n\n'
              'event: playback_changed\ndata: {}\n\n',
            );
            await request.response.close();
          } else {
            send(request, 'event: profile_changed\ndata: {}\n\n');
            await request.response.flush();
          }
        };
        expect(
          await sync.observeProfileUpdates('profile').take(3).toList(),
          List.filled(3, CloudProfileChange.profile),
        );
        expect(requests.map((request) => request.uri.queryParameters), [
          {'profile_id': 'profile', 'playback_events': '1'},
          {'profile_id': 'profile'},
          {'profile_id': 'profile'},
        ]);
      },
    );

    for (final status in [HttpStatus.unauthorized, HttpStatus.forbidden]) {
      test('HTTP $status does not retry as a legacy subscription', () async {
        final received = Completer<void>();
        respond = (request) async {
          request.response.statusCode = status;
          await request.response.close();
          if (!received.isCompleted) received.complete();
        };
        final subscription = sync.observeProfileUpdates('profile').listen((_) {
          fail('An authentication failure must not emit profile updates');
        });
        await received.future;
        await subscription.cancel();
        expect(requests, hasLength(1));
        expect(requests.single.uri.queryParameters['playback_events'], '1');
      });
    }

    test(
      'legacy void observers still receive both kinds over one connection',
      () async {
        respond = (request) async {
          send(
            request,
            'event: profile_changed\ndata: {}\n\n'
            'event: playback_changed\ndata: {}\n\n',
          );
          await request.response.flush();
        };
        expect(
          await sync.observeProfileChanges('profile').take(2).toList(),
          hasLength(2),
        );
        expect(requests, hasLength(1));
      },
    );

    test(
      'cancellation stops reconnection after a completed response',
      () async {
        final received = Completer<void>();
        respond = (request) async {
          send(request, 'event: profile_changed\ndata: {}\n\n');
          await request.response.close();
        };
        final subscription = sync.observeProfileUpdates('profile').listen((_) {
          if (!received.isCompleted) received.complete();
        });
        await received.future;
        await subscription.cancel();
        await Future<void>.delayed(const Duration(milliseconds: 2200));
        expect(requests, hasLength(1));
      },
    );
  });
}
