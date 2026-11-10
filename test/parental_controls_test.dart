import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/parental_controls.dart';
import 'package:iptvs/data/profile_pin.dart';
import 'package:iptvs/sources/source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final verifier = hashProfilePin(
    '4821',
    salt: List.filled(16, 7),
    iterations: 1,
  );
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('uncategorized provider rows cannot bypass category locks', () {
    for (final kind in [
      ContentKind.live,
      ContentKind.movie,
      ContentKind.series,
    ]) {
      final rules = ParentalRules(
        verifier: verifier,
        categories: {ParentalRules.categoryKey('source', kind, 'restricted')},
      );
      expect(rules.protects('source', 'unknown', kind: kind), isTrue);
      expect(
        rules.protects('source', 'unknown', categoryId: '', kind: kind),
        isTrue,
      );
      expect(
        rules.protects('source', 'known', categoryId: 'public', kind: kind),
        isFalse,
      );
      expect(rules.protects('other', 'unknown', kind: kind), isFalse);
    }
  });

  test(
    'locks are source-scoped and content-kind-scoped, including episodes',
    () {
      final rules = ParentalRules(
        verifier: verifier,
        channels: {ParentalRules.channelKey('a', 'channel')},
        categories: {
          ParentalRules.categoryKey('a', ContentKind.live, 'adult'),
          ParentalRules.categoryKey('a', ContentKind.series, 'drama'),
        },
      );
      expect(rules.protects('a', 'channel'), isTrue);
      expect(rules.protects('b', 'channel'), isFalse);
      expect(rules.protects('a', 'other', categoryId: 'adult'), isTrue);
      expect(
        rules.protects(
          'a',
          'other',
          categoryId: 'adult',
          kind: ContentKind.movie,
        ),
        isFalse,
      );
      expect(
        rules.protects(
          'a',
          'episode',
          categoryId: 'drama',
          kind: ContentKind.episode,
        ),
        isTrue,
      );
      expect(rules.protects('a', 'episode', kind: ContentKind.episode), isTrue);
      expect(
        rules.protects('b', 'episode', kind: ContentKind.episode),
        isFalse,
      );
      expect(
        ParentalRules.fromJson(rules.toJson()).categories,
        rules.categories,
      );
    },
  );

  test(
    'PIN session unlock never persists and wrong verifier cannot unlock',
    () async {
      final controls = ParentalControlService();
      addTearDown(controls.dispose);
      await controls.ensureInitialized();
      await controls.save(
        ParentalRules(
          verifier: verifier,
          channels: {ParentalRules.channelKey('a', 'channel')},
        ),
      );
      expect(controls.allows('a', 'channel'), isFalse);
      controls.unlock('wrong');
      expect(controls.allows('a', 'channel'), isFalse);
      controls.unlock(verifier);
      expect(controls.allows('a', 'channel'), isTrue);
      final restarted = ParentalControlService();
      addTearDown(restarted.dispose);
      await restarted.ensureInitialized();
      expect(restarted.allows('a', 'channel'), isFalse);
      controls.lock();
      expect(controls.allows('a', 'channel'), isFalse);
      expect(controls.allows('a', 'public'), isTrue);
      await controls.save(const ParentalRules());
      expect(controls.allows('a', 'channel'), isTrue);
    },
  );

  test(
    'damaged and future policies fail closed instead of disabling the PIN',
    () async {
      for (final raw in [
        'not-json',
        jsonEncode({...const ParentalRules().toJson(), 'version': 2}),
        jsonEncode({...const ParentalRules().toJson(), 'verifier': 'bad'}),
        jsonEncode({
          ...const ParentalRules().toJson(),
          'channels': ['not-an-identity'],
        }),
      ]) {
        FlutterSecureStorage.setMockInitialValues({
          ParentalControlService.storageKey: raw,
        });
        final controls = ParentalControlService();
        await expectLater(controls.ensureInitialized(), throwsFormatException);
        expect(controls.unavailable, isTrue);
        expect(controls.allows('any', 'channel'), isFalse);
        controls.unlock(verifier);
        expect(controls.allows('any', 'channel'), isFalse);
        controls.dispose();
      }
    },
  );
}
