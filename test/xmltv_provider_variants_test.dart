import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/sources/m3u_source.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/xtream_source.dart';

void main() {
  for (final m3u in [false, true]) {
    for (final batched in [false, true]) {
      test('${m3u ? 'M3U' : 'Xtream'} exact variants retain primary ownership '
          '(${batched ? 'batched' : 'unbatched'})', () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final origin = 'http://127.0.0.1:${server.port}';
        server.listen((request) async {
          if (request.uri.path == '/playlist.m3u') {
            request.response.write(
              '#EXTM3U url-tvg="$origin/primary.xml"\n'
              '${_catalog.map((row) => '#EXTINF:-1 '
                  'tvg-id="${row['epg_channel_id'] ?? ''}",${row['name']}\n'
                  'http://stream.example.invalid/${row['stream_id']}.ts\n').join()}',
            );
          } else {
            final primary = request.uri.path != '/additional.xml';
            request.response.write(
              '<?xml version="1.0"?><tv>'
              '<channel id="one"><display-name>Provider one</display-name>'
              '</channel>'
              '${primary ? '' : '<channel id="two">'
                        '<display-name>Provider two</display-name></channel>'}'
              '${_programme('one', primary ? 'Primary schedule' : 'Wrong schedule')}'
              '${primary ? '' : _programme('two', 'Additional schedule')}'
              '</tv>',
            );
          }
          await request.response.close();
        });
        final Source source = m3u
            ? M3uSource(
                sourceId: 'source',
                playlistUrl: '$origin/playlist.m3u',
                extraEpgUrls: ['$origin/additional.xml'],
              )
            : XtreamSource(
                sourceId: 'source',
                host: origin,
                username: 'fixture-user',
                password: 'fixture-value',
                extraEpgUrls: ['$origin/additional.xml'],
                debugApi: (_) async => _catalog,
              );
        addTearDown(source.dispose);
        final channels = await source.channels();
        final programmes = batched
            ? (await (source as BatchedEpgSource)
                      .epgBatched(channels)!
                      .toList())
                  .expand((batch) => batch)
                  .toList()
            : await source.epg(channels);

        expect(programmes, hasLength(5));
        for (final channel in channels) {
          final rows = programmes.where((p) => p.channelId == channel.id);
          switch (channel.extra['tvgId']) {
            case 'one':
              expect(rows.single.title, 'Primary schedule');
            case 'two':
              expect(rows.single.title, 'Additional schedule');
            default:
              expect(rows, isEmpty);
          }
        }
      });
    }
  }
}

const _catalog = [
  {'stream_id': 10, 'name': 'One RAW', 'epg_channel_id': 'one'},
  {'stream_id': 11, 'name': 'One HD', 'epg_channel_id': 'one'},
  {'stream_id': 12, 'name': 'One FHD', 'epg_channel_id': 'one'},
  {'stream_id': 20, 'name': 'Two RAW', 'epg_channel_id': 'two'},
  {'stream_id': 21, 'name': 'Two HD', 'epg_channel_id': 'two'},
  {'stream_id': 30, 'name': 'No provider EPG'},
  {'stream_id': 40, 'name': 'Unmapped', 'epg_channel_id': 'not-in-guide'},
];

String _programme(String id, String title) =>
    '<programme channel="$id" start="20261022120000 +0000" '
    'stop="20261022130000 +0000"><title>$title</title></programme>';
