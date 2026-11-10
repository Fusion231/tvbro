import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/sources/source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late AppDatabase db;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    tempDir = Directory.systemTemp.createTempSync('iptvs_library_content_test');
    db = await AppDatabase.openAt('${tempDir.path}/iptv.db');
  });

  tearDown(() async {
    await db.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test(
    'an empty TV refresh timestamp does not count as cached content',
    () async {
      await db.replaceLibrary('source', 'Source', const [], const []);

      expect(await db.lastSynced('source'), isNotNull);
      expect(await db.hasLibraryContent('source'), isFalse);
    },
  );

  test('cached TV channels count as library content', () async {
    await db.replaceLibrary('source', 'Source', const [], const [
      Channel(id: 'tv', name: 'TV'),
    ]);

    expect(await db.hasLibraryContent('source'), isTrue);
  });

  for (final kind in [ContentKind.movie, ContentKind.series]) {
    test('cached ${kind.name}-only content counts without TV', () async {
      await db.replaceMediaLibrary('source', kind, const [], [
        MediaItem(id: 'item', title: 'Item', kind: kind),
      ]);

      expect(await db.lastSynced('source'), isNull);
      expect(await db.hasLibraryContent('source'), isTrue);
    });
  }

  test('content belonging to another source does not count', () async {
    await db.replaceLibrary('other', 'Other', const [], const [
      Channel(id: 'tv', name: 'TV'),
    ]);
    for (final kind in [ContentKind.movie, ContentKind.series]) {
      await db.replaceMediaLibrary('other', kind, const [], [
        MediaItem(id: 'item', title: 'Item', kind: kind),
      ]);
    }

    expect(await db.hasLibraryContent('source'), isFalse);
  });

  test('child media alone does not count as a root catalog', () async {
    await db.replaceMediaLibrary('source', ContentKind.series, const [], const [
      MediaItem(
        id: 'child',
        title: 'Child',
        kind: ContentKind.series,
        parentId: 'parent',
      ),
    ], parentId: 'parent');

    expect(await db.hasLibraryContent('source'), isFalse);
  });
}
