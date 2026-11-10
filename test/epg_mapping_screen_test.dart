import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/screens/epg_mapping_screen.dart';
import 'package:iptvs/sources/demo_source.dart';
import 'package:iptvs/sources/epg_mapping.dart';
import 'package:iptvs/sources/source.dart';

class _MappingRepo extends LibraryRepository {
  final saved = <EpgChannelOverride>[];
  _MappingRepo(AppDatabase db) : super(source: DemoSource(), db: db);

  @override
  Future<List<EpgGuideChannel>> readEpgGuideChannels() async => const [
    EpgGuideChannel(
      guideId: 'guide',
      guideLabel: 'User guide',
      channelId: 'discovery',
      displayNames: ['Discovery'],
    ),
  ];

  @override
  Future<List<EpgChannelOverride>> readEpgMappings() async => const [];

  @override
  Future<void> setEpgMapping(
    EpgChannelOverride mapping, {
    List<Channel>? channels,
  }) async {
    saved.add(mapping);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlutterSecureStorage.setMockInitialValues({});
  late AppDatabase db;
  setUp(() async => db = await AppDatabase.openAt(':memory:'));
  tearDown(() => db.close());

  testWidgets('choosing a guide candidate requires Save before persisting', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repo = _MappingRepo(db);
    await tester.pumpWidget(
      MaterialApp(
        home: EpgMappingScreen(
          repo: repo,
          channels: const [Channel(id: 'stable', name: 'Discovery HD')],
          initialChannelId: 'stable',
        ),
      ),
    );
    await tester.pump();
    expect(
      repo.saved,
      isEmpty,
      reason: 'opening suggested matches must not save',
    );
    final search = find.descendant(
      of: find.byKey(const ValueKey('epg.guideSearch')),
      matching: find.byType(TextField),
    );
    await tester.tap(find.byKey(const ValueKey('epg.guideSearch')));
    await tester.pump();
    await tester.enterText(search, 'discovery');
    await tester.pump();
    final candidate = find.byKey(
      const ValueKey('epg.candidate.guide.discovery'),
    );
    await tester.ensureVisible(candidate);
    await tester.tap(candidate);
    await tester.pump();
    expect(
      repo.saved,
      isEmpty,
      reason: 'candidate selection must remain a draft',
    );
    final save = find.byKey(const ValueKey('epg.save'));
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pump();
    expect(repo.saved.single.channelId, 'stable');
    expect(repo.saved.single.guideId, 'guide');
    expect(repo.saved.single.guideChannelId, 'discovery');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
