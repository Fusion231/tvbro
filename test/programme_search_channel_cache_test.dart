import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/channel_organization.dart';
import 'package:iptvs/data/epg_models.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/data/parental_controls.dart';
import 'package:iptvs/data/profile_pin.dart';
import 'package:iptvs/data/source_store.dart';
import 'package:iptvs/screens/channel_list_screen.dart';
import 'package:iptvs/screens/global_search_view.dart';
import 'package:iptvs/screens/live_tab_view.dart';
import 'package:iptvs/sources/demo_source.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/source_config.dart';
import 'package:iptvs/widgets/tv_text_field.dart';

class _IdReads {
  int count = 0;
}

class _CountedChannel extends Channel {
  const _CountedChannel(String id, this.reads)
    : _id = id,
      super(id: id, name: 'Match $id');

  final String _id;
  final _IdReads reads;

  @override
  String get id {
    reads.count++;
    return _id;
  }
}

class _CacheDatabase implements AppDatabase {
  @override
  Stream<String> get epgChanged => const Stream.empty();

  @override
  Stream<void> get favoritesReplaced => const Stream.empty();

  @override
  Stream<void> get favoritesChanged => const Stream.empty();

  @override
  Stream<void> get playbackPositionsReplaced => const Stream.empty();

  @override
  Future<Set<String>> readFavoriteIds(
    String sourceId,
    ContentKind kind,
  ) async => const {};

  @override
  Future<List<({String sourceId, Channel channel})>>
  readFavoriteChannelsAcrossSources() async => const [];

  @override
  Future<List<PlaybackPosition>> readRecentPositions(
    String sourceId, {
    int limit = 20,
  }) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CacheRepository extends LibraryRepository {
  _CacheRepository(String id, this.channels)
    : super(
        source: DemoSource(sourceId: id),
        db: _CacheDatabase(),
        autoEnrichMetadata: false,
      );

  List<Channel> channels;
  final changes = StreamController<ContentKind>.broadcast(sync: true);

  @override
  Stream<ContentKind> get catalogChanged => changes.stream;

  @override
  Future<LibrarySnapshot> load({bool forceRefresh = false}) async =>
      LibrarySnapshot(
        channels: channels,
        categories: const [],
        fromCache: true,
        syncedAt: DateTime(2026),
      );

  @override
  Future<({Map<String, Programme> now, Map<String, Programme> next})> nowNext({
    List<String>? channelIds,
  }) async => (
    now: const <String, Programme>{},
    next: const <String, Programme>{},
  );

  @override
  Future<List<ProgrammeSearchResult>> searchProgrammes(
    String query, {
    Set<String>? allowedChannelIds,
    DateTime? from,
    DateTime? to,
    int limit = 80,
  }) async => const [];
}

void main() {
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    debugDisableNetworkChannelLogos = true;
    await ParentalControlService.instance.save(const ParentalRules());
  });

  tearDown(() => debugDisableNetworkChannelLogos = false);

  SourceConfig configFor(String sourceId) => SourceConfig(
    id: sourceId,
    kind: SourceKind.demo,
    label: sourceId,
    fields: const {},
  );

  Widget screen(
    _CacheRepository repo,
    SourceConfig config, {
    String profileName = 'Profile',
  }) => MaterialApp(
    home: ChannelListScreen(
      repo: repo,
      config: config,
      store: SourceStore(),
      profileName: profileName,
    ),
  );

  Future<void> pumpUpdates(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  Future<void> openSearch(
    WidgetTester tester,
    _CacheRepository repo,
    SourceConfig config,
  ) async {
    // The phone layout exercises the same search parent without requiring a
    // native preview engine in a host widget test.
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() => tester.pumpWidget(const SizedBox()));

    await tester.pumpWidget(screen(repo, config));
    await pumpUpdates(tester);
    await tester.tap(find.byKey(const ValueKey('home-live')));
    await pumpUpdates(tester);
    final field = tester.widget<TvTextField>(find.byType(TvTextField));
    field.controller.text = 'match';
    field.onChanged!('match');
    await pumpUpdates(tester);
    expect(find.byType(GlobalSearchView), findsOneWidget);
  }

  Set<String> programmeIds(WidgetTester tester) => tester
      .widget<GlobalSearchView>(find.byType(GlobalSearchView))
      .programmeChannelIds!;

  testWidgets('50k-channel search reuses IDs without another catalog scan', (
    tester,
  ) async {
    final reads = _IdReads();
    final repo = _CacheRepository('large', [
      for (var i = 0; i < 50000; i++) _CountedChannel('$i', reads),
    ]);
    addTearDown(repo.changes.close);
    final config = configFor(repo.source.id);
    await openSearch(tester, repo, config);
    final first = programmeIds(tester);
    expect(first, hasLength(50000));

    reads.count = 0;
    await tester.pumpWidget(screen(repo, config, profileName: 'Changed'));
    await pumpUpdates(tester);
    final rebuilt = programmeIds(tester);
    debugPrint(
      'PROGRAMME_SEARCH_CACHE_WORK channels=50000 '
      'idReadsAfterRebuild=${reads.count} reused=${identical(rebuilt, first)}',
    );
    expect(rebuilt, same(first));
    // Lazy visible result rows can read a few IDs; rebuilding the allowed-ID
    // set would read every one of the 50,000 channels again.
    expect(reads.count, lessThan(100));

    final field = tester.widget<TvTextField>(find.byType(TvTextField));
    field.controller.text = 'match 2';
    field.onChanged!('match 2');
    await pumpUpdates(tester);
    expect(programmeIds(tester), same(first));
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings and parental changes invalidate allowed search IDs', (
    tester,
  ) async {
    final repo = _CacheRepository('filtered', const [
      Channel(id: 'shown', name: 'Match shown', categoryId: 'public'),
      Channel(
        id: 'hidden-category',
        name: 'Match hidden',
        categoryId: 'hidden',
      ),
      Channel(id: 'hidden-channel', name: 'Match hidden channel'),
      Channel(id: 'locked-channel', name: 'Match protected channel'),
      Channel(
        id: 'locked-category',
        name: 'Match protected',
        categoryId: 'locked',
      ),
    ]);
    addTearDown(repo.changes.close);
    final config = configFor(repo.source.id)
        .withHiddenCategories(ContentKind.live, {'hidden'})
        .withChannelOrganization(
          const ChannelOrganization(hidden: {'hidden-channel'}),
        );
    await openSearch(tester, repo, config);
    final initial = programmeIds(tester);
    expect(initial, {'shown', 'locked-channel', 'locked-category'});

    final verifier = hashProfilePin(
      '4821',
      salt: List.filled(16, 7),
      iterations: 1,
    );
    await ParentalControlService.instance.save(
      ParentalRules(
        verifier: verifier,
        channels: {ParentalRules.channelKey(repo.source.id, 'locked-channel')},
        categories: {
          ParentalRules.categoryKey(repo.source.id, ContentKind.live, 'locked'),
        },
      ),
    );
    await pumpUpdates(tester);
    final locked = programmeIds(tester);
    expect(locked, isNot(same(initial)));
    expect(locked, {'shown'});

    ParentalControlService.instance.unlock(verifier);
    await pumpUpdates(tester);
    final unlocked = programmeIds(tester);
    expect(unlocked, isNot(same(locked)));
    expect(unlocked, initial);

    await tester.pumpWidget(screen(repo, configFor(repo.source.id)));
    await pumpUpdates(tester);
    final all = programmeIds(tester);
    expect(all, isNot(same(unlocked)));
    expect(all, {
      'shown',
      'hidden-category',
      'hidden-channel',
      'locked-channel',
      'locked-category',
    });
    expect(tester.takeException(), isNull);
  });

  testWidgets('catalog refresh and source replacement replace allowed IDs', (
    tester,
  ) async {
    final repo = _CacheRepository('first', const [
      Channel(id: 'old', name: 'Match old'),
    ]);
    addTearDown(repo.changes.close);
    final config = configFor(repo.source.id);
    await openSearch(tester, repo, config);
    final initial = programmeIds(tester);
    expect(initial, {'old'});

    repo.channels = const [Channel(id: 'new', name: 'Match new')];
    repo.changes.add(ContentKind.live);
    await pumpUpdates(tester);
    final refreshed = programmeIds(tester);
    expect(refreshed, isNot(same(initial)));
    expect(refreshed, {'new'});

    final replacement = _CacheRepository('second', const [
      Channel(id: 'other', name: 'Match other'),
    ]);
    addTearDown(replacement.changes.close);
    await tester.pumpWidget(
      screen(replacement, configFor(replacement.source.id)),
    );
    await pumpUpdates(tester);
    final replaced = programmeIds(tester);
    expect(replaced, isNot(same(refreshed)));
    expect(replaced, {'other'});
    expect(tester.takeException(), isNull);
  });
}
