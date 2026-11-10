import '../sources/source.dart';
import '../sources/source_config.dart';

const kCustomChannelGroupPrefix = 'tvbro.group.';

class CustomChannelGroup {
  const CustomChannelGroup({
    required this.id,
    required this.name,
    this.channelIds = const [],
  });

  final String id;
  final String name;
  final List<String> channelIds;

  Map<String, Object> toJson() => {
    'id': id,
    'name': name,
    'channels': channelIds,
  };
}

/// Presentation preferences keep provider IDs and payloads intact. They live
/// beside existing source preferences and survive a catalogue refresh.
class ChannelOrganization {
  const ChannelOrganization({
    this.names = const {},
    this.hidden = const {},
    this.order = const [],
    this.groups = const [],
  });

  final Map<String, String> names;
  final Set<String> hidden;
  final List<String> order;
  final List<CustomChannelGroup> groups;

  factory ChannelOrganization.fromJson(Object? value) {
    if (value is! Map) return const ChannelOrganization();
    List<String> strings(Object? raw) =>
        raw is List ? raw.whereType<String>().toSet().toList() : const [];
    final rawNames = value['names'];
    final groups = <CustomChannelGroup>[];
    final seen = <String>{};
    if (value['groups'] case final List rawGroups) {
      for (final raw in rawGroups) {
        if (raw is! Map) continue;
        final id = raw['id'];
        final name = raw['name'];
        if (id is! String ||
            !id.startsWith(kCustomChannelGroupPrefix) ||
            !seen.add(id) ||
            name is! String ||
            name.trim().isEmpty) {
          continue;
        }
        groups.add(
          CustomChannelGroup(
            id: id,
            name: name.trim(),
            channelIds: strings(raw['channels']),
          ),
        );
      }
    }
    return ChannelOrganization(
      names: rawNames is Map
          ? {
              for (final entry in rawNames.entries)
                if (entry.key is String &&
                    entry.value is String &&
                    (entry.value as String).trim().isNotEmpty)
                  entry.key as String: (entry.value as String).trim(),
            }
          : const {},
      hidden: strings(value['hidden']).toSet(),
      order: strings(value['order']),
      groups: groups,
    );
  }

  ChannelOrganization copyWith({
    Map<String, String>? names,
    Set<String>? hidden,
    List<String>? order,
    List<CustomChannelGroup>? groups,
  }) => ChannelOrganization(
    names: names ?? this.names,
    hidden: hidden ?? this.hidden,
    order: order ?? this.order,
    groups: groups ?? this.groups,
  );

  Map<String, Object> toJson() => {
    'version': 1,
    'names': names,
    'hidden': hidden.toList(),
    'order': order,
    'groups': groups.map((group) => group.toJson()).toList(),
  };

  Channel decorate(Channel channel) {
    final name = names[channel.id];
    if (name == null || name == channel.name) return channel;
    return Channel(
      id: channel.id,
      name: name,
      logo: channel.logo,
      categoryId: channel.categoryId,
      number: channel.number,
      archiveDays: channel.archiveDays,
      extra: channel.extra,
    );
  }

  List<Channel> apply(
    Iterable<Channel> channels, {
    bool includeHidden = false,
  }) {
    final result = [
      for (final channel in channels)
        if (includeHidden || !hidden.contains(channel.id)) decorate(channel),
    ];
    if (order.isEmpty) return result;
    final ranks = {for (var i = 0; i < order.length; i++) order[i]: i};
    final original = {for (var i = 0; i < result.length; i++) result[i].id: i};
    result.sort((a, b) {
      final compared = (ranks[a.id] ?? order.length).compareTo(
        ranks[b.id] ?? order.length,
      );
      return compared != 0
          ? compared
          : original[a.id]!.compareTo(original[b.id]!);
    });
    return result;
  }

  CustomChannelGroup? group(String? id) =>
      groups.where((group) => group.id == id).firstOrNull;
}

extension SourceChannelOrganization on SourceConfig {
  ChannelOrganization get channelOrganization =>
      ChannelOrganization.fromJson(settings['channelOrganization']);

  SourceConfig withChannelOrganization(ChannelOrganization organization) =>
      copyWith(
        settings: {...settings, 'channelOrganization': organization.toJson()},
      );
}
