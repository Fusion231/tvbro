import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/screens/epg_grid_screen.dart';
import 'package:iptvs/sources/demo_source.dart';
import 'package:iptvs/sources/source.dart';

class _GuideDatabase implements AppDatabase {
  final changed = StreamController<String>.broadcast(sync: true);
  final batches = <List<String>>[];
  int version = 1;
  final at = DateTime(2026, 10, 23, 12);

  @override
  Stream<String> get epgChanged => changed.stream;

  @override
  Future<Map<String, List<Programme>>> programmesForChannels(
    String sourceId,
    List<String> channelIds, {
    required DateTime from,
    required DateTime to,
  }) async {
    batches.add([...channelIds]);
    return {
      for (final id in channelIds)
        id: [
          Programme(
            channelId: id,
            start: at.subtract(const Duration(minutes: 10)),
            stop: at.add(const Duration(hours: 1)),
            title: 'Guide $version $id',
          ),
        ],
    };
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets(
    'guide refresh retains only the viewport buffer and selected row',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = _GuideDatabase();
      final source = DemoSource();
      final scroll = ScrollController();
      final channels = [
        for (var i = 0; i < 1000; i++) Channel(id: 'ch$i', name: 'Channel $i'),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: EpgGridScreen(
            repo: LibraryRepository(source: source, db: db),
            channels: channels,
            rowExtent: 100,
            scrollController: scroll,
            now: () => db.at,
            onPlayChannel: (_) {},
            onPlayArchive: (_, _) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Guide 1 ch1'), findsOneWidget);

      scroll.jumpTo(20000);
      await tester.pumpAndSettle();
      expect(find.text('Guide 1 ch200'), findsOneWidget);
      db.batches.clear();
      db.version = 2;
      db.changed.add(source.id);
      await tester.pumpAndSettle();

      final refreshed = db.batches.expand((ids) => ids).toSet();
      expect(refreshed.length, lessThan(50));
      expect(refreshed, containsAll(['ch0', 'ch200']));
      expect(
        refreshed,
        isNot(contains('ch1')),
        reason: 'an evicted row must not be reread on every guide replacement',
      );
      expect(find.text('Guide 2 ch200'), findsOneWidget);

      db.batches.clear();
      scroll.jumpTo(0);
      await tester.pumpAndSettle();
      expect(db.batches.expand((ids) => ids), contains('ch1'));
      expect(
        find.text('Guide 2 ch1'),
        findsOneWidget,
        reason: 'returning to an evicted row must read the latest guide',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      scroll.dispose();
      await db.changed.close();
      await source.dispose();
    },
  );
}
