import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/epg_models.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/screens/global_search_view.dart';
import 'package:iptvs/sources/demo_source.dart';
import 'package:iptvs/sources/source.dart';

class _GuideDb implements AppDatabase {
  final changes = StreamController<String>.broadcast(sync: true);

  @override
  Stream<String> get epgChanged => changes.stream;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _GuideRepo implements LibraryRepository {
  @override
  final _GuideDb db = _GuideDb();
  @override
  final Source source = DemoSource(sourceId: 's');
  final calls = <(String, Set<String>?)>[];
  final pending = <Completer<List<ProgrammeSearchResult>>>[];
  @override
  Future<List<ProgrammeSearchResult>> searchProgrammes(
    String query, {
    Set<String>? allowedChannelIds,
    DateTime? from,
    DateTime? to,
    int limit = 80,
  }) {
    calls.add((query, allowedChannelIds));
    final completer = Completer<List<ProgrammeSearchResult>>();
    pending.add(completer);
    return completer.future;
  }

  @override
  Future<List<MediaItem>> searchMedia(
    ContentKind kind,
    String query, {
    String? categoryId,
  }) async => [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets(
    'programme search waits for typing and drops stale results after a lock',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 1000);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final repo = _GuideRepo();
      addTearDown(repo.db.changes.close);
      ProgrammeSearchResult? opened;
      final result = ProgrammeSearchResult(
        sourceId: 's',
        sourceName: 'Source',
        channel: const Channel(id: 'public', name: 'Provider name'),
        programme: Programme(
          channelId: 'public',
          title: 'Space news',
          start: DateTime(2026, 11, 1, 12),
          stop: DateTime(2026, 11, 1, 13),
        ),
      );
      var query = '';
      Widget search(Set<String> allowed) => MaterialApp(
        home: Scaffold(
          body: GlobalSearchView(
            repo: repo,
            query: query,
            channels: const [],
            channelsLoading: false,
            channelsError: null,
            hiddenMovieCategories: const {},
            hiddenSeriesCategories: const {},
            isMediaAllowed: (_) => true,
            onPlayChannel: (_) {},
            onOpenMedia: (_) {},
            programmeChannelIds: allowed,
            channelNames: const {'public': 'My news'},
            onOpenProgramme: (value) => opened = value,
          ),
        ),
      );
      await tester.pumpWidget(search({'public'}));
      repo.db.changes.add('s');
      await tester.pump(const Duration(seconds: 1));
      expect(repo.calls, isEmpty);
      query = 'space';
      await tester.pumpWidget(search({'public', 'protected'}));
      repo.db.changes.add('s');
      await tester.pump(const Duration(milliseconds: 799));
      expect(repo.calls, isEmpty);
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pumpWidget(search({'public'}));
      await tester.pump(const Duration(milliseconds: 800));
      expect(repo.calls.map((call) => call.$1), ['space', 'space']);
      expect(repo.calls.first.$2, {'public', 'protected'});
      expect(repo.calls.last.$2, {'public'});
      repo.pending.last.complete([result]);
      await tester.pumpAndSettle();
      final row = find.textContaining('Space news\nMy news');
      expect(row, findsOneWidget);
      await tester.tap(row);
      expect(opened, same(result));
      repo.pending.first.complete([]);
      await tester.pumpAndSettle();
      expect(row, findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
