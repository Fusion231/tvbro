import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/net.dart';
import 'package:iptvs/l10n/app_localizations.dart';

void main() {
  group('transient source loading', () {
    test('retries one timeout and returns the successful result', () async {
      var calls = 0;
      final retriedAttempts = <int>[];

      final result = await retryTransientNetworkOperation(
        () async {
          calls++;
          if (calls == 1) throw TimeoutException('portal URL and details');
          return 'loaded';
        },
        retryDelay: Duration.zero,
        onRetry: (_, attempt) => retriedAttempts.add(attempt),
      );

      expect(result, 'loaded');
      expect(calls, 2);
      expect(retriedAttempts, [2]);
    });

    test('does not retry workload policy failures', () async {
      var calls = 0;

      await expectLater(
        retryTransientNetworkOperation(() async {
          calls++;
          throw const HttpWorkloadException('provider exceeds limit');
        }, retryDelay: Duration.zero),
        throwsA(isA<HttpWorkloadException>()),
      );
      expect(calls, 1);
    });
  });

  group('sourceLoadErrorMessage', () {
    test('distinguishes refused connections from timeouts', () {
      final message = sourceLoadErrorMessage(
        const SocketException('Connection refused'),
      );

      expect(message, contains('connection to the source was refused'));
      expect(message, contains('source address'));
      expect(message, contains('HTTP/HTTPS'));
      expect(message, contains('port'));
      expect(message, contains('another network'));
      expect(message, isNot(contains('did not respond in time')));
    });

    for (final code in [111, 61, 10061]) {
      test('recognizes localized socket refusal code $code', () {
        final message = sourceLoadErrorMessage(
          SocketException(
            'Połączenie odrzucone',
            osError: OSError('Połączenie odrzucone', code),
          ),
        );

        expect(message, contains('connection to the source was refused'));
        expect(message, isNot(contains('did not respond in time')));
      });
    }

    test('recognizes wrapped refusals without exposing request details', () {
      final message = sourceLoadErrorMessage(
        StateError(
          'SocketException: Connection refused '
          'http://private-user:private-password@panel.invalid/private-playlist',
        ),
      );

      expect(message, contains('connection to the source was refused'));
      for (final secret in [
        'private-user',
        'private-password',
        'panel.invalid',
        'private-playlist',
      ]) {
        expect(message, isNot(contains(secret)));
      }
    });

    test('translates refused-connection guidance into Polish', () {
      final controller = AppLanguageController.instance;
      controller.preview(AppLanguage.polish);
      addTearDown(() => controller.preview(AppLanguage.english));

      expect(
        sourceLoadErrorMessage(const SocketException('Connection refused')),
        'Połączenie ze źródłem zostało odrzucone. Sprawdź adres źródła, '
        'protokół HTTP/HTTPS i port lub spróbuj w innej sieci.',
      );
    });

    test('hides nested URLs and exception details for timeouts', () {
      final message = sourceLoadErrorMessage(
        TimeoutException(
          'request to http://user:password@example.invalid/private timed out',
        ),
      );

      expect(message, contains('retried automatically'));
      expect(message, contains('did not respond in time'));
      expect(message, isNot(contains('example.invalid')));
      expect(message, isNot(contains('password')));
    });

    test('names the status and blames the provider for an unknown code', () {
      // From a field report: a panel answered its playlist endpoint with
      // `HTTP 884`, a code outside the standard range entirely. The old mapper
      // recognised no status at all, so this read "check its details and try
      // again" — while the same provider's player_api.php had authenticated
      // seconds earlier, i.e. the details were provably fine.
      final message = sourceLoadErrorMessage(
        StateError('HTTP 884 fetching http://panel.invalid/get.php'),
      );

      expect(message, contains('884'));
      expect(message, contains('their server'));
      expect(message, isNot(contains('panel.invalid')));
    });

    test('maps auth, missing and rate-limit statuses apart', () {
      String forStatus(int status) => sourceLoadErrorMessage(
        StateError('HTTP $status fetching http://panel.invalid/get.php'),
      );

      expect(forStatus(401), contains('rejected these credentials'));
      expect(forStatus(403), contains('rejected these credentials'));
      expect(forStatus(404), contains('Try again; if the error persists'));
      expect(forStatus(410), contains('no such address'));
      expect(forStatus(429), contains('rate-limiting'));
      expect(forStatus(503), contains('refused this request'));
      for (final status in [401, 403, 404, 429, 503]) {
        expect(forStatus(status), contains('$status'));
      }
    });

    test('a port in the URL is not mistaken for a status', () {
      // `redactUrl` leaves the host and port, and the guard against reading
      // those digits is the capitals and the space in the thrown `HTTP nnn`.
      final message = sourceLoadErrorMessage(
        Exception('connection failed to http://panel.invalid:8080/get.php'),
      );

      expect(
        message,
        'The source could not be loaded. Check its details and try again.',
      );
    });

    test('keeps the credential wording for a status-less auth failure', () {
      // XtreamSource.connect throws this for `{"user_info":{"auth":0}}`, which
      // arrives as HTTP 200 — there is no status to read, and the keyword path
      // is what still has to answer.
      final message = sourceLoadErrorMessage(
        StateError('Xtream authentication failed'),
      );

      expect(message, contains('rejected the saved credentials'));
    });

    test('uses a bounded generic message for unknown provider errors', () {
      final message = sourceLoadErrorMessage(
        Exception('very long response body ${'secret ' * 500}'),
      );

      expect(message.length, lessThan(100));
      expect(message, isNot(contains('secret')));
    });
  });
}
