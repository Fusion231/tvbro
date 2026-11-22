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
import 'package:iptvs/widgets/routed_focus_node.dart';
import 'package:iptvs/widgets/tv_text_field.dart';

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

  testWidgets('TV goBack closes editing, search and Favorites in order', (
    tester,
  ) async {
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
    Future<void> pressBack() async {
      await tester.sendKeyEvent(
        LogicalKeyboardKey.goBack,
        // Flutter has no physical test key for Tizen's logical goBack.
        physicalKey: PhysicalKeyboardKey.escape,
      );
      await tester.pump();
    }

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
      await tester.tap(find.byKey(const ValueKey('home-favorites')));
      await tester.pump();
      await tester.tap(find.byType(TvTextField));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'example');
      await tester.pump();
      expect(
        focusRouteKey(FocusManager.instance.primaryFocus),
        'TvTextField.field',
      );

      await pressBack();
      expect(
        focusRouteKey(FocusManager.instance.primaryFocus),
        'live.search.cell',
      );
      expect(
        tester.widget<TvTextField>(find.byType(TvTextField)).controller.text,
        'example',
      );
      await pressBack();
      expect(focusRouteKey(FocusManager.instance.primaryFocus), 'library.home');
      expect(
        tester.widget<TvTextField>(find.byType(TvTextField)).controller.text,
        isEmpty,
      );
      await pressBack();
      expect(
        focusRouteKey(FocusManager.instance.primaryFocus),
        'content.tab.favorites',
      );
      await pressBack();
      expect(find.text('Press Back again to exit'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() => db.epgIngest.cancelAndWait());
      await tester.pump(const Duration(seconds: 11));
    }
  });
}
