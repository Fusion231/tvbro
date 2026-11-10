import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/player/mpv_http_response_parser.dart';

void main() {
  test(
    'curl refusal retains server retry timing after the response completes',
    () {
      final parser = MpvHttpResponseParser();
      expect(
        parser.addCurlResponseLine('< HTTP/1.1 429 Too Many Requests'),
        isNull,
      );
      expect(parser.addCurlResponseLine('< rEtRy-AfTeR: 600'), isNull);
      final refusal = parser.addCurlResponseLine('<');
      expect(refusal?.status, 429);
      expect(refusal?.retryAfter, '600');
    },
  );

  test(
    'request headers and successful/redirect responses never become refusals',
    () {
      final parser = MpvHttpResponseParser();
      for (final line in [
        '> Authorization: Bearer secret',
        '> Retry-After: 999',
        '< HTTP/2 302',
        '< location: https://user:secret@example.test/path',
        '<',
        '< HTTP/2 200',
        '< set-cookie: private=value',
        '< retry-after: 600',
      ]) {
        expect(parser.addCurlResponseLine(line), isNull);
      }
      expect(parser.addCurlResponseLine('<'), isNull);
    },
  );

  test(
    'retry timing cannot leak across responses, reloads or dropped events',
    () {
      final parser = MpvHttpResponseParser();
      parser.addCurlResponseLine('< HTTP/2 429');
      parser.addCurlResponseLine('< Retry-After: 600');
      parser.reset();
      parser.addCurlResponseLine('< HTTP/2 403');
      expect(parser.addCurlResponseLine('<')?.retryAfter, isNull);
      parser.addCurlResponseLine('< HTTP/2 429');
      parser.addCurlResponseLine('< Retry-After: 600');
      parser.addCurlResponseLine('< HTTP/2 401');
      expect(parser.addCurlResponseLine('<')?.retryAfter, isNull);
    },
  );

  test('503 requires validated delta-seconds or HTTP date', () {
    final parser = MpvHttpResponseParser();
    for (final value in [
      '-1',
      'secret',
      '1e9',
      '600\r\nAuthorization: secret',
    ]) {
      parser.addCurlResponseLine('< HTTP/1.1 503 Unavailable');
      parser.addCurlResponseLine('< Retry-After: $value');
      expect(parser.addCurlResponseLine('<'), isNull);
    }
    const date = 'Mon, 26 Oct 2026 13:00:00 GMT';
    parser.addCurlResponseLine('< HTTP/1.1 503 Unavailable');
    parser.addCurlResponseLine('< Retry-After: $date');
    expect(parser.addCurlResponseLine('<')?.retryAfter, date);
  });
}
