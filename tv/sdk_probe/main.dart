import 'dart:convert';

import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/source_config.dart';
import 'package:iptvs/sources/source_identity.dart';

// Compile the original factory and identity owner without contacting a provider.
// The generated ARM artifact is never executed on the Windows host.
Future<void> main(List<String> arguments) async {
  final index = arguments.isEmpty ? 0 : int.parse(arguments.first);
  final kind = SourceKind.values[index % SourceKind.values.length];
  final source = SourceConfig(
    id: '00000000-0000-4000-8000-000000000001',
    kind: kind,
    label: 'SDK compilation probe',
    fields: const {
      'portal': 'http://127.0.0.1/',
      'mac': '00:00:00:00:00:00',
      'host': 'http://127.0.0.1/',
      'username': 'fixture',
      'password': 'fixture',
      'playlistUrl': 'http://127.0.0.1/fixture.m3u',
    },
  ).build();
  print(
    jsonEncode({
      'sourceId': source.id,
      'name': source.name,
      'epg': capabilitiesOf(source).epg.name,
      'channelId': stableM3uChannelId('http://127.0.0.1/fixture.ts'),
    }),
  );
  await source.dispose();
}
