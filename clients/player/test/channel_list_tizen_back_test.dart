import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/data/source_store.dart';
import 'package:iptvs/player/playback_backend.dart';
import 'package:iptvs/screens/channel_list_screen.dart';
import 'package:iptvs/sources/demo_source.dart';
import 'package:iptvs/sources/source_config.dart';

void main() {
  late Directory tempDir;
  late AppDatabase db;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('iptvs_tizen_back_test');
    db = await AppDatabase.openAt('${tempDir.path}/iptv.db');
    FlutterSecureStorage.setMockInitialValues({});
  });

  tearDown(() async {
    await db.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  testWidgets('TV goBack key invokes the existing home Back ladder', (
    tester,
  ) async {
    // Keep this focused on the key-to-Back route. No player or native plugin
    // should be constructed by the home screen.
    PlaybackBackend.register(
      initialize: () {},
      createPlayer: (_) => throw StateError('Unexpected player creation'),
      ownsPlayer: (_) => true,
      buildVideo: (_, _, _) => const SizedBox.shrink(),
    );

    const config = SourceConfig(
      id: 'demo',
      kind: SourceKind.demo,
      label: 'Demo',
      fields: {},
    );
    final repo = LibraryRepository(source: DemoSource(), db: db);
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: ChannelListScreen(
            repo: repo,
            config: config,
            store: SourceStore(),
          ),
        ),
      );
      await tester.pump();
      await tester.sendKeyEvent(
        LogicalKeyboardKey.goBack,
        // Flutter's test key table has no physical key for goBack. Keep the
        // logical Tizen key while using a known physical key for simulation.
        physicalKey: PhysicalKeyboardKey.escape,
      );
      await tester.pump();

      expect(find.text('Press Back again to exit'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });
}
