// The aspect cycle used to be private to `_PlayerScreenState`, so the Kotlin
// and Swift sides were pinned and the Dart side was not. It is shared and
// public now, which is what makes these possible.
import 'dart:io' show Platform;

import 'package:flutter/widgets.dart' show BoxFit, Size, applyBoxFit;
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/device_class.dart';
import 'package:iptvs/player/aspect_mode.dart';

void main() {
  group('the cycle', () {
    test('preserves manual mode order and adds Auto on Windows', () {
      expect(kAspectModes.map((m) => m.label), [
        'Fit',
        'Fill',
        'Stretch',
        '16:9',
        '4:3',
        if (Platform.isWindows) 'Auto',
      ]);
    });

    test('Fill crops and Stretch distorts — they are not the same mode', () {
      // The distinction is the whole reason both exist. Fill keeps the
      // picture's shape and loses the edges; Stretch keeps every pixel and
      // loses the shape. Collapsing them is easy and silently removes the mode
      // users ask for by name.
      final fill = kAspectModes[aspectModeIndexOf('Fill')];
      final stretch = kAspectModes[aspectModeIndexOf('Stretch')];

      expect(fill.fit, BoxFit.cover);
      expect(fill.panscan, '1.0');
      expect(fill.keepaspect, 'yes');

      expect(stretch.fit, BoxFit.fill);
      expect(stretch.keepaspect, 'no');
      expect(stretch.panscan, '0.0');
    });

    test('every mode restores keepaspect unless it is Stretch', () {
      // The modes are cycled, so leaving Stretch has to undo it on the very
      // next press — a mode that only sets what it needs leaves the picture
      // distorted in Fit.
      for (final mode in kAspectModes) {
        expect(
          mode.keepaspect,
          mode.label == 'Stretch' ? 'no' : 'yes',
          reason: mode.label,
        );
      }
    });

    test('a forced ratio letterboxes whatever shape it produces', () {
      for (final label in ['16:9', '4:3']) {
        final mode = kAspectModes[aspectModeIndexOf(label)];
        expect(mode.aspect, label);
        expect(mode.fit, BoxFit.contain);
        expect(mode.panscan, '0.0');
      }
    });
  });

  group('aspectModeIndexOf', () {
    test('finds a label regardless of case', () {
      expect(aspectModeIndexOf('Fit'), 0);
      expect(aspectModeIndexOf('stretch'), 2);
      expect(aspectModeIndexOf('4:3'), 4);
    });

    test('reports -1 for anything it does not know', () {
      // A label a *newer* build wrote must not resolve to an arbitrary mode.
      expect(aspectModeIndexOf(null), -1);
      expect(aspectModeIndexOf(''), -1);
      expect(aspectModeIndexOf('Zoom'), -1);
    });
  });

  group('the default', () {
    // Named for what they are rather than for a device, since the rule is the
    // container's shape.
    const landscapeHandset = Size(2340, 1080);
    const portraitHandset = Size(1080, 2340);
    const nearSquareFoldable = Size(1200, 1080); // 1.11:1

    tearDown(() => debugIsTelevision = false);

    test('is Fill on a television, whatever shape it reports', () {
      // A TV screen is a fixed shape that usually matches the content, so Fill
      // and Fit are identical there — they differ only on 4:3 material, where
      // filling the screen is what a television viewer expects. A TV also does
      // not rotate, so the container test below has nothing to add.
      debugIsTelevision = true;
      expect(kAspectModes[defaultAspectModeIndex()].label, 'Fill');
      expect(
        kAspectModes[defaultAspectModeIndex(container: portraitHandset)].label,
        'Fill',
      );
    });

    test('uses uncropped framing on a desktop however wide the window is', () {
      // Guarded so it states what it means rather than passing vacuously.
      if (Platform.isAndroid || Platform.isIOS) return;
      debugIsTelevision = false;
      for (final size in [landscapeHandset, portraitHandset]) {
        expect(
          kAspectModes[defaultAspectModeIndex(container: size)].label,
          Platform.isWindows ? 'Auto' : 'Fit',
          reason:
              'a desktop window is an arbitrary shape, so cropping it is '
              'wrong — the crop would change every time it is resized',
        );
      }
    });

    test('follows the window on a handset: Fill landscape, Fit portrait', () {
      // The regression this exists for: a phone is not a fixed shape, and
      // Fill in portrait opened on a sliver of the middle of the frame.
      if (!Platform.isAndroid && !Platform.isIOS) return;
      debugIsTelevision = false;
      expect(
        kAspectModes[defaultAspectModeIndex(container: landscapeHandset)].label,
        'Fill',
      );
      expect(
        kAspectModes[defaultAspectModeIndex(container: portraitHandset)].label,
        'Fit',
      );
    });

    test('the threshold is 4:3, and a near-square window fails it', () {
      // Asserted on the constant rather than through the platform branch, so
      // it states the rule on every host the suite runs on.
      expect(kFillMinContainerAspect, closeTo(4 / 3, 1e-12));
      expect(
        landscapeHandset.width / landscapeHandset.height,
        greaterThanOrEqualTo(kFillMinContainerAspect),
      );
      for (final size in [portraitHandset, nearSquareFoldable]) {
        expect(
          size.width / size.height,
          lessThan(kFillMinContainerAspect),
          reason: 'below 4:3, Fill stops trimming and starts discarding',
        );
      }
    });

    test('a degenerate container is Fit, not Fill', () {
      // Fit shows every pixel, so being wrong here costs black bars rather
      // than picture.
      if (!Platform.isAndroid && !Platform.isIOS) return;
      debugIsTelevision = false;
      for (final size in [Size.zero, const Size(1080, 0)]) {
        expect(
          kAspectModes[defaultAspectModeIndex(container: size)].label,
          'Fit',
        );
      }
    });
  });

  group('resolveAspectModeIndex', () {
    tearDown(() => debugIsTelevision = false);

    test('honours a stored choice over the default', () {
      debugIsTelevision = true; // default would be Fill
      expect(kAspectModes[resolveAspectModeIndex('Fit')].label, 'Fit');
      expect(kAspectModes[resolveAspectModeIndex('4:3')].label, '4:3');
    });

    test('a stored choice wins over the container too', () {
      // The window only decides the *default*. Someone who chose Fill on a
      // phone keeps it in portrait — it is their answer, not a guess.
      const portrait = Size(1080, 2340);
      final index = resolveAspectModeIndex('Fill', container: portrait);
      expect(kAspectModes[index].label, 'Fill');
    });

    test('falls back to the default when nothing is stored', () {
      debugIsTelevision = true;
      expect(kAspectModes[resolveAspectModeIndex(null)].label, 'Fill');
    });

    test('falls back when the stored label is one this build lost', () {
      // Rather than throwing or landing on index 0 by accident.
      debugIsTelevision = true;
      expect(kAspectModes[resolveAspectModeIndex('Zoom')].label, 'Fill');
    });

    test('always returns an index that is in range', () {
      for (final label in [null, '', 'Fit', 'nonsense', '4:3']) {
        final index = resolveAspectModeIndex(label);
        expect(index, inInclusiveRange(0, kAspectModes.length - 1));
      }
    });
  });

  group('Windows automatic framing', () {
    test(
      'keeps the whole source and its proportions through window resizes',
      () {
        final mode = kAspectModes[aspectModeIndexOf('Auto')];
        const sources = [Size(1920, 1080), Size(1440, 1080), Size(2560, 1080)];
        const windows = [
          Size(1280, 720),
          Size(480, 900),
          Size(900, 900),
          Size(2560, 1080),
          Size(1920, 1080),
          Size(640, 360),
        ];
        for (final source in sources) {
          for (final window in windows) {
            final fitted = applyBoxFit(mode.fit, source, window);
            final context = '$source in $window';
            expect(fitted.source, source, reason: context);
            expect(
              fitted.destination.aspectRatio,
              closeTo(source.aspectRatio, 1e-9),
              reason: context,
            );
            expect(
              fitted.destination.width,
              lessThanOrEqualTo(window.width),
              reason: context,
            );
            expect(
              fitted.destination.height,
              lessThanOrEqualTo(window.height),
              reason: context,
            );
            expect(
              fitted.destination.width == window.width ||
                  fitted.destination.height == window.height,
              isTrue,
              reason: 'Auto should use all available space in $context',
            );
          }
        }
      },
      skip: !Platform.isWindows,
    );

    test('clears crop, stretching and forced native aspect ratios', () {
      final auto = kAspectModes[aspectModeIndexOf('Auto')];
      expect(auto.panscan, '0.0');
      expect(auto.keepaspect, 'yes');
      expect(auto.aspect, 'no');
      expect(auto.fit, BoxFit.contain);
      expect(aspectModeIndexOf('auto'), aspectModeIndexOf('Auto'));
    }, skip: !Platform.isWindows);

    test('restores Auto by default and preserves explicit manual choices', () {
      debugIsTelevision = false;
      const portrait = Size(480, 900);
      for (final saved in [null, '', 'unknown', 'Auto']) {
        final mode =
            kAspectModes[resolveAspectModeIndex(saved, container: portrait)];
        expect(mode.label, 'Auto');
      }
      for (final saved in ['Fit', 'Fill', 'Stretch', '16:9', '4:3']) {
        final mode =
            kAspectModes[resolveAspectModeIndex(saved, container: portrait)];
        expect(mode.label, saved);
      }
    }, skip: !Platform.isWindows);
  });
}
