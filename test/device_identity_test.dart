import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/device_identity.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('iptvs/device');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('Android scope becomes a stable app-namespaced SHA-256 hint', () async {
    final methods = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      methods.add(call.method);
      return 'app.tvbro.player|0123456789abcdef';
    });
    final first = await detectDeviceIdentity(operatingSystem: 'android');
    final next = await detectDeviceIdentity(operatingSystem: 'android');
    // Independent SHA-256 test vector; no raw platform scope is returned.
    expect(
      first,
      '2a1d6e2d0892c575ab6fa400639648b4ea5fe7c3438b7f03222fdc088b974535',
    );
    expect(next, first);
    expect(methods, ['stableIdentity', 'stableIdentity']);
  });

  test('Windows hint includes platform and native user/app scope', () async {
    var scope = 'app.tvbro.player|0123456789abcdef|S-1-5-21-100-200-300-1001';
    messenger.setMockMethodCallHandler(channel, (_) async => scope);
    final first = await detectDeviceIdentity(operatingSystem: 'windows');
    expect(
      first,
      'fb0a9345c57f18f3d6471c1c02edbef24a0a86e99d0e8915248c4846a94bc52a',
    );
    scope = 'app.tvbro.player|0123456789abcdef|S-1-5-21-100-200-300-1002';
    expect(
      await detectDeviceIdentity(operatingSystem: 'windows'),
      isNot(first),
    );
    expect(
      await detectDeviceIdentity(operatingSystem: 'android'),
      isNot(await detectDeviceIdentity(operatingSystem: 'windows')),
    );
  });

  test(
    'unsupported platforms leave anonymous-session pairing unchanged',
    () async {
      var reads = 0;
      messenger.setMockMethodCallHandler(channel, (_) async {
        reads++;
        return 'app.tvbro.player|0123456789abcdef';
      });
      for (final platform in ['linux', 'ios', 'macos', 'tizen', 'webos', '']) {
        expect(await detectDeviceIdentity(operatingSystem: platform), isNull);
      }
      expect(reads, 0);
    },
  );

  test('old runners and platform errors are an unavailable hint', () async {
    expect(await detectDeviceIdentity(operatingSystem: 'windows'), isNull);
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'unavailable');
    });
    expect(await detectDeviceIdentity(operatingSystem: 'android'), isNull);
  });

  test('missing, malformed and unbounded native replies fail closed', () async {
    Object? reply;
    messenger.setMockMethodCallHandler(channel, (_) async => reply);
    for (final value in [
      null,
      '',
      ' ',
      ' leading',
      'trailing ',
      'scope\nvalue',
      'scope\u0000value',
      'scope\u007fvalue',
      'x' * 513,
      {'scope': 'wrong type'},
    ]) {
      reply = value;
      expect(await detectDeviceIdentity(operatingSystem: 'android'), isNull);
    }
  });
}
