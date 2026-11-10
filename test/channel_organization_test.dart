import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/channel_organization.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/source_config.dart';

void main() {
  const channels = [
    Channel(
      id: 'a',
      name: 'Provider A',
      categoryId: 'news',
      extra: {'url': 'sealed'},
    ),
    Channel(id: 'b', name: 'Provider B'),
    Channel(id: 'c', name: 'Provider C'),
  ];
  test(
    'organization preserves provider identity, payload, and untouched order',
    () {
      const organization = ChannelOrganization(
        names: {'a': 'My news'},
        hidden: {'b'},
        order: ['c', 'missing', 'a'],
        groups: [
          CustomChannelGroup(
            id: 'tvbro.group.news',
            name: 'News',
            channelIds: ['a', 'c'],
          ),
        ],
      );
      final restored = ChannelOrganization.fromJson(organization.toJson());
      final result = restored.apply(channels);
      expect(result.map((c) => c.id), ['c', 'a']);
      expect(result.last.name, 'My news');
      expect(result.last.categoryId, 'news');
      expect(result.last.extra, same(channels.first.extra));
      expect(channels.first.name, 'Provider A');
      expect(restored.apply(channels, includeHidden: true).map((c) => c.id), [
        'c',
        'a',
        'b',
      ]);
      expect(restored.group('tvbro.group.news')!.channelIds, ['a', 'c']);
      expect(
        restored
            .apply([...channels, const Channel(id: 'd', name: 'New')])
            .last
            .id,
        'd',
      );
    },
  );

  test(
    'source updates preserve existing provider and playback preferences',
    () {
      const config = SourceConfig(
        id: 'source',
        kind: SourceKind.demo,
        label: 'Demo',
        fields: {'provider': 'unchanged'},
        settings: {
          'bufferPreset': 'large',
          'hiddenLiveCategories': ['x'],
        },
      );
      final updated = config.withChannelOrganization(
        const ChannelOrganization(hidden: {'a'}),
      );
      final restored = SourceConfig.fromJson(updated.toJson());
      expect(restored.fields, config.fields);
      expect(restored.settings['bufferPreset'], 'large');
      expect(restored.settings['hiddenLiveCategories'], ['x']);
      expect(restored.channelOrganization.hidden, {'a'});
    },
  );

  test('malformed optional entries cannot replace provider categories', () {
    final result = ChannelOrganization.fromJson({
      'names': {'a': '  Alias  ', 'b': 42},
      'order': ['a', 'a', 7],
      'groups': [
        {'id': 'news', 'name': 'Collision'},
        {
          'id': 'tvbro.group.ok',
          'name': 'Good',
          'channels': ['a', 'a'],
        },
        {'id': 'tvbro.group.ok', 'name': 'Duplicate'},
      ],
    });
    expect(result.names, {'a': 'Alias'});
    expect(result.order, ['a']);
    expect(result.groups.single.channelIds, ['a']);
  });
}
