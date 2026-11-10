import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/load_token.dart';
import 'package:iptvs/data/net.dart';

void main() {
  final epoch = DateTime.utc(2026, 10, 23, 12);
  final uri = Uri.parse('https://provider.test/api?username=private');

  test('paces 250 ms starts across ports and limits in-flight bodies', () {
    fakeAsync((clock) {
      final gate = ProviderRequestGate(now: () => epoch.add(clock.elapsed));
      final bodies = List.generate(4, (_) => Completer<void>());
      final starts = <Duration>[];
      var completed = 0;
      for (var i = 0; i < bodies.length; i++) {
        gate
            .run(uri.replace(port: 8000 + i), () {
              starts.add(clock.elapsed);
              return bodies[i].future;
            })
            .then((_) => completed++);
      }
      clock.flushMicrotasks();
      expect(starts, [Duration.zero]);
      clock.elapse(const Duration(milliseconds: 249));
      expect(starts, [Duration.zero]);
      clock.elapse(const Duration(milliseconds: 1));
      expect(starts, [Duration.zero, const Duration(milliseconds: 250)]);
      clock.elapse(const Duration(seconds: 5));
      expect(starts, hasLength(2));
      bodies[0].complete();
      clock.flushMicrotasks();
      expect(starts.last, const Duration(milliseconds: 5250));
      bodies[1].complete();
      clock.flushMicrotasks();
      clock.elapse(const Duration(milliseconds: 249));
      expect(starts, hasLength(3));
      clock.elapse(const Duration(milliseconds: 1));
      expect(starts.last, const Duration(milliseconds: 5500));
      bodies[2].complete();
      bodies[3].complete();
      clock.flushMicrotasks();
      expect(completed, 4);
    });
  });

  test('refusal stops queued work before it opens a socket', () {
    fakeAsync((clock) {
      final gate = ProviderRequestGate(now: () => epoch.add(clock.elapsed));
      var calls = 0;
      final errors = <Object>[];
      for (var i = 0; i < 8; i++) {
        gate
            .run(uri, () async {
              calls++;
              gate.recordResponse(uri, 429, retryAfter: '600');
              gate.check(uri);
            })
            .then<void>((_) {}, onError: (Object error) => errors.add(error));
      }
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 1));
      expect(calls, 1);
      expect(errors, hasLength(8));
      expect(errors, everyElement(isA<ProviderRequestBlocked>()));
      clock.elapse(const Duration(minutes: 9));
      expect(() => gate.check(uri), throwsA(isA<ProviderRequestBlocked>()));
      clock.elapse(const Duration(minutes: 1));
      expect(() => gate.check(uri), returnsNormally);
    });
  });

  test('cooldown wakes callers waiting for an occupied concurrency slot', () {
    fakeAsync((clock) {
      final gate = ProviderRequestGate(
        minimumStartGap: Duration.zero,
        maximumConcurrentRequests: 1,
        now: () => epoch.add(clock.elapsed),
      );
      final body = Completer<void>();
      var calls = 0;
      Object? blocked;
      gate.run(uri, () => body.future);
      gate
          .run(uri, () async {
            calls++;
          })
          .then<void>(
            (_) {},
            onError: (Object error) {
              blocked = error;
            },
          );
      clock.flushMicrotasks();
      gate.recordResponse(uri, 401);
      clock.flushMicrotasks();
      expect(blocked, isA<ProviderRequestBlocked>());
      expect(calls, 0);
      body.complete();
      clock.flushMicrotasks();
    });
  });

  test('HTTP dates extend the minimum pause and success cannot clear it', () {
    var now = epoch;
    final gate = ProviderRequestGate(now: () => now);
    final until = epoch.add(const Duration(hours: 1));
    gate.recordResponse(uri, 429, retryAfter: HttpDate.format(until));
    gate.recordResponse(uri, 200);
    now = epoch.add(const Duration(minutes: 1));
    gate.recordResponse(uri, 401, retryAfter: '1');
    expect(
      () => gate.check(Uri.parse('http://PROVIDER.test.:9999/other')),
      throwsA(
        isA<ProviderRequestBlocked>().having(
          (e) => e.retryAt,
          'retryAt',
          until,
        ),
      ),
    );
    expect(() => gate.check(Uri.parse('https://other.test')), returnsNormally);
    now = until;
    expect(() => gate.check(uri), returnsNormally);
  });

  test('a queued deadline expires without waiting for occupied bodies', () {
    fakeAsync((clock) {
      final gate = ProviderRequestGate(
        minimumStartGap: Duration.zero,
        maximumConcurrentRequests: 1,
        now: () => epoch.add(clock.elapsed),
      );
      final body = Completer<void>();
      gate.run(uri, () => body.future);
      var calls = 0;
      Object? failure;
      gate.run(uri, () async => calls++, timeout: const Duration(seconds: 1))
          .then<void>((_) {}, onError: (Object error) => failure = error);
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 1));
      expect(failure, isA<TimeoutException>());
      expect(calls, 0);
      body.complete();
      clock.flushMicrotasks();
      gate.run(uri, () async => calls++);
      clock.flushMicrotasks();
      expect(calls, 1);
    });
  });

  test('cancellation while pacing does not reserve an extra start gap', () {
    fakeAsync((clock) {
      final gate = ProviderRequestGate(now: () => epoch.add(clock.elapsed));
      final token = LoadToken();
      final starts = <Duration>[];
      var cancelledStarts = 0;
      Object? failure;
      gate.run(uri, () async => starts.add(clock.elapsed));
      gate.run(
        uri,
        () async => cancelledStarts++,
        cancellation: token.whenCancelled,
      ).then<void>((_) {}, onError: (Object error) => failure = error);
      gate.run(uri, () async => starts.add(clock.elapsed));
      clock.flushMicrotasks();
      clock.elapse(const Duration(milliseconds: 100));
      token.cancel();
      clock.flushMicrotasks();
      expect(failure, isA<LoadCancelledException>());
      clock.elapse(const Duration(milliseconds: 150));
      expect(starts, [Duration.zero, const Duration(milliseconds: 250)]);
      expect(cancelledStarts, 0);
    });
  });

  test('cancelling a middle FIFO entry cannot let its successor overtake', () {
    fakeAsync((clock) {
      final gate = ProviderRequestGate(
        minimumStartGap: Duration.zero,
        maximumConcurrentRequests: 1,
        now: () => epoch.add(clock.elapsed),
      );
      final body = Completer<void>();
      final nextBody = Completer<void>();
      final token = LoadToken();
      final calls = <String>[];
      Object? failure;
      gate.run(uri, () => body.future);
      gate.run(uri, () {
        calls.add('first');
        return nextBody.future;
      });
      gate.run(uri, () async => calls.add('cancelled'),
        cancellation: token.whenCancelled,
      ).then<void>((_) {}, onError: (Object error) => failure = error);
      gate.run(uri, () async => calls.add('last'));
      clock.flushMicrotasks();
      token.cancel();
      clock.flushMicrotasks();
      expect(failure, isA<LoadCancelledException>());
      expect(calls, isEmpty);
      body.complete();
      clock.flushMicrotasks();
      expect(calls, ['first']);
      nextBody.complete();
      clock.flushMicrotasks();
      expect(calls, ['first', 'last']);
    });
  });

  test('a deadline also covers FIFO waits behind a still-live entry', () {
    fakeAsync((clock) {
      final gate = ProviderRequestGate(
        minimumStartGap: Duration.zero,
        maximumConcurrentRequests: 1,
        now: () => epoch.add(clock.elapsed),
      );
      final body = Completer<void>();
      final calls = <String>[];
      Object? failure;
      gate.run(uri, () => body.future);
      gate.run(uri, () async => calls.add('first'));
      gate.run(uri, () async => calls.add('expired'),
        timeout: const Duration(seconds: 1),
      ).then<void>((_) {}, onError: (Object error) => failure = error);
      gate.run(uri, () async => calls.add('last'));
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 1));
      expect(failure, isA<TimeoutException>());
      body.complete();
      clock.flushMicrotasks();
      expect(calls, ['first', 'last']);
    });
  });

  for (final status in [401, 429]) {
    test('HTTP $status has a minimum pause with malformed Retry-After', () {
      final gate = ProviderRequestGate(now: () => epoch);
      gate.recordResponse(uri, status, retryAfter: 'not a date');
      expect(
        () => gate.check(uri),
        throwsA(
          isA<ProviderRequestBlocked>()
              .having((e) => e.status, 'status', status)
              .having(
                (e) => e.retryAt,
                'retryAt',
                epoch.add(const Duration(minutes: 5)),
              ),
        ),
      );
    });
  }

  test('HTTP 403 allows an immediate retry even with Retry-After', () async {
    final gate = ProviderRequestGate(
      minimumStartGap: Duration.zero,
      maximumConcurrentRequests: 1,
      now: () => epoch,
    );
    expect(
      await gate.run(uri, () async {
        gate.recordResponse(uri, 403, retryAfter: '3600');
        gate.check(uri);
        return 403;
      }),
      403,
    );
    expect(
      await gate.run(uri.replace(port: 9999), () async => 200),
      200,
    );
  });

  test('503 only pauses the host when Retry-After is provided', () {
    final gate = ProviderRequestGate(now: () => epoch);
    gate.recordResponse(uri, 503);
    expect(() => gate.check(uri), returnsNormally);
    gate.recordResponse(uri, 503, retryAfter: '900');
    expect(() => gate.check(uri), throwsA(isA<ProviderRequestBlocked>()));
  });

  test('a failed operation releases the permit for the next request', () async {
    final gate = ProviderRequestGate(
      minimumStartGap: Duration.zero,
      maximumConcurrentRequests: 1,
    );
    await expectLater(
      gate.run<void>(uri, () async {
        throw const FormatException();
      }),
      throwsFormatException,
    );
    expect(await gate.run(uri, () async => 42), 42);
  });

  test('refusals are never network retries and do not expose credentials', () {
    final blocked = ProviderRequestBlocked(
      status: 429,
      retryAt: epoch.add(const Duration(minutes: 5)),
    );
    expect(isTransientNetworkError(blocked), isFalse);
    expect(isTransientHttpStatus(429), isFalse);
    expect('$blocked', contains('HTTP 429'));
    expect('$blocked', isNot(contains('private')));
    expect(sourceLoadErrorMessage(blocked), contains('429'));
    expect(sourceLoadErrorMessage(blocked), contains('paused until'));
  });

  test('cooldown and Retry-After survive restart without persisting host or credentials', () async {
    final directory = Directory.systemTemp.createTempSync('provider_cooldown');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/cooldowns.json');
    final gate = ProviderRequestGate(now: () => epoch);
    await gate.restoreCooldowns(file);
    gate.recordResponse(uri, 429, retryAfter: '3600');
    await gate.flushCooldowns();
    final saved = await file.readAsString();
    expect(saved, isNot(contains('provider.test')));
    expect(saved, isNot(contains('private')));
    expect(saved, isNot(contains('username')));
    expect((jsonDecode(saved) as Map).keys.single, matches(r'^[a-f0-9]{64}$'));

    final restarted = ProviderRequestGate(
      now: () => epoch.add(const Duration(minutes: 1)),
    );
    await restarted.restoreCooldowns(file);
    var opened = false;
    await expectLater(
      restarted.run(uri.replace(scheme: 'http', port: 9999), () async {
        opened = true;
      }),
      throwsA(
        isA<ProviderRequestBlocked>().having(
          (e) => e.retryAt,
          'retryAt',
          epoch.add(const Duration(hours: 1)),
        ),
      ),
    );
    expect(opened, isFalse);
    expect(
      () => restarted.check(Uri.parse('https://different.test')),
      returnsNormally,
    );

    final expired = ProviderRequestGate(
      now: () => epoch.add(const Duration(hours: 2)),
    );
    await expired.restoreCooldowns(file);
    expect(() => expired.check(uri), returnsNormally);
  });

  test(
    'serialized cooldown writes retain multiple hosts and the longest deadline',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'provider_cooldown',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/cooldowns.json');
      final gate = ProviderRequestGate(now: () => epoch);
      await gate.restoreCooldowns(file);
      final second = Uri.parse('https://second.test');
      gate.recordResponse(uri, 401);
      gate.recordResponse(second, 401);
      gate.recordResponse(uri, 429, retryAfter: '7200');
      gate.recordResponse(uri, 200);
      await gate.flushCooldowns();

      final restarted = ProviderRequestGate(now: () => epoch);
      await restarted.restoreCooldowns(file);
      expect(
        () => restarted.check(uri),
        throwsA(
          isA<ProviderRequestBlocked>().having(
            (e) => e.retryAt,
            'retryAt',
            epoch.add(const Duration(hours: 2)),
          ),
        ),
      );
      expect(
        () => restarted.check(second),
        throwsA(
          isA<ProviderRequestBlocked>().having((e) => e.status, 'status', 401),
        ),
      );
    },
  );

  test('persisted HTTP 403 does not prevent requests after restart', () async {
    final directory = Directory.systemTemp.createTempSync('provider_cooldown');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/cooldowns.json');
    final gate = ProviderRequestGate(now: () => epoch);
    await gate.restoreCooldowns(file);
    gate.recordResponse(uri, 401, retryAfter: '3600');
    await gate.flushCooldowns();
    final saved = jsonDecode(await file.readAsString()) as Map;
    saved[saved.keys.single]['status'] = 403;
    await file.writeAsString(jsonEncode(saved));

    final restarted = ProviderRequestGate(now: () => epoch);
    await restarted.restoreCooldowns(file);
    expect(() => restarted.check(uri), returnsNormally);
    expect(
      await restarted.run(uri.replace(port: 9999), () async => 200),
      200,
    );
  });

  test('invalid cooldown records cannot pause unrelated hosts', () async {
    final directory = Directory.systemTemp.createTempSync('provider_cooldown');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/cooldowns.json');
    await file.writeAsString('{broken');
    final gate = ProviderRequestGate(now: () => epoch);
    await gate.restoreCooldowns(file);
    expect(() => gate.check(uri), returnsNormally);
    gate.recordResponse(uri, 401);
    await gate.flushCooldowns();
    final saved = jsonDecode(await file.readAsString()) as Map;
    final key = saved.keys.single;
    saved[key]['status'] = 200;
    await file.writeAsString(jsonEncode(saved));
    final restarted = ProviderRequestGate(now: () => epoch);
    await restarted.restoreCooldowns(file);
    expect(() => restarted.check(uri), returnsNormally);
  });

  test('an unreadable cooldown cache does not prevent startup', () async {
    final gate = ProviderRequestGate(now: () => epoch);
    await gate.restoreCooldowns(_UnreadableCooldownFile());
    expect(() => gate.check(uri), returnsNormally);
  });
}

class _UnreadableCooldownFile implements File {
  @override
  Future<bool> exists() async => true;

  @override
  Future<String> readAsString({Encoding encoding = utf8}) async {
    throw const FileSystemException('Permission denied');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
