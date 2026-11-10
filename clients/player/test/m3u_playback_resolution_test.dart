import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/data/secret_locator_vault.dart';
import 'package:iptvs/sources/m3u_source.dart';
import 'package:iptvs/sources/source.dart';

// A cached playback locator must not need another channel/catalogue query.
class _ResolveOnlyDatabase implements AppDatabase {
  _ResolveOnlyDatabase(this.delegate);
  final AppDatabase delegate;

  @override
  Future<Channel> revealChannel(Channel channel) =>
      delegate.revealChannel(channel);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected database operation during M3U playback');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'cached M3U playback reveals one locator without fetching a playlist',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final directory = await Directory.systemTemp.createTemp('m3u_playback_');
      final db = await AppDatabase.openAt('${directory.path}/library.db');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requests = <Uri>[];
      server.listen((request) async {
        requests.add(request.uri);
        request.response.statusCode = HttpStatus.serviceUnavailable;
        await request.response.close();
      });
      final source = M3uSource(
        sourceId: 'playlist',
        playlistUrl: 'http://127.0.0.1:${server.port}/unavailable.m3u',
        userAgent: 'M3U fixture',
      );
      try {
        const channel = Channel(
          id: 'episode',
          name: 'Series S01E01',
          categoryId: 'Series',
          extra: {'url': 'https://example.test/episode.mp4'},
        );
        await db.replaceLibrary(source.id, source.name, const [], [channel]);
        final cached = (await db.readChannel(source.id, channel.id))!;
        expect(hasSealedLocator(cached.extra), isTrue);
        final before = db.vault.decryptCount;
        final repo = LibraryRepository(
          source: source,
          db: _ResolveOnlyDatabase(db),
        );

        final stream = await repo.resolve(cached);
        expect(stream.url, channel.extra['url']);
        expect(stream.headers, {'User-Agent': 'M3U fixture'});
        expect(db.vault.decryptCount, before + 1);
        expect(requests, isEmpty);
      } finally {
        await source.dispose();
        await server.close(force: true);
        await db.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
