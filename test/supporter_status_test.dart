import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/supporter_status.dart';

void main() {
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
