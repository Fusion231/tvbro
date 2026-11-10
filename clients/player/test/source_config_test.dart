import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/sources/m3u_source.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/source_config.dart';
import 'package:iptvs/sources/xtream_source.dart';

void main() {
  const base = SourceConfig(
    id: 'id1',
    kind: SourceKind.xtream,
    label: 'Provider',
    fields: {'host': 'http://h:80', 'username': 'u', 'password': 'p'},
  );

  group('stable source identity', () {
    test('build uses SourceConfig.id instead of provider credentials', () {
      expect(base.build().id, base.id);
      final changedCredentials = base.copyWith(
        fields: const {
          'host': 'https://different.invalid',
          'username': 'other',
          'password': 'new-secret',
        },
      );
      expect(changedCredentials.build().id, base.id);
    });

    test('legacy namespace exactly matches pre-PR4 derivation', () {
      expect(base.legacyCacheId, 'xtream:http://h:80|u');
      expect(
        base
            .copyWith(
              fields: const {
                'host': 'provider.invalid/',
                'username': 'alice',
                'password': 'secret',
              },
            )
            .legacyCacheId,
        'xtream:http://provider.invalid|alice',
      );
    });
  });

  group('settings serialization', () {
    test('parses only nonnegative integral simultaneous-stream limits', () {
      for (final sample in <({Object? raw, int? expected})>[
        (raw: null, expected: null),
        (raw: 'invalid', expected: null),
        (raw: -1, expected: null),
        (raw: 1.5, expected: null),
        (raw: true, expected: null),
        (raw: 0, expected: 0),
        (raw: '0', expected: 0),
        (raw: 1, expected: 1),
        (raw: '2', expected: 2),
        (raw: 8, expected: 8),
      ]) {
        final config = base.copyWith(settings: {'maximumStreams': sample.raw});
        expect(config.maximumStreams, sample.expected);
        expect(
          SourceConfig.fromJson(config.toJson()).maximumStreams,
          sample.expected,
        );
      }
    });

    test('build forwards the stream cap to Xtream and M3U sources', () {
      for (final maximum in <int?>[null, 0, 2]) {
        final configured = base.copyWith(
          settings: {'maximumStreams': ?maximum},
        );
        final xtream = configured.build() as XtreamSource;
        final m3u =
            configured.copyWith(
                  kind: SourceKind.m3u,
                  fields: const {'playlistUrl': 'https://playlist.test/list.m3u'},
                ).build()
                as M3uSource;
        addTearDown(xtream.dispose);
        addTearDown(m3u.dispose);
        expect(xtream.maximumStreams, maximum);
        expect(m3u.maximumStreams, maximum);
      }
    });

    test('omits settings from JSON when empty (legacy-compatible)', () {
      expect(base.toJson().containsKey('settings'), isFalse);
    });

    test('round-trips settings through JSON', () {
      final cfg = base.withHiddenCategories(ContentKind.live, {'a', 'b'});
      final round = SourceConfig.fromJson(cfg.toJson());
      expect(round.hiddenCategoryIds(ContentKind.live), {'a', 'b'});
      expect(round.id, base.id);
      expect(round.kind, base.kind);
      expect(round.fields, base.fields);
    });

    test('fromJson tolerates legacy JSON without a settings key', () {
      final legacy = {
        'id': 'id2',
        'kind': 'demo',
        'label': 'Demo',
        'fields': <String, String>{},
      };
      final cfg = SourceConfig.fromJson(legacy);
      expect(cfg.settings, isEmpty);
      expect(cfg.hiddenCategoryIds(ContentKind.live), isEmpty);
    });

    test('build applies persisted catch-up overrides', () {
      final configured = base.copyWith(
        settings: const {
          'catchupTimezone': 'Europe/London',
          'catchupOffsetMinutes': 60,
          'catchupMaxDays': 14,
        },
      );
      final source = configured.build() as XtreamSource;
      expect(source.catchupCapability.timezone, 'Europe/London');
      expect(source.catchupCapability.fixedOffsetMinutes, 60);
      expect(
        source.catchupCapability.maxArchiveWindow,
        const Duration(days: 14),
      );
    });
  });

  group('hiddenCategoryIds / withHiddenCategories', () {
    test('defaults to an empty set per kind', () {
      expect(base.hiddenCategoryIds(ContentKind.live), isEmpty);
      expect(base.hiddenCategoryIds(ContentKind.movie), isEmpty);
      expect(base.hiddenCategoryIds(ContentKind.series), isEmpty);
    });

    test('tracks hidden ids independently per kind', () {
      final cfg = base
          .withHiddenCategories(ContentKind.live, {'live1'})
          .withHiddenCategories(ContentKind.movie, {'mov1', 'mov2'});
      expect(cfg.hiddenCategoryIds(ContentKind.live), {'live1'});
      expect(cfg.hiddenCategoryIds(ContentKind.movie), {'mov1', 'mov2'});
      expect(cfg.hiddenCategoryIds(ContentKind.series), isEmpty);
    });

    test('clearing a kind removes its entry; empty clears all settings', () {
      final hidden = base.withHiddenCategories(ContentKind.live, {'x'});
      expect(hidden.settings.containsKey('hiddenCategories'), isTrue);

      final cleared = hidden.withHiddenCategories(ContentKind.live, {});
      expect(cleared.hiddenCategoryIds(ContentKind.live), isEmpty);
      // No leftover empty map, so it serializes back to no settings.
      expect(cleared.toJson().containsKey('settings'), isFalse);
    });

    test('does not mutate the original config', () {
      base.withHiddenCategories(ContentKind.live, {'x'});
      expect(base.hiddenCategoryIds(ContentKind.live), isEmpty);
      expect(base.settings, isEmpty);
    });

    test('copyWith preserves settings unless overridden', () {
      final cfg = base.withHiddenCategories(ContentKind.series, {'s1'});
      final relabeled = cfg.copyWith(label: 'New');
      expect(relabeled.label, 'New');
      expect(relabeled.hiddenCategoryIds(ContentKind.series), {'s1'});
    });
  });
}
