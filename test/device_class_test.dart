import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/data/device_class.dart';

void main() {
  test('Tizen TV API versions select the television layout on Linux', () {
    for (final version in ['6.0', '6.5', '8.0', '10.0']) {
      expect(
        isTizenTelevisionEnvironment(
          operatingSystem: 'linux',
          environment: {'TIZEN_API_VERSION': version, 'ELM_PROFILE': 'tv'},
        ),
        isTrue,
        reason: version,
      );
    }
  });

  test('Tizen TV markers do not change Android or desktop classification', () {
    for (final os in ['android', 'windows', 'macos', 'ios']) {
      expect(
        isTizenTelevisionEnvironment(
          operatingSystem: os,
          environment: {'TIZEN_API_VERSION': '6.0', 'ELM_PROFILE': 'tv'},
        ),
        isFalse,
        reason: os,
      );
    }
  });

  test('ordinary Linux and other Tizen profiles are not televisions', () {
    for (final environment in <Map<String, String>>[
      {},
      {'ELM_PROFILE': 'tv'},
      {'TIZEN_API_VERSION': '6.0'},
      {'TIZEN_API_VERSION': '6.0', 'ELM_PROFILE': 'common'},
      {'TIZEN_API_VERSION': '6.0', 'ELM_PROFILE': 'mobile'},
      {'TIZEN_API_VERSION': '6.0', 'ELM_PROFILE': 'TV'},
    ]) {
      expect(
        isTizenTelevisionEnvironment(
          operatingSystem: 'linux',
          environment: environment,
        ),
        isFalse,
        reason: '$environment',
      );
    }
  });

  test('malformed or empty Tizen API markers fail closed', () {
    for (final version in ['', 'none', 'NaN', '6', '6.0.0', '0.0', ' 6.0']) {
      expect(
        isTizenTelevisionEnvironment(
          operatingSystem: 'linux',
          environment: {'TIZEN_API_VERSION': version, 'ELM_PROFILE': 'tv'},
        ),
        isFalse,
        reason: version,
      );
    }
  });
}
