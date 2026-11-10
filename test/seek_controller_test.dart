import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/player/seek_controller.dart';

void main() {
  for (final playing in [false, true]) {
    test(
      '20 relative inputs accumulate with delayed position (playing=$playing)',
      () {
        fakeAsync((clock) {
          final seeks = <Duration>[];
          final controller = PlaybackSeekController(
            position: () => const Duration(seconds: 100),
            duration: () => const Duration(seconds: 600),
            seek: (target) async {
              seeks.add(target);
            },
          );
          for (var i = 0; i < 20; i++) {
            controller.relative(const Duration(seconds: 10));
            clock.elapse(const Duration(milliseconds: 50));
          }
          expect(seeks, isEmpty);
          clock.elapse(const Duration(milliseconds: 80));
          expect(seeks, [const Duration(seconds: 300)]);
          controller.confirm(const Duration(seconds: 300));
          clock.flushMicrotasks();
          expect(controller.pendingTarget, isNull);
          controller.dispose();
        });
      },
    );
  }

  test('only the latest target follows an in-flight seek', () {
    fakeAsync((clock) {
      final seeks = <Duration>[];
      final command = Completer<void>();
      var position = const Duration(seconds: 100);
      final controller = PlaybackSeekController(
        position: () => position,
        duration: () => const Duration(seconds: 600),
        seek: (target) {
          seeks.add(target);
          return seeks.length == 1 ? command.future : Future.value();
        },
      );
      controller.relative(const Duration(seconds: 10));
      clock.elapse(const Duration(milliseconds: 80));
      for (var i = 0; i < 19; i++) {
        controller.relative(const Duration(seconds: 10));
        clock.elapse(const Duration(milliseconds: 100));
      }
      expect(seeks, [const Duration(seconds: 110)]);
      command.complete();
      clock.flushMicrotasks();
      expect(seeks, hasLength(1));
      position = const Duration(seconds: 110);
      controller.confirm(position);
      clock.elapse(Duration.zero);
      expect(seeks, [
        const Duration(seconds: 110),
        const Duration(seconds: 300),
      ]);
      controller.confirm(const Duration(seconds: 300));
      clock.flushMicrotasks();
      controller.dispose();
    });
  });

  test('opposite inputs cancel and known duration clamps both edges', () {
    fakeAsync((clock) {
      final seeks = <Duration>[];
      final controller = PlaybackSeekController(
        position: () => const Duration(seconds: 100),
        duration: () => const Duration(seconds: 120),
        seek: (target) async {
          seeks.add(target);
        },
      );
      controller.relative(const Duration(seconds: 10));
      controller.relative(const Duration(seconds: -10));
      clock.elapse(const Duration(milliseconds: 80));
      expect(seeks, [const Duration(seconds: 100)]);
      clock.flushMicrotasks();
      controller.absolute(const Duration(seconds: 999));
      clock.elapse(const Duration(milliseconds: 80));
      expect(seeks.last, const Duration(seconds: 120));
      controller.confirm(const Duration(seconds: 120));
      clock.flushMicrotasks();
      controller.relative(const Duration(seconds: -999));
      clock.elapse(const Duration(milliseconds: 80));
      expect(seeks.last, Duration.zero);
      controller.dispose();
      clock.flushMicrotasks();
    });
  });

  test('reset and disposal discard queued commands during a media switch', () {
    fakeAsync((clock) {
      final seeks = <Duration>[];
      final controller = PlaybackSeekController(
        position: () => Duration.zero,
        duration: () => const Duration(seconds: 120),
        seek: (target) async {
          seeks.add(target);
        },
      );
      controller.relative(const Duration(seconds: 10));
      controller.reset();
      clock.elapse(const Duration(seconds: 3));
      expect(seeks, isEmpty);
      controller.relative(const Duration(seconds: 10));
      controller.dispose();
      clock.elapse(const Duration(seconds: 3));
      expect(seeks, isEmpty);
    });
  });
}
