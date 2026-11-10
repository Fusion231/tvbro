import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/player/player_screen.dart';

void main() {
  group('iOS native callback ownership', () {
    test('controller events require the current open ID', () {
      expect(
        acceptsIosNativeOpenEvent(
          isIos: true,
          event: 'nativePlayback',
          arguments: {'nativeOpenId': 12},
          nativeOpenId: 12,
        ),
        isTrue,
      );
      for (final arguments in <Map?>[
        null,
        const <String, Object?>{},
        const <String, Object?>{'nativeOpenId': 11},
      ]) {
        expect(
          acceptsIosNativeOpenEvent(
            isIos: true,
            event: 'nativePlayback',
            arguments: arguments,
            nativeOpenId: 12,
          ),
          isFalse,
        );
      }
    });

    test('host visibility is process scoped and Android remains unchanged', () {
      expect(
        acceptsIosNativeOpenEvent(
          isIos: true,
          event: 'hostVisibility',
          arguments: const <String, Object?>{},
          nativeOpenId: 12,
        ),
        isTrue,
      );
      expect(
        acceptsIosNativeOpenEvent(
          isIos: false,
          event: 'nativePlayback',
          arguments: null,
          nativeOpenId: 12,
        ),
        isTrue,
      );
    });
  });

  group('iOS channel-switch stop reply', () {
    test(
      'accepts only an applied checkpoint from the current native session',
      () {
        expect(
          acceptsIosChannelSwitchStop(
            reply: const {
              'nativeOpenId': 12,
              'positionMs': 60000,
              'durationMs': 120000,
              'applied': true,
            },
            nativeOpenId: 12,
          ),
          isTrue,
        );
      },
    );

    test(
      'rejects refusal, missing checkpoint identity, and stale sessions',
      () {
        for (final reply in [
          null,
          true,
          const <String, Object?>{},
          const <String, Object?>{'applied': true},
          const <String, Object?>{'nativeOpenId': 12},
          const <String, Object?>{'nativeOpenId': 11, 'applied': true},
          const <String, Object?>{'nativeOpenId': 12, 'applied': false},
        ]) {
          expect(
            acceptsIosChannelSwitchStop(reply: reply, nativeOpenId: 12),
            isFalse,
            reason: '$reply',
          );
        }
      },
    );
  });

  group('iOS VOD progress persistence cadence', () {
    test('coalesces second-level updates but always accepts flushes', () {
      expect(
        shouldPersistIosNativeProgress(
          nowMs: 1000,
          lastPersistMs: 0,
          flush: false,
        ),
        isTrue,
      );
      expect(
        shouldPersistIosNativeProgress(
          nowMs: 29000,
          lastPersistMs: 1000,
          flush: false,
        ),
        isFalse,
      );
      expect(
        shouldPersistIosNativeProgress(
          nowMs: 31000,
          lastPersistMs: 1000,
          flush: false,
        ),
        isTrue,
      );
      expect(
        shouldPersistIosNativeProgress(
          nowMs: 2000,
          lastPersistMs: 1000,
          flush: true,
        ),
        isTrue,
      );
    });
  });
}
