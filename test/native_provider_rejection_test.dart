import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/net.dart';
import 'package:iptvs/player/player_screen.dart';

void main() {
  setUp(() => ProviderRequestGate.instance.debugReset());
  tearDown(() => ProviderRequestGate.instance.debugReset());

  for (final status in [429, 503]) {
    test(
      'native HTTP $status keeps the server deadline and redirected host',
      () {
        final before = DateTime.now();
        recordPlaybackProviderRejection(
          'https://origin.test/live/private',
          status,
          retryAfter: '3600',
          responseOrigin: 'https://cdn.test:443/',
        );
        for (final host in ['origin.test', 'cdn.test']) {
          expect(
            () => ProviderRequestGate.instance.check(Uri.https(host, '/other')),
            throwsA(
              isA<ProviderRequestBlocked>()
                  .having((error) => error.status, 'status', status)
                  .having(
                    (error) => error.retryAt.isAfter(
                      before.add(const Duration(minutes: 59)),
                    ),
                    'server deadline',
                    isTrue,
                  ),
            ),
          );
        }
      },
    );
  }

  test('native ordinary 503 remains transient without retry timing', () {
    recordPlaybackProviderRejection('https://origin.test/live', 503);
    expect(
      () =>
          ProviderRequestGate.instance.check(Uri.https('origin.test', '/api')),
      returnsNormally,
    );
  });
}
