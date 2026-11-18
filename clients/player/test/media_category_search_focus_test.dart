import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/device_class.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/data/source_store.dart';
import 'package:iptvs/screens/channel_list_screen.dart';
import 'package:iptvs/screens/global_search_view.dart';
import 'package:iptvs/screens/media_tab_view.dart';
import 'package:iptvs/sources/demo_source.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/source_config.dart';
import 'package:iptvs/widgets/routed_focus_node.dart';

void main() {
  late Directory temp;
  late AppDatabase db;
  setUp(() async {
    temp = Directory.systemTemp.createTempSync('tvbro_category_focus_qa');
    db = await AppDatabase.openAt('${temp.path}/iptv.db');
    FlutterSecureStorage.setMockInitialValues({});
  });
  tearDown(() async {
    await db.close();
    temp.deleteSync(recursive: true);
  });

  for (final kind in [ContentKind.movie, ContentKind.series]) {
    testWidgets('${kind.name} category focus after clearing search', (
      tester,
    ) async {
      final wasTelevision = isTelevision;
      debugIsTelevision = true;
      tester.view.physicalSize = const Size(873, 491);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        debugIsTelevision = wasTelevision;
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final repo = LibraryRepository(
        source: _CategorySource(),
        db: db,
        metadataProviders: const [],
        autoEnrichMetadata: false,
      );
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: ChannelListScreen(
              repo: repo,
              config: const SourceConfig(
                id: 'demo',
                kind: SourceKind.demo,
                label: 'Demo',
                fields: {},
              ),
              store: SourceStore(),
            ),
          ),
        );
        await tester.tap(find.byKey(ValueKey('home-${kind.name}')));
        await _awaitCatalog(tester, filtered: false);

        await _press(tester, LogicalKeyboardKey.arrowLeft);
        expect(_route, 'media.category.all');
        await _press(tester, LogicalKeyboardKey.arrowDown);
        expect(_route, 'media.category.action');
        await _press(tester, LogicalKeyboardKey.select);
        await _awaitCatalog(tester, filtered: true);
        await _press(tester, LogicalKeyboardKey.arrowRight);
        expect(_route, 'media.${kind.name}.first');
        await _press(tester, LogicalKeyboardKey.arrowLeft);
        expect(_route, 'media.category.action');
        await _press(tester, LogicalKeyboardKey.arrowRight);
        await _press(tester, LogicalKeyboardKey.arrowUp);
        expect(_route, 'library.home');
        await _press(tester, LogicalKeyboardKey.arrowRight);
        expect(_route, 'live.search.cell');
        await _press(tester, LogicalKeyboardKey.select);
        await tester.enterText(find.byType(TextField), 'no-match');
        await tester.pump();
        expect(find.byType(GlobalSearchView), findsOneWidget);

        await tester.binding.handlePopRoute();
        await tester.pump();
        await tester.binding.handlePopRoute();
        await _awaitCatalog(tester, filtered: true);
        expect(_route, 'library.home');
        await _press(tester, LogicalKeyboardKey.arrowDown);
        expect(_route, 'media.${kind.name}.first');
        await _press(tester, LogicalKeyboardKey.arrowLeft);
        expect(_route, 'media.category.action');
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() => db.epgIngest.cancelAndWait());
        await tester.pump(const Duration(seconds: 11));
      }
    });
  }
}

String get _route => focusRouteKey(FocusManager.instance.primaryFocus);

Future<void> _press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pump(const Duration(milliseconds: 150));
}

Future<void> _awaitCatalog(
  WidgetTester tester, {
  required bool filtered,
}) async {
  final ready = find.byWidgetPredicate(
    (widget) =>
        widget is MediaTabView &&
        !widget.loading &&
        widget.categoryFilterActive == filtered &&
        widget.visible.isNotEmpty,
  );
  for (var frame = 0; frame < 40; frame++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (ready.evaluate().isNotEmpty) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
  }
  fail('Catalog did not become ready (filtered=$filtered).');
}

class _CategorySource extends DemoSource {
  @override
  Future<List<MediaCategory>> mediaCategories(ContentKind kind) async => [
    MediaCategory(id: 'action', title: 'Action', kind: kind),
    MediaCategory(id: 'comedy', title: 'Comedy', kind: kind),
  ];

  @override
  Future<List<MediaItem>> mediaItems(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    int? maxPages,
  }) async => [
    for (final category in ['action', 'comedy'])
      if (categoryId == null || categoryId == category)
        MediaItem(
          id: '${kind.name}-$category',
          title: category,
          kind: kind,
          categoryId: category,
        ),
  ];
}
